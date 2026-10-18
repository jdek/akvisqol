// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

import zimt;

// Indices of the positive x[i], in any order.
[shader("compute")]
[numthreads(64, 1, 1)]
void compact(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<float> x,
    uniform RW<uint> list,
    uniform RW<uint> count,
    uniform uint n)
{
    uint i = zimt_index(tid);
    if (i >= n || x[i] <= 0.0) return;
    uint slot;
    InterlockedAdd(count.p[0], 1u, slot);
    list[slot] = i;
}

// Groups for `scale_listed` over the compacted list.
[shader("compute")]
[numthreads(1, 1, 1)]
void plan(uniform RO<uint> count, uniform RW<uint3> groups, uniform uint threads_x)
{
    groups[0] = zimt_groups(count[0], threads_x);
}

[shader("compute")]
[numthreads(64, 1, 1)]
void scale_listed(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<uint> list,
    uniform RO<uint> count,
    uniform RW<float> x,
    uniform float s)
{
    uint i = zimt_index(tid);
    if (i >= count[0]) return;
    x[list[i]] = x[list[i]] * s;
}
