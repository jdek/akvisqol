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
    int device* p_0;
};

int RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

struct PairSignals_0
{
    uint ref_off_0;
    uint ref_len_0;
    uint deg_off_0;
    uint deg_len_0;
};

struct RO_2
{
    PairSignals_0 device* p_0;
};

PairSignals_0 RO_operatorx5Bx5D_get_2(const RO_2 constant* this_2, uint i_2)
{
    return *(this_2->p_0 + i_2);
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
    RO_0 signals_0;
    RO_2 pairs_0;
    RO_1 lags_0;
    RW_0 energy_0;
    uint num_pairs_0;
    uint block_0;
    uint blocks_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    array<float, int(64)> threadgroup* acc_0;
};

[[kernel]] void spl_energy(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    threadgroup array<float, int(64)> acc_1;
    (&kernelContext_0)->acc_0 = &acc_1;
    RW_0 _S1 = entryPointParams_1->energy_0;
    uint g_0 = zimt_index_0(tid_1) / 64U;
    uint lane_0 = tid_1.x % 64U;
    if(g_0 >= (entryPointParams_1->num_pairs_0 * 2U * entryPointParams_1->blocks_0))
    {
        return;
    }
    uint side_0 = g_0 / entryPointParams_1->blocks_0;
    PairSignals_0 _S2 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->pairs_0, side_0 / 2U);
    uint _S3 = _S2.ref_off_0 + _S2.ref_len_0;
    bool shift_0;
    uint from_0;
    uint to_0;
    if((side_0 % 2U) == 1U)
    {
        int _S4 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->lags_0, side_0 / 2U);
        if(_S4 < int(0))
        {
            shift_0 = uint(- _S4) <= (_S2.ref_len_0 / 2U);
        }
        else
        {
            shift_0 = false;
        }
        if(shift_0)
        {
            from_0 = min(uint(- _S4), _S2.deg_len_0);
        }
        else
        {
            from_0 = 0U;
        }
        uint _S5 = _S2.deg_off_0 + _S2.deg_len_0;
        from_0 = _S2.deg_off_0 + from_0;
        to_0 = _S5;
    }
    else
    {
        from_0 = _S2.ref_off_0;
        to_0 = _S3;
    }
    uint _S6 = g_0 % entryPointParams_1->blocks_0;
    uint _S7 = from_0 + _S6 * (&kernelContext_0)->entryPointParams_0->block_0 + lane_0;
    uint k_0 = 0U;
    uint i_3 = _S7;
    float e_0 = 0.0f;
    for(;;)
    {
        if(k_0 < ((&kernelContext_0)->entryPointParams_0->block_0 / 64U))
        {
            shift_0 = i_3 < to_0;
        }
        else
        {
            shift_0 = false;
        }
        if(shift_0)
        {
        }
        else
        {
            break;
        }
        float _S8 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->signals_0, i_3);
        float _S9 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->signals_0, i_3);
        float e_1 = e_0 + _S8 * _S9;
        uint i_4 = i_3 + 64U;
        k_0 = k_0 + 1U;
        i_3 = i_4;
        e_0 = e_1;
    }
    (*(&kernelContext_0)->acc_0)[lane_0] = e_0;
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
            (*(&kernelContext_0)->acc_0)[lane_0] = (*(&kernelContext_0)->acc_0)[lane_0] + (*(&kernelContext_0)->acc_0)[lane_0 + s_0];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        s_0 = s_0 >> 1U;
    }
    if(lane_0 == 0U)
    {
        *(_S1.p_1 + g_0) = (*(&kernelContext_0)->acc_0)[int(0)];
    }
    return;
}

