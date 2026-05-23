#!/usr/bin/env python3
"""
UART frame sender / receiver for fpga_top (Nexys4 DDR).
Takes an approval test source under tests/, locates its generated test.bin,
wraps it into the Bridge frame protocol, sends it over serial, and displays
FPGA response bytes (CPU output + Bridge response frame).

Frame protocol (PC -> FPGA):
    [IDLE >= 1ms] [CMD=0x01] [ADDR 4B LE] [LEN 4B LE] [DATA ...] [CHKSUM 1B]

Response from FPGA:
    1. CPU MMIO output bytes (writes to 0x0001_0000, forwarded to UART TX)
    2. Bridge response frame: [0x02] [STATUS 1B] [CHKSUM 1B]
       STATUS: 0x00=OK, 0x01=TIMEOUT, 0x02=RANGE_ERR,
               0x03=UNSUPPORTED_CMD, 0xFF=CHECKSUM_ERR

Usage:
    python3 scripts/send_frame.py tests/grade3/g3_test1.s
    python3 scripts/send_frame.py grade3/g3_test1.s --port /dev/ttyUSB1
    python3 scripts/send_frame.py --bin tests/grade3/artifacts/g3_test1/test.bin
"""

import argparse
from pathlib import Path
import struct
import sys
import time


REPO_ROOT = Path(__file__).resolve().parents[1]
TESTS_ROOT = REPO_ROOT / "tests"


STATUS_NAMES = {
    0x00: "OK (trap)",
    0x01: "TIMEOUT",
    0x02: "RANGE_ERR",
    0x03: "UNSUPPORTED_CMD",
    0xFF: "CHECKSUM_ERR",
}


def calc_checksum(cmd, addr_le, len_le, data):
    """XOR all frame bytes: CMD ^ ADDR[4] ^ LEN[4] ^ DATA[LEN]"""
    chk = cmd
    for b in addr_le:
        chk ^= b
    for b in len_le:
        chk ^= b
    for b in data:
        chk ^= b
    return chk & 0xFF


def build_frame(addr, data):
    """Build the full UART frame as a bytes object."""
    cmd = 0x01
    addr_le = struct.pack("<I", addr)
    length = len(data)
    len_le = struct.pack("<I", length)
    chk = calc_checksum(cmd, addr_le, len_le, data)
    frame = bytes([cmd]) + addr_le + len_le + data + bytes([chk])
    return frame


def decode_byte(b):
    """Return a displayable character or dot."""
    if 0x20 <= b <= 0x7E:
        return chr(b)
    return "."


def resolve_existing_path(path_text):
    """Resolve a user path from cwd, repo root, or tests root."""
    candidate = Path(path_text).expanduser()
    candidates = [candidate]
    if not candidate.is_absolute():
        candidates.extend([REPO_ROOT / candidate, TESTS_ROOT / candidate])

    for path in candidates:
        if path.exists():
            return path.resolve()
    return candidate.resolve()


def artifact_bin_for_test(source_path):
    return source_path.parent / "artifacts" / source_path.stem / "test.bin"


def metadata_bin_for_test(source_path):
    metadata_path = source_path.parent / "artifacts" / source_path.stem / "metadata.json"
    if not metadata_path.exists():
        return None

    try:
        import json

        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except Exception:
        return None

    bin_text = metadata.get("bin")
    if not bin_text:
        return None

    bin_path = Path(bin_text)
    if bin_path.exists():
        return bin_path.resolve()
    return None


def resolve_bin_path(args):
    if args.bin:
        bin_path = resolve_existing_path(args.bin)
        if not bin_path.exists():
            raise FileNotFoundError(f"bin file does not exist: {bin_path}")
        return bin_path, None

    if not args.test:
        raise ValueError("missing test source. Example: scripts/send_frame.py tests/grade3/g3_test1.s")

    source_path = resolve_existing_path(args.test)
    if not source_path.exists():
        raise FileNotFoundError(f"test source does not exist: {source_path}")

    if source_path.suffix == ".bin":
        return source_path, None

    if "tests" not in source_path.parts:
        raise ValueError(f"test source must be under tests/: {source_path}")

    if source_path.suffix not in {".s", ".S"}:
        raise ValueError(f"expected an assembly test source or .bin file: {source_path}")

    bin_path = metadata_bin_for_test(source_path) or artifact_bin_for_test(source_path)
    if not bin_path.exists():
        raise FileNotFoundError(
            f"missing generated bin for {source_path}: {bin_path}\n"
            f"Run: python3 {REPO_ROOT / 'scripts' / 'build_bins.py'} --test {source_path}"
        )
    return bin_path.resolve(), source_path


def main():
    parser = argparse.ArgumentParser(description="UART frame sender for fpga_top")
    parser.add_argument(
        "test",
        nargs="?",
        help="Path to a tests/ assembly source, e.g. tests/grade3/g3_test1.s",
    )
    parser.add_argument(
        "--bin",
        default=None,
        help="Legacy/debug override: send this .bin directly instead of resolving from tests/.",
    )
    parser.add_argument("--port", default="/dev/ttyUSB1", help="Serial port device")
    parser.add_argument("--baud", type=int, default=115200, help="Baud rate")
    parser.add_argument("--addr", default="0x80000000", help="IMEM base address (hex)")
    parser.add_argument("--timeout", type=float, default=8.0,
                        help="Seconds to wait for FPGA response after sending")
    parser.add_argument("--idle-ms", type=int, default=20,
                        help="Idle gap before frame (ms)")
    args = parser.parse_args()

    # Parse address
    addr = int(args.addr, 16)

    try:
        bin_path, source_path = resolve_bin_path(args)
    except (FileNotFoundError, ValueError) as e:
        print(f"[SEND] ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    data = bin_path.read_bytes()
    if source_path is not None:
        print(f"[SEND] Test source: {source_path}")
    print(f"[SEND] Loaded {bin_path}: {len(data)} bytes, "
          f"words={len(data) // 4}, addr=0x{addr:08X}")

    if len(data) == 0:
        print("[SEND] ERROR: empty bin file")
        sys.exit(1)
    if len(data) % 4 != 0:
        print("[SEND] WARNING: bin size not word-aligned, "
              "bridge will write partial last word")

    # Build frame
    frame = build_frame(addr, data)
    print(f"[SEND] Frame: CMD+ADDR+LEN={9}, DATA={len(data)}, "
          f"CHKSUM=0x{frame[-1]:02X}, total={len(frame)} bytes")

    # Import pyserial
    try:
        import serial
    except ImportError:
        print("[SEND] ERROR: pyserial not installed. Run: pip install pyserial")
        sys.exit(1)

    # Open serial port
    try:
        ser = serial.Serial(args.port, args.baud, timeout=0.1)
    except serial.SerialException as e:
        print(f"[SEND] ERROR opening {args.port}: {e}")
        print("[SEND] Available ports:")
        try:
            from serial.tools import list_ports
            for p in list_ports.comports():
                print(f"  {p.device}: {p.description}")
        except ImportError:
            pass
        sys.exit(1)

    # Flush any stale data
    ser.reset_input_buffer()
    ser.reset_output_buffer()

    # Idle gap before frame (bridge detects ~1ms gap to start a new frame)
    print(f"[SEND] Sending idle gap ({args.idle_ms}ms)...")
    time.sleep(args.idle_ms / 1000.0)

    # Send frame
    print(f"[SEND] Sending {len(frame)} bytes...")
    ser.write(frame)
    ser.flush()
    print("[SEND] Done. Waiting for FPGA response...")

    # Receive and display FPGA output
    print("\n[RECV] ─── FPGA response ───")
    print(f"{'#':>4}  {'Hex':<8} {'ASCII':<6}  Notes")
    print(f"{'─'*4}  {'─'*8} {'─'*6}  {'─'*40}")

    rx_bytes = []
    rx_count = 0
    silence_count = 0

    t_start = time.time()

    while True:
        b = ser.read(1)
        elapsed = time.time() - t_start

        if b:
            rx_bytes.append(b[0])
            rx_count += 1
            silence_count = 0

            note = ""
            # Detect response frame start
            if len(rx_bytes) >= 3:
                last3 = rx_bytes[-3:]
                if last3[0] == 0x02:
                    resp_status = last3[1]
                    resp_chk = last3[2]
                    exp_chk = 0x02 ^ resp_status
                    status_str = STATUS_NAMES.get(resp_status, f"UNKNOWN({resp_status:02X})")
                    chk_ok = "OK" if resp_chk == exp_chk else f"MISMATCH(exp=0x{exp_chk:02X})"
                    note = f"  <── RESPONSE: STATUS={status_str}, CHK={chk_ok}"

            print(f"{rx_count:>4d}  0x{b[0]:02X}    {decode_byte(b[0]):<6s} {note}")

        if not b:
            silence_count += 1
            if silence_count > 50:  # 5 seconds of silence
                if elapsed > args.timeout:
                    break
        else:
            silence_count = 0

    ser.close()

    # Summary
    print(f"\n[RECV] ─── Summary ───")
    print(f"[RECV] Received {rx_count} bytes in {elapsed:.1f}s")
    if rx_bytes:
        actual_start = rx_count - len(rx_bytes)
        # Try to find response pattern
        for i in range(len(rx_bytes)):
            if rx_bytes[i] == 0x02 and i + 2 < len(rx_bytes):
                status = rx_bytes[i + 1]
                status_str = STATUS_NAMES.get(status, f"0x{status:02X}")
                print(f"[RECV] Response frame at byte {i+1}: "
                      f"STATUS={status_str}")
        # Print ASCII-only view for CPU output
        ascii_str = "".join(decode_byte(b) for b in rx_bytes)
        print(f"[RECV] ASCII view: {ascii_str}")
    else:
        print("[RECV] No bytes received — check:")
        print("  - USB-UART cable connected to JP2/J14 port (upper Micro-USB)")
        print("  - Correct serial port (use --port to override)")
        print("  - Bitstream properly programmed (LD2 should be lit)")
        print("  - Baud rate 115200 8N1")


if __name__ == "__main__":
    main()
