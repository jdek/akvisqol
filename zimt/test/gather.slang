// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

import zimt;

public struct Span
{
    public uint start;
    public uint len;
}

// float2 sits at 12 in SPIR-V and on Metal, at 16 on CUDA.
public struct Job
{
    public Span src;
    public float scale;
    public float2 bias;
}

// y[i] = scale · Σ x[src] + bias.x - bias.y for job i.

[shader("compute")]
[numthreads(32, 1, 1)]
void gather(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<Job> jobs,
    uniform RO<float> x,
    uniform RW<float> y,
    uniform uint n)
{
    uint i = zimt_index(tid);
    if (i >= n) return;
    Job j = jobs[i];
    float s = 0;
    for (uint k = 0; k < j.src.len; k++) s += x[j.src.start + k];
    y[i] = s * j.scale + j.bias.x - j.bias.y;
}
