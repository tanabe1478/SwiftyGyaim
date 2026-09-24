"""Small bidirectional encoder + permutation-equivariant candidate-set classifier."""
import math

import torch
from torch import nn
from common import validate_config


class Block(nn.Module):
    def __init__(self, d, heads, dropout):
        super().__init__()
        self.heads, self.width = heads, d // heads
        self.norm1, self.norm2 = nn.LayerNorm(d), nn.LayerNorm(d)
        self.qkv, self.proj = nn.Linear(d, 3 * d), nn.Linear(d, d)
        self.ff = nn.Sequential(nn.Linear(d, 4 * d), nn.GELU(), nn.Dropout(dropout), nn.Linear(4 * d, d))
        self.drop = nn.Dropout(dropout)

    def forward(self, x, mask):
        b, length, d = x.shape
        q, k, v = self.qkv(self.norm1(x)).reshape(b, length, 3, self.heads, self.width).permute(2, 0, 3, 1, 4).unbind(0)
        scores = torch.matmul(q, k.transpose(-1, -2)) / math.sqrt(self.width)
        scores = scores.masked_fill(~mask[:, None, None, :], -10000)
        weights = scores.float().softmax(-1).to(v.dtype)
        y = torch.matmul(weights, v).transpose(1, 2).reshape(b, length, d)
        x = x + self.drop(self.proj(y))
        return x + self.drop(self.ff(self.norm2(x)))


class Encoder(nn.Module):
    def __init__(self, vocab, d, layers, heads, max_length, dropout):
        super().__init__()
        self.token = nn.Embedding(vocab, d)
        self.position = nn.Embedding(max_length, d)
        self.segment = nn.Embedding(3, d)
        self.blocks = nn.ModuleList([Block(d, heads, dropout) for _ in range(layers)])
        self.norm = nn.LayerNorm(d)

    def forward(self, ids, segments, mask):
        x = self.token(ids) + self.segment(segments) + self.position(torch.arange(ids.shape[1], device=ids.device))[None]
        for block in self.blocks:
            x = block(x, mask)
        x = self.norm(x)
        weights = mask.to(x.dtype).unsqueeze(-1)
        return (x * weights).sum(1) / weights.sum(1).clamp(min=1)


class DecisionModel(nn.Module):
    def __init__(self, config):
        super().__init__()
        validate_config(config)
        self.config = config
        m, data = config['model'], config['data']
        d = m['hidden_size']
        args = (m['vocab_size'], d, m['layers'], m['heads'], max(data['max_context_tokens'], data['max_candidate_tokens']), m['dropout'])
        self.state_encoder = Encoder(*args)
        self.candidate_encoder = Encoder(*args) if m['separate_encoder'] else None
        self.source, self.kind = nn.Embedding(7, 16), nn.Embedding(8, 16)
        self.metadata = nn.Linear(40, d)
        self.combine = nn.Sequential(nn.Linear(d * 4, d), nn.GELU(), nn.LayerNorm(d))
        self.none = nn.Parameter(torch.zeros(1, 1, d))
        self.interaction = Block(d, m['heads'], m['dropout'])
        self.score = nn.Linear(d, 1)
        self.none_score = nn.Linear(d, 1)
        mode = m.get('metadata', 'all')
        numeric = {'text': [0]*8, 'source_kind': [0]*8, 'frequency': [0,1,0,0,0,1,0,0],
                   'affinity': [0,0,1,0,0,0,1,0], 'all': [1]*8}[mode]
        self.register_buffer('numeric_gate', torch.tensor(numeric, dtype=torch.float32))
        self.category_enabled = mode in ('all', 'source_kind')

    def forward(self, state_ids, state_segments, state_mask, candidate_ids, candidate_segments,
                token_mask, candidate_mask, categories, numeric):
        state = self.state_encoder(state_ids, state_segments, state_mask)
        b, n, t = candidate_ids.shape
        encoder = self.candidate_encoder if self.candidate_encoder is not None else self.state_encoder
        cand = encoder(candidate_ids.reshape(b*n, t), candidate_segments.reshape(b*n, t), token_mask.reshape(b*n, t)).reshape(b, n, -1)
        cat = torch.cat([self.source(categories[:, :, 0]), self.kind(categories[:, :, 1])], -1)
        cat = cat * float(self.category_enabled)
        meta = self.metadata(torch.cat([cat, numeric * self.numeric_gate], -1))
        state_set = state[:, None].expand(-1, n, -1)
        features = self.combine(torch.cat([cand, state_set, cand * state_set, meta], -1))
        features = torch.cat([features, state[:, None] + self.none], 1)
        mask = torch.cat([candidate_mask, torch.ones_like(candidate_mask[:, :1])], 1)
        features = self.interaction(features, mask)
        logits = self.score(features[:, :-1]).squeeze(-1).float().masked_fill(~candidate_mask, -10000)
        return torch.cat([logits, self.none_score(features[:, -1]).float()], -1)


def loss(logits, target):
    return nn.functional.cross_entropy(logits.float(), target)
