"""Reference JSON inference. Candidate order is never mutated."""
import argparse
import json
from pathlib import Path

import numpy as np
import yaml

from common import digest, read_json, validate
from metrics import probabilities
from tokenizer import Tokenizer


def inference(directory, request, backend='pytorch'):
    directory = Path(directory)
    validate(request)
    manifest = read_json(directory / 'manifest.json')
    if manifest['schemaVersion'] != 1 or manifest['tokenizerHash'] != digest(directory / 'tokenizer.json'):
        raise ValueError('manifest/tokenizer mismatch')
    for name in ['model.pt' if backend=='pytorch' else 'model.onnx', 'config.yaml', 'calibration.json']:
        if manifest['files'][name] != digest(directory / name):
            raise ValueError(f'artifact checksum mismatch: {name}')
    if backend=='pytorch':
        import torch
        from train import load_model,tensor_batch
        model, config, tokenizer = load_model(directory)
        torch.set_num_threads(config['training'].get('cpu_threads',4))
        batch = tensor_batch(tokenizer.batch([request]), slice(None), 'cpu')
        with torch.inference_mode():
            logits = model(**batch).numpy()
    elif backend=='onnx':
        import onnxruntime as ort
        config=yaml.safe_load((directory/'config.yaml').read_text(encoding='utf-8'))
        tokenizer=Tokenizer(directory/'tokenizer.json',config['data'])
        options=ort.SessionOptions()
        options.intra_op_num_threads=4
        options.inter_op_num_threads=1
        runtime=ort.InferenceSession(str(directory/'model.onnx'),sess_options=options,providers=['CPUExecutionProvider'])
        arrays=tokenizer.batch([request])
        names={i.name for i in runtime.get_inputs()}
        feed={k:(v.astype(np.int64) if np.issubdtype(v.dtype,np.integer) else v) for k,v in arrays.items() if k in names}
        logits=runtime.run(None,feed)[0]
    else:
        raise ValueError('unsupported backend')
    probs = probabilities(logits, manifest['temperature'])[0]
    return dict(schemaVersion=1, modelVersion=manifest['modelVersion'],
                candidates=[dict(index=i,logit=float(logits[0,i]),probability=float(probs[i])) for i in range(len(request['candidates']))],
                noneLogit=float(logits[0,24]), noneProbability=float(probs[24]))


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model',type=Path,required=True)
    p.add_argument('--input',type=Path,required=True)
    p.add_argument('--backend',choices=['pytorch','onnx'],default='pytorch')
    a=p.parse_args()
    print(json.dumps(inference(a.model,read_json(a.input),a.backend),ensure_ascii=True,allow_nan=False))
