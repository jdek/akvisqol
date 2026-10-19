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

struct Alignment_0
{
    uint deg_off_0;
    uint skip_0;
    uint zeros_0;
    uint out_off_0;
    uint len_0;
};

struct RO_1
{
    Alignment_0 device* p_0;
};

Alignment_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
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
    RO_0 signals_0;
    RO_1 alignments_0;
    RO_0 factors_0;
    RW_0 out_0;
    uint num_pairs_0;
    uint max_len_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void apply_lag(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S1 = entryPointParams_1->out_0;
    uint id_0 = zimt_index_0(tid_1);
    uint k_0 = id_0 / entryPointParams_1->max_len_0;
    uint i_2 = id_0 % entryPointParams_1->max_len_0;
    if(k_0 >= ((&kernelContext_0)->entryPointParams_0->num_pairs_0))
    {
        return;
    }
    Alignment_0 _S2 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->alignments_0, k_0);
    if(i_2 >= (_S2.len_0))
    {
        return;
    }
    uint _S3 = _S2.out_off_0 + i_2;
    float _S4;
    if(i_2 < (_S2.zeros_0))
    {
        _S4 = 0.0f;
    }
    else
    {
        float _S5 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->signals_0, _S2.deg_off_0 + _S2.skip_0 + i_2 - _S2.zeros_0);
        float _S6 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->factors_0, k_0);
        _S4 = _S5 * _S6;
    }
    *(_S1.p_1 + _S3) = _S4;
    return;
}

