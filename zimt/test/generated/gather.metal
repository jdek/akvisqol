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

struct Span_0
{
    uint start_0;
    uint len_0;
};

struct Job_0
{
    Span_0 src_0;
    float scale_0;
    float2 bias_0;
};

struct Job_natural_0
{
    Span_0 src_0;
    float scale_0;
    packed_float2 bias_0;
};

struct RO_1
{
    Job_natural_0 device* p_0;
};

Job_0 RO_operatorx5Bx5D_get_1(const RO_1 constant* this_1, uint i_1)
{
    Job_natural_0 device* _S1 = this_1->p_0 + i_1;
    Job_0 _S2 = { (*_S1).src_0, (*_S1).scale_0, float2((*_S1).bias_0)  };
    return _S2;
}

uint zimt_index_0(uint3 tid_0)
{
    return tid_0.x + tid_0.y * 1048576U;
}

struct RW_0
{
    float device* p_1;
};

struct EntryPointParams_0
{
    RO_1 jobs_0;
    RO_0 x_0;
    RW_0 y_0;
    uint n_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
};

[[kernel]] void gather(uint3 tid_1 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    RW_0 _S3 = entryPointParams_1->y_0;
    uint i_2 = zimt_index_0(tid_1);
    if(i_2 >= (entryPointParams_1->n_0))
    {
        return;
    }
    Job_0 _S4 = RO_operatorx5Bx5D_get_1(&(&kernelContext_0)->entryPointParams_0->jobs_0, i_2);
    uint k_0 = 0U;
    float s_0 = 0.0f;
    for(;;)
    {
        if(k_0 < (_S4.src_0.len_0))
        {
        }
        else
        {
            break;
        }
        float _S5 = RO_operatorx5Bx5D_get_0(&(&kernelContext_0)->entryPointParams_0->x_0, _S4.src_0.start_0 + k_0);
        float s_1 = s_0 + _S5;
        k_0 = k_0 + 1U;
        s_0 = s_1;
    }
    *(_S3.p_1 + i_2) = s_0 * _S4.scale_0 + _S4.bias_0.x - _S4.bias_0.y;
    return;
}

