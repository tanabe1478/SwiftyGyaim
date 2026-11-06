"""Pairwise contextual distillation with frozen student word-prior scores."""
import hashlib
import json
import math
from pathlib import Path
import re


def pair_fingerprint(row):
    payload = {k: row[k] for k in ('input', 'context', 'chosen', 'rejected')}
    return hashlib.sha256(json.dumps(payload, ensure_ascii=False, sort_keys=True,
                                    separators=(',', ':')).encode('utf-8')).hexdigest()


def load_teacher_margins(path, rows, pairs_sha256):
    cache = json.loads(Path(path).read_text(encoding='utf-8'))
    if (type(cache.get('formatVersion')) is not int or cache['formatVersion'] != 1
            or cache.get('pairsSha256') != pairs_sha256
            or cache.get('precision') != 'fp32' or cache.get('textPreprocessing') != 'hf'):
        raise ValueError('teacher cache format, source, precision or preprocessing mismatch')
    if not isinstance(cache.get('teacherModel'), str) or not cache['teacherModel']:
        raise ValueError('teacher model identity required')
    weight_hash = cache.get('teacherWeightsSha256')
    if not isinstance(weight_hash, str) or not re.fullmatch('[0-9a-f]{64}', weight_hash):
        raise ValueError('teacher weight hash required')
    if not isinstance(cache.get('records'), list):
        raise ValueError('teacher records must be a list')
    expected = {pair_fingerprint(row) for row in rows}
    if len(expected) != len(rows) or not expected:
        raise ValueError('expected teacher rows must be unique and nonempty')
    margins = {}
    for record in cache['records']:
        key, value = record['pairHash'], record['contextMargin']
        if key in margins or key not in expected:
            raise ValueError('duplicate or unknown teacher pair')
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError('teacher margin must be a finite number')
        margins[key] = float(value)
    if set(margins) != expected:
        raise ValueError('incomplete teacher coverage')
    metadata = {k: cache[k] for k in ('teacherModel', 'teacherWeightsSha256',
                                    'pairsSha256', 'precision', 'textPreprocessing')}
    return margins, metadata


def context_distillation_loss(scores, reference, preservation=1.):
    """Reference: teacher contextual margin, frozen student plain scores.

    BCE matches sigmoid(mean-logprob margin) at temperature1. This is
    two-candidate preference distillation, not full-vocabulary token KL.
    """
    import torch
    import torch.nn.functional as F
    if not math.isfinite(preservation) or preservation <= 0:
        raise ValueError('positive finite prior preservation required')
    scores = scores.reshape(-1, 4)
    if reference.shape != (len(scores), 3):
        raise ValueError('distillation requires three reference values per pair')
    if not torch.isfinite(reference).all():
        raise ValueError('non-finite distillation reference')
    frozen = reference.detach()
    targets = frozen[:, 0].sigmoid()
    margins = scores[:, 0]-scores[:, 1]
    return (F.binary_cross_entropy_with_logits(margins, targets)
            + preservation*F.mse_loss(scores[:, 2:], frozen[:, 1:]))
