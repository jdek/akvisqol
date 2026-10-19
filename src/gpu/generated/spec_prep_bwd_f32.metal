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

struct SpecPair_0
{
    uint ref_off_0;
    uint ref_frames_0;
    uint deg_off_0;
    uint deg_frames_0;
};

struct RO_1
{
    SpecPair_0 device* p_0;
};

SpecPair_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 8388608U;
}

float dB_0(float x_0)
{
    float _S1;
    if(x_0 == 0.0f)
    {
        _S1 = (as_type<float>((872415232U)));
    }
    else
    {
        _S1 = abs(x_0);
    }
    return max(10.0f * log10(_S1), -45.0f);
}

float dBSlope_0(float x_1, float d_0)
{
    bool _S2;
    if(x_1 != 0.0f)
    {
        _S2 = d_0 > -45.0f;
    }
    else
    {
        _S2 = false;
    }
    float _S3;
    if(_S2)
    {
        _S3 = 10.0f / (x_1 * 2.30258512496948242f);
    }
    else
    {
        _S3 = 0.0f;
    }
    return _S3;
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_1 rows_0;
    RO_0 raw_0;
    RO_0 out_0;
    RO_0 g_out_0;
    RW_0 g_raw_0;
    uint num_rows_0;
    uint num_bands_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    array<float, int(256)> threadgroup* g_part_0;
    array<uint, int(256)> threadgroup* g_first_0;
};

[[kernel]] void spec_prep_bwd(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    uint cell_0;
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    threadgroup array<float, int(256)> g_part_1;
    (&kernelContext_0)->g_part_0 = &g_part_1;
    threadgroup array<uint, int(256)> g_first_1;
    (&kernelContext_0)->g_first_0 = &g_first_1;
    RW_0 _S4 = entryPointParams_1->g_raw_0;
    uint row_0 = zimt_index_0(tid_1) / 256U;
    uint lane_0 = tid_1.x % 256U;
    if(row_0 >= (entryPointParams_1->num_rows_0))
    {
        return;
    }
    SpecPair_0 _S5 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    SpecPair_0 _S6 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    SpecPair_0 _S7 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    SpecPair_0 _S8 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    uint _S9 = (&kernelContext_0)->entryPointParams_0->num_bands_0 * _S6.ref_frames_0;
    uint first_0 = 4294967295U;
    uint i_2 = lane_0;
    float sum_0 = 0.0f;
    for(;;)
    {
        if(i_2 < _S9)
        {
        }
        else
        {
            break;
        }
        uint _S10 = _S5.ref_off_0 + i_2;
        float _S11 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->g_out_0, _S10);
        float sum_1 = sum_0 + _S11;
        float _S12 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->out_0, _S10);
        if(_S12 == 0.0f)
        {
            first_0 = min(first_0, i_2);
        }
        i_2 = i_2 + 256U;
        sum_0 = sum_1;
    }
    i_2 = lane_0;
    for(;;)
    {
        if(i_2 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S8.deg_frames_0))
        {
        }
        else
        {
            break;
        }
        uint _S13 = _S7.deg_off_0 + i_2;
        float _S14 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->g_out_0, _S13);
        float sum_2 = sum_0 + _S14;
        float _S15 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->out_0, _S13);
        if(_S15 == 0.0f)
        {
            first_0 = min(first_0, _S9 + i_2);
        }
        i_2 = i_2 + 256U;
        sum_0 = sum_2;
    }
    (*(&kernelContext_0)->g_part_0)[lane_0] = sum_0;
    (*(&kernelContext_0)->g_first_0)[lane_0] = first_0;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint s_0 = 128U;
    for(;;)
    {
        if(s_0 > 0U)
        {
        }
        else
        {
            break;
        }
        if(lane_0 < s_0)
        {
            uint _S16 = lane_0 + s_0;
            (*(&kernelContext_0)->g_part_0)[lane_0] = (*(&kernelContext_0)->g_part_0)[lane_0] + (*(&kernelContext_0)->g_part_0)[_S16];
            (*(&kernelContext_0)->g_first_0)[lane_0] = min((*(&kernelContext_0)->g_first_0)[lane_0], (*(&kernelContext_0)->g_first_0)[_S16]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        s_0 = s_0 >> 1U;
    }
    float _S17 = - (*(&kernelContext_0)->g_part_0)[int(0)];
    uint _S18 = (*(&kernelContext_0)->g_first_0)[int(0)];
    uint _S19 = min(_S6.ref_frames_0, _S8.deg_frames_0);
    uint c_0 = lane_0;
    for(;;)
    {
        if(c_0 < _S19)
        {
        }
        else
        {
            break;
        }
        float top_0 = - (as_type<float>((2139095040U)));
        uint arg_0 = 0U;
        uint k_0 = 0U;
        for(;;)
        {
            if(k_0 < (2U * (&kernelContext_0)->entryPointParams_0->num_bands_0))
            {
            }
            else
            {
                break;
            }
            if(k_0 < ((&kernelContext_0)->entryPointParams_0->num_bands_0))
            {
                cell_0 = _S5.ref_off_0 + k_0 * _S6.ref_frames_0 + c_0;
            }
            else
            {
                cell_0 = _S7.deg_off_0 + (k_0 - (&kernelContext_0)->entryPointParams_0->num_bands_0) * _S8.deg_frames_0 + c_0;
            }
            float _S20 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->raw_0, cell_0);
            float d_1 = dB_0(_S20);
            if(d_1 > top_0)
            {
                top_0 = d_1;
                arg_0 = k_0;
            }
            k_0 = k_0 + 1U;
        }
        float _S21 = top_0 - 45.0f;
        float g_arg_0 = 0.0f;
        uint k_1 = 0U;
        float g_floor_0 = 0.0f;
        for(;;)
        {
            if(k_1 < (2U * (&kernelContext_0)->entryPointParams_0->num_bands_0))
            {
            }
            else
            {
                break;
            }
            if(k_1 < ((&kernelContext_0)->entryPointParams_0->num_bands_0))
            {
                cell_0 = _S5.ref_off_0 + k_1 * _S6.ref_frames_0 + c_0;
            }
            else
            {
                cell_0 = _S7.deg_off_0 + (k_1 - (&kernelContext_0)->entryPointParams_0->num_bands_0) * _S8.deg_frames_0 + c_0;
            }
            uint lin_0;
            if(k_1 < ((&kernelContext_0)->entryPointParams_0->num_bands_0))
            {
                lin_0 = k_1 * _S6.ref_frames_0 + c_0;
            }
            else
            {
                lin_0 = _S9 + (k_1 - (&kernelContext_0)->entryPointParams_0->num_bands_0) * _S8.deg_frames_0 + c_0;
            }
            float _S22 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->g_out_0, cell_0);
            if(lin_0 == _S18)
            {
                sum_0 = _S17;
            }
            else
            {
                sum_0 = 0.0f;
            }
            float g_0 = _S22 + sum_0;
            float _S23 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->raw_0, cell_0);
            float d_2 = dB_0(_S23);
            float g_1;
            if(d_2 < _S21)
            {
                float g_floor_1 = g_floor_0 + g_0;
                g_1 = 0.0f;
                g_floor_0 = g_floor_1;
            }
            else
            {
                g_1 = g_0;
            }
            if(k_1 == arg_0)
            {
                g_arg_0 = g_1;
            }
            else
            {
                float _S24 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->raw_0, cell_0);
                *(_S4.p_1 + cell_0) = g_1 * dBSlope_0(_S24, d_2);
            }
            k_1 = k_1 + 1U;
        }
        if(arg_0 < ((&kernelContext_0)->entryPointParams_0->num_bands_0))
        {
            cell_0 = _S5.ref_off_0 + arg_0 * _S6.ref_frames_0 + c_0;
        }
        else
        {
            cell_0 = _S7.deg_off_0 + (arg_0 - (&kernelContext_0)->entryPointParams_0->num_bands_0) * _S8.deg_frames_0 + c_0;
        }
        float _S25 = g_arg_0 + g_floor_0;
        float _S26 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->raw_0, cell_0);
        *(_S4.p_1 + cell_0) = _S25 * dBSlope_0(_S26, top_0);
        c_0 = c_0 + 256U;
    }
    i_2 = lane_0;
    for(;;)
    {
        if(i_2 < _S9)
        {
        }
        else
        {
            break;
        }
        uint _S27 = i_2 % _S6.ref_frames_0;
        if(_S27 < _S19)
        {
            i_2 = i_2 + 256U;
            continue;
        }
        uint _S28 = _S5.ref_off_0 + i_2;
        float _S29 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->g_out_0, _S28);
        if(i_2 == _S18)
        {
            sum_0 = _S17;
        }
        else
        {
            sum_0 = 0.0f;
        }
        float _S30 = _S29 + sum_0;
        float _S31 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->raw_0, _S28);
        float _S32 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->raw_0, _S28);
        *(_S4.p_1 + _S28) = _S30 * dBSlope_0(_S31, dB_0(_S32));
        i_2 = i_2 + 256U;
    }
    i_2 = lane_0;
    for(;;)
    {
        if(i_2 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S8.deg_frames_0))
        {
        }
        else
        {
            break;
        }
        uint _S33 = i_2 % _S8.deg_frames_0;
        if(_S33 < _S19)
        {
            i_2 = i_2 + 256U;
            continue;
        }
        uint _S34 = _S7.deg_off_0 + i_2;
        float _S35 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->g_out_0, _S34);
        if((_S9 + i_2) == _S18)
        {
            sum_0 = _S17;
        }
        else
        {
            sum_0 = 0.0f;
        }
        float _S36 = _S35 + sum_0;
        float _S37 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->raw_0, _S34);
        float _S38 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->raw_0, _S34);
        *(_S4.p_1 + _S34) = _S36 * dBSlope_0(_S37, dB_0(_S38));
        i_2 = i_2 + 256U;
    }
    return;
}

