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

float RO_operatorx5Bx5D_get_1(const RO_0 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

struct RefPatch_0
{
    uint ref_off_0;
    uint ref_frames_0;
    uint ref_frame_0;
};

struct SimRow_0
{
    uint task_0;
    uint count_0;
    uint lo_0;
    RefPatch_0 ref_0;
    uint deg_off_0;
    uint deg_frames_0;
};

struct RO_1
{
    SimRow_0 device* p_0;
};

SimRow_0 RO_operatorx5Bx5D_get_2(const RO_1 constant* this_2, uint i_2)
{
    return *(this_2->p_0 + i_2);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

float wgt_0(int dr_0, int dc_0)
{
    bool _S1 = dr_0 == int(0);
    bool _S2;
    if(_S1)
    {
        _S2 = dc_0 == int(0);
    }
    else
    {
        _S2 = false;
    }
    if(_S2)
    {
        return 0.61948585510253906f;
    }
    if(_S1)
    {
        _S2 = true;
    }
    else
    {
        _S2 = dc_0 == int(0);
    }
    if(_S2)
    {
        return 0.08382514864206314f;
    }
    return 0.01130339130759239f;
}

float degAt_0(const RO_0 constant* deg_0, uint base_0, uint nf_0, int band_0, int col_0)
{
    uint _S3 = uint(col_0);
    float _S4;
    if(_S3 < nf_0)
    {
        float _S5 = RO_operatorx5Bx5D_get_1(deg_0, base_0 + uint(band_0) * nf_0 + _S3);
        _S4 = _S5;
    }
    else
    {
        _S4 = 0.0f;
    }
    return _S4;
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_0 ref_spec_0;
    RO_0 deg_spec_0;
    RO_1 rows_0;
    RO_0 mu_ref_0;
    RO_0 srs_ref_0;
    RW_0 out_0;
    uint num_rows_0;
    uint num_tasks_0;
    uint num_bands_0;
    uint patch_size_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void patch_sims(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S6 = entryPointParams_1->out_0;
    uint t_0 = zimt_index_0(tid_1);
    if(t_0 >= (entryPointParams_1->num_tasks_0))
    {
        return;
    }
    uint _S7 = (&kernelContext_0)->entryPointParams_0->num_rows_0 - 1U;
    uint lo_r_0 = 0U;
    uint hi_r_0 = _S7;
    for(;;)
    {
        if(lo_r_0 < hi_r_0)
        {
        }
        else
        {
            break;
        }
        uint mid_0 = (lo_r_0 + hi_r_0 + 1U) / 2U;
        SimRow_0 _S8 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->rows_0, mid_0);
        if((_S8.task_0) <= t_0)
        {
            lo_r_0 = mid_0;
        }
        else
        {
            hi_r_0 = mid_0 - 1U;
        }
    }
    SimRow_0 _S9 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->rows_0, lo_r_0);
    uint _S10 = _S9.lo_0 + t_0 - _S9.task_0;
    int _S11 = int((&kernelContext_0)->entryPointParams_0->num_bands_0);
    int _S12 = int((&kernelContext_0)->entryPointParams_0->patch_size_0);
    uint cells_0 = (&kernelContext_0)->entryPointParams_0->num_bands_0 * (&kernelContext_0)->entryPointParams_0->patch_size_0;
    int r_0 = int(0);
    float total_0 = 0.0f;
    for(;;)
    {
        if(r_0 < _S11)
        {
        }
        else
        {
            break;
        }
        int c_0 = int(0);
        float band_sum_0 = 0.0f;
        for(;;)
        {
            if(c_0 < _S12)
            {
            }
            else
            {
                break;
            }
            int dr_1 = int(-1);
            float md_0 = 0.0f;
            float dsq_0 = 0.0f;
            float rd_0 = 0.0f;
            for(;;)
            {
                if(dr_1 <= int(1))
                {
                }
                else
                {
                    break;
                }
                int _S13 = clamp(r_0 + dr_1, int(0), _S11 - int(1));
                int dc_1 = int(-1);
                for(;;)
                {
                    if(dc_1 <= int(1))
                    {
                    }
                    else
                    {
                        break;
                    }
                    int cc_0 = clamp(c_0 + dc_1, int(0), _S12 - int(1));
                    float w_0 = wgt_0(dr_1, dc_1);
                    float _S14 = degAt_0(&(&kernelContext_0)->entryPointParams_0->deg_spec_0, _S9.deg_off_0, _S9.deg_frames_0, _S13, int(_S10) + cc_0);
                    float _S15 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->ref_spec_0, _S9.ref_0.ref_off_0 + uint(_S13) * _S9.ref_0.ref_frames_0 + _S9.ref_0.ref_frame_0 + uint(cc_0));
                    float md_1 = md_0 + w_0 * _S14;
                    float dsq_1 = dsq_0 + w_0 * (_S14 * _S14);
                    float rd_1 = rd_0 + w_0 * (_S15 * _S14);
                    dc_1 = dc_1 + int(1);
                    md_0 = md_1;
                    dsq_0 = dsq_1;
                    rd_0 = rd_1;
                }
                dr_1 = dr_1 + int(1);
            }
            uint ci_0 = lo_r_0 * cells_0 + uint(r_0) * (&kernelContext_0)->entryPointParams_0->patch_size_0 + uint(c_0);
            float _S16 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->mu_ref_0, ci_0);
            float _S17 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->srs_ref_0, ci_0);
            float dms_0 = md_0 * md_0;
            float mrd_0 = _S16 * md_0;
            float srd_0 = rd_0 - mrd_0;
            float intensity_0 = (2.0f * mrd_0 + 0.00009999999747379f) / (_S16 * _S16 + dms_0 + 0.00009999999747379f);
            float prod_0 = _S17 * (dsq_0 - dms_0);
            float denom_0;
            if(prod_0 < 0.0f)
            {
                denom_0 = 0.00044999999227002f;
            }
            else
            {
                denom_0 = sqrt(prod_0) + 0.00044999999227002f;
            }
            float band_sum_1 = band_sum_0 + intensity_0 * ((srd_0 + 0.00044999999227002f) / denom_0);
            c_0 = c_0 + int(1);
            band_sum_0 = band_sum_1;
        }
        float total_1 = total_0 + band_sum_0;
        r_0 = r_0 + int(1);
        total_0 = total_1;
    }
    *(_S6.p_1 + t_0) = total_0 / float(cells_0);
    return;
}

