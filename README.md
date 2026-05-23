# CPU UART RISC-V on Nexys4

This repository contains a Vivado/Nexys4 FPGA implementation of a UART-loaded
RISC-V CPU test platform. A host PC sends a RISC-V binary over the Nexys4
USB-UART link, the FPGA writes it into the CPU-visible memory space, releases
the CPU, and receives the program output through a UART MMIO address.

The default implementation also includes a compact always-on ILA core for
approval/debug capture.

## Repository Layout

| Path | Contents |
| --- | --- |
| `RTL/cpu/` | CPU, UART bridge, top-level FPGA RTL, and branch/FPU support RTL |
| `RTL/TB/` | SystemVerilog testbenches |
| `RTL/berkeley-hardfloat/` | HardFloat sources used by the floating-point wrapper |
| `Nexys4/const/` | Nexys4 XDC constraints |
| `Nexys4/IMP/` | Vivado Tcl flow and simulation scripts |
| `scripts/` | Host-side build, programming, UART, compare, and ILA export scripts |
| `tests/` | School approval tests and generated-test workflow |

Generated Vivado products, test artifacts, logs, Python caches, `.bit`, and
`.ltx` files are ignored by Git. Rebuild them locally when needed.

## Requirements

- Vivado with `vivado` available through `PATH`, `VIVADO`, or `VIVADO_BIN`
- Python 3
- `pyserial` for FPGA UART communication
- RISC-V GCC toolchain, usually `riscv64-unknown-elf-gcc` and
  `riscv64-unknown-elf-objcopy`
- Spike for reference comparison, usually `spike`
- Nexys4 board connected through JTAG and USB-UART

## Quick Start

From the repository root:

```bash
# Generate instrumented ELF/BIN files for all tests.
python3 scripts/build_bins.py --root tests

# Show whether Vivado would rebuild, without running Vivado.
python3 scripts/vivado_impl.py --dry-run

# Build only: generate Nexys4/IMP/imp/fpga_top.bit and fpga_top.ltx.
python3 scripts/vivado_impl.py --build-only

# Program an already-built FPGA bitstream and automatically bind the LTX file.
python3 scripts/vivado_impl.py --program-only

# Force rebuild and then program the board.
python3 scripts/vivado_impl.py --force
```

Run one approval test against Spike and the programmed FPGA:

```bash
python3 scripts/run_fpga_compare.py tests/grade3/g3_test1.s --port /dev/ttyUSB1
```

Send a test binary to the FPGA without comparing against Spike:

```bash
python3 scripts/send_frame.py tests/grade3/g3_test1.s --port /dev/ttyUSB1
```

The scripts default to `Nexys4/IMP/imp/fpga_top.bit` and
`Nexys4/IMP/imp/fpga_top.ltx`.

## Test Binary Flow

`scripts/build_bins.py` scans the test tree and creates per-test artifacts under
`tests/<grade>/artifacts/<test_name>/`:

- `instrumented.S`
- `link.ld`
- `test.elf`
- `test.bin`
- `metadata.json`
- `spike_expected.json`

Examples:

```bash
# Build everything.
python3 scripts/build_bins.py --root tests

# Build one test.
python3 scripts/build_bins.py --root tests --test tests/grade4/g4_test1.S

# Build one test and skip Spike output generation.
python3 scripts/build_bins.py --root tests --test tests/grade5/g5_test1.s --no-spike
```

`scripts/run_fpga_compare.py` locates the test's generated `test.bin`, runs
Spike, sends the UART frame to the FPGA, and compares the FPGA UART payload with
the Spike reference bytes.

```bash
python3 scripts/run_fpga_compare.py tests/grade3/g3_test5.s --port /dev/ttyUSB1
python3 scripts/run_fpga_compare.py tests/grade5/g5_test2.s --port /dev/ttyUSB1 --rebuild
```

## UART Protocol

The host sends one frame:

```text
[0x01][ADDR_LE32][LEN_LE32][DATA...][XOR]
```

The FPGA responds after CPU completion, timeout, or frame error:

```text
[PAYLOAD...][0x02][STATUS][0x02 ^ STATUS]
```

Status values:

| Status | Meaning |
| --- | --- |
| `0x00` | Normal trap/completion |
| `0x01` | CPU timeout |
| `0x02` | Length/range error |
| `0x03` | Unsupported command |
| `0xFF` | Checksum error |

CPU program output is produced by MMIO stores to address `0x0001_0000`.

## Vivado Flow

The implementation flow is driven by `scripts/vivado_impl.py`, which checks RTL,
constraints, and flow script fingerprints before deciding whether to rebuild.

Useful modes:

```bash
python3 scripts/vivado_impl.py --dry-run
python3 scripts/vivado_impl.py --build-only
python3 scripts/vivado_impl.py --program-existing
python3 scripts/vivado_impl.py --program-only
python3 scripts/vivado_impl.py --force
```

Programming options:

```bash
python3 scripts/vivado_impl.py --program-only \
  --bitstream Nexys4/IMP/imp/fpga_top.bit \
  --ltx Nexys4/IMP/imp/fpga_top.ltx
```

The generated implementation outputs are local build products and are not meant
to be committed.

## ILA Acceptance Notes

The default Nexys4 implementation includes one `ila_cpu_uart_dbg` core clocked
from the internal 50 MHz `sys_clk`.

The build writes both hardware debug artifacts to `Nexys4/IMP/imp/`:

- `fpga_top.bit`
- `fpga_top.ltx`

### Hardware Manager Flow

1. Open Vivado Hardware Manager and connect to the Nexys4 target.
2. Program the FPGA with `scripts/vivado_impl.py --program-only`; the script
   binds `fpga_top.ltx` automatically. If programming manually, use
   `fpga_top.bit` and associate `fpga_top.ltx`.
3. Open `ila_cpu_uart_dbg`, set a trigger, and arm the capture.
4. Send a test bin with `scripts/run_fpga_compare.py` or `scripts/send_frame.py`.
5. Inspect the capture around program load, CPU retire, MMIO UART output, and
   trap.

Useful triggers:

- `probe13 == 1`: IMEM program write
- Rising `probe12`: CPU release after a valid UART transaction
- `probe14 == 1`: CPU MMIO UART byte accepted by the bridge
- `probe15 == 1`: trap/completion observed by the bridge
- `probe17 == 1`: committed GPR writeback into the debug mirror

### Probe Map

Bits are listed low to high. Multi-bit fields use inclusive bit ranges.

| ILA port | Signal group | Fields |
| --- | --- | --- |
| `probe0[3:0]` | Reset | `[0] sys_clk_locked`, `[1] sys_reset_n`, `[2] cpu_reset_n`, `[3] rx_line_idle` |
| `probe1[8:0]` | UART RX | `[0] rx_valid`, `[8:1] rx_data` |
| `probe2[12:0]` | Bridge | `[2:0] state`, `[10:3] response_status`, `[11] uart_tx_busy`, `[12] cpu_uart_tx_ready` |
| `probe3[48:0]` | Program write | `[0] imem_wr_en`, `[4:1] imem_wr_be`, `[16:5] imem_wr_addr`, `[48:17] imem_wr_data` |
| `probe4[12:0]` | Memory clear | `[0] mem_clear_en`, `[12:1] mem_clear_addr` |
| `probe5[75:0]` | CPU data request | `[0] valid`, `[1] ready`, `[4:2] cmd`, `[7:5] size`, `[39:8] addr`, `[71:40] wdata`, `[75:72] wstrb` |
| `probe6[18:0]` | UART TX | `[0] cpu_uart_tx_start`, `[8:1] cpu_uart_tx_byte`, `[9] uart_tx_start`, `[17:10] uart_tx_data`, `[18] uart_tx_busy` |
| `probe7[102:0]` | Retire slot 0 | `[0] valid`, `[32:1] pc`, `[64:33] inst`, `[65] regwrite`, `[70:66] rd`, `[102:71] wdata` |
| `probe8[102:0]` | Retire slot 1 | Same field layout as `probe7` |
| `probe9[67:0]` | BP fetch | `[0] valid`, `[32:1] pc`, `[33] pred_taken0`, `[34] pred_taken1`, `[35] spec_taken`, `[67:36] spec_target` |
| `probe10[66:0]` | BP update | `[0] valid`, `[32:1] pc`, `[33] actual_taken`, `[34] mispredict`, `[66:35] target` |
| `probe11[24:0]` | CPU debug | `[0] trap`, `[8:1] perf_backend_flags`, `[16:9] dbg_stall_flags`, `[24:17] dbg_ex_flags` |
| `probe12` | Trigger | `cpu_reset_n` |
| `probe13` | Trigger | `imem_wr_en` |
| `probe14` | Trigger | `cpu_uart_tx_start` |
| `probe15` | Trigger | `mon_trap_occurred` |
| `probe16[37:0]` | GPR scan | `[0] scan_valid`, `[5:1] scan_idx`, `[37:6] scan_data` |
| `probe17` | Trigger | `gpr_retire_write` |

`probe2.state` follows the UART bridge FSM order in `uart_bridge.sv`: `IDLE`,
`RX_FRAME`, `CHKSUM_CHECK`, `RELEASE_CPU`, `MONITOR`, `DRAIN_TX`, and
`SEND_RESP`.

`probe11.dbg_stall_flags` uses bit 0 through bit 7 for `stall_all`,
`stall_mem`, `stall_load_use`, `stall_fp`, `stall_csr`, `stall_iq`,
`stall_prf`, and `stall_rob_or_retract`.

`probe11.dbg_ex_flags` uses bit 0 through bit 7 for `md0_start`, `md0_busy`,
`md0_done`, `md1_start`, `md1_busy`, `md1_done`, `stall_fpu`, and
`muldiv_wait`.

`probe16` scans a retire-driven GPR mirror. When `scan_valid` is high,
`scan_data` is the architectural mirror value for `x<scan_idx>`. The mirror is
cleared while the CPU is held in reset, `x0` is forced to zero, and updates are
accepted only from the retire interfaces. It does not include speculative PRF,
CDB, or EX-stage values. To recover `x0` through `x31`, capture any continuous
32 valid scan samples and group them by `scan_idx`.

### Approval Captures

- Grade 3: capture IMEM loading, CPU release, retire records, GPR scan, and
  UART output.
- Grade 4: capture a multiply/divide test with `muldiv_wait`, busy, done flags,
  and GPR scan.
- Grade 5: capture a floating-point test with FPU stall flags, final UART
  output, and any needed integer helper registers in GPR scan.

### ILA Export

In the Vivado Tcl console:

```tcl
source scripts/ila_export.tcl
ila_export
```

Or from a shell:

```bash
vivado -mode batch -source scripts/ila_export.tcl
```
