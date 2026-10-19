#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct LagParams_0
{
    uint max_lag_0;
    float slack_0;
};

struct RO_0
{
    LagParams_0 device* p_0;
};

LagParams_0 RO_operatorx5Bx5D_get_0(const RO_0 constant* this_0, uint i_0)
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
    int device* p_1;
};

struct RW_1
{
    uint device* p_1;
};

struct EntryPointParams_0
{
    RO_0 params_0;
    RO_1 keys_0;
    RW_0 lags_0;
    RW_1 status_0;
    uint first_0;
    uint num_rows_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void lag_fast_pick(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S1 = entryPointParams_1->lags_0;
    RW_1 _S2 = entryPointParams_1->status_0;
    uint row_0 = zimt_index_0(tid_1);
    if(row_0 >= (entryPointParams_1->num_rows_0))
    {
        return;
    }
    uint _S3 = (&kernelContext_0)->entryPointParams_0->first_0 + row_0;
    uint _S4 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->keys_0, row_0);
    int _S5 = int(~_S4);
    LagParams_0 _S6 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->params_0, row_0);
    *(_S1.p_1 + _S3) = _S5 - int(_S6.max_lag_0);
    *(_S2.p_1 + ((&kernelContext_0)->entryPointParams_0->first_0 + row_0)) = 0U;
    return;
}

