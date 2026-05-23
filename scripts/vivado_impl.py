#!/usr/bin/env python3
"""Build and program the Nexys4 bitstream when implementation inputs change."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterable


SCHEMA_VERSION = 1
SOURCE_SUFFIXES = {".sv", ".svh", ".v", ".vh", ".vi"}
DEFAULT_VIVADO = Path("/media/alice/workplace/tools/xilinx/2025.2/Vivado/bin/vivado")
PROGRAM_TCL = r"""
set bitfile [file normalize [lindex $argv 0]]
set ltxfile [file normalize [lindex $argv 1]]
set device_filter [lindex $argv 2]

if {![file exists $bitfile]} {
    puts stderr "\[PROGRAM\] ERROR: bitstream not found: $bitfile"
    exit 2
}
if {![file exists $ltxfile]} {
    puts stderr "\[PROGRAM\] ERROR: debug probes file not found: $ltxfile"
    exit 2
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set devices [get_hw_devices]
set device ""
foreach candidate $devices {
    if {[string match -nocase $device_filter $candidate]} {
        set device $candidate
        break
    }
}

if {$device eq ""} {
    puts stderr "\[PROGRAM\] ERROR: no hardware device matches '$device_filter'. Available devices: $devices"
    close_hw_manager
    exit 3
}

puts "\[PROGRAM\] Programming $device with $bitfile"
current_hw_device $device
refresh_hw_device -update_hw_probes false $device
set_property PROGRAM.FILE $bitfile $device
puts "\[PROGRAM\] Binding debug probes $ltxfile"
set hw_props [list_property $device]
if {[lsearch -exact $hw_props PROBES.FILE] >= 0} {
    set_property PROBES.FILE $ltxfile $device
}
if {[lsearch -exact $hw_props FULL_PROBES.FILE] >= 0} {
    set_property FULL_PROBES.FILE $ltxfile $device
}
program_hw_devices $device
refresh_hw_device -update_hw_probes true $device
puts "\[PROGRAM\] SUCCESS: programmed $device"
close_hw_manager
"""


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def relpath(path: Path, root: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def state_path_text(path: Path, root: Path) -> str:
    try:
        return relpath(path, root)
    except ValueError:
        return str(path.resolve())


def resolve_project_path(path: Path, root: Path) -> Path:
    path = path.expanduser()
    if path.is_absolute():
        return path.resolve()
    return (root / path).resolve()


def source_files(root: Path) -> list[Path]:
    roots = [
        root / "RTL" / "cpu",
        root / "RTL" / "berkeley-hardfloat" / "extract",
    ]
    files: list[Path] = []
    for source_root in roots:
        if not source_root.is_dir():
            raise SystemExit(f"[ERROR] Missing RTL source directory: {source_root}")
        files.extend(
            path
            for path in source_root.rglob("*")
            if path.is_file() and path.suffix.lower() in SOURCE_SUFFIXES
        )
    return sorted(files)


def constraint_files(root: Path) -> list[Path]:
    const_dir = root / "Nexys4" / "const"
    if not const_dir.is_dir():
        raise SystemExit(f"[ERROR] Missing constraint directory: {const_dir}")
    return sorted(path for path in const_dir.glob("*.xdc") if path.is_file())


def watched_files(root: Path) -> tuple[list[Path], list[Path], list[Path]]:
    rtl = source_files(root)
    constraints = constraint_files(root)
    flow = [root / "Nexys4" / "IMP" / "build.tcl"]
    missing = [path for path in flow if not path.is_file()]
    if missing:
        raise SystemExit(f"[ERROR] Missing Vivado flow file: {missing[0]}")
    return rtl, constraints, flow


def fingerprint(paths: Iterable[Path], root: Path) -> tuple[str, dict[str, str]]:
    digest = hashlib.sha256()
    files: dict[str, str] = {}
    for path in sorted(paths):
        relative = relpath(path, root)
        file_hash = hash_file(path)
        files[relative] = file_hash
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(file_hash.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest(), files


def load_state(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"[WARN] Ignoring unreadable state file {path}: {exc}", file=sys.stderr)
        return {}


def save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(state, indent=2, sort_keys=True) + "\n"
    path.write_text(text, encoding="utf-8")


def changed_paths(old_files: dict[str, str], new_files: dict[str, str]) -> list[str]:
    old_paths = set(old_files)
    new_paths = set(new_files)
    changes = [f"added {path}" for path in sorted(new_paths - old_paths)]
    changes.extend(f"removed {path}" for path in sorted(old_paths - new_paths))
    changes.extend(
        f"modified {path}"
        for path in sorted(old_paths & new_paths)
        if old_files[path] != new_files[path]
    )
    return changes


def resolve_vivado(requested: str | None) -> Path:
    candidates: list[Path] = []
    if requested:
        candidates.append(Path(requested).expanduser())
    if os.environ.get("VIVADO"):
        candidates.append(Path(os.environ["VIVADO"]).expanduser())
    if os.environ.get("VIVADO_BIN"):
        candidates.append(Path(os.environ["VIVADO_BIN"]).expanduser() / "vivado")
    candidates.append(DEFAULT_VIVADO)
    from_path = shutil.which("vivado")
    if from_path:
        candidates.append(Path(from_path))

    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()
    searched = ", ".join(str(candidate) for candidate in candidates)
    raise SystemExit(f"[ERROR] Could not find executable vivado. Checked: {searched}")


def run(command: list[str], cwd: Path, dry_run: bool) -> None:
    print(f"[RUN] cwd={cwd}")
    print(f"[RUN] {shlex.join(command)}")
    if dry_run:
        return
    subprocess.run(command, cwd=cwd, check=True)


def program_bitstream(
    vivado: Path,
    root: Path,
    bitstream: Path,
    probes: Path,
    device_filter: str,
    dry_run: bool,
) -> None:
    imp_dir = root / "Nexys4" / "IMP"
    with tempfile.TemporaryDirectory(prefix="vivado_program_") as temp_dir:
        program_script = Path(temp_dir) / "program_fpga.tcl"
        program_script.write_text(PROGRAM_TCL.lstrip(), encoding="utf-8")
        command = [
            str(vivado),
            "-mode",
            "batch",
            "-source",
            str(program_script),
            "-log",
            str(imp_dir / "imp" / "program_vivado.log"),
            "-journal",
            str(imp_dir / "imp" / "program_vivado.jou"),
            "-tclargs",
            str(bitstream.resolve()),
            str(probes.resolve()),
            device_filter,
        ]
        run(command, cwd=imp_dir, dry_run=dry_run)


def parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=(
            "Rebuild Nexys4/IMP/imp/fpga_top.bit when RTL/XDC inputs changed, "
            "then program the connected Nexys4 FPGA."
        )
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="run implementation even when the cached input fingerprint is current",
    )
    ap.add_argument(
        "--build-only",
        action="store_true",
        help="stop after a successful bitstream build and do not open the JTAG target",
    )
    ap.add_argument(
        "--program-existing",
        action="store_true",
        help="program the current bitstream even when implementation is skipped",
    )
    ap.add_argument(
        "--program-only",
        action="store_true",
        help=(
            "only connect to hardware and program the existing bitstream/LTX; "
            "skip RTL/XDC change detection and implementation"
        ),
    )
    ap.add_argument(
        "--bitstream",
        type=Path,
        help="override bitstream path; default is Nexys4/IMP/imp/fpga_top.bit",
    )
    ap.add_argument(
        "--ltx",
        type=Path,
        help="override debug probes path; default is Nexys4/IMP/imp/fpga_top.ltx",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="print update detection and Vivado commands without running Vivado or writing state",
    )
    ap.add_argument(
        "--vivado",
        help="path to the Vivado executable; VIVADO or VIVADO_BIN are also accepted",
    )
    ap.add_argument(
        "--device-filter",
        default="xc7a100t*",
        help="Tcl string-match filter for get_hw_devices during programming",
    )
    ap.add_argument(
        "--state",
        type=Path,
        help="override state cache path; default is tests/.vivado_impl_state.json",
    )
    return ap


def main() -> int:
    args = parser().parse_args()
    if args.program_only and args.build_only:
        raise SystemExit("[ERROR] --program-only cannot be combined with --build-only")
    if args.program_only and args.force:
        raise SystemExit("[ERROR] --program-only cannot be combined with --force")

    root = repo_root()
    imp_dir = root / "Nexys4" / "IMP"
    build_tcl = imp_dir / "build.tcl"
    bitstream = (
        resolve_project_path(args.bitstream, root)
        if args.bitstream
        else imp_dir / "imp" / "fpga_top.bit"
    )
    probes = (
        resolve_project_path(args.ltx, root)
        if args.ltx
        else imp_dir / "imp" / "fpga_top.ltx"
    )
    state_path = args.state.expanduser().resolve() if args.state else root / "tests" / ".vivado_impl_state.json"
    vivado = resolve_vivado(args.vivado)

    if args.program_only:
        print(f"[CHECK] repo={root}")
        print("[CHECK] --program-only requested; skipping implementation flow")
        print(f"[CHECK] bitstream={bitstream}")
        print(f"[CHECK] probes={probes}")
        if not args.dry_run:
            if not bitstream.is_file():
                raise SystemExit(f"[ERROR] bitstream missing: {bitstream}")
            if not probes.is_file():
                raise SystemExit(f"[ERROR] debug probes missing: {probes}")
        program_bitstream(vivado, root, bitstream, probes, args.device_filter, args.dry_run)
        if not args.dry_run:
            state = load_state(state_path)
            state.update(
                {
                    "schema": SCHEMA_VERSION,
                    "repo": str(root),
                    "bitstream": state_path_text(bitstream, root),
                    "bitstream_sha256": hash_file(bitstream),
                    "ltx": state_path_text(probes, root),
                    "ltx_sha256": hash_file(probes),
                    "last_program_utc": utc_now(),
                    "last_program_device_filter": args.device_filter,
                }
            )
            save_state(state_path, state)
        return 0

    rtl, constraints, flow = watched_files(root)
    input_hash, current_files = fingerprint([*rtl, *constraints, *flow], root)
    state = load_state(state_path)
    old_files = state.get("files", {}) if isinstance(state.get("files"), dict) else {}
    file_changes = changed_paths(old_files, current_files)

    print(f"[CHECK] repo={root}")
    print(f"[CHECK] watched RTL={len(rtl)} constraints={len(constraints)} flow={len(flow)}")
    print(f"[CHECK] input fingerprint={input_hash}")

    reasons: list[str] = []
    if args.force:
        reasons.append("--force requested")
    if state.get("schema") != SCHEMA_VERSION:
        reasons.append("no compatible implementation state")
    if state.get("input_fingerprint") != input_hash:
        reasons.append("RTL/XDC/flow fingerprint changed")
    if not bitstream.is_file():
        reasons.append(f"bitstream missing: {bitstream}")
    if not probes.is_file():
        reasons.append(f"debug probes missing: {probes}")
    if bitstream.is_file() and state.get("schema") == SCHEMA_VERSION:
        if not state.get("bitstream_sha256"):
            reasons.append("state has no recorded bitstream hash")
        elif state.get("bitstream_sha256") != hash_file(bitstream):
            reasons.append("bitstream differs from last successful build")

    needs_build = bool(reasons)
    if needs_build:
        print("[CHECK] implementation required:")
        for reason in reasons:
            print(f"  - {reason}")
        for change in file_changes[:20]:
            print(f"  - {change}")
        if len(file_changes) > 20:
            print(f"  - ... {len(file_changes) - 20} more file changes")
    else:
        print("[CHECK] cached bitstream matches current RTL and constraints")

    built = False
    if needs_build:
        run([str(vivado), "-mode", "batch", "-source", str(build_tcl)], cwd=imp_dir, dry_run=args.dry_run)
        if args.dry_run:
            next_step = "stop before JTAG programming" if args.build_only else "program the FPGA"
            print(f"[DRY-RUN] bitstream build would {next_step}")
        else:
            if not bitstream.is_file():
                raise SystemExit(f"[ERROR] Vivado finished without bitstream: {bitstream}")
            if not probes.is_file():
                raise SystemExit(f"[ERROR] Vivado finished without debug probes: {probes}")
            state = {
                "schema": SCHEMA_VERSION,
                "repo": str(root),
                "input_fingerprint": input_hash,
                "files": current_files,
                "bitstream": state_path_text(bitstream, root),
                "bitstream_sha256": hash_file(bitstream),
                "ltx": state_path_text(probes, root),
                "ltx_sha256": hash_file(probes),
                "last_build_utc": utc_now(),
            }
            save_state(state_path, state)
            print(f"[BUILD] Current bitstream recorded in {state_path}")
            built = True

    should_program = not args.build_only and (built or (not needs_build and args.program_existing))
    if args.dry_run and needs_build and not args.build_only:
        should_program = True

    if should_program:
        if not args.dry_run:
            if not bitstream.is_file():
                raise SystemExit(f"[ERROR] bitstream missing: {bitstream}")
            if not probes.is_file():
                raise SystemExit(f"[ERROR] debug probes missing: {probes}")
        program_bitstream(vivado, root, bitstream, probes, args.device_filter, args.dry_run)
        if not args.dry_run:
            state["last_program_utc"] = utc_now()
            state["last_program_device_filter"] = args.device_filter
            state["ltx"] = state_path_text(probes, root)
            state["ltx_sha256"] = hash_file(probes)
            save_state(state_path, state)
    elif args.build_only and needs_build:
        print("[PROGRAM] skipped by --build-only")
    elif not needs_build:
        print("[PROGRAM] skipped; use --program-existing to reload the cached bitstream")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
