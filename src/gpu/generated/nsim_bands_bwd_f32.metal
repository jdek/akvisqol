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

float refAt_0(const RO_0 constant* spec_0, uint o_0, uint nf_0, uint col0_0, uint b_0, uint c_0)
{
    float _S1 = RO_operatorx5Bx5D_get_1(spec_0, o_0 + b_0 * nf_0 + col0_0 + c_0);
    return _S1;
}

float degAt_0(const RO_0 constant* spec_1, uint o_1, uint nf_1, uint col0_1, uint b_1, uint c_1)
{
    float _S2;
    if((col0_1 + c_1) < nf_1)
    {
        float _S3 = RO_operatorx5Bx5D_get_1(spec_1, o_1 + b_1 * nf_1 + col0_1 + c_1);
        _S2 = _S3;
    }
    else
    {
        _S2 = 0.0f;
    }
    return _S2;
}

struct SimTerms_0
{
    array<float, int(9)> er_0;
    array<float, int(9)> ed_0;
    float sr_0;
    float sd_0;
    float mr_0;
    float md_0;
    float srs_0;
    float sds_0;
    float srd_0;
    float prod_0;
};

SimTerms_0 SimTerms_x24init_0(const array<float, int(9)> thread* r_0, const array<float, int(9)> thread* d_0, const array<float, int(9)> thread* w_0)
{
    thread SimTerms_0 _S4;
    (&_S4)->sr_0 = 0.0f;
    (&_S4)->sd_0 = 0.0f;
    uint k_0 = 0U;
    float qr_0 = 0.0f;
    float qd_0 = 0.0f;
    float qrd_0 = 0.0f;
    for(;;)
    {
        if(k_0 < 9U)
        {
        }
        else
        {
            break;
        }
        float _S5 = (*r_0)[k_0] - (*r_0)[int(4)];
        (&_S4)->er_0[k_0] = _S5;
        float _S6 = (*d_0)[k_0] - (*d_0)[int(4)];
        (&_S4)->ed_0[k_0] = _S6;
        (&_S4)->sr_0 = (&_S4)->sr_0 + (*w_0)[k_0] * _S5;
        (&_S4)->sd_0 = (&_S4)->sd_0 + (*w_0)[k_0] * _S6;
        float qr_1 = qr_0 + (*w_0)[k_0] * (_S5 * _S5);
        float qd_1 = qd_0 + (*w_0)[k_0] * (_S6 * _S6);
        float qrd_1 = qrd_0 + (*w_0)[k_0] * (_S5 * _S6);
        k_0 = k_0 + 1U;
        qr_0 = qr_1;
        qd_0 = qd_1;
        qrd_0 = qrd_1;
    }
    (&_S4)->mr_0 = (*r_0)[int(4)] + (&_S4)->sr_0;
    (&_S4)->md_0 = (*d_0)[int(4)] + (&_S4)->sd_0;
    float _S7 = qr_0 - (&_S4)->sr_0 * (&_S4)->sr_0;
    (&_S4)->srs_0 = _S7;
    float _S8 = qd_0 - (&_S4)->sd_0 * (&_S4)->sd_0;
    (&_S4)->sds_0 = _S8;
    (&_S4)->srd_0 = qrd_0 - (&_S4)->sr_0 * (&_S4)->sd_0;
    (&_S4)->prod_0 = _S7 * _S8;
    return _S4;
}

float SimTerms_denom_0(const SimTerms_0 thread* this_4, float c3_0)
{
    float _S9 = this_4->prod_0;
    float _S10;
    if((this_4->prod_0) > 0.0f)
    {
        _S10 = sqrt(_S9) + c3_0;
    }
    else
    {
        _S10 = c3_0;
    }
    return _S10;
}

float SimTerms_sim_0(const SimTerms_0 thread* this_5, float c1_0, float c3_1)
{
    float intensity_0 = (2.0f * (this_5->mr_0 * this_5->md_0) + c1_0) / (this_5->mr_0 * this_5->mr_0 + this_5->md_0 * this_5->md_0 + c1_0);
    float _S11 = this_5->srd_0 + c3_1;
    float _S12 = SimTerms_denom_0(this_5, c3_1);
    return intensity_0 * (_S11 / _S12);
}

void simBwd_0(const array<float, int(9)> thread* r_1, const array<float, int(9)> thread* d_1, const array<float, int(9)> thread* w_1, float c1_1, float c3_2, float g_0, array<float, int(9)> thread* gr_0, array<float, int(9)> thread* gd_0)
{
    SimTerms_0 _S13 = SimTerms_x24init_0(r_1, d_1, w_1);
    float a_0 = 2.0f * (_S13.mr_0 * _S13.md_0) + c1_1;
    float bb_0 = _S13.mr_0 * _S13.mr_0 + _S13.md_0 * _S13.md_0 + c1_1;
    thread SimTerms_0 _S14 = _S13;
    float _S15 = SimTerms_denom_0(&_S14, c3_2);
    float n_0 = _S13.srd_0 + c3_2;
    float g_i_0 = g_0 * (n_0 / _S15);
    float g_s_0 = g_0 * (a_0 / bb_0);
    float g_srd_0 = g_s_0 / _S15;
    float g_den_0 = - g_s_0 * n_0 / (_S15 * _S15);
    float g_prod_0;
    if((_S13.prod_0) > 0.0f)
    {
        g_prod_0 = g_den_0 / (2.0f * sqrt(_S13.prod_0));
    }
    else
    {
        g_prod_0 = 0.0f;
    }
    float g_srs_0 = g_prod_0 * _S13.sds_0;
    float g_sds_0 = g_prod_0 * _S13.srs_0;
    float _S16 = g_i_0 / bb_0 * 2.0f;
    float _S17 = - g_i_0 * a_0 / (bb_0 * bb_0) * 2.0f;
    float _S18 = _S16 * _S13.md_0 + _S17 * _S13.mr_0 - 2.0f * _S13.sr_0 * g_srs_0 - _S13.sd_0 * g_srd_0;
    float _S19 = _S16 * _S13.mr_0 + _S17 * _S13.md_0 - 2.0f * _S13.sd_0 * g_sds_0 - _S13.sr_0 * g_srd_0;
    uint k_1 = 0U;
    for(;;)
    {
        if(k_1 < 9U)
        {
        }
        else
        {
            break;
        }
        float _S20 = (*w_1)[k_1];
        (*gr_0)[k_1] = (*w_1)[k_1] * (_S18 + 2.0f * _S13.er_0[k_1] * g_srs_0 + _S13.ed_0[k_1] * g_srd_0);
        (*gd_0)[k_1] = _S20 * (_S19 + 2.0f * _S13.ed_0[k_1] * g_sds_0 + _S13.er_0[k_1] * g_srd_0);
        k_1 = k_1 + 1U;
    }
    return;
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_0 ref_spec_0;
    RO_0 deg_spec_0;
    RO_0 window_0;
    RO_1 rows_0;
    RO_2 active_0;
    RO_0 stats_0;
    RO_0 g_stats_0;
    RW_0 cells_0;
    uint num_rows_0;
    uint num_bands_0;
    uint max_cols_0;
    float c1_2;
    float c3_3;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void nsim_bands_bwd(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S21 = entryPointParams_1->cells_0;
    uint id_0 = zimt_index_0(tid_1);
    uint row_0 = id_0 / (entryPointParams_1->num_bands_0 * entryPointParams_1->max_cols_0);
    uint _S22 = id_0 / entryPointParams_1->max_cols_0;
    uint b_2 = _S22 % entryPointParams_1->num_bands_0;
    uint c_2 = id_0 % entryPointParams_1->max_cols_0;
    bool _S23;
    if(row_0 >= ((&kernelContext_0)->entryPointParams_0->num_rows_0))
    {
        _S23 = true;
    }
    else
    {
        uint _S24 = RO_operatorx5Bx5D_get_3(&(&kernelContext_0)->entryPointParams_0->active_0, row_0);
        _S23 = _S24 == 0U;
    }
    if(_S23)
    {
        return;
    }
    PatchPair_0 _S25 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    if(c_2 >= (_S25.cols_0))
    {
        return;
    }
    uint o_2 = (row_0 * entryPointParams_1->num_bands_0 + b_2) * 3U;
    float _S26 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->g_stats_0, o_2);
    uint _S27 = o_2 + 1U;
    float _S28 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->g_stats_0, _S27);
    thread array<float, int(9)> w_2;
    thread array<float, int(9)> r_2;
    thread array<float, int(9)> d_2;
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
        uint _S29 = uint(clamp(int(b_2) + dr_0, int(0), int(entryPointParams_1->num_bands_0) - int(1)));
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
            uint cc_0 = uint(clamp(int(c_2) + dc_0, int(0), int(_S25.cols_0) - int(1)));
            uint k_2 = uint((dr_0 + int(1)) * int(3) + dc_0 + int(1));
            float _S30 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->window_0, k_2);
            w_2[k_2] = _S30;
            float _S31 = refAt_0(&(&kernelContext_0)->entryPointParams_0->ref_spec_0, _S25.ref_off_0, _S25.ref_frames_0, _S25.ref_frame_0, _S29, cc_0);
            r_2[k_2] = _S31;
            float _S32 = degAt_0(&(&kernelContext_0)->entryPointParams_0->deg_spec_0, _S25.deg_off_0, _S25.deg_frames_0, _S25.deg_frame_0, _S29, cc_0);
            d_2[k_2] = _S32;
            dc_0 = dc_0 + int(1);
        }
        dr_0 = dr_0 + int(1);
    }
    float _S33 = float(_S25.cols_0);
    float g_1 = _S26 / _S33;
    float _S34 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->stats_0, _S27);
    if((_S25.cols_0) > 1U)
    {
        _S23 = _S34 > 0.0f;
    }
    else
    {
        _S23 = false;
    }
    if(_S23)
    {
        _S23 = _S28 != 0.0f;
    }
    else
    {
        _S23 = false;
    }
    float g_2;
    if(_S23)
    {
        thread array<float, int(9)> _S35 = r_2;
        thread array<float, int(9)> _S36 = d_2;
        thread array<float, int(9)> _S37 = w_2;
        SimTerms_0 _S38 = SimTerms_x24init_0(&_S35, &_S36, &_S37);
        float _S39 = (&kernelContext_0)->entryPointParams_0->c1_2;
        float _S40 = (&kernelContext_0)->entryPointParams_0->c3_3;
        thread SimTerms_0 _S41 = _S38;
        float _S42 = SimTerms_sim_0(&_S41, _S39, _S40);
        float _S43 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->stats_0, o_2);
        g_2 = g_1 + _S28 * (_S42 - _S43) / ((_S33 - 1.0f) * _S34);
    }
    else
    {
        g_2 = g_1;
    }
    float _S44 = (&kernelContext_0)->entryPointParams_0->c1_2;
    float _S45 = (&kernelContext_0)->entryPointParams_0->c3_3;
    thread array<float, int(9)> _S46 = r_2;
    thread array<float, int(9)> _S47 = d_2;
    thread array<float, int(9)> _S48 = w_2;
    thread array<float, int(9)> gr_1;
    thread array<float, int(9)> gd_1;
    simBwd_0(&_S46, &_S47, &_S48, _S44, _S45, g_2, &gr_1, &gd_1);
    uint _S49 = ((row_0 * entryPointParams_1->num_bands_0 + b_2) * entryPointParams_1->max_cols_0 + c_2) * 18U;
    uint k_3 = 0U;
    for(;;)
    {
        if(k_3 < 9U)
        {
        }
        else
        {
            break;
        }
        *(_S21.p_1 + (_S49 + k_3)) = gr_1[k_3];
        *(_S21.p_1 + (_S49 + 9U + k_3)) = gd_1[k_3];
        k_3 = k_3 + 1U;
    }
    return;
}

