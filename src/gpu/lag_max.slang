// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Non-negative floats order like their bits, so the integer max is exact
// and independent of thread order. `top` is zeroed by the host.
import lag_common;
import tables;
import zimt;

[shader("compute")]
[numthreads(64, 1, 1)]
void lag_max(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<float2> corr,
    uniform RO<LagParams> params,
    uniform RW<uint> top,
    uniform uint log2_n,
    uniform uint chunk,
    uniform uint total_chunks)
{
    uint g = zimt_index(tid);
    if (g >= total_chunks) return;
    uint n = 1u << log2_n;
    uint chunks_per_row = n / chunk;
    uint row = g / chunks_per_row;
    uint first = (g % chunks_per_row) * chunk;
    uint max_lag = params[row].max_lag;
    uint m = 0;
    for (uint k = 0; k < chunk; k++) {
        uint i = first + k;
        if (lag_valid(i, n, max_lag)) m = max(m, asuint(lag_abs(corr, row, i, log2_n)));
    }
    if (m != 0) InterlockedMax(top.p[row], m);
}
