# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A CPU-less LiteX SoC (Wishbone bus) with UARTBone (UART→Wishbone bridge) and a LiteScope ILA,
emitted as **one self-contained Verilog file** (`build/virtual/gateware/soc.v`, `module soc`) meant
to be dropped into an external Verilog project as a black-box IP. Python ≥3.12, managed with `uv`;
only `migen` (pinned rev), `litex` and `litescope` (git tag `2026.04`) are dependencies — nothing
else is imported by a build. Verilator/Yosys come from oss-cad-suite.

## Commands

```sh
uv sync                 # install the pinned LiteX stack into .venv
make build              # generate + copy soc.v, csr.csv, csr.json, analyzer.csv to dist/
make generate           # uv run simple-soc ... -> build/virtual/{gateware/soc.v,csr.csv,csr.json,analyzer.csv}
make test               # lint + Verilator self-checking sim (test/tb_soc.cpp), ~10 s
make simulate           # Verilator sim only
make -j synth-estimate  # Yosys LUT/FF/BRAM estimate: MAX10, Gowin, Xilinx, Lattice -> build/synth/*.stat, ~10 s
make clean              # rm -rf build dist
```

- Core parameters are Makefile vars forwarded to `simple-soc`: `CLK_FREQ` (default 50000000),
  `BAUDRATE` (115200), `BUILD_NAME` (soc → also the top module name). A `.params` stamp forces
  regeneration when they change. `simple-soc` rejects `clk_freq < 16 * baudrate`.
- The testbenches are self-checking (non-zero exit on failure) and speak the UARTBone protocol over
  `serial_rx`/`serial_tx`: cmd 0x01 write / 0x02 read, length, 32-bit big-endian **word** address
  (byte_addr >> 2), big-endian data. CSR byte addresses are hard-coded from `csr.csv` (ctrl_scratch
  0x804, analyzer_* at 0x0..) — update both TBs if the CSR map changes.
- LiteScope gotcha: with no trigger condition loaded it triggers immediately, and `storage_done` is 1
  while idle — the TBs load one match-all condition (`trigger_mem_write`) before arming.
- **Icarus support is commented out in the Makefile (the user will fix it later).** `test/tb_soc.v` exists
  but isn't wired in. Generated `always @(*)` blocks with default-then-override `<=` re-trigger each
  other in Icarus: ILA mux ↔ storage FSM hangs when probe data is non-zero, and UARTBone ↔ wishbone2csr
  runs ~100× slower. See its header. `vvp` buffers stdout when writing to files or pipes, so a killed
  run shows no output.
- `synth-estimate` vars: `SYNTH_TARGETS` (intel gowin xilinx lattice; also `make synth-<t>`),
  `LATTICE_FAMILY` (xo2), `SYNTH_TIMEOUT` (60 s per run; logs in `build/synth/<t>.log`). Other
  `synth_*` passes were surveyed: `synth`, `_achronix`, `_fabulous`, `_quicklogic`, `_sf2` take
  >60 s; `synth_microchip` fails on initialized FFs; `synth_easic` needs eTools. The ILA sample
  buffer (167 bit × `ILA_DEPTH`) dominates BRAM.
- Optional Yosys smoke test:
  `yosys -p "read_verilog build/virtual/gateware/soc.v; hierarchy -top soc; proc; opt; check"`.

## Architecture

- `src/litex_wb_litescope/soc.py` — the **entire system** in one file:
  - `_io` list (LiteX board-style `(name, 0, Pins(width) | Subsignal(...))`, like
    `litex_sim.py`) → every top-level port of the IP (subsignals become `<group>_<sub>`, e.g.
    `serial_tx`). `Pins(n)` = n unplaced pins; Migen infers directions. `io_ports(_io)` lists the
    resulting port names. `ILA_PROBES`/`ILA_DEPTH`
    select which pins the analyzer captures.
  - `VirtualPlatform(GenericPlatform)` — vendor-agnostic platform whose `build()` (mirroring
    `litex.build.sim.verilator.SimVerilatorToolchain.build`) only calls `get_verilog()` and writes
    a single flat `.v`; no toolchain runs.
  - `BaseSoC(SoCCore)` — `CRG` from `clk`/`rst` pins (must be set **before** `SoCCore.__init__`),
    `cpu_type="None"`, no UART/timer, `add_uartbone(uart_name="serial")`, `LiteScopeAnalyzer`
    (`samplerate=clk_freq`, so VCD timescales from `litescope_cli` are correct).
- `src/litex_wb_litescope/build_soc.py` — `simple-soc` entry point; runs `Builder(...,
  compile_software=False, compile_gateware=False).build(run=False)`. `csr.csv` comes from Builder,
  `analyzer.csv` from `LiteScopeAnalyzer.do_exit`. Both are needed by host tools
  (`litex_server`/`litex_cli`/`litescope_cli`, see README).
- `src/litex_wb_litescope/__init__.py` — placeholder `litex-wb-litescope` script (hello world).
- `.github/prompts/plan-litexUartboneLiteScope.prompt.md` — original design plan and rationale.

## Invariants / gotchas

- Keep `ident=""` and `integrated_sram_size=0`: adding an identifier or SRAM/ROM introduces
  `.init`/`$readmem` file dependencies and breaks the "single self-contained file" property.
- Changing `_io` changes the IP's port list — update `test/tb_soc.cpp` (Verilator exposes signals
  >64 bits as `uint32_t` word arrays, e.g. `probe3[0..3]`; built with `--prefix Vdut`),
  `test/tb_soc.v`, and the README instantiation example.
- To target real FPGA hardware, swap `VirtualPlatform` for a `litex_boards` platform; SoC code stays.
