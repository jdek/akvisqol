#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct RO_0
{
    packed_float2 device* p_0;
};

float2 RO_operatorx5Bx5D_get_0(const RO_0 constant* this_0, uint i_0)
{
    return float2(*(this_0->p_0 + i_0)) ;
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

struct RW_0
{
    packed_float2 device* p_1;
};

struct EntryPointParams_0
{
    RO_0 z_0;
    RW_0 out_0;
    uint log2_n_0;
    uint total_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void xcorr_spectrum(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S1 = entryPointParams_1->out_0;
    uint g_0 = zimt_index_0(tid_1);
    if(g_0 >= (entryPointParams_1->total_0))
    {
        return;
    }
    uint n_0 = 1U << ((&kernelContext_0)->entryPointParams_0->log2_n_0);
    uint base_0 = (g_0 >> ((&kernelContext_0)->entryPointParams_0->log2_n_0)) << ((&kernelContext_0)->entryPointParams_0->log2_n_0);
    uint _S2 = n_0 - 1U;
    uint k_0 = g_0 & _S2;
    uint _S3 = base_0 + k_0;
    float2 _S4 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->z_0, _S3);
    float2 _S5 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->z_0, base_0 + ((n_0 - k_0) & _S2));
    float _S6 = _S4.x;
    float _S7 = _S5.x;
    float _S8 = _S6 + _S7;
    float _S9 = _S4.y;
    float _S10 = _S5.y;
    float _S11 = _S9 - _S10;
    float _S12 = _S6 - _S7;
    float _S13 = _S9 + _S10;
    *(_S1.p_1 + _S3) = packed_float2((float2(0.25f)  * float2(_S8 * _S13 - _S11 * _S12, _S8 * _S12 + _S11 * _S13))) ;
    return;
}

