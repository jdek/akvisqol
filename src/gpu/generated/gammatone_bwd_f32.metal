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

struct FrameGrad_0
{
    int start_0;
    uint lo_0;
    uint hi_0;
    uint grad_0;
    uint stride_0;
    uint out_0;
};

struct RO_1
{
    FrameGrad_0 device* p_0;
};

FrameGrad_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 1048576U;
}

struct Cascade_0
{
    array<float, int(8)> s_0;
};

Cascade_0 Cascade_x24init_0()
{
    thread Cascade_0 _S1;
    uint k_0 = 0U;
    for(;;)
    {
        if(k_0 < 8U)
        {
        }
        else
        {
            break;
        }
        (&_S1)->s_0[k_0] = 0.0f;
        k_0 = k_0 + 1U;
    }
    return _S1;
}

float sampleAt_0(const RO_0 constant* signals_0, const FrameGrad_0 thread* fr_0, uint i_2)
{
    int t_0 = fr_0->start_0 + int(i_2);
    bool _S2;
    if(t_0 >= int(fr_0->lo_0))
    {
        _S2 = t_0 < int(fr_0->hi_0);
    }
    else
    {
        _S2 = false;
    }
    float _S3;
    if(_S2)
    {
        float _S4 = RO_operatorx5Bx5D_get_0(signals_0, uint(t_0));
        _S3 = _S4;
    }
    else
    {
        _S3 = 0.0f;
    }
    return _S3;
}

float Cascade_step_0(Cascade_0 thread* this_2, float x_0, const array<float, int(8)> thread* c_0)
{
    float f1_0 = (*c_0)[int(0)] * x_0 + this_2->s_0[int(0)];
    float _S5 = (*c_0)[int(6)];
    this_2->s_0[int(0)] = (*c_0)[int(1)] * x_0 + this_2->s_0[int(1)] - (*c_0)[int(6)] * f1_0;
    float _S6 = (*c_0)[int(7)];
    this_2->s_0[int(1)] = - ((*c_0)[int(7)] * f1_0);
    float _S7 = (*c_0)[int(5)];
    float f2_0 = (*c_0)[int(5)] * f1_0 + this_2->s_0[int(2)];
    this_2->s_0[int(2)] = (*c_0)[int(2)] * f1_0 + this_2->s_0[int(3)] - _S5 * f2_0;
    this_2->s_0[int(3)] = - (_S6 * f2_0);
    float f3_0 = _S7 * f2_0 + this_2->s_0[int(4)];
    this_2->s_0[int(4)] = (*c_0)[int(3)] * f2_0 + this_2->s_0[int(5)] - _S5 * f3_0;
    this_2->s_0[int(5)] = - (_S6 * f3_0);
    float f4_0 = _S7 * f3_0 + this_2->s_0[int(6)];
    this_2->s_0[int(6)] = (*c_0)[int(4)] * f3_0 + this_2->s_0[int(7)] - _S5 * f4_0;
    this_2->s_0[int(7)] = - (_S6 * f4_0);
    return f4_0;
}

struct Adjoint_0
{
    array<float, int(4)> r1_0;
    array<float, int(4)> r2_0;
};

Adjoint_0 Adjoint_x24init_0()
{
    thread Adjoint_0 _S8;
    uint k_1 = 0U;
    for(;;)
    {
        if(k_1 < 4U)
        {
        }
        else
        {
            break;
        }
        (&_S8)->r1_0[k_1] = 0.0f;
        (&_S8)->r2_0[k_1] = 0.0f;
        k_1 = k_1 + 1U;
    }
    return _S8;
}

float Adjoint_step_0(Adjoint_0 thread* this_3, float g_0, const array<float, int(8)> thread* c_1)
{
    float _S9 = g_0;
    int k_2 = int(3);
    for(;;)
    {
        if(k_2 >= int(0))
        {
        }
        else
        {
            break;
        }
        float b0_0;
        if(k_2 == int(0))
        {
            b0_0 = (*c_1)[int(0)];
        }
        else
        {
            b0_0 = (*c_1)[int(5)];
        }
        float v_0 = _S9 - (*c_1)[int(6)] * this_3->r1_0[k_2] - (*c_1)[int(7)] * this_3->r2_0[k_2];
        float _S10 = b0_0 * v_0 + (*c_1)[int(1) + k_2] * this_3->r1_0[k_2];
        this_3->r2_0[k_2] = this_3->r1_0[k_2];
        this_3->r1_0[k_2] = v_0;
        int _S11 = k_2 - int(1);
        _S9 = _S10;
        k_2 = _S11;
    }
    return _S9;
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_0 signals_1;
    RO_1 frames_0;
    RO_0 coeffs_0;
    RO_0 hann_0;
    RO_0 grad_1;
    RW_0 grads_0;
    uint num_frames_0;
    uint num_bands_0;
    uint window_size_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    array<array<float, int(64)>, int(32)> threadgroup* part_0;
};

[[kernel]] void gammatone_bwd(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    float g_1;
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    threadgroup array<array<float, int(64)>, int(32)> part_1;
    (&kernelContext_0)->part_0 = &part_1;
    RW_0 _S12 = entryPointParams_1->grads_0;
    uint frame_0 = zimt_index_0(tid_1) / 32U;
    uint band_0 = tid_1.x % 32U;
    if(frame_0 >= (entryPointParams_1->num_frames_0))
    {
        return;
    }
    FrameGrad_0 _S13 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->frames_0, frame_0);
    thread array<float, int(8)> c_2;
    uint k_3 = 0U;
    for(;;)
    {
        if(k_3 < 8U)
        {
        }
        else
        {
            break;
        }
        if(band_0 < ((&kernelContext_0)->entryPointParams_0->num_bands_0))
        {
            float _S14 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->coeffs_0, band_0 * 8U + k_3);
            g_1 = _S14;
        }
        else
        {
            g_1 = 0.0f;
        }
        c_2[k_3] = g_1;
        k_3 = k_3 + 1U;
    }
    if(band_0 < ((&kernelContext_0)->entryPointParams_0->num_bands_0))
    {
        float _S15 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->grad_1, _S13.grad_0 + band_0 * _S13.stride_0);
        g_1 = _S15;
    }
    else
    {
        g_1 = 0.0f;
    }
    uint blocks_0 = ((&kernelContext_0)->entryPointParams_0->window_size_0 + 64U - 1U) / 64U;
    thread array<float, int(512)> saved_0;
    uint i_3;
    float sum_0;
    float scale_0;
    if(g_1 != 0.0f)
    {
        thread Cascade_0 f_0 = Cascade_x24init_0();
        i_3 = 0U;
        sum_0 = 0.0f;
        for(;;)
        {
            if(i_3 < ((&kernelContext_0)->entryPointParams_0->window_size_0))
            {
            }
            else
            {
                break;
            }
            if((i_3 % 64U) == 0U)
            {
                k_3 = 0U;
                for(;;)
                {
                    if(k_3 < 8U)
                    {
                    }
                    else
                    {
                        break;
                    }
                    saved_0[i_3 / 64U * 8U + k_3] = (&f_0)->s_0[k_3];
                    k_3 = k_3 + 1U;
                }
            }
            thread FrameGrad_0 _S16 = _S13;
            float _S17 = sampleAt_0(&(&kernelContext_0)->entryPointParams_0->signals_1, &_S16, i_3);
            float _S18 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->hann_0, i_3);
            float _S19 = _S17 * _S18;
            thread array<float, int(8)> _S20 = c_2;
            float _S21 = Cascade_step_0(&f_0, _S19, &_S20);
            float sum_sq_0 = sum_0 + _S21 * _S21;
            i_3 = i_3 + 1U;
            sum_0 = sum_sq_0;
        }
        float rms_0 = sqrt(sum_0 / float((&kernelContext_0)->entryPointParams_0->window_size_0));
        if(rms_0 > 0.0f)
        {
            scale_0 = g_1 / (rms_0 * float((&kernelContext_0)->entryPointParams_0->window_size_0));
        }
        else
        {
            scale_0 = 0.0f;
        }
    }
    else
    {
        scale_0 = 0.0f;
    }
    thread Adjoint_0 adj_0 = Adjoint_x24init_0();
    thread array<float, int(64)> y_0;
    int blk_0 = int(blocks_0) - int(1);
    for(;;)
    {
        if(blk_0 >= int(0))
        {
        }
        else
        {
            break;
        }
        uint _S22 = uint(blk_0);
        uint first_0 = _S22 * 64U;
        uint _S23 = min(64U, (&kernelContext_0)->entryPointParams_0->window_size_0 - first_0);
        if(scale_0 != 0.0f)
        {
            thread Cascade_0 f_1 = Cascade_x24init_0();
            k_3 = 0U;
            for(;;)
            {
                if(k_3 < 8U)
                {
                }
                else
                {
                    break;
                }
                (&f_1)->s_0[k_3] = saved_0[_S22 * 8U + k_3];
                k_3 = k_3 + 1U;
            }
            i_3 = 0U;
            for(;;)
            {
                if(i_3 < _S23)
                {
                }
                else
                {
                    break;
                }
                uint _S24 = first_0 + i_3;
                thread FrameGrad_0 _S25 = _S13;
                float _S26 = sampleAt_0(&(&kernelContext_0)->entryPointParams_0->signals_1, &_S25, _S24);
                float _S27 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->hann_0, _S24);
                float _S28 = _S26 * _S27;
                thread array<float, int(8)> _S29 = c_2;
                float _S30 = Cascade_step_0(&f_1, _S28, &_S29);
                y_0[i_3] = _S30;
                i_3 = i_3 + 1U;
            }
            int i_4 = int(_S23) - int(1);
            for(;;)
            {
                if(i_4 >= int(0))
                {
                }
                else
                {
                    break;
                }
                uint at_0 = first_0 + uint(i_4);
                int t_1 = _S13.start_0 + int(at_0);
                float _S31 = scale_0 * y_0[i_4];
                thread array<float, int(8)> _S32 = c_2;
                float _S33 = Adjoint_step_0(&adj_0, _S31, &_S32);
                float _S34 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->hann_0, at_0);
                float gs_0 = _S33 * _S34;
                bool _S35;
                if(t_1 >= int(_S13.lo_0))
                {
                    _S35 = t_1 < int(_S13.hi_0);
                }
                else
                {
                    _S35 = false;
                }
                if(_S35)
                {
                    g_1 = gs_0;
                }
                else
                {
                    g_1 = 0.0f;
                }
                (*(&kernelContext_0)->part_0)[band_0][i_4] = g_1;
                i_4 = i_4 - int(1);
            }
        }
        else
        {
            i_3 = 0U;
            for(;;)
            {
                if(i_3 < _S23)
                {
                }
                else
                {
                    break;
                }
                (*(&kernelContext_0)->part_0)[band_0][i_3] = 0.0f;
                i_3 = i_3 + 1U;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        i_3 = band_0;
        for(;;)
        {
            if(i_3 < _S23)
            {
            }
            else
            {
                break;
            }
            uint b_0 = 0U;
            sum_0 = 0.0f;
            for(;;)
            {
                if(b_0 < ((&kernelContext_0)->entryPointParams_0->num_bands_0))
                {
                }
                else
                {
                    break;
                }
                float sum_1 = sum_0 + (*(&kernelContext_0)->part_0)[b_0][i_3];
                b_0 = b_0 + 1U;
                sum_0 = sum_1;
            }
            *(_S12.p_1 + (_S13.out_0 + first_0 + i_3)) = sum_0;
            i_3 = i_3 + 32U;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        blk_0 = blk_0 - int(1);
    }
    return;
}

