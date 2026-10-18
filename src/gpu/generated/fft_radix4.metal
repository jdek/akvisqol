#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct RO_0
{
    packed_float2 device* p_0;
};

float2 RO_operatorx5Bx5D_get_0(const RO_0 constant* this_0, uint i_0)
{
    return float2(*(this_0->p_0 + i_0)) ;
}

float2 RO_operatorx5Bx5D_get_1(const RO_0 constant* this_1, uint i_1)
{
    return float2(*(this_1->p_0 + i_1)) ;
}

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

float2 twiddle_0(const RO_0 constant* tw_0, uint t_0, uint log2_n_0, float sign_0)
{
    uint s_0 = (log2_n_0 + 1U) >> 1U;
    uint _S5 = 1U << s_0;
    float2 _S6 = RO_operatorx5Bx5D_get_1(tw_0, _S5 + (t_0 >> s_0));
    float2 _S7 = RO_operatorx5Bx5D_get_1(tw_0, t_0 & (_S5 - 1U));
    float2 w_0 = cmul_0(_S6, _S7);
    return float2(w_0.x, sign_0 * w_0.y);
}

struct RW_0
{
    packed_float2 device* p_1;
};

struct EntryPointParams_0
{
    RO_0 x_0;
    RW_0 y_0;
    RO_0 tw_1;
    uint log2_n_1;
    uint p_2;
    uint total_0;
    float sign_1;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

float2 mul_si_0(float2 a_1, float sign_2)
{
    return float2(- sign_2 * a_1.y, sign_2 * a_1.x);
}

void dft4_0(float2 thread* a0_0, float2 thread* a1_0, float2 thread* a2_0, float2 thread* a3_0, float sign_3)
{
    float2 v0_0 = *a0_0 + *a2_0;
    float2 v1_0 = *a0_0 - *a2_0;
    float2 v2_0 = *a1_0 + *a3_0;
    float2 v3_0 = mul_si_0(*a1_0 - *a3_0, sign_3);
    *a0_0 = v0_0 + v2_0;
    *a1_0 = v1_0 + v3_0;
    *a2_0 = v0_0 - v2_0;
    *a3_0 = v1_0 - v3_0;
    return;
}

void Radix4_dft_0(array<float2, int(4)> thread* u_0, float sign_4)
{
    dft4_0(&(*u_0)[int(0)], &(*u_0)[int(1)], &(*u_0)[int(2)], &(*u_0)[int(3)], sign_4);
    return;
}

[[kernel]] void fft_pass(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S8 = entryPointParams_1->y_0;
    uint g_0 = zimt_index_0(tid_1);
    if(g_0 >= (entryPointParams_1->total_0))
    {
        return;
    }
    uint q_0 = (1U << ((&kernelContext_0)->entryPointParams_0->log2_n_1)) >> 2U;
    uint base_0 = (g_0 >> ((&kernelContext_0)->entryPointParams_0->log2_n_1 - 2U)) << ((&kernelContext_0)->entryPointParams_0->log2_n_1);
    uint i_2 = g_0 & (q_0 - 1U);
    uint k_0 = i_2 & ((&kernelContext_0)->entryPointParams_0->p_2 - 1U);
    uint _S9 = q_0 / (&kernelContext_0)->entryPointParams_0->p_2;
    thread array<float2, int(4)> u_1;
    uint _S10 = base_0 + i_2;
    float2 _S11 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->x_0, _S10);
    u_1[int(0)] = _S11;
    uint m_0 = 1U;
    for(;;)
    {
        if(m_0 < 4U)
        {
        }
        else
        {
            break;
        }
        float2 _S12 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->x_0, _S10 + m_0 * q_0);
        float2 _S13 = twiddle_0(&(&kernelContext_0)->entryPointParams_0->tw_1, m_0 * k_0 * _S9, (&kernelContext_0)->entryPointParams_0->log2_n_1, (&kernelContext_0)->entryPointParams_0->sign_1);
        u_1[m_0] = cmul_0(_S12, _S13);
        m_0 = m_0 + 1U;
    }
    Radix4_dft_0(&u_1, (&kernelContext_0)->entryPointParams_0->sign_1);
    uint _S14 = base_0 + ((i_2 - k_0) << 2U) + k_0;
    uint r_0 = 0U;
    for(;;)
    {
        if(r_0 < 4U)
        {
        }
        else
        {
            break;
        }
        *(_S8.p_1 + (_S14 + r_0 * (&kernelContext_0)->entryPointParams_0->p_2)) = packed_float2(u_1[r_0]) ;
        r_0 = r_0 + 1U;
    }
    return;
}

