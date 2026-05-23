#!/usr/bin/env python3
"""Run one approval-test binary on an already-programmed FPGA and compare it.

Example:

    python3 scripts/run_fpga_compare.py tests/grade3/g3_test1.s --port /dev/ttyUSB1

The script expects scripts/build_bins.py to have generated the matching artifact
directory.  It reruns Spike on the generated ELF for the reference byte stream,
sends the generated BIN to the FPGA over the existing UART frame protocol, and
compares the FPGA UART payload with the Spike MMIO output.
"""

from __future__ import annotations

import argparse
import atexit
import json
from pathlib import Path
import struct
import sys
import time
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from build_bins import (  # noqa: E402
    BuildError,
    DEFAULT_GCC,
    DEFAULT_OBJCOPY,
    SPIKE_MEM,
    TEST_SPECS,
    UART_MMIO,
    artifact_dir_for_source,
    build_one,
    find_tool,
    isa_for_test,
    run_spike_expected,
    test_name_from_path,
)


RESP_CMD = 0x02
STATUS_NAMES = {
    0x00: "OK",
    0x01: "TIMEOUT",
    0x02: "RANGE_ERR",
    0x03: "UNSUPPORTED_CMD",
    0xFF: "CHECKSUM_ERR",
}

_TTY_FD: int | None = None
_TTY_ATTRS: list[Any] | None = None


def remember_tty_state() -> None:
    """Remember interactive stdin settings so they can be restored on exit."""

    global _TTY_FD, _TTY_ATTRS
    if not sys.stdin.isatty():
        return
    try:
        import termios

        _TTY_FD = sys.stdin.fileno()
        _TTY_ATTRS = termios.tcgetattr(_TTY_FD)
    except Exception:
        _TTY_FD = None
        _TTY_ATTRS = None


def restore_tty_state() -> None:
    if _TTY_FD is None or _TTY_ATTRS is None:
        return
    try:
        import termios

        termios.tcsetattr(_TTY_FD, termios.TCSANOW, _TTY_ATTRS)
    except Exception:
        pass


class CompareError(RuntimeError):
    """Raised when the FPGA result cannot be accepted."""


def calc_checksum(cmd: int, addr_le: bytes, len_le: bytes, data: bytes) -> int:
    chk = cmd & 0xFF
    for b in addr_le:
        chk ^= b
    for b in len_le:
        chk ^= b
    for b in data:
        chk ^= b
    return chk & 0xFF


def build_frame(addr: int, data: bytes) -> bytes:
    cmd = 0x01
    addr_le = struct.pack("<I", addr)
    len_le = struct.pack("<I", len(data))
    chk = calc_checksum(cmd, addr_le, len_le, data)
    return bytes([cmd]) + addr_le + len_le + data + bytes([chk])


def decode_ascii(data: bytes) -> str:
    return "".join(chr(b) if 0x20 <= b <= 0x7E else "." for b in data)


def find_response_frame(rx: bytes, min_index: int = 0) -> tuple[int, int, int] | None:
    """Return (start_index, status, checksum) for the last valid response."""

    found: tuple[int, int, int] | None = None
    for idx in range(0, max(0, len(rx) - 2)):
        if idx < min_index:
            continue
        if rx[idx] != RESP_CMD:
            continue
        status = rx[idx + 1]
        chk = rx[idx + 2]
        if chk == (RESP_CMD ^ status):
            found = (idx, status, chk)
    return found


def send_to_fpga(
    bin_path: Path,
    port: str,
    baud: int,
    addr: int,
    timeout_s: float,
    idle_ms: int,
    expected_payload_len: int,
) -> dict[str, Any]:
    try:
        import serial
    except ImportError as exc:  # pragma: no cover - depends on host setup.
        raise CompareError("pyserial is not installed. Run: pip install pyserial") from exc

    data = bin_path.read_bytes()
    if not data:
        raise CompareError(f"Binary is empty: {bin_path}")

    frame = build_frame(addr, data)
    print(
        f"[SEND] {bin_path} size={len(data)} bytes addr=0x{addr:08X} "
        f"frame={len(frame)} bytes",
        flush=True,
    )

    try:
        ser = serial.Serial(port, baud, timeout=0.05)
    except serial.SerialException as exc:
        raise CompareError(f"Could not open serial port {port}: {exc}") from exc

    rx = bytearray()
    try:
        ser.reset_input_buffer()
        ser.reset_output_buffer()
        time.sleep(idle_ms / 1000.0)
        ser.write(frame)
        ser.flush()

        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            chunk = ser.read(256)
            if chunk:
                rx.extend(chunk)
                resp = find_response_frame(bytes(rx), min_index=expected_payload_len)
                if resp is not None:
                    break
            else:
                time.sleep(0.01)
    finally:
        ser.close()

    rx_bytes = bytes(rx)
    response = find_response_frame(rx_bytes, min_index=expected_payload_len)
    if response is None:
        early_response = find_response_frame(rx_bytes)
        early_note = ""
        if early_response is not None:
            early_note = (
                f" Found a response at byte {early_response[0]}, but expected "
                f"at least {expected_payload_len} payload bytes before it."
            )
        raise CompareError(
            f"No valid FPGA response frame within {timeout_s:.1f}s. "
            f"Received {len(rx_bytes)} bytes: {rx_bytes.hex()}.{early_note}"
        )

    resp_idx, status, chk = response
    payload = rx_bytes[:resp_idx]
    return {
        "raw": rx_bytes,
        "payload": payload,
        "status": status,
        "status_name": STATUS_NAMES.get(status, f"UNKNOWN_0x{status:02X}"),
        "checksum": chk,
        "response_index": resp_idx,
    }


def load_metadata(source: Path) -> dict[str, Any]:
    metadata_path = artifact_dir_for_source(source) / "metadata.json"
    if not metadata_path.exists():
        raise CompareError(
            f"Missing metadata: {metadata_path}\n"
            f"Run: python3 {SCRIPT_DIR / 'build_bins.py'} --test {source}"
        )
    return json.loads(metadata_path.read_text(encoding="utf-8"))


def ensure_artifacts(source: Path, args: argparse.Namespace) -> dict[str, Any]:
    metadata_path = artifact_dir_for_source(source) / "metadata.json"
    if metadata_path.exists() and not args.rebuild:
        return load_metadata(source)

    gcc = args.gcc or find_tool("RISCV_GCC", DEFAULT_GCC, "riscv64-unknown-elf-gcc")
    objcopy = args.objcopy or find_tool(
        "RISCV_OBJCOPY", DEFAULT_OBJCOPY, "riscv64-unknown-elf-objcopy"
    )
    spike = args.spike or find_tool("SPIKE", Path("/usr/bin/spike"), "spike")
    result = build_one(
        source=source,
        gcc=gcc,
        objcopy=objcopy,
        spike=spike,
        run_spike=True,
        timeout_s=args.spike_timeout,
    )
    print(f"[BUILD] Rebuilt artifacts in {result['artifact_dir']}")
    return load_metadata(source)


def compare_bytes(expected: bytes, actual: bytes) -> None:
    if expected == actual:
        return

    first_mismatch: str
    limit = min(len(expected), len(actual))
    mismatch_idx = None
    for idx in range(limit):
        if expected[idx] != actual[idx]:
            mismatch_idx = idx
            break

    if mismatch_idx is None:
        first_mismatch = f"length differs expected={len(expected)} actual={len(actual)}"
    else:
        first_mismatch = (
            f"byte {mismatch_idx}: expected=0x{expected[mismatch_idx]:02X} "
            f"actual=0x{actual[mismatch_idx]:02X}"
        )

    raise CompareError(
        "FPGA payload does not match Spike output: "
        f"{first_mismatch}\n"
        f"expected({len(expected)}): {expected.hex()}\n"
        f"actual  ({len(actual)}): {actual.hex()}"
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare an FPGA UART test run against Spike reference output."
    )
    parser.add_argument("test", help="Path to the original test source, e.g. tests/grade3/g3_test1.s")
    parser.add_argument("--port", default="/dev/ttyUSB1", help="Serial port")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--addr", default="0x80000000", help="Frame load address")
    parser.add_argument("--timeout", type=float, default=8.0, help="FPGA receive timeout")
    parser.add_argument("--idle-ms", type=int, default=20)
    parser.add_argument("--spike", default=None, help="Path to spike")
    parser.add_argument("--spike-timeout", type=float, default=8.0)
    parser.add_argument("--gcc", default=None, help="Only used with --rebuild")
    parser.add_argument("--objcopy", default=None, help="Only used with --rebuild")
    parser.add_argument(
        "--rebuild",
        action="store_true",
        help="Rebuild this test's artifacts before running.",
    )
    parser.add_argument(
        "--show-bytes",
        action="store_true",
        help="Print full expected and actual payload hex even on pass.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    remember_tty_state()
    atexit.register(restore_tty_state)

    args = parse_args(sys.argv[1:] if argv is None else argv)
    source = Path(args.test).resolve()

    try:
        if not source.exists():
            raise CompareError(f"Test source does not exist: {source}")

        test_name = test_name_from_path(source)
        if test_name not in TEST_SPECS:
            raise CompareError(f"No observation spec for {test_name}")

        metadata = ensure_artifacts(source, args)
        bin_path = Path(metadata["bin"])
        elf_path = Path(metadata["elf"])
        if not bin_path.exists() or not elf_path.exists():
            raise CompareError(
                f"Missing artifacts for {source}. "
                f"Run: python3 {SCRIPT_DIR / 'build_bins.py'} --test {source}"
            )

        _, _, spike_isa = isa_for_test(test_name)
        spike = args.spike or find_tool("SPIKE", Path("/usr/bin/spike"), "spike")
        print(
            f"[SPIKE] isa={spike_isa} mem={SPIKE_MEM} "
            f"mmio=0x{UART_MMIO:08X}",
            flush=True,
        )
        expected_info = run_spike_expected(
            elf_path,
            spike=spike,
            isa=spike_isa,
            timeout_s=args.spike_timeout,
        )
        expected = bytes(expected_info["expected_bytes"])
        print(f"[SPIKE] expected {len(expected)} bytes: {expected.hex()}", flush=True)

        fpga = send_to_fpga(
            bin_path=bin_path,
            port=args.port,
            baud=args.baud,
            addr=int(args.addr, 16),
            timeout_s=args.timeout,
            idle_ms=args.idle_ms,
            expected_payload_len=len(expected),
        )

        status = int(fpga["status"])
        payload = bytes(fpga["payload"])
        print(
            f"[FPGA] payload {len(payload)} bytes: {payload.hex()} "
            f"ascii={decode_ascii(payload)}",
            flush=True,
        )
        print(
            f"[FPGA] response status=0x{status:02X} "
            f"({fpga['status_name']}) checksum=0x{int(fpga['checksum']):02X}",
            flush=True,
        )

        if status != 0x00:
            raise CompareError(f"FPGA returned non-OK status: {fpga['status_name']}")

        compare_bytes(expected, payload)

        if args.show_bytes:
            print(f"[PASS] expected={expected.hex()}", flush=True)
            print(f"[PASS] actual  ={payload.hex()}", flush=True)
        print(f"[PASS] {source} FPGA output matches Spike", flush=True)
        return 0
    except (BuildError, CompareError) as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("[FAIL] interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
