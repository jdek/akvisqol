// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

#include "tflite_quality_mapper.h"

namespace Visqol {

TFLiteQualityMapper::TFLiteQualityMapper(absl::string_view, int) {}

absl::Status TFLiteQualityMapper::Init() {
  return absl::UnimplementedError(
      "lattice model not built into this benchmark (TFLite stubbed)");
}

double TFLiteQualityMapper::PredictQuality(const std::vector<double>&,
                                           const std::vector<double>&,
                                           const std::vector<double>&,
                                           const std::vector<double>&) const {
  return 0.0;
}

}  // namespace Visqol
