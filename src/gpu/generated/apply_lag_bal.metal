#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct RW_0
{
    float device* p_0;
};

float RW_operatorx5Bx5D_get_0(const RW_0 constant* this_0, uint i_0)
{
    return *(this_0->p_0 + i_0);
}

struct RO_0
{
    float device* p_1;
};

float RO_operatorx5Bx5D_get_0(const RO_0 constant* this_1, uint i_1)
{
    return *(this_1->p_1 + i_1);
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
    Alignment_0 device* p_1;
};

Alignment_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_2, uint i_2)
{
    return *(this_2->p_1 + i_2);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

struct DF_0
{
    float hi_0;
    float lo_0;
};

DF_0 DF_x24init_0(float x_0)
{
    thread DF_0 _S1;
    (&_S1)->hi_0 = x_0;
    (&_S1)->lo_0 = 0.0f;
    return _S1;
}

DF_0 DF_x24init_1(float h_0, float l_0)
{
    thread DF_0 _S2;
    (&_S2)->hi_0 = h_0;
    (&_S2)->lo_0 = l_0;
    return _S2;
}

DF_0 quickTwoSum_0(float a_0, float b_0)
{
    float s_0 = a_0 + b_0;
    return DF_x24init_1(s_0, b_0 - (s_0 - a_0));
}

DF_0 mul_0(const DF_0 thread* a_1, const DF_0 thread* b_1)
{
    float p_2 = a_1->hi_0 * b_1->hi_0;
    return quickTwoSum_0(p_2, fma(a_1->hi_0, b_1->hi_0, - p_2) + (a_1->hi_0 * b_1->lo_0 + a_1->lo_0 * b_1->hi_0));
}

struct EntryPointParams_0
{
    RO_0 signals_0;
    RO_1 alignments_0;
    RO_0 factors_0;
    RW_0 out_0;
    RW_0 lo_1;
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
    RW_0 _S3 = entryPointParams_1->out_0;
    RW_0 _S4 = entryPointParams_1->lo_1;
    uint id_0 = zimt_index_0(tid_1);
    uint k_0 = id_0 / entryPointParams_1->max_len_0;
    uint i_3 = id_0 % entryPointParams_1->max_len_0;
    if(k_0 >= ((&kernelContext_0)->entryPointParams_0->num_pairs_0))
    {
        return;
    }
    Alignment_0 _S5 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->alignments_0, k_0);
    if(i_3 >= (_S5.len_0))
    {
        return;
    }
    DF_0 _S6 = DF_x24init_0(0.0f);
    DF_0 x_1;
    if(i_3 >= (_S5.zeros_0))
    {
        uint src_0 = _S5.deg_off_0 + _S5.skip_0 + i_3 - _S5.zeros_0;
        float _S7 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->signals_0, src_0);
        float _S8 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->lo_1, src_0);
        DF_0 _S9 = DF_x24init_1(_S7, _S8);
        uint _S10 = k_0 * 2U;
        float _S11 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->factors_0, _S10);
        float _S12 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->factors_0, _S10 + 1U);
        DF_0 _S13 = DF_x24init_1(_S11, _S12);
        thread DF_0 _S14 = _S9;
        thread DF_0 _S15 = _S13;
        DF_0 _S16 = mul_0(&_S14, &_S15);
        x_1 = _S16;
    }
    else
    {
        x_1 = _S6;
    }
    uint _S17 = _S5.out_off_0 + i_3;
    *(_S3.p_0 + _S17) = x_1.hi_0;
    *(_S4.p_0 + _S17) = x_1.lo_0;
    return;
}

