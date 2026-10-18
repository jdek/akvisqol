#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct RO_0
{
    float device* p_0;
};

float RO_operatorx5Bx5D_get_0(const RO_0 constant* this_0, uint i_0)
{
    return *(this_0->p_0 + i_0);
}

struct RO_1
{
    uint device* p_0;
};

uint RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
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
    RO_0 signals_0;
    RO_1 jobs_0;
    RW_0 z_0;
    uint log2_n_0;
    uint total_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void lag_pack(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S1 = entryPointParams_1->z_0;
    uint g_0 = zimt_index_0(tid_1);
    if(g_0 >= (entryPointParams_1->total_0))
    {
        return;
    }
    uint t_0 = g_0 & ((1U << ((&kernelContext_0)->entryPointParams_0->log2_n_0)) - 1U);
    uint _S2 = (g_0 >> ((&kernelContext_0)->entryPointParams_0->log2_n_0)) * 4U;
    uint _S3 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->jobs_0, _S2);
    uint _S4 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->jobs_0, _S2 + 2U);
    uint _S5 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->jobs_0, _S2 + 1U);
    float _S6;
    if(t_0 < _S5)
    {
        float _S7 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->signals_0, _S3 + t_0);
        _S6 = _S7;
    }
    else
    {
        _S6 = 0.0f;
    }
    uint _S8 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->jobs_0, _S2 + 3U);
    float _S9;
    if(t_0 < _S8)
    {
        float _S10 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->signals_0, _S4 + t_0);
        _S9 = _S10;
    }
    else
    {
        _S9 = 0.0f;
    }
    *(_S1.p_1 + g_0) = packed_float2(float2(_S6, _S9)) ;
    return;
}

