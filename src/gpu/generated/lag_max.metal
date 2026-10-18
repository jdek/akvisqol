#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

bool lag_valid_0(uint i_0, uint n_0, uint max_lag_0)
{
    bool _S1;
    if(i_0 <= max_lag_0)
    {
        _S1 = true;
    }
    else
    {
        _S1 = i_0 >= (n_0 - max_lag_0);
    }
    return _S1;
}

float lag_abs_0(packed_float2 device* corr_0, uint row_0, uint i_1, uint log2_n_0)
{
    return abs((float2(*(corr_0+((row_0 << log2_n_0) + i_1))) ).x);
}

struct EntryPointParams_0
{
    uint log2_n_1;
    uint total_chunks_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    packed_float2 device* entryPointParams_corr_0;
    uint device* entryPointParams_params_0;
    uint device* entryPointParams_top_0;
};

[[kernel]] void lag_max(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]], packed_float2 device* entryPointParams_corr_1 [[buffer(1)]], uint device* entryPointParams_params_1 [[buffer(2)]], uint device* entryPointParams_top_1 [[buffer(3)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    (&kernelContext_0)->entryPointParams_corr_0 = entryPointParams_corr_1;
    (&kernelContext_0)->entryPointParams_params_0 = entryPointParams_params_1;
    (&kernelContext_0)->entryPointParams_top_0 = entryPointParams_top_1;
    uint g_0 = zimt_index_0(tid_1);
    if(g_0 >= (entryPointParams_1->total_chunks_0))
    {
        return;
    }
    uint n_1 = 1U << ((&kernelContext_0)->entryPointParams_0->log2_n_1);
    uint chunks_per_row_0 = n_1 / 64U;
    uint row_1 = g_0 / chunks_per_row_0;
    uint _S2 = g_0 % chunks_per_row_0;
    uint _S3 = _S2 * 64U;
    uint _S4 = (&kernelContext_0)->entryPointParams_params_0[row_1 * 2U];
    uint m_0 = 0U;
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
        uint i_2 = _S3 + k_0;
        if(lag_valid_0(i_2, n_1, _S4))
        {
            m_0 = max(m_0, (as_type<uint>((lag_abs_0((&kernelContext_0)->entryPointParams_corr_0, row_1, i_2, (&kernelContext_0)->entryPointParams_0->log2_n_1)))));
        }
        k_0 = k_0 + 1U;
    }
    if(m_0 != 0U)
    {
        uint _S5 = atomic_fetch_max_explicit(((atomic_uint device*)((&kernelContext_0)->entryPointParams_top_0+row_1)), m_0, memory_order_relaxed);
    }
    return;
}

