"""Verify mixed-mode scoring preserves gradients, ordering, and module states."""
import unittest
from unittest.mock import patch
import torch
from transformers import GPT2Config, GPT2LMHeadModel
from train_context_preference import distillation_scores, collate_preference_examples


class DeterministicPriorTests(unittest.TestCase):
    def setUp(self):
        torch.manual_seed(125)
        torch.set_num_threads(2)
        self.model = GPT2LMHeadModel(GPT2Config(vocab_size=16, n_positions=16,
            n_embd=8, n_layer=1, n_head=2, resid_pdrop=.4, embd_pdrop=.4, attn_pdrop=.4))
        example = dict(sequences=[[1,2,3,4], [1,2,5], [6,3,4], [6,5]],
                       promptLengths=[2,2,1,1], reference_delta=[0.,0.,0.])
        self.batch = collate_preference_examples([example, example], 0)

    def test_plain_is_deterministic_context_stochastic_and_both_have_gradients(self):
        self.model.eval()
        baseline = distillation_scores(self.model, self.batch).detach().reshape(-1,4)
        self.model.train()
        first = distillation_scores(self.model, self.batch, True).reshape(-1,4)
        second = distillation_scores(self.model, self.batch, True).reshape(-1,4)
        torch.testing.assert_close(first[:,2:], baseline[:,2:])
        torch.testing.assert_close(first[:,2:], second[:,2:])
        self.assertFalse(torch.equal(first[:,:2], second[:,:2]))
        for scores in (first[:,:2], first[:,2:]):
            grad = torch.autograd.grad(scores.sum(), self.model.transformer.wte.weight,
                                       retain_graph=True)[0]
            self.assertTrue(torch.isfinite(grad).all())
            self.assertGreater(grad.norm().item(), 0)
        self.assertTrue(all(m.training for m in self.model.modules()))
        self.model.eval()
        torch.testing.assert_close(distillation_scores(self.model, self.batch, True).reshape(-1,4), baseline)

    def test_restores_individual_modes_after_plain_forward_error(self):
        self.model.train()
        self.model.transformer.h[0].attn.resid_dropout.eval()
        modes = [m.training for m in self.model.modules()]
        original = self.model.forward
        def fail_in_eval(*args, **kwargs):
            if not self.model.training:
                raise RuntimeError('synthetic failure')
            return original(*args, **kwargs)
        with patch.object(self.model, 'forward', side_effect=fail_in_eval):
            with self.assertRaisesRegex(RuntimeError, 'synthetic failure'):
                distillation_scores(self.model, self.batch, True)
        self.assertEqual(modes, [m.training for m in self.model.modules()])

    def test_rejects_checkpointing_for_mode_sensitive_recomputation(self):
        self.model.train()
        self.model.gradient_checkpointing_enable()
        with self.assertRaisesRegex(ValueError, 'checkpointing'):
            distillation_scores(self.model, self.batch, True)


if __name__ == '__main__':
    unittest.main()
