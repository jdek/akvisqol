#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;
struct EntryPointParams_0
{
    float a_0;
    uint n_0;
};

struct KernelContext_0
{
    EntryPointParams_0 constant* entryPointParams_0;
    float device* entryPointParams_x_0;
    float device* entryPointParams_y_0;
};

[[kernel]] void saxpy(uint3 tid_0 [[thread_position_in_grid]], EntryPointParams_0 constant* entryPointParams_1 [[buffer(0)]], float device* entryPointParams_x_1 [[buffer(1)]], float device* entryPointParams_y_1 [[buffer(2)]])
{
    thread KernelContext_0 kernelContext_0;
    (&kernelContext_0)->entryPointParams_0 = entryPointParams_1;
    (&kernelContext_0)->entryPointParams_x_0 = entryPointParams_x_1;
    (&kernelContext_0)->entryPointParams_y_0 = entryPointParams_y_1;
    uint i_0 = tid_0.x;
    if(i_0 >= (entryPointParams_1->n_0))
    {
        return;
    }
    *((&kernelContext_0)->entryPointParams_y_0+i_0) = (&kernelContext_0)->entryPointParams_0->a_0 * (&kernelContext_0)->entryPointParams_x_0[i_0] + *((&kernelContext_0)->entryPointParams_y_0+i_0);
    return;
}

