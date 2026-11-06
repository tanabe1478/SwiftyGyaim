#!/usr/bin/env python3
"""Private pairwise learning and contextual distillation with mean logprobs.

Preference mode is not canonical sequence-sum DPO. Fixed
evaluation pairs and SFT validation pairs are excluded on BOTH chosen/rejected.
"""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import signal

from prepare_context_training import (ROOT, RuntimeRomaToKata, ROMAKANA_SWIFT,
                                     load_roma_to_kata, context_holdout, legacy_holdout,
                                     normal, pair_key, read_rows, digest)


def split_pairs(rows, excluded, converter, seed=125):
    train, valid, seen = [], [], set()
    stats = Counter()
    for row in rows:
        source = row.get('source', 'observed-user-preference')
        if source not in ('public-corpus-dictionary-contrast', 'observed-user-preference'):
            raise ValueError('unknown pair source')
        reading = row.get('inputKana') or converter.convert(row['input'])
        chosen, rejected = row['chosen'], row['rejected']
        if not reading or not chosen or not rejected or chosen == rejected:
            stats['invalid'] += 1
            continue
        if source == 'observed-user-preference' and (row.get('rejectedRank') != 1 or row.get('chosenRank', 0) <= 1):
            raise ValueError('preference must be chosen below displayed rank 1')
        # Split and deduplicate on the same normalized identity used by holdouts.
        # inputKana can contain hiragana or decomposed combining characters.
        reading, chosen = pair_key(reading, chosen)
        _, rejected = pair_key(reading, rejected)
        if chosen == rejected:
            stats['invalid'] += 1
            continue
        keys = {pair_key(reading, chosen), pair_key(reading, rejected)}
        if keys & excluded:
            stats['holdoutOverlap'] += 1
            continue
        context = normal(row.get('context') or '').strip()[-20:]
        if not context:
            stats['noContext'] += 1
            continue
        key = (reading, context, chosen, rejected)
        if key in seen:
            stats['duplicate'] += 1
            continue
        seen.add(key)
        stats[source] += 1
        # All choices for the same reading stay together, including reversed pairs.
        bucket = int.from_bytes(hashlib.sha256(f'{seed}:{reading}'.encode()).digest()[:8], 'big')/2**64
        target = valid if bucket < .2 else train
        target.append(dict(input=reading, context=context, chosen=chosen, rejected=rejected))
    return train, valid, dict(stats)


def mean_completion_scores(logits, ids, completion_mask):
    import torch
    targets = ids[:, 1:]
    mask = completion_mask[:, 1:]
    if not torch.all(mask.sum(1) > 0):
        raise ValueError('empty completion span')
    logprobs = logits[:, :-1].float().log_softmax(-1)
    token_scores = logprobs.gather(-1, targets.unsqueeze(-1)).squeeze(-1)
    return token_scores.masked_fill(~mask, 0).sum(1)/mask.sum(1)


def preference_loss(scores, reference_delta, beta=2., anchor=.05):
    import torch.nn.functional as F
    if not math.isfinite(anchor) or anchor < 0:
        raise ValueError('anchor must be finite and nonnegative')
    pair = scores.reshape(-1, 2)
    delta = pair[:, 0]-pair[:, 1]
    return F.softplus(-beta*(delta-reference_delta)).mean() - anchor*pair[:, 0].mean()


def distillation_scores(model, inputs, deterministic_prior=False):
    """Keep contextual dropout, but optionally score the plain prior in eval mode.

    Eval mode does not disable gradients. Restore every module's original mode
    even if the plain forward fails. Evaluation itself uses the usual one pass.
    """
    import torch
    ids = inputs['input_ids']
    def score(index):
        selected = ids[index]
        logits = model(selected, attention_mask=inputs['attention_mask'][index]).logits
        return mean_completion_scores(logits, selected, inputs['completion_mask'][index])
    if not deterministic_prior or not model.training:
        return score(slice(None))
    if len(ids) % 4:
        raise ValueError('deterministic prior requires four sequences per pair')
    if getattr(model, 'is_gradient_checkpointing', False):
        raise ValueError('mixed forward modes do not support gradient checkpointing')
    indices = torch.arange(len(ids), device=ids.device).reshape(-1, 4)
    contextual = score(indices[:, :2].flatten()).reshape(-1, 2)
    modes = [(module, module.training) for module in model.modules()]
    try:
        model.eval()
        plain = score(indices[:, 2:].flatten()).reshape(-1, 2)
    finally:
        for module, training in modes:
            module.training = training
    return torch.cat((contextual, plain), dim=1).flatten()


def configure_training_dropout(config, dropout=None):
    """Set GPT2 dropout before model construction; omission preserves the base."""
    fields = ('attn_pdrop', 'embd_pdrop', 'resid_pdrop')
    before = {field: getattr(config, field, None) for field in fields}
    if dropout is not None:
        if not math.isfinite(dropout) or not 0 <= dropout < 1:
            raise ValueError('dropout must be finite and in [0, 1)')
        if config.model_type != 'gpt2' or any(v is None for v in before.values()):
            raise ValueError('dropout override requires GPT2 configuration')
        for field in fields:
            setattr(config, field, dropout)
    return dict(override=dropout, original=before,
                effective={field: getattr(config, field, None) for field in fields})


def configure_trainable_parameters(model, scope='all'):
    if scope not in ('all', 'attention'):
        raise ValueError('unknown trainable parameter scope')
    if scope == 'attention' and model.config.model_type != 'gpt2':
        raise ValueError('attention scope currently supports GPT2 only')
    names = []
    total = trainable = 0
    for name, parameter in model.named_parameters():
        enabled = scope == 'all' or (name.startswith('transformer.h.') and '.attn.' in name)
        parameter.requires_grad_(enabled)
        total += parameter.numel()
        if enabled:
            trainable += parameter.numel()
            names.append(name)
    if not trainable or (scope == 'attention' and trainable == total):
        raise ValueError('parameter scope matched an unexpected model layout')
    return dict(scope=scope, totalParameters=total, trainableParameters=trainable,
                trainableParameterNames=names)


def context_gain_loss(scores, reference, preservation=1., beta=2.):
    """Four scores: contextual chosen/rejected, then contextless chosen/rejected.

    Reference columns: contextual margin, contextless chosen, contextless rejected.
    This experimental training objective does not change runtime scoring.
    """
    import torch.nn.functional as F
    if not math.isfinite(preservation) or preservation <= 0:
        raise ValueError('positive finite prior preservation required')
    scores = scores.reshape(-1, 4)
    if reference.shape != (len(scores), 3):
        raise ValueError('context gain requires three reference values per pair')
    gain = scores[:, 0]-scores[:, 1]-scores[:, 2]+scores[:, 3]
    reference_gain = reference[:, 0]-reference[:, 1]+reference[:, 2]
    return (F.softplus(-beta*(gain-reference_gain)).mean()
            + preservation*F.mse_loss(scores[:, 2:], reference[:, 1:]))


def collate_preference_examples(examples, pad_id):
    import torch
    sequences = [s for ex in examples for s in ex['sequences']]
    prompts = [n for ex in examples for n in ex['promptLengths']]
    assert len(sequences) == len(prompts)
    size = max(map(len, sequences))
    ids = torch.full((len(sequences), size), pad_id, dtype=torch.long)
    attention = torch.zeros_like(ids)
    mask = torch.zeros_like(ids, dtype=torch.bool)
    for i, (sequence, prompt_length) in enumerate(zip(sequences, prompts)):
        if not 0 < prompt_length < len(sequence):
            raise ValueError('invalid completion span')
        ids[i, :len(sequence)] = torch.tensor(sequence)
        attention[i, :len(sequence)] = 1
        mask[i, prompt_length:len(sequence)] = True
    return dict(input_ids=ids, attention_mask=attention, completion_mask=mask,
                reference_delta=torch.tensor([ex['reference_delta'] for ex in examples]))


def replay_context_gain_loss(scores, reference, preservation, replay_weight):
    import torch.nn.functional as F
    if not math.isfinite(replay_weight) or replay_weight <= 0:
        raise ValueError('positive finite replay weight required')
    scores = scores.reshape(-1, 5)
    if reference.shape != (len(scores), 4):
        raise ValueError('replay requires four reference values')
    return (context_gain_loss(scores[:, :4], reference[:, :3], preservation)
            + replay_weight*F.mse_loss(scores[:, 4], reference[:, 3]))


def train(args):
    import torch
    from transformers import AutoConfig, AutoModelForCausalLM, AutoTokenizer, Trainer, TrainingArguments, set_seed
    from train_zenz import GracefulStopCallback, add_legacy_gpt2_context_alias
    output = args.output.resolve()
    if not output.is_relative_to((ROOT/'runs').resolve()) or output.exists():
        raise ValueError('use a new private run directory under runs/')
    if args.steps <= 0 or args.lr <= 0:
        raise ValueError('positive steps and learning rate required')
    if not math.isfinite(args.anchor) or args.anchor < 0:
        raise ValueError('anchor must be finite and nonnegative')
    distill_mode = args.objective == 'context_distill'
    if args.deterministic_prior and not distill_mode:
        raise ValueError('deterministic prior requires context_distill')
    gain_mode = args.objective in ('context_gain', 'context_distill')
    if gain_mode and (args.anchor != 0 or not math.isfinite(args.prior_preservation) or args.prior_preservation <= 0):
        raise ValueError('context objectives require anchor=0 and positive finite prior preservation')
    if distill_mode != (args.teacher_scores is not None):
        raise ValueError('teacher scores are required only for context_distill')
    width = 4 if gain_mode else 2
    replay_mode = args.prior_replay is not None
    if replay_mode:
        if args.objective != 'context_gain' or not math.isfinite(args.replay_weight) or args.replay_weight <= 0:
            raise ValueError('replay requires context_gain and positive finite weight')
        width = 5
    converter = RuntimeRomaToKata(load_roma_to_kata(ROMAKANA_SWIFT))
    excluded, _ = context_holdout(read_rows(args.context_cases), converter)
    excluded |= legacy_holdout(args.holdout)
    train_rows, valid_rows, stats = split_pairs(read_rows(args.pairs), excluded, converter, args.seed)
    if not train_rows or not valid_rows:
        raise ValueError('not enough independent preference train/validation data')
    teacher_margins = teacher_metadata = None
    if distill_mode:
        from context_distillation import load_teacher_margins, pair_fingerprint, context_distillation_loss
        teacher_margins, teacher_metadata = load_teacher_margins(
            args.teacher_scores, train_rows+valid_rows, digest(args.pairs))
    if not torch.cuda.is_available():
        raise ValueError('GPU required for this experiment')
    set_seed(args.seed)
    tokenizer = AutoTokenizer.from_pretrained(args.base_model)
    config = AutoConfig.from_pretrained(args.base_model)
    dropout_settings = configure_training_dropout(config, args.dropout)
    model = AutoModelForCausalLM.from_pretrained(args.base_model, config=config).cuda().eval()
    parameter_scope = configure_trainable_parameters(model, args.trainable)

    def encode(row):
        prompt = tokenizer.encode('\uEE02'+row['context']+'\uEE00'+row['input']+'\uEE01', add_special_tokens=False)
        completions = [tokenizer.encode(row[field], add_special_tokens=False) for field in ('chosen', 'rejected')]
        if not prompt or any(not c or len(prompt)+len(c) > 192 for c in completions):
            raise ValueError('empty or oversized preference; no silent truncation')
        sequences = [prompt+c for c in completions]
        lengths = [len(prompt)]*2
        if gain_mode:
            plain = tokenizer.encode('\uEE00'+row['input']+'\uEE01', add_special_tokens=False)
            sequences.extend(plain+c for c in completions)
            lengths.extend([len(plain)]*2)
        return dict(sequences=sequences, promptLengths=lengths,
                    reference_delta=[0., 0., 0.] if gain_mode else 0.)

    def collate(examples):
        return collate_preference_examples(examples, tokenizer.eos_token_id)

    def loss_for_scores(scores, reference):
        if distill_mode:
            return context_distillation_loss(scores, reference, args.prior_preservation)
        if replay_mode:
            return replay_context_gain_loss(scores, reference, args.prior_preservation, args.replay_weight)
        if gain_mode:
            return context_gain_loss(scores, reference, preservation=args.prior_preservation)
        return preference_loss(scores, reference, anchor=args.anchor)

    datasets = [[encode(row) for row in rows] for rows in (train_rows, valid_rows)]
    replay_counts = None
    if replay_mode:
        pools = [[], []]
        preference_readings = {r['input'] for r in train_rows+valid_rows}
        replay_readings = set()
        for row in read_rows(args.prior_replay):
            reading, completion = pair_key(row['input'], row['output'])
            if (reading, completion) in excluded or reading in preference_readings or reading in replay_readings:
                raise ValueError('replay overlap or duplicate reading')
            replay_readings.add(reading)
            prompt = tokenizer.encode('\uEE00'+reading+'\uEE01', add_special_tokens=False)
            tail = tokenizer.encode(completion, add_special_tokens=False)
            if not tail or len(prompt)+len(tail)>192:
                raise ValueError('invalid replay completion; no truncation')
            bucket = int.from_bytes(hashlib.sha256(f'{args.seed}:{reading}'.encode()).digest()[:8], 'big')/2**64
            pools[int(bucket < .2)].append((prompt+tail, len(prompt)))
        if any(not pool for pool in pools):
            raise ValueError('empty replay split')
        replay_counts = [len(pool) for pool in pools]
        for dataset, pool in zip(datasets, pools):
            if len(pool)>len(dataset):
                raise ValueError('replay pool exceeds preference examples')
            for i, example in enumerate(dataset):
                sequence, prompt_length = pool[i % len(pool)]
                example['sequences'].append(sequence)
                example['promptLengths'].append(prompt_length)
                example['reference_delta'].append(0.)
    # Cache reference odds before updating the model. Neither train nor validation
    # text is written to console, checkpoints' metadata, or public reports.
    with torch.inference_mode(), torch.autocast('cuda', dtype=torch.float16, enabled=args.precision == 'fp16'):
        for dataset in datasets:
            for start in range(0, len(dataset), 16):
                examples = dataset[start:start+16]
                batch = {k: v.cuda() for k, v in collate(examples).items()}
                logits = model(batch['input_ids'], attention_mask=batch['attention_mask']).logits
                scores = mean_completion_scores(logits, batch['input_ids'], batch['completion_mask'])
                pairs = scores.reshape(-1, width)
                for example, values, delta in zip(examples, pairs.tolist(), (pairs[:, 0]-pairs[:, 1]).tolist()):
                    example['reference_delta'] = [delta, values[2], values[3]] if gain_mode else delta
                    if replay_mode:
                        example['reference_delta'].append(values[4])

    if distill_mode:
        for dataset, rows in zip(datasets, (train_rows, valid_rows)):
            for example, row in zip(dataset, rows):
                # Preserve the original student's plain scores, replacing only
                # the contextual target with the independently frozen teacher.
                example['reference_delta'][0] = teacher_margins[pair_fingerprint(row)]

    class PairTrainer(Trainer):
        def compute_loss(self, model, inputs, return_outputs=False, **kwargs):
            scores = distillation_scores(model, inputs, args.deterministic_prior)
            loss = loss_for_scores(scores, inputs['reference_delta'])
            return (loss, {'logits': scores.reshape(-1, width)}) if return_outputs else loss

    output.mkdir(parents=True)
    manifest = dict(privacy='private', objective=f'reference-relative logistic mean-logprob preference + {args.anchor:g} chosen NLL',
                    beta=2., anchor=args.anchor, baseModel=str(args.base_model), baseWeightsSha256=digest(args.base_model/'model.safetensors'),
                    pairsSha256=digest(args.pairs), casesSha256=digest(args.context_cases),
                    holdoutSha256=[digest(p) for p in args.holdout], seed=args.seed, learningRate=args.lr,
                    maxSteps=args.steps, trainPairs=len(train_rows), validationPairs=len(valid_rows), filtering=stats,
                    split='reading-group SHA256; 20% validation; context present only',
                    torch=torch.__version__, selection=args.selection, precision=args.precision,
                    parameterScope=parameter_scope, trainingDropout=dropout_settings)
    manifest['objectiveMode'] = args.objective
    if gain_mode:
        manifest['objective'] = 'reference-relative contextual minus contextless margin logistic + contextless score MSE'
        manifest['priorPreservation'] = args.prior_preservation
    if distill_mode:
        manifest['objective'] = 'teacher contextual pair-probability BCE + frozen student contextless score MSE'
        manifest['deterministicPrior'] = args.deterministic_prior
        manifest.pop('beta')
        manifest['temperature'] = 1.
        manifest['teacher'] = dict(teacher_metadata, cacheSha256=digest(args.teacher_scores))
    if replay_mode:
        manifest['publicPriorReplay'] = dict(sha256=digest(args.prior_replay),
            weight=args.replay_weight, trainRows=replay_counts[0], validationRows=replay_counts[1],
            assignment='deterministic cyclic within disjoint reading splits; one replay sequence per preference')
    (output/'preference_manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({'trainPairs': len(train_rows), 'validationPairs': len(valid_rows), 'filtering': stats}), flush=True)
    callback = GracefulStopCallback(output/'STOP_REQUESTED')
    def pair_metrics(prediction):
        scores = prediction.predictions
        if isinstance(scores, tuple):
            scores = scores[0]
        margins = scores[:, 0]-scores[:, 1]
        accuracy = float((margins > 0).mean())
        loss = float(loss_for_scores(torch.tensor(scores).flatten(), torch.tensor(prediction.label_ids)))
        # The bounded secondary term can never outweigh one correct pair.
        quality = accuracy - loss/(1+abs(loss))/(100*(len(margins)+1))
        metrics = dict(pair_accuracy=accuracy, pair_margin=float(margins.mean()), pair_quality=quality)
        if gain_mode:
            metrics['prior_score_rmse'] = float(((scores[:, 2:4]-prediction.label_ids[:, 1:3])**2).mean()**.5)
        if replay_mode:
            metrics['replay_score_rmse'] = float(((scores[:, 4]-prediction.label_ids[:, 3])**2).mean()**.5)
        return metrics
    trainer = PairTrainer(model=model, args=TrainingArguments(
        output_dir=str(output), max_steps=args.steps, learning_rate=args.lr,
        per_device_train_batch_size=8, per_device_eval_batch_size=8,
        fp16=args.precision == 'fp16', seed=args.seed, remove_unused_columns=False, label_names=['reference_delta'],
        eval_strategy='steps', eval_steps=25, save_steps=25, logging_steps=10,
        load_best_model_at_end=True, metric_for_best_model='eval_'+args.selection,
        greater_is_better=args.selection != 'loss',
        save_total_limit=2, report_to=[], dataloader_num_workers=0),
        train_dataset=datasets[0], eval_dataset=datasets[1], data_collator=collate, callbacks=[callback],
        compute_metrics=pair_metrics)
    manifest['initialValidation'] = trainer.evaluate()
    (output/'preference_manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
    previous = signal.signal(signal.SIGINT, lambda *_: callback.request_stop())
    try:
        trainer.train()
    finally:
        signal.signal(signal.SIGINT, previous)
    if callback.stop_was_honored:
        print('Preference training stopped with checkpoint; no final artifact published.')
        return
    final = output/'final'
    trainer.save_model(str(final))
    tokenizer.save_pretrained(final)
    add_legacy_gpt2_context_alias(final)
    manifest['bestCheckpoint'] = trainer.state.best_model_checkpoint
    manifest['bestValidationMetric'] = trainer.state.best_metric
    manifest['finalValidation'] = trainer.evaluate()
    (output/'preference_manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-model', type=Path, required=True)
    parser.add_argument('--pairs', type=Path, required=True)
    parser.add_argument('--context-cases', type=Path, required=True)
    parser.add_argument('--holdout', type=Path, action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--steps', type=int, default=100)
    parser.add_argument('--lr', type=float, default=1e-6)
    parser.add_argument('--seed', type=int, default=125)
    parser.add_argument('--selection', choices=['loss', 'pair_accuracy', 'pair_quality'], default='loss')
    parser.add_argument('--precision', choices=['fp16', 'fp32'], default='fp16')
    parser.add_argument('--trainable', choices=['all', 'attention'], default='all')
    parser.add_argument('--dropout', type=float,
                        help='GPT2 training dropout override in [0,1); omitted preserves base config')
    parser.add_argument('--anchor', type=float, default=.05,
                        help='chosen NLL weight; zero isolates relative pairwise learning')
    parser.add_argument('--objective', choices=['pair', 'context_gain', 'context_distill'], default='pair')
    parser.add_argument('--teacher-scores', type=Path,
                        help='verified contextual teacher cache; context_distill only')
    parser.add_argument('--prior-preservation', type=float, default=1.)
    parser.add_argument('--deterministic-prior', action='store_true',
                        help='context_distill only: disable dropout for plain preservation forwards, retaining gradients')
    parser.add_argument('--prior-replay', type=Path)
    parser.add_argument('--replay-weight', type=float, default=10.)
    train(parser.parse_args())
