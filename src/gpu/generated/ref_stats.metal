#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
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

struct EntryPointParams_0
{
    uint num_rows_0;
    uint num_bands_0;
    uint patch_size_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    float device* entryPointParams_spec_0;
    uint device* entryPointParams_rows_0;
    float device* entryPointParams_mu_0;
    float device* entryPointParams_srs_0;
};

[[kernel]] void ref_stats(uint3 tid_0 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]], float device* entryPointParams_spec_1 [[buffer(1)]], uint device* entryPointParams_rows_1 [[buffer(2)]], float device* entryPointParams_mu_1 [[buffer(3)]], float device* entryPointParams_srs_1 [[buffer(4)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    (&kernelContext_0)->entryPointParams_spec_0 = entryPointParams_spec_1;
    (&kernelContext_0)->entryPointParams_rows_0 = entryPointParams_rows_1;
    (&kernelContext_0)->entryPointParams_mu_0 = entryPointParams_mu_1;
    (&kernelContext_0)->entryPointParams_srs_0 = entryPointParams_srs_1;
    uint cells_0 = entryPointParams_1->num_bands_0 * entryPointParams_1->patch_size_0;
    uint _S3 = tid_0.x;
    uint row_0 = _S3 / cells_0;
    if(row_0 >= ((&kernelContext_0)->entryPointParams_0->num_rows_0))
    {
        return;
    }
    uint cell_0 = _S3 % cells_0;
    uint _S4 = cell_0 / entryPointParams_1->patch_size_0;
    int _S5 = int(_S4);
    uint _S6 = cell_0 % entryPointParams_1->patch_size_0;
    int _S7 = int(_S6);
    uint _S8 = row_0 * 3U;
    uint _S9 = (&kernelContext_0)->entryPointParams_rows_0[_S8];
    uint _S10 = (&kernelContext_0)->entryPointParams_rows_0[_S8 + 1U];
    uint _S11 = (&kernelContext_0)->entryPointParams_rows_0[_S8 + 2U];
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
        int _S12 = clamp(_S5 + dr_1, int(0), int(entryPointParams_1->num_bands_0) - int(1));
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
            float v_0 = (&kernelContext_0)->entryPointParams_spec_0[_S9 + uint(_S12) * _S10 + _S11 + uint(clamp(_S7 + dc_1, int(0), int(entryPointParams_1->patch_size_0) - int(1)))];
            float w_0 = wgt_0(dr_1, dc_1);
            float m_1 = m_0 + w_0 * v_0;
            float sq_1 = sq_0 + w_0 * (v_0 * v_0);
            dc_1 = dc_1 + int(1);
            m_0 = m_1;
            sq_0 = sq_1;
        }
        dr_1 = dr_1 + int(1);
    }
    uint o_0 = row_0 * cells_0 + cell_0;
    *((&kernelContext_0)->entryPointParams_mu_0+o_0) = m_0;
    *((&kernelContext_0)->entryPointParams_srs_0+o_0) = sq_0 - m_0 * m_0;
    return;
}

