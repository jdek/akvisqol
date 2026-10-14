// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Radix-2 Stockham pass (see fft_radix4.slang), only when log2(n) is odd.
import fft_common;

[shader("compute")]
[numthreads(64, 1, 1)]
void fft_radix2(
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
    uint h = n >> 1;
    uint base = (g >> (log2_n - 1)) << log2_n;
    uint i = g & (h - 1);
    uint k = i & (p - 1);

    float2 u0 = x[base + i];
    float2 u1 = cmul(x[base + i + h], twiddle(tw, k * (h / p), log2_n, sign));
    uint j = base + ((i - k) << 1) + k;
    y[j] = u0 + u1;
    y[j + p] = u0 - u1;
}
