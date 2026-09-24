"""Sequential reproducible GPU experiments; select on validation, audit test once."""
from __future__ import annotations

import argparse
import copy
import json
import subprocess
import sys
from pathlib import Path

import yaml

from common import ROOT, digest, read_json, write_json


def run(*args):
    subprocess.run([sys.executable,*map(str,args)],cwd=ROOT,check=True)


def experiments(config_path,output,lm,export_artifact):
    base=yaml.safe_load(config_path.read_text(encoding='utf-8'))
    data=Path(base['data']['directory'])
    output.mkdir(parents=True,exist_ok=True)
    variants=[('shared-all',False,'all'),('separate-all',True,'all'),('shared-text',False,'text'),
              ('shared-source-kind',False,'source_kind'),('shared-frequency',False,'frequency'),('shared-affinity',False,'affinity')]
    summaries=[]
    for name,separate,metadata in variants:
        config=copy.deepcopy(base)
        config['modelVersion']='gyaim-decision-'+name+'-v1'
        config['model']['separate_encoder']=separate
        config['model']['metadata']=metadata
        path=output/(name+'.yaml')
        if path.exists() and yaml.safe_load(path.read_text(encoding='utf-8'))!=config:
            raise ValueError('existing experiment config changed; choose a new output directory')
        path.write_text(yaml.safe_dump(config,sort_keys=False),encoding='utf-8')
        directory=output/name
        final=directory/'final'
        if not final.exists():
            checkpoints=sorted((directory/'checkpoints').glob('step-*/state.pt'),key=lambda p:int(p.parent.name.split('-')[1]))
            if checkpoints:
                run('train.py','--resume',checkpoints[-1].parent)
            else:
                run('train.py','--config',path,'--run',directory)
        if not (final/'calibration.json').exists():
            run('calibrate.py','--model',final,'--data',data/'calibration.jsonl','--device',base['training']['device'])
        evaluation=directory/'eval/validation'
        if not (evaluation/'evaluation.json').exists():
            run('evaluate.py','--model',final,'--data',data/'validation.jsonl','--output',evaluation,'--device',base['training']['device'])
        report=read_json(evaluation/'evaluation.json')
        info=read_json(final/'metadata.json')
        summary=dict(name=name,model=str(final),params=info['parameterCount'],top1=report['ranking'].get('top1'),
                     mrr=report['ranking'].get('mrr'),homophone=report['homophone'].get('top1'),ece=report['calibration']['ece'],
                     noneF1=report['none']['f1'],netBenefit=report['relative']['netBenefit'])
        # Measure each architecture, not just the final winner.
        if not (directory/'benchmark.json').exists():
            run('measure.py','--model',final,'--output',directory/'benchmark.json')
        measured=read_json(directory/'benchmark.json')
        summary['latency']=measured
        summary['fp32Bytes']=(final/'model.pt').stat().st_size
        summaries.append(summary)
        write_json(output/'comparison.json',summaries)
    selected=max(summaries,key=lambda s:(s['mrr']+.25*s['noneF1'],-s['params']))
    write_json(output/'selection.json',dict(selected=selected['name'],criterion='validation MRR + 0.25 NONE F1; smaller model breaks ties',
               datasetHash=digest(data/'validation.jsonl'),testUsedForSelection=False))
    final=Path(selected['model'])
    for split in ['test','regression']:
        evaluation=output/selected['name']/'eval'/split
        if not (evaluation/'evaluation.json').exists():
            run('evaluate.py','--model',final,'--data',data/f'{split}.jsonl','--output',evaluation,
                '--device',base['training']['device'],'--lm',lm)
    lines=['# Decision model experiments','','Selection uses validation only. All models train from scratch on identical public splits.',
           'Frequency and affinity are missing in public data; those ablations do not establish personalization quality.','',
           '| Model | Params | Top1 | MRR | Homophone | ECE | NONE F1 | Net benefit | CPU p50 ms | FP32 MB |',
           '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
    for s in summaries:
        lines.append(f"| {s['name']} | {s['params']} | {s['top1']:.4f} | {s['mrr']:.4f} | {s['homophone'] or 0:.4f} | {s['ece']:.4f} | {s['noneF1']:.4f} | {s['netBenefit']} | {s['latency']['cpu24']['p50']:.2f} | {s['fp32Bytes']/1e6:.2f} |")
    lines+=['',f"Selected: {selected['name']}. See test/regression reports for final audits."]
    (output/'COMPARISON.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    if export_artifact:
        run('export.py','--model',final,'--output',export_artifact,'--validation',data/'validation.jsonl',
            '--evaluation',output/selected['name']/'eval/test')
    print(json.dumps(selected,ensure_ascii=True),flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config',type=Path,default=ROOT/'configs/small-a.yaml')
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--lm',type=Path,default=ROOT.parent/'model-training/runs/zenz-v2.5-full/final')
    p.add_argument('--artifact',type=Path)
    a=p.parse_args()
    experiments(a.config,a.output,a.lm,a.artifact)
