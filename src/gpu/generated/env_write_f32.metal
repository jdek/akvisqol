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

uint Side_total_0(const Side_0 thread* this_2)
{
    return this_2->pad_0 + this_2->len_0;
}

uint Side_total_1(const Side_0 thread* this_3)
{
    return this_3->pad_0 + this_3->len_0;
}

float at_0(const Side_0 thread* v_0, const RO_0 constant* signals_0, uint i_2)
{
    uint _S1 = v_0->pad_0;
    float _S2;
    if(i_2 < (v_0->pad_0))
    {
        _S2 = 0.0f;
    }
    else
    {
        float _S3 = RO_operatorx5Bx5D_get_0(signals_0, v_0->start_0 + i_2 - _S1);
        _S2 = _S3;
    }
    return _S2;
}

float envelopeAt_0(const Side_0 thread* v_1, const RO_0 constant* signals_1, uint i_3, float mean_0, float nyq_0)
{
    uint _S4 = Side_total_1(v_1);
    if(i_3 >= _S4)
    {
        return 0.0f;
    }
    float t_0;
    if((i_3 & 1U) == 0U)
    {
        t_0 = nyq_0;
    }
    else
    {
        t_0 = - nyq_0;
    }
    float _S5 = at_0(v_1, signals_1, i_3);
    return abs(2.0f * (_S5 - mean_0 - t_0) - 9.99999997475242708e-07f) + mean_0;
}

struct RW_0
{
    float device* p_1;
};

struct RW_1
{
    packed_float2 device* p_1;
};

struct EntryPointParams_0
{
    RO_0 signals_2;
    RO_1 rows_0;
    RO_0 stats_0;
    RW_0 env_0;
    RW_1 z_0;
    RW_0 energy_0;
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

float groupSum_0(float v_2, uint lane_0, KernelContext_0 thread* kernelContext_0)
{
    (*kernelContext_0->acc_0)[lane_0] = v_2;
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

[[kernel]] void env_write(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_1;
    (&kernelContext_1)->entryPointParams_0 = entryPointParams_1;
    threadgroup array<float, int(64)> acc_1;
    (&kernelContext_1)->acc_0 = &acc_1;
    RW_0 _S6 = entryPointParams_1->env_0;
    RW_1 _S7 = entryPointParams_1->z_0;
    RW_0 _S8 = entryPointParams_1->energy_0;
    uint g_0 = zimt_index_0(tid_1) / 64U;
    uint lane_1 = tid_1.x % 64U;
    if(g_0 >= (entryPointParams_1->total_0))
    {
        return;
    }
    uint n_0 = 1U << ((&kernelContext_1)->entryPointParams_0->log2_n_0);
    uint blocks_0 = n_0 / (&kernelContext_1)->entryPointParams_0->block_0;
    uint row_0 = g_0 / blocks_0;
    LagRow_0 _S9 = RO_operatorx5Bx5D_get_1(&(&kernelContext_1)->entryPointParams_0->rows_0, (&kernelContext_1)->entryPointParams_0->first_0 + row_0);
    LagRow_0 _S10 = RO_operatorx5Bx5D_get_1(&(&kernelContext_1)->entryPointParams_0->rows_0, (&kernelContext_1)->entryPointParams_0->first_0 + row_0);
    uint _S11 = g_0 % blocks_0;
    uint _S12 = _S11 * (&kernelContext_1)->entryPointParams_0->block_0 + lane_1;
    uint k_0 = 0U;
    uint i_4 = _S12;
    float e_0 = 0.0f;
    for(;;)
    {
        if(k_0 < ((&kernelContext_1)->entryPointParams_0->block_0 / 64U))
        {
        }
        else
        {
            break;
        }
        uint _S13 = row_0 * 4U;
        float _S14 = RO_operatorx5Bx5D_get_0(&(&kernelContext_1)->entryPointParams_0->stats_0, _S13);
        float _S15 = RO_operatorx5Bx5D_get_0(&(&kernelContext_1)->entryPointParams_0->stats_0, _S13 + 1U);
        thread Side_0 _S16 = _S9.a_0;
        float _S17 = envelopeAt_0(&_S16, &(&kernelContext_1)->entryPointParams_0->signals_2, i_4, _S14, _S15);
        float _S18 = RO_operatorx5Bx5D_get_0(&(&kernelContext_1)->entryPointParams_0->stats_0, _S13 + 2U);
        float _S19 = RO_operatorx5Bx5D_get_0(&(&kernelContext_1)->entryPointParams_0->stats_0, _S13 + 3U);
        thread Side_0 _S20 = _S10.b_0;
        float _S21 = envelopeAt_0(&_S20, &(&kernelContext_1)->entryPointParams_0->signals_2, i_4, _S18, _S19);
        thread Side_0 _S22 = _S9.a_0;
        uint _S23 = Side_total_0(&_S22);
        if(i_4 < _S23)
        {
            *(_S6.p_1 + (row_0 * 2U * n_0 + i_4)) = _S17;
        }
        thread Side_0 _S24 = _S10.b_0;
        uint _S25 = Side_total_0(&_S24);
        if(i_4 < _S25)
        {
            *(_S6.p_1 + ((row_0 * 2U + 1U) * n_0 + i_4)) = _S21;
        }
        *(_S7.p_1 + (row_0 * n_0 + i_4)) = packed_float2(float2(_S17, _S21)) ;
        float e_1 = e_0 + (_S17 * _S17 + _S21 * _S21);
        uint i_5 = i_4 + 64U;
        k_0 = k_0 + 1U;
        i_4 = i_5;
        e_0 = e_1;
    }
    float _S26 = groupSum_0(e_0, lane_1, &kernelContext_1);
    if(lane_1 == 0U)
    {
        *(_S8.p_1 + g_0) = _S26;
    }
    return;
}

