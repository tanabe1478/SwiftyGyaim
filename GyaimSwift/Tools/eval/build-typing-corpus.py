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
    # 文脈で決まる同音異義語
    "kinou:昨日 no:の kaigi:会議 de:で kimatta:決まった koto:こと wo:を matomeru:まとめる .:。",
    "atarasii:新しい kinou:機能 wo:を tuika:追加 +sita:した .:。",
    "ie:家 ni:に kaeru:帰る mae:前 ni:に settei:設定 wo:を kaeru:変える .:。",
    "kusuri:薬 ga:が kiku:効く made:まで sizuka:静か ni:に matu:待つ .:。",
    "wakaranai:分からない koto:こと ha:は senpai:先輩 ni:に kiku:聞く .:。",
    "kikai:機会 ga:が areba:あれば kikai:機械 no:の sekkei:設計 mo:も yaritai:やりたい .:。",
    "sikou:試行 +sakugo:錯誤 wo:を kurikaesite:繰り返して keturonn:結論 wo:を dasu:出す .:。",
    "kyousou:競争 ga:が hagesii:激しい sijou:市場 de:で ikinokoru:生き残る .:。",
    "kouenn:公園 de:で kouenn:講演 no:の renshuu:練習 wo:を sita:した .:。",
    "hennkou:変更 +tenn:点 wo:を kakuninn:確認 +site:して moraemasuka:もらえますか ?:？",
    # 数字と助数詞
    "2:2 +ko:個 no:の fairu:ファイル wo:を hennkou:変更 +sita:した .:。",
    "3:3 +jikann:時間 hodo:ほど kakarimasu:かかります .:。",
    "10:10 +funn:分 go:後 ni:に kaisi:開始 +simasu:します .:。",
    "sannninn:三人 de:で nikai:二回 kakuninn:確認 +sita:した .:。",
    # カタカナ語 + する / 複合語
    "de-ta:データ wo:を appuro-do:アップロード +sita:した .:。",
    "sa-ba-:サーバー wo:を saikidou:再起動 +site:して kara:から rogu:ログ wo:を mita:見た .:。",
    "kaihatu:開発 +kannkyou:環境 no:の settei:設定 wo:を minaosu:見直す .:。",
    "yu-za-:ユーザー +settei:設定 ga:が hozonn:保存 +sarenai:されない .:。",
    "risuto:リスト no:の junnbann:順番 wo:を irekaeru:入れ替える .:。",
    # 形容詞・形容動詞
    "kono:この houhou:方法 ha:は kanntann:簡単 +na:な node:ので sugu:すぐ tamesemasu:試せます .:。",
    "sonnnani:そんなに muzukasiku:難しく nai:ない to:と omoimasu:思います .:。",
    "kyou:今日 ha:は totemo:とても atui:暑い .:。",
    "hituyou:必要 +na:な jouhou:情報 dake:だけ wo:を nokosu:残す .:。",
    "tanosikatta:楽しかった kedo:けど tukareta:疲れた .:。",
    # 敬語・定型
    "okurete:遅れて mousiwake:申し訳 arimasenn:ありません .:。",
    "goannnai:ご案内 +itasimasu:いたします .:。",
    "yorosiku:よろしく onegai:お願い +itasimasu:いたします .:。",
    "otukaresama:お疲れ様 desu:です .:。",
    # 複合動詞・補助動詞
    "setumei:説明 wo:を kakinaosu:書き直す .:。",
    "settei:設定 +fairu:ファイル wo:を yomikomu:読み込む .:。",
    "tamesite:試して mimasita:みました ga:が umaku:うまく ugokimasenn:動きません .:。",
    "kinou:機能 wo:を tukaikonasu:使いこなす niha:には jikann:時間 ga:が kakaru:かかる .:。",
    # 固有名詞・地名
    "toukyou:東京 kara:から oosaka:大阪 made:まで sinnkannsenn:新幹線 de:で iku:行く .:。",
    "raisyuu:来週 no:の getuyoubi:月曜日 ni:に syuttyou:出張 +simasu:します .:。",
]


# Held-out set: the same words as SENTENCES in new contexts, for measuring what
# learning from SENTENCES carries over (GYAIM_TYPING_SIM_TRAIN_CORPUS).
HELDOUT = [
    "sono:その kikai:機会 ni:に kikai:機械 +gakusyuu:学習 wo:を benkyou:勉強 +sita:した .:。",
    "kouenn:公園 no:の benti:ベンチ de:で kouenn:講演 no:の siryou:資料 wo:を yonnda:読んだ .:。",
    "kinou:昨日 tuika:追加 +sita:した kinou:機能 ga:が ugokanai:動かない .:。",
    "rogu:ログ no:の keisiki:形式 wo:を kaeru:変える to:と ie:家 ni:に kaeru:帰る .:。",
    "wakaranai:分からない tokoro:ところ ga:が ooi:多い node:ので sukosi:少し sirabemasu:調べます .:。",
    "yokatta:良かった ra:ら kono:この houhou:方法 wo:を tukatte:使って kudasai:ください .:。",
    "sono:その kusuri:薬 ha:は yoku:よく kiku:効く ga:が jikann:時間 ga:が kakaru:かかる .:。",
    "sennsei:先生 ni:に situmonn:質問 wo:を kiku:聞く kikai:機会 ga:が nai:ない .:。",
    "kyousou:競争 +aite:相手 no:の seihinn:製品 wo:を siyou:使用 +site:して mita:みた .:。",
    "siyou:仕様 wo:を kakuninn:確認 +site:して kara:から jissou:実装 +simasu:します .:。",
    "sikou:試行 no:の kaisuu:回数 wo:を fuyasu:増やす .:。",
    "densya:電車 ga:が okurete:遅れて kaigi:会議 ni:に maniawanakatta:間に合わなかった .:。",
    "konnsinn:懇親 +kai:会 de:で hanasita:話した hito:人 ni:に me-ru:メール wo:を okuru:送る .:。",
    "kannsu:関数 no:の namae:名前 ga:が wakarinikui:分かりにくい .:。",
    "de-ta:データ no:の ryou:量 ga:が ooi:多い to:と syori:処理 ga:が osoku:遅く naru:なる .:。",
    "kono:この hou:方 ga:が yoi:良い to:と omoimasu:思います .:。",
    "sukosi:少し matte:待って kara:から mouitido:もう一度 tamesimasu:試します .:。",
    "hayai:速い kuruma:車 de:で iku:行く hou:方 ga:が raku:楽 desu:です .:。",
    "keturonn:結論 ha:は raisyuu:来週 no:の kaigi:会議 de:で kimemasu:決めます .:。",
    "hennkou:変更 wo:を kakuninn:確認 +sita:した ue:上 de:で ma-ji:マージ +simasu:します .:。",
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
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent
    for name, sentences, prefix in [("typing-corpus.jsonl", SENTENCES, "s"),
                                    ("typing-corpus-heldout.jsonl", HELDOUT, "h")]:
        out = out_dir / name
        with out.open("w", encoding="utf-8") as f:
            for index, sentence in enumerate(sentences, 1):
                habit, natural = segments(sentence)
                assert "".join(e for _, e in habit) == "".join(e for _, e in natural)
                row = {"id": f"{prefix}{index:03d}", "segmentations": {"habit": habit, "natural": natural}}
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
        print(f"wrote {len(sentences)} sentences to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
