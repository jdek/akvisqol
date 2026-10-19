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

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 8388608U;
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_0 src_0;
    RW_0 dst_0;
    uint src_off_0;
    uint dst_off_0;
    uint n_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void copy(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S1 = entryPointParams_1->dst_0;
    uint i_1 = zimt_index_0(tid_1);
    if(i_1 < (entryPointParams_1->n_0))
    {
        uint _S2 = (&kernelContext_0)->entryPointParams_0->dst_off_0 + i_1;
        float _S3 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->src_0, (&kernelContext_0)->entryPointParams_0->src_off_0 + i_1);
        *(_S1.p_1 + _S2) = _S3;
    }
    return;
}

