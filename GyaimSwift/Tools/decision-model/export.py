"""Versioned reference artifact, ONNX parity, quantization and latency measurements."""
from __future__ import annotations

import argparse
import copy
import shutil
import time
import uuid
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import torch
from onnxruntime.quantization import quantize_dynamic, QuantType

from common import ROOT, REPO, SOURCES, KINDS, candidate, digest, private_output, read_json, rows, write_json
from metrics import summarize
from tokenizer import INPUT_NAMES
from train import encode_records, load_model, predict, tensor_batch


def resolve_weight_aliases(source, destination):
    """Expose shared constant weights to ORT's dynamic quantizer."""
    graph = onnx.load(str(source))
    constants = {value.name for value in graph.graph.initializer}
    outputs = {value.name for value in graph.graph.output}
    aliases = {}
    retained = []
    for node in graph.graph.node:
        for index, name in enumerate(node.input):
            node.input[index] = aliases.get(name, name)
        if node.op_type == 'Identity' and node.input[0] in constants and node.output[0] not in outputs:
            aliases[node.output[0]] = node.input[0]
        else:
            retained.append(node)
    del graph.graph.node[:]
    graph.graph.node.extend(retained)
    onnx.checker.check_model(graph)
    onnx.save(graph, str(destination))


def request(count):
    # Public deterministic benchmark payload; stable shape and UTF-8 coverage.
    return dict(schemaVersion=1, context='このモデルの変換候補を', readingRoman='kinou', readingHiragana='きのう',
                candidates=[candidate(['機能','昨日','きのう','帰納'][i%4]+str(i//4), 'kinou', 'connection', 'exact', i) for i in range(count)])


def session(path):
    options = ort.SessionOptions()
    options.intra_op_num_threads=4
    options.inter_op_num_threads=1
    return ort.InferenceSession(str(path),sess_options=options,providers=['CPUExecutionProvider'])


def ort_inputs(arrays, inputs=None):
    keys = {i.name for i in inputs} if inputs else set(INPUT_NAMES)
    return {k: v.astype(np.int64) if k in ('state_ids','candidate_ids','state_segments','candidate_segments','categories') else v
            for k,v in arrays.items() if k in keys}


def onnx_export(model, tokenizer, path):
    arrays = tokenizer.batch([request(3)])
    tensors = tensor_batch(arrays,slice(None),'cpu')
    # Fixed 24 candidate slots, dynamic batch only. Legacy exporter explicitly pinned
    # to avoid ROCm Windows torch.export compatibility differences; parity is mandatory.
    torch.onnx.export(model, tuple(tensors[k] for k in INPUT_NAMES), str(path), input_names=INPUT_NAMES,
                      output_names=['logits'], opset_version=17, dynamo=False,
                      dynamic_axes={k:{0:'batch'} for k in INPUT_NAMES+['logits']})
    onnx.checker.check_model(str(path))
    runtime = session(path)
    reports=[]
    for count in [1,3,8,24]:
        for batch_size in [1,2]:
            arrays=tokenizer.batch([request(count)]*batch_size)
            expected=predict(model,arrays,'cpu',batch_size)
            actual=runtime.run(None,ort_inputs(arrays,runtime.get_inputs()))[0]
            np.testing.assert_allclose(actual,expected,atol=2e-4,rtol=2e-4)
            if not np.array_equal(actual.argmax(1),expected.argmax(1)):
                raise AssertionError('ONNX candidate/NONE argmax mismatch')
            reports.append(dict(candidates=count,batch=batch_size,maxAbsError=float(np.max(np.abs(actual-expected)))))
    return reports


def time_call(fn, iterations=30, synchronize=None):
    for _ in range(5):
        fn()
    if synchronize:
        synchronize()
    timings=[]
    for _ in range(iterations):
        start=time.perf_counter()
        fn()
        if synchronize:
            synchronize()
        timings.append((time.perf_counter()-start)*1000)
    return dict(p50=float(np.percentile(timings,50)),p95=float(np.percentile(timings,95)),mean=float(np.mean(timings)),iterations=iterations)


def benchmark(model,tokenizer,onnx_path):
    report=dict(cpuThreads=4,units='milliseconds',batch=1,paddingSlots=24,measurements=[])
    runtime=session(onnx_path)
    model.eval()
    with torch.inference_mode():
        for count in [3,8,24]:
            arrays=tokenizer.batch([request(count)])
            tensors=tensor_batch(arrays,slice(None),'cpu')
            report['measurements'].append(dict(backend='pytorch-cpu',candidates=count,**time_call(lambda:model(**tensors))))
            feed=ort_inputs(arrays,runtime.get_inputs())
            report['measurements'].append(dict(backend='onnx-cpu',candidates=count,**time_call(lambda:runtime.run(None,feed))))
            report['measurements'].append(dict(backend='tokenizer-cpu',candidates=count,**time_call(lambda:tokenizer.batch([request(count)]))))
        if torch.cuda.is_available():
            model=model.to('cuda')
            for count in [3,8,24]:
                tensors=tensor_batch(tokenizer.batch([request(count)]),slice(None),'cuda')
                report['measurements'].append(dict(backend='pytorch-gpu-fp32',candidates=count,
                    **time_call(lambda:model(**tensors),synchronize=torch.cuda.synchronize)))
            model.cpu()
    return report


def _export(model_dir, output, dataset, evaluation_dir, personalized=False):
    if output.exists():
        raise ValueError('artifact output already exists')
    meta=read_json(model_dir/'metadata.json')
    if meta['provenance']['privacy']=='private':
        if not personalized:
            raise ValueError('public export rejects private models')
        private_output(output)
    if not meta.get('completed'):
        raise ValueError('cannot export incomplete or benchmark run')
    calibration=read_json(model_dir/'calibration.json')
    if calibration['modelHash']!=digest(model_dir/'model.pt'):
        raise ValueError('stale calibration: model hash differs')
    evaluation=read_json(evaluation_dir/'evaluation.json')
    if meta['provenance']['privacy']=='public' and evaluation.get('privacy')=='private':
        raise ValueError('cannot bundle a private evaluation in a public artifact')
    if evaluation.get('modelHash')!=digest(model_dir/'model.pt'):
        raise ValueError('evaluation report belongs to a different model')
    if evaluation.get('temperature')!=calibration['temperature']:
        raise ValueError('evaluation did not use the exported calibration')
    dataset_manifest=read_json(dataset.parent/'manifest.json')
    if digest(dataset.parent/'manifest.json')!=meta['provenance']['datasetManifestHash']:
        raise ValueError('quantization validation provenance differs from training')
    if digest(dataset)!=dataset_manifest['files']['validation']:
        raise ValueError('quantization choices must use validation split')
    if meta['provenance']['privacy']=='public' and dataset_manifest['privacy']!='public':
        raise ValueError('cannot export private validation into public artifact')
    model,config,tokenizer=load_model(model_dir)
    torch.set_num_threads(4)
    output.mkdir(parents=True)
    reference=output/'reference'
    reference.mkdir()
    for name in ['model.py','tokenizer.py','common.py','metrics.py','train.py','indexed_data.py','infer.py','requirements.txt']:
        shutil.copyfile(ROOT/name,reference/name)
    for name in ['model.pt','tokenizer.json','config.yaml','metadata.json','calibration.json']:
        shutil.copyfile(model_dir/name,output/name)
    tokenizer_dir=Path(config['data']['tokenizer']).parent
    for name in ['tokenizer-spec.json','tokenizer-vectors.json']:
        shutil.copyfile(tokenizer_dir/name,output/name)
    shutil.copyfile(ROOT/'schema.json',output/'schema.json')
    write_json(output/'metadata-spec.json',dict(schemaVersion=1,sourceIds=SOURCES,kindIds=KINDS,
        categoricalColumns=['source','kind'],numericColumns=['rank','frequency','affinity','exact','hasRank','hasFrequency','hasAffinity','hasExact'],
        normalization=['min(originalRank,23)/23','min(log1p(studyFrequency),10)/10','contextAffinity','float(exactReadingMatch)'],
        missing='numeric value=0 and its hasX flag=0; unknown categorical ID=0',
        candidateMask='true for supplied candidates, false for padding; NONE slot24 is always valid'))
    for name in ['LICENSE','THIRD_PARTY_NOTICES.md']:
        shutil.copyfile(REPO/name,output/name)
    shutil.copyfile(dataset.parent/'manifest.json',output/'dataset-manifest.json')
    if (model_dir.parent/'training-benchmark.json').exists():
        shutil.copyfile(model_dir.parent/'training-benchmark.json',output/'training-benchmark.json')
    regression_path=evaluation_dir.parent/'regression/evaluation.json'
    regression=None
    if regression_path.exists():
        regression=read_json(regression_path)
        if meta['provenance']['privacy']=='public' and regression.get('privacy')=='private':
            raise ValueError('cannot bundle private regression evaluation in public artifact')
        if regression.get('modelHash')!=digest(model_dir/'model.pt'):
            raise ValueError('regression report belongs to another model')
        shutil.copyfile(regression_path,output/'regression-evaluation.json')
    for name in ['comparison.json','selection.json','COMPARISON.md']:
        comparison=model_dir.parent.parent/name
        if comparison.exists():
            shutil.copyfile(comparison,output/name)
    parity=onnx_export(model,tokenizer,output/'model.onnx')
    write_json(output/'export-parity.json',parity)
    shutil.copyfile(evaluation_dir/'evaluation.json',output/'evaluation.json')
    evaluation=read_json(output/'evaluation.json')
    latency=benchmark(model,tokenizer,output/'model.onnx')
    write_json(output/'benchmark.json',latency)
    # Dynamic INT8 keeps attention/embeddings in FP32. This is measured, not called
    # a fully INT8 model. Export actual size and validation impact explicitly.
    quant_source = output/'quantization-source.onnx'
    resolve_weight_aliases(output/'model.onnx', quant_source)
    quantize_dynamic(str(quant_source),str(output/'model-int8.onnx'),weight_type=QuantType.QInt8,
                     op_types_to_quantize=['MatMul','Gemm'],extra_options={'MatMulConstBOnly':True})
    quant_source.unlink()
    records=list(rows(dataset))
    arrays=encode_records(records,tokenizer)
    reference_device='cuda' if torch.cuda.is_available() else 'cpu'
    model.to(reference_device)
    reference=predict(model,arrays,reference_device)
    model.cpu()
    quant_runtime=session(output/'model-int8.onnx')
    q=[]
    for start in range(0,len(records),32):
        feed=ort_inputs({k:v[start:start+32] for k,v in arrays.items()},quant_runtime.get_inputs())
        q.append(quant_runtime.run(None,feed)[0])
    quantized=np.concatenate(q)
    r,_=summarize(reference,records,calibration['temperature'])
    qr,_=summarize(quantized,records,calibration['temperature'])
    # FP16 weights as an additional PyTorch storage format; runtime precision uses
    # FP16 on GPU and is separately evaluated below.
    torch.save({k:v.half() if v.is_floating_point() else v for k,v in model.state_dict().items()},output/'model-fp16.pt')
    quant_report=dict(validationHash=digest(dataset),fp32=r,int8=qr,
                      referenceDevice=reference_device,
                      top1Delta=qr['ranking'].get('top1',0)-r['ranking'].get('top1',0),
                      eceDelta=qr['calibration']['ece']-r['calibration']['ece'],
                      argmaxAgreement=float((quantized.argmax(1)==reference.argmax(1)).mean()),
                      int8Scope='dynamic linear weights; embeddings/attention stay FP32')
    quant_report['latencyInt8']=[]
    for count in [3,8,24]:
        feed=ort_inputs(tokenizer.batch([request(count)]),quant_runtime.get_inputs())
        quant_report['latencyInt8'].append(dict(candidates=count,**time_call(lambda:quant_runtime.run(None,feed))))
    if torch.cuda.is_available():
        half_model=copy.deepcopy(model).to('cuda').half().eval()
        hp=[]
        with torch.inference_mode():
            for start in range(0,len(records),32):
                batch=tensor_batch(arrays,slice(start,start+32),'cuda')
                batch['numeric']=batch['numeric'].half()
                hp.append(half_model(**batch).float().cpu().numpy())
        hr,_=summarize(np.concatenate(hp),records,calibration['temperature'])
        quant_report['fp16']=hr
        quant_report['fp16Top1Delta']=hr['ranking'].get('top1',0)-r['ranking'].get('top1',0)
        quant_report['fp16EceDelta']=hr['calibration']['ece']-r['calibration']['ece']
        quant_report['latencyFp16']=[]
        with torch.inference_mode():
            for candidates in [3,8,24]:
                batch=tensor_batch(tokenizer.batch([request(candidates)]),slice(None),'cuda')
                batch['numeric']=batch['numeric'].half()
                quant_report['latencyFp16'].append(dict(candidates=candidates,
                    **time_call(lambda:half_model(**batch),synchronize=torch.cuda.synchronize)))
        del half_model
    write_json(output/'quantization.json',quant_report)
    count=sum(p.numel() for p in model.parameters())
    sizes={name:(output/name).stat().st_size for name in ['model.pt','model-fp16.pt','model.onnx','model-int8.onnx']}
    lm=evaluation.get('gyaimLM')
    gates=dict(positiveNetBenefit=evaluation['relative']['netBenefit']>0,
               competitiveWithLM=bool(lm and evaluation['ranking'].get('top1',0)>=lm['ranking'].get('top1',0)),
               homophoneNonRegression=bool(lm and evaluation['homophone'].get('top1',0)>=lm['homophone'].get('top1',0)-.02),
               parameterTarget=count<=10_000_000,fp16SizeTarget=sizes['model-fp16.pt']<=25_000_000,
               int8SizeTarget=sizes['model-int8.onnx']<=12_000_000)
    if regression:
        regression_lm=regression.get('gyaimLM')
        gates['regressionNetBenefit']=regression['relative']['netBenefit']>=0
        gates['regressionHomophoneNonRegression']=bool(regression_lm and
            regression['homophone'].get('top1',0)>=regression_lm['homophone'].get('top1',0)-.02)
    else:
        gates['regressionAuditAvailable']=False
    status='research-not-approved'  # A single synthetic public test cannot approve production.
    manifest=dict(schemaVersion=1,metadataSchemaVersion=1,modelVersion=config['modelVersion'],
                   architecture='bidirectional-text-encoder-and-set-attention',parameterCount=count,
                   tokenizerVersion='gyaim-char-scalar-v1',tokenizerHash=digest(output/'tokenizer.json'),
                   maxCandidates=24,maxContextTokens=config['data']['max_context_tokens'],maxCandidateTokens=config['data']['max_candidate_tokens'],
                   temperature=calibration['temperature'],noneIndex=24,maskedLogit=-10000,
                   privacy=meta['provenance']['privacy'],releaseStatus=status,qualityGates=gates,sizes=sizes,
                   files={p.relative_to(output).as_posix():digest(p) for p in output.rglob('*') if p.is_file()})
    write_json(output/'manifest.json',manifest)
    card=f'''# {config['modelVersion']}

Status: **{status}**. This artifact is reproducible research, not an approved IME replacement.

- Purpose: rank 1–24 supplied candidates and detect NONE; no generation.
- Architecture: bidirectional text encoder(s), metadata and set attention; {count:,} parameters.
- Training: public zenz dictionary-competitive subset; provenance and hashes in metadata.json.
- Licensing: zenz Wikipedia CC-BY-SA-4.0; llm-jp component ODC-BY (upstream terms apply).
  Tokenizer from ku-nlp/gpt2-small-japanese-char (CC-BY-SA-4.0). Dictionary retains repository notices.
- Private data usage: {meta['provenance']['privacy']}; public training excludes domain/dogfood files.
- Tokenizer: NFC, ASCII space to ideographic space, scalar tokenization; see tokenizer-spec.json.
- Evaluation: evaluation.json; candidate-only ranking is separate from NONE decision accuracy.
- Calibration: independent split, temperature {calibration['temperature']:.6f}; calibration.json.
- Latency: benchmark.json, batch 1 at 3/8/24 candidates, fixed 24 padded slots.
- Size/quantization: manifest.json and quantization.json contain actual measurements.
- Limitations: synthetic candidate sets, bounded corpus-prefix sampling, incomplete dictionary
  graph reproduction, no actual private preference supervision, Windows is not macOS timing.
- Integration: validate schemas/hashes, mask padding, apply stored temperature, retain NONE.
  Threshold and UI behavior need independent macOS integration and production validation.
  Do not promote this artifact automatically on synthetic accuracy alone.
- Core ML: not validated on Windows; ONNX FP32 and PyTorch reference supplied for conversion.

Quality gates: {gates}
'''
    (output/'MODEL_CARD.md').write_text(card,encoding='utf-8')
    manifest['files']['MODEL_CARD.md']=digest(output/'MODEL_CARD.md')
    write_json(output/'manifest.json',manifest)
    print({'artifact':str(output),'parameterCount':count,'qualityGates':gates})
    return manifest


def export(model_dir,output,dataset,evaluation_dir,personalized=False):
    """Publish a complete local directory only after all checks succeed."""
    if output.exists():
        raise ValueError('artifact output already exists')
    staging=output.with_name(output.name+'-building-'+uuid.uuid4().hex[:8])
    result=_export(model_dir,staging,dataset,evaluation_dir,personalized)
    staging.rename(output)
    print({'completedArtifact':str(output)},flush=True)
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--validation',type=Path,required=True)
    p.add_argument('--evaluation',type=Path,required=True)
    p.add_argument('--personalized',action='store_true')
    a=p.parse_args()
    export(a.model,a.output,a.validation,a.evaluation,a.personalized)
