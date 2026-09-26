# ADR-030: サ変名詞の接続を UniDic の品詞から補う

## Status

Accepted (2026-09-24)

## Decision

同梱の接続辞書 `Resources/dict.txt` で、一般名詞（`3 4`）のうち UniDic が `サ変可能` / `サ変形状詞可能` とする名詞に、サ変クラスの行（`50 51`）を追加する。`50 51` の行は する の活用形（し / して / します / した …）にだけ接続するので、「jissousimasu」から「実装します」を合成できるようになる。

生成は `Tools/dict/add-sahen-connection.py` で行い、UniDic（unidic-lite 1.0.8 = UniDic 2.1.2、BSD ライセンスを選択）は生成時だけ使う。IME の実行時には依存しない。既存行は変更せず、各 `3 4` 行の直後に追加する（4,255 行 / 2,053 語）。

## Context

タイピングシミュレータ（`Tools/eval/run-typing-simulation.sh`）で、自然な区切り（名詞+する をまとめて打つ）の候補なし 20 件のうち 3 件が名詞+する だった。同梱辞書でサ変クラスを持つのは 515 語だけで、「実装」「登録」「寄与」など頻出の漢語が漏れていた。dogfood ログでも、長い読みを打ってから前半だけ確定する例（`kangaeteimasu` → 考えて など）があり、ユーザーの短い区切りは変換できない形を避けた結果と考えられる。

## Consideration

- 漢字2文字以上の一般名詞すべてに する を許す: 「時間します」「要件します」も合成される。する が付くかは語ごとの性質（動作性）で、字面では決まらない。
- UniDic の品詞で限定する（採用）: 既存のサ変クラス 515 語のうち 469 語が UniDic でも `サ変可能` と一致した。残りの多くは `サ変形状詞可能`（心配・安心）か、UniDic 上で複数語に分かれる語（再利用・自動化）。
- IPAdic の `名詞,サ変接続`: 同じ情報を持つが、fugashi で扱える unidic-lite を選んだ。

## Consequences

- シミュレータの自然な区切りで 1 位率 0.737 → 0.758（実装します・登録して が候補なし → 1 位）。普段の区切りの結果は不変。
- 追加行は する の活用形まで入力したときだけ使われる。UniDic の判定誤り（例: 鼻歌・奉行 もサ変可能とされる）はその入力をしたときにしか現れない。
- UniDic で複数語に分かれる複合語（再利用など）は対象外。名詞+名詞の複合語は別の判断（未対応）。
- `Resources/DICTIONARY_THIRD_PARTY_NOTICES.txt` に UniDic の BSD 表示を同梱する。

## References

- [辞書システム spec](../specs/dictionary-system.md)
- `Tools/dict/add-sahen-connection.py`
- UniDic: https://clrd.ninjal.ac.jp/unidic/
