// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Stockham FFT passes over contiguous n-point transforms (x -> y). Passes
// with p = 1, R1, R1·R2, ... up to n give natural order; sign = -1
// forward, +1 inverse (unscaled). One thread per R points.
import fft_common;
import zimt;

public interface IRadix
{
    static const uint R;
    static const uint LOG2R;
    // In place, outputs in natural order.
    static void dft(inout float2 u[R], float sign);
}

public struct Radix2 : IRadix
{
    static const uint R = 2;
    static const uint LOG2R = 1;
    static void dft(inout float2 u[R], float sign)
    {
        float2 a = u[0];
        u[0] = a + u[1];
        u[1] = a - u[1];
    }
}

public struct Radix4 : IRadix
{
    static const uint R = 4;
    static const uint LOG2R = 2;
    static void dft(inout float2 u[R], float sign)
    {
        dft4(u[0], u[1], u[2], u[3], sign);
    }
}

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

// 4x4 radix-4 butterflies in registers.
public struct Radix16 : IRadix
{
    static const uint R = 16;
    static const uint LOG2R = 4;
    static void dft(inout float2 u[R], float sign)
    {
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
        float2 v[R];
        for (uint k1 = 0; k1 < 4; k1++)
        {
            float2 a0 = u[4 * k1], a1 = u[4 * k1 + 1], a2 = u[4 * k1 + 2], a3 = u[4 * k1 + 3];
            dft4(a0, a1, a2, a3, sign);
            v[k1] = a0;
            v[k1 + 4] = a1;
            v[k1 + 8] = a2;
            v[k1 + 12] = a3;
        }
        u = v;
    }
}

[shader("compute")]
[numthreads(64, 1, 1)]
void fft_pass<T : IRadix>(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<float2> x,
    uniform RW<float2> y,
    uniform RO<float2> tw,
    uniform uint log2_n,
    uniform uint p,
    uniform uint total,
    uniform float sign)
{
    uint g = zimt_index(tid);
    if (g >= total) return;
    uint q = (1u << log2_n) >> T.LOG2R;
    uint base = (g >> (log2_n - T.LOG2R)) << log2_n;
    uint i = g & (q - 1);
    uint k = i & (p - 1);
    uint ts = q / p; // n / (R·p)

    float2 u[T.R];
    u[0] = x[base + i];
    for (uint m = 1; m < T.R; m++)
        u[m] = cmul(x[base + i + m * q], twiddle(tw, m * k * ts, log2_n, sign));
    T.dft(u, sign);

    uint j = base + ((i - k) << T.LOG2R) + k;
    for (uint r = 0; r < T.R; r++)
        y[j + r * p] = u[r];
}
