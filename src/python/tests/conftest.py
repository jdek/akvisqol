# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

import os
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
TESTDATA = Path(os.environ.get("VISQOL_TESTDATA", REPO / "tests" / "data"))


@pytest.fixture
def testdata():
    if not (TESTDATA / "clean_speech" / "CA01_01.wav").is_file():
        pytest.skip("conformance audio missing; run tests/fetch_data.sh")
    return TESTDATA
