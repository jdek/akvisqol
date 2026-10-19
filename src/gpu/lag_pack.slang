// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Real s1, s2 (each row's `a` and `b`) into complex rows z = s1 + i·s2,
// zero-padded.
import tables;
import zimt;

[shader("compute")]
[numthreads(64, 1, 1)]
void lag_pack(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<float> signals,
    uniform RO<LagRow> rows,
    uniform RW<float2> z,
    uniform uint log2_n,
    uniform uint total)
{
    uint g = zimt_index(tid);
    if (g >= total) return;
    uint row = g >> log2_n;
    uint t = g & ((1u << log2_n) - 1);
    Side a = rows[row].a;
    Side b = rows[row].b;
    z[g] = float2(t < a.len ? signals[a.start + t] : 0.0, t < b.len ? signals[b.start + t] : 0.0);
}
