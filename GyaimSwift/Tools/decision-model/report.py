"""Summarize the completed, versioned artifact without re-running any evaluation."""
import argparse
from pathlib import Path

from common import private_output, read_json


def percent(value):
    return f'{value * 100:.2f}%' if value is not None else 'N/A'


def report(artifact,output):
    manifest=read_json(artifact/'manifest.json')
    if manifest['privacy']=='private':
        private_output(output)
    test=read_json(artifact/'evaluation.json')
    regression_path=artifact/'regression-evaluation.json'
    regression=read_json(regression_path) if regression_path.exists() else None
    calibration=read_json(artifact/'calibration.json')
    benchmark=read_json(artifact/'benchmark.json')
    quantization=read_json(artifact/'quantization.json')
    lines=['# Gyaim Decision Model 実験結果','','Last updated: 2026-09-19','',
           f"モデル: `{manifest['modelVersion']}` / {manifest['parameterCount']:,} parameters。",
           f"成果物の判定: **{manifest['releaseStatus']}**。Swift本体のモデル置換は行っていない。",'',
           '## 評価', '',
           '候補Top-1/MRRは正解が候補内にある例のみ。NONEを含む全例の正解率とは分けて示す。',
           'モデル選定はvalidationのみで完了し、その後にtest/regressionを評価した。', '',
           '| 評価集合 | 件数 | Decision Top-1 | heuristic Top-1 | gyaim-lm Top-1 | Decision MRR | 改善 | 悪化 | net benefit |',
           '|---|---:|---:|---:|---:|---:|---:|---:|---:|']
    for label,record in [('public test',test),('regression holdout',regression)]:
        if not record:
            continue
        lm=record.get('gyaimLM',{})
        rel=record['relative']
        lines.append(f"| {label} | {record['count']} | {percent(record['ranking'].get('top1'))} | {percent(record['heuristic'].get('top1'))} | {percent(lm.get('ranking',{}).get('top1'))} | {record['ranking'].get('mrr',0):.4f} | {rel['improved']} | {rel['worsened']} | {rel['netBenefit']:+d} |")
    lines+=['',f"Public test: NONE F1={test['none']['f1']:.4f}、全例decision accuracy={percent(test['decisionAccuracy'])}、ECE={test['calibration']['ece']:.4f}。",
            f"候補Recall@24={percent(test['candidateRecallAt24'])}。これは短い読み・競合辞書候補がある集合に条件付けたRecallであり、本番全入力のRecallではない。",'',
            '既存gyaim-lmは公開zenz全体で学習済み。public testはDecisionモデルにとってのholdoutであり、LMにとって未学習とは保証できない。',
            'HF条件付き平均logprobを同一候補集合で比較しており、本番GGUF＋保護規則全体の再現ではない。','',
            '## 校正・量子化', '',
            f"Temperature={calibration['temperature']:.6f}。独立calibration splitのNLL {calibration['before']['nll']:.4f} → {calibration['after']['nll']:.4f}、ECE {calibration['before']['ece']:.4f} → {calibration['after']['ece']:.4f}。",
            f"INT8 validation Top-1差={quantization['top1Delta']*100:+.3f} percentage points、ECE差={quantization['eceDelta']:+.5f}、argmax一致率={percent(quantization['argmaxAgreement'])}。",
            'INT8はlinear重みのdynamic quantizationであり、embedding/attentionはFP32のまま。','',
            '| ファイル | 実サイズ MB |','|---|---:|']
    for name,size in manifest['sizes'].items():
        lines.append(f'| {name} | {size/1_000_000:.3f} |')
    lines+=['','各サイズは単一modelファイル。参照コード・複数精度・reportを含む配布directory全体のサイズではない。','',
            '## Latency', '', 'Windows上、batch=1、warmup後、CPU threads=4。model loadは除外。macOS実測ではない。', '',
            '| backend | candidates | p50 ms | p95 ms | mean ms |','|---|---:|---:|---:|---:|']
    for row in benchmark['measurements']:
        lines.append(f"| {row['backend']} | {row['candidates']} | {row['p50']:.3f} | {row['p95']:.3f} | {row['mean']:.3f} |")
    lines+=['','## 品質判定','','| gate | result |','|---|---|']
    for name,passed in manifest['qualityGates'].items():
        lines.append(f"| {name} | {'PASS' if passed else 'FAIL'} |")
    if regression and regression.get('subsets'):
        lines+=['','## 回帰fixtureの内訳','','同じケースが複数tagに属するため、件数は単純加算できない。','',
                '| tag | 件数 | Decision Top-1 | gyaim-lm Top-1 | net benefit |','|---|---:|---:|---:|---:|']
        for tag,subset in regression['subsets'].items():
            lm=regression.get('gyaimLM',{}).get('subsets',{}).get(tag,{})
            lines.append(f"| {tag} | {subset['count']} | {percent(subset['ranking'].get('top1'))} | {percent(lm.get('ranking',{}).get('top1'))} | {subset['relative']['netBenefit']:+d} |")
    lines+=['','## 残る制約','',
            '- 公開データは各source先頭50万件から抽出。接続辞書graph全体、学習辞書、入力途中の分布は再現していない。',
            '- 公開学習には実際のstudyFrequency/contextAffinityがない。個人選好の有効性は未立証。',
            '- private temporal split・private artifact分離は実装／テスト済みだが、今回privateデータは使っていない。',
            '- 本番採用は未承認。品質gateが失敗したモデルをSwiftへ置き換えない。',
            '- Core MLの変換・実行とmacOS速度は別途検証が必要。', '',
            '詳細な再実行手順はREADME.md、比較実験全表は成果物のCOMPARISON.mdを参照する。']
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text('\n'.join(lines)+'\n',encoding='utf-8')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    report(args.artifact,args.output)
