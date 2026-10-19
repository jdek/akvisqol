// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Fast lags: after `lag_max`, the first lag whose f32 |re| is the row's
// maximum, in `xcorr.bestLagCached`'s order (most negative first), without
// rescoring. `keys` (zeroed) collects ~order through an integer max.
import lag_common;
import tables;
import zimt;

[shader("compute")]
[numthreads(64, 1, 1)]
void lag_first(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<float2> corr,
    uniform RO<LagParams> params,
    uniform RO<uint> top,
    uniform RW<uint> keys,
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
    uint best = 0xffffffff;
    for (uint k = 0; k < chunk; k++) {
        uint i = first + k;
        if (!lag_valid(i, n, max_lag) || asuint(lag_abs(corr, row, i, log2_n)) != top[row]) continue;
        best = min(best, i >= n - max_lag ? i - (n - max_lag) : i + max_lag);
    }
    if (best != 0xffffffff) InterlockedMax(keys.p[row], ~best);
}

[shader("compute")]
[numthreads(64, 1, 1)]
void lag_fast_pick(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<LagParams> params,
    uniform RO<uint> keys,
    uniform RW<int> lags,
    uniform RW<uint> status,
    uniform uint first,
    uniform uint num_rows)
{
    uint row = zimt_index(tid);
    if (row >= num_rows) return;
    lags[first + row] = int(~keys[row]) - int(params[row].max_lag);
    status[first + row] = 0;
}
