// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Two-float numbers, hi + lo with |lo| ≤ ulp(hi) / 2: ~48 bits of
// precision from f32 hardware. Error-free transforms need IEEE operation
// order: build with `-fp-mode precise`. `fma` must be fused (CUDA, Metal,
// and the Vulkan drivers tested).
module df;

public struct DF
{
    public float hi;
    public float lo;

    public __init(float h, float l)
    {
        hi = h;
        lo = l;
    }

    public __init(float x)
    {
        hi = x;
        lo = 0;
    }

    public float value() { return hi + lo; }
}

// a + b = s + e exactly.
DF twoSum(float a, float b)
{
    float s = a + b;
    float bb = s - a;
    return DF(s, (a - (s - bb)) + (b - bb));
}

// For |a| ≥ |b|.
DF quickTwoSum(float a, float b)
{
    float s = a + b;
    return DF(s, b - (s - a));
}

public DF add(DF a, DF b)
{
    DF s = twoSum(a.hi, b.hi);
    DF t = twoSum(a.lo, b.lo);
    s = quickTwoSum(s.hi, s.lo + t.hi);
    return quickTwoSum(s.hi, s.lo + t.lo);
}

public DF neg(DF a) { return DF(-a.hi, -a.lo); }

public DF sub(DF a, DF b) { return add(a, neg(b)); }

public DF mul(DF a, DF b)
{
    float p = a.hi * b.hi;
    float e = fma(a.hi, b.hi, -p);
    e += a.hi * b.lo + a.lo * b.hi;
    return quickTwoSum(p, e);
}

public DF mulf(DF a, float b) { return mul(a, DF(b)); }

public DF div(DF a, DF b)
{
    float q1 = a.hi / b.hi;
    DF r = sub(a, mul(DF(q1), b));
    float q2 = r.hi / b.hi;
    r = sub(r, mul(DF(q2), b));
    float q3 = r.hi / b.hi;
    DF q = quickTwoSum(q1, q2);
    return add(q, DF(q3));
}

public DF sqrt(DF a)
{
    if (a.hi <= 0) return DF(0);
    float s = sqrt(a.hi);
    DF e = sub(a, mul(DF(s), DF(s)));
    return quickTwoSum(s, e.hi / (2 * s));
}

public bool less(DF a, DF b) { return a.hi < b.hi || (a.hi == b.hi && a.lo < b.lo); }

static const DF LN10_INV = DF(asfloat(0x3EDE5BD9u), asfloat(0xB22D91AFu)); // 1 / ln(10)
static const DF LN2 = DF(asfloat(0x3F317218u), asfloat(0xB102E308u));

// ln(x) for normal x > 0: the exponent's part exactly, the mantissa's
// (m in [√½, √2)) as 2t·(1 + t²/3 + t⁴/5 …), t = (m - 1) / (m + 1). With
// t² ≤ 0.03 the series past 1 is under 1% of it, so f32 there leaves
// ~1e-9 relative: ample for a result rounded to f32.
public DF ln(float x)
{
    uint bits = asuint(x);
    int e = int((bits >> 23) & 0xff) - 127;
    float m = asfloat((bits & 0x7fffff) | 0x3f800000);
    if (m > 1.41421356f) {
        m *= 0.5f;
        e += 1;
    }
    DF t = div(sub(DF(m), DF(1)), add(DF(m), DF(1)));
    float z = t.hi * t.hi;
    float tail = z * (1.0f / 3 + z * (1.0f / 5 + z * (1.0f / 7 + z * (1.0f / 9 + z * (1.0f / 11)))));
    DF lnm = mul(add(t, t), quickTwoSum(1, tail));
    return add(mul(DF(float(e)), LN2), lnm);
}

public DF log10DF(float x) { return mul(ln(x), LN10_INV); }
