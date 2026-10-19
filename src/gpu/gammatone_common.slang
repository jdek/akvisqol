// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Gammatone RMS of one windowed frame in one band, in REAL.
//
// EXACT (f64): `filterBandRmsFresh` in gammatone.zig operation for
// operation, so built without contraction it matches the CPU.
//   coeffs: (num_bands, 10) — s1n0, s1n1, s2n1, s3n1, s4n1, a0, d1, d2.
//
// BALANCED (f32): the EXACT form in two-float arithmetic (df.slang), from
// hi + lo samples, hann (hann[window_size + i] the lo parts) and
// coefficients (coeffs[band * 20 + 10 + k] the lo parts), rounded to f32
// at the end.
//
// Otherwise (f32): each biquad stage in delta form, since low-band poles
// near z = 1 make the direct f32 recursion lose ~1/(1 - r)^2 to
// cancellation:
//   dy = dy[n-1] + c2·dy[n-1] - e·y[n-1] + n0·dx + m1·x[n-1] + n2·x[n-2]
// with c2 = d2 - 1, e = 1 + d1 + d2, m1 = n0 + n1 formed in f64 on the
// host; each stage's (y, dy) is the next one's (x, dx), and the square
// sum is blocked to keep error ~sqrt(n)·eps.
//   coeffs: (num_bands, 10) — stage 1 n0, m1, n2; m1 for stages 2-4; c2; e;
//           n0, n2 for stages 2-4.
module gammatone_common;

import df;
import zimt;

public typealias real = REAL;

#if BALANCED
public typealias Sample = DF;
#else
public typealias Sample = real;
#endif

public interface IFrame
{
    Sample at(uint i);
}

public real gammatone_rms<F : IFrame>(F frame, uint band, RO<real> coeffs, RO<real> hann, uint window_size)
{
#if BALANCED
    uint o = band * 20;
    DF s1n0 = DF(coeffs[o + 0], coeffs[o + 10]);
    DF s1n1 = DF(coeffs[o + 1], coeffs[o + 11]);
    DF s2n1 = DF(coeffs[o + 2], coeffs[o + 12]);
    DF s3n1 = DF(coeffs[o + 3], coeffs[o + 13]);
    DF s4n1 = DF(coeffs[o + 4], coeffs[o + 14]);
    DF ca0 = DF(coeffs[o + 5], coeffs[o + 15]);
    DF d1 = DF(coeffs[o + 6], coeffs[o + 16]);
    DF d2 = DF(coeffs[o + 7], coeffs[o + 17]);
    DF s1c0 = DF(0), s1c1 = DF(0), s2c0 = DF(0), s2c1 = DF(0), s3c0 = DF(0), s3c1 = DF(0), s4c0 = DF(0), s4c1 = DF(0);
    DF sum_sq = DF(0);
    for (uint i = 0; i < window_size; i++) {
        DF s = mul(frame.at(i), DF(hann[i], hann[window_size + i]));
        DF f1 = add(mul(s1n0, s), s1c0);
        s1c0 = sub(add(mul(s1n1, s), s1c1), mul(d1, f1));
        s1c1 = neg(mul(d2, f1));
        DF f2 = add(mul(ca0, f1), s2c0);
        s2c0 = sub(add(mul(s2n1, f1), s2c1), mul(d1, f2));
        s2c1 = neg(mul(d2, f2));
        DF f3 = add(mul(ca0, f2), s3c0);
        s3c0 = sub(add(mul(s3n1, f2), s3c1), mul(d1, f3));
        s3c1 = neg(mul(d2, f3));
        DF f4 = add(mul(ca0, f3), s4c0);
        s4c0 = sub(add(mul(s4n1, f3), s4c1), mul(d1, f4));
        s4c1 = neg(mul(d2, f4));
        sum_sq = add(sum_sq, mul(f4, f4));
    }
    // sqrt(sum_sq / n): mean in two-float, the root needs f32 only.
    float n = float(window_size);
    float q = sum_sq.hi / n;
    DF r = sub(sum_sq, mul(DF(q), DF(n)));
    return sqrt(q + r.value() / n);
#else
    uint o = band * 10;
#if EXACT
    real s1n0 = coeffs[o + 0];
    real s1n1 = coeffs[o + 1];
    real s2n1 = coeffs[o + 2];
    real s3n1 = coeffs[o + 3];
    real s4n1 = coeffs[o + 4];
    real ca0 = coeffs[o + 5];
    real d1 = coeffs[o + 6];
    real d2 = coeffs[o + 7];
    real s1c0 = 0, s1c1 = 0, s2c0 = 0, s2c1 = 0, s3c0 = 0, s3c1 = 0, s4c0 = 0, s4c1 = 0;
    real sum_sq = 0;
    for (uint i = 0; i < window_size; i++) {
        real s = frame.at(i) * hann[i];
        real f1 = s1n0 * s + s1c0;
        s1c0 = s1n1 * s + s1c1 - d1 * f1;
        s1c1 = -(d2 * f1);
        real f2 = ca0 * f1 + s2c0;
        s2c0 = s2n1 * f1 + s2c1 - d1 * f2;
        s2c1 = -(d2 * f2);
        real f3 = ca0 * f2 + s3c0;
        s3c0 = s3n1 * f2 + s3c1 - d1 * f3;
        s3c1 = -(d2 * f3);
        real f4 = ca0 * f3 + s4c0;
        s4c0 = s4n1 * f3 + s4c1 - d1 * f4;
        s4c1 = -(d2 * f4);
        sum_sq += f4 * f4;
    }
    real inv_n = real(1) / real(window_size);
    return sqrt(sum_sq * inv_n);
#else
    real s1n0 = coeffs[o + 0];
    real s1m1 = coeffs[o + 1];
    real s1n2 = coeffs[o + 2];
    real s2m1 = coeffs[o + 3];
    real s3m1 = coeffs[o + 4];
    real s4m1 = coeffs[o + 5];
    real c2 = coeffs[o + 6];
    real e = coeffs[o + 7];
    real n0 = coeffs[o + 8];
    real n2 = coeffs[o + 9];

    real x1_1 = 0, x2_1 = 0, y_1 = 0, dy_1 = 0;
    real x1_2 = 0, x2_2 = 0, y_2 = 0, dy_2 = 0;
    real x1_3 = 0, x2_3 = 0, y_3 = 0, dy_3 = 0;
    real x1_4 = 0, x2_4 = 0, y_4 = 0, dy_4 = 0;
    real total = 0;
    real block = 0;
    for (uint i = 0; i < window_size; i++) {
        real x = frame.at(i) * hann[i];
        real dx = x - x1_1;

        dy_1 = dy_1 + c2 * dy_1 - e * y_1 + (s1n0 * dx + s1m1 * x1_1 + s1n2 * x2_1);
        x2_1 = x1_1; x1_1 = x;
        y_1 = y_1 + dy_1;

        dy_2 = dy_2 + c2 * dy_2 - e * y_2 + (n0 * dy_1 + s2m1 * x1_2 + n2 * x2_2);
        x2_2 = x1_2; x1_2 = y_1;
        y_2 = y_2 + dy_2;

        dy_3 = dy_3 + c2 * dy_3 - e * y_3 + (n0 * dy_2 + s3m1 * x1_3 + n2 * x2_3);
        x2_3 = x1_3; x1_3 = y_2;
        y_3 = y_3 + dy_3;

        dy_4 = dy_4 + c2 * dy_4 - e * y_4 + (n0 * dy_3 + s4m1 * x1_4 + n2 * x2_4);
        x2_4 = x1_4; x1_4 = y_3;
        y_4 = y_4 + dy_4;

        block += y_4 * y_4;
        if ((i & 63) == 63) {
            total += block;
            block = 0;
        }
    }
    total += block;
    return sqrt(total / real(window_size));
#endif
#endif
}
