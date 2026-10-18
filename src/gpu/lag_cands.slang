// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Lags whose |re| reaches top - slack (f32, as `refineLag`), unordered:
// the first `cap` per row go to `cands`, `count` has them all.
import lag_common;
import zimt;

[shader("compute")]
[numthreads(64, 1, 1)]
void lag_cands(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<float2> corr,
    uniform RO<uint> params,
    uniform RO<uint> top,
    uniform RW<uint> count,
    uniform RW<int> cands,
    uniform uint log2_n,
    uniform uint total_chunks,
    uniform uint cap)
{
    uint g = zimt_index(tid);
    if (g >= total_chunks) return;
    uint n = 1u << log2_n;
    uint chunks_per_row = n / LAG_CHUNK;
    uint row = g / chunks_per_row;
    uint first = (g % chunks_per_row) * LAG_CHUNK;
    uint max_lag = params[row * 2];
    float floor = asfloat(top[row]) - asfloat(params[row * 2 + 1]);
    for (uint k = 0; k < LAG_CHUNK; k++) {
        uint i = first + k;
        if (!lag_valid(i, n, max_lag) || !(lag_abs(corr, row, i, log2_n) >= floor)) continue;
        uint slot;
        InterlockedAdd(count.p[row], 1u, slot);
        if (slot < cap) cands[row * cap + slot] = i <= max_lag ? int(i) : int(i) - int(n);
    }
}
