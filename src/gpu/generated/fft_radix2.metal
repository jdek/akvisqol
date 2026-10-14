#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
float2 cmul_0(float2 a_0, float2 b_0)
{
    float _S1 = a_0.x;
    float _S2 = b_0.x;
    float _S3 = a_0.y;
    float _S4 = b_0.y;
    return float2(_S1 * _S2 - _S3 * _S4, _S1 * _S4 + _S3 * _S2);
}

float2 twiddle_0(packed_float2 device* tw_0, uint t_0, uint log2_n_0, float sign_0)
{
    uint s_0 = (log2_n_0 + 1U) >> 1U;
    uint _S5 = 1U << s_0;
    float2 w_0 = cmul_0(float2(*(tw_0+(_S5 + (t_0 >> s_0)))) , float2(*(tw_0+(t_0 & (_S5 - 1U)))) );
    return float2(w_0.x, sign_0 * w_0.y);
}

struct EntryPointParams_0
{
    uint log2_n_1;
    uint p_0;
    uint total_0;
    float sign_1;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    packed_float2 device* entryPointParams_x_0;
    packed_float2 device* entryPointParams_y_0;
    packed_float2 device* entryPointParams_tw_0;
};

[[kernel]] void fft_radix2(uint3 tid_0 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]], packed_float2 device* entryPointParams_x_1 [[buffer(1)]], packed_float2 device* entryPointParams_y_1 [[buffer(2)]], packed_float2 device* entryPointParams_tw_1 [[buffer(3)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    (&kernelContext_0)->entryPointParams_x_0 = entryPointParams_x_1;
    (&kernelContext_0)->entryPointParams_y_0 = entryPointParams_y_1;
    (&kernelContext_0)->entryPointParams_tw_0 = entryPointParams_tw_1;
    uint g_0 = tid_0.x;
    if(g_0 >= (entryPointParams_1->total_0))
    {
        return;
    }
    uint h_0 = (1U << ((&kernelContext_0)->entryPointParams_0->log2_n_1)) >> 1U;
    uint base_0 = (g_0 >> ((&kernelContext_0)->entryPointParams_0->log2_n_1 - 1U)) << ((&kernelContext_0)->entryPointParams_0->log2_n_1);
    uint i_0 = g_0 & (h_0 - 1U);
    uint k_0 = i_0 & ((&kernelContext_0)->entryPointParams_0->p_0 - 1U);
    uint _S6 = base_0 + i_0;
    float2 _S7 = float2(*((&kernelContext_0)->entryPointParams_x_0+_S6)) ;
    float2 _S8 = float2(*((&kernelContext_0)->entryPointParams_x_0+(_S6 + h_0))) ;
    uint _S9 = h_0 / (&kernelContext_0)->entryPointParams_0->p_0;
    float2 u1_0 = cmul_0(_S8, twiddle_0((&kernelContext_0)->entryPointParams_tw_0, k_0 * _S9, (&kernelContext_0)->entryPointParams_0->log2_n_1, (&kernelContext_0)->entryPointParams_0->sign_1));
    uint j_0 = base_0 + ((i_0 - k_0) << 1U) + k_0;
    *((&kernelContext_0)->entryPointParams_y_0+j_0) = packed_float2((_S7 + u1_0)) ;
    *((&kernelContext_0)->entryPointParams_y_0+(j_0 + (&kernelContext_0)->entryPointParams_0->p_0)) = packed_float2((_S7 - u1_0)) ;
    return;
}

