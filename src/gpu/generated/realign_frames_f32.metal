#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct RW_0
{
    uint device* p_0;
};

uint RW_operatorx5Bx5D_get_0(const RW_0 constant* this_0, uint i_0)
{
    return *(this_0->p_0 + i_0);
}

struct RO_0
{
    uint device* p_1;
};

uint RO_operatorx5Bx5D_get_0(const RO_0 constant* this_1, uint i_1)
{
    return *(this_1->p_1 + i_1);
}

struct RO_1
{
    int device* p_1;
};

int RO_operatorx5Bx5D_get_1(const RO_1 constant* this_2, uint i_2)
{
    return *(this_2->p_1 + i_2);
}

struct Match_0
{
    uint deg_frame_0;
    uint visited_0;
    uint valid_0;
};

struct RO_2
{
    Match_0 device* p_1;
};

Match_0 RO_operatorx5Bx5D_get_2(const RO_2 constant* this_3, uint i_3)
{
    return *(this_3->p_1 + i_3);
}

struct RealignPatch_0
{
    uint patch_0;
    uint deg_off_0;
    uint slices_0;
};

struct RO_3
{
    RealignPatch_0 device* p_1;
};

RealignPatch_0 RO_operatorx5Bx5D_get_3(const RO_3 constant* this_4, uint i_4)
{
    return *(this_4->p_1 + i_4);
}

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

struct RO_4
{
    LagRow_0 device* p_1;
};

LagRow_0 RO_operatorx5Bx5D_get_4(const RO_4 constant* this_5, uint i_5)
{
    return *(this_5->p_1 + i_5);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

uint Side_total_0(const Side_0 thread* this_6)
{
    return this_6->pad_0 + this_6->len_0;
}

struct Trim_0
{
    int lag_0;
    int head_0;
    int len_1;
};

Trim_0 Trim_x24init_0(int lag_1, int head_1, int len_2)
{
    thread Trim_0 _S1;
    (&_S1)->lag_0 = lag_1;
    (&_S1)->head_0 = head_1;
    (&_S1)->len_1 = len_2;
    return _S1;
}

Trim_0 trim_0(const LagRow_0 thread* row_0, int lag_2, const RO_0 constant* back_0)
{
    uint _S2 = Side_total_0(&row_0->a_0);
    int r_0 = int(_S2);
    uint _S3 = Side_total_0(&row_0->b_0);
    int d_0 = int(_S3);
    bool _S4;
    if(lag_2 == int(0))
    {
        _S4 = true;
    }
    else
    {
        _S4 = (abs(lag_2)) > (r_0 / int(2));
    }
    int _S5;
    if(_S4)
    {
        _S5 = int(0);
    }
    else
    {
        _S5 = lag_2;
    }
    int dl_0;
    if(_S5 < int(0))
    {
        dl_0 = d_0 - min(- _S5, d_0);
    }
    else
    {
        dl_0 = d_0 + _S5;
    }
    thread Trim_0 t_0 = Trim_x24init_0(_S5, int(0), r_0);
    if(r_0 > dl_0)
    {
        (&t_0)->len_1 = dl_0;
    }
    else
    {
        if(r_0 < dl_0)
        {
            _S4 = _S5 > int(0);
        }
        else
        {
            _S4 = false;
        }
        if(_S4)
        {
            uint _S6 = RO_operatorx5Bx5D_get_0(back_0, uint(_S5 / int(32)));
            int _S7 = _S5 - int((_S6 >> uint(_S5 % int(32))) & 1U);
            (&t_0)->head_0 = _S7;
            if(_S7 > int(0))
            {
                (&t_0)->len_1 = r_0 - (&t_0)->head_0;
            }
            else
            {
                (&t_0)->head_0 = int(0);
            }
        }
    }
    return t_0;
}

uint Trim_frames_0(const Trim_0 thread* this_7, uint window_size_0, uint hop_size_0)
{
    int _S8 = this_7->len_1;
    uint _S9;
    if((this_7->len_1) < int(window_size_0))
    {
        _S9 = 0U;
    }
    else
    {
        uint _S10 = (uint(_S8) - window_size_0) / hop_size_0;
        _S9 = 1U + _S10;
    }
    return _S9;
}

struct SpecPair_0
{
    uint ref_off_0;
    uint ref_frames_0;
    uint deg_off_1;
    uint deg_frames_0;
};

SpecPair_0 SpecPair_x24init_0(uint ref_off_1, uint ref_frames_1, uint deg_off_2, uint deg_frames_1)
{
    thread SpecPair_0 _S11;
    (&_S11)->ref_off_0 = ref_off_1;
    (&_S11)->ref_frames_0 = ref_frames_1;
    (&_S11)->deg_off_1 = deg_off_2;
    (&_S11)->deg_frames_0 = deg_frames_1;
    return _S11;
}

struct PatchPair_0
{
    uint ref_off_2;
    uint ref_frames_2;
    uint ref_frame_0;
    uint deg_off_3;
    uint deg_frames_2;
    uint deg_frame_1;
    uint cols_0;
};

PatchPair_0 PatchPair_x24init_0(uint ref_off_3, uint ref_frames_3, uint ref_frame_1, uint deg_off_4, uint deg_frames_3, uint deg_frame_2, uint cols_1)
{
    thread PatchPair_0 _S12;
    (&_S12)->ref_off_2 = ref_off_3;
    (&_S12)->ref_frames_2 = ref_frames_3;
    (&_S12)->ref_frame_0 = ref_frame_1;
    (&_S12)->deg_off_3 = deg_off_4;
    (&_S12)->deg_frames_2 = deg_frames_3;
    (&_S12)->deg_frame_1 = deg_frame_2;
    (&_S12)->cols_0 = cols_1;
    return _S12;
}

struct Realigned_0
{
    int lag_3;
    uint deg_total_0;
    uint accepted_0;
};

Realigned_0 Realigned_x24init_0(int lag_4, uint deg_total_1, uint accepted_1)
{
    thread Realigned_0 _S13;
    (&_S13)->lag_3 = lag_4;
    (&_S13)->deg_total_0 = deg_total_1;
    (&_S13)->accepted_0 = accepted_1;
    return _S13;
}

struct RW_1
{
    SpecPair_0 device* p_0;
};

struct RW_2
{
    PatchPair_0 device* p_0;
};

struct RW_3
{
    Realigned_0 device* p_0;
};

struct EntryPointParams_0
{
    RO_3 patches_0;
    RO_2 matches_0;
    RO_4 rows_0;
    RO_1 lags_0;
    RW_0 status_0;
    RO_0 back_1;
    RW_1 specs_0;
    RW_2 pairs_0;
    RW_0 active_0;
    RW_3 realigned_0;
    uint num_rows_0;
    uint num_bands_0;
    uint window_size_1;
    uint hop_size_1;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void realign_frames(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S14 = entryPointParams_1->status_0;
    RW_1 _S15 = entryPointParams_1->specs_0;
    RW_2 _S16 = entryPointParams_1->pairs_0;
    RW_0 _S17 = entryPointParams_1->active_0;
    RW_3 _S18 = entryPointParams_1->realigned_0;
    uint row_1 = zimt_index_0(tid_1);
    if(row_1 >= (entryPointParams_1->num_rows_0))
    {
        return;
    }
    LagRow_0 _S19 = RO_operatorx5Bx5D_get_4(&(&kernelContext_0)->entryPointParams_0->rows_0, row_1);
    RealignPatch_0 _S20 = RO_operatorx5Bx5D_get_3(&(&kernelContext_0)->entryPointParams_0->patches_0, row_1);
    Match_0 _S21 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->matches_0, _S20.patch_0);
    int _S22 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->lags_0, row_1);
    thread LagRow_0 _S23 = _S19;
    Trim_0 _S24 = trim_0(&_S23, _S22, &(&kernelContext_0)->entryPointParams_0->back_1);
    uint _S25 = (&kernelContext_0)->entryPointParams_0->window_size_1;
    uint _S26 = (&kernelContext_0)->entryPointParams_0->hop_size_1;
    thread Trim_0 _S27 = _S24;
    uint _S28 = Trim_frames_0(&_S27, _S25, _S26);
    bool live_0;
    if((_S21.visited_0) != 0U)
    {
        live_0 = (_S21.valid_0) != 0U;
    }
    else
    {
        live_0 = false;
    }
    if(live_0)
    {
        thread Side_0 _S29 = _S19.a_0;
        uint _S30 = Side_total_0(&_S29);
        live_0 = _S30 >= ((&kernelContext_0)->entryPointParams_0->window_size_1);
    }
    else
    {
        live_0 = false;
    }
    if(live_0)
    {
        thread Side_0 _S31 = _S19.b_0;
        uint _S32 = Side_total_0(&_S31);
        live_0 = _S32 >= ((&kernelContext_0)->entryPointParams_0->window_size_1);
    }
    else
    {
        live_0 = false;
    }
    if(!live_0)
    {
        *(_S14.p_0 + row_1) = 2U;
    }
    if(live_0)
    {
        uint _S33 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->status_0, row_1);
        live_0 = _S33 == 0U;
    }
    else
    {
        live_0 = false;
    }
    bool on_0;
    if(live_0)
    {
        on_0 = _S28 > 0U;
    }
    else
    {
        on_0 = false;
    }
    uint base_0 = _S19.first_slot_0 * 2U * (&kernelContext_0)->entryPointParams_0->num_bands_0;
    uint _S34;
    if(on_0)
    {
        _S34 = _S28;
    }
    else
    {
        _S34 = 0U;
    }
    uint _S35 = base_0 + (&kernelContext_0)->entryPointParams_0->num_bands_0 * _S19.slots_0;
    uint _S36;
    if(on_0)
    {
        _S36 = _S28;
    }
    else
    {
        _S36 = 0U;
    }
    *(_S15.p_0 + row_1) = SpecPair_x24init_0(base_0, _S34, _S35, _S36);
    *(_S16.p_0 + row_1) = PatchPair_x24init_0(base_0, _S28, 0U, base_0 + (&kernelContext_0)->entryPointParams_0->num_bands_0 * _S19.slots_0, _S28, 0U, _S28);
    int _S37;
    if(on_0)
    {
        _S37 = int(1);
    }
    else
    {
        _S37 = int(0);
    }
    *(_S17.p_0 + row_1) = uint(_S37);
    int _S38 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->lags_0, row_1);
    thread Side_0 _S39 = _S19.b_0;
    uint _S40 = Side_total_0(&_S39);
    Realigned_0 ra_0 = Realigned_x24init_0(_S38, _S40, 0U);
    RealignPatch_0 _S41 = RO_operatorx5Bx5D_get_3(&(&kernelContext_0)->entryPointParams_0->patches_0, row_1);
    *(_S18.p_0 + _S41.patch_0) = ra_0;
    return;
}

