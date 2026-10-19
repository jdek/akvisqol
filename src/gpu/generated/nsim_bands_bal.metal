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

float RO_operatorx5Bx5D_get_1(const RO_0 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

struct PatchPair_0
{
    uint ref_off_0;
    uint ref_frames_0;
    uint ref_frame_0;
    uint deg_off_0;
    uint deg_frames_0;
    uint deg_frame_0;
    uint cols_0;
};

struct RO_1
{
    PatchPair_0 device* p_0;
};

PatchPair_0 RO_operatorx5Bx5D_get_2(const RO_1 constant* this_2, uint i_2)
{
    return *(this_2->p_0 + i_2);
}

struct RO_2
{
    uint device* p_0;
};

uint RO_operatorx5Bx5D_get_3(const RO_2 constant* this_3, uint i_3)
{
    return *(this_3->p_0 + i_3);
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

float degAt_0(const RO_0 constant* spec_0, uint o_0, uint nf_0, uint col0_0, uint b_0, uint c_0)
{
    float _S2;
    if((col0_0 + c_0) < nf_0)
    {
        float _S3 = RO_operatorx5Bx5D_get_1(spec_0, o_0 + b_0 * nf_0 + col0_0 + c_0);
        _S2 = _S3;
    }
    else
    {
        _S2 = 0.0f;
    }
    return _S2;
}

DF_0 DF_x24init_1(float h_0, float l_0)
{
    thread DF_0 _S4;
    (&_S4)->hi_0 = h_0;
    (&_S4)->lo_0 = l_0;
    return _S4;
}

DF_0 twoSum_0(float a_0, float b_1)
{
    float s_0 = a_0 + b_1;
    float bb_0 = s_0 - a_0;
    return DF_x24init_1(s_0, a_0 - (s_0 - bb_0) + (b_1 - bb_0));
}

DF_0 quickTwoSum_0(float a_1, float b_2)
{
    float s_1 = a_1 + b_2;
    return DF_x24init_1(s_1, b_2 - (s_1 - a_1));
}

DF_0 add_0(const DF_0 thread* a_2, const DF_0 thread* b_3)
{
    DF_0 s_2 = twoSum_0(a_2->hi_0, b_3->hi_0);
    DF_0 t_0 = twoSum_0(a_2->lo_0, b_3->lo_0);
    DF_0 s_3 = quickTwoSum_0(s_2.hi_0, s_2.lo_0 + t_0.hi_0);
    return quickTwoSum_0(s_3.hi_0, s_3.lo_0 + t_0.lo_0);
}

DF_0 add_1(const DF_0 thread* a_3, const DF_0 thread* b_4)
{
    DF_0 s_4 = twoSum_0(a_3->hi_0, b_4->hi_0);
    DF_0 t_1 = twoSum_0(a_3->lo_0, b_4->lo_0);
    DF_0 s_5 = quickTwoSum_0(s_4.hi_0, s_4.lo_0 + t_1.hi_0);
    return quickTwoSum_0(s_5.hi_0, s_5.lo_0 + t_1.lo_0);
}

float refAt_0(const RO_0 constant* spec_1, uint o_1, uint nf_1, uint col0_1, uint b_5, uint c_1)
{
    float _S5 = RO_operatorx5Bx5D_get_1(spec_1, o_1 + b_5 * nf_1 + col0_1 + c_1);
    return _S5;
}

struct Cell_0
{
    float cr_0;
    float cd_0;
    DF_0 sr_0;
    DF_0 sd_0;
    DF_0 qr_0;
    DF_0 qd_0;
    DF_0 qrd_0;
};

Cell_0 Cell_x24init_0(float r0_0, float d0_0)
{
    thread Cell_0 _S6;
    (&_S6)->cr_0 = r0_0;
    (&_S6)->cd_0 = d0_0;
    DF_0 _S7 = DF_x24init_0(0.0f);
    (&_S6)->sr_0 = _S7;
    (&_S6)->sd_0 = _S7;
    (&_S6)->qr_0 = _S7;
    (&_S6)->qd_0 = _S7;
    (&_S6)->qrd_0 = _S7;
    return _S6;
}

DF_0 neg_0(const DF_0 thread* a_4)
{
    return DF_x24init_1(- a_4->hi_0, - a_4->lo_0);
}

DF_0 sub_0(const DF_0 thread* a_5, const DF_0 thread* b_6)
{
    DF_0 _S8 = neg_0(b_6);
    thread DF_0 _S9 = _S8;
    DF_0 _S10 = add_0(a_5, &_S9);
    return _S10;
}

DF_0 mul_0(const DF_0 thread* a_6, const DF_0 thread* b_7)
{
    float p_1 = a_6->hi_0 * b_7->hi_0;
    return quickTwoSum_0(p_1, fma(a_6->hi_0, b_7->hi_0, - p_1) + (a_6->hi_0 * b_7->lo_0 + a_6->lo_0 * b_7->hi_0));
}

DF_0 plus_0(const DF_0 thread* a_7, const DF_0 thread* b_8)
{
    DF_0 _S11 = add_1(a_7, b_8);
    return _S11;
}

void Cell_add_0(Cell_0 thread* this_4, float w_0, float rv_0, float dv_0)
{
    DF_0 _S12 = DF_x24init_0(this_4->cr_0);
    thread DF_0 _S13 = DF_x24init_0(rv_0);
    thread DF_0 _S14 = _S12;
    DF_0 _S15 = sub_0(&_S13, &_S14);
    DF_0 _S16 = DF_x24init_0(this_4->cd_0);
    thread DF_0 _S17 = DF_x24init_0(dv_0);
    thread DF_0 _S18 = _S16;
    DF_0 _S19 = sub_0(&_S17, &_S18);
    DF_0 ww_0 = DF_x24init_0(w_0);
    thread DF_0 _S20 = ww_0;
    thread DF_0 _S21 = _S15;
    DF_0 _S22 = mul_0(&_S20, &_S21);
    thread DF_0 _S23 = this_4->sr_0;
    thread DF_0 _S24 = _S22;
    DF_0 _S25 = plus_0(&_S23, &_S24);
    this_4->sr_0 = _S25;
    thread DF_0 _S26 = ww_0;
    thread DF_0 _S27 = _S19;
    DF_0 _S28 = mul_0(&_S26, &_S27);
    thread DF_0 _S29 = this_4->sd_0;
    thread DF_0 _S30 = _S28;
    DF_0 _S31 = plus_0(&_S29, &_S30);
    this_4->sd_0 = _S31;
    thread DF_0 _S32 = _S15;
    thread DF_0 _S33 = _S15;
    DF_0 _S34 = mul_0(&_S32, &_S33);
    thread DF_0 _S35 = ww_0;
    thread DF_0 _S36 = _S34;
    DF_0 _S37 = mul_0(&_S35, &_S36);
    thread DF_0 _S38 = this_4->qr_0;
    thread DF_0 _S39 = _S37;
    DF_0 _S40 = plus_0(&_S38, &_S39);
    this_4->qr_0 = _S40;
    thread DF_0 _S41 = _S19;
    thread DF_0 _S42 = _S19;
    DF_0 _S43 = mul_0(&_S41, &_S42);
    thread DF_0 _S44 = ww_0;
    thread DF_0 _S45 = _S43;
    DF_0 _S46 = mul_0(&_S44, &_S45);
    thread DF_0 _S47 = this_4->qd_0;
    thread DF_0 _S48 = _S46;
    DF_0 _S49 = plus_0(&_S47, &_S48);
    this_4->qd_0 = _S49;
    thread DF_0 _S50 = _S15;
    thread DF_0 _S51 = _S19;
    DF_0 _S52 = mul_0(&_S50, &_S51);
    thread DF_0 _S53 = ww_0;
    thread DF_0 _S54 = _S52;
    DF_0 _S55 = mul_0(&_S53, &_S54);
    thread DF_0 _S56 = this_4->qrd_0;
    thread DF_0 _S57 = _S55;
    DF_0 _S58 = plus_0(&_S56, &_S57);
    this_4->qrd_0 = _S58;
    return;
}

DF_0 div_0(const DF_0 thread* a_8, const DF_0 thread* b_9)
{
    float _S59 = b_9->hi_0;
    float q1_0 = a_8->hi_0 / b_9->hi_0;
    thread DF_0 _S60 = DF_x24init_0(q1_0);
    DF_0 _S61 = mul_0(&_S60, b_9);
    thread DF_0 _S62 = _S61;
    DF_0 _S63 = sub_0(a_8, &_S62);
    float q2_0 = _S63.hi_0 / _S59;
    thread DF_0 _S64 = DF_x24init_0(q2_0);
    DF_0 _S65 = mul_0(&_S64, b_9);
    thread DF_0 _S66 = _S63;
    thread DF_0 _S67 = _S65;
    DF_0 _S68 = sub_0(&_S66, &_S67);
    DF_0 _S69 = DF_x24init_0(_S68.hi_0 / _S59);
    thread DF_0 _S70 = quickTwoSum_0(q1_0, q2_0);
    thread DF_0 _S71 = _S69;
    DF_0 _S72 = add_0(&_S70, &_S71);
    return _S72;
}

DF_0 sqrt_0(const DF_0 thread* a_9)
{
    float _S73 = a_9->hi_0;
    if((a_9->hi_0) <= 0.0f)
    {
        return DF_x24init_0(0.0f);
    }
    float s_6 = sqrt(_S73);
    DF_0 _S74 = DF_x24init_0(s_6);
    thread DF_0 _S75 = _S74;
    thread DF_0 _S76 = _S74;
    DF_0 _S77 = mul_0(&_S75, &_S76);
    thread DF_0 _S78 = _S77;
    DF_0 _S79 = sub_0(a_9, &_S78);
    return quickTwoSum_0(s_6, _S79.hi_0 / (2.0f * s_6));
}

float Cell_sim_0(const Cell_0 thread* this_5, float c1_0, float c3_0)
{
    thread DF_0 _S80 = DF_x24init_0(this_5->cr_0);
    DF_0 _S81 = plus_0(&_S80, &this_5->sr_0);
    thread DF_0 _S82 = DF_x24init_0(this_5->cd_0);
    DF_0 _S83 = plus_0(&_S82, &this_5->sd_0);
    DF_0 _S84 = mul_0(&this_5->sr_0, &this_5->sr_0);
    thread DF_0 _S85 = _S84;
    DF_0 _S86 = sub_0(&this_5->qr_0, &_S85);
    DF_0 _S87 = mul_0(&this_5->sd_0, &this_5->sd_0);
    thread DF_0 _S88 = _S87;
    DF_0 _S89 = sub_0(&this_5->qd_0, &_S88);
    DF_0 _S90 = mul_0(&this_5->sr_0, &this_5->sd_0);
    thread DF_0 _S91 = _S90;
    DF_0 _S92 = sub_0(&this_5->qrd_0, &_S91);
    thread DF_0 _S93 = _S81;
    thread DF_0 _S94 = _S83;
    DF_0 _S95 = mul_0(&_S93, &_S94);
    DF_0 k1_0 = DF_x24init_0(c1_0);
    DF_0 k3_0 = DF_x24init_0(c3_0);
    thread DF_0 _S96 = DF_x24init_0(2.0f);
    thread DF_0 _S97 = _S95;
    DF_0 _S98 = mul_0(&_S96, &_S97);
    thread DF_0 _S99 = _S98;
    thread DF_0 _S100 = k1_0;
    DF_0 _S101 = plus_0(&_S99, &_S100);
    thread DF_0 _S102 = _S81;
    thread DF_0 _S103 = _S81;
    DF_0 _S104 = mul_0(&_S102, &_S103);
    thread DF_0 _S105 = _S83;
    thread DF_0 _S106 = _S83;
    DF_0 _S107 = mul_0(&_S105, &_S106);
    thread DF_0 _S108 = _S104;
    thread DF_0 _S109 = _S107;
    DF_0 _S110 = plus_0(&_S108, &_S109);
    thread DF_0 _S111 = _S110;
    thread DF_0 _S112 = k1_0;
    DF_0 _S113 = plus_0(&_S111, &_S112);
    thread DF_0 _S114 = _S101;
    thread DF_0 _S115 = _S113;
    DF_0 _S116 = div_0(&_S114, &_S115);
    thread DF_0 _S117 = _S86;
    thread DF_0 _S118 = _S89;
    DF_0 _S119 = mul_0(&_S117, &_S118);
    DF_0 denom_0;
    if((_S119.hi_0) < 0.0f)
    {
        denom_0 = k3_0;
    }
    else
    {
        thread DF_0 _S120 = _S119;
        DF_0 _S121 = sqrt_0(&_S120);
        thread DF_0 _S122 = _S121;
        thread DF_0 _S123 = k3_0;
        DF_0 _S124 = plus_0(&_S122, &_S123);
        denom_0 = _S124;
    }
    thread DF_0 _S125 = _S92;
    thread DF_0 _S126 = k3_0;
    DF_0 _S127 = plus_0(&_S125, &_S126);
    thread DF_0 _S128 = _S127;
    thread DF_0 _S129 = denom_0;
    DF_0 _S130 = div_0(&_S128, &_S129);
    thread DF_0 _S131 = _S116;
    thread DF_0 _S132 = _S130;
    DF_0 _S133 = mul_0(&_S131, &_S132);
    return _S133.hi_0 + _S133.lo_0;
}

float bandSim_0(const RO_0 constant* ref_spec_0, const RO_0 constant* deg_spec_0, const RO_0 constant* window_0, const PatchPair_0 thread* pp_0, uint b_10, uint c_2, uint nb_0, float c1_1, float c3_1)
{
    uint _S134 = pp_0->cols_0;
    uint _S135 = pp_0->ref_off_0;
    uint _S136 = pp_0->ref_frames_0;
    uint _S137 = pp_0->ref_frame_0;
    float _S138 = refAt_0(ref_spec_0, pp_0->ref_off_0, pp_0->ref_frames_0, pp_0->ref_frame_0, b_10, c_2);
    uint _S139 = pp_0->deg_off_0;
    uint _S140 = pp_0->deg_frames_0;
    uint _S141 = pp_0->deg_frame_0;
    float _S142 = degAt_0(deg_spec_0, pp_0->deg_off_0, pp_0->deg_frames_0, pp_0->deg_frame_0, b_10, c_2);
    thread Cell_0 cell_0 = Cell_x24init_0(_S138, _S142);
    int dr_0 = int(-1);
    for(;;)
    {
        if(dr_0 <= int(1))
        {
        }
        else
        {
            break;
        }
        uint _S143 = uint(clamp(int(b_10) + dr_0, int(0), int(nb_0) - int(1)));
        int dc_0 = int(-1);
        for(;;)
        {
            if(dc_0 <= int(1))
            {
            }
            else
            {
                break;
            }
            uint cc_0 = uint(clamp(int(c_2) + dc_0, int(0), int(_S134) - int(1)));
            float _S144 = RO_operatorx5Bx5D_get_0(window_0, uint((dr_0 + int(1)) * int(3) + dc_0 + int(1)));
            float _S145 = refAt_0(ref_spec_0, _S135, _S136, _S137, _S143, cc_0);
            float _S146 = degAt_0(deg_spec_0, _S139, _S140, _S141, _S143, cc_0);
            Cell_add_0(&cell_0, _S144, _S145, _S146);
            dc_0 = dc_0 + int(1);
        }
        dr_0 = dr_0 + int(1);
    }
    thread Cell_0 _S147 = cell_0;
    float _S148 = Cell_sim_0(&_S147, c1_1, c3_1);
    return _S148;
}

struct RW_0
{
    float device* p_2;
};

struct EntryPointParams_0
{
    RO_0 ref_spec_1;
    RO_0 deg_spec_1;
    RO_0 window_1;
    RO_1 rows_0;
    RO_2 active_0;
    RW_0 stats_0;
    uint num_rows_0;
    uint num_bands_0;
    float c1_2;
    float c3_2;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void nsim_bands(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S149 = entryPointParams_1->stats_0;
    uint id_0 = zimt_index_0(tid_1);
    uint row_0 = id_0 / entryPointParams_1->num_bands_0;
    uint b_11 = id_0 % entryPointParams_1->num_bands_0;
    bool _S150;
    if(row_0 >= ((&kernelContext_0)->entryPointParams_0->num_rows_0))
    {
        _S150 = true;
    }
    else
    {
        uint _S151 = RO_operatorx5Bx5D_get_3(&(&kernelContext_0)->entryPointParams_0->active_0, row_0);
        _S150 = _S151 == 0U;
    }
    if(_S150)
    {
        return;
    }
    PatchPair_0 _S152 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    DF_0 _S153 = DF_x24init_0(0.0f);
    DF_0 deg_sum_0 = _S153;
    uint c_3 = 0U;
    for(;;)
    {
        if(c_3 < (_S152.cols_0))
        {
        }
        else
        {
            break;
        }
        float _S154 = degAt_0(&(&kernelContext_0)->entryPointParams_0->deg_spec_1, _S152.deg_off_0, _S152.deg_frames_0, _S152.deg_frame_0, b_11, c_3);
        DF_0 _S155 = DF_x24init_0(_S154);
        thread DF_0 _S156 = deg_sum_0;
        thread DF_0 _S157 = _S155;
        DF_0 _S158 = add_0(&_S156, &_S157);
        uint _S159 = c_3 + 1U;
        deg_sum_0 = _S158;
        c_3 = _S159;
    }
    DF_0 sim_sum_0 = _S153;
    c_3 = 0U;
    for(;;)
    {
        if(c_3 < (_S152.cols_0))
        {
        }
        else
        {
            break;
        }
        float _S160 = (&kernelContext_0)->entryPointParams_0->c1_2;
        float _S161 = (&kernelContext_0)->entryPointParams_0->c3_2;
        thread PatchPair_0 _S162 = _S152;
        float _S163 = bandSim_0(&(&kernelContext_0)->entryPointParams_0->ref_spec_1, &(&kernelContext_0)->entryPointParams_0->deg_spec_1, &(&kernelContext_0)->entryPointParams_0->window_1, &_S162, b_11, c_3, entryPointParams_1->num_bands_0, _S160, _S161);
        DF_0 _S164 = DF_x24init_0(_S163);
        thread DF_0 _S165 = sim_sum_0;
        thread DF_0 _S166 = _S164;
        DF_0 _S167 = add_0(&_S165, &_S166);
        uint _S168 = c_3 + 1U;
        sim_sum_0 = _S167;
        c_3 = _S168;
    }
    float _S169 = float(_S152.cols_0);
    DF_0 n_0 = DF_x24init_0(_S169);
    thread DF_0 _S170 = sim_sum_0;
    thread DF_0 _S171 = n_0;
    DF_0 _S172 = div_0(&_S170, &_S171);
    float mean_0 = _S172.hi_0 + _S172.lo_0;
    float dev_0;
    if((_S152.cols_0) > 1U)
    {
        DF_0 ss_0 = _S153;
        c_3 = 0U;
        for(;;)
        {
            if(c_3 < (_S152.cols_0))
            {
            }
            else
            {
                break;
            }
            float _S173 = (&kernelContext_0)->entryPointParams_0->c1_2;
            float _S174 = (&kernelContext_0)->entryPointParams_0->c3_2;
            thread PatchPair_0 _S175 = _S152;
            float _S176 = bandSim_0(&(&kernelContext_0)->entryPointParams_0->ref_spec_1, &(&kernelContext_0)->entryPointParams_0->deg_spec_1, &(&kernelContext_0)->entryPointParams_0->window_1, &_S175, b_11, c_3, entryPointParams_1->num_bands_0, _S173, _S174);
            thread DF_0 _S177 = DF_x24init_0(_S176);
            thread DF_0 _S178 = _S172;
            DF_0 _S179 = sub_0(&_S177, &_S178);
            thread DF_0 _S180 = _S179;
            thread DF_0 _S181 = _S179;
            DF_0 _S182 = mul_0(&_S180, &_S181);
            thread DF_0 _S183 = ss_0;
            thread DF_0 _S184 = _S182;
            DF_0 _S185 = add_0(&_S183, &_S184);
            uint _S186 = c_3 + 1U;
            ss_0 = _S185;
            c_3 = _S186;
        }
        DF_0 _S187 = DF_x24init_0(_S169 - 1.0f);
        thread DF_0 _S188 = ss_0;
        thread DF_0 _S189 = _S187;
        DF_0 _S190 = div_0(&_S188, &_S189);
        dev_0 = sqrt(_S190.hi_0 + _S190.lo_0);
    }
    else
    {
        dev_0 = 0.0f;
    }
    thread DF_0 _S191 = deg_sum_0;
    thread DF_0 _S192 = n_0;
    DF_0 _S193 = div_0(&_S191, &_S192);
    float deg_mean_0 = _S193.hi_0 + _S193.lo_0;
    uint o_2 = (row_0 * entryPointParams_1->num_bands_0 + b_11) * 3U;
    *(_S149.p_2 + o_2) = mean_0;
    *(_S149.p_2 + (o_2 + 1U)) = dev_0;
    *(_S149.p_2 + (o_2 + 2U)) = deg_mean_0;
    return;
}

