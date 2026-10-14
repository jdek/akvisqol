// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Source-compatible with google/visqol visqol_manager.h, except:
//   * Run(AudioSignal) is replaced by Run on spans.
//   * Lattice models run without TFLite; an empty model path selects the embedded default.
//   * RunBatch is an extension.
#ifndef VISQOL_INCLUDE_VISQOL_MANAGER_H
#define VISQOL_INCLUDE_VISQOL_MANAGER_H

#include <cstddef>
#include <memory>
#include <vector>

#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/strings/string_view.h"
#include "absl/types/span.h"
#include "file_path.h"
#include "src/proto/similarity_result.pb.h"

struct visqol_ctx;

namespace Visqol {

class VisqolManager {
 public:
  VisqolManager();
  ~VisqolManager();
  VisqolManager(VisqolManager&&) noexcept;
  VisqolManager& operator=(VisqolManager&&) noexcept;

  absl::Status Init(const FilePath& similarity_to_quality_mapper_model, bool use_speech_mode,
                    bool use_unscaled_speech, int search_window, bool use_lattice_model = true,
                    bool disable_global_alignment = false, bool disable_realignment = false);

  absl::Status Init(absl::string_view similarity_to_quality_mapper_model_string,
                    bool use_speech_mode, bool use_unscaled_speech, int search_window,
                    bool use_lattice_model = true, bool disable_global_alignment = false,
                    bool disable_realignment = false);

  absl::StatusOr<SimilarityResultMsg> Run(const FilePath& ref_signal_path,
                                          const FilePath& deg_signal_path);

  // Mono float64 signals at a shared sample rate.
  absl::StatusOr<SimilarityResultMsg> Run(absl::Span<const double> ref_signal,
                                          absl::Span<const double> deg_signal,
                                          size_t sample_rate);

  // Up to `num_threads` threads (0 = all cores); one result per pair, in input order.
  std::vector<absl::StatusOr<SimilarityResultMsg>> RunBatch(
      const std::vector<ReferenceDegradedPathPair>& pairs, unsigned num_threads = 0);

 private:
  struct CtxDeleter {
    void operator()(visqol_ctx* ctx) const;
  };
  std::unique_ptr<visqol_ctx, CtxDeleter> ctx_;
};

}  // namespace Visqol

#endif  // VISQOL_INCLUDE_VISQOL_MANAGER_H
