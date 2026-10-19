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

struct LagParams_0
{
    uint max_lag_0;
    float slack_0;
};

struct RO_1
{
    LagParams_0 device* p_0;
};

LagParams_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

bool lag_valid_0(uint i_2, uint n_0, uint max_lag_1)
{
    bool _S1;
    if(i_2 <= max_lag_1)
    {
        _S1 = true;
    }
    else
    {
        _S1 = i_2 >= (n_0 - max_lag_1);
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

struct EntryPointParams_0
{
    RO_0 corr_1;
    RO_1 params_0;
    RW_0 top_0;
    uint log2_n_1;
    uint chunk_0;
    uint total_chunks_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void lag_max(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    uint g_0 = zimt_index_0(tid_1);
    if(g_0 >= (entryPointParams_1->total_chunks_0))
    {
        return;
    }
    uint n_1 = 1U << ((&kernelContext_0)->entryPointParams_0->log2_n_1);
    uint chunks_per_row_0 = n_1 / (&kernelContext_0)->entryPointParams_0->chunk_0;
    uint row_1 = g_0 / chunks_per_row_0;
    uint _S3 = g_0 % chunks_per_row_0;
    uint _S4 = _S3 * (&kernelContext_0)->entryPointParams_0->chunk_0;
    LagParams_0 _S5 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->params_0, row_1);
    uint m_0 = 0U;
    uint k_0 = 0U;
    for(;;)
    {
        if(k_0 < ((&kernelContext_0)->entryPointParams_0->chunk_0))
        {
        }
        else
        {
            break;
        }
        uint i_4 = _S4 + k_0;
        if(lag_valid_0(i_4, n_1, _S5.max_lag_0))
        {
            float _S6 = lag_abs_0(&(&kernelContext_0)->entryPointParams_0->corr_1, row_1, i_4, (&kernelContext_0)->entryPointParams_0->log2_n_1);
            m_0 = max(m_0, (as_type<uint>((_S6))));
        }
        k_0 = k_0 + 1U;
    }
    if(m_0 != 0U)
    {
        uint _S7 = atomic_fetch_max_explicit(((atomic_uint device*)((&kernelContext_0)->entryPointParams_0->top_0.p_1 + row_1)), m_0, memory_order_relaxed);
    }
    return;
}

