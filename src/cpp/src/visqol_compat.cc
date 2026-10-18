// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// google/visqol C++ API (VisqolApi, VisqolManager) over libvisqol's C ABI.
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#include "absl/strings/str_cat.h"
#include "visqol.h"
#include "visqol_api.h"
#include "visqol_manager.h"

namespace Visqol {
namespace {

absl::Status FromCode(int rc, absl::string_view context = "") {
  if (rc == VISQOL_OK) return absl::OkStatus();
  std::string msg = visqol_last_error();
  if (!context.empty()) msg = absl::StrCat(context, ": ", msg);
  switch (rc) {
    case VISQOL_E_INVALID_ARGUMENT:
    case VISQOL_E_SIGNAL:
      return absl::InvalidArgumentError(msg);
    case VISQOL_E_IO:
      return absl::NotFoundError(msg);
    case VISQOL_E_OUT_OF_MEMORY:
      return absl::ResourceExhaustedError(msg);
    case VISQOL_E_BACKEND:
      return absl::UnavailableError(msg);
    default:
      return absl::InternalError(msg);
  }
}

// VISQOL_BACKEND=cpu|metal|cuda|vulkan; unknown values select CPU.
uint32_t BackendFromEnv() {
  const char* b = std::getenv("VISQOL_BACKEND");
  if (b == nullptr) return VISQOL_BACKEND_CPU;
  if (std::strcmp(b, "metal") == 0) return VISQOL_BACKEND_METAL;
  if (std::strcmp(b, "cuda") == 0) return VISQOL_BACKEND_CUDA;
  if (std::strcmp(b, "vulkan") == 0) return VISQOL_BACKEND_VULKAN;
  return VISQOL_BACKEND_CPU;
}

// Copies a libvisqol result into the proto and frees it.
SimilarityResultMsg ToMsg(visqol_result* r) {
  SimilarityResultMsg msg;
  const size_t nb = r->num_bands;
  msg.set_moslqo(r->moslqo);
  msg.set_vnsim(r->vnsim);
  msg.set_alignment_lag_s(r->alignment_lag_s);
  msg.mutable_fvnsim()->Add(r->fvnsim, r->fvnsim + nb);
  msg.mutable_fvnsim10()->Add(r->fvnsim10, r->fvnsim10 + nb);
  msg.mutable_fstdnsim()->Add(r->fstdnsim, r->fstdnsim + nb);
  msg.mutable_fvdegenergy()->Add(r->fvdegenergy, r->fvdegenergy + nb);
  msg.mutable_center_freq_bands()->Add(r->center_freq_bands, r->center_freq_bands + nb);
  for (size_t i = 0; i < r->num_patches; ++i) {
    const visqol_patch& p = r->patch_sims[i];
    auto* pm = msg.add_patch_sims();
    pm->set_similarity(p.similarity);
    pm->mutable_freq_band_means()->Add(p.freq_band_means, p.freq_band_means + nb);
    pm->set_ref_patch_start_time(p.ref_patch_start_time);
    pm->set_ref_patch_end_time(p.ref_patch_end_time);
    pm->set_deg_patch_start_time(p.deg_patch_start_time);
    pm->set_deg_patch_end_time(p.deg_patch_end_time);
  }
  visqol_result_free(r);
  return msg;
}

}  // namespace

void VisqolManager::CtxDeleter::operator()(visqol_ctx* ctx) const { visqol_destroy(ctx); }

VisqolManager::VisqolManager() = default;
VisqolManager::~VisqolManager() = default;
VisqolManager::VisqolManager(VisqolManager&&) noexcept = default;
VisqolManager& VisqolManager::operator=(VisqolManager&&) noexcept = default;

absl::Status VisqolManager::Init(const FilePath& similarity_to_quality_mapper_model,
                                 bool use_speech_mode, bool use_unscaled_speech, int search_window,
                                 bool use_lattice_model, bool disable_global_alignment,
                                 bool disable_realignment) {
  visqol_options opts;
  visqol_options_default(&opts);
  opts.mode = use_speech_mode ? VISQOL_MODE_SPEECH : VISQOL_MODE_AUDIO;
  opts.search_window_radius = search_window;
  opts.use_unscaled_speech_mos_mapping = use_unscaled_speech;
  opts.disable_global_alignment = disable_global_alignment;
  opts.disable_realignment = disable_realignment;
  // Audio mode ignores the flag, as upstream.
  opts.use_lattice_model = use_speech_mode && use_lattice_model;
  const std::string model = similarity_to_quality_mapper_model.Path();
  opts.model_path = model.empty() ? nullptr : model.c_str();
  opts.backend = BackendFromEnv();
  visqol_ctx* ctx = nullptr;
  if (absl::Status s = FromCode(visqol_create(&opts, &ctx)); !s.ok()) return s;
  ctx_.reset(ctx);
  return absl::OkStatus();
}

absl::Status VisqolManager::Init(absl::string_view similarity_to_quality_mapper_model_string,
                                 bool use_speech_mode, bool use_unscaled_speech, int search_window,
                                 bool use_lattice_model, bool disable_global_alignment,
                                 bool disable_realignment) {
  return Init(FilePath(similarity_to_quality_mapper_model_string), use_speech_mode,
              use_unscaled_speech, search_window, use_lattice_model, disable_global_alignment,
              disable_realignment);
}

absl::StatusOr<SimilarityResultMsg> VisqolManager::Run(const FilePath& ref_signal_path,
                                                       const FilePath& deg_signal_path) {
  if (!ctx_) return absl::FailedPreconditionError("VisqolManager must be initialized before use.");
  const std::string ref = ref_signal_path.Path(), deg = deg_signal_path.Path();
  visqol_result* r = nullptr;
  if (absl::Status s = FromCode(visqol_measure_files(ctx_.get(), ref.c_str(), deg.c_str(), &r));
      !s.ok())
    return s;
  SimilarityResultMsg msg = ToMsg(r);
  msg.set_reference_filepath(ref);
  msg.set_degraded_filepath(deg);
  return msg;
}

absl::StatusOr<SimilarityResultMsg> VisqolManager::Run(absl::Span<const double> ref_signal,
                                                       absl::Span<const double> deg_signal,
                                                       size_t sample_rate) {
  if (!ctx_) return absl::FailedPreconditionError("VisqolManager must be initialized before use.");
  visqol_result* r = nullptr;
  if (absl::Status s = FromCode(visqol_measure(ctx_.get(), ref_signal.data(), ref_signal.size(),
                                               deg_signal.data(), deg_signal.size(),
                                               static_cast<uint32_t>(sample_rate), &r));
      !s.ok())
    return s;
  return ToMsg(r);
}

std::vector<absl::StatusOr<SimilarityResultMsg>> VisqolManager::RunBatch(
    const std::vector<ReferenceDegradedPathPair>& pairs, unsigned num_threads) {
  std::vector<absl::StatusOr<SimilarityResultMsg>> out;
  if (!ctx_) {
    out.assign(pairs.size(),
               absl::FailedPreconditionError("VisqolManager must be initialized before use."));
    return out;
  }
  const size_t n = pairs.size();
  std::vector<std::string> refs(n), degs(n);
  std::vector<const char*> ref_p(n), deg_p(n);
  for (size_t i = 0; i < n; ++i) {
    refs[i] = pairs[i].reference.Path();
    degs[i] = pairs[i].degraded.Path();
    ref_p[i] = refs[i].c_str();
    deg_p[i] = degs[i].c_str();
  }
  std::vector<visqol_result*> results(n, nullptr);
  std::vector<int32_t> status(n, VISQOL_OK);
  visqol_measure_files_batch(ctx_.get(), n, ref_p.data(), deg_p.data(), num_threads,
                             results.data(), status.data());
  out.reserve(n);
  for (size_t i = 0; i < n; ++i) {
    if (status[i] != VISQOL_OK) {
      out.emplace_back(FromCode(status[i], absl::StrCat(refs[i], " vs ", degs[i])));
      continue;
    }
    SimilarityResultMsg msg = ToMsg(results[i]);
    msg.set_reference_filepath(refs[i]);
    msg.set_degraded_filepath(degs[i]);
    out.emplace_back(std::move(msg));
  }
  return out;
}

const size_t VisqolApi::k48kSampleRate = 48000;

absl::Status VisqolApi::Create(const VisqolConfig config) {
  if (!config.has_audio()) {
    return absl::InvalidArgumentError("Audio info must be supplied for config.");
  }
  sample_rate_ = config.audio().sample_rate();
  if (sample_rate_ == 0) {
    return absl::InvalidArgumentError("The sample rate for the signals must be set.");
  }
  bool speech_mode = false, unscaled_speech_map = false, allow_sr_override = false;
  bool use_lattice_model = true;
  int search_window = 60;
  std::string model_file;
  if (config.has_options()) {
    const auto& o = config.options();
    speech_mode = o.use_speech_scoring();
    unscaled_speech_map = o.use_unscaled_speech_mos_mapping();
    allow_sr_override = o.allow_unsupported_sample_rates();
    use_lattice_model = o.use_lattice_model();
    model_file = o.svr_model_path();
    if (o.search_window_radius()) search_window = o.search_window_radius();
  }
  if (sample_rate_ != k48kSampleRate && !speech_mode && !allow_sr_override) {
    return absl::InvalidArgumentError(
        "Currently, 48k is the only sample rate supported by ViSQOL Audio. "
        "See README for details of overriding.");
  }
  return visqol_.Init(FilePath(model_file), speech_mode, unscaled_speech_map, search_window,
                      use_lattice_model);
}

absl::StatusOr<SimilarityResultMsg> VisqolApi::Measure(const absl::Span<double>& reference,
                                                       const absl::Span<double>& degraded) {
  return visqol_.Run(absl::Span<const double>(reference), absl::Span<const double>(degraded),
                     sample_rate_);
}

}  // namespace Visqol
