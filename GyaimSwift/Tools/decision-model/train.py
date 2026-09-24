"""Native CUDA/HIP training with exact next-batch resume and provenance checks."""
from __future__ import annotations

import argparse
import copy
import datetime
import json
import math
import random
import shutil
import subprocess
import signal
import time
from pathlib import Path

import numpy as np
import torch
import yaml

from common import ROOT, digest, private_output, read_json, rows, write_json
from metrics import summarize
from model import DecisionModel, loss
from tokenizer import Tokenizer, INPUT_NAMES
from indexed_data import IndexedJSONL


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def device_info(config):
    device = config['training']['device']
    precision = config['training']['precision']
    if device == 'cuda' and not torch.cuda.is_available():
        raise RuntimeError('GPU requested but unavailable; CPU fallback is not silent')
    if precision != 'fp32' and device != 'cuda':
        raise ValueError('mixed precision requires GPU')
    if precision == 'bf16' and not torch.cuda.is_bf16_supported():
        raise ValueError('BF16 unsupported by this device')
    if precision not in ('fp32', 'fp16', 'bf16'):
        raise ValueError('invalid precision')
    info = dict(device=device, torch=torch.__version__, cuda=torch.version.cuda, hip=torch.version.hip, precision=precision)
    if device == 'cuda':
        info.update(name=torch.cuda.get_device_name(), vramBytes=torch.cuda.get_device_properties(0).total_memory)
        probe = torch.randn(16, 16, device=device)
        probe @ probe
        torch.cuda.synchronize()
    return info


def tensor_batch(arrays, indices, device):
    return {k: torch.as_tensor(v[indices], device=device, dtype=torch.long if k in
            ('state_ids', 'candidate_ids', 'state_segments', 'candidate_segments', 'categories') else None)
            for k, v in arrays.items()}


def encode_records(records, tokenizer):
    # Chunked allocation limits tokenizer temporary objects; cache is local to run.
    if not records:
        raise ValueError('empty split')
    first = tokenizer.batch(records[:128])
    result = {k: np.empty((len(records), *v.shape[1:]), dtype=v.dtype) for k, v in first.items()}
    for start in range(0, len(records), 128):
        chunk = first if start == 0 else tokenizer.batch(records[start:start+128])
        for k in result:
            result[k][start:start+len(chunk[k])] = chunk[k]
    return result


@torch.inference_mode()
def predict(model, arrays, device, batch_size=32):
    model.eval()
    outputs = []
    for start in range(0, len(arrays['state_ids']), batch_size):
        batch = tensor_batch(arrays, slice(start, start+batch_size), device)
        outputs.append(model(**batch).float().cpu().numpy())
    return np.concatenate(outputs)


def load_model(directory, device='cpu'):
    directory = Path(directory)
    config = yaml.safe_load((directory / 'config.yaml').read_text(encoding='utf-8'))
    model = DecisionModel(config)
    model.load_state_dict(torch.load(directory / 'model.pt', map_location='cpu', weights_only=True))
    return model.to(device).eval(), config, Tokenizer(directory / 'tokenizer.json', config['data'])


def save_checkpoint(run, model, optimizer, scheduler, scaler, config, epoch, offset, step, best, provenance):
    directory = run / 'checkpoints' / f'step-{step}'
    directory.mkdir(parents=True, exist_ok=True)
    payload = dict(model=model.state_dict(), optimizer=optimizer.state_dict(), scheduler=scheduler.state_dict(),
                   scaler=scaler.state_dict(), epoch=epoch, offset=offset, step=step, best=best, config=config,
                   python_rng=random.getstate(), numpy_rng=np.random.get_state(), torch_rng=torch.get_rng_state(),
                   gpu_rng=torch.cuda.get_rng_state_all() if torch.cuda.is_available() else None, provenance=provenance)
    # Keep the selected weights as well as the current training weights. Otherwise
    # a copied checkpoint cannot recover an earlier validation winner without run/best.pt.
    payload['best_model'] = torch.load(run/'best.pt',map_location='cpu',weights_only=True) if (run/'best.pt').exists() else None
    torch.save(payload, directory / 'state.tmp')
    (directory / 'state.tmp').replace(directory / 'state.pt')
    shutil.copyfile(run / 'tokenizer.json', directory / 'tokenizer.json')
    write_json(directory / 'resume.json', dict(run=str(run.resolve()), step=step, trustedLocalCheckpoint=True))
    return directory


def train(config, run, resume=None, benchmark=False, stop_after=None):
    config = copy.deepcopy(config)
    t = config['training']
    torch.set_num_threads(t.get('cpu_threads', 4))
    random.seed(config['seed'])
    np.random.seed(config['seed'])
    torch.manual_seed(config['seed'])
    info = device_info(config)
    print(json.dumps(info), flush=True)
    data = Path(config['data']['directory']).resolve()
    config['data']['directory']=str(data)
    manifest = read_json(data / 'manifest.json')
    if manifest['privacy'] not in ('public','private'):
        raise ValueError('dataset privacy must be public or private')
    if manifest['privacy'] == 'private':
        private_output(run)
    paths = {s: data / f'{s}.jsonl' for s in ['train', 'validation']}
    hashes = {s: digest(p) for s, p in paths.items()}
    for s, h in hashes.items():
        if manifest['files'][s] != h:
            raise ValueError('dataset hash differs from manifest')
    configured_tokenizer = Path(config['data']['tokenizer']).resolve()
    config['data']['tokenizer']=str(configured_tokenizer)
    tokenizer_path = configured_tokenizer if configured_tokenizer.exists() or not resume else resume/'tokenizer.json'
    provenance = dict(datasetManifestHash=digest(data / 'manifest.json'), files=hashes, tokenizerHash=digest(tokenizer_path),
                      privacy=manifest['privacy'], datasetVersion=manifest['version'])
    if run.exists() and not resume:
        raise ValueError('run already exists: resume or choose new run')
    run.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(tokenizer_path, run / 'tokenizer.json')
    tokenizer = Tokenizer(run / 'tokenizer.json', config['data'])
    if tokenizer.backend.get_vocab_size() != config['model']['vocab_size']:
        raise ValueError('vocabulary size mismatch')
    indexed=config['data'].get('cache_mode','memory')=='indexed'
    records = {s:(IndexedJSONL(p,run/'train.offsets',manifest['privacy']) if s=='train' and indexed else list(rows(p))) for s,p in paths.items()}
    from common import validate
    for split in records.values():
        if isinstance(split,IndexedJSONL):
            continue
        for record in split:
            validate(record,True)
            if manifest['privacy']=='public' and (record.get('privacy')=='private' or record.get('origin')=='dogfood'):
                raise ValueError('private record in public training manifest')
    encoded = {}
    for s in records:
        if s=='train' and indexed:
            continue
        cache = run / f'{s}-encoded.npz'
        if resume and cache.exists():
            with np.load(cache) as z:
                encoded[s] = {k: z[k] for k in z.files}
        else:
            print(f'encoding {s}: {len(records[s])}', flush=True)
            encoded[s] = encode_records(records[s], tokenizer)
            np.savez(cache, **encoded[s])
    model = DecisionModel(config).to(t['device'])
    parameter_count = sum(p.numel() for p in model.parameters())
    if parameter_count > 10_000_000:
        raise ValueError('production config exceeds 10M parameters')
    optimizer = torch.optim.AdamW(model.parameters(), lr=t['learning_rate'], weight_decay=t['weight_decay'])
    total_steps = math.ceil(len(records['train']) / t['batch_size']) * t['epochs']
    scheduler = torch.optim.lr_scheduler.LambdaLR(optimizer, lambda step: min(1., (step+1)/100) * .5 * (1+math.cos(math.pi*min(step,total_steps)/total_steps)))
    scaler = torch.amp.GradScaler('cuda', init_scale=1024., enabled=t['precision']=='fp16')
    epoch = offset = step = 0
    best = -1.
    if resume:
        # Only load checkpoints produced locally by this script (contains Python RNG state).
        saved = torch.load(resume / 'state.pt', map_location='cpu', weights_only=False)
        if saved['provenance'] != provenance or saved['config'] != config:
            raise ValueError('resume config/data/tokenizer mismatch')
        model.load_state_dict(saved['model'])
        if saved.get('best_model') is not None:
            torch.save(saved['best_model'],run/'best.pt')
        elif saved['best'] >= 0 and not (run/'best.pt').exists():
            raise ValueError('legacy checkpoint needs its original best.pt; selected weights are missing')
        optimizer.load_state_dict(saved['optimizer'])
        scheduler.load_state_dict(saved['scheduler'])
        scaler.load_state_dict(saved['scaler'])
        epoch, offset, step, best = [saved[k] for k in ['epoch', 'offset', 'step', 'best']]
        random.setstate(saved['python_rng'])
        np.random.set_state(saved['numpy_rng'])
        torch.set_rng_state(saved['torch_rng'])
        if saved['gpu_rng'] is not None:
            torch.cuda.set_rng_state_all(saved['gpu_rng'])
    (run / 'config.yaml').write_text(yaml.safe_dump(config, sort_keys=False), encoding='utf-8')
    metadata = dict(start=now(), parameterCount=parameter_count, environment=info, seed=config['seed'], provenance=provenance,
                    gitSHA=subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT, text=True).strip(),
                    gitDirty=bool(subprocess.check_output(['git','status','--porcelain'], cwd=ROOT, text=True).strip()),
                    resumedFrom=str(resume) if resume else None)
    metadata['sourceHashes']={p.name:digest(p) for p in ROOT.glob('*.py')}
    metadata['configHash']=digest(run/'config.yaml')
    from importlib.metadata import version
    metadata['dependencies']={p:version(p) for p in ['numpy','PyYAML','tokenizers','onnx','onnxruntime']}
    if resume and (run/'metadata.json').exists():
        previous=read_json(run/'metadata.json')
        metadata['start']=previous['start']
        metadata['resumeHistory']=previous.get('resumeHistory',[])+[dict(at=now(),step=step)]
    write_json(run / 'metadata.json', metadata)
    targets = None if indexed else np.array([24 if r['selected'] is None else r['selected'] for r in records['train']], np.int64)
    train_count=len(records['train'])
    started, processed, start_step = time.perf_counter(), 0, step
    step_times = []
    stopped = False
    stop_signal = [False]
    previous_handler = signal.signal(signal.SIGINT, lambda *_: stop_signal.__setitem__(0,True))
    for e in range(epoch, t['epochs']):
        order = np.random.default_rng(config['seed'] + e).permutation(train_count)
        for start in range(offset if e==epoch else 0, len(order), t['batch_size']):
            tick = time.perf_counter()
            indices = order[start:start+t['batch_size']]
            model.train()
            optimizer.zero_grad(set_to_none=True)
            if indexed:
                batch_records=records['train'].read(indices)
                batch=tensor_batch(tokenizer.batch(batch_records),slice(None),t['device'])
                batch_targets=np.array([24 if r['selected'] is None else r['selected'] for r in batch_records],np.int64)
            else:
                batch = tensor_batch(encoded['train'], indices, t['device'])
                batch_targets=targets[indices]
            with torch.autocast(device_type=t['device'], dtype=torch.float16 if t['precision']=='fp16' else torch.bfloat16, enabled=t['precision']!='fp32'):
                output = model(**batch)
                value = loss(output, torch.as_tensor(batch_targets, device=t['device']))
            if not torch.isfinite(value):
                raise RuntimeError('non-finite loss')
            scaler.scale(value).backward()
            scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(model.parameters(), t['grad_clip'], error_if_nonfinite=not scaler.is_enabled())
            old_scale=scaler.get_scale()
            scaler.step(optimizer)
            scaler.update()
            if scaler.get_scale()>=old_scale:
                scheduler.step()
            step += 1
            processed += len(indices)
            if t['device']=='cuda':
                torch.cuda.synchronize()
            step_times.append(time.perf_counter()-tick)
            next_epoch, next_offset = (e+1, 0) if start+t['batch_size'] >= len(order) else (e, start+t['batch_size'])
            if step % 50 == 0:
                print(json.dumps(dict(step=step, total=total_steps, loss=float(value.detach()), examplesPerSec=processed/(time.perf_counter()-started))), flush=True)
            should_stop = stop_signal[0] or (run / 'STOP_REQUESTED').exists() or (stop_after is not None and step>=stop_after)
            end = next_epoch == t['epochs']
            if not benchmark and (step % t['validation_steps']==0 or end):
                scores = predict(model, encoded['validation'], t['device'], t['batch_size'])
                report, _ = summarize(scores, records['validation'])
                report['validationLoss']=report['calibration']['nll']
                selection = report['ranking'].get('mrr',0) + .25 * report['none']['f1']
                with (run / 'validation.jsonl').open('a', encoding='utf-8') as f:
                    f.write(json.dumps(dict(step=step, selectionScore=selection, report=report))+'\n')
                if selection > best:
                    best = selection
                    torch.save(model.state_dict(), run / 'best.pt')
            if step % t['checkpoint_steps']==0 or should_stop or end:
                cp = save_checkpoint(run, model, optimizer, scheduler, scaler, config, next_epoch, next_offset, step, best, provenance)
                print(f'checkpoint {cp.name}', flush=True)
            if should_stop or (benchmark and step-start_step>=t['benchmark_steps']):
                stopped = True
                break
        if stopped:
            break
    elapsed = time.perf_counter()-started
    signal.signal(signal.SIGINT,previous_handler)
    benchmark_report = dict(steps=step-start_step, examples=processed, elapsedSeconds=elapsed,
                            examplesPerSecond=processed/max(elapsed,1e-9), stepMeanMs=float(np.mean(step_times)*1000) if step_times else None,
                            estimatedFullTrainingSeconds=total_steps*float(np.mean(step_times)) if step_times else None,
                            peakGpuBytes=torch.cuda.max_memory_allocated() if t['device']=='cuda' else None)
    write_json(run / 'training-benchmark.json', benchmark_report)
    metadata.update(end=now(), step=step, completed=not stopped, benchmark=benchmark)
    write_json(run / 'metadata.json', metadata)
    if not stopped:
        final = run / 'final'
        final.mkdir(exist_ok=True)
        shutil.copyfile(run / 'best.pt', final / 'model.pt')
        for name in ['config.yaml', 'tokenizer.json', 'metadata.json']:
            shutil.copyfile(run / name, final / name)
    print(json.dumps(benchmark_report), flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config', type=Path)
    p.add_argument('--run', type=Path)
    p.add_argument('--resume', type=Path)
    p.add_argument('--benchmark', action='store_true')
    p.add_argument('--stop-after', type=int)
    args = p.parse_args()
    if args.resume:
        saved = torch.load(args.resume / 'state.pt', map_location='cpu', weights_only=False)
        config = saved['config']
        run = Path(read_json(args.resume / 'resume.json')['run'])
    else:
        if not args.config or not args.run:
            p.error('--config and --run required unless --resume')
        config = yaml.safe_load(args.config.read_text(encoding='utf-8'))
        run = args.run
    train(config, run, args.resume, args.benchmark, args.stop_after)


if __name__ == '__main__':
    main()
