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
    uint cap_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    packed_float2 device* entryPointParams_corr_0;
    uint device* entryPointParams_params_0;
    uint device* entryPointParams_top_0;
    uint device* entryPointParams_count_0;
    int device* entryPointParams_cands_0;
};

[[kernel]] void lag_cands(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]], packed_float2 device* entryPointParams_corr_1 [[buffer(1)]], uint device* entryPointParams_params_1 [[buffer(2)]], uint device* entryPointParams_top_1 [[buffer(3)]], uint device* entryPointParams_count_1 [[buffer(4)]], int device* entryPointParams_cands_1 [[buffer(5)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    (&kernelContext_0)->entryPointParams_corr_0 = entryPointParams_corr_1;
    (&kernelContext_0)->entryPointParams_params_0 = entryPointParams_params_1;
    (&kernelContext_0)->entryPointParams_top_0 = entryPointParams_top_1;
    (&kernelContext_0)->entryPointParams_count_0 = entryPointParams_count_1;
    (&kernelContext_0)->entryPointParams_cands_0 = entryPointParams_cands_1;
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
    uint _S4 = row_1 * 2U;
    uint _S5 = (&kernelContext_0)->entryPointParams_params_0[_S4];
    float _S6 = (as_type<float>(((&kernelContext_0)->entryPointParams_top_0[row_1]))) - (as_type<float>(((&kernelContext_0)->entryPointParams_params_0[_S4 + 1U])));
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
        bool _S7;
        if(!lag_valid_0(i_2, n_1, _S5))
        {
            _S7 = true;
        }
        else
        {
            _S7 = !((lag_abs_0((&kernelContext_0)->entryPointParams_corr_0, row_1, i_2, (&kernelContext_0)->entryPointParams_0->log2_n_1)) >= _S6);
        }
        if(_S7)
        {
            k_0 = k_0 + 1U;
            continue;
        }
        uint slot_0 = atomic_fetch_add_explicit(((atomic_uint device*)((&kernelContext_0)->entryPointParams_count_0+row_1)), 1U, memory_order_relaxed);
        if(slot_0 < ((&kernelContext_0)->entryPointParams_0->cap_0))
        {
            int device* _S8 = (&kernelContext_0)->entryPointParams_cands_0+(row_1 * (&kernelContext_0)->entryPointParams_0->cap_0 + slot_0);
            int _S9;
            if(i_2 <= _S5)
            {
                _S9 = int(i_2);
            }
            else
            {
                _S9 = int(i_2) - int(n_1);
            }
            *_S8 = _S9;
        }
        k_0 = k_0 + 1U;
    }
    return;
}

