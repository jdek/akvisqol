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

struct RO_1
{
    uint device* p_0;
};

uint RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
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

struct RO_2
{
    PatchPair_0 device* p_0;
};

PatchPair_0 RO_operatorx5Bx5D_get_2(const RO_2 constant* this_2, uint i_2)
{
    return *(this_2->p_0 + i_2);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_2 rows_0;
    RO_1 active_0;
    RO_0 g_stats_0;
    RO_0 cells_0;
    RW_0 patch_grad_0;
    uint num_rows_0;
    uint num_bands_0;
    uint max_cols_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void nsim_cells_bwd(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S1 = entryPointParams_1->patch_grad_0;
    uint id_0 = zimt_index_0(tid_1);
    uint row_0 = id_0 / (2U * entryPointParams_1->num_bands_0 * entryPointParams_1->max_cols_0);
    uint _S2 = id_0 / (entryPointParams_1->num_bands_0 * entryPointParams_1->max_cols_0);
    uint side_0 = _S2 % 2U;
    uint _S3 = id_0 / entryPointParams_1->max_cols_0;
    uint b_0 = _S3 % entryPointParams_1->num_bands_0;
    uint c_0 = id_0 % entryPointParams_1->max_cols_0;
    if(row_0 >= ((&kernelContext_0)->entryPointParams_0->num_rows_0))
    {
        return;
    }
    PatchPair_0 _S4 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
    uint _S5 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->active_0, row_0);
    bool _S6;
    if(_S5 != 0U)
    {
        _S6 = c_0 < (_S4.cols_0);
    }
    else
    {
        _S6 = false;
    }
    float sum_0;
    if(_S6)
    {
        int _S7 = int(b_0);
        int sb_0 = _S7 - int(1);
        float sum_1 = 0.0f;
        for(;;)
        {
            if(sb_0 <= (_S7 + int(1)))
            {
            }
            else
            {
                break;
            }
            if(sb_0 < int(0))
            {
                _S6 = true;
            }
            else
            {
                _S6 = sb_0 >= int(entryPointParams_1->num_bands_0);
            }
            if(_S6)
            {
                sum_0 = sum_1;
                sb_0 = sb_0 + int(1);
                sum_1 = sum_0;
                continue;
            }
            int _S8 = int(c_0);
            int sc_0 = _S8 - int(1);
            float sum_2 = sum_1;
            for(;;)
            {
                if(sc_0 <= (_S8 + int(1)))
                {
                }
                else
                {
                    break;
                }
                bool _S9;
                if(sc_0 < int(0))
                {
                    _S9 = true;
                }
                else
                {
                    _S9 = sc_0 >= int(_S4.cols_0);
                }
                if(_S9)
                {
                    sum_0 = sum_2;
                    sc_0 = sc_0 + int(1);
                    sum_2 = sum_0;
                    continue;
                }
                uint _S10 = ((row_0 * entryPointParams_1->num_bands_0 + uint(sb_0)) * entryPointParams_1->max_cols_0 + uint(sc_0)) * 18U + side_0 * 9U;
                int dr_0 = int(-1);
                float sum_3 = sum_2;
                for(;;)
                {
                    if(dr_0 <= int(1))
                    {
                    }
                    else
                    {
                        break;
                    }
                    if((clamp(sb_0 + dr_0, int(0), int(entryPointParams_1->num_bands_0) - int(1))) != _S7)
                    {
                        sum_0 = sum_3;
                        dr_0 = dr_0 + int(1);
                        sum_3 = sum_0;
                        continue;
                    }
                    int dc_0 = int(-1);
                    sum_0 = sum_3;
                    for(;;)
                    {
                        if(dc_0 <= int(1))
                        {
                        }
                        else
                        {
                            break;
                        }
                        if((clamp(sc_0 + dc_0, int(0), int(_S4.cols_0) - int(1))) != _S8)
                        {
                            dc_0 = dc_0 + int(1);
                            continue;
                        }
                        float _S11 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->cells_0, _S10 + uint((dr_0 + int(1)) * int(3) + dc_0 + int(1)));
                        sum_0 = sum_0 + _S11;
                        dc_0 = dc_0 + int(1);
                    }
                    dr_0 = dr_0 + int(1);
                    sum_3 = sum_0;
                }
                sum_0 = sum_3;
                sc_0 = sc_0 + int(1);
                sum_2 = sum_0;
            }
            sum_0 = sum_2;
            sb_0 = sb_0 + int(1);
            sum_1 = sum_0;
        }
        if(side_0 == 1U)
        {
            float _S12 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->g_stats_0, (row_0 * entryPointParams_1->num_bands_0 + b_0) * 3U + 2U);
            sum_1 = sum_1 + _S12 / float(_S4.cols_0);
        }
        sum_0 = sum_1;
    }
    else
    {
        sum_0 = 0.0f;
    }
    *(_S1.p_1 + (((row_0 * 2U + side_0) * entryPointParams_1->num_bands_0 + b_0) * entryPointParams_1->max_cols_0 + c_0)) = sum_0;
    return;
}

