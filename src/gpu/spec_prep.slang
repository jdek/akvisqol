// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// `spectrogram.prepareForComparison` of each row's ref and deg spectrograms,
// `raw` (linear) into `out` (dB), one thread group per row: dB with the
// absolute floor, the per-frame floor over the shared frames, then the
// joint minimum subtracted. Max and min are exact in any order, so in f64
// this matches the CPU up to log10 (musl's here; the CPU's is libm's).
//
// Each spectrogram (num_bands, frames) at its offset.
import df;
import tables;
import zimt;

typealias real = REAL;

static const uint THREADS = 256;

#if EXACT
static const double IVLN10HI = asdouble(0x15200000u, 0x3FDBCB7Bu);
static const double IVLN10LO = asdouble(0xCA9AADD5u, 0x3DBB9438u);
static const double LOG10_2HI = asdouble(0x509F6000u, 0x3FD34413u);
static const double LOG10_2LO = asdouble(0x11F12B36u, 0x3D59FEF3u);
static const double LG1 = asdouble(0x55555593u, 0x3FE55555u);
static const double LG2 = asdouble(0x9997FA04u, 0x3FD99999u);
static const double LG3 = asdouble(0x94229359u, 0x3FD24924u);
static const double LG4 = asdouble(0x1D8E78AFu, 0x3FCC71C5u);
static const double LG5 = asdouble(0x96CB03DEu, 0x3FC74664u);
static const double LG6 = asdouble(0xD078C69Fu, 0x3FC39A09u);
static const double LG7 = asdouble(0xDF3E5244u, 0x3FC2F112u);
static const double EPS = asdouble(0x00000000u, 0x3CB00000u);
static const double TWO54 = asdouble(0x00000000u, 0x43500000u);
static const double INF = asdouble(0x00000000u, 0x7FF00000u);

// musl's log10 (error < 1 ulp) for positive finite x: Vulkan has no f64
// log, and Slang's CUDA log10(double) goes through f32.
double log10Exact(double x)
{
    uint lo, hx;
    asuint(x, lo, hx);
    int k = 0;
    if (hx < 0x00100000u) {
        k -= 54;
        x *= TWO54;
        asuint(x, lo, hx);
    }
    hx += 0x3ff00000u - 0x3fe6a09eu;
    k += int(hx >> 20) - 0x3ff;
    hx = (hx & 0x000fffffu) + 0x3fe6a09eu;
    x = asdouble(lo, hx);

    double f = x - 1.0;
    double hfsq = 0.5 * f * f;
    double s = f / (2.0 + f);
    double z = s * s;
    double w = z * z;
    double t1 = w * (LG2 + w * (LG4 + w * LG6));
    double t2 = z * (LG1 + w * (LG3 + w * (LG5 + w * LG7)));
    double r = t2 + t1;

    double hi = f - hfsq;
    uint hl, hh;
    asuint(hi, hl, hh);
    hi = asdouble(0u, hh);
    double lo2 = f - hi - hfsq + s * (hfsq + r);

    double val_hi = hi * IVLN10HI;
    double dk = double(k);
    double y = dk * LOG10_2HI;
    double val_lo = dk * LOG10_2LO + (lo2 + hi) * IVLN10LO + lo2 * IVLN10HI;
    w = y + val_hi;
    val_lo += (y - w) + val_hi;
    val_hi = w;
    return val_lo + val_hi;
}

real dB(real x)
{
    return max(real(10) * log10Exact(x == real(0) ? EPS : abs(x)), real(-45));
}
#else
static const float EPS = asfloat(0x34000000u);  // f32 epsilon
static const float INF = asfloat(0x7F800000u);

#if BALANCED
// 10·log10 in two-float, rounded once: f32 log10 is good to a few ulp at
// best, and dB values feed the NSIM statistics.
real dB(real x)
{
    DF l = mul(log10DF(x == real(0) ? EPS : abs(x)), DF(10));
    return max(l.hi + l.lo, real(-45));
}
#else
real dB(real x)
{
    return max(real(10) * log10(x == real(0) ? EPS : abs(x)), real(-45));
}
#endif
#endif

groupshared real lowest[THREADS];

[shader("compute")]
[numthreads(THREADS, 1, 1)]
void spec_prep(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<SpecPair> rows,
    uniform RO<real> raw,
    uniform RW<real> out,
    uniform uint num_rows,
    uniform uint num_bands)
{
    uint row = zimt_index(tid) / THREADS;
    uint lane = tid.x % THREADS;
    if (row >= num_rows) return;
    uint ro = rows[row].ref_off;
    uint rn = rows[row].ref_frames;
    uint dof = rows[row].deg_off;
    uint dn = rows[row].deg_frames;

    for (uint i = lane; i < num_bands * rn; i += THREADS) out[ro + i] = dB(raw[ro + i]);
    for (uint i = lane; i < num_bands * dn; i += THREADS) out[dof + i] = dB(raw[dof + i]);
    AllMemoryBarrierWithGroupSync();

    // Relative floor over the shared frames.
    for (uint c = lane; c < min(rn, dn); c += THREADS) {
        real top = -INF;
        for (uint b = 0; b < num_bands; b++) top = max(top, max(out[ro + b * rn + c], out[dof + b * dn + c]));
        real floor = top - real(45);
        for (uint b = 0; b < num_bands; b++) {
            out[ro + b * rn + c] = max(out[ro + b * rn + c], floor);
            out[dof + b * dn + c] = max(out[dof + b * dn + c], floor);
        }
    }
    AllMemoryBarrierWithGroupSync();

    real lo = INF;
    for (uint i = lane; i < num_bands * rn; i += THREADS) lo = min(lo, out[ro + i]);
    for (uint i = lane; i < num_bands * dn; i += THREADS) lo = min(lo, out[dof + i]);
    lowest[lane] = lo;
    GroupMemoryBarrierWithGroupSync();
    for (uint s = THREADS / 2; s > 0; s >>= 1) {
        if (lane < s) lowest[lane] = min(lowest[lane], lowest[lane + s]);
        GroupMemoryBarrierWithGroupSync();
    }
    lo = lowest[0];

    for (uint i = lane; i < num_bands * rn; i += THREADS) out[ro + i] -= lo;
    for (uint i = lane; i < num_bands * dn; i += THREADS) out[dof + i] -= lo;
}
