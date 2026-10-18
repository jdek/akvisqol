// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// `lag_max` then `lag_cands` reproduce `xcorr.refineLag`'s candidate set
// on the device. Each thread scans LAG_CHUNK entries.
//
// params: (rows, 2) u32 — max_lag, slack (f32 bits).
module lag_common;

import zimt;

public static const uint LAG_CHUNK = 64;

public bool lag_valid(uint i, uint n, uint max_lag)
{
    return i <= max_lag || i >= n - max_lag;
}

public float lag_abs(RO<float2> corr, uint row, uint i, uint log2_n)
{
    return abs(corr[(row << log2_n) + i].x);
}
