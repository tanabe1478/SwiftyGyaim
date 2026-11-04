"""Synthetic tests for filtering and the actual preference objective."""
import unittest

import torch

from train_context_preference import split_pairs, mean_completion_scores, preference_loss


class PreferenceTests(unittest.TestCase):
    def test_equivalent_readings_share_normalized_split_and_deduplication(self):
        rows = [dict(input='unused', inputKana=reading, context='作業を',
                     chosen='更新', rejected='行進', source='public-corpus-dictionary-contrast')
                for reading in ('が', 'ガ', 'カ\u3099')]
        train, valid, stats = split_pairs(rows, set(), None)
        self.assertEqual(len(train) + len(valid), 1)
        self.assertEqual((train + valid)[0]['input'], 'ガ')
        self.assertEqual(stats['duplicate'], 2)
        rows[0].update(chosen='ガ', rejected='カ\u3099')
        train, valid, stats = split_pairs(rows[:1], set(), None)
        self.assertEqual(train + valid, [])
        self.assertEqual(stats['invalid'], 1)

    def test_context_gain_separates_context_from_word_prior(self):
        from train_context_preference import context_gain_loss
        reference = torch.tensor([[-1., -3., -2.]])
        scores = torch.tensor([-2., -1., -3., -2.], requires_grad=True)
        loss = context_gain_loss(scores, reference)
        self.assertAlmostEqual(loss.item(), torch.log(torch.tensor(2.)).item(), places=6)
        loss.backward()
        self.assertLess(scores.grad[0].item(), 0)
        self.assertGreater(scores.grad[1].item(), 0)
        # Equal candidate-specific changes with and without context do not
        # improve contextual gain; the preservation term penalizes them.
        prior_shift = torch.tensor([.5, -.5, .5, -.5])
        shifted = context_gain_loss(scores.detach()+prior_shift, reference)
        self.assertAlmostEqual((shifted-loss).item(), .25, places=6)
        contextual_improvement = scores.detach()+torch.tensor([.5, -.5, 0., 0.])
        self.assertLess(context_gain_loss(contextual_improvement, reference).item(), loss.item())
        drift = (scores.detach()+prior_shift).requires_grad_()
        context_gain_loss(drift, reference, preservation=10).backward()
        self.assertGreater(drift.grad[2].item(), 0)
        self.assertLess(drift.grad[3].item(), 0)
        with self.assertRaises(ValueError):
            context_gain_loss(scores, reference[:, :2])

    def test_four_sequence_collation_preserves_prompt_spans_and_pair_order(self):
        from train_context_preference import collate_preference_examples
        example = dict(sequences=[[1,2,3,4], [1,2,5], [6,3,4], [6,5]],
                       promptLengths=[2,2,1,1], reference_delta=[-1.,-3.,-2.])
        batch = collate_preference_examples([example, example], 0)
        self.assertEqual(batch['input_ids'].shape, (8,4))
        self.assertEqual(batch['completion_mask'].sum(1).tolist(), [2,1,2,1]*2)
        self.assertEqual(batch['attention_mask'].sum(1).tolist(), [4,3,3,2]*2)
        self.assertEqual(batch['reference_delta'].tolist(), [[-1.,-3.,-2.]]*2)
        self.assertEqual(batch['input_ids'][3].tolist(), [6,5,0,0])

    def test_attention_training_keeps_embeddings_mlp_and_layer_norms_fixed(self):
        from transformers import GPT2Config, GPT2LMHeadModel
        from train_context_preference import configure_trainable_parameters
        torch.manual_seed(125)
        model = GPT2LMHeadModel(GPT2Config(vocab_size=16, n_positions=16, n_embd=8,
                                          n_layer=2, n_head=2, resid_pdrop=0.,
                                          embd_pdrop=0., attn_pdrop=0.))
        stats = configure_trainable_parameters(model, 'attention')
        before = {n:p.detach().clone() for n,p in model.named_parameters()}
        optimizer = torch.optim.SGD([p for p in model.parameters() if p.requires_grad], lr=.1)
        ids = torch.tensor([[1, 2, 3, 4], [1, 2, 3, 5]])
        mask = torch.tensor([[False, False, False, True]]*2)
        loss = preference_loss(mean_completion_scores(model(ids).logits, ids, mask), torch.zeros(1))
        loss.backward()
        optimizer.step()
        changed = {n for n,p in model.named_parameters() if not torch.equal(before[n], p)}
        self.assertTrue(changed)
        self.assertTrue(changed.issubset(set(stats['trainableParameterNames'])))
        self.assertLess(stats['trainableParameters'], stats['totalParameters'])
        self.assertFalse(model.get_input_embeddings().weight.requires_grad)
        self.assertEqual(model.get_input_embeddings().weight.data_ptr(),
                         model.get_output_embeddings().weight.data_ptr())
        for n,p in model.named_parameters():
            if n not in stats['trainableParameterNames']:
                self.assertIsNone(p.grad)
                self.assertTrue(torch.equal(before[n], p))
        configure_trainable_parameters(model, 'all')
        self.assertTrue(all(p.requires_grad for p in model.parameters()))

    def test_mined_negatives_are_distinct_from_observed_preferences(self):
        from build_context_contrasts import mine
        class Converter:
            def convert(self, text):
                return text
        source = [dict(input='シヨウ', output='仕様', left_context='このシステムの詳細な動作の')]
        pairs, stats = mine(source, {('シヨウ', '仕様'): {'使用', '私用'}}, {('シヨウ', '私用')})
        self.assertEqual(stats['pairs'], 1)
        self.assertEqual(pairs[0]['rejected'], '使用')
        self.assertNotIn('rejectedRank', pairs[0])
        train, valid, _ = split_pairs(pairs, set(), Converter())
        self.assertEqual(len(train+valid), 1)
        train, valid, _ = split_pairs(pairs, {('シヨウ', '使用')}, Converter())
        self.assertFalse(train+valid)

    def test_both_sides_excluded_and_reading_groups_kept_together(self):
        class Converter:
            def convert(self, text):
                return text
        rows = [dict(input=f'カナ{i}', context='合成文脈', chosen=f'選択{i}', rejected=f'先頭{i}',
                     chosenRank=2, rejectedRank=1) for i in range(50)]
        rows += [dict(r, chosen=r['rejected'], rejected=r['chosen']) for r in rows]
        train, valid, stats = split_pairs(rows, {('カナ0', '先頭0'), ('カナ1', '選択1')}, Converter())
        self.assertTrue(train and valid)
        self.assertFalse({r['input'] for r in train} & {r['input'] for r in valid})
        self.assertEqual(stats['holdoutOverlap'], 4)
        self.assertNotIn('カナ0', {r['input'] for r in train+valid})
        self.assertNotIn('カナ1', {r['input'] for r in train+valid})

    def test_prompt_padding_and_length_normalization(self):
        ids = torch.tensor([[0, 1, 2, 3], [0, 2, 1, 0]])
        logits = torch.zeros(2, 4, 5)
        mask = torch.tensor([[False, False, True, True], [False, True, False, False]])
        expected = torch.full((2,), -torch.log(torch.tensor(5.)).item())
        self.assertTrue(torch.allclose(mean_completion_scores(logits, ids, mask), expected))
        logits[0, 0] = torch.tensor([20., 0., 0., 0., 0.])  # excluded prompt prediction
        logits[1, 1:] = 50.  # padding / positions outside the completion
        self.assertTrue(torch.allclose(mean_completion_scores(logits, ids, mask), expected))
        with self.assertRaises(ValueError):
            mean_completion_scores(logits, ids, torch.zeros_like(mask))

    def test_loss_pushes_chosen_up_rejected_down(self):
        scores = torch.tensor([-2., -1.], requires_grad=True)
        reference = torch.tensor([-1.])
        loss = preference_loss(scores, reference)
        loss.backward()
        self.assertLess(scores.grad[0].item(), 0)
        self.assertGreater(scores.grad[1].item(), 0)
        better = preference_loss(torch.tensor([-1., -2.]), reference)
        self.assertLess(better.item(), loss.item())
        no_anchor = preference_loss(scores.detach(), reference, anchor=0)
        self.assertAlmostEqual(no_anchor.item(), torch.log(torch.tensor(2.)).item(), places=6)

    def test_zero_anchor_has_no_common_score_shift_incentive(self):
        scores = torch.tensor([-2., -1.], requires_grad=True)
        reference = torch.tensor([-1.])
        loss = preference_loss(scores, reference, anchor=0)
        loss.backward()
        self.assertAlmostEqual(scores.grad.sum().item(), 0., places=6)
        shifted = preference_loss(scores.detach()+.5, reference, anchor=0)
        self.assertAlmostEqual(loss.item(), shifted.item(), places=6)
        anchored = preference_loss(scores.detach(), reference, anchor=.05)
        shifted_anchored = preference_loss(scores.detach()+.5, reference, anchor=.05)
        self.assertAlmostEqual((anchored-shifted_anchored).item(), .025, places=6)
        for invalid in [-.1, float('nan'), float('inf')]:
            with self.assertRaises(ValueError):
                preference_loss(scores.detach(), reference, anchor=invalid)


class ReplayPreservationTests(unittest.TestCase):
    def test_replay_gradient_restores_reference_without_changing_pair_loss(self):
        from train_context_preference import replay_context_gain_loss, context_gain_loss
        scores = torch.tensor([[-1., -2., -3., -4., -2.5]], requires_grad=True)
        reference = torch.tensor([[1., -3., -4., -3.]])
        loss = replay_context_gain_loss(scores, reference, 10., 10.)
        base = context_gain_loss(scores[:, :4], reference[:, :3], 10.)
        self.assertAlmostEqual((loss-base).item(), 2.5, places=5)
        loss.backward()
        self.assertAlmostEqual(scores.grad[0, 4].item(), 10., places=5)
        exact = scores.detach().clone(); exact[0, 4] = -3.
        self.assertAlmostEqual(replay_context_gain_loss(exact, reference, 10., 10.).item(), base.item(), places=5)
        with self.assertRaises(ValueError):
            replay_context_gain_loss(scores, reference[:, :3], 10., 10.)


class TrainingDropoutTests(unittest.TestCase):
    def test_override_validation_and_default_preservation(self):
        from types import SimpleNamespace
        from train_context_preference import configure_training_dropout
        config = SimpleNamespace(model_type='gpt2', attn_pdrop=.1, embd_pdrop=.2, resid_pdrop=.3)
        info = configure_training_dropout(config)
        self.assertEqual(info['original'], info['effective'])
        for value in (-.1, 1., float('nan'), float('inf')):
            with self.assertRaises(ValueError): configure_training_dropout(config, value)
        self.assertEqual(config.attn_pdrop, .1)
        with self.assertRaises(ValueError):
            configure_training_dropout(SimpleNamespace(model_type='other'), 0.)

    def test_zero_dropout_is_deterministic_trainable_and_persisted(self):
        import copy
        import tempfile
        from transformers import GPT2Config, GPT2LMHeadModel
        from train_context_preference import configure_training_dropout
        torch.manual_seed(125)
        config = GPT2Config(vocab_size=32, n_positions=16, n_embd=8, n_layer=1, n_head=2,
                            attn_pdrop=.3, embd_pdrop=.3, resid_pdrop=.3, use_cache=False)
        original = GPT2LMHeadModel(config).eval()
        revised = copy.deepcopy(config)
        configure_training_dropout(revised, 0.)
        model = GPT2LMHeadModel(revised).eval()
        model.load_state_dict(original.state_dict())
        ids = torch.tensor([[3,4,5,6]])
        with torch.no_grad():
            expected = original(ids).logits
            self.assertTrue(torch.allclose(expected, model(ids).logits, atol=1e-7))
        model.train()
        first = model(ids).logits
        self.assertTrue(torch.equal(first, model(ids).logits))
        self.assertTrue(torch.allclose(first, expected, atol=1e-7))
        torch.nn.functional.cross_entropy(first[:,:-1].reshape(-1,32),ids[:,1:].reshape(-1)).backward()
        self.assertTrue(torch.isfinite(model.transformer.wte.weight.grad).all())
        self.assertGreater(model.transformer.wte.weight.grad.abs().sum().item(), 0.)
        with tempfile.TemporaryDirectory() as directory:
            model.save_pretrained(directory)
            loaded = GPT2LMHeadModel.from_pretrained(directory).train()
            self.assertTrue(all(m.p == 0 for m in loaded.modules() if isinstance(m, torch.nn.Dropout)))
            self.assertTrue(torch.allclose(loaded(ids).logits, first, atol=1e-7))


class ContextDistillationTests(unittest.TestCase):
    def test_teacher_can_favor_either_candidate_and_has_no_gradient(self):
        from context_distillation import context_distillation_loss
        for teacher_margin in (-2., 2.):
            scores=torch.tensor([-2.,-2.,-3.,-4.],requires_grad=True)
            reference=torch.tensor([[teacher_margin,-3.,-4.]],requires_grad=True)
            loss=context_distillation_loss(scores,reference,10.)
            loss.backward()
            self.assertLess(scores.grad[0].item()*teacher_margin,0)
            self.assertGreater(scores.grad[1].item()*teacher_margin,0)
            self.assertTrue(torch.equal(scores.grad[2:],torch.zeros(2)))
            self.assertIsNone(reference.grad)

    def test_matching_teacher_is_stationary_and_plain_drift_is_penalized(self):
        from context_distillation import context_distillation_loss
        reference=torch.tensor([[1.,-3.,-4.]])
        scores=torch.tensor([-1.,-2.,-3.,-4.],requires_grad=True)
        original=context_distillation_loss(scores,reference,10.)
        original.backward()
        self.assertTrue(torch.allclose(scores.grad,torch.zeros(4),atol=1e-7))
        shifted=scores.detach()+torch.tensor([.5,.5,.5,-.5])
        shifted.requires_grad_()
        loss=context_distillation_loss(shifted,reference,10.)
        self.assertAlmostEqual((loss-original).item(),2.5,places=5)
        loss.backward()
        self.assertGreater(shifted.grad[2].item(),0)
        self.assertLess(shifted.grad[3].item(),0)
        for invalid in (0.,-1.,float('nan'),float('inf')):
            with self.assertRaises(ValueError): context_distillation_loss(scores,reference,invalid)
        with self.assertRaises(ValueError): context_distillation_loss(scores,reference[:,:2])
        with self.assertRaises(ValueError): context_distillation_loss(scores,reference*float('nan'))

    def test_teacher_cache_requires_exact_finite_coverage_and_matching_source(self):
        import json
        import tempfile
        from pathlib import Path
        from context_distillation import pair_fingerprint,load_teacher_margins
        rows=[dict(input='カナ',context='合成文脈',chosen='甲',rejected='乙')]
        key=pair_fingerprint(rows[0])
        self.assertNotEqual(key,pair_fingerprint(dict(rows[0],context='別の合成文脈')))
        self.assertNotEqual(key,pair_fingerprint(dict(rows[0],chosen='乙',rejected='甲')))
        cache=dict(formatVersion=1,pairsSha256='a'*64,precision='fp32',textPreprocessing='hf',
                   teacherModel='synthetic',teacherWeightsSha256='b'*64,
                   records=[dict(pairHash=key,contextMargin=-.5)])
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'cache.json'
            def write(value): path.write_text(json.dumps(value),encoding='utf8')
            write(cache)
            margins,_=load_teacher_margins(path,rows,'a'*64)
            self.assertEqual(margins,{key:-.5})
            with self.assertRaises(ValueError): load_teacher_margins(path,rows,'c'*64)
            mutations=[]
            for records in ([],cache['records']*2,[dict(pairHash='d'*64,contextMargin=1.)],
                            [dict(pairHash=key,contextMargin=float('nan'))],
                            [dict(pairHash=key,contextMargin=True)]):
                mutations.append(dict(cache,records=records))
            mutations.extend([dict(cache,precision='fp16'),dict(cache,textPreprocessing='native-whitespace'),
                              dict(cache,teacherWeightsSha256=None)])
            for value in mutations:
                write(value)
                with self.assertRaises(ValueError): load_teacher_margins(path,rows,'a'*64)


if __name__ == '__main__':
    unittest.main()
