# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A CPU-less LiteX SoC (Wishbone bus) with UARTBone (UART→Wishbone bridge) and a LiteScope ILA,
emitted as **one self-contained Verilog file** (`build/virtual/gateware/soc.v`, `module soc`) meant
to be dropped into an external Verilog project as a black-box IP. Python ≥3.12, managed with `uv`;
the whole LiteX stack is pinned to git tag `2026.04` in `pyproject.toml` (`[tool.uv.sources]`).
Verilator/Yosys come from oss-cad-suite (installed by the devcontainer).

## Commands

```sh
uv sync                 # install the pinned LiteX stack into .venv
make generate           # uv run simple-soc --output-dir build/virtual -> soc.v, csr.csv, analyzer.csv
make lint               # verilator --lint-only on soc.v (benign generated-code warnings suppressed)
make simulate           # Verilator-compile soc.v + test/tb_soc.cpp, run -> "VERILATOR TB: PASS (4000 cycles)"
make clean              # rm -rf build
```

- `simple-soc` options: `--clk-freq` (default 100e6), `--baudrate` (115200), `--build-name` (soc),
  `--output-dir`. The IP must be clocked at `--clk-freq` for the UART baudrate to be correct.
- The Makefile only regenerates `soc.v` when `soc.py`/`build_soc.py` change; `make clean` to force.
- `TOP_MODULE` in the Makefile must match `--build-name` (the Makefile does not pass `--build-name`).
- There is no pytest suite; "testing" = `make lint` + `make simulate`. The C++ harness only drives
  stimulus for 4000 cycles and prints PASS — it has no assertions. Optional Yosys smoke test:
  `yosys -p "read_verilog build/virtual/gateware/soc.v; hierarchy -top soc; proc; opt; check"`.
- Icarus Verilog was deliberately dropped (vvp is impractically slow with the 4096×165-bit ILA memory).

## Architecture

- `src/litex_wb_litescope/soc.py` — the **entire system** in one file:
  - `PINS` dict → every top-level port of the IP (subsignals become `<group>_<sub>`, e.g.
    `serial_tx`). `direction` is informational; Migen infers real directions. `ILA_PROBES`/`ILA_DEPTH`
    select which pins the analyzer captures.
  - `VirtualPlatform(GenericPlatform)` — vendor-agnostic platform whose `build()` (mirroring
    `litex.build.sim.verilator.SimVerilatorToolchain.build`) only calls `get_verilog()` and writes
    a single flat `.v`; no toolchain runs.
  - `BaseSoC(SoCCore)` — `CRG` from `clk`/`rst` pins (must be set **before** `SoCCore.__init__`),
    `cpu_type="None"`, no UART/timer, `add_uartbone(uart_name="serial")`, `LiteScopeAnalyzer`.
- `src/litex_wb_litescope/build_soc.py` — `simple-soc` entry point; runs `Builder(...,
  compile_software=False, compile_gateware=False).build(run=False)`. `csr.csv` comes from Builder,
  `analyzer.csv` from `LiteScopeAnalyzer.do_exit`. Both are needed by host tools
  (`litex_server`/`litex_cli`/`litescope_cli`, see README).
- `src/litex_wb_litescope/__init__.py` — placeholder `litex-wb-litescope` script (hello world).
- `.github/prompts/plan-litexUartboneLiteScope.prompt.md` — original design plan and rationale.

## Invariants / gotchas

- Keep `ident=""` and `integrated_sram_size=0`: adding an identifier or SRAM/ROM introduces
  `.init`/`$readmem` file dependencies and breaks the "single self-contained file" property.
- Changing `PINS` changes the IP's port list — update `test/tb_soc.cpp` (Verilator exposes signals
  >64 bits as `uint32_t` word arrays, e.g. `probe3[0..3]`) and the README instantiation example.
- To target real FPGA hardware, swap `VirtualPlatform` for a `litex_boards` platform; SoC code stays.
