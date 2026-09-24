#!/usr/bin/env python3
"""Build typing-corpus.jsonl for TypingSimulationTests.

Each sentence is written in the "habit" segmentation observed in dogfood logs
(content words converted one by one, particles/auxiliaries kana-confirmed).
A leading "+" merges the segment into the previous one for the "natural"
segmentation (compounds, verb+auxiliary, noun+particle typed as one unit),
so both segmentations always spell the same sentence.

Romaji follows the user's style: si/ti/tu, nn for ん.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

SENTENCES = [
    "youkenn:要件 +teigi:定義 wo:を kakuninn:確認 +site:して kara:から jissou:実装 +simasu:します .:。",
    "kono:この kinou:機能 ha:は settei:設定 +gamenn:画面 kara:から kirikae:切り替え +rareru:られる youni:ように sitai:したい .:。",
    "tesuto:テスト ga:が sippai:失敗 +siteiru:している genninn:原因 wo:を sirabete:調べて mimasu:みます .:。",
    "rogu:ログ wo:を mita:見た kagiri:限り dewa:では moderu:モデル no:の kiyo:寄与 ha:は mada:まだ tiisai:小さい desu:です .:。",
    "kaizenn:改善 +tenn:点 wo:を matomete:まとめて okurimasu:送ります .:。",
    "sukosi:少し +zutu:ずつ seido:精度 ga:が agatte:上がって kiteiru:きている kannji:感じ ga:が simasu:します .:。",
    "kouho:候補 no:の junni:順位 ga:が okasii:おかしい baai:場合 ha:は houkoku:報告 +site:して kudasai:ください .:。",
    "bennri:便利 da:だ to:と omotta:思った kedo:けど tukai:使い +kata:方 ga:が wakaranai:分からない .:。",
    "sinnki:新規 +touroku:登録 no:の nagare:流れ wo:を zu:図 ni:に kaite:書いて mita:みた .:。",
    "kyou:今日 no:の mi-thinngu:ミーティング de:で hanasita:話した naiyou:内容 wo:を kyouyuu:共有 +simasu:します .:。",
    "sono:その housinn:方針 de:で susumete:進めて moraete:もらえて yokatta:良かった desu:です .:。",
    "insuto-ru:インストール ga:が owattara:終わったら dousa:動作 +kakuninn:確認 wo:を onegai:お願い +simasu:します .:。",
    "atarasii:新しい birudo:ビルド de:で kannsu:関数 no:の namae:名前 wo:を kaeta:変えた .:。",
    "nennnotame:念の為 mou:もう ikkai:一回 tesuto:テスト wo:を hasirasete:走らせて mimasu:みます .:。",
    "sessyonn:セッション ga:が kireta:切れた node:ので sai:再 +roguinn:ログイン +simasita:しました .:。",
    "kono:この de-ta:データ ha:は gakusyuu:学習 ni:に tukawanai:使わない de:で hosii:ほしい .:。",
    "siyou:使用 +ryou:量 ga:が ooi:多い jikann:時間 +tai:帯 wo:を sirabeta:調べた .:。",
    "rebyu-:レビュー de:で sitekisareta:指摘された bubunn:部分 wo:を syuusei:修正 +simasita:しました .:。",
    "hennkou:変更 no:の hanni:範囲 ha:は tiisai:小さい node:ので sugu:すぐ ma-ji:マージ dekimasu:できます .:。",
    "uwagaki:上書き sareru:される to:と komaru:困る node:ので bakkuappu:バックアップ wo:を totte:取って okimasu:おきます .:。",
    "kangaete:考えて +imasu:います ga:が mada:まだ keturonn:結論 ha:は dete:出て imasenn:いません .:。",
    "yoi:良い +tokoro:ところ wo:を nobasite:伸ばして warui:悪い +tokoro:ところ wo:を naosu:直す .:。",
    "konnsinn:懇親 +kai:会 no:の basyo:場所 wo:を kimete:決めて okimasita:おきました .:。",
    "museigenn:無制限 ni:に sita:した baai:場合 no:の eikyou:影響 wo:を mitumoru:見積もる .:。",
    "keisann:計算 +kekka:結果 ga:が atteiru:合っている ka:か dou:どう ka:か wo:を tasikameru:確かめる .:。",
    "zisyo:辞書 ni:に nai:ない tanngo:単語 ha:は touroku:登録 +site:して tukatte:使って imasu:います .:。",
    "kanozyo:彼女 no:の ikenn:意見 wo:を kiite:聞いて kara:から kimeru:決める .:。",
    "zennkai:前回 no:の hou:方 ga:が hayakatta:速かった ki:気 ga:が suru:する .:。",
    "sirabeta:調べた +kedo:けど yoku:よく wakaranakatta:分からなかった .:。",
    "saigo:最後 ni:に zenntai:全体 wo:を mitoosite:見通して moraemasuka:もらえますか ?:？",
]


def segments(sentence: str) -> tuple[list[list[str]], list[list[str]]]:
    habit: list[list[str]] = []
    natural: list[list[str]] = []
    for token in sentence.split():
        merge = token.startswith("+")
        romaji, expected = token.lstrip("+").split(":", 1)
        habit.append([romaji, expected])
        if merge and natural:
            natural[-1] = [natural[-1][0] + romaji, natural[-1][1] + expected]
        else:
            natural.append([romaji, expected])
    return habit, natural


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("typing-corpus.jsonl")
    with out.open("w", encoding="utf-8") as f:
        for index, sentence in enumerate(SENTENCES, 1):
            habit, natural = segments(sentence)
            assert "".join(e for _, e in habit) == "".join(e for _, e in natural)
            row = {"id": f"s{index:03d}", "segmentations": {"habit": habit, "natural": natural}}
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"wrote {len(SENTENCES)} sentences to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
