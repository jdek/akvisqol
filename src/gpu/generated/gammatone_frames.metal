#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

struct EntryPointParams_0
{
    uint num_frames_0;
    uint num_bands_0;
    uint window_size_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    float device* entryPointParams_signals_0;
    uint device* entryPointParams_frames_0;
    float device* entryPointParams_coeffs_0;
    float device* entryPointParams_coeffs2_0;
    float device* entryPointParams_hann_0;
    float device* entryPointParams_out_0;
};

[[kernel]] void gammatone_frames(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]], float device* entryPointParams_signals_1 [[buffer(1)]], uint device* entryPointParams_frames_1 [[buffer(2)]], float device* entryPointParams_coeffs_1 [[buffer(3)]], float device* entryPointParams_coeffs2_1 [[buffer(4)]], float device* entryPointParams_hann_1 [[buffer(5)]], float device* entryPointParams_out_1 [[buffer(6)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    (&kernelContext_0)->entryPointParams_signals_0 = entryPointParams_signals_1;
    (&kernelContext_0)->entryPointParams_frames_0 = entryPointParams_frames_1;
    (&kernelContext_0)->entryPointParams_coeffs_0 = entryPointParams_coeffs_1;
    (&kernelContext_0)->entryPointParams_coeffs2_0 = entryPointParams_coeffs2_1;
    (&kernelContext_0)->entryPointParams_hann_0 = entryPointParams_hann_1;
    (&kernelContext_0)->entryPointParams_out_0 = entryPointParams_out_1;
    uint gid_0 = zimt_index_0(tid_1);
    uint band_0 = gid_0 % entryPointParams_1->num_bands_0;
    uint frame_0 = gid_0 / entryPointParams_1->num_bands_0;
    if(frame_0 >= ((&kernelContext_0)->entryPointParams_0->num_frames_0))
    {
        return;
    }
    uint _S1 = frame_0 * 3U;
    uint _S2 = (&kernelContext_0)->entryPointParams_frames_0[_S1];
    uint out_idx_0 = (&kernelContext_0)->entryPointParams_frames_0[_S1 + 1U] + band_0 * (&kernelContext_0)->entryPointParams_frames_0[_S1 + 2U];
    uint _S3 = band_0 * 8U;
    float _S4 = (&kernelContext_0)->entryPointParams_coeffs_0[_S3];
    float _S5 = (&kernelContext_0)->entryPointParams_coeffs_0[_S3 + 1U];
    float _S6 = (&kernelContext_0)->entryPointParams_coeffs_0[_S3 + 2U];
    float _S7 = (&kernelContext_0)->entryPointParams_coeffs_0[_S3 + 3U];
    float _S8 = (&kernelContext_0)->entryPointParams_coeffs_0[_S3 + 4U];
    float _S9 = (&kernelContext_0)->entryPointParams_coeffs_0[_S3 + 5U];
    float _S10 = (&kernelContext_0)->entryPointParams_coeffs_0[_S3 + 6U];
    float _S11 = (&kernelContext_0)->entryPointParams_coeffs_0[_S3 + 7U];
    uint _S12 = band_0 * 2U;
    float _S13 = (&kernelContext_0)->entryPointParams_coeffs2_0[_S12];
    float _S14 = (&kernelContext_0)->entryPointParams_coeffs2_0[_S12 + 1U];
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
    uint i_0 = 0U;
    float block_0 = 0.0f;
    float total_0 = 0.0f;
    for(;;)
    {
        if(i_0 < ((&kernelContext_0)->entryPointParams_0->window_size_0))
        {
        }
        else
        {
            break;
        }
        float x_0 = (&kernelContext_0)->entryPointParams_signals_0[_S2 + i_0] * (&kernelContext_0)->entryPointParams_hann_0[i_0];
        float dy_1_1 = dy_1_0 + _S10 * dy_1_0 - _S11 * y_1_0 + (_S4 * (x_0 - x1_1_0) + _S5 * x1_1_0 + _S6 * x2_1_0);
        float y_1_1 = y_1_0 + dy_1_1;
        float dy_2_1 = dy_2_0 + _S10 * dy_2_0 - _S11 * y_2_0 + (_S13 * dy_1_1 + _S7 * y_1_0 + _S14 * x2_2_0);
        float y_2_1 = y_2_0 + dy_2_1;
        float dy_3_1 = dy_3_0 + _S10 * dy_3_0 - _S11 * y_3_0 + (_S13 * dy_2_1 + _S8 * y_2_0 + _S14 * x2_3_0);
        float y_3_1 = y_3_0 + dy_3_1;
        float dy_4_1 = dy_4_0 + _S10 * dy_4_0 - _S11 * y_4_0 + (_S13 * dy_3_1 + _S9 * y_3_0 + _S14 * x2_4_0);
        float y_4_1 = y_4_0 + dy_4_1;
        float block_1 = block_0 + y_4_1 * y_4_1;
        if((i_0 & 63U) == 63U)
        {
            float total_1 = total_0 + block_1;
            block_0 = 0.0f;
            total_0 = total_1;
        }
        else
        {
            block_0 = block_1;
        }
        uint _S15 = i_0 + 1U;
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
        i_0 = _S15;
    }
    *((&kernelContext_0)->entryPointParams_out_0+out_idx_0) = sqrt((total_0 + block_0) / float((&kernelContext_0)->entryPointParams_0->window_size_0));
    return;
}

