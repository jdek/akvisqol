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

struct DegPlane_0
{
    uint deg_off_0;
    uint deg_frames_0;
    uint plane_0;
    uint width_0;
};

struct RO_1
{
    DegPlane_0 device* p_0;
};

DegPlane_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
{
    return *(this_1->p_0 + i_1);
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 2097152U;
}

struct Terms_0
{
    float c_0;
    float m_0;
    float v_0;
};

Terms_0 Terms_x24init_0(float c_1, float m_1, float v_1)
{
    thread Terms_0 _S1;
    (&_S1)->c_0 = c_1;
    (&_S1)->m_0 = m_1;
    (&_S1)->v_0 = v_1;
    return _S1;
}

Terms_0 windowTerms_0(const array<float, int(9)> thread* x_0, float centre_0, const RO_0 constant* window_0)
{
    uint k_0 = 0U;
    float m_2 = 0.0f;
    float q_0 = 0.0f;
    for(;;)
    {
        if(k_0 < 9U)
        {
        }
        else
        {
            break;
        }
        float e_0 = (*x_0)[k_0] - centre_0;
        float _S2 = RO_operatorx5Bx5D_get_0(window_0, k_0);
        float m_3 = m_2 + _S2 * e_0;
        float _S3 = RO_operatorx5Bx5D_get_0(window_0, k_0);
        float q_1 = q_0 + _S3 * (e_0 * e_0);
        k_0 = k_0 + 1U;
        m_2 = m_3;
        q_0 = q_1;
    }
    return Terms_x24init_0(centre_0, m_2, q_0 - m_2 * m_2);
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_0 deg_spec_0;
    RO_0 window_1;
    RO_1 planes_0;
    RW_0 deg_terms_0;
    uint num_planes_0;
    uint max_cells_0;
    uint num_bands_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void deg_plane(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S4 = entryPointParams_1->deg_terms_0;
    uint id_0 = zimt_index_0(tid_1);
    uint p_2 = id_0 / entryPointParams_1->max_cells_0;
    uint cell_0 = id_0 % entryPointParams_1->max_cells_0;
    if(p_2 >= ((&kernelContext_0)->entryPointParams_0->num_planes_0))
    {
        return;
    }
    DegPlane_0 _S5 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->planes_0, p_2);
    if(cell_0 >= ((&kernelContext_0)->entryPointParams_0->num_bands_0 * _S5.width_0))
    {
        return;
    }
    uint _S6 = cell_0 / _S5.width_0;
    int _S7 = int(_S6);
    uint _S8 = cell_0 % _S5.width_0;
    int _S9 = int(_S8);
    thread array<float, int(9)> x_1;
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
            uint rr_0 = uint(clamp(_S7 + dr_0, int(0), int((&kernelContext_0)->entryPointParams_0->num_bands_0) - int(1)));
            uint cc_0 = uint(clamp(_S9 + dc_0, int(0), int(_S5.width_0) - int(1)));
            float _S10;
            if(cc_0 < (_S5.deg_frames_0))
            {
                float _S11 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->deg_spec_0, _S5.deg_off_0 + rr_0 * _S5.deg_frames_0 + cc_0);
                _S10 = _S11;
            }
            else
            {
                _S10 = 0.0f;
            }
            x_1[(dr_0 + int(1)) * int(3) + dc_0 + int(1)] = _S10;
            dc_0 = dc_0 + int(1);
        }
        dr_0 = dr_0 + int(1);
    }
    thread array<float, int(9)> _S12 = x_1;
    Terms_0 _S13 = windowTerms_0(&_S12, x_1[int(4)], &(&kernelContext_0)->entryPointParams_0->window_1);
    uint _S14 = _S5.plane_0 + cell_0 * 2U;
    *(_S4.p_1 + _S14) = _S13.m_0;
    *(_S4.p_1 + (_S14 + 1U)) = _S13.v_0;
    return;
}

