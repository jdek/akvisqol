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

struct Match_0
{
    uint deg_frame_0;
    uint visited_0;
    uint valid_0;
};

struct RO_0
{
    Match_0 device* p_1;
};

Match_0 RO_operatorx5Bx5D_get_0(const RO_0 constant* this_1, uint i_1)
{
    return *(this_1->p_1 + i_1);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

struct EntryPointParams_0
{
    RO_0 matches_0;
    RW_0 stats_0;
    RW_0 similarity_0;
    uint num_patches_0;
    uint num_bands_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void match_finalize(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S1 = entryPointParams_1->stats_0;
    RW_0 _S2 = entryPointParams_1->similarity_0;
    uint m_0 = zimt_index_0(tid_1);
    bool _S3;
    if(m_0 >= (entryPointParams_1->num_patches_0))
    {
        _S3 = true;
    }
    else
    {
        Match_0 _S4 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->matches_0, m_0);
        _S3 = (_S4.visited_0) == 0U;
    }
    if(_S3)
    {
        return;
    }
    Match_0 _S5 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->matches_0, m_0);
    bool valid_1 = (_S5.valid_0) != 0U;
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
        float _S6 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->stats_0, (m_0 * (&kernelContext_0)->entryPointParams_0->num_bands_0 + b_0) * 3U);
        float sum_1 = sum_0 + _S6;
        if(!valid_1)
        {
            *(_S1.p_0 + (m_0 * (&kernelContext_0)->entryPointParams_0->num_bands_0 + b_0) * 3U) = 0.0f;
        }
        b_0 = b_0 + 1U;
        sum_0 = sum_1;
    }
    if(valid_1)
    {
        sum_0 = sum_0 / float((&kernelContext_0)->entryPointParams_0->num_bands_0);
    }
    else
    {
        sum_0 = 0.0f;
    }
    *(_S2.p_0 + m_0) = sum_0;
    return;
}

