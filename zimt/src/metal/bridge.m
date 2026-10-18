// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "bridge.h"
#include <stdlib.h>
#include <string.h>

struct ZimtMetal {
    void *device;   /* id<MTLDevice> */
    void *queue;    /* id<MTLCommandQueue> */
    void *cmdbuf;   /* id<MTLCommandBuffer>, open while encoding */
    void *encoder;  /* id<MTLComputeCommandEncoder> */
};

static void copy_err(char *dst, size_t len, NSString *msg) {
    if (!dst || len == 0) return;
    const char *s = msg ? [msg UTF8String] : "unknown Metal error";
    strncpy(dst, s ? s : "", len - 1);
    dst[len - 1] = 0;
}

int zimt_metal_open(ZimtMetal **out, char *name, size_t name_len) {
    @autoreleasepool {
        *out = NULL;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return -1;
        id<MTLCommandQueue> q = [dev newCommandQueue];
        if (!q) return -1;
        ZimtMetal *m = calloc(1, sizeof(ZimtMetal));
        if (!m) return -1;
        m->device = (__bridge_retained void *)dev;
        m->queue = (__bridge_retained void *)q;
        copy_err(name, name_len, dev.name);
        *out = m;
        return 0;
    }
}

static void end_encoding(ZimtMetal *m) {
    if (m->encoder) {
        id<MTLComputeCommandEncoder> enc = (__bridge_transfer id<MTLComputeCommandEncoder>)m->encoder;
        [enc endEncoding];
        m->encoder = NULL;
    }
}

void *zimt_metal_commit(ZimtMetal *m) {
    @autoreleasepool {
        if (!m->cmdbuf) return NULL;
        end_encoding(m);
        id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)m->cmdbuf;
        [cb commit];
        void *handle = m->cmdbuf; /* retain moves to the caller */
        m->cmdbuf = NULL;
        return handle;
    }
}

int zimt_metal_finish(void *cmdbuf, int block, char *err, size_t err_len) {
    @autoreleasepool {
        id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cmdbuf;
        if (block) {
            [cb waitUntilCompleted];
        } else {
            MTLCommandBufferStatus s = cb.status;
            if (s != MTLCommandBufferStatusCompleted && s != MTLCommandBufferStatusError) return 0;
        }
        int rc = 1;
        if (cb.status == MTLCommandBufferStatusError) {
            copy_err(err, err_len, cb.error.localizedDescription);
            rc = -1;
        }
        (void)(__bridge_transfer id)cmdbuf;
        return rc;
    }
}

/* The caller has retired every submission. */
void zimt_metal_close(ZimtMetal *m) {
    if (!m) return;
    @autoreleasepool {
        end_encoding(m);
        if (m->cmdbuf) (void)(__bridge_transfer id)m->cmdbuf;
        if (m->queue) (void)(__bridge_transfer id)m->queue;
        if (m->device) (void)(__bridge_transfer id)m->device;
    }
    free(m);
}

void zimt_metal_release(void *obj) {
    if (obj) (void)(__bridge_transfer id)obj;
}

void *zimt_metal_library_new(ZimtMetal *m, const void *bytes, size_t len, char *err, size_t err_len) {
    @autoreleasepool {
        id<MTLDevice> dev = (__bridge id<MTLDevice>)m->device;
        dispatch_data_t data = dispatch_data_create(bytes, len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        NSError *e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithData:data error:&e];
        if (!lib) {
            copy_err(err, err_len, e.localizedDescription);
            return NULL;
        }
        return (__bridge_retained void *)lib;
    }
}

void *zimt_metal_pipeline_new(ZimtMetal *m, void *lib, const char *entry, uint32_t *max_threads, char *err, size_t err_len) {
    @autoreleasepool {
        id<MTLDevice> dev = (__bridge id<MTLDevice>)m->device;
        id<MTLLibrary> l = (__bridge id<MTLLibrary>)lib;
        id<MTLFunction> fn = [l newFunctionWithName:[NSString stringWithUTF8String:entry]];
        if (!fn) {
            copy_err(err, err_len, [NSString stringWithFormat:@"no kernel '%s' in library", entry]);
            return NULL;
        }
        NSError *e = nil;
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:fn error:&e];
        if (!ps) {
            copy_err(err, err_len, e.localizedDescription);
            return NULL;
        }
        if (max_threads) *max_threads = (uint32_t)ps.maxTotalThreadsPerThreadgroup;
        return (__bridge_retained void *)ps;
    }
}

void zimt_metal_memory(ZimtMetal *m, uint64_t *used, uint64_t *limit) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)m->device;
    *used = dev.currentAllocatedSize;
    *limit = dev.recommendedMaxWorkingSetSize;
}

void *zimt_metal_buffer_new(ZimtMetal *m, size_t bytes, void **contents) {
    @autoreleasepool {
        id<MTLDevice> dev = (__bridge id<MTLDevice>)m->device;
        id<MTLBuffer> b = [dev newBufferWithLength:(bytes ? bytes : 4) options:MTLResourceStorageModeShared];
        if (!b) return NULL;
        if (contents) *contents = b.contents;
        return (__bridge_retained void *)b;
    }
}

int zimt_metal_dispatch(ZimtMetal *m, void *pipeline,
                        void *const *buffers, const size_t *offsets, const uint32_t *indices, uint32_t nbuffers,
                        const void *bytes, uint32_t nbytes, uint32_t bytes_index,
                        const uint32_t groups[3], const uint32_t threads[3]) {
    @autoreleasepool {
        if (!m->cmdbuf) {
            id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)m->queue;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            if (!cb) return -1;
            m->cmdbuf = (__bridge_retained void *)cb;
        }
        if (!m->encoder) {
            id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)m->cmdbuf;
            /* Serial dispatch: each dispatch sees the previous one's writes. */
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial];
            if (!enc) return -1;
            m->encoder = (__bridge_retained void *)enc;
        }
        id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)m->encoder;
        [enc setComputePipelineState:(__bridge id<MTLComputePipelineState>)pipeline];
        if (nbytes > 0) [enc setBytes:bytes length:nbytes atIndex:bytes_index];
        for (uint32_t i = 0; i < nbuffers; i++) {
            [enc setBuffer:(__bridge id<MTLBuffer>)buffers[i] offset:offsets[i] atIndex:indices[i]];
        }
        [enc dispatchThreadgroups:MTLSizeMake(groups[0], groups[1], groups[2])
            threadsPerThreadgroup:MTLSizeMake(threads[0], threads[1], threads[2])];
        return 0;
    }
}
