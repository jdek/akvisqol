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

PatchPair_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

struct RO_2
{
    uint device* p_0;
};

uint RO_operatorx5Bx5D_get_2(const RO_2 constant* this_2, uint i_2)
{
    return *(this_2->p_0 + i_2);
}

struct SpecGather_0
{
    uint off_0;
    uint frames_0;
    uint side_0;
    uint first_0;
    uint count_0;
};

struct RO_3
{
    SpecGather_0 device* p_0;
};

SpecGather_0 RO_operatorx5Bx5D_get_3(const RO_3 constant* this_3, uint i_3)
{
    return *(this_3->p_0 + i_3);
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
    RO_3 specs_0;
    RO_1 rows_0;
    RO_2 active_0;
    RO_0 patch_grad_0;
    RW_0 out_0;
    uint num_specs_0;
    uint max_cells_0;
    uint num_bands_0;
    uint max_cols_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void spec_grad(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S1 = entryPointParams_1->out_0;
    uint id_0 = zimt_index_0(tid_1);
    uint s_0 = id_0 / entryPointParams_1->max_cells_0;
    uint cell_0 = id_0 % entryPointParams_1->max_cells_0;
    if(s_0 >= ((&kernelContext_0)->entryPointParams_0->num_specs_0))
    {
        return;
    }
    SpecGather_0 _S2 = RO_operatorx5Bx5D_get_3(&(&kernelContext_0)->entryPointParams_0->specs_0, s_0);
    if(cell_0 >= ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S2.frames_0))
    {
        return;
    }
    uint _S3 = cell_0 / _S2.frames_0;
    uint _S4 = cell_0 % _S2.frames_0;
    uint i_4 = 0U;
    float sum_0 = 0.0f;
    for(;;)
    {
        if(i_4 < (_S2.count_0))
        {
        }
        else
        {
            break;
        }
        uint row_0 = _S2.first_0 + i_4;
        uint _S5 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->active_0, row_0);
        if(_S5 == 0U)
        {
            i_4 = i_4 + 1U;
            continue;
        }
        PatchPair_0 _S6 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->rows_0, row_0);
        uint first_1;
        if((_S2.side_0) == 0U)
        {
            first_1 = _S6.ref_frame_0;
        }
        else
        {
            first_1 = _S6.deg_frame_0;
        }
        bool _S7;
        if(_S4 < first_1)
        {
            _S7 = true;
        }
        else
        {
            _S7 = (_S4 - first_1) >= (_S6.cols_0);
        }
        if(_S7)
        {
            i_4 = i_4 + 1U;
            continue;
        }
        float _S8 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->patch_grad_0, ((row_0 * 2U + _S2.side_0) * (&kernelContext_0)->entryPointParams_0->num_bands_0 + _S3) * (&kernelContext_0)->entryPointParams_0->max_cols_0 + _S4 - first_1);
        sum_0 = sum_0 + _S8;
        i_4 = i_4 + 1U;
    }
    *(_S1.p_1 + (_S2.off_0 + cell_0)) = sum_0;
    return;
}

