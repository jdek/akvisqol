// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Source-compatible with google/visqol src/include/file_path.h.
#ifndef VISQOL_INCLUDE_FILEPATH_H
#define VISQOL_INCLUDE_FILEPATH_H

#include <filesystem>
#include <string>

#include "absl/strings/string_view.h"

namespace Visqol {

class FilePath {
 public:
  FilePath() {}
  FilePath(const FilePath& other) { path_ = other.path_; }
  FilePath(absl::string_view path) { path_ = std::filesystem::path(std::string(path)).string(); }

  const std::string Path() const { return path_; }
  bool Exists() const { return std::filesystem::exists(path_); }
  static std::string currentWorkingDir() { return std::filesystem::current_path().string(); }

 private:
  std::string path_;
};

struct ReferenceDegradedPathPair {
  FilePath reference;
  FilePath degraded;
};

}  // namespace Visqol

#endif  // VISQOL_INCLUDE_FILEPATH_H
