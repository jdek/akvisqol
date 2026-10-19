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
    uint b_0;
    float top_0;
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    threadgroup array<float, int(256)> lowest_1;
    (&kernelContext_0)->lowest_0 = &lowest_1;
    RW_0 _S2 = entryPointParams_1->out_0;
    uint row_0 = zimt_index_0(tid_1) / 256U;
    uint lane_0 = tid_1.x % 256U;
    if(row_0 >= (entryPointParams_1->num_rows_0))
    {
        return;
    }
    SpecPair_0 _S3 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    SpecPair_0 _S4 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    SpecPair_0 _S5 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    SpecPair_0 _S6 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    uint i_3 = lane_0;
    for(;;)
    {
        if(i_3 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S4.ref_frames_0))
        {
        }
        else
        {
            break;
        }
        uint _S7 = _S3.ref_off_0 + i_3;
        float _S8 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->raw_0, _S7);
        *(_S2.p_0 + _S7) = dB_0(_S8);
        i_3 = i_3 + 256U;
    }
    i_3 = lane_0;
    for(;;)
    {
        if(i_3 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S6.deg_frames_0))
        {
        }
        else
        {
            break;
        }
        uint _S9 = _S5.deg_off_0 + i_3;
        float _S10 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->raw_0, _S9);
        *(_S2.p_0 + _S9) = dB_0(_S10);
        i_3 = i_3 + 256U;
    }
    threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup | mem_flags::mem_texture | mem_flags::mem_threadgroup_imageblock);
    uint c_0 = lane_0;
    for(;;)
    {
        if(c_0 < (min(_S4.ref_frames_0, _S6.deg_frames_0)))
        {
        }
        else
        {
            break;
        }
        top_0 = - (as_type<float>((2139095040U)));
        b_0 = 0U;
        for(;;)
        {
            if(b_0 < ((&kernelContext_0)->entryPointParams_0->num_bands_0))
            {
            }
            else
            {
                break;
            }
            float _S11 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S3.ref_off_0 + b_0 * _S4.ref_frames_0 + c_0);
            float _S12 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S5.deg_off_0 + b_0 * _S6.deg_frames_0 + c_0);
            float _S13 = max(top_0, max(_S11, _S12));
            uint _S14 = b_0 + 1U;
            top_0 = _S13;
            b_0 = _S14;
        }
        float _S15 = top_0 - 45.0f;
        uint b_1 = 0U;
        for(;;)
        {
            if(b_1 < ((&kernelContext_0)->entryPointParams_0->num_bands_0))
            {
            }
            else
            {
                break;
            }
            uint _S16 = _S3.ref_off_0 + b_1 * _S4.ref_frames_0 + c_0;
            float _S17 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S16);
            *(_S2.p_0 + _S16) = max(_S17, _S15);
            uint _S18 = _S5.deg_off_0 + b_1 * _S6.deg_frames_0 + c_0;
            float _S19 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S18);
            *(_S2.p_0 + _S18) = max(_S19, _S15);
            b_1 = b_1 + 1U;
        }
        c_0 = c_0 + 256U;
    }
    threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup | mem_flags::mem_texture | mem_flags::mem_threadgroup_imageblock);
    top_0 = (as_type<float>((2139095040U)));
    i_3 = lane_0;
    for(;;)
    {
        if(i_3 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S4.ref_frames_0))
        {
        }
        else
        {
            break;
        }
        float _S20 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S3.ref_off_0 + i_3);
        float _S21 = min(top_0, _S20);
        uint i_4 = i_3 + 256U;
        top_0 = _S21;
        i_3 = i_4;
    }
    i_3 = lane_0;
    for(;;)
    {
        if(i_3 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S6.deg_frames_0))
        {
        }
        else
        {
            break;
        }
        float _S22 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S5.deg_off_0 + i_3);
        float _S23 = min(top_0, _S22);
        uint i_5 = i_3 + 256U;
        top_0 = _S23;
        i_3 = i_5;
    }
    (*(&kernelContext_0)->lowest_0)[lane_0] = top_0;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    b_0 = 128U;
    for(;;)
    {
        if(b_0 > 0U)
        {
        }
        else
        {
            break;
        }
        if(lane_0 < b_0)
        {
            (*(&kernelContext_0)->lowest_0)[lane_0] = min((*(&kernelContext_0)->lowest_0)[lane_0], (*(&kernelContext_0)->lowest_0)[lane_0 + b_0]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        b_0 = b_0 >> 1U;
    }
    float _S24 = (*(&kernelContext_0)->lowest_0)[int(0)];
    i_3 = lane_0;
    for(;;)
    {
        if(i_3 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S4.ref_frames_0))
        {
        }
        else
        {
            break;
        }
        uint _S25 = _S3.ref_off_0 + i_3;
        float _S26 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S25);
        *(_S2.p_0 + _S25) = _S26 - _S24;
        i_3 = i_3 + 256U;
    }
    i_3 = lane_0;
    for(;;)
    {
        if(i_3 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S6.deg_frames_0))
        {
        }
        else
        {
            break;
        }
        uint _S27 = _S5.deg_off_0 + i_3;
        float _S28 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->out_0, _S27);
        *(_S2.p_0 + _S27) = _S28 - _S24;
        i_3 = i_3 + 256U;
    }
    return;
}

