// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Radix-4 Stockham pass over contiguous n-point transforms (x -> y).
// Passes with p = 1, R1, R1·R2, ... up to n give natural order.
// sign = -1 forward, +1 inverse (unscaled). One thread per 4 points.
import fft_common;

[shader("compute")]
[numthreads(64, 1, 1)]
void fft_radix4(
    uint3 tid: SV_DispatchThreadID,
    uniform StructuredBuffer<float2> x,
    uniform RWStructuredBuffer<float2> y,
    uniform StructuredBuffer<float2> tw,
    uniform uint log2_n,
    uniform uint p,
    uniform uint total,
    uniform float sign)
{
    uint g = tid.x;
    if (g >= total) return;
    uint n = 1u << log2_n;
    uint q = n >> 2;
    uint base = (g >> (log2_n - 2)) << log2_n;
    uint i = g & (q - 1);
    uint k = i & (p - 1);
    uint ts = q / p; // n / (4p)

    float2 u0 = x[base + i];
    float2 u1 = cmul(x[base + i + q], twiddle(tw, k * ts, log2_n, sign));
    float2 u2 = cmul(x[base + i + 2 * q], twiddle(tw, 2 * k * ts, log2_n, sign));
    float2 u3 = cmul(x[base + i + 3 * q], twiddle(tw, 3 * k * ts, log2_n, sign));
    dft4(u0, u1, u2, u3, sign);

    uint j = base + ((i - k) << 2) + k;
    y[j] = u0;
    y[j + p] = u1;
    y[j + 2 * p] = u2;
    y[j + 3 * p] = u3;
}
