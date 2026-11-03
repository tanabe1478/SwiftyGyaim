#!/usr/bin/env python3
"""Extract left-context evaluation cases from gyaim.log (ADR-040 analysis).

For every `Fast context accepted detail` line the script reconstructs when each
character of the model context was committed (from the `Commit outcome`
sequence of the same controller, the ADR-035 inheritance, and the committed
words), so the time gaps inside the 20-character context are known. It also
records the previously committed word and reading, and corrects the "chosen"
label when the user retyped the same reading within 15 s and picked another
word (the first commit was a mistake, the retyped word is the truth).

The output is one JSON object per accepted composition:

  time, controller, input, context (what the model saw), gaps [[index, s]],
  preGap, prevWord, prevReading, prevGap, chosen, chosenRank, truth,
  modelTop, modelOutcome, modelState, inherited, candidates [{text, source,
  kind, reading, contextAffinity, studyFrequency, score}]

The output contains the user's own text; keep it out of the repository.

Usage:
  python3 Tools/eval/extract-context-cases.py \
      --log ~/.gyaim/archive/gyaim-2026-10.log --log ~/.gyaim/gyaim.log \
      --out ~/.gyaim/eval/context-cases.jsonl
"""
import argparse
import bisect
import json
import re
import sys
from collections import defaultdict
from datetime import datetime

LINE = re.compile(
    r'^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] \[input\] \[info\] '
    r'(Commit outcome|Fast context accepted detail): input="([^"]*)" payload=(\{.*\})\s*$'
)
KANA = re.compile(r'[\u3041-\u3096\u30a1-\u30f6ー]+')
MODEL_CONTEXT_CHARS = 20
RETYPE_WINDOW_SECONDS = 15


def load_events(paths):
    events = {}
    for path in paths:
        with open(path, errors='replace') as handle:
            for line in handle:
                match = LINE.match(line)
                if not match:
                    continue
                stamp, kind, inp, payload = match.groups()
                try:
                    data = json.loads(payload)
                except ValueError:
                    continue
                key = (stamp, kind, data.get('controller'), data.get('generation'), data.get('composition'))
                events[key] = (datetime.strptime(stamp, '%Y-%m-%d %H:%M:%S'), kind, inp, data)
    return sorted(events.values(), key=lambda e: (e[0], 0 if e[1].startswith('Fast') else 1))


def committed_word(prev_context, next_context):
    """next == (prev + word)[-40:]; return word."""
    for k in range(min(len(prev_context), len(next_context)), 0, -1):
        if next_context.startswith(prev_context[len(prev_context) - k:]):
            return next_context[k:]
    return next_context


class Reconstruction:
    def __init__(self, events):
        self.events = events
        self.all_commits = []   # (time, word), chronological
        self.pending = []       # (time, known text) of controllers whose last word is unknown
        self.timelines = {}     # controller -> [(char, time | None)]
        self.last_word = {}     # controller -> (word, reading, time)
        self.reading_of = {}    # (time, word) -> reading
        self._derive_committed_words()

    def _derive_committed_words(self):
        commits = defaultdict(list)
        chosen, reading = {}, {}
        for t, kind, _inp, p in self.events:
            if kind == 'Commit outcome':
                commits[p['controller']].append((t, p['context'], p.get('composition')))
            else:
                top = p.get('top') or []
                rank = p.get('chosenRank')
                if rank is not None and rank < len(top):
                    chosen[(p['controller'], p.get('composition'))] = top[rank]['word']
                    reading[(p['controller'], p.get('composition'))] = top[rank].get('reading')
        self.committed = {}
        for controller, items in commits.items():
            for i in range(len(items) - 1):
                self.committed[(controller, i)] = committed_word(items[i][1], items[i + 1][1])
            last_time, _ctx, composition = items[-1]
            word = chosen.get((controller, composition))
            if word:
                self.committed[(controller, len(items) - 1)] = word
        self.reading_by = reading

    def align_backwards(self, context, now):
        remainder, cursor, out = context, now, []
        while remainder:
            hi = bisect.bisect_right(self.all_commits, (cursor, '\uffff'))
            found = None
            for j in range(hi - 1, -1, -1):
                commit_time, word = self.all_commits[j]
                if (now - commit_time).total_seconds() > 3600:
                    break
                if word and remainder.endswith(word):
                    found = (commit_time, word)
                    break
            if not found:
                for pending_time, text in reversed(self.pending[-100:]):
                    if (now - pending_time).total_seconds() > 3600 or not text:
                        continue
                    tail = text[-6:]
                    for k in range(1, 11):
                        if len(remainder) > k and remainder[:-k].endswith(tail):
                            found = (pending_time, remainder[-k:])
                            break
                    if found:
                        break
            if not found:
                break
            commit_time, word = found
            out = [(ch, commit_time) for ch in word] + out
            remainder, cursor = remainder[:-len(word)], commit_time
        return [(ch, None) for ch in remainder] + out

    @staticmethod
    def text(timeline):
        return ''.join(ch for ch, _ in timeline)

    def timeline_for(self, controller, context, now):
        timeline = self.timelines.get(controller)
        if timeline is None:
            timeline = self.align_backwards(context, now)
        elif not self.text(timeline).endswith(context):
            known = self.text(timeline)
            overlap = 0
            for k in range(min(len(context), len(known)), 0, -1):
                if known.endswith(context[:k]):
                    overlap = k
                    break
            if overlap:
                timeline = timeline + [(ch, None) for ch in context[overlap:]]
            else:
                timeline = self.align_backwards(context, now)
        self.timelines[controller] = timeline
        return timeline

    def previous_word(self, controller, context, now):
        previous = self.last_word.get(controller)
        if previous is None:
            for commit_time, word in reversed(self.all_commits[-300:]):
                if word and context.endswith(word) and (now - commit_time).total_seconds() <= 3600:
                    previous = (word, self.reading_of.get((commit_time, word)), commit_time)
                    break
        return previous

    def run(self):
        cases = []
        index_in_controller = defaultdict(int)
        for t, kind, inp, p in self.events:
            controller, context = p['controller'], p.get('context', '')
            timeline = self.timeline_for(controller, context, t)
            if kind == 'Fast context accepted detail':
                cases.append(self.accepted_case(t, inp, p, timeline))
                continue
            i = index_in_controller[controller]
            index_in_controller[controller] += 1
            word = self.committed.get((controller, i))
            if word is None:
                self.pending.append((t, self.text(timeline)))
                continue
            reading = self.reading_by.get((controller, p.get('composition')))
            if reading is None and KANA.fullmatch(word):
                reading = word
            self.all_commits.append((t, word))
            self.last_word[controller] = (word, reading, t)
            self.reading_of[(t, word)] = reading
            self.timelines[controller] = (timeline + [(ch, t) for ch in word])[-200:]
        return cases

    def accepted_case(self, t, inp, p, timeline):
        scores = (p.get('review') or {}).get('scores') or {}
        model_context = (p.get('modelContext') or p.get('context', '')).strip()[-MODEL_CONTEXT_CHARS:]
        segment = timeline[len(timeline) - len(model_context):] if model_context else []
        gaps = []
        for i in range(1, len(segment)):
            a, b = segment[i - 1][1], segment[i][1]
            if a is not None and b is not None and b > a:
                gaps.append([i, (b - a).total_seconds()])
        pre_gap = (t - segment[-1][1]).total_seconds() if segment and segment[-1][1] is not None else None
        top = p.get('top') or []
        rank = p.get('chosenRank')
        chosen = top[rank]['word'] if rank is not None and rank < len(top) else None
        by_index = {d['index']: d for d in p.get('dictionaryCandidates', [])}
        model_top = None
        if scores:
            best = max(scores, key=lambda k: scores[k])
            model_top = by_index.get(int(best), {}).get('text')
        previous = self.previous_word(p['controller'], p.get('context', ''), t)
        return dict(
            time=t.isoformat(sep=' '), controller=p['controller'], input=inp, context=model_context,
            gaps=gaps, preGap=pre_gap,
            prevWord=previous[0] if previous else None, prevReading=previous[1] if previous else None,
            prevGap=(t - previous[2]).total_seconds() if previous else None,
            chosen=chosen, chosenRank=rank, truth=chosen, modelTop=model_top,
            modelOutcome=p.get('modelOutcome'), modelState=p.get('modelState'),
            inherited=p.get('contextInherited'),
            candidates=[dict(text=d['text'], source=d.get('source'), kind=d.get('kind'), reading=d.get('reading'),
                             contextAffinity=d.get('contextAffinity'), studyFrequency=d.get('studyFrequency'),
                             score=scores.get(str(d['index'])))
                        for d in sorted(by_index.values(), key=lambda d: d['index'])] if scores else [],
        )


def correct_retypes(cases):
    """The first of two same-reading commits within 15 s was a mistake."""
    by_controller = defaultdict(list)
    for case in cases:
        by_controller[case['controller']].append(case)
    corrected = 0
    for items in by_controller.values():
        for first, second in zip(items, items[1:]):
            t1 = datetime.fromisoformat(first['time'])
            t2 = datetime.fromisoformat(second['time'])
            if (t2 - t1).total_seconds() > RETYPE_WINDOW_SECONDS:
                continue
            if not first['chosen'] or not second['chosen'] or first['chosen'] == second['chosen']:
                continue
            same_reading = first['input'] == second['input'] or (
                len(first['input']) >= 3 and second['input'].startswith(first['input']))
            if not same_reading:
                continue
            texts = [d['text'] for d in first['candidates']]
            truth = second['chosen'] if second['chosen'] in texts else next(
                (x for x in texts if x and second['chosen'].startswith(x) and x != first['chosen'] and x != first['input']),
                None)
            if truth:
                first['truth'] = truth
                corrected += 1
    return corrected


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--log', action='append', required=True, help='gyaim.log file (repeatable)')
    parser.add_argument('--out', required=True, help='output JSONL')
    args = parser.parse_args()
    events = load_events(args.log)
    cases = Reconstruction(events).run()
    corrected = correct_retypes(cases)
    with open(args.out, 'w') as out:
        for case in cases:
            out.write(json.dumps(case, ensure_ascii=False) + '\n')
    scored = sum(1 for c in cases if c['candidates'])
    with_gap = sum(1 for c in cases if c['gaps'])
    print(f'events={len(events)} cases={len(cases)} scored={scored} withGapInfo={with_gap} '
          f'retypeCorrected={corrected} -> {args.out}', file=sys.stderr)


if __name__ == '__main__':
    main()
