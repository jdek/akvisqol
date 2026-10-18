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
    packed_float2 device* entryPointParams_z_0;
    packed_float2 device* entryPointParams_out_0;
};

[[kernel]] void xcorr_spectrum(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]], packed_float2 device* entryPointParams_z_1 [[buffer(1)]], packed_float2 device* entryPointParams_out_1 [[buffer(2)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    (&kernelContext_0)->entryPointParams_z_0 = entryPointParams_z_1;
    (&kernelContext_0)->entryPointParams_out_0 = entryPointParams_out_1;
    uint g_0 = zimt_index_0(tid_1);
    if(g_0 >= (entryPointParams_1->total_0))
    {
        return;
    }
    uint n_0 = 1U << ((&kernelContext_0)->entryPointParams_0->log2_n_0);
    uint base_0 = (g_0 >> ((&kernelContext_0)->entryPointParams_0->log2_n_0)) << ((&kernelContext_0)->entryPointParams_0->log2_n_0);
    uint _S1 = n_0 - 1U;
    uint k_0 = g_0 & _S1;
    uint _S2 = base_0 + k_0;
    float2 _S3 = float2(*((&kernelContext_0)->entryPointParams_z_0+_S2)) ;
    float2 _S4 = float2(*((&kernelContext_0)->entryPointParams_z_0+(base_0 + ((n_0 - k_0) & _S1)))) ;
    float _S5 = _S3.x;
    float _S6 = _S4.x;
    float _S7 = _S5 + _S6;
    float _S8 = _S3.y;
    float _S9 = _S4.y;
    float _S10 = _S8 - _S9;
    float _S11 = _S5 - _S6;
    float _S12 = _S8 + _S9;
    *((&kernelContext_0)->entryPointParams_out_0+_S2) = packed_float2((float2(0.25f)  * float2(_S7 * _S12 - _S10 * _S11, _S7 * _S11 + _S10 * _S12))) ;
    return;
}

