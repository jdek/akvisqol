// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Stub TFLite lattice mapper for builds without TensorFlow; Init() returns UNIMPLEMENTED.
#ifndef THIRD_PARTY_VISQOL_SRC_INCLUDE_TFLITE_QUALITY_MAPPER_H_
#define THIRD_PARTY_VISQOL_SRC_INCLUDE_TFLITE_QUALITY_MAPPER_H_

#include <string>
#include <vector>

#include "absl/status/status.h"
#include "absl/strings/string_view.h"
#include "similarity_to_quality_mapper.h"

namespace Visqol {

class TFLiteQualityMapper : public SimilarityToQualityMapper {
 public:
  TFLiteQualityMapper(absl::string_view model_path, int num_frequency_bands);
  absl::Status Init() override;
  double PredictQuality(const std::vector<double>& fvnsim_vector,
                        const std::vector<double>& fvnsim10_vector,
                        const std::vector<double>& fstdnsim_vector,
                        const std::vector<double>& fvdegenergy_vector) const override;
};

}  // namespace Visqol

#endif
