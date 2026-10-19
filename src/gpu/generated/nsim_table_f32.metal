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

struct PatchSearch_0
{
    uint ref_off_0;
    uint ref_frames_0;
    uint ref_frame_0;
    uint deg_off_0;
    uint deg_frames_0;
    uint lo_0;
    uint hi_0;
    uint row_0;
    uint plane_0;
    uint width_0;
};

struct RO_1
{
    PatchSearch_0 device* p_0;
};

PatchSearch_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

struct SimTask_0
{
    uint patch_0;
    uint first_0;
};

struct RO_2
{
    SimTask_0 device* p_0;
};

SimTask_0 RO_operatorx5Bx5D_get_2(const RO_2 constant* this_2, uint i_2)
{
    return *(this_2->p_0 + i_2);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

struct Terms_0
{
    float c_0;
    float m_0;
    float v_0;
};

Terms_0 Terms_x24init_0(float c_1, float m_1, float v_1)
{
    thread Terms_0 _S1;
    (&_S1)->c_0 = c_1;
    (&_S1)->m_0 = m_1;
    (&_S1)->v_0 = v_1;
    return _S1;
}

Terms_0 windowTerms_0(const array<float, int(9)> thread* x_0, float centre_0, const RO_0 constant* window_0)
{
    uint k_0 = 0U;
    float m_2 = 0.0f;
    float q_0 = 0.0f;
    for(;;)
    {
        if(k_0 < 9U)
        {
        }
        else
        {
            break;
        }
        float e_0 = (*x_0)[k_0] - centre_0;
        float _S2 = RO_operatorx5Bx5D_get_0(window_0, k_0);
        float m_3 = m_2 + _S2 * e_0;
        float _S3 = RO_operatorx5Bx5D_get_0(window_0, k_0);
        float q_1 = q_0 + _S3 * (e_0 * e_0);
        k_0 = k_0 + 1U;
        m_2 = m_3;
        q_0 = q_1;
    }
    return Terms_x24init_0(centre_0, m_2, q_0 - m_2 * m_2);
}

float cellSim_0(const Terms_0 thread* r_0, const Terms_0 thread* d_0, float cross_0, float c1_0, float c3_0)
{
    float mr_0 = r_0->c_0 + r_0->m_0;
    float md_0 = d_0->c_0 + d_0->m_0;
    float srd_0 = cross_0 - r_0->m_0 * d_0->m_0;
    float intensity_0 = (2.0f * (mr_0 * md_0) + c1_0) / (mr_0 * mr_0 + md_0 * md_0 + c1_0);
    float prod_0 = r_0->v_0 * d_0->v_0;
    float denom_0;
    if(prod_0 < 0.0f)
    {
        denom_0 = c3_0;
    }
    else
    {
        denom_0 = sqrt(prod_0) + c3_0;
    }
    return intensity_0 * ((srd_0 + c3_0) / denom_0);
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_0 ref_spec_0;
    RO_0 deg_spec_0;
    RO_0 window_1;
    RO_1 patches_0;
    RO_2 tasks_0;
    RO_0 ref_terms_0;
    RO_0 deg_terms_0;
    RW_0 sims_0;
    uint num_tasks_0;
    uint num_bands_0;
    uint patch_size_0;
    float c1_1;
    float c3_1;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    array<float, int(1024)> threadgroup* ref_tile_0;
    array<float, int(3040)> threadgroup* deg_tile_0;
};

[[kernel]] void nsim_table(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    float sum_0;
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    threadgroup array<float, int(1024)> ref_tile_1;
    (&kernelContext_0)->ref_tile_0 = &ref_tile_1;
    threadgroup array<float, int(3040)> deg_tile_1;
    (&kernelContext_0)->deg_tile_0 = &deg_tile_1;
    RW_0 _S4 = entryPointParams_1->sims_0;
    uint task_0 = zimt_index_0(tid_1) / 64U;
    uint lane_0 = tid_1.x % 64U;
    if(task_0 >= (entryPointParams_1->num_tasks_0))
    {
        return;
    }
    SimTask_0 _S5 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->tasks_0, task_0);
    PatchSearch_0 _S6 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->patches_0, _S5.patch_0);
    uint _S7 = 64U + (&kernelContext_0)->entryPointParams_0->patch_size_0 - 1U;
    uint i_3 = lane_0;
    for(;;)
    {
        if(i_3 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * (&kernelContext_0)->entryPointParams_0->patch_size_0))
        {
        }
        else
        {
            break;
        }
        uint b_0 = i_3 / (&kernelContext_0)->entryPointParams_0->patch_size_0;
        uint _S8 = _S6.ref_off_0 + b_0 * _S6.ref_frames_0 + _S6.ref_frame_0;
        uint _S9 = i_3 % (&kernelContext_0)->entryPointParams_0->patch_size_0;
        float _S10 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->ref_spec_0, _S8 + _S9);
        (*(&kernelContext_0)->ref_tile_0)[i_3] = _S10;
        i_3 = i_3 + 64U;
    }
    i_3 = lane_0;
    for(;;)
    {
        if(i_3 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S7))
        {
        }
        else
        {
            break;
        }
        uint b_1 = i_3 / _S7;
        uint _S11 = i_3 % _S7;
        uint col_0 = _S5.first_0 + _S11;
        if(col_0 < (_S6.deg_frames_0))
        {
            float _S12 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->deg_spec_0, _S6.deg_off_0 + b_1 * _S6.deg_frames_0 + col_0);
            sum_0 = _S12;
        }
        else
        {
            sum_0 = 0.0f;
        }
        (*(&kernelContext_0)->deg_tile_0)[b_1 * 95U + _S11] = sum_0;
        i_3 = i_3 + 64U;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint off_0 = _S5.first_0 + lane_0;
    if(off_0 > (_S6.hi_0))
    {
        return;
    }
    int nb_0 = int((&kernelContext_0)->entryPointParams_0->num_bands_0);
    int ps_0 = int((&kernelContext_0)->entryPointParams_0->patch_size_0);
    uint _S13 = _S5.patch_0 * (&kernelContext_0)->entryPointParams_0->num_bands_0 * (&kernelContext_0)->entryPointParams_0->patch_size_0;
    int r_1 = int(0);
    sum_0 = 0.0f;
    for(;;)
    {
        if(r_1 < nb_0)
        {
        }
        else
        {
            break;
        }
        int c_2 = int(0);
        for(;;)
        {
            if(c_2 < ps_0)
            {
            }
            else
            {
                break;
            }
            uint _S14 = uint(r_1 * ps_0 + c_2);
            uint ri_0 = (_S13 + _S14) * 2U;
            float _S15 = (*(&kernelContext_0)->ref_tile_0)[_S14];
            float _S16 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->ref_terms_0, ri_0);
            float _S17 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->ref_terms_0, ri_0 + 1U);
            Terms_0 rs_0 = Terms_x24init_0(_S15, _S16, _S17);
            uint _S18 = uint(r_1);
            uint _S19 = uint(c_2);
            float dc0_0 = (*(&kernelContext_0)->deg_tile_0)[_S18 * 95U + lane_0 + _S19];
            thread array<float, int(9)> d_1;
            int dr_0 = int(-1);
            float cross_1 = 0.0f;
            for(;;)
            {
                if(dr_0 <= int(1))
                {
                }
                else
                {
                    break;
                }
                uint _S20 = uint(clamp(r_1 + dr_0, int(0), nb_0 - int(1)));
                int dc_0 = int(-1);
                for(;;)
                {
                    if(dc_0 <= int(1))
                    {
                    }
                    else
                    {
                        break;
                    }
                    uint cc_0 = uint(clamp(c_2 + dc_0, int(0), ps_0 - int(1)));
                    uint k_1 = uint((dr_0 + int(1)) * int(3) + dc_0 + int(1));
                    float rv_0 = (*(&kernelContext_0)->ref_tile_0)[_S20 * (&kernelContext_0)->entryPointParams_0->patch_size_0 + cc_0];
                    float _S21 = (*(&kernelContext_0)->deg_tile_0)[_S20 * 95U + lane_0 + cc_0];
                    d_1[k_1] = (*(&kernelContext_0)->deg_tile_0)[_S20 * 95U + lane_0 + cc_0];
                    float _S22 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->window_1, k_1);
                    float cross_2 = cross_1 + _S22 * ((rv_0 - rs_0.c_0) * (_S21 - dc0_0));
                    dc_0 = dc_0 + int(1);
                    cross_1 = cross_2;
                }
                dr_0 = dr_0 + int(1);
            }
            thread Terms_0 ds_0;
            bool _S23;
            if(c_2 == int(0))
            {
                _S23 = true;
            }
            else
            {
                _S23 = c_2 == (ps_0 - int(1));
            }
            if(_S23)
            {
                thread array<float, int(9)> _S24 = d_1;
                Terms_0 _S25 = windowTerms_0(&_S24, dc0_0, &(&kernelContext_0)->entryPointParams_0->window_1);
                ds_0 = _S25;
            }
            else
            {
                uint di_0 = _S6.plane_0 + (_S18 * _S6.width_0 + off_0 + _S19) * 2U;
                (&ds_0)->c_0 = dc0_0;
                float _S26 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->deg_terms_0, di_0);
                (&ds_0)->m_0 = _S26;
                float _S27 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->deg_terms_0, di_0 + 1U);
                (&ds_0)->v_0 = _S27;
            }
            float _S28 = (&kernelContext_0)->entryPointParams_0->c1_1;
            float _S29 = (&kernelContext_0)->entryPointParams_0->c3_1;
            thread Terms_0 _S30 = rs_0;
            thread Terms_0 _S31 = ds_0;
            float _S32 = cellSim_0(&_S30, &_S31, cross_1, _S28, _S29);
            float sum_1 = sum_0 + _S32;
            c_2 = c_2 + int(1);
            sum_0 = sum_1;
        }
        r_1 = r_1 + int(1);
    }
    *(_S4.p_1 + (_S6.row_0 + off_0)) = sum_0 / float(nb_0 * ps_0);
    return;
}

