"""Pinned HF tokenizers backend, explicit segment packing and golden vectors."""
from __future__ import annotations

import argparse
import shutil
import unicodedata
from functools import lru_cache
from pathlib import Path

import numpy as np
from tokenizers import Tokenizer as Backend

from common import ROOT, SOURCES, KINDS, digest, normalize, validate, write_json

INPUT_NAMES = ['state_ids', 'state_segments', 'state_mask', 'candidate_ids', 'candidate_segments',
               'token_mask', 'candidate_mask', 'categories', 'numeric']


class Tokenizer:
    def __init__(self, path, config):
        self.backend = Backend.from_file(str(path))
        self.backend.no_truncation()
        self.backend.no_padding()
        self.config = config
        self.pad = self.backend.token_to_id('[PAD]')
        self.unk = self.backend.token_to_id('[UNK]')
        if self.pad is None:
            raise ValueError('tokenizer must contain [PAD]')

    @lru_cache(maxsize=8192)
    def scalar(self, c):
        return tuple(self.backend.encode(c, add_special_tokens=False).ids)

    def encode(self, text):
        # Encode one Unicode scalar at a time so literal special-token strings
        # in user text cannot inject reserved tokens into the tensor protocol.
        return [t for c in normalize(text) for t in self.scalar(c)]

    def pack(self, segments, size):
        ids, types = [], []
        # Reserve room for readings before retaining the context suffix.
        budgets = self.config.get('segment_budgets', [64, 24, 24])
        for i, text in enumerate(segments):
            tokens = self.encode(text)
            budget = budgets[i] if len(segments) == 3 else size // 2
            tokens = tokens[-budget:] if len(segments) == 3 and i == 0 else tokens[:budget]
            ids.extend(tokens)
            types.extend([i] * len(tokens))
        ids, types = ids[:size], types[:size]
        # An empty segment collection still has a valid neutral token.
        if not ids:
            ids, types = [self.pad], [0]
        mask = [True] * len(ids) + [False] * (size - len(ids))
        return ids + [self.pad] * (size - len(ids)), types + [0] * (size - len(types)), mask

    def batch(self, records):
        b, n = len(records), 24
        s, c = self.config['max_context_tokens'], self.config['max_candidate_tokens']
        out = dict(state_ids=np.full((b, s), self.pad, np.int64), state_segments=np.zeros((b, s), np.int64),
                   state_mask=np.zeros((b, s), bool), candidate_ids=np.full((b, n, c), self.pad, np.int64),
                   candidate_segments=np.zeros((b, n, c), np.int64), token_mask=np.zeros((b, n, c), bool),
                   candidate_mask=np.zeros((b, n), bool), categories=np.zeros((b, n, 2), np.int64),
                   numeric=np.zeros((b, n, 8), np.float32))
        out['token_mask'][:, :, 0] = True
        for j, r in enumerate(records):
            validate(r)
            a, t, m = self.pack([r['context'], r['readingRoman'], r['readingHiragana']], s)
            out['state_ids'][j], out['state_segments'][j], out['state_mask'][j] = a, t, m
            for i, cand in enumerate(r['candidates']):
                a, t, m = self.pack([cand['text'], cand.get('reading') or ''], c)
                out['candidate_ids'][j, i], out['candidate_segments'][j, i], out['token_mask'][j, i] = a, t, m
                out['candidate_mask'][j, i] = True
                out['categories'][j, i] = [SOURCES.index(cand.get('source', 'unknown')), KINDS.index(cand.get('kind', 'unknown'))]
                rank, freq, affinity, exact = [cand.get(k) for k in ['originalRank', 'studyFrequency', 'contextAffinity', 'exactReadingMatch']]
                out['numeric'][j, i] = [min(rank or 0, 23) / 23, min(np.log1p(freq or 0), 10) / 10,
                                         affinity or 0, float(exact or False), rank is not None, freq is not None,
                                         affinity is not None, exact is not None]
        for k in ['state_ids', 'candidate_ids']:
            out[k] = out[k].astype(np.int32)
        for k in ['state_segments', 'candidate_segments', 'categories']:
            out[k] = out[k].astype(np.int8)
        return out


def prepare(source, output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(Path(source) / 'tokenizer.json', output / 'tokenizer.json')
    tk = Tokenizer(output / 'tokenizer.json', {})
    probes = {'hiragana': 'ひらがな', 'katakana': 'カタカナ', 'kanji': '機能昨日仕様使用', 'rare': '𠮷𩸽髙﨑',
              'ascii': 'ABC xyz', 'romaji': 'kinou nn kya', 'numbers': '123４５６', 'symbols': '〇△×!?。、',
              'emoji': '👨‍👩‍👧‍👦🙂', 'dictionary': 'SwiftyGyaim再現性', 'literalSpecial': '[PAD]', 'combining': 'か\u3099'}
    vectors = []
    for category, text in probes.items():
        ids = tk.encode(text)
        vectors.append(dict(category=category, text=text, normalized=normalize(text), ids=ids,
                            unknownCount=ids.count(tk.unk), tokensPerScalar=len(ids) / len(text)))
    write_json(output / 'tokenizer-vectors.json', vectors)
    write_json(output / 'tokenizer-spec.json', dict(schemaVersion=1, tokenizerHash=digest(output / 'tokenizer.json'),
               vocabularySize=tk.backend.get_vocab_size(), normalization='NFC then U+0020 -> U+3000; no strip/casefold',
               unicodeVersion=unicodedata.unidata_version,
               algorithm='Encode each Unicode scalar separately with tokenizer.json; concatenate; add_special_tokens=false',
               paddingId=tk.pad, segmentIds={'context/text': 0, 'roman/reading': 1, 'hiragana': 2},
               truncation='Use config.data.segment_budgets for state; context suffix, roman/kana prefixes. Candidate text and reading each use floor(max_candidate_tokens/2) prefix tokens.',
               source='ku-nlp/gpt2-small-japanese-char, copied from local public gyaim-lm artifact',
               note='No new vocabulary/special tokens. Scalar encoding prevents special-token injection.'))
    return vectors


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--source', type=Path, default=ROOT.parent / 'model-training/runs/zenz-v2.5-full/final')
    p.add_argument('--output', type=Path, default=ROOT / 'data/tokenizer')
    args = p.parse_args()
    vectors = prepare(args.source, args.output)
    print({'categories': len(vectors), 'unknownTokens': sum(v['unknownCount'] for v in vectors)})
