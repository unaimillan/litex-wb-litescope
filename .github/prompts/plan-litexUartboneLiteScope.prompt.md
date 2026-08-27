## Plan: LiteX UARTBone + LiteScope standalone IP core

**TL;DR** — A CPU-less, minimal LiteX SoC (Wishbone bus) with **UARTBone** (host UART→Wishbone bridge) and **LiteScope ILA**, built on a custom vendor-agnostic "virtual" platform. The **entire system** (pins, platform, SoC) is described in **one Python file**; the build emits **one self-contained Verilog file** (`soc.v`) plus `csr.csv`/`analyzer.csv`, instantiable as a black-box IP in an external Verilog project. Verification is **full**: Verilator lint + compile/run (black-box C++ harness) + optional Yosys synthesis smoke test, using **oss-cad-suite** (installed to `/opt` if the tools are absent). Icarus Verilog simulation was **dropped** — its interpreted `vvp` run was impractically slow with the 4096×165-bit ILA storage.

All APIs verified against the installed LiteX **2026.04** (in `.venv`).

**Decisions**
- CPU-less bus SoC (`cpu_type="None"`); CSRs at `0x00000000` (CPUNone map); no timer; no BIOS.
- Pins: editable Python dict (user edits + re-runs).
- ILA: 4 probes, widths `[1, 4, 32, 128]`, depth `4096` (4k samples). System pins: `clk`, `rst`; UARTBone `serial` (tx/rx).
- **Single file** `soc.py` describes the whole system (pins + platform + SoC). A thin `build_soc.py` entry point builds it.
- **Verification:** generation → structural check → Verilator lint + compile/run → optional Yosys synth smoke; oss-cad-suite to `/opt` if tools missing. (Icarus dropped for slowness.)

**Steps**

*Phase 1 — Single system-definition file*
1. `src/litex_wb_litescope/soc.py` — **one file describing the whole system**, containing:
   - `PINS` dict — user-editable pin spec:
     - System: `clk` (in, 1), `rst` (in, 1)
     - UARTBone: `serial` (subsignals `tx` out 1 / `rx` in 1)
     - ILA probes: `probe0` (in, 1), `probe1` (in, 4), `probe2` (in, 32), `probe3` (in, 128)
     - (`direction` is informational — migen infers port direction from logic)
   - `ILA_PROBES = ["probe0", "probe1", "probe2", "probe3"]`; `ILA_DEPTH = 4096`
   - `build_io(pins)` — converts the dict to a LiteX `io` list via `Pins`/`Subsignal` (symbolic locations; top-level port names = group/subsignal names)
   - `class VirtualPlatform(GenericPlatform)` — `__init__(pins, name)` → `GenericPlatform("virtual", build_io(pins), name=name)`; override `build(...)` mirroring `litex/build/sim/verilator.py` (~L210): `platform.finalize(fragment)` → `get_verilog(fragment, name=build_name)` → write single `<build_name>.v`, return `vns`. No vendor toolchain → everything inlined into **one** module.
   - `class BaseSoC(SoCCore)`:
     - `self.crg = CRG(platform.request("clk"), platform.request("rst", loose=True) or 0)` **before** `SoCCore.__init__` (reuse `litex.build.io.CRG`, ~L305 — vendor-agnostic power-on reset)
     - `SoCCore.__init__(..., cpu_type="None", with_uart=False, with_timer=False, ident="", integrated_sram_size=0)` — no identifier/SRAM modules, so the emitted Verilog is truly self-contained (zero external `.init`/`$readmem` deps)
     - `self.add_uartbone(name="uartbone", uart_name="serial", clk_freq=..., baudrate=...)` (in `litex/soc/integration/soc.py` ~L1921)
     - `self.analyzer = LiteScopeAnalyzer({0: probes}, depth=ILA_DEPTH, clock_domain="sys", csr_csv=<abs path>)` (`litescope/core.py` ~L364; import `from litescope import LiteScopeAnalyzer`)

*Phase 2 — Thin build entry + wiring*
2. `src/litex_wb_litescope/build_soc.py` — `main()` importing `PINS, ILA_PROBES, ILA_DEPTH, VirtualPlatform, BaseSoC` from `.soc`; args `--output-dir build/virtual`, `--build-name soc`, `--clk-freq 100e6`, `--baudrate 115200`; then `Builder(soc, output_dir=..., compile_software=False, compile_gateware=False).build(run=False)` → writes `soc.v` (platform) + `csr.csv` (Builder) + `analyzer.csv` (via `soc.do_exit` → `LiteScopeAnalyzer.do_exit`).
3. `pyproject.toml` — add `[project.scripts] simple-soc = "litex_wb_litescope.build_soc:main"`; run `uv sync`.

*Phase 3 — Toolchain (oss-cad-suite to /opt if needed)*
4. Check `which iverilog verilator`. If absent, install oss-cad-suite to `/opt`:
   - `cd /opt`
   - resolve latest tag: `OSS_TAG=$(curl -s https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')`
   - download `https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_TAG}/oss-cad-suite-linux-x64-${OSS_TAG}.tgz`
   - `tar -xzf oss-cad-suite-*.tgz` → `/opt/oss-cad-suite`
   - add `source /opt/oss-cad-suite/environment` to shell profile; `source` it
   - verify: `iverilog -V`, `verilator --version` (also gives `yosys`)
   - (Lighter fallback if tarball unsuitable: `apt install iverilog verilator`.)

*Phase 4 — Full verification*
5. `uv run simple-soc --output-dir build/virtual` → expect `build/virtual/gateware/soc.v` (single `module soc`), `csr.csv`, `analyzer.csv`.
6. Structural check: exactly one `module`; ports `clk, rst, serial_tx, serial_rx, probe0, probe1, probe2, probe3`; sanity on `analyzer.csv` (probe widths 1/4/32/128, depth 4096) and `csr.csv` (`analyzer_*`, `ctrl_*`).
7. ~~Icarus Verilog~~ — **dropped during implementation**: the interpreted `vvp` run with the 4096×165-bit ILA storage was impractically slow (>6 min for 4k cycles). `test/tb_soc.v` and `build/sim/` were removed.
8. **Verilator** — lint: `verilator --lint-only -Wno-fatal -Wno-COMBDLY -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE --top-module soc build/virtual/gateware/soc.v` (exit 0, 0 warnings — suppressed classes are benign generated-code styles); compile+run: C++ harness `test/tb_soc.cpp` (drives all 4 probes incl. 128-bit `probe3`) with `verilator --cc --exe --timing -Wall -Wno-fatal --top-module soc -Mdir build/verilator build/virtual/gateware/soc.v test/tb_soc.cpp`, then `make -C build/verilator -f Vsoc.mk` and `./build/verilator/Vsoc` (4000 cycles ≥ ILA depth) → PASS.
9. Optional bonus (oss-cad-suite ships `yosys`): `yosys -p "read_verilog build/virtual/gateware/soc.v; hierarchy -top soc; proc; opt; memory; opt; techmap; opt; stat"` (lighter flow, no ABC — full `synth` is heavy with the 4096×165-bit ILA) to prove synthesizability as a black-box IP.

**Relevant files**
- New: `src/litex_wb_litescope/soc.py` (whole-system definition: pins+platform+soc), `src/litex_wb_litescope/build_soc.py` (thin CLI), `test/tb_soc.cpp` (Verilator harness; `test/tb_soc.v` removed with Icarus)
- Edit: `pyproject.toml` (add `simple-soc` script)
- Reference: `litex/build/sim/verilator.py` (L210), `litex/build/io.py` (`CRG` L305), `litex/soc/integration/soc.py` (`add_uartbone` L1921), `litescope/core.py` (`LiteScopeAnalyzer` L364), `litex/soc/integration/builder.py` (`Builder` L67)

**Excluded (this iteration)**
- Running the generated IP through the host round-trip (`litex_server`/`litescope_cli`) — documented for later.
- Real FPGA bitstream / physical pin constraints; memory/ethernet; CPU inclusion.

**Further Considerations**
1. Later host round-trip: `litex_server --uart --uart-port=... --uart-baudrate=<match>` → `litex_cli --ident/--read/--write` and `litescope_cli --rising-edge probe0 --dump dump.vcd` (baudrate must equal the SoC's).
2. Real board later: swap `VirtualPlatform` for a `litex_boards` platform — SoC code unchanged.
