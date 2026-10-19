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

struct FrameRun_0
{
    int start_0;
    uint count_0;
    uint out_0;
};

struct RO_1
{
    FrameRun_0 device* p_0;
};

FrameRun_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

struct SignalGrad_0
{
    uint start_1;
    uint len_0;
    uint first_run_0;
    uint runs_0;
    uint out_1;
};

struct RO_2
{
    SignalGrad_0 device* p_0;
};

SignalGrad_0 RO_operatorx5Bx5D_get_2(const RO_2 constant* this_2, uint i_2)
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
    RO_2 signals_0;
    RO_1 runs_1;
    RO_0 grads_0;
    RW_0 out_2;
    uint num_signals_0;
    uint max_len_0;
    uint window_size_0;
    uint hop_size_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void signal_grad(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S1 = entryPointParams_1->out_2;
    uint id_0 = zimt_index_0(tid_1);
    uint p_2 = id_0 / entryPointParams_1->max_len_0;
    uint i_3 = id_0 % entryPointParams_1->max_len_0;
    if(p_2 >= ((&kernelContext_0)->entryPointParams_0->num_signals_0))
    {
        return;
    }
    SignalGrad_0 _S2 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->signals_0, p_2);
    if(i_3 >= (_S2.len_0))
    {
        return;
    }
    int _S3 = int(_S2.start_1 + i_3);
    uint r_0 = 0U;
    float sum_0 = 0.0f;
    for(;;)
    {
        if(r_0 < (_S2.runs_0))
        {
        }
        else
        {
            break;
        }
        FrameRun_0 _S4 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->runs_1, _S2.first_run_0 + r_0);
        int rel_0 = _S3 - _S4.start_0;
        if(rel_0 < int(0))
        {
            r_0 = r_0 + 1U;
            continue;
        }
        int _S5 = rel_0 / int((&kernelContext_0)->entryPointParams_0->hop_size_0);
        int k_0 = min(_S5, int(_S4.count_0) - int(1));
        float sum_1 = sum_0;
        for(;;)
        {
            bool _S6;
            if(k_0 >= int(0))
            {
                _S6 = (rel_0 - k_0 * int((&kernelContext_0)->entryPointParams_0->hop_size_0)) < int((&kernelContext_0)->entryPointParams_0->window_size_0);
            }
            else
            {
                _S6 = false;
            }
            if(_S6)
            {
            }
            else
            {
                break;
            }
            float _S7 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->grads_0, _S4.out_0 + uint(k_0) * (&kernelContext_0)->entryPointParams_0->window_size_0 + uint(rel_0 - k_0 * int((&kernelContext_0)->entryPointParams_0->hop_size_0)));
            float sum_2 = sum_1 + _S7;
            k_0 = k_0 - int(1);
            sum_1 = sum_2;
        }
        sum_0 = sum_1;
        r_0 = r_0 + 1U;
    }
    *(_S1.p_1 + (_S2.out_1 + i_3)) = sum_0;
    return;
}

