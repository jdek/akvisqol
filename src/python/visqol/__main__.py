# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

"""`visqol` / `python -m visqol`: visqol-python compatible command line."""

from __future__ import annotations

import argparse
import logging
import sys

from .api import VisqolApi

logger = logging.getLogger("visqol")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="visqol",
        description="ViSQOL - Virtual Speech Quality Objective Listener",
    )
    parser.add_argument("--reference", required=True, help="Path to reference audio file (WAV)")
    parser.add_argument("--degraded", required=True, help="Path to degraded audio file (WAV)")
    parser.add_argument("--speech_mode", action="store_true",
                        help="Use speech mode (16 kHz, exponential mapping)")
    parser.add_argument("--model", default=None, help="Path to SVR model file (Audio mode only)")
    parser.add_argument("--search_window", type=int, default=60, help="Search window radius (default: 60)")
    parser.add_argument("--unscaled_speech", action="store_true", help="Don't scale speech MOS to max 5.0")
    parser.add_argument("--no_lattice_model", action="store_true",
                        help="Speech mode: use the polynomial mapping instead of the TFLite lattice "
                             "model")
    parser.add_argument("--lattice_model", default=None,
                        help="Path to lattice .tflite model (speech mode, optional override)")
    parser.add_argument("--no_alignment", action="store_true", help="Disable global alignment")
    parser.add_argument("--no_realignment", action="store_true", help="Disable fine realignment")
    parser.add_argument("--backend", default=None, help="Compute backend: cpu, metal, cuda (extension)")
    parser.add_argument("--verbose", "-v", action="store_true", help="Enable verbose output")
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING,
                        format="%(levelname)s: %(message)s", stream=sys.stderr)
    try:
        api = VisqolApi()
        api.create(
            mode="speech" if args.speech_mode else "audio",
            model_path=args.model,
            search_window=args.search_window,
            use_unscaled_speech=args.unscaled_speech,
            use_lattice_model=False if args.no_lattice_model else None,
            lattice_model_path=args.lattice_model,
            disable_global_alignment=args.no_alignment,
            disable_realignment=args.no_realignment,
            backend=args.backend,
        )
        result = api.measure(args.reference, args.degraded)
    except (FileNotFoundError, ImportError, ValueError, RuntimeError) as exc:
        logger.error("%s", exc)
        sys.exit(1)

    print(f"MOS-LQO:      {result.moslqo:.6f}")
    print(f"VNSIM:        {result.vnsim:.6f}")
    if args.verbose:
        logger.info("FVNSIM:       %s", result.fvnsim)
        logger.info("FVNSIM10:     %s", result.fvnsim10)
        logger.info("FSTDNSIM:     %s", result.fstdnsim)
        logger.info("FVDEGENERGY:  %s", result.fvdegenergy)
        logger.info("Patches:      %d", len(result.patch_sims))
        for i, p in enumerate(result.patch_sims):
            logger.info("  Patch %d: sim=%.4f ref=[%.3f-%.3f] deg=[%.3f-%.3f]", i, p.similarity,
                        p.ref_patch_start_time, p.ref_patch_end_time,
                        p.deg_patch_start_time, p.deg_patch_end_time)


if __name__ == "__main__":
    main()
