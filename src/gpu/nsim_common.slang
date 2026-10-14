// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Mirrors src/visqol/nsim.zig.
module nsim_common;

// 3x3 Gaussian window.
public static const float W_CORNER = 0.0113033910173052;
public static const float W_EDGE = 0.0838251475442633;
public static const float W_CENTER = 0.619485845753726;

public static const float C1 = 0.0001;     // (0.01 * 1.0)^2
public static const float C3 = 0.00045;    // (0.03 * 1.0)^2 / 2

public float wgt(int dr, int dc)
{
    if (dr == 0 && dc == 0) return W_CENTER;
    if (dr == 0 || dc == 0) return W_EDGE;
    return W_CORNER;
}
