"""Cache FP32 contextual pair margins after the same holdout/split filtering."""
import argparse
import json
from pathlib import Path
from prepare_context_training import (ROOT, read_rows, digest, RuntimeRomaToKata,
    load_roma_to_kata, ROMAKANA_SWIFT, context_holdout, legacy_holdout)
from train_context_preference import split_pairs, collate_preference_examples, mean_completion_scores
from context_distillation import pair_fingerprint, load_teacher_margins


def cache_teacher(args):
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM
    output = args.output.resolve()
    if output.exists() or not output.is_relative_to((ROOT/'runs').resolve()):
        raise ValueError('use a new cache file under ignored runs/')
    converter = RuntimeRomaToKata(load_roma_to_kata(ROMAKANA_SWIFT))
    excluded, _ = context_holdout(read_rows(args.context_cases), converter)
    excluded |= legacy_holdout(args.holdout)
    train, valid, filtering = split_pairs(read_rows(args.pairs), excluded, converter, args.seed)
    if not train or not valid or not torch.cuda.is_available():
        raise ValueError('nonempty train/validation splits and GPU required')
    rows = train+valid
    tokenizer = AutoTokenizer.from_pretrained(args.teacher_model)
    model = AutoModelForCausalLM.from_pretrained(args.teacher_model, torch_dtype=torch.float32).cuda().eval()
    records = []
    with torch.inference_mode():
        for start in range(0, len(rows), 16):
            batch_rows = rows[start:start+16]
            examples = []
            for row in batch_rows:
                prompt = tokenizer.encode('\uEE02'+row['context']+'\uEE00'+row['input']+'\uEE01', add_special_tokens=False)
                tails = [tokenizer.encode(row[k], add_special_tokens=False) for k in ('chosen','rejected')]
                if not prompt or any(not t or len(prompt)+len(t)>192 for t in tails):
                    raise ValueError('empty or oversized teacher pair; no truncation')
                examples.append(dict(sequences=[prompt+t for t in tails],
                                     promptLengths=[len(prompt)]*2, reference_delta=0.))
            batch = {k:v.cuda() for k,v in collate_preference_examples(examples,tokenizer.eos_token_id).items()}
            logits = model(batch['input_ids'],attention_mask=batch['attention_mask']).logits
            scores = mean_completion_scores(logits,batch['input_ids'],batch['completion_mask']).reshape(-1,2)
            for row, margin in zip(batch_rows,(scores[:,0]-scores[:,1]).tolist()):
                records.append(dict(pairHash=pair_fingerprint(row),contextMargin=margin))
            if start % 800 == 0:
                print(json.dumps(dict(scoredPairs=len(records),totalPairs=len(rows))),flush=True)
    cache = dict(formatVersion=1,teacherModel=str(args.teacher_model),
        teacherWeightsSha256=digest(args.teacher_model/'model.safetensors'),
        pairsSha256=digest(args.pairs),casesSha256=digest(args.context_cases),
        holdoutSha256=[digest(p) for p in args.holdout],seed=args.seed,
        precision='fp32',textPreprocessing='hf',trainPairs=len(train),validationPairs=len(valid),
        filtering=filtering,torch=torch.__version__,scriptSha256=digest(Path(__file__)),records=records)
    output.parent.mkdir(parents=True,exist_ok=True)
    # A partial file is never treated as a usable cache.
    temporary = output.with_suffix(output.suffix+'.partial')
    if temporary.exists(): raise ValueError('partial cache already exists')
    temporary.write_text(json.dumps(cache,indent=2),encoding='utf8')
    load_teacher_margins(temporary,rows,digest(args.pairs))
    temporary.rename(output)
    print(json.dumps(dict(trainPairs=len(train),validationPairs=len(valid),cacheSha256=digest(output))),flush=True)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--teacher-model',type=Path,required=True)
    parser.add_argument('--pairs',type=Path,required=True)
    parser.add_argument('--context-cases',type=Path,required=True)
    parser.add_argument('--holdout',type=Path,action='append',required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--seed',type=int,default=125)
    cache_teacher(parser.parse_args())
