#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct RO_0
{
    packed_float2 device* p_0;
};

float2 RO_operatorx5Bx5D_get_0(const RO_0 constant* this_0, uint i_0)
{
    return float2(*(this_0->p_0 + i_0)) ;
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

bool lag_valid_0(uint i_2, uint n_0, uint max_lag_0)
{
    bool _S1;
    if(i_2 <= max_lag_0)
    {
        _S1 = true;
    }
    else
    {
        _S1 = i_2 >= (n_0 - max_lag_0);
    }
    return _S1;
}

float lag_abs_0(const RO_0 constant* corr_0, uint row_0, uint i_3, uint log2_n_0)
{
    float2 _S2 = RO_operatorx5Bx5D_get_0(corr_0, (row_0 << log2_n_0) + i_3);
    return abs(_S2.x);
}

struct RW_0
{
    uint device* p_1;
};

struct RW_1
{
    int device* p_1;
};

struct EntryPointParams_0
{
    RO_0 corr_1;
    RO_1 params_0;
    RO_1 top_0;
    RW_0 count_0;
    RW_1 cands_0;
    uint log2_n_1;
    uint total_chunks_0;
    uint cap_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void lag_cands(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_1 _S3 = entryPointParams_1->cands_0;
    uint g_0 = zimt_index_0(tid_1);
    if(g_0 >= (entryPointParams_1->total_chunks_0))
    {
        return;
    }
    uint n_1 = 1U << ((&kernelContext_0)->entryPointParams_0->log2_n_1);
    uint chunks_per_row_0 = n_1 / 64U;
    uint row_1 = g_0 / chunks_per_row_0;
    uint _S4 = g_0 % chunks_per_row_0;
    uint _S5 = _S4 * 64U;
    uint _S6 = row_1 * 2U;
    uint _S7 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->params_0, _S6);
    uint _S8 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->top_0, row_1);
    float _S9 = (as_type<float>((_S8)));
    uint _S10 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->params_0, _S6 + 1U);
    float _S11 = _S9 - (as_type<float>((_S10)));
    uint k_0 = 0U;
    for(;;)
    {
        if(k_0 < 64U)
        {
        }
        else
        {
            break;
        }
        uint i_4 = _S5 + k_0;
        bool _S12;
        if(!lag_valid_0(i_4, n_1, _S7))
        {
            _S12 = true;
        }
        else
        {
            float _S13 = lag_abs_0(&(&kernelContext_0)->entryPointParams_0->corr_1, row_1, i_4, (&kernelContext_0)->entryPointParams_0->log2_n_1);
            _S12 = !(_S13 >= _S11);
        }
        if(_S12)
        {
            k_0 = k_0 + 1U;
            continue;
        }
        uint slot_0 = atomic_fetch_add_explicit(((atomic_uint device*)((&kernelContext_0)->entryPointParams_0->count_0.p_1 + row_1)), 1U, memory_order_relaxed);
        if(slot_0 < ((&kernelContext_0)->entryPointParams_0->cap_0))
        {
            uint _S14 = row_1 * (&kernelContext_0)->entryPointParams_0->cap_0 + slot_0;
            int _S15;
            if(i_4 <= _S7)
            {
                _S15 = int(i_4);
            }
            else
            {
                _S15 = int(i_4) - int(n_1);
            }
            *(_S3.p_1 + _S14) = _S15;
        }
        k_0 = k_0 + 1U;
    }
    return;
}

