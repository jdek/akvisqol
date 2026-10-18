// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

/* Metal compute bridge. Handles are retained Objective-C objects. */
#ifndef ZIMT_METAL_BRIDGE_H
#define ZIMT_METAL_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

typedef struct ZimtMetal ZimtMetal;

/* 0 on success. `name` receives the device name (NUL-terminated). */
int zimt_metal_open(ZimtMetal **out, char *name, size_t name_len);
void zimt_metal_close(ZimtMetal *m);

void zimt_metal_release(void *obj);

void *zimt_metal_library_new(ZimtMetal *m, const void *bytes, size_t len, char *err, size_t err_len);
void *zimt_metal_pipeline_new(ZimtMetal *m, void *lib, const char *entry, uint32_t *max_threads, char *err, size_t err_len);

/* Bytes the device has allocated, and the most it should for good
   performance (recommendedMaxWorkingSetSize). */
void zimt_metal_memory(ZimtMetal *m, uint64_t *used, uint64_t *limit);

/* Shared-storage buffer; `*contents` receives the CPU mapping. */
void *zimt_metal_buffer_new(ZimtMetal *m, size_t bytes, void **contents);

/* buffers[i] binds at indices[i] from offsets[i]; `bytes` (if nbytes > 0) at bytes_index. */
int zimt_metal_dispatch(ZimtMetal *m, void *pipeline,
                        void *const *buffers, const size_t *offsets, const uint32_t *indices, uint32_t nbuffers,
                        const void *bytes, uint32_t nbytes, uint32_t bytes_index,
                        const uint32_t groups[3], const uint32_t threads[3]);

/* Non-blocking; returns the retained command buffer, or NULL if empty. */
void *zimt_metal_commit(ZimtMetal *m);

/* 0: still running; 1: completed; -1: failed (`err` set). Releases on 1 and -1. */
int zimt_metal_finish(void *cmdbuf, int block, char *err, size_t err_len);

#endif
