#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct RW_0
{
    float device* p_0;
};

float RW_operatorx5Bx5D_get_0(const RW_0 constant* this_0, uint i_0)
{
    return *(this_0->p_0 + i_0);
}

struct RO_0
{
    float device* p_1;
};

float RO_operatorx5Bx5D_get_0(const RO_0 constant* this_1, uint i_1)
{
    return *(this_1->p_1 + i_1);
}

struct RealignPatch_0
{
    uint patch_0;
    uint deg_off_0;
    uint slices_0;
};

struct RO_1
{
    RealignPatch_0 device* p_1;
};

RealignPatch_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_2, uint i_2)
{
    return *(this_2->p_1 + i_2);
}

struct RO_2
{
    uint device* p_1;
};

uint RO_operatorx5Bx5D_get_2(const RO_2 constant* this_3, uint i_3)
{
    return *(this_3->p_1 + i_3);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

struct Realigned_0
{
    int lag_0;
    uint deg_total_0;
    uint accepted_0;
};

struct RW_1
{
    Realigned_0 device* p_0;
};

struct EntryPointParams_0
{
    RO_1 patches_0;
    RO_2 active_0;
    RO_0 rstats_0;
    RW_0 stats_0;
    RW_0 similarity_0;
    RW_1 realigned_0;
    uint num_rows_0;
    uint num_bands_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void realign_accept(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S1 = entryPointParams_1->stats_0;
    RW_0 _S2 = entryPointParams_1->similarity_0;
    uint row_0 = zimt_index_0(tid_1);
    bool _S3;
    if(row_0 >= (entryPointParams_1->num_rows_0))
    {
        _S3 = true;
    }
    else
    {
        uint _S4 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->active_0, row_0);
        _S3 = _S4 == 0U;
    }
    if(_S3)
    {
        return;
    }
    RealignPatch_0 _S5 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->patches_0, row_0);
    uint b_0 = 0U;
    float sum_0 = 0.0f;
    for(;;)
    {
        if(b_0 < ((&kernelContext_0)->entryPointParams_0->num_bands_0))
        {
        }
        else
        {
            break;
        }
        float _S6 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->rstats_0, (row_0 * (&kernelContext_0)->entryPointParams_0->num_bands_0 + b_0) * 3U);
        float sum_1 = sum_0 + _S6;
        b_0 = b_0 + 1U;
        sum_0 = sum_1;
    }
    float mean_0 = sum_0 / float((&kernelContext_0)->entryPointParams_0->num_bands_0);
    float _S7 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->similarity_0, _S5.patch_0);
    if(mean_0 < _S7)
    {
        return;
    }
    uint i_4 = 0U;
    for(;;)
    {
        if(i_4 < ((&kernelContext_0)->entryPointParams_0->num_bands_0 * 3U))
        {
        }
        else
        {
            break;
        }
        uint _S8 = _S5.patch_0 * (&kernelContext_0)->entryPointParams_0->num_bands_0 * 3U + i_4;
        float _S9 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->rstats_0, row_0 * (&kernelContext_0)->entryPointParams_0->num_bands_0 * 3U + i_4);
        *(_S1.p_0 + _S8) = _S9;
        i_4 = i_4 + 1U;
    }
    *(_S2.p_0 + _S5.patch_0) = mean_0;
    ((&kernelContext_0)->entryPointParams_0->realigned_0.p_0 + _S5.patch_0)->accepted_0 = 1U;
    return;
}

