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

struct RO_1
{
    LagRow_0 device* p_0;
};

LagRow_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

Side_0 side_0(const RO_1 constant* rows_0, uint row_0, uint s_0)
{
    Side_0 _S1;
    if(s_0 == 0U)
    {
        LagRow_0 _S2 = RO_operatorx5Bx5D_get_1(rows_0, row_0);
        _S1 = _S2.a_0;
    }
    else
    {
        LagRow_0 _S3 = RO_operatorx5Bx5D_get_1(rows_0, row_0);
        _S1 = _S3.b_0;
    }
    return _S1;
}

uint Side_total_0(const Side_0 thread* this_2)
{
    return this_2->pad_0 + this_2->len_0;
}

float at_0(const Side_0 thread* v_0, const RO_0 constant* signals_0, uint i_2)
{
    uint _S4 = v_0->pad_0;
    float _S5;
    if(i_2 < (v_0->pad_0))
    {
        _S5 = 0.0f;
    }
    else
    {
        float _S6 = RO_operatorx5Bx5D_get_0(signals_0, v_0->start_0 + i_2 - _S4);
        _S5 = _S6;
    }
    return _S5;
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_0 signals_1;
    RO_1 rows_1;
    RW_0 part_0;
    uint first_0;
    uint log2_n_0;
    uint block_0;
    uint total_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    array<float, int(64)> threadgroup* acc_0;
};

float groupSum_0(float v_1, uint lane_0, KernelContext_0 thread* kernelContext_0)
{
    (*kernelContext_0->acc_0)[lane_0] = v_1;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint s_1 = 32U;
    for(;;)
    {
        if(s_1 > 0U)
        {
        }
        else
        {
            break;
        }
        if(lane_0 < s_1)
        {
            (*kernelContext_0->acc_0)[lane_0] = (*kernelContext_0->acc_0)[lane_0] + (*kernelContext_0->acc_0)[lane_0 + s_1];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        s_1 = s_1 >> 1U;
    }
    return (*kernelContext_0->acc_0)[int(0)];
}

[[kernel]] void env_sums(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_1;
    (&kernelContext_1)->entryPointParams_0 = entryPointParams_1;
    threadgroup array<float, int(64)> acc_1;
    (&kernelContext_1)->acc_0 = &acc_1;
    RW_0 _S7 = entryPointParams_1->part_0;
    uint g_0 = zimt_index_0(tid_1) / 64U;
    uint lane_1 = tid_1.x % 64U;
    if(g_0 >= (entryPointParams_1->total_0))
    {
        return;
    }
    uint blocks_0 = (1U << ((&kernelContext_1)->entryPointParams_0->log2_n_0)) / (&kernelContext_1)->entryPointParams_0->block_0;
    uint s_2 = g_0 / blocks_0;
    Side_0 _S8 = side_0(&(&kernelContext_1)->entryPointParams_0->rows_1, (&kernelContext_1)->entryPointParams_0->first_0 + s_2 / 2U, s_2 % 2U);
    uint _S9 = g_0 % blocks_0;
    uint _S10 = _S9 * (&kernelContext_1)->entryPointParams_0->block_0 + lane_1;
    uint k_0 = 0U;
    uint i_3 = _S10;
    float sum_0 = 0.0f;
    for(;;)
    {
        if(k_0 < ((&kernelContext_1)->entryPointParams_0->block_0 / 64U))
        {
        }
        else
        {
            break;
        }
        thread Side_0 _S11 = _S8;
        uint _S12 = Side_total_0(&_S11);
        if(i_3 < _S12)
        {
            thread Side_0 _S13 = _S8;
            float _S14 = at_0(&_S13, &(&kernelContext_1)->entryPointParams_0->signals_1, i_3);
            sum_0 = sum_0 + _S14;
        }
        uint i_4 = i_3 + 64U;
        k_0 = k_0 + 1U;
        i_3 = i_4;
    }
    float _S15 = groupSum_0(sum_0, lane_1, &kernelContext_1);
    if(lane_1 == 0U)
    {
        *(_S7.p_1 + g_0) = _S15;
    }
    return;
}

