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
    RO_0 lo_0;
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

struct DF_0
{
    float hi_1;
    float lo_1;
};

DF_0 DF_x24init_0(float h_0, float l_0)
{
    thread DF_0 _S1;
    (&_S1)->hi_1 = h_0;
    (&_S1)->lo_1 = l_0;
    return _S1;
}

DF_0 DF_x24init_1(float x_0)
{
    thread DF_0 _S2;
    (&_S2)->hi_1 = x_0;
    (&_S2)->lo_1 = 0.0f;
    return _S2;
}

uint Side_total_0(const Side_0 thread* this_1)
{
    return this_1->pad_0 + this_1->len_0;
}

float RO_operatorx5Bx5D_get_1(const RO_0 thread* this_2, uint i_1)
{
    return *(this_2->p_0 + i_1);
}

DF_0 Signals_at_0(const Signals_0 thread* this_3, uint i_2)
{
    float _S3 = RO_operatorx5Bx5D_get_1(&this_3->hi_0, i_2);
    float _S4 = RO_operatorx5Bx5D_get_1(&this_3->lo_0, i_2);
    return DF_x24init_0(_S3, _S4);
}

DF_0 at_0(const Side_0 thread* s_0, const Signals_0 thread* signals_1, int i_3)
{
    uint _S5 = s_0->pad_0;
    bool _S6;
    if(i_3 < int(s_0->pad_0))
    {
        _S6 = true;
    }
    else
    {
        uint _S7 = Side_total_0(s_0);
        _S6 = i_3 >= int(_S7);
    }
    if(_S6)
    {
        return DF_x24init_1(0.0f);
    }
    DF_0 _S8 = Signals_at_0(signals_1, s_0->start_0 + uint(i_3) - _S5);
    return _S8;
}

DF_0 Windowed_at_0(const Windowed_0 thread* this_4, uint i_4)
{
    DF_0 _S9 = at_0(&this_4->side_0, &this_4->signals_0, this_4->start_1 + int(i_4));
    return _S9;
}

DF_0 quickTwoSum_0(float a_0, float b_0)
{
    float s_1 = a_0 + b_0;
    return DF_x24init_0(s_1, b_0 - (s_1 - a_0));
}

DF_0 mul_0(const DF_0 thread* a_1, const DF_0 thread* b_1)
{
    float p_1 = a_1->hi_1 * b_1->hi_1;
    return quickTwoSum_0(p_1, fma(a_1->hi_1, b_1->hi_1, - p_1) + (a_1->hi_1 * b_1->lo_1 + a_1->lo_1 * b_1->hi_1));
}

DF_0 twoSum_0(float a_2, float b_2)
{
    float s_2 = a_2 + b_2;
    float bb_0 = s_2 - a_2;
    return DF_x24init_0(s_2, a_2 - (s_2 - bb_0) + (b_2 - bb_0));
}

DF_0 add_0(const DF_0 thread* a_3, const DF_0 thread* b_3)
{
    DF_0 s_3 = twoSum_0(a_3->hi_1, b_3->hi_1);
    DF_0 t_0 = twoSum_0(a_3->lo_1, b_3->lo_1);
    DF_0 s_4 = quickTwoSum_0(s_3.hi_1, s_3.lo_1 + t_0.hi_1);
    return quickTwoSum_0(s_4.hi_1, s_4.lo_1 + t_0.lo_1);
}

DF_0 neg_0(const DF_0 thread* a_4)
{
    return DF_x24init_0(- a_4->hi_1, - a_4->lo_1);
}

DF_0 sub_0(const DF_0 thread* a_5, const DF_0 thread* b_4)
{
    DF_0 _S10 = neg_0(b_4);
    thread DF_0 _S11 = _S10;
    DF_0 _S12 = add_0(a_5, &_S11);
    return _S12;
}

float DF_value_0(const DF_0 thread* this_5)
{
    return this_5->hi_1 + this_5->lo_1;
}

float gammatone_rms_0(const Windowed_0 thread* frame_0, uint band_0, const RO_0 constant* coeffs_0, const RO_0 constant* hann_0, uint window_size_0)
{
    uint o_0 = band_0 * 20U;
    float _S13 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0);
    float _S14 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 10U);
    DF_0 _S15 = DF_x24init_0(_S13, _S14);
    float _S16 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 1U);
    float _S17 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 11U);
    DF_0 _S18 = DF_x24init_0(_S16, _S17);
    float _S19 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 2U);
    float _S20 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 12U);
    DF_0 _S21 = DF_x24init_0(_S19, _S20);
    float _S22 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 3U);
    float _S23 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 13U);
    DF_0 _S24 = DF_x24init_0(_S22, _S23);
    float _S25 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 4U);
    float _S26 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 14U);
    DF_0 _S27 = DF_x24init_0(_S25, _S26);
    float _S28 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 5U);
    float _S29 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 15U);
    DF_0 _S30 = DF_x24init_0(_S28, _S29);
    float _S31 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 6U);
    float _S32 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 16U);
    DF_0 _S33 = DF_x24init_0(_S31, _S32);
    float _S34 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 7U);
    float _S35 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 17U);
    DF_0 _S36 = DF_x24init_0(_S34, _S35);
    DF_0 _S37 = DF_x24init_1(0.0f);
    DF_0 s1c0_0 = _S37;
    DF_0 s1c1_0 = _S37;
    DF_0 s2c0_0 = _S37;
    DF_0 s2c1_0 = _S37;
    DF_0 s3c0_0 = _S37;
    DF_0 s3c1_0 = _S37;
    DF_0 s4c0_0 = _S37;
    DF_0 s4c1_0 = _S37;
    DF_0 sum_sq_0 = _S37;
    uint i_5 = 0U;
    for(;;)
    {
        if(i_5 < window_size_0)
        {
        }
        else
        {
            break;
        }
        DF_0 _S38 = Windowed_at_0(frame_0, i_5);
        float _S39 = RO_operatorx5Bx5D_get_0(hann_0, i_5);
        float _S40 = RO_operatorx5Bx5D_get_0(hann_0, window_size_0 + i_5);
        DF_0 _S41 = DF_x24init_0(_S39, _S40);
        thread DF_0 _S42 = _S38;
        thread DF_0 _S43 = _S41;
        DF_0 _S44 = mul_0(&_S42, &_S43);
        thread DF_0 _S45 = _S15;
        thread DF_0 _S46 = _S44;
        DF_0 _S47 = mul_0(&_S45, &_S46);
        thread DF_0 _S48 = _S47;
        thread DF_0 _S49 = s1c0_0;
        DF_0 _S50 = add_0(&_S48, &_S49);
        thread DF_0 _S51 = _S18;
        thread DF_0 _S52 = _S44;
        DF_0 _S53 = mul_0(&_S51, &_S52);
        thread DF_0 _S54 = _S53;
        thread DF_0 _S55 = s1c1_0;
        DF_0 _S56 = add_0(&_S54, &_S55);
        thread DF_0 _S57 = _S33;
        thread DF_0 _S58 = _S50;
        DF_0 _S59 = mul_0(&_S57, &_S58);
        thread DF_0 _S60 = _S56;
        thread DF_0 _S61 = _S59;
        DF_0 _S62 = sub_0(&_S60, &_S61);
        thread DF_0 _S63 = _S36;
        thread DF_0 _S64 = _S50;
        DF_0 _S65 = mul_0(&_S63, &_S64);
        thread DF_0 _S66 = _S65;
        DF_0 _S67 = neg_0(&_S66);
        thread DF_0 _S68 = _S30;
        thread DF_0 _S69 = _S50;
        DF_0 _S70 = mul_0(&_S68, &_S69);
        thread DF_0 _S71 = _S70;
        thread DF_0 _S72 = s2c0_0;
        DF_0 _S73 = add_0(&_S71, &_S72);
        thread DF_0 _S74 = _S21;
        thread DF_0 _S75 = _S50;
        DF_0 _S76 = mul_0(&_S74, &_S75);
        thread DF_0 _S77 = _S76;
        thread DF_0 _S78 = s2c1_0;
        DF_0 _S79 = add_0(&_S77, &_S78);
        thread DF_0 _S80 = _S33;
        thread DF_0 _S81 = _S73;
        DF_0 _S82 = mul_0(&_S80, &_S81);
        thread DF_0 _S83 = _S79;
        thread DF_0 _S84 = _S82;
        DF_0 _S85 = sub_0(&_S83, &_S84);
        thread DF_0 _S86 = _S36;
        thread DF_0 _S87 = _S73;
        DF_0 _S88 = mul_0(&_S86, &_S87);
        thread DF_0 _S89 = _S88;
        DF_0 _S90 = neg_0(&_S89);
        thread DF_0 _S91 = _S30;
        thread DF_0 _S92 = _S73;
        DF_0 _S93 = mul_0(&_S91, &_S92);
        thread DF_0 _S94 = _S93;
        thread DF_0 _S95 = s3c0_0;
        DF_0 _S96 = add_0(&_S94, &_S95);
        thread DF_0 _S97 = _S24;
        thread DF_0 _S98 = _S73;
        DF_0 _S99 = mul_0(&_S97, &_S98);
        thread DF_0 _S100 = _S99;
        thread DF_0 _S101 = s3c1_0;
        DF_0 _S102 = add_0(&_S100, &_S101);
        thread DF_0 _S103 = _S33;
        thread DF_0 _S104 = _S96;
        DF_0 _S105 = mul_0(&_S103, &_S104);
        thread DF_0 _S106 = _S102;
        thread DF_0 _S107 = _S105;
        DF_0 _S108 = sub_0(&_S106, &_S107);
        thread DF_0 _S109 = _S36;
        thread DF_0 _S110 = _S96;
        DF_0 _S111 = mul_0(&_S109, &_S110);
        thread DF_0 _S112 = _S111;
        DF_0 _S113 = neg_0(&_S112);
        thread DF_0 _S114 = _S30;
        thread DF_0 _S115 = _S96;
        DF_0 _S116 = mul_0(&_S114, &_S115);
        thread DF_0 _S117 = _S116;
        thread DF_0 _S118 = s4c0_0;
        DF_0 _S119 = add_0(&_S117, &_S118);
        thread DF_0 _S120 = _S27;
        thread DF_0 _S121 = _S96;
        DF_0 _S122 = mul_0(&_S120, &_S121);
        thread DF_0 _S123 = _S122;
        thread DF_0 _S124 = s4c1_0;
        DF_0 _S125 = add_0(&_S123, &_S124);
        thread DF_0 _S126 = _S33;
        thread DF_0 _S127 = _S119;
        DF_0 _S128 = mul_0(&_S126, &_S127);
        thread DF_0 _S129 = _S125;
        thread DF_0 _S130 = _S128;
        DF_0 _S131 = sub_0(&_S129, &_S130);
        thread DF_0 _S132 = _S36;
        thread DF_0 _S133 = _S119;
        DF_0 _S134 = mul_0(&_S132, &_S133);
        thread DF_0 _S135 = _S134;
        DF_0 _S136 = neg_0(&_S135);
        thread DF_0 _S137 = _S119;
        thread DF_0 _S138 = _S119;
        DF_0 _S139 = mul_0(&_S137, &_S138);
        thread DF_0 _S140 = sum_sq_0;
        thread DF_0 _S141 = _S139;
        DF_0 _S142 = add_0(&_S140, &_S141);
        uint _S143 = i_5 + 1U;
        s1c0_0 = _S62;
        s1c1_0 = _S67;
        s2c0_0 = _S85;
        s2c1_0 = _S90;
        s3c0_0 = _S108;
        s3c1_0 = _S113;
        s4c0_0 = _S131;
        s4c1_0 = _S136;
        sum_sq_0 = _S142;
        i_5 = _S143;
    }
    float n_0 = float(window_size_0);
    float q_0 = sum_sq_0.hi_1 / n_0;
    DF_0 _S144 = DF_x24init_1(n_0);
    thread DF_0 _S145 = DF_x24init_1(q_0);
    thread DF_0 _S146 = _S144;
    DF_0 _S147 = mul_0(&_S145, &_S146);
    thread DF_0 _S148 = sum_sq_0;
    thread DF_0 _S149 = _S147;
    DF_0 _S150 = sub_0(&_S148, &_S149);
    thread DF_0 _S151 = _S150;
    float _S152 = DF_value_0(&_S151);
    return sqrt(q_0 + _S152 / n_0);
}

struct Inside_0
{
    Signals_0 signals_2;
    uint start_2;
};

DF_0 Inside_at_0(const Inside_0 thread* this_6, uint i_6)
{
    DF_0 _S153 = Signals_at_0(&this_6->signals_2, this_6->start_2 + i_6);
    return _S153;
}

float gammatone_rms_1(const Inside_0 thread* frame_1, uint band_1, const RO_0 constant* coeffs_1, const RO_0 constant* hann_1, uint window_size_1)
{
    uint o_1 = band_1 * 20U;
    float _S154 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1);
    float _S155 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 10U);
    DF_0 _S156 = DF_x24init_0(_S154, _S155);
    float _S157 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 1U);
    float _S158 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 11U);
    DF_0 _S159 = DF_x24init_0(_S157, _S158);
    float _S160 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 2U);
    float _S161 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 12U);
    DF_0 _S162 = DF_x24init_0(_S160, _S161);
    float _S163 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 3U);
    float _S164 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 13U);
    DF_0 _S165 = DF_x24init_0(_S163, _S164);
    float _S166 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 4U);
    float _S167 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 14U);
    DF_0 _S168 = DF_x24init_0(_S166, _S167);
    float _S169 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 5U);
    float _S170 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 15U);
    DF_0 _S171 = DF_x24init_0(_S169, _S170);
    float _S172 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 6U);
    float _S173 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 16U);
    DF_0 _S174 = DF_x24init_0(_S172, _S173);
    float _S175 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 7U);
    float _S176 = RO_operatorx5Bx5D_get_0(coeffs_1, o_1 + 17U);
    DF_0 _S177 = DF_x24init_0(_S175, _S176);
    DF_0 _S178 = DF_x24init_1(0.0f);
    DF_0 s1c0_1 = _S178;
    DF_0 s1c1_1 = _S178;
    DF_0 s2c0_1 = _S178;
    DF_0 s2c1_1 = _S178;
    DF_0 s3c0_1 = _S178;
    DF_0 s3c1_1 = _S178;
    DF_0 s4c0_1 = _S178;
    DF_0 s4c1_1 = _S178;
    DF_0 sum_sq_1 = _S178;
    uint i_7 = 0U;
    for(;;)
    {
        if(i_7 < window_size_1)
        {
        }
        else
        {
            break;
        }
        DF_0 _S179 = Inside_at_0(frame_1, i_7);
        float _S180 = RO_operatorx5Bx5D_get_0(hann_1, i_7);
        float _S181 = RO_operatorx5Bx5D_get_0(hann_1, window_size_1 + i_7);
        DF_0 _S182 = DF_x24init_0(_S180, _S181);
        thread DF_0 _S183 = _S179;
        thread DF_0 _S184 = _S182;
        DF_0 _S185 = mul_0(&_S183, &_S184);
        thread DF_0 _S186 = _S156;
        thread DF_0 _S187 = _S185;
        DF_0 _S188 = mul_0(&_S186, &_S187);
        thread DF_0 _S189 = _S188;
        thread DF_0 _S190 = s1c0_1;
        DF_0 _S191 = add_0(&_S189, &_S190);
        thread DF_0 _S192 = _S159;
        thread DF_0 _S193 = _S185;
        DF_0 _S194 = mul_0(&_S192, &_S193);
        thread DF_0 _S195 = _S194;
        thread DF_0 _S196 = s1c1_1;
        DF_0 _S197 = add_0(&_S195, &_S196);
        thread DF_0 _S198 = _S174;
        thread DF_0 _S199 = _S191;
        DF_0 _S200 = mul_0(&_S198, &_S199);
        thread DF_0 _S201 = _S197;
        thread DF_0 _S202 = _S200;
        DF_0 _S203 = sub_0(&_S201, &_S202);
        thread DF_0 _S204 = _S177;
        thread DF_0 _S205 = _S191;
        DF_0 _S206 = mul_0(&_S204, &_S205);
        thread DF_0 _S207 = _S206;
        DF_0 _S208 = neg_0(&_S207);
        thread DF_0 _S209 = _S171;
        thread DF_0 _S210 = _S191;
        DF_0 _S211 = mul_0(&_S209, &_S210);
        thread DF_0 _S212 = _S211;
        thread DF_0 _S213 = s2c0_1;
        DF_0 _S214 = add_0(&_S212, &_S213);
        thread DF_0 _S215 = _S162;
        thread DF_0 _S216 = _S191;
        DF_0 _S217 = mul_0(&_S215, &_S216);
        thread DF_0 _S218 = _S217;
        thread DF_0 _S219 = s2c1_1;
        DF_0 _S220 = add_0(&_S218, &_S219);
        thread DF_0 _S221 = _S174;
        thread DF_0 _S222 = _S214;
        DF_0 _S223 = mul_0(&_S221, &_S222);
        thread DF_0 _S224 = _S220;
        thread DF_0 _S225 = _S223;
        DF_0 _S226 = sub_0(&_S224, &_S225);
        thread DF_0 _S227 = _S177;
        thread DF_0 _S228 = _S214;
        DF_0 _S229 = mul_0(&_S227, &_S228);
        thread DF_0 _S230 = _S229;
        DF_0 _S231 = neg_0(&_S230);
        thread DF_0 _S232 = _S171;
        thread DF_0 _S233 = _S214;
        DF_0 _S234 = mul_0(&_S232, &_S233);
        thread DF_0 _S235 = _S234;
        thread DF_0 _S236 = s3c0_1;
        DF_0 _S237 = add_0(&_S235, &_S236);
        thread DF_0 _S238 = _S165;
        thread DF_0 _S239 = _S214;
        DF_0 _S240 = mul_0(&_S238, &_S239);
        thread DF_0 _S241 = _S240;
        thread DF_0 _S242 = s3c1_1;
        DF_0 _S243 = add_0(&_S241, &_S242);
        thread DF_0 _S244 = _S174;
        thread DF_0 _S245 = _S237;
        DF_0 _S246 = mul_0(&_S244, &_S245);
        thread DF_0 _S247 = _S243;
        thread DF_0 _S248 = _S246;
        DF_0 _S249 = sub_0(&_S247, &_S248);
        thread DF_0 _S250 = _S177;
        thread DF_0 _S251 = _S237;
        DF_0 _S252 = mul_0(&_S250, &_S251);
        thread DF_0 _S253 = _S252;
        DF_0 _S254 = neg_0(&_S253);
        thread DF_0 _S255 = _S171;
        thread DF_0 _S256 = _S237;
        DF_0 _S257 = mul_0(&_S255, &_S256);
        thread DF_0 _S258 = _S257;
        thread DF_0 _S259 = s4c0_1;
        DF_0 _S260 = add_0(&_S258, &_S259);
        thread DF_0 _S261 = _S168;
        thread DF_0 _S262 = _S237;
        DF_0 _S263 = mul_0(&_S261, &_S262);
        thread DF_0 _S264 = _S263;
        thread DF_0 _S265 = s4c1_1;
        DF_0 _S266 = add_0(&_S264, &_S265);
        thread DF_0 _S267 = _S174;
        thread DF_0 _S268 = _S260;
        DF_0 _S269 = mul_0(&_S267, &_S268);
        thread DF_0 _S270 = _S266;
        thread DF_0 _S271 = _S269;
        DF_0 _S272 = sub_0(&_S270, &_S271);
        thread DF_0 _S273 = _S177;
        thread DF_0 _S274 = _S260;
        DF_0 _S275 = mul_0(&_S273, &_S274);
        thread DF_0 _S276 = _S275;
        DF_0 _S277 = neg_0(&_S276);
        thread DF_0 _S278 = _S260;
        thread DF_0 _S279 = _S260;
        DF_0 _S280 = mul_0(&_S278, &_S279);
        thread DF_0 _S281 = sum_sq_1;
        thread DF_0 _S282 = _S280;
        DF_0 _S283 = add_0(&_S281, &_S282);
        uint _S284 = i_7 + 1U;
        s1c0_1 = _S203;
        s1c1_1 = _S208;
        s2c0_1 = _S226;
        s2c1_1 = _S231;
        s3c0_1 = _S249;
        s3c1_1 = _S254;
        s4c0_1 = _S272;
        s4c1_1 = _S277;
        sum_sq_1 = _S283;
        i_7 = _S284;
    }
    float n_1 = float(window_size_1);
    float q_1 = sum_sq_1.hi_1 / n_1;
    DF_0 _S285 = DF_x24init_1(n_1);
    thread DF_0 _S286 = DF_x24init_1(q_1);
    thread DF_0 _S287 = _S285;
    DF_0 _S288 = mul_0(&_S286, &_S287);
    thread DF_0 _S289 = sum_sq_1;
    thread DF_0 _S290 = _S288;
    DF_0 _S291 = sub_0(&_S289, &_S290);
    thread DF_0 _S292 = _S291;
    float _S293 = DF_value_0(&_S292);
    return sqrt(q_1 + _S293 / n_1);
}

struct RO_1
{
    uint device* p_0;
};

uint RO_operatorx5Bx5D_get_2(const RO_1 constant* this_7, uint i_8)
{
    return *(this_7->p_0 + i_8);
}

struct RO_2
{
    int device* p_0;
};

int RO_operatorx5Bx5D_get_3(const RO_2 constant* this_8, uint i_9)
{
    return *(this_8->p_0 + i_9);
}

struct LagRow_0
{
    Side_0 a_6;
    Side_0 b_5;
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

LagRow_0 RO_operatorx5Bx5D_get_4(const RO_3 constant* this_9, uint i_10)
{
    return *(this_9->p_0 + i_10);
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
    thread Trim_0 _S294;
    (&_S294)->lag_0 = lag_1;
    (&_S294)->head_0 = head_1;
    (&_S294)->len_1 = len_2;
    return _S294;
}

Trim_0 trim_0(const LagRow_0 thread* row_0, int lag_2, const RO_1 constant* back_0)
{
    uint _S295 = Side_total_0(&row_0->a_6);
    int r_0 = int(_S295);
    uint _S296 = Side_total_0(&row_0->b_5);
    int d_0 = int(_S296);
    bool _S297;
    if(lag_2 == int(0))
    {
        _S297 = true;
    }
    else
    {
        _S297 = (abs(lag_2)) > (r_0 / int(2));
    }
    int _S298;
    if(_S297)
    {
        _S298 = int(0);
    }
    else
    {
        _S298 = lag_2;
    }
    int dl_0;
    if(_S298 < int(0))
    {
        dl_0 = d_0 - min(- _S298, d_0);
    }
    else
    {
        dl_0 = d_0 + _S298;
    }
    thread Trim_0 t_1 = Trim_x24init_0(_S298, int(0), r_0);
    if(r_0 > dl_0)
    {
        (&t_1)->len_1 = dl_0;
    }
    else
    {
        if(r_0 < dl_0)
        {
            _S297 = _S298 > int(0);
        }
        else
        {
            _S297 = false;
        }
        if(_S297)
        {
            uint _S299 = RO_operatorx5Bx5D_get_2(back_0, uint(_S298 / int(32)));
            int _S300 = _S298 - int((_S299 >> uint(_S298 % int(32))) & 1U);
            (&t_1)->head_0 = _S300;
            if(_S300 > int(0))
            {
                (&t_1)->len_1 = r_0 - (&t_1)->head_0;
            }
            else
            {
                (&t_1)->head_0 = int(0);
            }
        }
    }
    return t_1;
}

uint Trim_frames_0(const Trim_0 thread* this_10, uint window_size_2, uint hop_size_0)
{
    int _S301 = this_10->len_1;
    uint _S302;
    if((this_10->len_1) < int(window_size_2))
    {
        _S302 = 0U;
    }
    else
    {
        uint _S303 = (uint(_S301) - window_size_2) / hop_size_0;
        _S302 = 1U + _S303;
    }
    return _S302;
}

Signals_0 Signals_x24init_0(const RO_0 constant* hi_2, const RO_0 constant* lo_2)
{
    thread Signals_0 _S304;
    (&_S304)->hi_0 = *hi_2;
    (&_S304)->lo_0 = *lo_2;
    return _S304;
}

Inside_0 Inside_x24init_0(const Signals_0 thread* signals_3, uint start_3)
{
    thread Inside_0 _S305;
    (&_S305)->signals_2 = *signals_3;
    (&_S305)->start_2 = start_3;
    return _S305;
}

Windowed_0 Windowed_x24init_0(const Signals_0 thread* signals_4, const Side_0 thread* side_1, int start_4)
{
    thread Windowed_0 _S306;
    (&_S306)->signals_0 = *signals_4;
    (&_S306)->side_0 = *side_1;
    (&_S306)->start_1 = start_4;
    return _S306;
}

struct RW_0
{
    float device* p_2;
};

struct EntryPointParams_0
{
    RO_0 signals_5;
    RO_0 signals_lo_0;
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
    uint total_0;
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
    RW_0 _S307 = entryPointParams_1->out_0;
    uint gid_0 = zimt_index_0(tid_1);
    if(gid_0 >= (entryPointParams_1->total_0))
    {
        return;
    }
    uint band_2 = gid_0 % (&kernelContext_0)->entryPointParams_0->num_bands_0;
    uint _S308 = gid_0 / (&kernelContext_0)->entryPointParams_0->num_bands_0;
    bool ref_0 = (_S308 % 2U) == 0U;
    uint _S309 = gid_0 / (&kernelContext_0)->entryPointParams_0->num_bands_0;
    uint slot_0 = (&kernelContext_0)->entryPointParams_0->first_slot_1 + _S309 / 2U;
    uint _S310 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->slots_1, slot_0);
    uint _S311 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->status_0, _S310);
    if(_S311 != 0U)
    {
        return;
    }
    LagRow_0 _S312 = RO_operatorx5Bx5D_get_4(&(&kernelContext_0)->entryPointParams_0->rows_0, _S310);
    int _S313 = RO_operatorx5Bx5D_get_3(&(&kernelContext_0)->entryPointParams_0->lags_0, _S310);
    thread LagRow_0 _S314 = _S312;
    Trim_0 _S315 = trim_0(&_S314, _S313, &(&kernelContext_0)->entryPointParams_0->back_1);
    uint _S316 = (&kernelContext_0)->entryPointParams_0->window_size_3;
    uint _S317 = (&kernelContext_0)->entryPointParams_0->hop_size_1;
    thread Trim_0 _S318 = _S315;
    uint _S319 = Trim_frames_0(&_S318, _S316, _S317);
    if(_S319 == 0U)
    {
        return;
    }
    uint f_0 = slot_0 - _S312.first_slot_0;
    if(f_0 >= _S319)
    {
        return;
    }
    int off_0;
    if(ref_0)
    {
        off_0 = _S315.head_0;
    }
    else
    {
        off_0 = _S315.head_0 - _S315.lag_0;
    }
    Side_0 s_5;
    if(ref_0)
    {
        s_5 = _S312.a_6;
    }
    else
    {
        s_5 = _S312.b_5;
    }
    uint _S320 = _S312.first_slot_0 * 2U * (&kernelContext_0)->entryPointParams_0->num_bands_0;
    uint grid_0;
    if(ref_0)
    {
        grid_0 = 0U;
    }
    else
    {
        grid_0 = (&kernelContext_0)->entryPointParams_0->num_bands_0 * _S312.slots_0;
    }
    uint base_0 = _S320 + grid_0;
    if(ref_0)
    {
        grid_0 = _S312.a_grid_0;
    }
    else
    {
        grid_0 = _S312.b_grid_0;
    }
    bool _S321;
    if(grid_0 > 0U)
    {
        _S321 = off_0 >= int(s_5.pad_0);
    }
    else
    {
        _S321 = false;
    }
    if(_S321)
    {
        uint _S322;
        if(ref_0)
        {
            _S322 = _S312.a_base_0;
        }
        else
        {
            _S322 = _S312.b_base_0;
        }
        uint start_5 = _S322 + uint(off_0) - s_5.pad_0;
        uint _S323 = start_5 % (&kernelContext_0)->entryPointParams_0->hop_size_1;
        if(_S323 == 0U)
        {
            uint _S324 = start_5 / (&kernelContext_0)->entryPointParams_0->hop_size_1;
            _S321 = (_S324 + _S319) <= grid_0;
        }
        else
        {
            _S321 = false;
        }
        if(_S321)
        {
            if(((&kernelContext_0)->entryPointParams_0->copy_raw_0) != 0U)
            {
                uint _S325 = base_0 + band_2 * _S319 + f_0;
                if(ref_0)
                {
                    _S322 = _S312.a_raw_0;
                }
                else
                {
                    _S322 = _S312.b_raw_0;
                }
                uint _S326 = _S322 + band_2 * grid_0;
                uint _S327 = start_5 / (&kernelContext_0)->entryPointParams_0->hop_size_1;
                float _S328 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->raw_0, _S326 + _S327 + f_0);
                *(_S307.p_2 + _S325) = _S328;
            }
            return;
        }
    }
    int first_0 = off_0 + int(f_0 * (&kernelContext_0)->entryPointParams_0->hop_size_1);
    Signals_0 _S329 = Signals_x24init_0(&(&kernelContext_0)->entryPointParams_0->signals_5, &(&kernelContext_0)->entryPointParams_0->signals_lo_0);
    Side_0 _S330 = s_5;
    if(first_0 >= int(s_5.pad_0))
    {
        int _S331 = first_0 + int((&kernelContext_0)->entryPointParams_0->window_size_3);
        thread Side_0 _S332 = s_5;
        uint _S333 = Side_total_0(&_S332);
        _S321 = _S331 <= int(_S333);
    }
    else
    {
        _S321 = false;
    }
    float rms_0;
    if(_S321)
    {
        uint _S334 = s_5.start_0 + uint(first_0) - _S330.pad_0;
        thread Signals_0 _S335 = _S329;
        Inside_0 _S336 = Inside_x24init_0(&_S335, _S334);
        uint _S337 = (&kernelContext_0)->entryPointParams_0->window_size_3;
        thread Inside_0 _S338 = _S336;
        float _S339 = gammatone_rms_1(&_S338, band_2, &(&kernelContext_0)->entryPointParams_0->coeffs_2, &(&kernelContext_0)->entryPointParams_0->hann_2, _S337);
        rms_0 = _S339;
    }
    else
    {
        thread Signals_0 _S340 = _S329;
        thread Side_0 _S341 = s_5;
        Windowed_0 _S342 = Windowed_x24init_0(&_S340, &_S341, first_0);
        uint _S343 = (&kernelContext_0)->entryPointParams_0->window_size_3;
        thread Windowed_0 _S344 = _S342;
        float _S345 = gammatone_rms_0(&_S344, band_2, &(&kernelContext_0)->entryPointParams_0->coeffs_2, &(&kernelContext_0)->entryPointParams_0->hann_2, _S343);
        rms_0 = _S345;
    }
    *(_S307.p_2 + (base_0 + band_2 * _S319 + f_0)) = rms_0;
    return;
}

