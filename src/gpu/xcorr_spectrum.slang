// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Cross-spectrum of real s1, s2 packed as z = s1 + i·s2: with X = Z[k],
// Y = conj(Z[-k]), writes S1·conj(S2) = (X + Y)·i·conj(X - Y) / 4.
[shader("compute")]
[numthreads(64, 1, 1)]
void xcorr_spectrum(
    uint3 tid: SV_DispatchThreadID,
    uniform StructuredBuffer<float2> z,
    uniform RWStructuredBuffer<float2> out,
    uniform uint log2_n,
    uniform uint total)
{
    uint g = tid.x;
    if (g >= total) return;
    uint n = 1u << log2_n;
    uint base = (g >> log2_n) << log2_n;
    uint k = g & (n - 1);
    float2 x = z[base + k];
    float2 zm = z[base + ((n - k) & (n - 1))];
    float2 s = float2(x.x + zm.x, x.y - zm.y);  // X + Y
    float2 d = float2(x.x - zm.x, x.y + zm.y);  // X - Y
    float2 idc = float2(d.y, d.x);              // i·conj(X - Y)
    out[base + k] = 0.25 * float2(s.x * idc.x - s.y * idc.y, s.x * idc.y + s.y * idc.x);
}
