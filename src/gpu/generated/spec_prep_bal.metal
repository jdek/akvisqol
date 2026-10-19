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

struct SpecPair_0
{
    uint ref_off_0;
    uint ref_frames_0;
    uint deg_off_0;
    uint deg_frames_0;
};

struct RO_1
{
    SpecPair_0 device* p_1;
};

SpecPair_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_2, uint i_2)
{
    return *(this_2->p_1 + i_2);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 8388608U;
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

DF_0 neg_0(const DF_0 thread* a_0)
{
    return DF_x24init_1(- a_0->hi_0, - a_0->lo_0);
}

DF_0 twoSum_0(float a_1, float b_0)
{
    float s_0 = a_1 + b_0;
    float bb_0 = s_0 - a_1;
    return DF_x24init_1(s_0, a_1 - (s_0 - bb_0) + (b_0 - bb_0));
}

DF_0 quickTwoSum_0(float a_2, float b_1)
{
    float s_1 = a_2 + b_1;
    return DF_x24init_1(s_1, b_1 - (s_1 - a_2));
}

DF_0 add_0(const DF_0 thread* a_3, const DF_0 thread* b_2)
{
    DF_0 s_2 = twoSum_0(a_3->hi_0, b_2->hi_0);
    DF_0 t_0 = twoSum_0(a_3->lo_0, b_2->lo_0);
    DF_0 s_3 = quickTwoSum_0(s_2.hi_0, s_2.lo_0 + t_0.hi_0);
    return quickTwoSum_0(s_3.hi_0, s_3.lo_0 + t_0.lo_0);
}

DF_0 add_1(const DF_0 thread* a_4, const DF_0 thread* b_3)
{
    DF_0 s_4 = twoSum_0(a_4->hi_0, b_3->hi_0);
    DF_0 t_1 = twoSum_0(a_4->lo_0, b_3->lo_0);
    DF_0 s_5 = quickTwoSum_0(s_4.hi_0, s_4.lo_0 + t_1.hi_0);
    return quickTwoSum_0(s_5.hi_0, s_5.lo_0 + t_1.lo_0);
}

DF_0 sub_0(const DF_0 thread* a_5, const DF_0 thread* b_4)
{
    DF_0 _S3 = neg_0(b_4);
    thread DF_0 _S4 = _S3;
    DF_0 _S5 = add_1(a_5, &_S4);
    return _S5;
}

DF_0 sub_1(const DF_0 thread* a_6, const DF_0 thread* b_5)
{
    DF_0 _S6 = neg_0(b_5);
    thread DF_0 _S7 = _S6;
    DF_0 _S8 = add_1(a_6, &_S7);
    return _S8;
}

DF_0 mul_0(const DF_0 thread* a_7, const DF_0 thread* b_6)
{
    float p_2 = a_7->hi_0 * b_6->hi_0;
    return quickTwoSum_0(p_2, fma(a_7->hi_0, b_6->hi_0, - p_2) + (a_7->hi_0 * b_6->lo_0 + a_7->lo_0 * b_6->hi_0));
}

DF_0 mul_1(const DF_0 thread* a_8, const DF_0 thread* b_7)
{
    float p_3 = a_8->hi_0 * b_7->hi_0;
    return quickTwoSum_0(p_3, fma(a_8->hi_0, b_7->hi_0, - p_3) + (a_8->hi_0 * b_7->lo_0 + a_8->lo_0 * b_7->hi_0));
}

DF_0 mul_2(const DF_0 thread* a_9, const DF_0 thread* b_8)
{
    float p_4 = a_9->hi_0 * b_8->hi_0;
    return quickTwoSum_0(p_4, fma(a_9->hi_0, b_8->hi_0, - p_4) + (a_9->hi_0 * b_8->lo_0 + a_9->lo_0 * b_8->hi_0));
}

DF_0 mul_3(const DF_0 thread* a_10, const DF_0 thread* b_9)
{
    float p_5 = a_10->hi_0 * b_9->hi_0;
    return quickTwoSum_0(p_5, fma(a_10->hi_0, b_9->hi_0, - p_5) + (a_10->hi_0 * b_9->lo_0 + a_10->lo_0 * b_9->hi_0));
}

DF_0 div_0(const DF_0 thread* a_11, const DF_0 thread* b_10)
{
    float _S9 = b_10->hi_0;
    float q1_0 = a_11->hi_0 / b_10->hi_0;
    thread DF_0 _S10 = DF_x24init_0(q1_0);
    DF_0 _S11 = mul_3(&_S10, b_10);
    thread DF_0 _S12 = _S11;
    DF_0 _S13 = sub_1(a_11, &_S12);
    float q2_0 = _S13.hi_0 / _S9;
    thread DF_0 _S14 = DF_x24init_0(q2_0);
    DF_0 _S15 = mul_3(&_S14, b_10);
    thread DF_0 _S16 = _S13;
    thread DF_0 _S17 = _S15;
    DF_0 _S18 = sub_1(&_S16, &_S17);
    DF_0 _S19 = DF_x24init_0(_S18.hi_0 / _S9);
    thread DF_0 _S20 = quickTwoSum_0(q1_0, q2_0);
    thread DF_0 _S21 = _S19;
    DF_0 _S22 = add_1(&_S20, &_S21);
    return _S22;
}

DF_0 ln_0(float x_1)
{
    uint bits_0 = (as_type<uint>((x_1)));
    int e_0 = int((bits_0 >> 23U) & 255U) - int(127);
    float m_0 = (as_type<float>(((bits_0 & 8388607U) | 1065353216U)));
    float m_1;
    int e_1;
    if(m_0 > 1.41421353816986084f)
    {
        int e_2 = e_0 + int(1);
        m_1 = m_0 * 0.5f;
        e_1 = e_2;
    }
    else
    {
        m_1 = m_0;
        e_1 = e_0;
    }
    DF_0 _S23 = DF_x24init_0(m_1);
    DF_0 _S24 = DF_x24init_0(1.0f);
    thread DF_0 _S25 = _S23;
    thread DF_0 _S26 = _S24;
    DF_0 _S27 = sub_0(&_S25, &_S26);
    thread DF_0 _S28 = _S23;
    thread DF_0 _S29 = _S24;
    DF_0 _S30 = add_0(&_S28, &_S29);
    thread DF_0 _S31 = _S27;
    thread DF_0 _S32 = _S30;
    DF_0 _S33 = div_0(&_S31, &_S32);
    float _S34 = _S33.hi_0;
    float z_0 = _S34 * _S34;
    float tail_0 = z_0 * (0.3333333432674408f + z_0 * (0.20000000298023224f + z_0 * (0.1428571492433548f + z_0 * (0.1111111119389534f + z_0 * 0.09090909361839294f))));
    thread DF_0 _S35 = _S33;
    thread DF_0 _S36 = _S33;
    DF_0 _S37 = add_0(&_S35, &_S36);
    DF_0 _S38 = quickTwoSum_0(1.0f, tail_0);
    thread DF_0 _S39 = _S37;
    thread DF_0 _S40 = _S38;
    DF_0 _S41 = mul_0(&_S39, &_S40);
    DF_0 LN2_0 = DF_x24init_1((as_type<float>((1060205080U))), (as_type<float>((2969756424U))));
    thread DF_0 _S42 = DF_x24init_0(float(e_1));
    thread DF_0 _S43 = LN2_0;
    DF_0 _S44 = mul_0(&_S42, &_S43);
    thread DF_0 _S45 = _S44;
    thread DF_0 _S46 = _S41;
    DF_0 _S47 = add_0(&_S45, &_S46);
    return _S47;
}

DF_0 log10DF_0(float x_2)
{
    DF_0 LN10_INV_0 = DF_x24init_1((as_type<float>((1054759897U))), (as_type<float>((2989330863U))));
    thread DF_0 _S48 = ln_0(x_2);
    thread DF_0 _S49 = LN10_INV_0;
    DF_0 _S50 = mul_1(&_S48, &_S49);
    return _S50;
}

float dB_0(float x_3)
{
    float _S51;
    if(x_3 == 0.0f)
    {
        _S51 = (as_type<float>((872415232U)));
    }
    else
    {
        _S51 = abs(x_3);
    }
    DF_0 _S52 = DF_x24init_0(10.0f);
    thread DF_0 _S53 = log10DF_0(_S51);
    thread DF_0 _S54 = _S52;
    DF_0 _S55 = mul_2(&_S53, &_S54);
    return max(_S55.hi_0 + _S55.lo_0, -45.0f);
}

struct EntryPointParams_0
{
    RO_1 rows_0;
    RO_0 raw_0;
    RW_0 out_0;
    uint num_rows_0;
    uint num_bands_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    array<float, int(256)> threadgroup* lowest_0;
};

[[kernel]] void spec_prep(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    uint b_11;
    float top_0;
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    threadgroup array<float, int(256)> lowest_1;
    (&kernelContext_0)->lowest_0 = &lowest_1;
    RW_0 _S56 = entryPointParams_1->out_0;
    uint row_0 = zimt_index_0(tid_1) / 256U;
    uint lane_0 = tid_1.x % 256U;
    if(row_0 >= (entryPointParams_1->num_rows_0))
    {
        return;
    }
    SpecPair_0 _S57 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    SpecPair_0 _S58 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    SpecPair_0 _S59 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    SpecPair_0 _S60 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    uint i_3 = lane_0;
    for(;;)
    {
        if(i_3 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S58.ref_frames_0))
        {
        }
        else
        {
            break;
        }
        uint _S61 = _S57.ref_off_0 + i_3;
        float _S62 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->raw_0, _S61);
        *(_S56.p_0 + _S61) = dB_0(_S62);
        i_3 = i_3 + 256U;
    }
    i_3 = lane_0;
    for(;;)
    {
        if(i_3 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S60.deg_frames_0))
        {
        }
        else
        {
            break;
        }
        uint _S63 = _S59.deg_off_0 + i_3;
        float _S64 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->raw_0, _S63);
        *(_S56.p_0 + _S63) = dB_0(_S64);
        i_3 = i_3 + 256U;
    }
    threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup | mem_flags::mem_texture | mem_flags::mem_threadgroup_imageblock);
    uint c_0 = lane_0;
    for(;;)
    {
        if(c_0 < (min(_S58.ref_frames_0, _S60.deg_frames_0)))
        {
        }
        else
        {
            break;
        }
        top_0 = - (as_type<float>((2139095040U)));
        b_11 = 0U;
        for(;;)
        {
            if(b_11 < ((&kernelContext_0)->entryPointParams_0->num_bands_0))
            {
            }
            else
            {
                break;
            }
            float _S65 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S57.ref_off_0 + b_11 * _S58.ref_frames_0 + c_0);
            float _S66 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S59.deg_off_0 + b_11 * _S60.deg_frames_0 + c_0);
            float _S67 = max(top_0, max(_S65, _S66));
            uint _S68 = b_11 + 1U;
            top_0 = _S67;
            b_11 = _S68;
        }
        float _S69 = top_0 - 45.0f;
        uint b_12 = 0U;
        for(;;)
        {
            if(b_12 < ((&kernelContext_0)->entryPointParams_0->num_bands_0))
            {
            }
            else
            {
                break;
            }
            uint _S70 = _S57.ref_off_0 + b_12 * _S58.ref_frames_0 + c_0;
            float _S71 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S70);
            *(_S56.p_0 + _S70) = max(_S71, _S69);
            uint _S72 = _S59.deg_off_0 + b_12 * _S60.deg_frames_0 + c_0;
            float _S73 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S72);
            *(_S56.p_0 + _S72) = max(_S73, _S69);
            b_12 = b_12 + 1U;
        }
        c_0 = c_0 + 256U;
    }
    threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup | mem_flags::mem_texture | mem_flags::mem_threadgroup_imageblock);
    top_0 = (as_type<float>((2139095040U)));
    i_3 = lane_0;
    for(;;)
    {
        if(i_3 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S58.ref_frames_0))
        {
        }
        else
        {
            break;
        }
        float _S74 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S57.ref_off_0 + i_3);
        float _S75 = min(top_0, _S74);
        uint i_4 = i_3 + 256U;
        top_0 = _S75;
        i_3 = i_4;
    }
    i_3 = lane_0;
    for(;;)
    {
        if(i_3 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S60.deg_frames_0))
        {
        }
        else
        {
            break;
        }
        float _S76 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S59.deg_off_0 + i_3);
        float _S77 = min(top_0, _S76);
        uint i_5 = i_3 + 256U;
        top_0 = _S77;
        i_3 = i_5;
    }
    (*(&kernelContext_0)->lowest_0)[lane_0] = top_0;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    b_11 = 128U;
    for(;;)
    {
        if(b_11 > 0U)
        {
        }
        else
        {
            break;
        }
        if(lane_0 < b_11)
        {
            (*(&kernelContext_0)->lowest_0)[lane_0] = min((*(&kernelContext_0)->lowest_0)[lane_0], (*(&kernelContext_0)->lowest_0)[lane_0 + b_11]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        b_11 = b_11 >> 1U;
    }
    float _S78 = (*(&kernelContext_0)->lowest_0)[int(0)];
    i_3 = lane_0;
    for(;;)
    {
        if(i_3 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S58.ref_frames_0))
        {
        }
        else
        {
            break;
        }
        uint _S79 = _S57.ref_off_0 + i_3;
        float _S80 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S79);
        *(_S56.p_0 + _S79) = _S80 - _S78;
        i_3 = i_3 + 256U;
    }
    i_3 = lane_0;
    for(;;)
    {
        if(i_3 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S60.deg_frames_0))
        {
        }
        else
        {
            break;
        }
        uint _S81 = _S59.deg_off_0 + i_3;
        float _S82 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S81);
        *(_S56.p_0 + _S81) = _S82 - _S78;
        i_3 = i_3 + 256U;
    }
    return;
}

