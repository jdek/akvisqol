// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Timing driver for Google's C++ ViSQOL, matching the Zig CLI's batch mode:
//
//   visqol_google_bench --batch_input_csv PAIRS.csv [--results_csv OUT.csv]
//       [--threads N] [--use_speech_mode] [--use_lattice_model]
//       [--use_unscaled_speech_mos_mapping]
//       [--similarity_to_quality_model F] [--search_window_radius N]
//
// One VisqolManager per worker thread. Speech mode uses the exponential fit
// unless --use_lattice_model (upstream's CLI defaults to lattice). Wall time,
// including model load and WAV decoding, goes to stderr.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "file_path.h"
#include "src/proto/similarity_result.pb.h"
#include "visqol_manager.h"

#ifndef VISQOL_DEFAULT_LATTICE_MODEL
#define VISQOL_DEFAULT_LATTICE_MODEL ""
#endif

namespace {

struct Pair {
  std::string ref, deg;
};

struct Outcome {
  bool ok = false;
  double moslqo = 0.0;
  std::string error;
};

std::string Trim(const std::string& s) {
  const auto b = s.find_first_not_of(" \t\r\n");
  if (b == std::string::npos) return "";
  const auto e = s.find_last_not_of(" \t\r\n");
  return s.substr(b, e - b + 1);
}

std::vector<Pair> ReadPairs(const std::string& path) {
  std::ifstream in(path);
  if (!in) {
    std::cerr << "cannot open " << path << "\n";
    std::exit(2);
  }
  std::vector<Pair> pairs;
  std::string line;
  bool header = true;
  while (std::getline(in, line)) {
    line = Trim(line);
    if (line.empty()) continue;
    if (header) {
      header = false;
      if (line.rfind("reference", 0) == 0) continue;
    }
    const auto comma = line.find(',');
    if (comma == std::string::npos) {
      std::cerr << "bad CSV line: " << line << "\n";
      std::exit(2);
    }
    pairs.push_back({Trim(line.substr(0, comma)), Trim(line.substr(comma + 1))});
  }
  return pairs;
}

void Usage() {
  std::cerr << "usage: visqol_google_bench --batch_input_csv PAIRS.csv "
               "[--results_csv OUT.csv] [--threads N (0 = all cores)] "
               "[--use_speech_mode] [--use_lattice_model] [--use_unscaled_speech_mos_mapping] "
               "[--similarity_to_quality_model F] [--search_window_radius N]\n";
  std::exit(2);
}

}  // namespace

int main(int argc, char** argv) {
  std::string csv, results, model;
  unsigned threads = 1;
  bool speech = false, unscaled = false, lattice = false;
  int search_window = 60;
  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    auto value = [&]() -> std::string {
      if (i + 1 >= argc) Usage();
      return argv[++i];
    };
    if (a == "--batch_input_csv") csv = value();
    else if (a == "--results_csv") results = value();
    else if (a == "--threads") threads = static_cast<unsigned>(std::stoul(value()));
    else if (a == "--similarity_to_quality_model") model = value();
    else if (a == "--search_window_radius") search_window = std::stoi(value());
    else if (a == "--use_speech_mode") speech = true;
    else if (a == "--use_lattice_model") lattice = true;
    else if (a == "--use_unscaled_speech_mos_mapping") unscaled = true;
    else Usage();
  }
  if (csv.empty()) Usage();
  lattice = lattice && speech;
  if (model.empty()) model = lattice ? VISQOL_DEFAULT_LATTICE_MODEL : VISQOL_DEFAULT_MODEL;
  if (threads == 0) threads = std::max(1u, std::thread::hardware_concurrency());

  const std::vector<Pair> pairs = ReadPairs(csv);
  std::vector<Outcome> outcomes(pairs.size());
  std::atomic<size_t> next{0};

  const auto t0 = std::chrono::steady_clock::now();
  auto worker = [&]() {
    Visqol::VisqolManager manager;
    const absl::Status init =
        manager.Init(Visqol::FilePath(model), speech, unscaled, search_window, lattice);
    for (size_t i; (i = next.fetch_add(1)) < pairs.size();) {
      Outcome& o = outcomes[i];
      if (!init.ok()) {
        o.error = std::string(init.message());
        continue;
      }
      const auto r = manager.Run(Visqol::FilePath(pairs[i].ref), Visqol::FilePath(pairs[i].deg));
      if (r.ok()) {
        o.ok = true;
        o.moslqo = r->moslqo();
      } else {
        o.error = std::string(r.status().message());
      }
    }
  };
  std::vector<std::thread> pool;
  for (unsigned t = 1; t < std::min<size_t>(threads, pairs.size()); ++t) pool.emplace_back(worker);
  worker();
  for (auto& t : pool) t.join();
  const double secs =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();

  std::ofstream out;
  if (!results.empty()) {
    out.open(results);
    out << "reference,degraded,moslqo\n";
    out.precision(17);  // round-trips a double
  }
  int failed = 0;
  for (size_t i = 0; i < pairs.size(); ++i) {
    const Outcome& o = outcomes[i];
    if (o.ok) {
      std::printf("%s %s MOS-LQO: %.6f\n", pairs[i].ref.c_str(), pairs[i].deg.c_str(), o.moslqo);
      if (out) out << pairs[i].ref << "," << pairs[i].deg << "," << o.moslqo << "\n";
    } else {
      ++failed;
      std::fprintf(stderr, "%s %s ERROR: %s\n", pairs[i].ref.c_str(), pairs[i].deg.c_str(),
                   o.error.c_str());
    }
  }
  std::fprintf(stderr, "visqol_google_bench: %zu pairs, %u thread(s), %.3f s\n", pairs.size(), threads,
               secs);
  return failed ? 1 : 0;
}
