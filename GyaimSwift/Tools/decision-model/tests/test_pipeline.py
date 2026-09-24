import copy
import json
import sys
from pathlib import Path

import numpy as np
import pytest
import torch
import yaml
from tokenizers import Tokenizer as Backend, models, pre_tokenizers

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from build_dataset import Reading, Miner, none_variant, split_for
from calibrate import fit_temperature
from common import ROOT, candidate, digest, normalize, validate, write_json
from export import onnx_export, request, resolve_weight_aliases
from metrics import probabilities, summarize
from model import DecisionModel, loss
from tokenizer import Tokenizer
from train import train, load_model, tensor_batch


def test_shared_weight_alias_quantization(tmp_path):
    import onnx
    import onnxruntime as ort
    from onnx import helper, numpy_helper, TensorProto
    from onnxruntime.quantization import quantize_dynamic, QuantType
    weights = np.eye(64, dtype=np.float32)
    graph = helper.make_graph([
        helper.make_node('Identity', ['weight'], ['alias']),
        helper.make_node('MatMul', ['x', 'weight'], ['a']),
        helper.make_node('MatMul', ['x', 'alias'], ['b']),
        helper.make_node('Add', ['a', 'b'], ['y']),
    ], 'shared', [helper.make_tensor_value_info('x', TensorProto.FLOAT, [1, 64])],
        [helper.make_tensor_value_info('y', TensorProto.FLOAT, [1, 64])],
        [numpy_helper.from_array(weights, 'weight')])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 17)])
    model.ir_version = 9
    source, prepared, quantized = [tmp_path/name for name in ['original.onnx', 'prepared.onnx', 'int8.onnx']]
    onnx.save(model, source)
    resolve_weight_aliases(source, prepared)
    quantize_dynamic(str(prepared), str(quantized), weight_type=QuantType.QInt8,
                     op_types_to_quantize=['MatMul'], extra_options={'MatMulConstBOnly': True})
    feed = {'x': np.ones((1, 64), dtype=np.float32)}
    for path in [prepared, quantized]:
        result = ort.InferenceSession(str(path), providers=['CPUExecutionProvider']).run(None, feed)[0]
        np.testing.assert_allclose(result, 2*feed['x'], atol=1e-5)
    assert quantized.stat().st_size < source.stat().st_size / 2


@pytest.fixture
def setup(tmp_path):
    torch.set_num_threads(2)
    vocab={'[UNK]':0,'[PAD]':1,'機':2,'能':3,'昨':4,'日':5,'き':6,'の':7,'う':8}
    tk=Backend(models.WordLevel(vocab,unk_token='[UNK]'))
    tk.pre_tokenizer=pre_tokenizers.WhitespaceSplit()
    path=tmp_path/'tokenizer.json'
    tk.save(str(path))
    config=dict(schemaVersion=1,modelVersion='test',seed=42,
        model=dict(hidden_size=16,layers=1,heads=2,vocab_size=len(vocab),dropout=0.,separate_encoder=False,metadata='all'),
        data=dict(max_context_tokens=12,max_candidate_tokens=8,segment_budgets=[4,4,4],max_candidates=24,tokenizer=str(path)),
        training=dict(batch_size=2,learning_rate=.001,weight_decay=0.,epochs=2,precision='fp32',device='cpu',checkpoint_steps=2,
                      validation_steps=2,benchmark_steps=2,grad_clip=1.,cpu_threads=2))
    return config,Tokenizer(path,config['data'])


def test_schema():
    validate(request(1))
    validate(request(24))
    with pytest.raises(ValueError):
        validate(request(25))
    bad=request(1);bad['candidates'][0]['studyFrequency']=-1
    with pytest.raises(ValueError):
        validate(bad)
    bad=request(1);bad['selected']=1
    with pytest.raises(ValueError):
        validate(bad,True)


def test_invalid_config(setup):
    from common import validate_config
    config,_=setup
    validate_config(config)
    config['data']['max_context_tokens']=2
    with pytest.raises(ValueError,match='budgets'):
        validate_config(config)


def test_none_and_grouping():
    row=dict(request(3),id='a',selected=1)
    n=none_variant(row)
    assert n['selected'] is None and len(n['candidates'])==2
    assert row['candidates'][1] not in n['candidates']
    assert none_variant(dict(request(1),id='b',selected=0)) is None
    assert split_for('同じ文脈','あ',42)==split_for('同じ文脈','い',42)
    assert split_for('','ア',42)==split_for('','あ',42)


def test_dictionary_hard_negatives(tmp_path):
    p=tmp_path/'dict.txt'
    p.write_text('kinou\t機能\t1\t2\nkinou\t昨日\t1\t2\nka\t*化\t1\t2\n',encoding='utf-8')
    reading=Reading()
    assert reading.kana('kinou')=='きのう'
    assert reading.kana('kitta')=='きった'
    cs=Miner(p,reading).generate('きのう')
    assert [c['text'] for c in cs][:2]==['機能','昨日']
    assert all(c['hardNegativeType']!='random' for c in cs)


@pytest.mark.parametrize('separate',[False,True])
def test_padding_permutation_loss(setup,separate):
    config,tk=setup
    config['model']['separate_encoder']=separate
    model=DecisionModel(config).eval()
    arrays=tk.batch([request(3)])
    batch=tensor_batch(arrays,slice(None),'cpu')
    original=model(**batch)
    assert original.shape==(1,25)
    assert torch.all(original[0,3:24]==-10000)
    altered={k:v.clone() for k,v in batch.items()}
    altered['candidate_ids'][:,3:]=4
    altered['categories'][:,3:]=1
    altered['numeric'][:,3:]=999
    torch.testing.assert_close(original,model(**altered))
    # Change masked text tokens inside valid candidates and state too.
    altered={k:v.clone() for k,v in batch.items()}
    altered['candidate_ids'][~altered['token_mask']]=3
    altered['state_ids'][~altered['state_mask']]=3
    torch.testing.assert_close(original,model(**altered))
    perm=[2,0,1]+list(range(3,24))
    altered={k:(v[:,perm] if k not in ['state_ids','state_segments','state_mask'] else v) for k,v in batch.items()}
    reordered=model(**altered)
    torch.testing.assert_close(reordered[:,:24],original[:,perm])
    torch.testing.assert_close(reordered[:,24],original[:,24])
    value=loss(original,torch.tensor([24]))
    value.backward()
    assert torch.isfinite(value)
    assert model.none.grad is not None


def test_tokenizer_determinism(setup):
    _,tk=setup
    assert tk.encode('機能')==tk.encode('機能')
    assert normalize('か\u3099 a')=='が\u3000a'
    assert 1 not in tk.encode('[PAD]')


def test_metrics_calibration():
    records=[dict(request(3),selected=1,candidateRecall=True),dict(request(1),selected=None,candidateRecall=False)]
    logits=np.full((2,25),-10000.)
    logits[0,:3]=[0,2,1];logits[0,24]=-1
    logits[1,0]=0;logits[1,24]=2
    report,_=summarize(logits,records)
    assert report['ranking']['top1']==1 and report['relative']['netBenefit']==1
    assert report['none']['f1']==1 and report['candidateRecallAt24']==.5
    # Overconfident wrong decision: fitting must reduce NLL.
    bad=logits.copy();bad[0,0]=8
    targets=np.array([1,24])
    t=fit_temperature(bad,targets)
    before=-np.log(probabilities(bad)[np.arange(2),targets]).mean()
    after=-np.log(probabilities(bad,t)[np.arange(2),targets]).mean()
    assert after<=before and t>1
    assert np.all(probabilities(logits,20)[:,3:24]==0)
    with pytest.raises(ValueError):
        probabilities(logits,0)


def test_onnx_parity(setup,tmp_path):
    config,tk=setup
    reports=onnx_export(DecisionModel(config).eval(),tk,tmp_path/'model.onnx')
    assert len(reports)==8


@pytest.mark.parametrize('cache_mode',['memory','indexed'])
def test_training_resume_exact(setup,tmp_path,cache_mode):
    config,tk=setup
    config['model']['dropout']=.1
    config['data']['cache_mode']=cache_mode
    data=tmp_path/'data';data.mkdir()
    records=[dict(request(3),id=str(i),selected=i%3) for i in range(6)]
    for s in ['train','validation']:
        (data/f'{s}.jsonl').write_text('\n'.join(json.dumps(r) for r in records)+'\n',encoding='utf-8')
    write_json(data/'manifest.json',dict(privacy='public',version='test',files={s:digest(data/f'{s}.jsonl') for s in ['train','validation']}))
    config['data']['directory']=str(data)
    train(config,tmp_path/'complete')
    train(config,tmp_path/'resumed',stop_after=2)
    cp=tmp_path/'resumed/checkpoints/step-2'
    # Checkpoint alone must preserve an earlier best, even if the original run is moved.
    import shutil
    copied=tmp_path/'copied-checkpoint'
    shutil.copytree(cp,copied)
    (tmp_path/'resumed').rename(tmp_path/'archived-run')
    cp=copied
    train(config,tmp_path/'resumed',resume=cp)
    a=torch.load(tmp_path/'complete/checkpoints/step-6/state.pt',weights_only=False)
    b=torch.load(tmp_path/'resumed/checkpoints/step-6/state.pt',weights_only=False)
    for k in a['model']:
        torch.testing.assert_close(a['model'][k],b['model'][k],rtol=0,atol=0)
    assert a['scheduler']==b['scheduler']
    (data/'train.jsonl').write_text('{}\n',encoding='utf-8')
    with pytest.raises(ValueError,match='hash'):
        train(config,tmp_path/'resumed',resume=cp)


def test_complete_artifact_and_reference_inference(setup,tmp_path,monkeypatch):
    from calibrate import calibrate
    from evaluate import evaluate
    import export as export_module
    from infer import inference
    config,tk=setup
    data=tmp_path/'data';data.mkdir()
    for s in ['train','validation','calibration','test']:
        records=[dict(request(3),id=s+str(i),selected=i%3,candidateRecall=True) for i in range(6)]
        (data/f'{s}.jsonl').write_text('\n'.join(json.dumps(r) for r in records)+'\n',encoding='utf-8')
    write_json(data/'manifest.json',dict(privacy='public',version='test',files={s:digest(data/f'{s}.jsonl') for s in ['train','validation','calibration','test']}))
    for name in ['tokenizer-spec.json','tokenizer-vectors.json']:
        write_json(tmp_path/name,{})
    config['data']['directory']=str(data)
    train(config,tmp_path/'run')
    final=tmp_path/'run/final'
    calibrate(final,data/'calibration.jsonl','cpu')
    evaluate(final,data/'test.jsonl',tmp_path/'evaluation')
    monkeypatch.setattr(export_module,'benchmark',lambda *a:{'test':True})
    monkeypatch.setattr(export_module,'time_call',lambda *a,**kw:{'test':True})
    # Keep this integration test CPU-only; separate real experiment covers GPU FP16.
    monkeypatch.setattr(torch.cuda,'is_available',lambda:False)
    manifest=export_module.export(final,tmp_path/'artifact',data/'validation.jsonl',tmp_path/'evaluation')
    assert manifest['maxCandidates']==24 and manifest['noneIndex']==24
    result=inference(tmp_path/'artifact',request(3))
    onnx_result=inference(tmp_path/'artifact',request(3),'onnx')
    assert onnx_result['noneProbability']==pytest.approx(result['noneProbability'],abs=2e-5)
    assert len(result['candidates'])==3
    assert sum(c['probability'] for c in result['candidates'])+result['noneProbability']==pytest.approx(1.)
    assert (tmp_path/'artifact/reference/model.py').exists()
    evaluation=json.loads((tmp_path/'evaluation/evaluation.json').read_text(encoding='utf-8'))
    evaluation['privacy']='private'
    write_json(tmp_path/'evaluation/evaluation.json',evaluation)
    with pytest.raises(ValueError,match='private evaluation'):
        export_module.export(final,tmp_path/'forbidden-artifact',data/'validation.jsonl',tmp_path/'evaluation')
    (tmp_path/'artifact/calibration.json').write_text('{}',encoding='utf-8')
    with pytest.raises(ValueError,match='checksum'):
        inference(tmp_path/'artifact',request(3))


def test_private_temporal_split(tmp_path,monkeypatch):
    import common
    from build_dataset import private
    from types import SimpleNamespace
    monkeypatch.setattr(common,'ROOT',tmp_path)
    input_path=tmp_path/'events.jsonl'
    records=[dict(request(2),id=str(i),selected=0,timestamp=f'2026-0{i+1}-15T00:00:00+09:00') for i in range(4)]
    input_path.write_text('\n'.join(json.dumps(r) for r in records)+'\n',encoding='utf-8')
    args=SimpleNamespace(output=tmp_path/'private/dataset',sources=[input_path],version='private-test',
                         boundaries=['2026-02-01T00:00:00+09:00','2026-03-01T00:00:00+09:00','2026-04-01T00:00:00+09:00'])
    private(args)
    for i,s in enumerate(['train','validation','calibration','test']):
        result=list(common.rows(args.output/f'{s}.jsonl'))
        assert [r['id'] for r in result]==[str(i)]
        assert result[0]['privacy']=='private'
    with pytest.raises(ValueError,match='private'):
        common.private_output(tmp_path/'public')


def test_dataset_builder_holdout_and_determinism(tmp_path):
    from types import SimpleNamespace
    from build_dataset import public
    from common import rows
    dictionary=tmp_path/'dict.txt'
    dictionary.write_text('kinou\t機能\t1\t2\nkinou\t昨日\t1\t2\nshiyou\t仕様\t1\t2\nshiyou\t使用\t1\t2\n',encoding='utf-8')
    fixture=tmp_path/'fixture.jsonl'
    fixture.write_text(json.dumps(dict(id='held-out',inputPat='shiyou',inputKana='シヨウ',context='仕様の文脈',expectedTop='仕様',
        candidates=[dict(text='仕様',reading='shiyou',source='connection',kind='exact')]))+'\n',encoding='utf-8')
    source=tmp_path/'source.jsonl'
    source.write_text('\n'.join(json.dumps(dict(input=k,output=g,left_context=f'文脈{i}')) for i in range(100)
                     for k,g in [('キノウ','機能'),('シヨウ','仕様')])+'\n',encoding='utf-8')
    args=SimpleNamespace(output=tmp_path/'one',fixture=fixture,dictionary=dictionary,sources=[source],limit=0,
                         max_reading=12,seed=42,none_rate=.5,version='test')
    public(args)
    args.output=tmp_path/'two'
    public(args)
    seen={}
    for s in ['train','validation','calibration','test']:
        assert digest(tmp_path/'one'/f'{s}.jsonl')==digest(tmp_path/'two'/f'{s}.jsonl')
        for r in rows(tmp_path/'one'/f'{s}.jsonl'):
            assert r['readingHiragana']!='しよう'
            if r['context'] in seen:
                assert seen[r['context']]==s
            seen[r['context']]=s
