// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

import zimt;

// v[i] *= (s, 2s, 3s): float3 elements, 12 bytes apart on every backend.
[shader("compute")]
[numthreads(32, 1, 1)]
void scale3(
    uint3 tid: SV_DispatchThreadID,
    uniform RW<float3> v,
    uniform float s,
    uniform uint n)
{
    uint i = zimt_index(tid);
    if (i >= n) return;
    v[i] = v[i] * float3(s, 2.0 * s, 3.0 * s);
}
