// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Upstream conformance values through the C++ API. Skipped without tests/data/
// (tests/fetch_data.sh).
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>

#include "visqol_api.h"
#include "visqol_manager.h"

namespace {

int failures = 0;

#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
      ++failures;                                                         \
    }                                                                     \
  } while (0)

constexpr double kTolerance = 1e-4;  // upstream CONFORMANCE_TOLERANCE

struct Case {
  const char* ref;
  const char* deg;
  double mos;
};

const Case kAudio[] = {
    {"strauss48_stereo.wav", "strauss48_stereo_lp35.wav", 1.3888791489130758},
    {"steely48_stereo.wav", "steely48_stereo_lp7.wav", 2.2501683734385183},
    {"guitar48_stereo.wav", "guitar48_stereo_64kbps_aac.wav", 4.349722308064298},
    {"castanets48_stereo.wav", "castanets48_stereo.wav", 4.732101253042348},
};

void TestApiErrors() {
  Visqol::VisqolApi api;
  CHECK(!api.Create(Visqol::VisqolConfig()).ok());
  Visqol::VisqolConfig config;
  config.mutable_audio()->set_sample_rate(44100);
  CHECK(api.Create(config).code() == absl::StatusCode::kInvalidArgument);
  config.mutable_options()->set_allow_unsupported_sample_rates(true);
  CHECK(api.Create(config).ok());

  Visqol::VisqolManager uninit;
  CHECK(uninit.Run(Visqol::FilePath("a.wav"), Visqol::FilePath("b.wav")).status().code() ==
        absl::StatusCode::kFailedPrecondition);
  Visqol::VisqolManager lattice;
  CHECK(lattice.Init(Visqol::FilePath(""), true, false, 60, true).ok());
  Visqol::VisqolManager missing;
  CHECK(missing.Init(Visqol::FilePath("missing.tflite"), true, false, 60, true).code() ==
        absl::StatusCode::kNotFound);
}

void TestApiSine() {
  Visqol::VisqolConfig config;
  config.mutable_audio()->set_sample_rate(48000);
  Visqol::VisqolApi api;
  CHECK(api.Create(config).ok());
  std::vector<double> ref(48000 * 2), deg(ref.size());
  for (size_t i = 0; i < ref.size(); ++i) {
    ref[i] = std::sin(1000.0 * static_cast<double>(i) / static_cast<double>(ref.size()));
    deg[i] = ref[i] + 0.1 * std::sin(0.37 * static_cast<double>(i));
  }
  auto r = api.Measure(absl::MakeSpan(ref), absl::MakeSpan(deg));
  CHECK(r.ok());
  if (r.ok()) {
    CHECK(r->moslqo() >= 1.0 && r->moslqo() <= 5.0);
    CHECK(r->fvnsim_size() == 32 && r->center_freq_bands_size() == 32);
    CHECK(r->patch_sims_size() > 0 && r->patch_sims(0).freq_band_means_size() == 32);
  }
}

void TestConformance(const std::string& dir) {
  Visqol::VisqolManager m;
  CHECK(m.Init(Visqol::FilePath(""), false, false, 60).ok());
  std::vector<Visqol::ReferenceDegradedPathPair> pairs;
  for (const Case& c : kAudio) {
    Visqol::FilePath ref(dir + "/conformance_testdata_subset/" + c.ref);
    Visqol::FilePath deg(dir + "/conformance_testdata_subset/" + c.deg);
    auto r = m.Run(ref, deg);
    CHECK(r.ok() && std::fabs(r->moslqo() - c.mos) < kTolerance);
    CHECK(r.ok() && r->reference_filepath() == ref.Path());
    pairs.push_back({ref, deg});
  }
  pairs.push_back({Visqol::FilePath(dir + "/missing.wav"), pairs[0].degraded});
  auto batch = m.RunBatch(pairs, 2);
  CHECK(batch.size() == pairs.size());
  for (size_t i = 0; i + 1 < batch.size(); ++i) {
    CHECK(batch[i].ok() && std::fabs(batch[i]->moslqo() - kAudio[i].mos) < kTolerance);
  }
  CHECK(!batch.back().ok());

  Visqol::VisqolManager speech;
  CHECK(speech.Init(Visqol::FilePath(""), true, false, 60, /*use_lattice_model=*/false).ok());
  auto s = speech.Run(Visqol::FilePath(dir + "/clean_speech/CA01_01.wav"),
                      Visqol::FilePath(dir + "/clean_speech/transcoded_CA01_01.wav"));
  CHECK(s.ok() && std::fabs(s->moslqo() - 3.374505555111911) < kTolerance);

  Visqol::VisqolManager lattice;
  CHECK(lattice.Init(Visqol::FilePath(""), true, false, 60, /*use_lattice_model=*/true).ok());
  auto l = lattice.Run(Visqol::FilePath(dir + "/clean_speech/CA01_01.wav"),
                       Visqol::FilePath(dir + "/clean_speech/transcoded_CA01_01.wav"));
  CHECK(l.ok() && std::fabs(l->moslqo() - 3.3129234313964844) < kTolerance);
}

}  // namespace

int main() {
  TestApiErrors();
  TestApiSine();
  const char* env = std::getenv("VISQOL_TESTDATA");
  const std::string dir = env ? env : "tests/data";
  if (std::filesystem::exists(dir + "/clean_speech/CA01_01.wav")) {
    TestConformance(dir);
  } else {
    std::fprintf(stderr, "conformance audio missing (%s); skipped\n", dir.c_str());
  }
  if (failures) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  std::puts("visqol_cpp_test: OK");
  return 0;
}
