#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
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

struct RW_0
{
    LagRow_0 device* p_0;
};

LagRow_0 RW_operatorx5Bx5D_get_0(const RW_0 constant* this_0, uint i_0)
{
    return *(this_0->p_0 + i_0);
}

struct RO_0
{
    Side_0 device* p_1;
};

Side_0 RO_operatorx5Bx5D_get_0(const RO_0 constant* this_1, uint i_1)
{
    return *(this_1->p_1 + i_1);
}

struct Match_0
{
    uint deg_frame_0;
    uint visited_0;
    uint valid_0;
};

struct RO_1
{
    Match_0 device* p_1;
};

Match_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_2, uint i_2)
{
    return *(this_2->p_1 + i_2);
}

struct RealignPatch_0
{
    uint patch_0;
    uint deg_off_0;
    uint slices_0;
};

struct RO_2
{
    RealignPatch_0 device* p_1;
};

RealignPatch_0 RO_operatorx5Bx5D_get_2(const RO_2 constant* this_3, uint i_3)
{
    return *(this_3->p_1 + i_3);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

Side_0 Side_x24init_0(uint start_1, uint pad_1, uint len_1)
{
    thread Side_0 _S1;
    (&_S1)->start_0 = start_1;
    (&_S1)->pad_0 = pad_1;
    (&_S1)->len_0 = len_1;
    return _S1;
}

uint Side_total_0(const Side_0 thread* this_4)
{
    return this_4->pad_0 + this_4->len_0;
}

struct LagParams_0
{
    uint max_lag_0;
    float slack_0;
};

LagParams_0 LagParams_x24init_0(uint max_lag_1, float slack_1)
{
    thread LagParams_0 _S2;
    (&_S2)->max_lag_0 = max_lag_1;
    (&_S2)->slack_0 = slack_1;
    return _S2;
}

struct RW_1
{
    LagParams_0 device* p_0;
};

struct EntryPointParams_0
{
    RO_2 patches_0;
    RO_1 matches_0;
    RO_0 slices_1;
    RW_0 rows_0;
    RW_1 params_0;
    uint num_rows_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void realign_rows(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_1 _S3 = entryPointParams_1->params_0;
    uint row_0 = zimt_index_0(tid_1);
    if(row_0 >= (entryPointParams_1->num_rows_0))
    {
        return;
    }
    RealignPatch_0 _S4 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->patches_0, row_0);
    Match_0 _S5 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->matches_0, _S4.patch_0);
    thread Side_0 s_0 = Side_x24init_0(_S4.deg_off_0, 0U, 0U);
    bool _S6;
    if((_S5.visited_0) != 0U)
    {
        _S6 = (_S5.valid_0) != 0U;
    }
    else
    {
        _S6 = false;
    }
    uint base_0;
    if(_S6)
    {
        Side_0 _S7 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->slices_1, _S4.slices_0 + _S5.deg_frame_0);
        (&s_0)->start_0 = _S4.deg_off_0 + _S7.start_0;
        (&s_0)->pad_0 = _S7.pad_0;
        (&s_0)->len_0 = _S7.len_0;
        base_0 = _S7.start_0;
    }
    else
    {
        base_0 = 0U;
    }
    ((&kernelContext_0)->entryPointParams_0->rows_0.p_0 + row_0)->b_0 = s_0;
    ((&kernelContext_0)->entryPointParams_0->rows_0.p_0 + row_0)->b_base_0 = base_0;
    LagRow_0 _S8 = RW_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    thread Side_0 _S9 = _S8.a_0;
    uint _S10 = Side_total_0(&_S9);
    thread Side_0 _S11 = s_0;
    uint _S12 = Side_total_0(&_S11);
    *(_S3.p_0 + row_0) = LagParams_x24init_0(max(max(_S10, _S12), 1U) - 1U, 0.0f);
    return;
}

