// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Source-compatible with google/visqol visqol_api.h; see visqol_manager.h for differences.
#ifndef VISQOL_INCLUDE_VISQOL_API_H
#define VISQOL_INCLUDE_VISQOL_API_H

#include <cstddef>
#include <string>

#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/types/span.h"
#include "src/proto/similarity_result.pb.h"
#include "src/proto/visqol_config.pb.h"
#include "visqol_manager.h"

namespace Visqol {

class VisqolApi {
 public:
  static const size_t k48kSampleRate;

  absl::Status Create(const VisqolConfig config);

  absl::StatusOr<SimilarityResultMsg> Measure(const absl::Span<double>& reference,
                                              const absl::Span<double>& degraded);

 private:
  Visqol::VisqolManager visqol_;
  size_t sample_rate_ = 0;
};

}  // namespace Visqol

#endif  // VISQOL_INCLUDE_VISQOL_API_H
