// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Non-negative floats order like their bits, so the integer max is exact
// and independent of thread order. `top` is zeroed by the host.
import lag_common;
import zimt;

[shader("compute")]
[numthreads(64, 1, 1)]
void lag_max(
    uint3 tid: SV_DispatchThreadID,
    uniform StructuredBuffer<float2> corr,
    uniform StructuredBuffer<uint> params,
    uniform RWStructuredBuffer<uint> top,
    uniform uint log2_n,
    uniform uint total_chunks)
{
    uint g = zimt_index(tid);
    if (g >= total_chunks) return;
    uint n = 1u << log2_n;
    uint chunks_per_row = n / LAG_CHUNK;
    uint row = g / chunks_per_row;
    uint first = (g % chunks_per_row) * LAG_CHUNK;
    uint max_lag = params[row * 2];
    uint m = 0;
    for (uint k = 0; k < LAG_CHUNK; k++) {
        uint i = first + k;
        if (lag_valid(i, n, max_lag)) m = max(m, asuint(lag_abs(corr, row, i, log2_n)));
    }
    if (m != 0) InterlockedMax(top[row], m);
}
