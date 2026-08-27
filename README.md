# LiteX UARTBone + LiteScope — standalone IP core

A minimal, **CPU-less** [LiteX](https://github.com/enjoy-digital/litex) SoC (Wishbone bus) with
two main components:

- **UARTBone** — a UART → Wishbone bridge. The host can access the SoC's bus/CSRs
  over a single serial link (no CPU needed).
- **LiteScope ILA** — an integrated logic analyzer that captures user probe signals
  (4 probes, 4k samples) and streams them out over the same UART.

The whole system (pins + platform + SoC) is described in **one Python file**
(`src/litex_wb_litescope/soc.py`). The build emits **one self-contained Verilog file**
(`build/virtual/gateware/soc.v`) that can be dropped into an external Verilog project and
instantiated as a black-box IP core.

---

## Requirements

- `uv` (astral) + Python ≥ 3.12
- LiteX 2026.04 stack — already pinned in `pyproject.toml` (`uv sync` installs it)
- For verification: **oss-cad-suite** (Verilator, Yosys, Icarus) — see below

## Install

```sh
uv sync
```

If `verilator`/`yosys` are not on your PATH, install oss-cad-suite to `/opt`:

```sh
cd /opt
OSS_TAG=$(curl -s https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
curl -L -o oss-cad-suite.tgz "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_TAG}/oss-cad-suite-linux-x64-${OSS_TAG}.tgz"
tar -xzf oss-cad-suite.tgz
echo 'source /opt/oss-cad-suite/environment' >> ~/.bashrc
source /opt/oss-cad-suite/environment
```

(Lighter alternative: `apt install verilator yosys`.)

## Build the IP

```sh
make generate          # == uv run simple-soc --output-dir build/virtual
```

(Equivalent manual command: `uv run simple-soc --output-dir build/virtual`)

Outputs:

| File | Purpose |
|------|---------|
| `build/virtual/gateware/soc.v` | **Single-file IP** — one `module soc`, fully self-contained (no `.init`/`$readmem` deps) |
| `build/virtual/csr.csv` | SoC register map (needed by `litex_cli` / `litescope_cli`) |
| `build/virtual/analyzer.csv` | LiteScope ILA signal/group layout (needed by `litescope_cli`) |

CLI options: `--clk-freq` (default 100 MHz), `--baudrate` (default 115200), `--build-name`.

> The generated IP must be clocked at `--clk-freq` for the UARTBone baudrate to be correct.

## Customize pins / probes

Edit the `PINS` dict at the top of `src/litex_wb_litescope/soc.py`, then rebuild.
Every top-level port of the IP comes from this dict:

```python
PINS = {
    "clk":    {"direction": "in",  "width": 1},       # system clock
    "rst":    {"direction": "in",  "width": 1},       # system reset (active-high)
    "serial": {"direction": "inout", "subsignals": {  # UARTBone serial link
        "tx": {"direction": "out", "width": 1},
        "rx": {"direction": "in",  "width": 1},
    }},
    # LiteScope ILA probes (signals to observe).
    "probe0": {"direction": "in", "width": 1},
    "probe1": {"direction": "in", "width": 4},
    "probe2": {"direction": "in", "width": 32},
    "probe3": {"direction": "in", "width": 128},
}
ILA_PROBES = ["probe0", "probe1", "probe2", "probe3"]
ILA_DEPTH  = 4096
```

`direction` is informational — Migen infers the actual port direction from the logic.

## Instantiate in an external Verilog project

```verilog
module top(
    input  wire clk,
    input  wire rst,
    input  wire serial_rx,
    output wire serial_tx,
    input  wire [3:0]   user_control,   // e.g. connect to probe1
    input  wire [31:0]  user_counter,   // e.g. connect to probe2
    // ...
);

    soc u_soc (
        .clk       (clk),
        .rst       (rst),
        .serial_tx (serial_tx),
        .serial_rx (serial_rx),
        .probe0    (1'b0),
        .probe1    (user_control),
        .probe2    (user_counter),
        .probe3    (128'b0)
    );

endmodule
```

## Verification

```sh
make lint       # 1. Verilator lint-only pass (benign generated-code warnings suppressed)
make simulate   # 2. Verilator-compile + run the black-box C++ harness -> "VERILATOR TB: PASS (4000 cycles)"
make clean      # remove all build artifacts
```

(Equivalent manual commands:)

```sh
# 1. Lint
verilator --lint-only -Wno-fatal -Wno-COMBDLY -Wno-WIDTHEXPAND \
          -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE \
          --top-module soc build/virtual/gateware/soc.v

# 2. Compile + run the black-box C++ harness (4000 cycles >= ILA depth)
verilator --cc --exe --timing -Wall -Wno-fatal --top-module soc \
          -Mdir build/verilator build/virtual/gateware/soc.v test/tb_soc.cpp
make -C build/verilator -f Vsoc.mk
./build/verilator/Vsoc
```

```sh
# 3. Optional: Yosys elaboration/structural smoke test
yosys -p "read_verilog build/virtual/gateware/soc.v; hierarchy -top soc; \
          proc; opt; check"  # -> "Found and reported 0 problems."
```

(Icarus `iverilog` simulation was intentionally dropped — its interpreted `vvp` runtime is
impractically slow with the 4096×165-bit ILA storage.)

## Host round-trip (UARTBone + LiteScope over real/simulated UART)

Once the IP is running (FPGA or simulation), a host can talk to it:

```sh
# TCP bridge to the SoC's UARTBone (baudrate must match the build)
litex_server --uart --uart-port=/dev/ttyUSB0 --uart-baudrate=115200

# Read/write CSRs (e.g. ctrl.scratch), dump registers
litex_cli --ident --regs --write 0x0/0x800/0x0 0x12345678

# Configure and run the ILA, dump a capture
litescope_cli --host localhost --port 1234 \
              --csv build/virtual/analyzer.csv \
              --csr-csv build/virtual/csr.csv \
              --rising-edge probe0 --dump dump.vcd
```

## Notes

- CPU-less by design: the host owns the bus through UARTBone; no software/BIOS runs inside.
- No integrated SRAM/identifier is instantiated, so `soc.v` has zero external file
  dependencies — it is literally one file.
- To target a real FPGA later, swap `VirtualPlatform` for a `litex_boards` platform
  (e.g. `LatticeECP5Platform`, `Xilinx7SeriesPlatform`, ...) — the SoC code stays unchanged.
