// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// `lag_max` then `lag_cands` reproduce `xcorr.refineLag`'s candidate set
// on the device. Each thread scans `chunk` entries (dividing n).
module lag_common;

import zimt;

public bool lag_valid(uint i, uint n, uint max_lag)
{
    return i <= max_lag || i >= n - max_lag;
}

public float lag_abs(RO<float2> corr, uint row, uint i, uint log2_n)
{
    return abs(corr[(row << log2_n) + i].x);
}
