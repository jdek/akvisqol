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

struct PatchPair_0
{
    uint ref_off_0;
    uint ref_frames_0;
    uint ref_frame_0;
    uint deg_off_0;
    uint deg_frames_0;
    uint deg_frame_0;
    uint cols_0;
};

struct RO_1
{
    PatchPair_0 device* p_0;
};

PatchPair_0 RO_operatorx5Bx5D_get_2(const RO_1 constant* this_2, uint i_2)
{
    return *(this_2->p_0 + i_2);
}

struct RO_2
{
    uint device* p_0;
};

uint RO_operatorx5Bx5D_get_3(const RO_2 constant* this_3, uint i_3)
{
    return *(this_3->p_0 + i_3);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

float degAt_0(const RO_0 constant* spec_0, uint o_0, uint nf_0, uint col0_0, uint b_0, uint c_0)
{
    float _S1;
    if((col0_0 + c_0) < nf_0)
    {
        float _S2 = RO_operatorx5Bx5D_get_1(spec_0, o_0 + b_0 * nf_0 + col0_0 + c_0);
        _S1 = _S2;
    }
    else
    {
        _S1 = 0.0f;
    }
    return _S1;
}

float refAt_0(const RO_0 constant* spec_1, uint o_1, uint nf_1, uint col0_1, uint b_1, uint c_1)
{
    float _S3 = RO_operatorx5Bx5D_get_1(spec_1, o_1 + b_1 * nf_1 + col0_1 + c_1);
    return _S3;
}

struct Cell_0
{
    float cr_0;
    float cd_0;
    float sr_0;
    float sd_0;
    float qr_0;
    float qd_0;
    float qrd_0;
};

Cell_0 Cell_x24init_0(float r0_0, float d0_0)
{
    thread Cell_0 _S4;
    (&_S4)->cr_0 = r0_0;
    (&_S4)->cd_0 = d0_0;
    (&_S4)->sr_0 = 0.0f;
    (&_S4)->sd_0 = 0.0f;
    (&_S4)->qr_0 = 0.0f;
    (&_S4)->qd_0 = 0.0f;
    (&_S4)->qrd_0 = 0.0f;
    return _S4;
}

void Cell_add_0(Cell_0 thread* this_4, float w_0, float rv_0, float dv_0)
{
    float er_0 = rv_0 - this_4->cr_0;
    float ed_0 = dv_0 - this_4->cd_0;
    this_4->sr_0 = this_4->sr_0 + w_0 * er_0;
    this_4->sd_0 = this_4->sd_0 + w_0 * ed_0;
    this_4->qr_0 = this_4->qr_0 + w_0 * (er_0 * er_0);
    this_4->qd_0 = this_4->qd_0 + w_0 * (ed_0 * ed_0);
    this_4->qrd_0 = this_4->qrd_0 + w_0 * (er_0 * ed_0);
    return;
}

float Cell_sim_0(const Cell_0 thread* this_5, float c1_0, float c3_0)
{
    float mr_0 = this_5->cr_0 + this_5->sr_0;
    float md_0 = this_5->cd_0 + this_5->sd_0;
    float srd_0 = this_5->qrd_0 - this_5->sr_0 * this_5->sd_0;
    float intensity_0 = (2.0f * (mr_0 * md_0) + c1_0) / (mr_0 * mr_0 + md_0 * md_0 + c1_0);
    float prod_0 = (this_5->qr_0 - this_5->sr_0 * this_5->sr_0) * (this_5->qd_0 - this_5->sd_0 * this_5->sd_0);
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

float bandSim_0(const RO_0 constant* ref_spec_0, const RO_0 constant* deg_spec_0, const RO_0 constant* window_0, const PatchPair_0 thread* pp_0, uint b_2, uint c_2, uint nb_0, float c1_1, float c3_1)
{
    uint _S5 = pp_0->cols_0;
    uint _S6 = pp_0->ref_off_0;
    uint _S7 = pp_0->ref_frames_0;
    uint _S8 = pp_0->ref_frame_0;
    float _S9 = refAt_0(ref_spec_0, pp_0->ref_off_0, pp_0->ref_frames_0, pp_0->ref_frame_0, b_2, c_2);
    uint _S10 = pp_0->deg_off_0;
    uint _S11 = pp_0->deg_frames_0;
    uint _S12 = pp_0->deg_frame_0;
    float _S13 = degAt_0(deg_spec_0, pp_0->deg_off_0, pp_0->deg_frames_0, pp_0->deg_frame_0, b_2, c_2);
    thread Cell_0 cell_0 = Cell_x24init_0(_S9, _S13);
    int dr_0 = int(-1);
    for(;;)
    {
        if(dr_0 <= int(1))
        {
        }
        else
        {
            break;
        }
        uint _S14 = uint(clamp(int(b_2) + dr_0, int(0), int(nb_0) - int(1)));
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
            uint cc_0 = uint(clamp(int(c_2) + dc_0, int(0), int(_S5) - int(1)));
            float _S15 = RO_operatorx5Bx5D_get_0(window_0, uint((dr_0 + int(1)) * int(3) + dc_0 + int(1)));
            float _S16 = refAt_0(ref_spec_0, _S6, _S7, _S8, _S14, cc_0);
            float _S17 = degAt_0(deg_spec_0, _S10, _S11, _S12, _S14, cc_0);
            Cell_add_0(&cell_0, _S15, _S16, _S17);
            dc_0 = dc_0 + int(1);
        }
        dr_0 = dr_0 + int(1);
    }
    thread Cell_0 _S18 = cell_0;
    float _S19 = Cell_sim_0(&_S18, c1_1, c3_1);
    return _S19;
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_0 ref_spec_1;
    RO_0 deg_spec_1;
    RO_0 window_1;
    RO_1 rows_0;
    RO_2 active_0;
    RW_0 stats_0;
    uint num_rows_0;
    uint num_bands_0;
    float c1_2;
    float c3_2;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void nsim_bands(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S20 = entryPointParams_1->stats_0;
    uint id_0 = zimt_index_0(tid_1);
    uint row_0 = id_0 / entryPointParams_1->num_bands_0;
    uint b_3 = id_0 % entryPointParams_1->num_bands_0;
    bool _S21;
    if(row_0 >= ((&kernelContext_0)->entryPointParams_0->num_rows_0))
    {
        _S21 = true;
    }
    else
    {
        uint _S22 = RO_operatorx5Bx5D_get_3(&(&kernelContext_0)->entryPointParams_0->active_0, row_0);
        _S21 = _S22 == 0U;
    }
    if(_S21)
    {
        return;
    }
    PatchPair_0 _S23 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    float _S24 = float(_S23.cols_0);
    float inv_ncols_0 = 1.0f / _S24;
    uint c_3 = 0U;
    float deg_sum_0 = 0.0f;
    for(;;)
    {
        if(c_3 < (_S23.cols_0))
        {
        }
        else
        {
            break;
        }
        float _S25 = degAt_0(&(&kernelContext_0)->entryPointParams_0->deg_spec_1, _S23.deg_off_0, _S23.deg_frames_0, _S23.deg_frame_0, b_3, c_3);
        float deg_sum_1 = deg_sum_0 + _S25;
        c_3 = c_3 + 1U;
        deg_sum_0 = deg_sum_1;
    }
    c_3 = 0U;
    float sim_sum_0 = 0.0f;
    for(;;)
    {
        if(c_3 < (_S23.cols_0))
        {
        }
        else
        {
            break;
        }
        float _S26 = (&kernelContext_0)->entryPointParams_0->c1_2;
        float _S27 = (&kernelContext_0)->entryPointParams_0->c3_2;
        thread PatchPair_0 _S28 = _S23;
        float _S29 = bandSim_0(&(&kernelContext_0)->entryPointParams_0->ref_spec_1, &(&kernelContext_0)->entryPointParams_0->deg_spec_1, &(&kernelContext_0)->entryPointParams_0->window_1, &_S28, b_3, c_3, entryPointParams_1->num_bands_0, _S26, _S27);
        float sim_sum_1 = sim_sum_0 + _S29;
        c_3 = c_3 + 1U;
        sim_sum_0 = sim_sum_1;
    }
    float mean_0 = sim_sum_0 * inv_ncols_0;
    float dev_0;
    if((_S23.cols_0) > 1U)
    {
        c_3 = 0U;
        dev_0 = 0.0f;
        for(;;)
        {
            if(c_3 < (_S23.cols_0))
            {
            }
            else
            {
                break;
            }
            float _S30 = (&kernelContext_0)->entryPointParams_0->c1_2;
            float _S31 = (&kernelContext_0)->entryPointParams_0->c3_2;
            thread PatchPair_0 _S32 = _S23;
            float _S33 = bandSim_0(&(&kernelContext_0)->entryPointParams_0->ref_spec_1, &(&kernelContext_0)->entryPointParams_0->deg_spec_1, &(&kernelContext_0)->entryPointParams_0->window_1, &_S32, b_3, c_3, entryPointParams_1->num_bands_0, _S30, _S31);
            float d_0 = _S33 - mean_0;
            float ss_0 = dev_0 + d_0 * d_0;
            c_3 = c_3 + 1U;
            dev_0 = ss_0;
        }
        dev_0 = sqrt(dev_0 / (_S24 - 1.0f));
    }
    else
    {
        dev_0 = 0.0f;
    }
    float deg_mean_0 = deg_sum_0 * inv_ncols_0;
    uint o_2 = (row_0 * entryPointParams_1->num_bands_0 + b_3) * 3U;
    *(_S20.p_1 + o_2) = mean_0;
    *(_S20.p_1 + (o_2 + 1U)) = dev_0;
    *(_S20.p_1 + (o_2 + 2U)) = deg_mean_0;
    return;
}

