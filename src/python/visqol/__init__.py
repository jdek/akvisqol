# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

"""ViSQOL (Zig implementation) with drop-in APIs for existing users.

google/visqol's Python API:

    from visqol import visqol_lib_py
    from visqol.pb2 import visqol_config_pb2, similarity_result_pb2

visqol-python's API (and its `visqol` command line):

    from visqol import VisqolApi
"""

from ._native import __version__, available_backends
from .api import AudioSignal, PatchSimilarityResult, ProgressCallback, SimilarityResult, VisqolApi

__all__ = [
    "AudioSignal",
    "PatchSimilarityResult",
    "ProgressCallback",
    "SimilarityResult",
    "VisqolApi",
    "__version__",
    "available_backends",
]
