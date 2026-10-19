#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct Match_0
{
    uint deg_frame_0;
    uint visited_0;
    uint valid_0;
};

struct RO_0
{
    Match_0 device* p_0;
};

Match_0 RO_operatorx5Bx5D_get_0(const RO_0 constant* this_0, uint i_0)
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

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

struct PatchPair_0
{
    uint ref_off_1;
    uint ref_frames_1;
    uint ref_frame_1;
    uint deg_off_1;
    uint deg_frames_1;
    uint deg_frame_1;
    uint cols_0;
};

PatchPair_0 PatchPair_x24init_0(uint ref_off_2, uint ref_frames_2, uint ref_frame_2, uint deg_off_2, uint deg_frames_2, uint deg_frame_2, uint cols_1)
{
    thread PatchPair_0 _S1;
    (&_S1)->ref_off_1 = ref_off_2;
    (&_S1)->ref_frames_1 = ref_frames_2;
    (&_S1)->ref_frame_1 = ref_frame_2;
    (&_S1)->deg_off_1 = deg_off_2;
    (&_S1)->deg_frames_1 = deg_frames_2;
    (&_S1)->deg_frame_1 = deg_frame_2;
    (&_S1)->cols_0 = cols_1;
    return _S1;
}

struct RW_0
{
    PatchPair_0 device* p_1;
};

struct RW_1
{
    uint device* p_1;
};

struct EntryPointParams_0
{
    RO_1 patches_0;
    RO_0 matches_0;
    RW_0 rows_0;
    RW_1 active_0;
    uint num_patches_0;
    uint patch_size_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void match_rows(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S2 = entryPointParams_1->rows_0;
    RW_1 _S3 = entryPointParams_1->active_0;
    uint m_0 = zimt_index_0(tid_1);
    if(m_0 >= (entryPointParams_1->num_patches_0))
    {
        return;
    }
    PatchSearch_0 _S4 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->patches_0, m_0);
    Match_0 _S5 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->matches_0, m_0);
    *(_S2.p_1 + m_0) = PatchPair_x24init_0(_S4.ref_off_0, _S4.ref_frames_0, _S4.ref_frame_0, _S4.deg_off_0, _S4.deg_frames_0, _S5.deg_frame_0, (&kernelContext_0)->entryPointParams_0->patch_size_0);
    Match_0 _S6 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->matches_0, m_0);
    *(_S3.p_1 + m_0) = _S6.visited_0;
    return;
}

