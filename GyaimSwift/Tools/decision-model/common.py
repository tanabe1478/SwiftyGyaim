"""Versioned request contract and deterministic preprocessing (no model imports)."""
from __future__ import annotations

import hashlib
import json
import math
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
SOURCES = ['unknown', 'study', 'local', 'connection', 'external', 'google', 'synthetic']
KINDS = ['unknown', 'exact', 'prefix', 'compound', 'kana', 'raw', 'completion', 'google']
MAX_CANDIDATES = 24
SPLITS = ['train', 'validation', 'calibration', 'test']


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def write_json(path, obj):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')


def rows(path):
    with Path(path).open(encoding='utf-8-sig') as f:
        for line in f:
            if line.strip():
                yield json.loads(line)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(8 * 1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def key(*parts):
    return hashlib.sha256(json.dumps(parts, ensure_ascii=False).encode()).hexdigest()


def normalize(text):
    # Deliberately no NFKC, case folding or stripping. Preserve symbols and emoji.
    return unicodedata.normalize('NFC', text).replace(' ', '\u3000')


def hira(text):
    return ''.join(chr(ord(c) - 96) if '\u30a1' <= c <= '\u30f6' else c for c in text)


def kata(text):
    return ''.join(chr(ord(c) + 96) if '\u3041' <= c <= '\u3096' else c for c in text)


def validate(row, labeled=False):
    if row.get('schemaVersion', 1) != 1:
        raise ValueError('unsupported schemaVersion')
    for field in ['context', 'readingRoman', 'readingHiragana']:
        if not isinstance(row.get(field), str):
            raise ValueError(f'{field} must be a string')
    candidates = row.get('candidates')
    if not isinstance(candidates, list) or not 1 <= len(candidates) <= 24:
        raise ValueError('expected 1..24 candidates')
    for c in candidates:
        if not isinstance(c.get('text'), str) or not c['text']:
            raise ValueError('candidate text must be nonempty')
        if c.get('reading') is not None and not isinstance(c['reading'], str):
            raise ValueError('reading must be string or null')
        if c.get('source', 'unknown') not in SOURCES or c.get('kind', 'unknown') not in KINDS:
            raise ValueError('unknown source/kind enum')
        rank = c.get('originalRank')
        if rank is not None and (type(rank) is not int or rank < 0):
            raise ValueError('originalRank must be nonnegative integer or null')
        freq = c.get('studyFrequency')
        if freq is not None and (type(freq) is not int or freq < 0):
            raise ValueError('invalid studyFrequency')
        affinity = c.get('contextAffinity')
        if affinity is not None and (type(affinity) not in (int, float) or not math.isfinite(affinity) or not 0 <= affinity <= 1):
            raise ValueError('contextAffinity must be in [0,1] or null')
        if c.get('exactReadingMatch') is not None and type(c['exactReadingMatch']) is not bool:
            raise ValueError('exactReadingMatch must be bool or null')
    if labeled:
        if 'selected' not in row:
            raise ValueError('labeled examples require selected (null means NONE)')
        target = row.get('selected')
        if target is not None and (type(target) is not int or not 0 <= target < len(candidates)):
            raise ValueError('selected must be candidate index or null (NONE)')
    return row


def candidate(text, reading, source='unknown', kind='unknown', rank=None, **extra):
    return dict(text=text, reading=reading, source=source, kind=kind, originalRank=rank,
                studyFrequency=None, contextAffinity=None, exactReadingMatch=None, **extra)


def private_output(path):
    path = Path(path).resolve()
    if not path.is_relative_to((ROOT / 'private').resolve()):
        raise ValueError('private data and derived outputs must stay under decision-model/private/')
    return path


def validate_config(config):
    if config.get('schemaVersion')!=1:
        raise ValueError('unsupported config schemaVersion')
    m,d,t=config['model'],config['data'],config['training']
    if d.get('cache_mode','memory') not in ['memory','indexed']:
        raise ValueError('data.cache_mode must be memory or indexed')
    for name in ['hidden_size','layers','heads','vocab_size']:
        if type(m[name]) is not int or m[name]<1:
            raise ValueError(f'model.{name} must be positive integer')
    if m['hidden_size']%m['heads'] or not 0<=m['dropout']<1:
        raise ValueError('invalid heads/dropout configuration')
    if d['max_candidates']!=24 or d['max_candidate_tokens']<2:
        raise ValueError('schema v1 requires max_candidates=24 and at least two candidate tokens')
    budgets=d.get('segment_budgets',[64,24,24])
    if len(budgets)!=3 or min(budgets)<1 or sum(budgets)>d['max_context_tokens']:
        raise ValueError('state segment budgets must fit max_context_tokens')
    for name in ['batch_size','epochs','checkpoint_steps','validation_steps','benchmark_steps','cpu_threads']:
        if type(t[name]) is not int or t[name]<1:
            raise ValueError(f'training.{name} must be positive integer')
    if t['device'] not in ['cpu','cuda'] or t['precision'] not in ['fp32','fp16','bf16']:
        raise ValueError('unsupported device/precision')
    if not all(math.isfinite(t[k]) and t[k]>0 for k in ['learning_rate','grad_clip']):
        raise ValueError('invalid learning_rate/grad_clip')
    if not math.isfinite(t['weight_decay']) or t['weight_decay']<0:
        raise ValueError('invalid weight_decay')
    return config
