// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

import zimt;

// y = a*x + y over the first n elements.

[shader("compute")]
[numthreads(32, 1, 1)]
void saxpy(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<float> x,
    uniform RW<float> y,
    uniform float a,
    uniform uint n)
{
    uint i = zimt_index(tid);
    if (i >= n) return;
    y[i] = a * x[i] + y[i];
}
