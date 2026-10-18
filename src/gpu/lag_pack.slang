// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Real s1, s2 into complex rows z = s1 + i·s2, zero-padded.
//
// jobs: (rows, 4) u32 — s1 offset, s1 length, s2 offset, s2 length.
import zimt;

[shader("compute")]
[numthreads(64, 1, 1)]
void lag_pack(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<float> signals,
    uniform RO<uint> jobs,
    uniform RW<float2> z,
    uniform uint log2_n,
    uniform uint total)
{
    uint g = zimt_index(tid);
    if (g >= total) return;
    uint row = g >> log2_n;
    uint t = g & ((1u << log2_n) - 1);
    uint s1 = jobs[row * 4 + 0];
    uint s2 = jobs[row * 4 + 2];
    z[g] = float2(t < jobs[row * 4 + 1] ? signals[s1 + t] : 0.0,
                  t < jobs[row * 4 + 3] ? signals[s2 + t] : 0.0);
}
