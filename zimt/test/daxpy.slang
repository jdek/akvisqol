// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

import zimt;

// y = a*x + y in f64.

[shader("compute")]
[numthreads(32, 1, 1)]
void daxpy(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<double> x,
    uniform RW<double> y,
    uniform double a,
    uniform uint n)
{
    uint i = zimt_index(tid);
    if (i >= n) return;
    y[i] = a * x[i] + y[i];
}
