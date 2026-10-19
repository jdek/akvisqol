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

struct RefPatch_0
{
    uint ref_off_0;
    uint ref_frames_0;
    uint ref_frame_0;
};

struct RO_1
{
    RefPatch_0 device* p_0;
};

RefPatch_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
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

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_0 spec_0;
    RO_1 rows_0;
    RW_0 mu_0;
    RW_0 srs_0;
    uint num_rows_0;
    uint num_bands_0;
    uint patch_size_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void ref_stats(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S3 = entryPointParams_1->mu_0;
    RW_0 _S4 = entryPointParams_1->srs_0;
    uint cells_0 = entryPointParams_1->num_bands_0 * entryPointParams_1->patch_size_0;
    uint id_0 = zimt_index_0(tid_1);
    uint row_0 = id_0 / cells_0;
    if(row_0 >= ((&kernelContext_0)->entryPointParams_0->num_rows_0))
    {
        return;
    }
    uint cell_0 = id_0 % cells_0;
    uint _S5 = cell_0 / entryPointParams_1->patch_size_0;
    int _S6 = int(_S5);
    uint _S7 = cell_0 % entryPointParams_1->patch_size_0;
    int _S8 = int(_S7);
    RefPatch_0 _S9 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    RefPatch_0 _S10 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    RefPatch_0 _S11 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    int dr_1 = int(-1);
    float m_0 = 0.0f;
    float sq_0 = 0.0f;
    for(;;)
    {
        if(dr_1 <= int(1))
        {
        }
        else
        {
            break;
        }
        int _S12 = clamp(_S6 + dr_1, int(0), int(entryPointParams_1->num_bands_0) - int(1));
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
            float _S13 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->spec_0, _S9.ref_off_0 + uint(_S12) * _S10.ref_frames_0 + _S11.ref_frame_0 + uint(clamp(_S8 + dc_1, int(0), int(entryPointParams_1->patch_size_0) - int(1))));
            float w_0 = wgt_0(dr_1, dc_1);
            float m_1 = m_0 + w_0 * _S13;
            float sq_1 = sq_0 + w_0 * (_S13 * _S13);
            dc_1 = dc_1 + int(1);
            m_0 = m_1;
            sq_0 = sq_1;
        }
        dr_1 = dr_1 + int(1);
    }
    uint o_0 = row_0 * cells_0 + cell_0;
    *(_S3.p_1 + o_0) = m_0;
    *(_S4.p_1 + o_0) = sq_0 - m_0 * m_0;
    return;
}

