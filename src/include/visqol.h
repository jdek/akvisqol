// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

/* ViSQOL C ABI. Functions return VISQOL_OK (0) or a negative error code;
 * visqol_last_error() gives the calling thread's last failure message.
 * A visqol_ctx is single-threaded; visqol_measure_batch fans out internally.
 */
#ifndef VISQOL_H
#define VISQOL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VISQOL_ABI_VERSION 1

enum {
    VISQOL_OK = 0,
    VISQOL_E_INVALID_ARGUMENT = -1,
    VISQOL_E_OUT_OF_MEMORY = -2,
    VISQOL_E_IO = -3,
    VISQOL_E_MODEL = -4,
    VISQOL_E_SIGNAL = -5,
    VISQOL_E_BACKEND = -6,
    VISQOL_E_INTERNAL = -7, /* unclassified failure: a bug, please report */
};

enum { VISQOL_MODE_AUDIO = 0, VISQOL_MODE_SPEECH = 1 };

enum {
    VISQOL_BACKEND_CPU = 0,
    VISQOL_BACKEND_METAL = 1,
    VISQOL_BACKEND_CUDA = 2,
    VISQOL_BACKEND_VULKAN = 3,
};

typedef struct {
    uint32_t mode;                       /* VISQOL_MODE_* */
    int32_t search_window_radius;        /* <= 0 → 60 */
    uint8_t use_unscaled_speech_mos_mapping;
    uint8_t disable_global_alignment;
    uint8_t disable_realignment;
    uint8_t use_lattice_model;           /* speech: lattice vs exponential mapping */
    /* SVR model (audio) or lattice model (speech + use_lattice_model);
     * NULL or "" → embedded default. */
    const char *model_path;
    uint32_t backend;                    /* VISQOL_BACKEND_* */
    uint32_t _reserved1;
} visqol_options;

typedef struct {
    double similarity;
    double ref_patch_start_time;
    double ref_patch_end_time;
    double deg_patch_start_time;
    double deg_patch_end_time;
    const double *freq_band_means;       /* num_bands entries each */
    const double *freq_band_stddevs;
    const double *freq_band_deg_energy;
} visqol_patch;

typedef struct {
    double moslqo;
    double vnsim;
    double alignment_lag_s;
    size_t num_bands;
    const double *fvnsim;
    const double *fvnsim10;
    const double *fstdnsim;
    const double *fvdegenergy;
    const double *center_freq_bands;
    size_t num_patches;
    const visqol_patch *patch_sims;
} visqol_result;

typedef struct visqol_ctx visqol_ctx;

uint32_t visqol_abi_version(void);
const char *visqol_version(void);
const char *visqol_last_error(void);
/* Bitmask of (1 << VISQOL_BACKEND_*) available on this machine. */
uint32_t visqol_available_backends(void);

void visqol_options_default(visqol_options *opts);

int visqol_create(const visqol_options *opts, visqol_ctx **out);
void visqol_destroy(visqol_ctx *ctx);

/* Score mono float64 signals at a shared sample rate. */
int visqol_measure(visqol_ctx *ctx,
                   const double *ref, size_t ref_len,
                   const double *deg, size_t deg_len,
                   uint32_t sample_rate,
                   visqol_result **out);

/* Score two WAV files (down-mixed to mono). */
int visqol_measure_files(visqol_ctx *ctx, const char *ref_path,
                         const char *deg_path, visqol_result **out);

/* Score n pairs on up to num_threads threads (0 → all cores). On failure
 * out[i] is NULL and status[i] (if non-NULL) holds its error. */
int visqol_measure_batch(visqol_ctx *ctx, size_t n,
                         const double *const *refs, const size_t *ref_lens,
                         const double *const *degs, const size_t *deg_lens,
                         uint32_t sample_rate, uint32_t num_threads,
                         visqol_result **out, int32_t *status);

/* Batched visqol_measure_files; per-pair failures land in status[i]. */
int visqol_measure_files_batch(visqol_ctx *ctx, size_t n,
                               const char *const *ref_paths,
                               const char *const *deg_paths,
                               uint32_t num_threads,
                               visqol_result **out, int32_t *status);

void visqol_result_free(visqol_result *result);

#ifdef __cplusplus
}
#endif

#endif /* VISQOL_H */
