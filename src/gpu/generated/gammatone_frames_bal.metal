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

float RO_operatorx5Bx5D_get_1(const RO_0 thread* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

struct Samples_0
{
    RO_0 signals_0;
    RO_0 signals_lo_0;
    uint start_0;
};

struct DF_0
{
    float hi_0;
    float lo_0;
};

DF_0 DF_x24init_0(float h_0, float l_0)
{
    thread DF_0 _S1;
    (&_S1)->hi_0 = h_0;
    (&_S1)->lo_0 = l_0;
    return _S1;
}

DF_0 DF_x24init_1(float x_0)
{
    thread DF_0 _S2;
    (&_S2)->hi_0 = x_0;
    (&_S2)->lo_0 = 0.0f;
    return _S2;
}

DF_0 Samples_at_0(const Samples_0 thread* this_2, uint i_2)
{
    uint _S3 = this_2->start_0 + i_2;
    float _S4 = RO_operatorx5Bx5D_get_1(&this_2->signals_0, _S3);
    float _S5 = RO_operatorx5Bx5D_get_1(&this_2->signals_lo_0, _S3);
    return DF_x24init_0(_S4, _S5);
}

DF_0 quickTwoSum_0(float a_0, float b_0)
{
    float s_0 = a_0 + b_0;
    return DF_x24init_0(s_0, b_0 - (s_0 - a_0));
}

DF_0 mul_0(const DF_0 thread* a_1, const DF_0 thread* b_1)
{
    float p_1 = a_1->hi_0 * b_1->hi_0;
    return quickTwoSum_0(p_1, fma(a_1->hi_0, b_1->hi_0, - p_1) + (a_1->hi_0 * b_1->lo_0 + a_1->lo_0 * b_1->hi_0));
}

DF_0 twoSum_0(float a_2, float b_2)
{
    float s_1 = a_2 + b_2;
    float bb_0 = s_1 - a_2;
    return DF_x24init_0(s_1, a_2 - (s_1 - bb_0) + (b_2 - bb_0));
}

DF_0 add_0(const DF_0 thread* a_3, const DF_0 thread* b_3)
{
    DF_0 s_2 = twoSum_0(a_3->hi_0, b_3->hi_0);
    DF_0 t_0 = twoSum_0(a_3->lo_0, b_3->lo_0);
    DF_0 s_3 = quickTwoSum_0(s_2.hi_0, s_2.lo_0 + t_0.hi_0);
    return quickTwoSum_0(s_3.hi_0, s_3.lo_0 + t_0.lo_0);
}

DF_0 neg_0(const DF_0 thread* a_4)
{
    return DF_x24init_0(- a_4->hi_0, - a_4->lo_0);
}

DF_0 sub_0(const DF_0 thread* a_5, const DF_0 thread* b_4)
{
    DF_0 _S6 = neg_0(b_4);
    thread DF_0 _S7 = _S6;
    DF_0 _S8 = add_0(a_5, &_S7);
    return _S8;
}

float DF_value_0(const DF_0 thread* this_3)
{
    return this_3->hi_0 + this_3->lo_0;
}

float gammatone_rms_0(const Samples_0 thread* frame_0, uint band_0, const RO_0 constant* coeffs_0, const RO_0 constant* hann_0, uint window_size_0)
{
    uint o_0 = band_0 * 20U;
    float _S9 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0);
    float _S10 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 10U);
    DF_0 _S11 = DF_x24init_0(_S9, _S10);
    float _S12 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 1U);
    float _S13 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 11U);
    DF_0 _S14 = DF_x24init_0(_S12, _S13);
    float _S15 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 2U);
    float _S16 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 12U);
    DF_0 _S17 = DF_x24init_0(_S15, _S16);
    float _S18 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 3U);
    float _S19 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 13U);
    DF_0 _S20 = DF_x24init_0(_S18, _S19);
    float _S21 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 4U);
    float _S22 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 14U);
    DF_0 _S23 = DF_x24init_0(_S21, _S22);
    float _S24 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 5U);
    float _S25 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 15U);
    DF_0 _S26 = DF_x24init_0(_S24, _S25);
    float _S27 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 6U);
    float _S28 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 16U);
    DF_0 _S29 = DF_x24init_0(_S27, _S28);
    float _S30 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 7U);
    float _S31 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 17U);
    DF_0 _S32 = DF_x24init_0(_S30, _S31);
    DF_0 _S33 = DF_x24init_1(0.0f);
    DF_0 s1c0_0 = _S33;
    DF_0 s1c1_0 = _S33;
    DF_0 s2c0_0 = _S33;
    DF_0 s2c1_0 = _S33;
    DF_0 s3c0_0 = _S33;
    DF_0 s3c1_0 = _S33;
    DF_0 s4c0_0 = _S33;
    DF_0 s4c1_0 = _S33;
    DF_0 sum_sq_0 = _S33;
    uint i_3 = 0U;
    for(;;)
    {
        if(i_3 < window_size_0)
        {
        }
        else
        {
            break;
        }
        DF_0 _S34 = Samples_at_0(frame_0, i_3);
        float _S35 = RO_operatorx5Bx5D_get_0(hann_0, i_3);
        float _S36 = RO_operatorx5Bx5D_get_0(hann_0, window_size_0 + i_3);
        DF_0 _S37 = DF_x24init_0(_S35, _S36);
        thread DF_0 _S38 = _S34;
        thread DF_0 _S39 = _S37;
        DF_0 _S40 = mul_0(&_S38, &_S39);
        thread DF_0 _S41 = _S11;
        thread DF_0 _S42 = _S40;
        DF_0 _S43 = mul_0(&_S41, &_S42);
        thread DF_0 _S44 = _S43;
        thread DF_0 _S45 = s1c0_0;
        DF_0 _S46 = add_0(&_S44, &_S45);
        thread DF_0 _S47 = _S14;
        thread DF_0 _S48 = _S40;
        DF_0 _S49 = mul_0(&_S47, &_S48);
        thread DF_0 _S50 = _S49;
        thread DF_0 _S51 = s1c1_0;
        DF_0 _S52 = add_0(&_S50, &_S51);
        thread DF_0 _S53 = _S29;
        thread DF_0 _S54 = _S46;
        DF_0 _S55 = mul_0(&_S53, &_S54);
        thread DF_0 _S56 = _S52;
        thread DF_0 _S57 = _S55;
        DF_0 _S58 = sub_0(&_S56, &_S57);
        thread DF_0 _S59 = _S32;
        thread DF_0 _S60 = _S46;
        DF_0 _S61 = mul_0(&_S59, &_S60);
        thread DF_0 _S62 = _S61;
        DF_0 _S63 = neg_0(&_S62);
        thread DF_0 _S64 = _S26;
        thread DF_0 _S65 = _S46;
        DF_0 _S66 = mul_0(&_S64, &_S65);
        thread DF_0 _S67 = _S66;
        thread DF_0 _S68 = s2c0_0;
        DF_0 _S69 = add_0(&_S67, &_S68);
        thread DF_0 _S70 = _S17;
        thread DF_0 _S71 = _S46;
        DF_0 _S72 = mul_0(&_S70, &_S71);
        thread DF_0 _S73 = _S72;
        thread DF_0 _S74 = s2c1_0;
        DF_0 _S75 = add_0(&_S73, &_S74);
        thread DF_0 _S76 = _S29;
        thread DF_0 _S77 = _S69;
        DF_0 _S78 = mul_0(&_S76, &_S77);
        thread DF_0 _S79 = _S75;
        thread DF_0 _S80 = _S78;
        DF_0 _S81 = sub_0(&_S79, &_S80);
        thread DF_0 _S82 = _S32;
        thread DF_0 _S83 = _S69;
        DF_0 _S84 = mul_0(&_S82, &_S83);
        thread DF_0 _S85 = _S84;
        DF_0 _S86 = neg_0(&_S85);
        thread DF_0 _S87 = _S26;
        thread DF_0 _S88 = _S69;
        DF_0 _S89 = mul_0(&_S87, &_S88);
        thread DF_0 _S90 = _S89;
        thread DF_0 _S91 = s3c0_0;
        DF_0 _S92 = add_0(&_S90, &_S91);
        thread DF_0 _S93 = _S20;
        thread DF_0 _S94 = _S69;
        DF_0 _S95 = mul_0(&_S93, &_S94);
        thread DF_0 _S96 = _S95;
        thread DF_0 _S97 = s3c1_0;
        DF_0 _S98 = add_0(&_S96, &_S97);
        thread DF_0 _S99 = _S29;
        thread DF_0 _S100 = _S92;
        DF_0 _S101 = mul_0(&_S99, &_S100);
        thread DF_0 _S102 = _S98;
        thread DF_0 _S103 = _S101;
        DF_0 _S104 = sub_0(&_S102, &_S103);
        thread DF_0 _S105 = _S32;
        thread DF_0 _S106 = _S92;
        DF_0 _S107 = mul_0(&_S105, &_S106);
        thread DF_0 _S108 = _S107;
        DF_0 _S109 = neg_0(&_S108);
        thread DF_0 _S110 = _S26;
        thread DF_0 _S111 = _S92;
        DF_0 _S112 = mul_0(&_S110, &_S111);
        thread DF_0 _S113 = _S112;
        thread DF_0 _S114 = s4c0_0;
        DF_0 _S115 = add_0(&_S113, &_S114);
        thread DF_0 _S116 = _S23;
        thread DF_0 _S117 = _S92;
        DF_0 _S118 = mul_0(&_S116, &_S117);
        thread DF_0 _S119 = _S118;
        thread DF_0 _S120 = s4c1_0;
        DF_0 _S121 = add_0(&_S119, &_S120);
        thread DF_0 _S122 = _S29;
        thread DF_0 _S123 = _S115;
        DF_0 _S124 = mul_0(&_S122, &_S123);
        thread DF_0 _S125 = _S121;
        thread DF_0 _S126 = _S124;
        DF_0 _S127 = sub_0(&_S125, &_S126);
        thread DF_0 _S128 = _S32;
        thread DF_0 _S129 = _S115;
        DF_0 _S130 = mul_0(&_S128, &_S129);
        thread DF_0 _S131 = _S130;
        DF_0 _S132 = neg_0(&_S131);
        thread DF_0 _S133 = _S115;
        thread DF_0 _S134 = _S115;
        DF_0 _S135 = mul_0(&_S133, &_S134);
        thread DF_0 _S136 = sum_sq_0;
        thread DF_0 _S137 = _S135;
        DF_0 _S138 = add_0(&_S136, &_S137);
        uint _S139 = i_3 + 1U;
        s1c0_0 = _S58;
        s1c1_0 = _S63;
        s2c0_0 = _S81;
        s2c1_0 = _S86;
        s3c0_0 = _S104;
        s3c1_0 = _S109;
        s4c0_0 = _S127;
        s4c1_0 = _S132;
        sum_sq_0 = _S138;
        i_3 = _S139;
    }
    float n_0 = float(window_size_0);
    float q_0 = sum_sq_0.hi_0 / n_0;
    DF_0 _S140 = DF_x24init_1(n_0);
    thread DF_0 _S141 = DF_x24init_1(q_0);
    thread DF_0 _S142 = _S140;
    DF_0 _S143 = mul_0(&_S141, &_S142);
    thread DF_0 _S144 = sum_sq_0;
    thread DF_0 _S145 = _S143;
    DF_0 _S146 = sub_0(&_S144, &_S145);
    thread DF_0 _S147 = _S146;
    float _S148 = DF_value_0(&_S147);
    return sqrt(q_0 + _S148 / n_0);
}

struct Frame_0
{
    uint start_1;
    uint out_0;
    uint stride_0;
};

struct RO_1
{
    Frame_0 device* p_0;
};

Frame_0 RO_operatorx5Bx5D_get_2(const RO_1 constant* this_4, uint i_4)
{
    return *(this_4->p_0 + i_4);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

Samples_0 Samples_x24init_0(const RO_0 constant* signals_1, const RO_0 constant* signals_lo_1, uint start_2)
{
    thread Samples_0 _S149;
    (&_S149)->signals_0 = *signals_1;
    (&_S149)->signals_lo_0 = *signals_lo_1;
    (&_S149)->start_0 = start_2;
    return _S149;
}

struct RW_0
{
    float device* p_2;
};

struct EntryPointParams_0
{
    RO_0 signals_2;
    RO_0 signals_lo_2;
    RO_1 frames_0;
    RO_0 coeffs_1;
    RO_0 hann_1;
    RW_0 out_1;
    uint num_frames_0;
    uint num_bands_0;
    uint window_size_1;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void gammatone_frames(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S150 = entryPointParams_1->out_1;
    uint gid_0 = zimt_index_0(tid_1);
    uint band_1 = gid_0 % entryPointParams_1->num_bands_0;
    uint frame_1 = gid_0 / entryPointParams_1->num_bands_0;
    if(frame_1 >= ((&kernelContext_0)->entryPointParams_0->num_frames_0))
    {
        return;
    }
    Frame_0 _S151 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->frames_0, frame_1);
    Samples_0 _S152 = Samples_x24init_0(&(&kernelContext_0)->entryPointParams_0->signals_2, &(&kernelContext_0)->entryPointParams_0->signals_lo_2, _S151.start_1);
    uint _S153 = _S151.out_0 + band_1 * _S151.stride_0;
    uint _S154 = (&kernelContext_0)->entryPointParams_0->window_size_1;
    thread Samples_0 _S155 = _S152;
    float _S156 = gammatone_rms_0(&_S155, band_1, &(&kernelContext_0)->entryPointParams_0->coeffs_1, &(&kernelContext_0)->entryPointParams_0->hann_1, _S154);
    *(_S150.p_2 + _S153) = _S156;
    return;
}

