#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Compare actual Rust PTY snapshots with the native Swift binary decoder.

Linux only: XDG_DATA_HOME isolates the Rust Store and shell integration files.
Never load this harness on macOS, where Store uses the user's Library instead.
Compile NiaScreenDecoder.swift + NiaScreenDecoderTests.swift, then run:

  python3 tests/check_native_snapshot.py --library target/release/libnia_core.so \
      --decoder /tmp/nia-screen-tests [--benchmark]

The core, echo subprocess, logs and all binary/JSON fixtures are temporary.
The optional timings measure Rust serialization, not macOS presentation latency.
"""
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import statistics
import struct
import subprocess
import sys
import tempfile
import time


def configure_library(path):
    library = C.CDLL(str(path))
    signatures = [
        ("nia_core_new", [], C.c_void_p),
        ("nia_core_free", [C.c_void_p], None),
        ("nia_create_session", [C.c_void_p, C.c_char_p], C.c_int),
        ("nia_resize_fast", [C.c_void_p, C.c_char_p, C.c_uint16, C.c_uint16], C.c_int),
        ("nia_send", [C.c_void_p, C.c_char_p, C.c_char_p, C.c_size_t], C.c_int),
        ("nia_poll", [C.c_void_p], None),
        ("nia_maintain", [C.c_void_p], C.c_int),
        ("nia_flush_pending", [C.c_void_p], C.c_int),
        ("nia_screen", [C.c_void_p, C.c_char_p], C.c_void_p),
        ("nia_screen_snapshot", [C.c_void_p, C.c_char_p, C.c_uint64, C.POINTER(C.c_size_t)], C.c_void_p),
        ("nia_snapshot_free", [C.c_void_p, C.c_size_t], None),
        ("nia_string_free", [C.c_void_p], None),
        ("nia_sessions", [C.c_void_p], C.c_void_p),
        ("nia_last_error", [C.c_void_p], C.c_void_p),
        ("nia_scroll", [C.c_void_p, C.c_char_p, C.c_int], C.c_int),
    ]
    for name, arguments, result in signatures:
        function = getattr(library, name)
        function.argtypes = arguments
        function.restype = result
    return library


def run(library_path, decoder_path, benchmark):
    # Store::open and session_base use dirs::data_local_dir on Linux. Set the
    # isolated environment before loading/initializing any Rust core instance.
    with tempfile.TemporaryDirectory(prefix="nia-snapshot-ffi-") as temporary:
        base = Path(temporary)
        echo = base / "test-echo"
        echo.write_text(
            f"#!{sys.executable}\n"
            "import os, tty\n"
            "tty.setraw(0)\n"
            "os.write(1, b'READY')\n"
            "while True:\n"
            "    data = os.read(0, 65536)\n"
            "    if not data or data == bytes([0]): break\n"
            "    os.write(1, data)\n"
        )
        echo.chmod(0o700)
        saved_environment = {key: os.environ.get(key) for key in ("XDG_DATA_HOME", "SHELL")}
        os.environ["XDG_DATA_HOME"] = str(base / "data")
        os.environ["SHELL"] = str(echo)
        core = None
        created = False
        session = b"ffi-snapshot"
        try:
            library = configure_library(library_path)
            core = library.nia_core_new()
            assert core, "Could not create the isolated Rust core"

            def text(function, *arguments):
                pointer = function(*arguments)
                assert pointer, "Rust returned a null JSON/string result"
                try:
                    return C.string_at(pointer)
                finally:
                    library.nia_string_free(pointer)

            def success(status):
                assert status == 0, text(library.nia_last_error, core).decode(errors="replace")

            def send(data):
                success(library.nia_send(core, session, data, len(data)))

            def poll_until(predicate):
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    library.nia_poll(core)
                    frame = json.loads(text(library.nia_screen, core, session))
                    if predicate(frame):
                        return frame
                    time.sleep(0.002)
                raise AssertionError("PTY echo did not reach the expected screen")

            def compare(label, previous=None):
                legacy = text(library.nia_screen, core, session)
                length = C.c_size_t(123)
                pointer = library.nia_screen_snapshot(core, session, 0, C.byref(length))
                assert pointer and length.value >= 32, "Missing complete binary snapshot"
                try:
                    binary = C.string_at(pointer, length.value)
                finally:
                    library.nia_snapshot_free(pointer, length.value)
                assert binary[:4] == b"NIA1", "Wrong wire version"
                revision = struct.unpack_from("<Q", binary, 4)[0]
                assert revision > 0, "Zero revision is reserved"
                if previous is not None:
                    assert revision != previous, f"{label}: a changed screen reused its revision"
                same_length = C.c_size_t(123)
                same = library.nia_screen_snapshot(core, session, revision, C.byref(same_length))
                if same:
                    library.nia_snapshot_free(same, same_length.value)
                    raise AssertionError("An unchanged generation returned another snapshot")
                assert same_length.value == 0, "An unchanged snapshot must clear out_len"
                binary_path = base / f"{label}.bin"
                json_path = base / f"{label}.json"
                binary_path.write_bytes(binary)
                json_path.write_bytes(legacy)
                result = subprocess.run(
                    [str(decoder_path), "--compare", str(binary_path), str(json_path)],
                    capture_output=True, text=True, timeout=30,
                )
                assert result.returncode == 0, result.stdout + result.stderr
                assert "Rust/Swift snapshot equivalence passed" in result.stdout, result.stdout
                print(f"{label}: Rust/Swift equality and revision checks passed", flush=True)
                return revision

            def measure(rows, columns, revision):
                timings = {"JSON": [], "NIA1": [], "unchanged": []}
                binary_size = 0
                for _ in range(80):
                    begin = time.perf_counter_ns()
                    pointer = library.nia_screen(core, session)
                    timings["JSON"].append((time.perf_counter_ns() - begin) / 1e6)
                    assert pointer
                    library.nia_string_free(pointer)
                    length = C.c_size_t(0)
                    begin = time.perf_counter_ns()
                    pointer = library.nia_screen_snapshot(core, session, 0, C.byref(length))
                    timings["NIA1"].append((time.perf_counter_ns() - begin) / 1e6)
                    assert pointer
                    binary_size = length.value
                    library.nia_snapshot_free(pointer, length.value)
                    begin = time.perf_counter_ns()
                    pointer = library.nia_screen_snapshot(core, session, revision, C.byref(length))
                    timings["unchanged"].append((time.perf_counter_ns() - begin) / 1e6)
                    assert not pointer and length.value == 0
                for label, samples in timings.items():
                    samples.sort()
                    print(
                        f"Rust {label} {rows}x{columns}: NIA1 {binary_size} B; "
                        f"median {statistics.median(samples):.4f} ms / p95 {samples[76]:.4f} ms",
                        flush=True,
                    )

            success(library.nia_create_session(core, session))
            created = True
            poll_until(lambda frame: "".join(cell["t"] for cell in frame["cells"][0]).startswith("READY"))
            success(library.nia_resize_fast(core, session, 6, 24))
            send(b"\x1b[2J\x1b[H\x1b[1;2;3;4;7;38;2;1;2;3;48;5;200m"
                 + "é e\u0301 界 👩\u200d💻".encode() + b"\x1b[0m\r\nPLAIN")
            poll_until(lambda frame: "".join(cell["t"] for cell in frame["cells"][1]).startswith("PLAIN"))
            revision = compare("unicode-attributes")
            send(b"\x1b[?25l")
            poll_until(lambda frame: not frame["cursor_visible"])
            revision = compare("hidden-cursor", revision)
            send(b"\x1b[?25h\x1b[2J\x1b[H" + b"w" * 24)
            poll_until(lambda frame: frame["cursor_col"] == 24)
            revision = compare("pending-wrap", revision)
            send(b"\r\n" + b"old row\r\n" * 20 + b"CURRENT")
            poll_until(lambda frame: any("".join(cell["t"] for cell in row).startswith("CURRENT")
                                         for row in frame["cells"]))
            success(library.nia_scroll(core, session, 2))
            revision = compare("scrollback", revision)
            success(library.nia_resize_fast(core, session, 8, 30))
            compare("resized", revision)
            for rows, columns in [(30, 100), (50, 160), (80, 240)]:
                success(library.nia_resize_fast(core, session, rows, columns))
                success(library.nia_scroll(core, session, -1000000))
                send(b"\x1b[2J\x1b[H" + b"a" * (rows * columns - 1))
                poll_until(lambda frame: frame["cells"][rows - 1][columns - 2]["t"] == "a")
                revision = compare(f"grid-{rows}x{columns}")
                if benchmark:
                    measure(rows, columns, revision)
            print("Native snapshot integration: 8 actual Rust/Swift cases passed", flush=True)
        finally:
            if core:
                try:
                    if created:
                        # Exit the isolated raw-echo process through its own input;
                        # do not leave a PTY reader/subprocess after the test.
                        library.nia_send(core, session, b"\x00", 1)
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            library.nia_poll(core)
                            library.nia_maintain(core)
                            records = json.loads(text(library.nia_sessions, core))
                            if records and records[0]["closed"]:
                                break
                            time.sleep(0.01)
                    library.nia_flush_pending(core)
                finally:
                    library.nia_core_free(core)
            for key, value in saved_environment.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True, help="Built Rust Linux cdylib")
    parser.add_argument("--decoder", type=Path, required=True, help="Compiled NiaScreenDecoderTests executable")
    parser.add_argument("--benchmark", action="store_true", help="Also measure Rust snapshot serialization")
    arguments = parser.parse_args()
    if sys.platform != "linux":
        parser.error("Linux only: XDG_DATA_HOME does not isolate the macOS Store; refusing to load the core")
    for path in (arguments.library, arguments.decoder):
        if not path.is_file():
            parser.error(f"Required built file does not exist: {path}")
    run(arguments.library.resolve(), arguments.decoder.resolve(), arguments.benchmark)


if __name__ == "__main__":
    main()
