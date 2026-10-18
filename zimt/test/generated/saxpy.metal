#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct RW_0
{
    float device* p_0;
};

float RW_operatorx5Bx5D_get_0(const RW_0 constant* this_0, uint i_0)
{
    return *(this_0->p_0 + i_0);
}

struct RO_0
{
    float device* p_1;
};

float RO_operatorx5Bx5D_get_0(const RO_0 constant* this_1, uint i_1)
{
    return *(this_1->p_1 + i_1);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 1048576U;
}

struct EntryPointParams_0
{
    RO_0 x_0;
    RW_0 y_0;
    float a_0;
    uint n_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void saxpy(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S1 = entryPointParams_1->y_0;
    uint i_2 = zimt_index_0(tid_1);
    if(i_2 >= (entryPointParams_1->n_0))
    {
        return;
    }
    float _S2 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->x_0, i_2);
    float _S3 = (&kernelContext_0)->entryPointParams_0->a_0 * _S2;
    float _S4 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->y_0, i_2);
    *(_S1.p_0 + i_2) = _S3 + _S4;
    return;
}

