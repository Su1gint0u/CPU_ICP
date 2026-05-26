#!/usr/bin/env python3
"""Build instrumented RISC-V approval tests for the FPGA UART loader.

The script keeps the original school-provided sources untouched.  For each
assembly test it creates:

    tests/<grade>/artifacts/<test_name>/instrumented.S
    tests/<grade>/artifacts/<test_name>/test.elf
    tests/<grade>/artifacts/<test_name>/test.bin
    tests/<grade>/artifacts/<test_name>/metadata.json
    tests/<grade>/artifacts/<test_name>/spike_expected.json

The instrumented program writes the selected observation values to the CPU
UART MMIO address 0x0001_0000, then executes ebreak so the bridge returns OK.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import sys
import time
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
TESTS_ROOT = REPO_ROOT / "tests"

DEFAULT_TOOL_DIR = (
    Path("/media/alice/workplace/tools/xilinx/2025.2")
    / "Vitis/gnu/riscv/lin/bin"
)
DEFAULT_GCC = DEFAULT_TOOL_DIR / "riscv64-unknown-elf-gcc"
DEFAULT_OBJCOPY = DEFAULT_TOOL_DIR / "riscv64-unknown-elf-objcopy"

RESET_PC = 0x80000000
DATA_BASE = 0x80010000
UART_MMIO = 0x00010000
SPIKE_MEM = "0x00010000:0x1000,0x80000000:0x20000"

TMP_REG = "x25"
UART_REG = "x26"
DATA_REG = "x27"
STACK_REG = "x30"


TEST_SPECS: dict[str, dict[str, Any]] = {
    "g3_test1": {"kind": "int_regs", "regs": ["x2", "x8", "x10"]},
    "g3_test2": {"kind": "int_regs", "regs": ["x8", "x9"]},
    "g3_test3": {"kind": "int_regs", "regs": ["x20", "x21", "x22", "x23", "x24"]},
    "g3_test4": {"kind": "int_regs", "regs": ["x10"]},
    "g3_test5": {
        "kind": "int_regs",
        "regs": ["x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11"],
    },
    "g4_test1": {
        "kind": "int_regs",
        "regs": ["x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14"],
    },
    "g5_test1": {"kind": "fp_regs", "regs": ["f0"]},
    "g5_test2": {
        "kind": "memory_words",
        "base": DATA_BASE,
        "words": [
            {"label": "out_signed[0]", "offset": 48},
            {"label": "out_signed[1]", "offset": 52},
            {"label": "out_signed[2]", "offset": 56},
            {"label": "out_signed[3]", "offset": 60},
            {"label": "out_signed[4]", "offset": 64},
            {"label": "out_unsigned[0]", "offset": 68},
            {"label": "out_unsigned[1]", "offset": 72},
            {"label": "out_unsigned[2]", "offset": 76},
            {"label": "out_unsigned[3]", "offset": 80},
            {"label": "out_unsigned[4]", "offset": 84},
        ],
    },
}

MEM_OPS = (
    "flw",
    "fsw",
    "lw",
    "sw",
    "lb",
    "lbu",
    "lh",
    "lhu",
    "sb",
    "sh",
)


class BuildError(RuntimeError):
    """Raised when a test cannot be built or simulated."""


def find_tool(env_name: str, default_path: Path, fallback: str) -> str:
    env_value = os.environ.get(env_name)
    if env_value:
        return env_value
    if default_path.exists():
        return str(default_path)
    found = shutil.which(fallback)
    if found:
        return found
    raise BuildError(
        f"Could not find {fallback}. Set {env_name} or add the tool to PATH."
    )


def test_name_from_path(path: Path) -> str:
    return path.stem


def grade_from_path(path: Path) -> str:
    for part in path.parts:
        if part.startswith("grade"):
            return part
    return path.parent.name


def isa_for_test(test_name: str) -> tuple[str, str, str]:
    if test_name.startswith("g5_"):
        return "rv32imf_zicsr", "ilp32f", "RV32IMF_Zicsr"
    return "rv32im", "ilp32", "RV32IM"


def artifact_dir_for_source(source: Path) -> Path:
    return source.parent / "artifacts" / source.stem


def iter_test_sources(root: Path) -> list[Path]:
    out: list[Path] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if "artifacts" in path.parts:
            continue
        if path.suffix not in {".s", ".S"}:
            continue
        out.append(path)
    return out


def split_comment(line: str) -> tuple[str, str]:
    if "#" not in line:
        return line.rstrip("\n"), ""
    code, comment = line.rstrip("\n").split("#", 1)
    return code.rstrip(), "#" + comment


def normalize_non_gnu_memory_syntax(source: str) -> str:
    """Convert teaching-simulator memory operands to GNU assembler syntax."""

    reg_pat = r"(?:x\d+|zero|ra|sp|gp|tp|t[0-6]|s\d+|a\d+|f\d+|ft\d+|fs\d+|fa\d+)"
    imm_pat = r"[-+]?(?:0x[0-9a-fA-F]+|\d+)"
    rx = re.compile(
        rf"^(\s*)({'|'.join(MEM_OPS)})\s+({reg_pat})\s*,\s*({reg_pat})\s*,\s*({imm_pat})\s*$"
    )

    lines: list[str] = []
    for line in source.splitlines():
        code, comment = split_comment(line)
        match = rx.match(code)
        if match:
            indent, op, value_reg, base_reg, imm = match.groups()
            code = f"{indent}{op} {value_reg}, {imm}({base_reg})"
        lines.append(code + (f"  {comment}" if comment and code.strip() else comment))
    return "\n".join(lines) + "\n"


def rewrite_x0_memory_base(source: str) -> str:
    """Move direct low-memory x0 accesses to DATA_BASE via x27."""

    rx = re.compile(
        rf"^(\s*(?:{'|'.join(MEM_OPS)})\s+[^,]+,\s*)"
        r"([-+]?(?:0x[0-9a-fA-F]+|\d+))\((?:x0|zero)\)(.*)$"
    )

    lines: list[str] = []
    for line in source.splitlines():
        code, comment = split_comment(line)
        match = rx.match(code)
        if match:
            prefix, imm, suffix = match.groups()
            code = f"{prefix}{imm}({DATA_REG}){suffix}"
        lines.append(code + (f"  {comment}" if comment and code.strip() else comment))
    return "\n".join(lines) + "\n"


def compact_code(code: str) -> str:
    return re.sub(r"\s+", "", code).lower()


def apply_test_specific_rewrites(source: str, test_name: str) -> str:
    lines: list[str] = []
    for line in source.splitlines():
        code, comment = split_comment(line)
        compact = compact_code(code)
        replacement: str | None = None

        if test_name == "g3_test1":
            if compact == "addix1,x0,4":
                replacement = f"    addi x1, {DATA_REG}, 4"
            elif compact == "addx9,x0,x0":
                replacement = f"    add x9, {DATA_REG}, x0"

        elif test_name == "g5_test2":
            base_inits = {
                "addix8,x0,0": "x8",
                "addix9,x0,20": "x9",
                "addix18,x0,40": "x18",
                "addix19,x0,44": "x19",
                "addix20,x0,48": "x20",
                "addix21,x0,68": "x21",
            }
            if compact in base_inits:
                reg = base_inits[compact]
                imm = compact.rsplit(",", 1)[1]
                replacement = f"    addi {reg}, {DATA_REG}, {imm}"

        if replacement is not None:
            code = replacement

        lines.append(code + (f"  {comment}" if comment and code.strip() else comment))

        if test_name == "g5_test2" and re.match(r"^\s*convert_done:\s*$", code):
            lines.append("    jal x0, __approval_epilogue")

    return "\n".join(lines) + "\n"


def rename_or_create_entry(source: str) -> str:
    lines = source.splitlines()
    renamed = False
    out: list[str] = []

    for line in lines:
        code, comment = split_comment(line)
        global_match = re.match(r"^(\s*)\.(?:globl|global)\s+(main|_start)\s*$", code)
        label_match = re.match(r"^(\s*)(main|_start):\s*$", code)

        if global_match:
            out.append(f"{global_match.group(1)}.globl __approval_user_start")
            continue
        if (not renamed) and label_match:
            out.append(f"{label_match.group(1)}__approval_user_start:")
            renamed = True
            continue

        out.append(code + (f"  {comment}" if comment and code.strip() else comment))

    if renamed:
        return "\n".join(out) + "\n"
    return "__approval_user_start:\n" + "\n".join(out) + "\n"


def emit_word_asm(value_expr: str) -> list[str]:
    return [
        f"    mv {TMP_REG}, {value_expr}",
        "    jal x1, __approval_emit_word",
    ]


def epilogue_for_spec(spec: dict[str, Any]) -> str:
    lines = [
        "",
        "__approval_epilogue:",
        f"    lui {DATA_REG}, 0x{DATA_BASE >> 12:x}",
    ]

    kind = spec["kind"]
    if kind == "int_regs":
        for reg in spec["regs"]:
            lines.extend(emit_word_asm(reg))
    elif kind == "fp_regs":
        scratch_base = 128
        for idx, reg in enumerate(spec["regs"]):
            scratch_off = scratch_base + (idx * 4)
            lines.append(f"    fsw {reg}, {scratch_off}({DATA_REG})")
            lines.append(f"    lw {TMP_REG}, {scratch_off}({DATA_REG})")
            lines.append("    jal x1, __approval_emit_word")
    elif kind == "memory_words":
        for word in spec["words"]:
            offset = int(word["offset"])
            lines.append(f"    lw {TMP_REG}, {offset}({DATA_REG})")
            lines.append("    jal x1, __approval_emit_word")
    else:
        raise BuildError(f"Unknown observation kind: {kind}")

    lines.extend(
        [
            "    ebreak",
            "",
            "__approval_emit_word:",
            f"    li {UART_REG}, 0x{UART_MMIO:08x}",
            f"    sb {TMP_REG}, 0({UART_REG})",
            f"    srli {TMP_REG}, {TMP_REG}, 8",
            f"    sb {TMP_REG}, 0({UART_REG})",
            f"    srli {TMP_REG}, {TMP_REG}, 8",
            f"    sb {TMP_REG}, 0({UART_REG})",
            f"    srli {TMP_REG}, {TMP_REG}, 8",
            f"    sb {TMP_REG}, 0({UART_REG})",
            "    ret",
            "",
        ]
    )
    return "\n".join(lines)


def prologue_asm(enable_fpu: bool) -> str:
    lines = [
        ".section .text",
        ".option norelax",
        ".globl _start",
        ".balign 4",
        "_start:",
        f"    lui {DATA_REG}, 0x{DATA_BASE >> 12:x}",
        f"    addi {STACK_REG}, {DATA_REG}, 1024",
    ]
    if enable_fpu:
        lines.extend(
            [
                "    li x25, 0x00006000",
                "    csrs mstatus, x25",
            ]
        )
    lines.extend(
        [
            "    la x1, __approval_epilogue",
            "    jal x0, __approval_user_start",
            "",
        ]
    )
    return "\n".join(lines)


def make_instrumented_source(source_path: Path) -> str:
    test_name = test_name_from_path(source_path)
    spec = TEST_SPECS.get(test_name)
    if spec is None:
        raise BuildError(f"No observation spec for {test_name}")

    source = source_path.read_text(encoding="utf-8").replace("\r\n", "\n")
    source = normalize_non_gnu_memory_syntax(source)
    source = apply_test_specific_rewrites(source, test_name)
    source = rewrite_x0_memory_base(source)
    source = rename_or_create_entry(source)

    return prologue_asm(enable_fpu=test_name.startswith("g5_")) + source + epilogue_for_spec(spec)


def linker_script() -> str:
    return f"""OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{{
  . = 0x{RESET_PC:08x};
  .text : {{
    *(.text.init)
    *(.text*)
    *(.rodata*)
  }}
  . = ALIGN(4);
  .data : {{ *(.data*) }}
  .bss : {{ *(.bss*) *(COMMON) }}
}}
"""


def run_checked(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if proc.returncode != 0:
        raise BuildError(
            "Command failed with exit code "
            f"{proc.returncode}: {' '.join(cmd)}\n{proc.stdout}"
        )
    return proc


def parse_spike_mmio_line(line: str) -> int | None:
    match = re.search(r"\bmem\s+0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+)\b", line)
    if not match:
        return None
    addr = int(match.group(1), 16)
    if addr != UART_MMIO:
        return None
    value = int(match.group(2), 16)
    return value & 0xFF


def run_spike_expected(
    elf_path: Path,
    spike: str = "spike",
    isa: str = "RV32IM",
    timeout_s: float = 8.0,
) -> dict[str, Any]:
    cmd = [
        spike,
        f"--isa={isa}",
        f"-m{SPIKE_MEM}",
        "-l",
        "--log-commits",
        "--pc=0x80000000",
        str(elf_path),
    ]

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert proc.stdout is not None

    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)

    output_bytes: list[int] = []
    log_tail: list[str] = []
    saw_breakpoint = False
    deadline = time.monotonic() + timeout_s

    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BuildError(
                    f"Spike timed out after {timeout_s:.1f}s for {elf_path}\n"
                    + "".join(log_tail[-40:])
                )

            events = selector.select(timeout=min(0.2, remaining))
            if not events:
                if proc.poll() is not None:
                    break
                continue

            line = proc.stdout.readline()
            if not line:
                if proc.poll() is not None:
                    break
                continue

            log_tail.append(line)
            if len(log_tail) > 200:
                log_tail = log_tail[-200:]

            maybe_byte = parse_spike_mmio_line(line)
            if maybe_byte is not None:
                output_bytes.append(maybe_byte)

            if "trap_breakpoint" in line:
                saw_breakpoint = True
                proc.kill()
                break
    finally:
        selector.close()
        if proc.poll() is None:
            proc.kill()
        proc.wait(timeout=2)

    if not saw_breakpoint:
        raise BuildError(
            f"Spike did not reach ebreak for {elf_path}\n" + "".join(log_tail[-40:])
        )

    return {
        "command": cmd,
        "expected_hex": bytes(output_bytes).hex(),
        "expected_bytes": output_bytes,
    }


def bytes_to_words_le(data: bytes, labels: list[str]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for idx, label in enumerate(labels):
        chunk = data[idx * 4 : idx * 4 + 4]
        if len(chunk) != 4:
            break
        value = int.from_bytes(chunk, byteorder="little", signed=False)
        out.append({"label": label, "value_hex": f"0x{value:08x}", "value": value})
    return out


def observation_labels(spec: dict[str, Any]) -> list[str]:
    if spec["kind"] in {"int_regs", "fp_regs"}:
        return list(spec["regs"])
    if spec["kind"] == "memory_words":
        return [str(word["label"]) for word in spec["words"]]
    return []


def build_one(
    source: Path,
    gcc: str,
    objcopy: str,
    spike: str,
    run_spike: bool,
    timeout_s: float,
) -> dict[str, Any]:
    source = source.resolve()
    test_name = test_name_from_path(source)
    spec = TEST_SPECS.get(test_name)
    if spec is None:
        raise BuildError(f"No observation spec for {test_name}")

    march, mabi, spike_isa = isa_for_test(test_name)
    art_dir = artifact_dir_for_source(source)
    art_dir.mkdir(parents=True, exist_ok=True)

    inst_path = art_dir / "instrumented.S"
    elf_path = art_dir / "test.elf"
    bin_path = art_dir / "test.bin"
    link_path = art_dir / "link.ld"
    metadata_path = art_dir / "metadata.json"
    expected_path = art_dir / "spike_expected.json"

    inst_path.write_text(make_instrumented_source(source), encoding="utf-8")
    link_path.write_text(linker_script(), encoding="utf-8")

    compile_cmd = [
        gcc,
        f"-march={march}",
        f"-mabi={mabi}",
        "-nostdlib",
        "-nostartfiles",
        "-x",
        "assembler-with-cpp",
        "-Wl,-T," + str(link_path),
        "-Wl,--no-relax",
        "-Wl,--build-id=none",
        "-o",
        str(elf_path),
        str(inst_path),
    ]
    run_checked(compile_cmd)

    objcopy_cmd = [objcopy, "-O", "binary", "-j", ".text", str(elf_path), str(bin_path)]
    run_checked(objcopy_cmd)

    expected: dict[str, Any] | None = None
    if run_spike:
        expected = run_spike_expected(elf_path, spike=spike, isa=spike_isa, timeout_s=timeout_s)
        labels = observation_labels(spec)
        expected["expected_words_le"] = bytes_to_words_le(
            bytes(expected["expected_bytes"]), labels
        )
        expected_path.write_text(json.dumps(expected, indent=2), encoding="utf-8")

    metadata = {
        "source": str(source),
        "test_name": test_name,
        "grade": grade_from_path(source),
        "march": march,
        "mabi": mabi,
        "spike_isa": spike_isa,
        "reset_pc": f"0x{RESET_PC:08x}",
        "data_base": f"0x{DATA_BASE:08x}",
        "uart_mmio": f"0x{UART_MMIO:08x}",
        "observation": spec,
        "instrumented": str(inst_path),
        "elf": str(elf_path),
        "bin": str(bin_path),
        "bin_size": bin_path.stat().st_size,
        "spike_expected": str(expected_path) if run_spike else None,
    }
    metadata_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    return {
        "source": source,
        "artifact_dir": art_dir,
        "bin": bin_path,
        "elf": elf_path,
        "metadata": metadata_path,
        "expected": expected_path if run_spike else None,
        "bin_size": bin_path.stat().st_size,
        "expected_hex": expected["expected_hex"] if expected else None,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build instrumented approval-test binaries under tests/*/artifacts."
    )
    parser.add_argument("--root", default=str(TESTS_ROOT), help="Tests root directory")
    parser.add_argument(
        "--test",
        action="append",
        help="Specific test source to build. Can be passed multiple times.",
    )
    parser.add_argument("--gcc", default=None, help="Path to riscv64-unknown-elf-gcc")
    parser.add_argument("--objcopy", default=None, help="Path to riscv64-unknown-elf-objcopy")
    parser.add_argument("--spike", default=None, help="Path to spike")
    parser.add_argument(
        "--no-spike",
        action="store_true",
        help="Only build elf/bin; do not generate spike_expected.json.",
    )
    parser.add_argument("--spike-timeout", type=float, default=8.0)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    root = Path(args.root).resolve()

    try:
        gcc = args.gcc or find_tool("RISCV_GCC", DEFAULT_GCC, "riscv64-unknown-elf-gcc")
        objcopy = args.objcopy or find_tool(
            "RISCV_OBJCOPY", DEFAULT_OBJCOPY, "riscv64-unknown-elf-objcopy"
        )
        spike = args.spike or find_tool("SPIKE", Path("/usr/bin/spike"), "spike")

        if args.test:
            sources = [Path(t).resolve() for t in args.test]
        else:
            sources = iter_test_sources(root)

        if not sources:
            raise BuildError(f"No assembly tests found under {root}")

        failures: list[tuple[Path, str]] = []
        results: list[dict[str, Any]] = []
        for source in sources:
            try:
                result = build_one(
                    source=source,
                    gcc=gcc,
                    objcopy=objcopy,
                    spike=spike,
                    run_spike=not args.no_spike,
                    timeout_s=args.spike_timeout,
                )
                results.append(result)
                exp = result["expected_hex"]
                exp_note = f" expected={exp}" if exp is not None else ""
                print(
                    f"[OK] {source} -> {result['bin']} "
                    f"({result['bin_size']} bytes){exp_note}"
                )
            except Exception as exc:  # noqa: BLE001 - collect all test failures.
                failures.append((source, str(exc)))
                print(f"[FAIL] {source}: {exc}", file=sys.stderr)

        print(f"\nBuilt {len(results)}/{len(sources)} tests.")
        if failures:
            print("\nFailures:", file=sys.stderr)
            for source, error in failures:
                print(f"- {source}: {error}", file=sys.stderr)
            return 1
        return 0
    except Exception as exc:  # noqa: BLE001 - top-level CLI message.
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
