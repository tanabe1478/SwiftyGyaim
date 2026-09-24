"""Fit scalar temperature on an independently hashed calibration split."""
import argparse
from pathlib import Path

import numpy as np
import torch

from common import digest, private_output, read_json, rows, write_json
from metrics import calibration_metrics, probabilities
from train import encode_records, load_model, predict


def fit_temperature(logits, targets):
    # Bounded scalar optimization on CPU, no gradient or model mutation.
    def objective(log_t):
        probs = probabilities(logits, np.exp(log_t))
        return float(-np.log(probs[np.arange(len(targets)), targets].clip(1e-15)).mean())
    lo, hi = -3., 3.
    for _ in range(80):
        a, b = lo+(hi-lo)/3, hi-(hi-lo)/3
        if objective(a) < objective(b):
            hi = b
        else:
            lo = a
    value = float(np.exp((lo+hi)/2))
    return value if objective(np.log(value)) <= objective(0) else 1.


def calibrate(model_dir, dataset, device):
    manifest = read_json(dataset.parent / 'manifest.json')
    if manifest['files']['calibration'] != digest(dataset):
        raise ValueError('must use the manifest calibration split')
    meta = read_json(model_dir / 'metadata.json')
    if digest(dataset.parent / 'manifest.json') != meta['provenance']['datasetManifestHash']:
        raise ValueError('calibration dataset differs from training provenance')
    if manifest['privacy']=='private':
        private_output(model_dir)
    model, config, tokenizer = load_model(model_dir, device)
    torch.set_num_threads(config['training'].get('cpu_threads',4))
    records = list(rows(dataset))
    logits = predict(model, encode_records(records,tokenizer), device, config['training']['batch_size'])
    targets = np.array([24 if r['selected'] is None else r['selected'] for r in records])
    temperature = fit_temperature(logits, targets)
    report = dict(schemaVersion=1, method='temperature-scaling', temperature=temperature, count=len(records),
                  datasetHash=digest(dataset), modelHash=digest(model_dir/'model.pt'),
                  before=calibration_metrics(probabilities(logits),targets),
                  after=calibration_metrics(probabilities(logits,temperature),targets))
    write_json(model_dir / 'calibration.json', report)
    print({'temperature':temperature,'beforeNLL':report['before']['nll'],'afterNLL':report['after']['nll']})
    return report


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model',type=Path,required=True)
    p.add_argument('--data',type=Path,required=True)
    p.add_argument('--device',default='cpu')
    a=p.parse_args()
    calibrate(a.model,a.data,a.device)
