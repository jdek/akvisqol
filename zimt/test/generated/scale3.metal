#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct RW_0
{
    packed_float3 device* p_0;
};

float3 RW_operatorx5Bx5D_get_0(const RW_0 constant* this_0, uint i_0)
{
    return float3(*(this_0->p_0 + i_0)) ;
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 1048576U;
}

struct EntryPointParams_0
{
    RW_0 v_0;
    float s_0;
    uint n_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void scale3(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S1 = entryPointParams_1->v_0;
    uint i_1 = zimt_index_0(tid_1);
    if(i_1 >= (entryPointParams_1->n_0))
    {
        return;
    }
    float3 _S2 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->v_0, i_1);
    *(_S1.p_0 + i_1) = packed_float3((_S2 * float3((&kernelContext_0)->entryPointParams_0->s_0, 2.0f * (&kernelContext_0)->entryPointParams_0->s_0, 3.0f * (&kernelContext_0)->entryPointParams_0->s_0))) ;
    return;
}

