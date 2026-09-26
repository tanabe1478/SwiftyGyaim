#!/usr/bin/env python3
"""Add サ変名詞 (class 50 -> 51) rows to the bundled connection dictionary.

A 一般名詞 row (`romaji surface 3 4`) only connects to particles, so
"jissousimasu" cannot become 実装します unless 実装 also has a サ変 row
(`50 51`), which connects to する forms (し / して / します / した ...).
Whether a noun takes する is lexical, so this uses UniDic's POS: a surface
that UniDic tokenizes as one 名詞 with pos3 サ変可能 or サ変形状詞可能 gets
a `50 51` row right after each of its `3 4` rows. Existing rows are never
changed; rerunning is a no-op.

UniDic is only needed to regenerate (not at IME runtime):
    python3 -m venv /tmp/ud && /tmp/ud/bin/pip install fugashi unidic-lite
    /tmp/ud/bin/python Tools/dict/add-sahen-connection.py --write

UniDic (unidic-lite 1.0.8 = UniDic 2.1.2) is used under its BSD license;
see Resources/DICTIONARY_THIRD_PARTY_NOTICES.txt.
"""

from __future__ import annotations

import argparse
from pathlib import Path

DICT = Path(__file__).resolve().parents[2] / "Resources/dict.txt"
NOUN = ("3", "4")
SAHEN = ("50", "51")
SAHEN_POS3 = {"サ変可能", "サ変形状詞可能"}


def is_sahen(tagger, surface: str) -> bool:
    tokens = list(tagger(surface))
    return (len(tokens) == 1 and tokens[0].surface == surface
            and tokens[0].feature.pos1 == "名詞" and tokens[0].feature.pos3 in SAHEN_POS3)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dict", type=Path, default=DICT)
    parser.add_argument("--write", action="store_true", help="rewrite the dictionary in place")
    args = parser.parse_args()

    import fugashi  # noqa: PLC0415 - optional generation-time dependency

    tagger = fugashi.Tagger()
    lines = args.dict.read_text(encoding="utf-8").splitlines()
    rows = [line.split("\t") for line in lines]
    has_sahen = {(r[0], r[1]) for r in rows if len(r) >= 4 and (r[2], r[3]) == SAHEN}
    verdict: dict[str, bool] = {}
    out: list[str] = []
    added: list[str] = []
    for line, row in zip(lines, rows):
        out.append(line)
        if len(row) < 4 or (row[2], row[3]) != NOUN or "*" in row[1]:
            continue
        key = (row[0], row[1])
        if key in has_sahen:
            continue
        if row[1] not in verdict:
            verdict[row[1]] = is_sahen(tagger, row[1])
        if verdict[row[1]]:
            out.append("\t".join([row[0], row[1], *SAHEN]))
            has_sahen.add(key)
            added.append(row[1])

    print(f"added {len(added)} rows for {len(set(added))} surfaces")
    if args.write:
        args.dict.write_text("\n".join(out) + "\n", encoding="utf-8")
        print(f"wrote {args.dict}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
