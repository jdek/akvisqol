// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Radix-16 Stockham pass (see fft_radix4.slang) as 4x4 radix-4 butterflies
// in registers. One thread per 16 points.
import fft_common;
import zimt;

// (cos, sin)(2π j / 16), j <= 3·3.
static const float2 W16[10] = {
    float2(1.0, 0.0),
    float2(0.92387953251128674, 0.38268343236508978),
    float2(0.70710678118654752, 0.70710678118654752),
    float2(0.38268343236508978, 0.92387953251128674),
    float2(0.0, 1.0),
    float2(-0.38268343236508978, 0.92387953251128674),
    float2(-0.70710678118654752, 0.70710678118654752),
    float2(-0.92387953251128674, 0.38268343236508978),
    float2(-1.0, 0.0),
    float2(-0.92387953251128674, -0.38268343236508978),
};

[shader("compute")]
[numthreads(64, 1, 1)]
void fft_radix16(
    uint3 tid: SV_DispatchThreadID,
    uniform StructuredBuffer<float2> x,
    uniform RWStructuredBuffer<float2> y,
    uniform StructuredBuffer<float2> tw,
    uniform uint log2_n,
    uniform uint p,
    uniform uint total,
    uniform float sign)
{
    uint g = zimt_index(tid);
    if (g >= total) return;
    uint n = 1u << log2_n;
    uint q = n >> 4;
    uint base = (g >> (log2_n - 4)) << log2_n;
    uint i = g & (q - 1);
    uint k = i & (p - 1);
    uint ts = q / p; // n / (16p)

    float2 u[16];
    u[0] = x[base + i];
    for (uint m = 1; m < 16; m++)
        u[m] = cmul(x[base + i + m * q], twiddle(tw, m * k * ts, log2_n, sign));

    // m = 4·m1 + m2: DFT4 over m1, twiddle W16^(m2·k1), DFT4 over m2.
    for (uint m2 = 0; m2 < 4; m2++)
    {
        dft4(u[m2], u[m2 + 4], u[m2 + 8], u[m2 + 12], sign);
        for (uint k1 = 1; k1 < 4; k1++)
        {
            float2 w = W16[m2 * k1];
            u[m2 + 4 * k1] = cmul(u[m2 + 4 * k1], float2(w.x, sign * w.y));
        }
    }
    uint j = base + ((i - k) << 4) + k;
    for (uint k1 = 0; k1 < 4; k1++)
    {
        float2 a0 = u[4 * k1], a1 = u[4 * k1 + 1], a2 = u[4 * k1 + 2], a3 = u[4 * k1 + 3];
        dft4(a0, a1, a2, a3, sign);
        y[j + k1 * p] = a0;
        y[j + (k1 + 4) * p] = a1;
        y[j + (k1 + 8) * p] = a2;
        y[j + (k1 + 12) * p] = a3;
    }
}
