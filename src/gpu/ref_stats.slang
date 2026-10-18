// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Per ref patch cell: mu = conv3x3(ref), srs = conv3x3(ref^2) - mu^2,
// replicate-padded. One thread per (row, cell); reused by `patch_sims`.
//
// rows: (num_rows, 3) u32 — spec offset (row-major [bands, nf]), nf, patch column.
import nsim_common;
import zimt;

[shader("compute")]
[numthreads(64, 1, 1)]
void ref_stats(
    uint3 tid: SV_DispatchThreadID,
    uniform StructuredBuffer<float> spec,
    uniform StructuredBuffer<uint> rows,
    uniform RWStructuredBuffer<float> mu,
    uniform RWStructuredBuffer<float> srs,
    uniform uint num_rows,
    uniform uint num_bands,
    uniform uint patch_size)
{
    uint cells = num_bands * patch_size;
    uint id = zimt_index(tid);
    uint row = id / cells;
    if (row >= num_rows) return;
    uint cell = id % cells;
    int r = int(cell / patch_size);
    int c = int(cell % patch_size);

    uint base = rows[row * 3 + 0];
    uint nf = rows[row * 3 + 1];
    uint col0 = rows[row * 3 + 2];

    float m = 0, sq = 0;
    for (int dr = -1; dr <= 1; dr++) {
        int rr = clamp(r + dr, 0, int(num_bands) - 1);
        for (int dc = -1; dc <= 1; dc++) {
            int cc = clamp(c + dc, 0, int(patch_size) - 1);
            float v = spec[base + uint(rr) * nf + col0 + uint(cc)];
            float w = wgt(dr, dc);
            m += w * v;
            sq += w * (v * v);
        }
    }
    uint o = row * cells + cell;
    mu[o] = m;
    srs[o] = sq - m * m;
}
