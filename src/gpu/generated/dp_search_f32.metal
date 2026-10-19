#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct RW_0
{
    uint device* p_0;
};

uint RW_operatorx5Bx5D_get_0(const RW_0 constant* this_0, uint i_0)
{
    return *(this_0->p_0 + i_0);
}

struct RW_1
{
    float device* p_0;
};

float RW_operatorx5Bx5D_get_1(const RW_1 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

struct RO_0
{
    float device* p_1;
};

float RO_operatorx5Bx5D_get_0(const RO_0 constant* this_2, uint i_2)
{
    return *(this_2->p_1 + i_2);
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
    PatchSearch_0 device* p_1;
};

PatchSearch_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_3, uint i_3)
{
    return *(this_3->p_1 + i_3);
}

struct DpPair_0
{
    uint first_0;
    uint patches_0;
    uint deg_frames_1;
    uint table_0;
};

struct RO_2
{
    DpPair_0 device* p_1;
};

DpPair_0 RO_operatorx5Bx5D_get_2(const RO_2 constant* this_4, uint i_4)
{
    return *(this_4->p_1 + i_4);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 8388608U;
}

void keep_0(float thread* m_0, int thread* idx_0, float v_0, int j_0)
{
    if(v_0 >= (*m_0))
    {
        *m_0 = v_0;
        *idx_0 = j_0;
    }
    return;
}

struct Match_0
{
    uint deg_frame_0;
    uint visited_0;
    uint valid_0;
};

Match_0 Match_x24init_0(uint deg_frame_1, uint visited_1, uint valid_1)
{
    thread Match_0 _S1;
    (&_S1)->deg_frame_0 = deg_frame_1;
    (&_S1)->visited_0 = visited_1;
    (&_S1)->valid_0 = valid_1;
    return _S1;
}

struct RW_2
{
    Match_0 device* p_0;
};

struct EntryPointParams_0
{
    RO_2 pairs_0;
    RO_1 patches_1;
    RO_0 sims_0;
    RW_1 dp_0;
    RW_0 bt_0;
    RW_2 matches_0;
    uint num_pairs_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    array<float, int(256)> threadgroup* seg_max_0;
    array<int, int(256)> threadgroup* seg_idx_0;
};

[[kernel]] void dp_search(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    uint _S2;
    uint j_1;
    uint t_0;
    float similarity_0;
    int past_0;
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    threadgroup array<float, int(256)> seg_max_1;
    (&kernelContext_0)->seg_max_0 = &seg_max_1;
    threadgroup array<int, int(256)> seg_idx_1;
    (&kernelContext_0)->seg_idx_0 = &seg_idx_1;
    RW_1 _S3 = entryPointParams_1->dp_0;
    RW_0 _S4 = entryPointParams_1->bt_0;
    RW_2 _S5 = entryPointParams_1->matches_0;
    uint k_0 = zimt_index_0(tid_1) / 256U;
    uint lane_0 = tid_1.x % 256U;
    if(k_0 >= (entryPointParams_1->num_pairs_0))
    {
        return;
    }
    DpPair_0 _S6 = RO_operatorx5Bx5D_get_2(&(&kernelContext_0)->entryPointParams_0->pairs_0, k_0);
    uint pi_0 = 0U;
    for(;;)
    {
        _S2 = _S6.patches_0;
        if(pi_0 < (_S6.patches_0))
        {
        }
        else
        {
            break;
        }
        uint _S7 = _S6.first_0 + pi_0;
        PatchSearch_0 _S8 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->patches_1, _S7);
        uint row_1 = _S6.table_0 + pi_0 * _S6.deg_frames_1;
        uint s_0;
        if(pi_0 == 0U)
        {
            s_0 = _S8.lo_0 + lane_0;
            for(;;)
            {
                if(s_0 <= (_S8.hi_0))
                {
                }
                else
                {
                    break;
                }
                uint _S9 = row_1 + s_0;
                float _S10 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->sims_0, _S9);
                *(_S3.p_0 + _S9) = _S10;
                *(_S4.p_0 + _S9) = 4294967295U;
                s_0 = s_0 + 256U;
            }
            threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup | mem_flags::mem_texture | mem_flags::mem_threadgroup_imageblock);
            pi_0 = pi_0 + 1U;
            continue;
        }
        uint _S11 = row_1 - _S6.deg_frames_1;
        PatchSearch_0 _S12 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->patches_1, _S7 - 1U);
        uint _S13 = _S8.hi_0 + 1U;
        uint span_0 = (_S13 - _S12.lo_0 + 256U - 1U) / 256U;
        uint first_1 = _S12.lo_0 + lane_0 * span_0;
        uint _S14 = min(first_1 + span_0, _S13);
        thread float m_1 = (as_type<float>((4286578688U)));
        thread int idx_1 = int(-1);
        j_1 = first_1;
        for(;;)
        {
            if(j_1 < _S14)
            {
            }
            else
            {
                break;
            }
            float _S15 = RW_operatorx5Bx5D_get_1(&entryPointParams_1->dp_0, _S11 + j_1);
            keep_0(&m_1, &idx_1, _S15, int(j_1));
            j_1 = j_1 + 1U;
        }
        (*(&kernelContext_0)->seg_max_0)[lane_0] = m_1;
        (*(&kernelContext_0)->seg_idx_0)[lane_0] = idx_1;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        thread float rm_0 = (as_type<float>((4286578688U)));
        thread int ri_0 = int(-1);
        t_0 = 0U;
        for(;;)
        {
            if(t_0 < lane_0)
            {
            }
            else
            {
                break;
            }
            if(((*(&kernelContext_0)->seg_idx_0)[t_0]) >= int(0))
            {
                keep_0(&rm_0, &ri_0, (*(&kernelContext_0)->seg_max_0)[t_0], (*(&kernelContext_0)->seg_idx_0)[t_0]);
            }
            t_0 = t_0 + 1U;
        }
        s_0 = first_1;
        for(;;)
        {
            if(s_0 < _S14)
            {
            }
            else
            {
                break;
            }
            float _S16 = RW_operatorx5Bx5D_get_1(&entryPointParams_1->dp_0, _S11 + s_0);
            if(s_0 >= (_S8.lo_0))
            {
                uint _S17 = row_1 + s_0;
                float _S18 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->sims_0, _S17);
                float similarity_1 = _S18 + rm_0;
                int _S19 = ri_0;
                if(_S16 > similarity_1)
                {
                    int _S20 = int(s_0);
                    similarity_0 = _S16;
                    past_0 = _S20;
                }
                else
                {
                    similarity_0 = similarity_1;
                    past_0 = _S19;
                }
                *(_S3.p_0 + _S17) = similarity_0;
                uint _S21;
                if(past_0 < int(0))
                {
                    _S21 = 4294967295U;
                }
                else
                {
                    _S21 = uint(past_0);
                }
                *(_S4.p_0 + _S17) = _S21;
            }
            keep_0(&rm_0, &ri_0, _S16, int(s_0));
            s_0 = s_0 + 1U;
        }
        threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup | mem_flags::mem_texture | mem_flags::mem_threadgroup_imageblock);
        pi_0 = pi_0 + 1U;
    }
    if(lane_0 != 0U)
    {
        return;
    }
    uint last_0 = _S2 - 1U;
    PatchSearch_0 _S22 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->patches_1, _S6.first_0 + last_0);
    similarity_0 = (as_type<float>((4286578688U)));
    j_1 = 0U;
    t_0 = _S22.lo_0;
    for(;;)
    {
        if(t_0 <= (_S22.hi_0))
        {
        }
        else
        {
            break;
        }
        float _S23 = RW_operatorx5Bx5D_get_1(&entryPointParams_1->dp_0, _S6.table_0 + last_0 * _S6.deg_frames_1 + t_0);
        if(_S23 > similarity_0)
        {
            similarity_0 = _S23;
            j_1 = t_0;
        }
        t_0 = t_0 + 1U;
    }
    past_0 = int(last_0);
    for(;;)
    {
        if(past_0 >= int(0))
        {
        }
        else
        {
            break;
        }
        uint _S24 = uint(past_0);
        uint _S25 = RW_operatorx5Bx5D_get_0(&entryPointParams_1->bt_0, _S6.table_0 + _S24 * _S6.deg_frames_1 + j_1);
        int _S26;
        if(_S25 != j_1)
        {
            _S26 = int(1);
        }
        else
        {
            _S26 = int(0);
        }
        *(_S5.p_0 + (_S6.first_0 + _S24)) = Match_x24init_0(j_1, 1U, uint(_S26));
        if(_S25 == 4294967295U)
        {
            break;
        }
        int _S27 = past_0 - int(1);
        j_1 = _S25;
        past_0 = _S27;
    }
    return;
}

