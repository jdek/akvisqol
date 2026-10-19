#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
uint firstbithigh_0(uint value_0)
{
    if(value_0 == 0U)
    {
        return 4294967295U;
    }
    uint _S1 = clz(value_0);
    return 31U - _S1;
}

struct Side_0
{
    uint start_0;
    uint pad_0;
    uint len_0;
};

struct LagRow_0
{
    Side_0 a_0;
    Side_0 b_0;
    uint first_slot_0;
    uint slots_0;
    uint a_base_0;
    uint b_base_0;
    uint a_grid_0;
    uint b_grid_0;
    uint a_raw_0;
    uint b_raw_0;
};

struct RO_0
{
    LagRow_0 device* p_0;
};

LagRow_0 RO_operatorx5Bx5D_get_0(const RO_0 constant* this_0, uint i_0)
{
    return *(this_0->p_0 + i_0);
}

struct RO_1
{
    float device* p_0;
};

float RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_0 rows_0;
    RO_1 part_0;
    RW_0 stats_0;
    uint first_0;
    uint log2_n_0;
    uint block_0;
    uint sides_0;
    uint mode_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    array<float, int(64)> threadgroup* acc_0;
};

float groupSum_0(float v_0, uint lane_0, KernelContext_0 thread* kernelContext_0)
{
    (*kernelContext_0->acc_0)[lane_0] = v_0;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint s_0 = 32U;
    for(;;)
    {
        if(s_0 > 0U)
        {
        }
        else
        {
            break;
        }
        if(lane_0 < s_0)
        {
            (*kernelContext_0->acc_0)[lane_0] = (*kernelContext_0->acc_0)[lane_0] + (*kernelContext_0->acc_0)[lane_0 + s_0];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        s_0 = s_0 >> 1U;
    }
    return (*kernelContext_0->acc_0)[int(0)];
}

Side_0 side_0(const RO_0 constant* rows_1, uint row_0, uint s_1)
{
    Side_0 _S2;
    if(s_1 == 0U)
    {
        LagRow_0 _S3 = RO_operatorx5Bx5D_get_0(rows_1, row_0);
        _S2 = _S3.a_0;
    }
    else
    {
        LagRow_0 _S4 = RO_operatorx5Bx5D_get_0(rows_1, row_0);
        _S2 = _S4.b_0;
    }
    return _S2;
}

uint Side_total_0(const Side_0 thread* this_2)
{
    return this_2->pad_0 + this_2->len_0;
}

[[kernel]] void env_reduce(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_1;
    (&kernelContext_1)->entryPointParams_0 = entryPointParams_1;
    threadgroup array<float, int(64)> acc_1;
    (&kernelContext_1)->acc_0 = &acc_1;
    RW_0 _S5 = entryPointParams_1->stats_0;
    uint g_0 = zimt_index_0(tid_1) / 64U;
    uint lane_1 = tid_1.x % 64U;
    if(g_0 >= (entryPointParams_1->sides_0))
    {
        return;
    }
    uint _S6 = (1U << ((&kernelContext_1)->entryPointParams_0->log2_n_0)) / (&kernelContext_1)->entryPointParams_0->block_0;
    uint b_1 = lane_1;
    float s_2 = 0.0f;
    for(;;)
    {
        if(b_1 < _S6)
        {
        }
        else
        {
            break;
        }
        float _S7 = RO_operatorx5Bx5D_get_1(&(&kernelContext_1)->entryPointParams_0->part_0, g_0 * _S6 + b_1);
        float s_3 = s_2 + _S7;
        b_1 = b_1 + 64U;
        s_2 = s_3;
    }
    float _S8 = groupSum_0(s_2, lane_1, &kernelContext_1);
    if(lane_1 != 0U)
    {
        return;
    }
    Side_0 _S9 = side_0(&(&kernelContext_1)->entryPointParams_0->rows_0, (&kernelContext_1)->entryPointParams_0->first_0 + g_0 / 2U, g_0 % 2U);
    thread Side_0 _S10 = _S9;
    uint _S11 = Side_total_0(&_S10);
    if(((&kernelContext_1)->entryPointParams_0->mode_0) == 0U)
    {
        *(_S5.p_1 + g_0 * 2U) = _S8 / float(_S11);
        return;
    }
    if(_S11 <= 1U)
    {
        b_1 = 0U;
    }
    else
    {
        b_1 = firstbithigh_0(_S11 - 1U) + 1U;
    }
    uint _S12 = max(b_1, 5U);
    uint k_0 = 0U;
    s_2 = _S8;
    for(;;)
    {
        if(k_0 < _S12)
        {
        }
        else
        {
            break;
        }
        float s_4 = s_2 * 0.5f;
        k_0 = k_0 + 1U;
        s_2 = s_4;
    }
    *(_S5.p_1 + (g_0 * 2U + 1U)) = s_2;
    return;
}

