"""Evaluate one fixed candidate set against decision, stored rank and public LM."""
import argparse
import importlib.util
import json
import sys
from pathlib import Path

import numpy as np
import torch

from common import ROOT, digest, kata, private_output, read_json, rows, write_json
from metrics import summarize
from train import encode_records, load_model, predict


def heuristic_orders(records):
    path=ROOT.parent/'ai-rerank/evaluate-fast-context-rerank.py'
    spec=importlib.util.spec_from_file_location('gyaim_heuristic',path)
    module=importlib.util.module_from_spec(spec)
    sys.modules[spec.name]=module
    spec.loader.exec_module(module)
    result=[]
    for r in records:
        request=dict(version=1,mode='fast-context-rerank',inputPat=r['readingRoman'],hiragana=r['readingHiragana'],
                     context=r['context'],candidates=[dict(c,index=i) for i,c in enumerate(r['candidates'])])
        result.append(module.run_heuristic_backend(request)['order'])
    return result


def baseline_lm(records, model_path):
    path = ROOT.parent / 'model-training/compare-hf-gguf.py'
    spec = importlib.util.spec_from_file_location('gyaim_lm_baseline', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    scorer = module.HFScorer(str(model_path))
    logits = np.full((len(records),25), -10000., dtype=np.float32)
    for j, r in enumerate(records):
        # Matches current ZenzPrompt: last 20 characters, Japanese reading, output tag.
        context = r['context'][-20:]
        prompt = ('\uee02' + context if context else '') + '\uee00' + kata(r['readingHiragana']) + '\uee01'
        for i, c in enumerate(r['candidates']):
            score = scorer.score(prompt, c['text'])
            if score is None or not np.isfinite(score):
                raise RuntimeError('baseline scoring failed')
            logits[j,i] = score
        if (j+1) % 100 == 0:
            print(f'baseline scored {j+1}/{len(records)}', flush=True)
    return logits


def evaluate(model_dir, dataset, output, device='cpu', lm=None, limit=0, temperature=None):
    records = list(rows(dataset))
    if limit:
        records = records[:limit]
    if not records:
        raise ValueError('evaluation split is empty')
    meta = read_json(Path(model_dir) / 'metadata.json')
    input_manifest=Path(dataset).parent/'manifest.json'
    private = (meta['provenance']['privacy']=='private'
               or any(r.get('privacy')=='private' or r.get('origin')=='dogfood' for r in records)
               or (input_manifest.exists() and read_json(input_manifest).get('privacy')=='private'))
    if private:
        private_output(output)
    model, config, tokenizer = load_model(model_dir, device)
    torch.set_num_threads(config['training'].get('cpu_threads',4))
    arrays = encode_records(records, tokenizer)
    logits = predict(model, arrays, device, config['training']['batch_size'])
    if temperature is None:
        calibration = Path(model_dir) / 'calibration.json'
        temperature = read_json(calibration)['temperature'] if calibration.exists() else 1.
    baseline=heuristic_orders(records)
    report, errors = summarize(logits, records, temperature, baseline_orders=baseline)
    report['heuristicProtocol']='existing evaluate-fast-context-rerank.py Python port; identical candidate sets'
    report['modelHash']=digest(Path(model_dir)/'model.pt')
    report['privacy']='private' if private else 'public'
    report.update(datasetHash=digest(dataset), limit=limit, temperature=temperature)
    tag_subsets={tag:[i for i,r in enumerate(records) if tag in r.get('tags',[])]
                 for tag in sorted({tag for r in records for tag in r.get('tags',[])})}
    report['subsets']={}
    for tag,indices in tag_subsets.items():
        subset,_=summarize(logits[indices],[records[i] for i in indices],temperature,
                           baseline_orders=[baseline[i] for i in indices])
        report['subsets'][tag]={k:subset[k] for k in ['count','ranking','heuristic','relative','decisionAccuracy','none']}
    if lm:
        lm_logits = baseline_lm(records, lm)
        lm_report, _ = summarize(lm_logits, records, supports_none=False, baseline_orders=baseline)
        report['gyaimLM'] = lm_report
        report['gyaimLM']['protocol'] = 'HF conditional mean-logprob; context suffix20; identical candidates; no runtime guards; NONE unsupported'
        report['gyaimLM']['modelConfigHash'] = digest(Path(lm) / 'config.json')
        report['gyaimLM']['trainingOverlap'] = ('The existing LM was trained on the public zenz sources. '
            'Decision-model test splits are not certified unseen for that baseline; regression fixtures are reported separately.')
        report['gyaimLM']['weightHashes'] = {p.name:digest(p) for p in Path(lm).glob('*.safetensors')}
        report['gyaimLM']['subsets']={}
        for tag,indices in tag_subsets.items():
            subset,_=summarize(lm_logits[indices],[records[i] for i in indices],supports_none=False,
                               baseline_orders=[baseline[i] for i in indices])
            report['gyaimLM']['subsets'][tag]={k:subset[k] for k in ['count','ranking','relative']}
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    write_json(output / 'evaluation.json', report)
    # Errors deliberately contain IDs/indexes only; private text never enters reports/logs.
    with (output / 'errors.jsonl').open('w', encoding='utf-8') as f:
        for error in errors:
            f.write(json.dumps(error)+'\n')
    write_json(output / 'largest-regressions.json', sorted(errors,key=lambda e:-e['rankRegression'])[:50])
    np.savez(output / 'predictions.npz', logits=logits, targets=np.array([24 if r['selected'] is None else r['selected'] for r in records]))
    print(json.dumps({k:report[k] for k in ['count','ranking','relative','none']}, ensure_ascii=False), flush=True)
    return report


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model', type=Path, required=True)
    p.add_argument('--data', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--device', default='cpu')
    p.add_argument('--lm', type=Path)
    p.add_argument('--limit', type=int, default=0)
    a = p.parse_args()
    evaluate(a.model,a.data,a.output,a.device,a.lm,a.limit)
