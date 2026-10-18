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

struct RO_1
{
    uint device* p_0;
};

uint RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_0 signals_0;
    RO_1 frames_0;
    RO_0 coeffs_0;
    RO_0 coeffs2_0;
    RO_0 hann_0;
    RW_0 out_0;
    uint num_frames_0;
    uint num_bands_0;
    uint window_size_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void gammatone_frames(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S1 = entryPointParams_1->out_0;
    uint gid_0 = zimt_index_0(tid_1);
    uint band_0 = gid_0 % entryPointParams_1->num_bands_0;
    uint frame_0 = gid_0 / entryPointParams_1->num_bands_0;
    if(frame_0 >= ((&kernelContext_0)->entryPointParams_0->num_frames_0))
    {
        return;
    }
    uint _S2 = frame_0 * 3U;
    uint _S3 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->frames_0, _S2);
    uint _S4 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->frames_0, _S2 + 1U);
    uint _S5 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->frames_0, _S2 + 2U);
    uint out_idx_0 = _S4 + band_0 * _S5;
    uint _S6 = band_0 * 8U;
    float _S7 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->coeffs_0, _S6);
    float _S8 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->coeffs_0, _S6 + 1U);
    float _S9 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->coeffs_0, _S6 + 2U);
    float _S10 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->coeffs_0, _S6 + 3U);
    float _S11 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->coeffs_0, _S6 + 4U);
    float _S12 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->coeffs_0, _S6 + 5U);
    float _S13 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->coeffs_0, _S6 + 6U);
    float _S14 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->coeffs_0, _S6 + 7U);
    uint _S15 = band_0 * 2U;
    float _S16 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->coeffs2_0, _S15);
    float _S17 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->coeffs2_0, _S15 + 1U);
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
    uint i_2 = 0U;
    float block_0 = 0.0f;
    float total_0 = 0.0f;
    for(;;)
    {
        if(i_2 < ((&kernelContext_0)->entryPointParams_0->window_size_0))
        {
        }
        else
        {
            break;
        }
        float _S18 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->signals_0, _S3 + i_2);
        float _S19 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->hann_0, i_2);
        float x_0 = _S18 * _S19;
        float dy_1_1 = dy_1_0 + _S13 * dy_1_0 - _S14 * y_1_0 + (_S7 * (x_0 - x1_1_0) + _S8 * x1_1_0 + _S9 * x2_1_0);
        float y_1_1 = y_1_0 + dy_1_1;
        float dy_2_1 = dy_2_0 + _S13 * dy_2_0 - _S14 * y_2_0 + (_S16 * dy_1_1 + _S10 * y_1_0 + _S17 * x2_2_0);
        float y_2_1 = y_2_0 + dy_2_1;
        float dy_3_1 = dy_3_0 + _S13 * dy_3_0 - _S14 * y_3_0 + (_S16 * dy_2_1 + _S11 * y_2_0 + _S17 * x2_3_0);
        float y_3_1 = y_3_0 + dy_3_1;
        float dy_4_1 = dy_4_0 + _S13 * dy_4_0 - _S14 * y_4_0 + (_S16 * dy_3_1 + _S12 * y_3_0 + _S17 * x2_4_0);
        float y_4_1 = y_4_0 + dy_4_1;
        float block_1 = block_0 + y_4_1 * y_4_1;
        if((i_2 & 63U) == 63U)
        {
            float total_1 = total_0 + block_1;
            block_0 = 0.0f;
            total_0 = total_1;
        }
        else
        {
            block_0 = block_1;
        }
        uint _S20 = i_2 + 1U;
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
        i_2 = _S20;
    }
    *(_S1.p_1 + out_idx_0) = sqrt((total_0 + block_0) / float((&kernelContext_0)->entryPointParams_0->window_size_0));
    return;
}

