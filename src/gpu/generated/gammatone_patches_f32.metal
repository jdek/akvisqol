#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct RO_0
{
    float device* p_0;
};

struct Signals_0
{
    RO_0 hi_0;
};

struct Side_0
{
    uint start_0;
    uint pad_0;
    uint len_0;
};

struct Windowed_0
{
    Signals_0 signals_0;
    Side_0 side_0;
    int start_1;
};

float RO_operatorx5Bx5D_get_0(const RO_0 constant* this_0, uint i_0)
{
    return *(this_0->p_0 + i_0);
}

uint Side_total_0(const Side_0 thread* this_1)
{
    return this_1->pad_0 + this_1->len_0;
}

float RO_operatorx5Bx5D_get_1(const RO_0 thread* this_2, uint i_1)
{
    return *(this_2->p_0 + i_1);
}

float Signals_at_0(const Signals_0 thread* this_3, uint i_2)
{
    float _S1 = RO_operatorx5Bx5D_get_1(&this_3->hi_0, i_2);
    return _S1;
}

float at_0(const Side_0 thread* s_0, const Signals_0 thread* signals_1, int i_3)
{
    uint _S2 = s_0->pad_0;
    bool _S3;
    if(i_3 < int(s_0->pad_0))
    {
        _S3 = true;
    }
    else
    {
        uint _S4 = Side_total_0(s_0);
        _S3 = i_3 >= int(_S4);
    }
    if(_S3)
    {
        return 0.0f;
    }
    float _S5 = Signals_at_0(signals_1, s_0->start_0 + uint(i_3) - _S2);
    return _S5;
}

float Windowed_at_0(const Windowed_0 thread* this_4, uint i_4)
{
    float _S6 = at_0(&this_4->side_0, &this_4->signals_0, this_4->start_1 + int(i_4));
    return _S6;
}

float gammatone_rms_0(const Windowed_0 thread* frame_0, uint band_0, const RO_0 constant* coeffs_0, const RO_0 constant* hann_0, uint window_size_0)
{
    uint o_0 = band_0 * 10U;
    float _S7 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0);
    float _S8 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 1U);
    float _S9 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 2U);
    float _S10 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 3U);
    float _S11 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 4U);
    float _S12 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 5U);
    float _S13 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 6U);
    float _S14 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 7U);
    float _S15 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 8U);
    float _S16 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 9U);
    float x1_1_0 = 0.0f;
    float dy_1_0 = 0.0f;
    float y_1_0 = 0.0f;
    float x2_1_0 = 0.0f;
    float dy_2_0 = 0.0f;
    float y_2_0 = 0.0f;
    float x2_2_0 = 0.0f;
    float dy_3_0 = 0.0f;
    float y_3_0 = 0.0f;
    float x2_3_0 = 0.0f;
    float dy_4_0 = 0.0f;
    float y_4_0 = 0.0f;
    float x2_4_0 = 0.0f;
    uint i_5 = 0U;
    float block_0 = 0.0f;
    float total_0 = 0.0f;
    for(;;)
    {
        if(i_5 < window_size_0)
        {
        }
        else
        {
            break;
        }
        float _S17 = Windowed_at_0(frame_0, i_5);
        float _S18 = RO_operatorx5Bx5D_get_0(hann_0, i_5);
        float x_0 = _S17 * _S18;
        float dy_1_1 = dy_1_0 + _S13 * dy_1_0 - _S14 * y_1_0 + (_S7 * (x_0 - x1_1_0) + _S8 * x1_1_0 + _S9 * x2_1_0);
        float y_1_1 = y_1_0 + dy_1_1;
        float dy_2_1 = dy_2_0 + _S13 * dy_2_0 - _S14 * y_2_0 + (_S15 * dy_1_1 + _S10 * y_1_0 + _S16 * x2_2_0);
        float y_2_1 = y_2_0 + dy_2_1;
        float dy_3_1 = dy_3_0 + _S13 * dy_3_0 - _S14 * y_3_0 + (_S15 * dy_2_1 + _S11 * y_2_0 + _S16 * x2_3_0);
        float y_3_1 = y_3_0 + dy_3_1;
        float dy_4_1 = dy_4_0 + _S13 * dy_4_0 - _S14 * y_4_0 + (_S15 * dy_3_1 + _S12 * y_3_0 + _S16 * x2_4_0);
        float y_4_1 = y_4_0 + dy_4_1;
        float block_1 = block_0 + y_4_1 * y_4_1;
        if((i_5 & 63U) == 63U)
        {
            float total_1 = total_0 + block_1;
            block_0 = 0.0f;
            total_0 = total_1;
        }
        else
        {
            block_0 = block_1;
        }
        uint _S19 = i_5 + 1U;
        dy_1_0 = dy_1_1;
        x2_1_0 = x1_1_0;
        x1_1_0 = x_0;
        dy_2_0 = dy_2_1;
        x2_2_0 = y_1_0;
        y_1_0 = y_1_1;
        dy_3_0 = dy_3_1;
        x2_3_0 = y_2_0;
        y_2_0 = y_2_1;
        dy_4_0 = dy_4_1;
        y_4_0 = y_4_1;
        x2_4_0 = y_3_0;
        y_3_0 = y_3_1;
        i_5 = _S19;
    }
    return sqrt((total_0 + block_0) / float(window_size_0));
}

struct Inside_0
{
    Signals_0 signals_2;
    uint start_2;
};

float Inside_at_0(const Inside_0 thread* this_5, uint i_6)
{
    float _S20 = Signals_at_0(&this_5->signals_2, this_5->start_2 + i_6);
    return _S20;
}

float gammatone_rms_1(const Inside_0 thread* frame_1, uint band_1, const RO_0 constant* coeffs_1, const RO_0 constant* hann_1, uint window_size_1)
{
    uint o_1 = band_1 * 10U;
    float _S21 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1);
    float _S22 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 1U);
    float _S23 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 2U);
    float _S24 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 3U);
    float _S25 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 4U);
    float _S26 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 5U);
    float _S27 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 6U);
    float _S28 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 7U);
    float _S29 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 8U);
    float _S30 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 9U);
    float x1_1_1 = 0.0f;
    float dy_1_2 = 0.0f;
    float y_1_2 = 0.0f;
    float x2_1_1 = 0.0f;
    float dy_2_2 = 0.0f;
    float y_2_2 = 0.0f;
    float x2_2_1 = 0.0f;
    float dy_3_2 = 0.0f;
    float y_3_2 = 0.0f;
    float x2_3_1 = 0.0f;
    float dy_4_2 = 0.0f;
    float y_4_2 = 0.0f;
    float x2_4_1 = 0.0f;
    uint i_7 = 0U;
    float block_2 = 0.0f;
    float total_2 = 0.0f;
    for(;;)
    {
        if(i_7 < window_size_1)
        {
        }
        else
        {
            break;
        }
        float _S31 = Inside_at_0(frame_1, i_7);
        float _S32 = RO_operatorx5Bx5D_get_0(hann_1, i_7);
        float x_1 = _S31 * _S32;
        float dy_1_3 = dy_1_2 + _S27 * dy_1_2 - _S28 * y_1_2 + (_S21 * (x_1 - x1_1_1) + _S22 * x1_1_1 + _S23 * x2_1_1);
        float y_1_3 = y_1_2 + dy_1_3;
        float dy_2_3 = dy_2_2 + _S27 * dy_2_2 - _S28 * y_2_2 + (_S29 * dy_1_3 + _S24 * y_1_2 + _S30 * x2_2_1);
        float y_2_3 = y_2_2 + dy_2_3;
        float dy_3_3 = dy_3_2 + _S27 * dy_3_2 - _S28 * y_3_2 + (_S29 * dy_2_3 + _S25 * y_2_2 + _S30 * x2_3_1);
        float y_3_3 = y_3_2 + dy_3_3;
        float dy_4_3 = dy_4_2 + _S27 * dy_4_2 - _S28 * y_4_2 + (_S29 * dy_3_3 + _S26 * y_3_2 + _S30 * x2_4_1);
        float y_4_3 = y_4_2 + dy_4_3;
        float block_3 = block_2 + y_4_3 * y_4_3;
        if((i_7 & 63U) == 63U)
        {
            float total_3 = total_2 + block_3;
            block_2 = 0.0f;
            total_2 = total_3;
        }
        else
        {
            block_2 = block_3;
        }
        uint _S33 = i_7 + 1U;
        dy_1_2 = dy_1_3;
        x2_1_1 = x1_1_1;
        x1_1_1 = x_1;
        dy_2_2 = dy_2_3;
        x2_2_1 = y_1_2;
        y_1_2 = y_1_3;
        dy_3_2 = dy_3_3;
        x2_3_1 = y_2_2;
        y_2_2 = y_2_3;
        dy_4_2 = dy_4_3;
        y_4_2 = y_4_3;
        x2_4_1 = y_3_2;
        y_3_2 = y_3_3;
        i_7 = _S33;
    }
    return sqrt((total_2 + block_2) / float(window_size_1));
}

float RO_operatorx5Bx5D_get_2(const RO_0 constant* this_6, uint i_8)
{
    return *(this_6->p_0 + i_8);
}

struct RO_1
{
    uint device* p_0;
};

uint RO_operatorx5Bx5D_get_3(const RO_1 constant* this_7, uint i_9)
{
    return *(this_7->p_0 + i_9);
}

struct RO_2
{
    int device* p_0;
};

int RO_operatorx5Bx5D_get_4(const RO_2 constant* this_8, uint i_10)
{
    return *(this_8->p_0 + i_10);
}

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

struct RO_3
{
    LagRow_0 device* p_0;
};

LagRow_0 RO_operatorx5Bx5D_get_5(const RO_3 constant* this_9, uint i_11)
{
    return *(this_9->p_0 + i_11);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

struct Trim_0
{
    int lag_0;
    int head_0;
    int len_1;
};

Trim_0 Trim_x24init_0(int lag_1, int head_1, int len_2)
{
    thread Trim_0 _S34;
    (&_S34)->lag_0 = lag_1;
    (&_S34)->head_0 = head_1;
    (&_S34)->len_1 = len_2;
    return _S34;
}

Trim_0 trim_0(const LagRow_0 thread* row_0, int lag_2, const RO_1 constant* back_0)
{
    uint _S35 = Side_total_0(&row_0->a_0);
    int r_0 = int(_S35);
    uint _S36 = Side_total_0(&row_0->b_0);
    int d_0 = int(_S36);
    bool _S37;
    if(lag_2 == int(0))
    {
        _S37 = true;
    }
    else
    {
        _S37 = (abs(lag_2)) > (r_0 / int(2));
    }
    int _S38;
    if(_S37)
    {
        _S38 = int(0);
    }
    else
    {
        _S38 = lag_2;
    }
    int dl_0;
    if(_S38 < int(0))
    {
        dl_0 = d_0 - min(- _S38, d_0);
    }
    else
    {
        dl_0 = d_0 + _S38;
    }
    thread Trim_0 t_0 = Trim_x24init_0(_S38, int(0), r_0);
    if(r_0 > dl_0)
    {
        (&t_0)->len_1 = dl_0;
    }
    else
    {
        if(r_0 < dl_0)
        {
            _S37 = _S38 > int(0);
        }
        else
        {
            _S37 = false;
        }
        if(_S37)
        {
            uint _S39 = RO_operatorx5Bx5D_get_3(back_0, uint(_S38 / int(32)));
            int _S40 = _S38 - int((_S39 >> uint(_S38 % int(32))) & 1U);
            (&t_0)->head_0 = _S40;
            if(_S40 > int(0))
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

uint Trim_frames_0(const Trim_0 thread* this_10, uint window_size_2, uint hop_size_0)
{
    int _S41 = this_10->len_1;
    uint _S42;
    if((this_10->len_1) < int(window_size_2))
    {
        _S42 = 0U;
    }
    else
    {
        uint _S43 = (uint(_S41) - window_size_2) / hop_size_0;
        _S42 = 1U + _S43;
    }
    return _S42;
}

Signals_0 Signals_x24init_0(const RO_0 constant* hi_1)
{
    thread Signals_0 _S44;
    (&_S44)->hi_0 = *hi_1;
    return _S44;
}

Inside_0 Inside_x24init_0(const Signals_0 thread* signals_3, uint start_3)
{
    thread Inside_0 _S45;
    (&_S45)->signals_2 = *signals_3;
    (&_S45)->start_2 = start_3;
    return _S45;
}

Windowed_0 Windowed_x24init_0(const Signals_0 thread* signals_4, const Side_0 thread* side_1, int start_4)
{
    thread Windowed_0 _S46;
    (&_S46)->signals_0 = *signals_4;
    (&_S46)->side_0 = *side_1;
    (&_S46)->start_1 = start_4;
    return _S46;
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_0 signals_5;
    RO_3 rows_0;
    RO_1 slots_1;
    RO_2 lags_0;
    RO_1 status_0;
    RO_1 back_1;
    RO_0 coeffs_2;
    RO_0 hann_2;
    RO_0 raw_0;
    RW_0 out_0;
    uint copy_raw_0;
    uint first_slot_1;
    uint total_4;
    uint num_bands_0;
    uint window_size_3;
    uint hop_size_1;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void gammatone_patches(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S47 = entryPointParams_1->out_0;
    uint gid_0 = zimt_index_0(tid_1);
    if(gid_0 >= (entryPointParams_1->total_4))
    {
        return;
    }
    uint band_2 = gid_0 % (&kernelContext_0)->entryPointParams_0->num_bands_0;
    uint _S48 = gid_0 / (&kernelContext_0)->entryPointParams_0->num_bands_0;
    bool ref_0 = (_S48 % 2U) == 0U;
    uint _S49 = gid_0 / (&kernelContext_0)->entryPointParams_0->num_bands_0;
    uint slot_0 = (&kernelContext_0)->entryPointParams_0->first_slot_1 + _S49 / 2U;
    uint _S50 = RO_operatorx5Bx5D_get_3(&(&kernelContext_0)->entryPointParams_0->slots_1, slot_0);
    uint _S51 = RO_operatorx5Bx5D_get_3(&(&kernelContext_0)->entryPointParams_0->status_0, _S50);
    if(_S51 != 0U)
    {
        return;
    }
    LagRow_0 _S52 = RO_operatorx5Bx5D_get_5(&(&kernelContext_0)->entryPointParams_0->rows_0, _S50);
    int _S53 = RO_operatorx5Bx5D_get_4(&(&kernelContext_0)->entryPointParams_0->lags_0, _S50);
    thread LagRow_0 _S54 = _S52;
    Trim_0 _S55 = trim_0(&_S54, _S53, &(&kernelContext_0)->entryPointParams_0->back_1);
    uint _S56 = (&kernelContext_0)->entryPointParams_0->window_size_3;
    uint _S57 = (&kernelContext_0)->entryPointParams_0->hop_size_1;
    thread Trim_0 _S58 = _S55;
    uint _S59 = Trim_frames_0(&_S58, _S56, _S57);
    if(_S59 == 0U)
    {
        return;
    }
    uint f_0 = slot_0 - _S52.first_slot_0;
    if(f_0 >= _S59)
    {
        return;
    }
    int off_0;
    if(ref_0)
    {
        off_0 = _S55.head_0;
    }
    else
    {
        off_0 = _S55.head_0 - _S55.lag_0;
    }
    Side_0 s_1;
    if(ref_0)
    {
        s_1 = _S52.a_0;
    }
    else
    {
        s_1 = _S52.b_0;
    }
    uint _S60 = _S52.first_slot_0 * 2U * (&kernelContext_0)->entryPointParams_0->num_bands_0;
    uint grid_0;
    if(ref_0)
    {
        grid_0 = 0U;
    }
    else
    {
        grid_0 = (&kernelContext_0)->entryPointParams_0->num_bands_0 * _S52.slots_0;
    }
    uint base_0 = _S60 + grid_0;
    if(ref_0)
    {
        grid_0 = _S52.a_grid_0;
    }
    else
    {
        grid_0 = _S52.b_grid_0;
    }
    bool _S61;
    if(grid_0 > 0U)
    {
        _S61 = off_0 >= int(s_1.pad_0);
    }
    else
    {
        _S61 = false;
    }
    if(_S61)
    {
        uint _S62;
        if(ref_0)
        {
            _S62 = _S52.a_base_0;
        }
        else
        {
            _S62 = _S52.b_base_0;
        }
        uint start_5 = _S62 + uint(off_0) - s_1.pad_0;
        uint _S63 = start_5 % (&kernelContext_0)->entryPointParams_0->hop_size_1;
        if(_S63 == 0U)
        {
            uint _S64 = start_5 / (&kernelContext_0)->entryPointParams_0->hop_size_1;
            _S61 = (_S64 + _S59) <= grid_0;
        }
        else
        {
            _S61 = false;
        }
        if(_S61)
        {
            if(((&kernelContext_0)->entryPointParams_0->copy_raw_0) != 0U)
            {
                uint _S65 = base_0 + band_2 * _S59 + f_0;
                if(ref_0)
                {
                    _S62 = _S52.a_raw_0;
                }
                else
                {
                    _S62 = _S52.b_raw_0;
                }
                uint _S66 = _S62 + band_2 * grid_0;
                uint _S67 = start_5 / (&kernelContext_0)->entryPointParams_0->hop_size_1;
                float _S68 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->raw_0, _S66 + _S67 + f_0);
                *(_S47.p_1 + _S65) = _S68;
            }
            return;
        }
    }
    int first_0 = off_0 + int(f_0 * (&kernelContext_0)->entryPointParams_0->hop_size_1);
    Signals_0 _S69 = Signals_x24init_0(&(&kernelContext_0)->entryPointParams_0->signals_5);
    Side_0 _S70 = s_1;
    if(first_0 >= int(s_1.pad_0))
    {
        int _S71 = first_0 + int((&kernelContext_0)->entryPointParams_0->window_size_3);
        thread Side_0 _S72 = s_1;
        uint _S73 = Side_total_0(&_S72);
        _S61 = _S71 <= int(_S73);
    }
    else
    {
        _S61 = false;
    }
    float rms_0;
    if(_S61)
    {
        uint _S74 = s_1.start_0 + uint(first_0) - _S70.pad_0;
        thread Signals_0 _S75 = _S69;
        Inside_0 _S76 = Inside_x24init_0(&_S75, _S74);
        uint _S77 = (&kernelContext_0)->entryPointParams_0->window_size_3;
        thread Inside_0 _S78 = _S76;
        float _S79 = gammatone_rms_1(&_S78, band_2, &(&kernelContext_0)->entryPointParams_0->coeffs_2, &(&kernelContext_0)->entryPointParams_0->hann_2, _S77);
        rms_0 = _S79;
    }
    else
    {
        thread Signals_0 _S80 = _S69;
        thread Side_0 _S81 = s_1;
        Windowed_0 _S82 = Windowed_x24init_0(&_S80, &_S81, first_0);
        uint _S83 = (&kernelContext_0)->entryPointParams_0->window_size_3;
        thread Windowed_0 _S84 = _S82;
        float _S85 = gammatone_rms_0(&_S84, band_2, &(&kernelContext_0)->entryPointParams_0->coeffs_2, &(&kernelContext_0)->entryPointParams_0->hann_2, _S83);
        rms_0 = _S85;
    }
    *(_S47.p_1 + (base_0 + band_2 * _S59 + f_0)) = rms_0;
    return;
}

