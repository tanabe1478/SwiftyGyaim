"""Ranking metrics separate present-gold decisions, NONE and generator recall."""
import numpy as np


def probabilities(logits, temperature=1.):
    if not np.isfinite(temperature) or temperature<=0:
        raise ValueError('temperature must be positive and finite')
    logits=np.asarray(logits,dtype=np.float64)
    padding=logits == -10000
    padding[:,-1]=False
    x = logits / temperature
    x[padding]=-np.inf
    x -= x.max(1, keepdims=True)
    x = np.exp(x)
    return x / x.sum(1, keepdims=True)


def calibration_metrics(probs, targets):
    targets = np.asarray(targets, dtype=np.int64)
    confidence, pred = probs.max(1), probs.argmax(1)
    correct = pred == targets
    onehot = np.eye(25)[targets]
    table = []
    edges = [0, .1, .2, .3, .4, .5, .6, .7, .8, .9, .95, 1.]
    ece = 0.
    for i, (lo, hi) in enumerate(zip(edges[:-1], edges[1:])):
        mask = (confidence >= lo) & ((confidence < hi) if i < len(edges)-2 else confidence <= hi)
        count = int(mask.sum())
        accuracy, mean = (float(correct[mask].mean()), float(confidence[mask].mean())) if count else (None, None)
        if count:
            ece += count / len(targets) * abs(accuracy - mean)
        table.append(dict(low=lo, high=hi, count=count, accuracy=accuracy, meanProbability=mean))
    return dict(nll=float(-np.log(probs[np.arange(len(targets)), targets].clip(1e-15)).mean()),
                brier=float(((probs-onehot)**2).sum(1).mean()), ece=ece, reliability=table)


def summarize(logits, records, temperature=1., supports_none=True, baseline_orders=None):
    if not records:
        return {'count': 0}
    targets = np.array([24 if r['selected'] is None else r['selected'] for r in records])
    probs = probabilities(logits, temperature)
    preds = probs.argmax(1)
    present = targets != 24
    ranks, heuristic_ranks, homophone, preference = [], [], [], []
    errors = []
    for j, r in enumerate(records):
        n = len(r['candidates'])
        # Candidate-only ordering: NONE abstention assessed separately below.
        order = np.argsort(-logits[j, :n], kind='stable').tolist()
        base = sorted(range(n), key=lambda i: (r['candidates'][i].get('originalRank') if r['candidates'][i].get('originalRank') is not None else i, i))
        if baseline_orders is not None:
            base = baseline_orders[j]
        rank, base_rank = None, None
        is_homophone = sum(c.get('exactReadingMatch') is True and c.get('kind') in ('exact','compound') for c in r['candidates']) >= 2
        is_preference = any(c.get('studyFrequency') is not None or c.get('contextAffinity') is not None for c in r['candidates'])
        if r['selected'] is not None:
            rank, base_rank = order.index(r['selected']) + 1, base.index(r['selected']) + 1
            ranks.append(rank)
            heuristic_ranks.append(base_rank)
            homophone.append(is_homophone)
            preference.append(is_preference)
        wrong = preds[j] != targets[j]
        categories = []
        if wrong:
            categories.append('highest-confidence-wrong')
        if rank is not None and rank > base_rank:
            categories.append('rank-regression')
        if preds[j] == 24 and present[j]:
            categories.append('none-false-positive')
        if preds[j] != 24 and not present[j]:
            categories.append('none-false-negative')
        if wrong and is_homophone:
            categories.append('homophone-failure')
        if wrong and is_preference:
            categories.append('preference-failure')
        if categories:
            errors.append(dict(id=r.get('id', str(j)), categories=categories, prediction=int(preds[j]),
                               confidence=float(probs[j].max()), goldRank=rank, originalGoldRank=base_rank,
                               rankRegression=(rank-base_rank) if rank is not None else 0))
    ranks, base = np.asarray(ranks), np.asarray(heuristic_ranks)
    def ranking(v):
        return dict(count=len(v), top1=float((v==1).mean()), top3=float((v<=3).mean()),
                    mrr=float((1/v).mean()), meanGoldRank=float(v.mean())) if len(v) else {'count': 0}
    tp = int(((preds==24) & ~present).sum())
    fp = int(((preds==24) & present).sum())
    fn = int(((preds!=24) & ~present).sum())
    precision, recall = tp/max(tp+fp,1), tp/max(tp+fn,1)
    real = [r['candidateRecall'] for r in records if r.get('noneType') != 'synthetic' and 'candidateRecall' in r]
    coverage = []
    for threshold in [0, .5, .6, .7, .8, .9, .95, .99]:
        mask = (probs.max(1) >= threshold) & (preds != 24)
        coverage.append(dict(threshold=threshold, count=int(mask.sum()), coverage=float(mask.mean()),
                             accuracy=float((preds[mask]==targets[mask]).mean()) if mask.any() else None,
                             wrongDecisionRate=float((mask & (preds!=targets)).mean())))
    report = dict(count=len(records), candidateRecallAt24=float(np.mean(real)) if real else None,
                  ranking=ranking(ranks), heuristic=ranking(base), homophone=ranking(ranks[np.array(homophone, dtype=bool)]),
                  preference=ranking(ranks[np.array(preference, dtype=bool)]),
                  relative=dict(improved=int((ranks<base).sum()), unchanged=int((ranks==base).sum()),
                                worsened=int((ranks>base).sum()), netBenefit=int((ranks<base).sum()-(ranks>base).sum()),
                                meanRankDelta=float((base-ranks).mean()) if len(ranks) else None),
                  decisionAccuracy=float((preds==targets).mean()),
                  none=dict(precision=precision, recall=recall, f1=2*precision*recall/max(precision+recall,1e-15),
                            truePositive=tp, falsePositive=fp, falseNegative=fn) if supports_none else None,
                  calibration=calibration_metrics(probs, targets) if supports_none else None,
                  coverage=coverage if supports_none else None)
    return report, sorted(errors, key=lambda e: -e['confidence'])
