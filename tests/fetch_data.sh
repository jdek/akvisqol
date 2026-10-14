#!/bin/sh
# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

# Fetch upstream conformance audio into tests/data, pinned to the revision
# src/conformance_test.zig's constants come from.
set -eu
REV=38d0b0163e441047d4429bf07ad09e5b9031d02c
BASE="https://raw.githubusercontent.com/google/visqol/$REV/testdata"
cd "$(dirname "$0")/.."
while read -r f; do
  [ -z "$f" ] && continue
  [ -f "tests/data/$f" ] && continue
  mkdir -p "tests/data/$(dirname "$f")"
  echo "fetch $f"
  curl -sfL "$BASE/$f" -o "tests/data/$f.part" && mv "tests/data/$f.part" "tests/data/$f"
done <<'LIST'
clean_speech/CA01_01.wav
clean_speech/transcoded_CA01_01.wav
conformance_testdata_subset/strauss48_stereo.wav
conformance_testdata_subset/strauss48_stereo_lp35.wav
conformance_testdata_subset/steely48_stereo.wav
conformance_testdata_subset/steely48_stereo_lp7.wav
conformance_testdata_subset/sopr48_stereo.wav
conformance_testdata_subset/sopr48_stereo_256kbps_aac.wav
conformance_testdata_subset/ravel48_stereo.wav
conformance_testdata_subset/ravel48_stereo_128kbps_opus.wav
conformance_testdata_subset/moonlight48_stereo.wav
conformance_testdata_subset/moonlight48_stereo_128kbps_aac.wav
conformance_testdata_subset/harpsichord48_stereo.wav
conformance_testdata_subset/harpsichord48_stereo_96kbps_mp3.wav
conformance_testdata_subset/guitar48_stereo.wav
conformance_testdata_subset/guitar48_stereo_64kbps_aac.wav
conformance_testdata_subset/glock48_stereo.wav
conformance_testdata_subset/glock48_stereo_48kbps_aac.wav
conformance_testdata_subset/contrabassoon48_stereo.wav
conformance_testdata_subset/contrabassoon48_stereo_24kbps_aac.wav
conformance_testdata_subset/castanets48_stereo.wav
short_duration/5_second/guitar48_stereo_5_sec.wav
alignment/reference.wav
alignment/degraded.wav
LIST
