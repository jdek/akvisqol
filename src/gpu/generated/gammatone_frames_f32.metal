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
    uint start_0;
};

float Samples_at_0(const Samples_0 thread* this_2, uint i_2)
{
    float _S1 = RO_operatorx5Bx5D_get_1(&this_2->signals_0, this_2->start_0 + i_2);
    return _S1;
}

float gammatone_rms_0(const Samples_0 thread* frame_0, uint band_0, const RO_0 constant* coeffs_0, const RO_0 constant* hann_0, uint window_size_0)
{
    uint o_0 = band_0 * 10U;
    float _S2 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0);
    float _S3 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 1U);
    float _S4 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 2U);
    float _S5 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 3U);
    float _S6 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 4U);
    float _S7 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 5U);
    float _S8 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 6U);
    float _S9 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 7U);
    float _S10 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 8U);
    float _S11 = RO_operatorx5Bx5D_get_0(coeffs_0, o_0 + 9U);
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
    uint i_3 = 0U;
    float block_0 = 0.0f;
    float total_0 = 0.0f;
    for(;;)
    {
        if(i_3 < window_size_0)
        {
        }
        else
        {
            break;
        }
        float _S12 = Samples_at_0(frame_0, i_3);
        float _S13 = RO_operatorx5Bx5D_get_0(hann_0, i_3);
        float x_0 = _S12 * _S13;
        float dy_1_1 = dy_1_0 + _S8 * dy_1_0 - _S9 * y_1_0 + (_S2 * (x_0 - x1_1_0) + _S3 * x1_1_0 + _S4 * x2_1_0);
        float y_1_1 = y_1_0 + dy_1_1;
        float dy_2_1 = dy_2_0 + _S8 * dy_2_0 - _S9 * y_2_0 + (_S10 * dy_1_1 + _S5 * y_1_0 + _S11 * x2_2_0);
        float y_2_1 = y_2_0 + dy_2_1;
        float dy_3_1 = dy_3_0 + _S8 * dy_3_0 - _S9 * y_3_0 + (_S10 * dy_2_1 + _S6 * y_2_0 + _S11 * x2_3_0);
        float y_3_1 = y_3_0 + dy_3_1;
        float dy_4_1 = dy_4_0 + _S8 * dy_4_0 - _S9 * y_4_0 + (_S10 * dy_3_1 + _S7 * y_3_0 + _S11 * x2_4_0);
        float y_4_1 = y_4_0 + dy_4_1;
        float block_1 = block_0 + y_4_1 * y_4_1;
        if((i_3 & 63U) == 63U)
        {
            float total_1 = total_0 + block_1;
            block_0 = 0.0f;
            total_0 = total_1;
        }
        else
        {
            block_0 = block_1;
        }
        uint _S14 = i_3 + 1U;
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
        i_3 = _S14;
    }
    return sqrt((total_0 + block_0) / float(window_size_0));
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

Frame_0 RO_operatorx5Bx5D_get_2(const RO_1 constant* this_3, uint i_4)
{
    return *(this_3->p_0 + i_4);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

Samples_0 Samples_x24init_0(const RO_0 constant* signals_1, uint start_2)
{
    thread Samples_0 _S15;
    (&_S15)->signals_0 = *signals_1;
    (&_S15)->start_0 = start_2;
    return _S15;
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_0 signals_2;
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
    RW_0 _S16 = entryPointParams_1->out_1;
    uint gid_0 = zimt_index_0(tid_1);
    uint band_1 = gid_0 % entryPointParams_1->num_bands_0;
    uint frame_1 = gid_0 / entryPointParams_1->num_bands_0;
    if(frame_1 >= ((&kernelContext_0)->entryPointParams_0->num_frames_0))
    {
        return;
    }
    Frame_0 _S17 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->frames_0, frame_1);
    Samples_0 _S18 = Samples_x24init_0(&(&kernelContext_0)->entryPointParams_0->signals_2, _S17.start_1);
    uint _S19 = _S17.out_0 + band_1 * _S17.stride_0;
    uint _S20 = (&kernelContext_0)->entryPointParams_0->window_size_1;
    thread Samples_0 _S21 = _S18;
    float _S22 = gammatone_rms_0(&_S21, band_1, &(&kernelContext_0)->entryPointParams_0->coeffs_1, &(&kernelContext_0)->entryPointParams_0->hann_1, _S20);
    *(_S16.p_1 + _S19) = _S22;
    return;
}

