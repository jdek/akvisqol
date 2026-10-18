#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct RO_0
{
    uint device* p_0;
};

uint RO_operatorx5Bx5D_get_0(const RO_0 constant* this_0, uint i_0)
{
    return *(this_0->p_0 + i_0);
}

uint3 zimt_groups_0(uint n_0, uint threads_x_0)
{
    uint g_0 = (n_0 + threads_x_0 - 1U) / threads_x_0;
    if(g_0 <= 32768U)
    {
        return uint3(g_0, 1U, 1U);
    }
    return uint3(32768U, (g_0 + 32768U - 1U) / 32768U, 1U);
}

struct RW_0
{
    packed_uint3 device* p_1;
};

struct EntryPointParams_0
{
    RO_0 count_0;
    RW_0 groups_0;
    uint threads_x_1;
};

[[kernel]] void plan(EntryPointParams_0 constant* entryPointParams_0 [[buffer(0)]])
{
    uint _S1 = RO_operatorx5Bx5D_get_0(&entryPointParams_0->count_0, 0U);
    uint3 _S2 = zimt_groups_0(_S1, entryPointParams_0->threads_x_1);
    *(entryPointParams_0->groups_0.p_1 + 0U) = packed_uint3(_S2) ;
    return;
}

