#!/usr/bin/env python3
"""Add the decodium_rx_core target to a Decodium 4 source tree.

decodium_rx_core is Decodium 4's own file-mode decoder frontend
(utils/jt9.cpp) built as an FT2/FT4/FT8/Q65/MSK144 "helper only" binary:
the same C++ decode workers the Decodium GUI runs, without the legacy
Fortran JT9/JT65 path (not compiled in Decodium 4 any more). The copy gets
an --ft2 option, which the upstream frontend does not expose.

    python3 patch-core.py /path/to/Decodium-4.0-Core-Shannon

Every edit checks its anchor and fails loudly if the source moved on.
"""

import pathlib
import sys

CMAKE_TARGET = """
# --- DecodiumOS: terminal RX decoder core (added by mods/54-decodium-rx) ---
add_executable (decodium_rx_core utils/decodium_rx_core.cpp)
target_sources (decodium_rx_core PRIVATE
  Decoder/decodedtext.cpp
  Detector/FT2DecodeWorker.cpp
  Detector/FT4DecodeWorker.cpp
  Detector/FT8DecodeWorker.cpp
  Detector/LegacyJtDecodeWorker.cpp
  Detector/MSK144DecodeWorker.cpp
  Detector/Q65DecodeWorker.cpp
  )
target_compile_definitions (decodium_rx_core PRIVATE DECODIUM_FTX_HELPER_ONLY)
link_wsjtx_cycle_group (decodium_rx_core wsjt_qt wsjt_cxx wsjt_fort)

# FT2 test-signal generator used by the DecodiumOS build self-test (not shipped).
add_executable (decodium_ft2sim utils/decodium_ft2sim.cpp)
link_wsjtx_cycle_group (decodium_ft2sim wsjt_qt wsjt_cxx wsjt_fort)
"""

EDITS = [
    # FT2 slots are 3.75 s: 45000 samples at 12 kHz.
    ("  int input_sample_count (int mode, double trPeriod)\n  {\n",
     "  int input_sample_count (int mode, double trPeriod)\n  {\n"
     "    if (mode == 2)\n      {\n        return 45000;\n      }\n"),
    ("    QCommandLineOption ft8Option (",
     "    QCommandLineOption ft2Option ({QStringLiteral (\"2\"), QStringLiteral (\"ft2\")},\n"
     "                                  QStringLiteral (\"FT2 mode\"));\n"
     "    QCommandLineOption ft8Option ("),
    ("fst4wHashOption, ft8Option,", "fst4wHashOption, ft8Option, ft2Option,"),
    ("    addMode (parser.isSet (ft8Option), 8);\n",
     "    addMode (parser.isSet (ft8Option), 8);\n    addMode (parser.isSet (ft2Option), 2);\n"),
    # Route FT2 to the native FTx path, where run_native_ftx() calls the
    # FT2 worker (upstream only reaches it from the GUI's shared memory).
    ("    if (params.nmode == 5 || params.nmode == 8 || params.nmode == 66)\n",
     "    if (params.nmode == 2 || params.nmode == 5 || params.nmode == 8 || params.nmode == 66)\n"),
    ('app.setApplicationName (QStringLiteral ("jt9"));',
     'app.setApplicationName (QStringLiteral ("decodium-rx-core"));'),
]


def main():
    root = pathlib.Path(sys.argv[1])
    source = (root / "utils/jt9.cpp").read_text(encoding="utf-8")
    for old, new in EDITS:
        if source.count(old) != 1:
            sys.exit(f"patch-core: anchor not found exactly once: {old.strip()[:60]!r}")
        source = source.replace(old, new)
    (root / "utils/decodium_rx_core.cpp").write_text(source, encoding="utf-8")
    here = pathlib.Path(__file__).resolve().parent
    (root / "utils/decodium_ft2sim.cpp").write_text(
        (here / "decodium_ft2sim.cpp").read_text(encoding="utf-8"), encoding="utf-8")

    cmake = root / "CMakeLists.txt"
    text = cmake.read_text(encoding="utf-8")
    if "decodium_rx_core" not in text:
        if "function (link_wsjtx_cycle_group" not in text and "function(link_wsjtx_cycle_group" not in text:
            sys.exit("patch-core: link_wsjtx_cycle_group() not found in CMakeLists.txt")
        cmake.write_text(text + CMAKE_TARGET, encoding="utf-8")
    print("patch-core: decodium_rx_core target added")


if __name__ == "__main__":
    main()
