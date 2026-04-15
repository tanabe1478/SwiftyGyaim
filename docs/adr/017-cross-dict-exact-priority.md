# ADR-017: 完全一致reading優先を辞書をまたいで適用

## Status

Accepted (supersedes ADR-016 — extends its scope from per-dict to cross-dict)

## Decision

ADR-016 で導入した完全一致reading優先を、**辞書をまたいだ4バケット順序**で適用する:

```
1. studyDict exact   (reading == q)
2. localDict exact   (yomi == q)
3. studyDict prefix  (regex prefix match)
4. localDict prefix
5. connectionDict    (現状の挙動を維持、最後)
```

`exactReadingMatchPriority` が ON のときのみ適用。OFF時の挙動は完全に維持。

## Context

ADR-016 では `exactReadingMatchPriority = ON` のとき、各辞書（study, local）内で2パス（exact → prefix）に分けて優先表示していた。しかし**辞書をまたいだ exact > prefix の整理は行っていなかった**。

### 報告された症状（BUG-004）

ユーザーが `ken` で `件` を毎回確定しても、studyDict に学習済みの `kensaku → 検索`, `kentou → 検討`, `kensyou → 検証`, `kengen → 権限` 等の **prefix match** が先に並び、localDict の **exact match** である `件` (reading=ken) は **7番目** に埋もれた。`exactReadingMatchPriority = ON` でも改善せず、ユーザーは "完全一致優先" の契約が満たされていないと感じた。

### 原因

`WordSearch.search()` の探索順:

```
ADR-016 の挙動:
  studyDict exact → studyDict prefix → localDict exact → localDict prefix → connection
                                       ↑ '件' がここまで来ない
```

**studyDict prefix が localDict exact より先**に列挙されるため、localDict の exact 候補が studyDict の prefix 群に押し下げられていた。

## Consideration

Codex CLI (gpt-5.1) と2往復のセカンドオピニオンを実施。検討した代替案:

### Option A: 4バケット (採用)

```
study-exact → local-exact → study-prefix → local-prefix → connection(all)
```

- メリット: 報告バグを最小差分で修正。予測変換の体験を維持
- 既存ユーザー手動登録 (`localDict`) または学習済み (`studyDict`) の exact のみ前置
- connection 由来の単漢字（`県, 権, 圏, 拳, 券...`）は元の位置に留まる

### Option B: 6バケット (却下)

```
study-exact → local-exact → connection-exact → study-prefix → local-prefix → connection-prefix
```

却下理由:
- `ken` の connectionDict exact は16件 (`県, 権, 圏, 拳, 券, 軒, 健, 剣, 件, 堅, 兼, 検, 建, 研, 犬, 賢`) もあり、1ページ目（list mode 9枠）が単漢字で埋まる
- 学習済みの `検索/検討/検証` が1ページ目から消え、予測変換の体験が著しく劣化
- dedup 先着勝ちにより `connection exact` が `local exact` より前に出ると `source = .connection` となり、Shift+X 候補削除（GyaimController.deleteCurrentCandidate）が機能しなくなる

### Option C: rank tuple stable sort (将来検討)

`(isExact, sourceTier, frequency, recency, ...)` の tuple で全候補を stable sort。
- メリット: 最も柔軟、Mozc 風の汎用ランキング
- デメリット: 現状の `study` 永続化問題（BUG-003）解決後、緊急度なし。over-engineering
- 将来 default ON 化や予測精度向上を狙うときの本命

## Consequences

- 有効時: localDict exact が studyDict prefix より先に表示される。報告ケース `ken → 件` 解決
- 無効時: 完全に従来通り（OFF分岐は touch せず）
- studyDict / localDict は **走査回数2回** になる（exact pass + prefix pass）が、≤10,000件の線形スキャンなので実用影響なし
- connectionDict は単一バケット維持のため、connection-only な短い exact は元の位置を維持
- dedup 先着勝ちにより、user-owned dict (study/local) の `source` が保持され、候補削除機能と整合

## Test Coverage

| Test | 検証内容 |
|------|---------|
| `testLocalExactBeatsStudyPrefix` | 報告バグの直接的再現と修正検証 |
| `testStudyExactBeatsLocalExact` | 階層 (study > local) の維持 |
| `testConnectionExactDoesNotJumpAheadOfStudyPrefix` | 6バケット採用していないこと（regression防止） |
| `testLocalExactSourcePreservedOverConnection` | source = .local 維持で削除機能と整合 |

既存 ADR-016 の4テスト（`testExactReadingMatchPrioritizedOverPrefix`, `testExactMatchOrderPreservedWithinGroup`, `testPrefixMatchOrderPreservedWithinGroup`, `testLocalDictExactReadingMatchPrioritized`, `testDefaultDisabledPreservesExistingBehavior`）も全てpass。

## Future Work

- rank tuple stable sort への移行（Option C）— default ON 化や Mozc 風予測精度向上を狙うとき
- connection exact の救済（手動 promote ボタン or 短縮reading 自動提案）— 今回のスコープ外

## References

- ADR-016: 完全一致reading優先（基礎機能）
- BUG-004: cross-dict exact priority (docs/specs/bug-memory.md)
- Codex CLI 2往復相談 (2026-04-15)
