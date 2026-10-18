#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

struct EntryPointParams_0
{
    uint log2_n_0;
    uint total_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    float device* entryPointParams_signals_0;
    uint device* entryPointParams_jobs_0;
    packed_float2 device* entryPointParams_z_0;
};

[[kernel]] void lag_pack(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]], float device* entryPointParams_signals_1 [[buffer(1)]], uint device* entryPointParams_jobs_1 [[buffer(2)]], packed_float2 device* entryPointParams_z_1 [[buffer(3)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    (&kernelContext_0)->entryPointParams_signals_0 = entryPointParams_signals_1;
    (&kernelContext_0)->entryPointParams_jobs_0 = entryPointParams_jobs_1;
    (&kernelContext_0)->entryPointParams_z_0 = entryPointParams_z_1;
    uint g_0 = zimt_index_0(tid_1);
    if(g_0 >= (entryPointParams_1->total_0))
    {
        return;
    }
    uint t_0 = g_0 & ((1U << ((&kernelContext_0)->entryPointParams_0->log2_n_0)) - 1U);
    uint _S1 = (g_0 >> ((&kernelContext_0)->entryPointParams_0->log2_n_0)) * 4U;
    uint s1_0 = (&kernelContext_0)->entryPointParams_jobs_0[_S1];
    uint s2_0 = (&kernelContext_0)->entryPointParams_jobs_0[_S1 + 2U];
    packed_float2 device* _S2 = (&kernelContext_0)->entryPointParams_z_0+g_0;
    float _S3;
    if(t_0 < ((&kernelContext_0)->entryPointParams_jobs_0)[_S1 + 1U])
    {
        _S3 = (&kernelContext_0)->entryPointParams_signals_0[s1_0 + t_0];
    }
    else
    {
        _S3 = 0.0f;
    }
    float _S4;
    if(t_0 < ((&kernelContext_0)->entryPointParams_jobs_0)[_S1 + 3U])
    {
        _S4 = (&kernelContext_0)->entryPointParams_signals_0[s2_0 + t_0];
    }
    else
    {
        _S4 = 0.0f;
    }
    *_S2 = packed_float2(float2(_S3, _S4)) ;
    return;
}

