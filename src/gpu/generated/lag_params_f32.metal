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

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

struct LagParams_0
{
    uint max_lag_0;
    float slack_0;
};

struct RW_0
{
    LagParams_0 device* p_1;
};

struct EntryPointParams_0
{
    RO_0 energy_0;
    RW_0 params_0;
    uint log2_n_0;
    uint block_0;
    uint num_rows_0;
    float slack_scale_0;
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

[[kernel]] void lag_params(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_1;
    (&kernelContext_1)->entryPointParams_0 = entryPointParams_1;
    threadgroup array<float, int(64)> acc_1;
    (&kernelContext_1)->acc_0 = &acc_1;
    uint row_0 = zimt_index_0(tid_1) / 64U;
    uint lane_1 = tid_1.x % 64U;
    if(row_0 >= (entryPointParams_1->num_rows_0))
    {
        return;
    }
    uint _S1 = (1U << ((&kernelContext_1)->entryPointParams_0->log2_n_0)) / (&kernelContext_1)->entryPointParams_0->block_0;
    uint b_0 = lane_1;
    float e_0 = 0.0f;
    for(;;)
    {
        if(b_0 < _S1)
        {
        }
        else
        {
            break;
        }
        float _S2 = RO_operatorx5Bx5D_get_0(&(&kernelContext_1)->entryPointParams_0->energy_0, row_0 * _S1 + b_0);
        float e_1 = e_0 + _S2;
        b_0 = b_0 + 64U;
        e_0 = e_1;
    }
    float _S3 = groupSum_0(e_0, lane_1, &kernelContext_1);
    if(lane_1 == 0U)
    {
        ((&kernelContext_1)->entryPointParams_0->params_0.p_1 + row_0)->slack_0 = _S3 * (&kernelContext_1)->entryPointParams_0->slack_scale_0;
    }
    return;
}

