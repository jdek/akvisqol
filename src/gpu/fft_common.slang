// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Shared complex helpers for the Stockham FFT passes.
module fft_common;

public float2 cmul(float2 a, float2 b)
{
    return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

// exp(sign · 2πi · t / n) from a two-level table, s = ceil(log2(n) / 2):
//   tw[j]       = (cos, sin)(2π j / n),        j < 2^s
//   tw[2^s + h] = (cos, sin)(2π h · 2^s / n),  h < n / 2^s
public float2 twiddle(StructuredBuffer<float2> tw, uint t, uint log2_n, float sign)
{
    uint s = (log2_n + 1) >> 1;
    float2 w = cmul(tw[(1u << s) + (t >> s)], tw[t & ((1u << s) - 1)]);
    return float2(w.x, sign * w.y);
}

// sign · i · a
public float2 mul_si(float2 a, float sign)
{
    return float2(-sign * a.y, sign * a.x);
}

// In-place 4-point DFT with kernel exp(sign · 2πi · jk / 4).
public void dft4(inout float2 a0, inout float2 a1, inout float2 a2, inout float2 a3, float sign)
{
    float2 v0 = a0 + a2;
    float2 v1 = a0 - a2;
    float2 v2 = a1 + a3;
    float2 v3 = mul_si(a1 - a3, sign);
    a0 = v0 + v2;
    a1 = v1 + v3;
    a2 = v0 - v2;
    a3 = v1 - v3;
}
