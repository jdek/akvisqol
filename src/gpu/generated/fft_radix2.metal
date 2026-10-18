#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

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

void Radix2_dft_0(array<float2, int(2)> thread* u_0, float sign_2)
{
    float2 a_1 = (*u_0)[int(0)];
    (*u_0)[int(0)] = (*u_0)[int(0)] + (*u_0)[int(1)];
    (*u_0)[int(1)] = a_1 - (*u_0)[int(1)];
    return;
}

[[kernel]] void fft_pass(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]], packed_float2 device* entryPointParams_x_1 [[buffer(1)]], packed_float2 device* entryPointParams_y_1 [[buffer(2)]], packed_float2 device* entryPointParams_tw_1 [[buffer(3)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    (&kernelContext_0)->entryPointParams_x_0 = entryPointParams_x_1;
    (&kernelContext_0)->entryPointParams_y_0 = entryPointParams_y_1;
    (&kernelContext_0)->entryPointParams_tw_0 = entryPointParams_tw_1;
    uint g_0 = zimt_index_0(tid_1);
    if(g_0 >= (entryPointParams_1->total_0))
    {
        return;
    }
    uint q_0 = (1U << ((&kernelContext_0)->entryPointParams_0->log2_n_1)) >> 1U;
    uint base_0 = (g_0 >> ((&kernelContext_0)->entryPointParams_0->log2_n_1 - 1U)) << ((&kernelContext_0)->entryPointParams_0->log2_n_1);
    uint i_0 = g_0 & (q_0 - 1U);
    uint k_0 = i_0 & ((&kernelContext_0)->entryPointParams_0->p_0 - 1U);
    uint _S6 = q_0 / (&kernelContext_0)->entryPointParams_0->p_0;
    thread array<float2, int(2)> u_1;
    uint _S7 = base_0 + i_0;
    u_1[int(0)] = float2(*((&kernelContext_0)->entryPointParams_x_0+_S7)) ;
    uint m_0 = 1U;
    for(;;)
    {
        if(m_0 < 2U)
        {
        }
        else
        {
            break;
        }
        u_1[m_0] = cmul_0(float2(*((&kernelContext_0)->entryPointParams_x_0+(_S7 + m_0 * q_0))) , twiddle_0((&kernelContext_0)->entryPointParams_tw_0, m_0 * k_0 * _S6, (&kernelContext_0)->entryPointParams_0->log2_n_1, (&kernelContext_0)->entryPointParams_0->sign_1));
        m_0 = m_0 + 1U;
    }
    Radix2_dft_0(&u_1, (&kernelContext_0)->entryPointParams_0->sign_1);
    uint _S8 = base_0 + ((i_0 - k_0) << 1U) + k_0;
    uint r_0 = 0U;
    for(;;)
    {
        if(r_0 < 2U)
        {
        }
        else
        {
            break;
        }
        *((&kernelContext_0)->entryPointParams_y_0+(_S8 + r_0 * (&kernelContext_0)->entryPointParams_0->p_0)) = packed_float2(u_1[r_0]) ;
        r_0 = r_0 + 1U;
    }
    return;
}

