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
- For verification: **oss-cad-suite** (Verilator; optionally Yosys) — see below

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
make build             # generate the IP and copy the final files to dist/
make generate          # only generate into build/virtual/
```

(Equivalent manual command: `uv run simple-soc --output-dir build/virtual`)

Core parameters are Makefile variables (forwarded to `simple-soc`; changing them triggers a rebuild):

```sh
make build CLK_FREQ=100000000 BAUDRATE=1000000 BUILD_NAME=my_ila
```

Outputs:

| File | Purpose |
|------|---------|
| `soc.v` | **Single-file IP** — one `module soc`, fully self-contained (no `.init`/`$readmem` deps) |
| `csr.csv` / `csr.json` | SoC register map (needed by `litex_cli` / `litescope_cli`) |
| `analyzer.csv` | LiteScope ILA signal/group layout and samplerate (needed by `litescope_cli`) |

`make build` copies these to `dist/`; `make generate` leaves them in `build/virtual/` (`soc.v` under `gateware/`).

CLI options: `--clk-freq` (default 50 MHz), `--baudrate` (default 115200), `--build-name`, `--output-dir`.
`--clk-freq` must be at least 16× `--baudrate`.

> The generated IP must be clocked at `--clk-freq` for the UARTBone baudrate to be correct.

## Customize pins / probes

Edit the `_io` list at the top of `src/litex_wb_litescope/soc.py`, then rebuild.
It uses the same `Pins`/`Subsignal` format as LiteX board files (`litex_boards/platforms/*.py`).
Every top-level port of the IP comes from this list:

```python
_io = [
    # Clk / Rst.
    ("clk", 0, Pins(1)),
    ("rst", 0, Pins(1)),  # active-high.

    # UARTBone serial link (host <-> SoC over UART).
    ("serial", 0,
        Subsignal("tx", Pins(1)),  # out.
        Subsignal("rx", Pins(1)),  # in.
    ),

    # LiteScope ILA probes (signals to observe).
    ("probe0", 0, Pins(1)),
    ("probe1", 0, Pins(4)),
    ("probe2", 0, Pins(32)),
    ("probe3", 0, Pins(128)),
]
ILA_PROBES = ["probe0", "probe1", "probe2", "probe3"]
ILA_DEPTH  = 4096
```

`Pins(<width>)` declares `<width>` unplaced pins, because a virtual platform has no package locations.
Subsignals become `<name>_<subsignal>` ports (`serial_tx`, `serial_rx`).
Migen infers port directions from the logic.
Probes are sampled in the `clk` domain without synchronizers, so drive them from logic synchronous to `clk`.

If you change `_io`, update the testbenches (`test/tb_soc.cpp`, `test/tb_soc.v`) too.

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
make test       # lint + Verilator self-checking simulation (~10 s)
make clean      # remove all build artifacts (build/, dist/)
```

The Verilator testbench (`test/tb_soc.cpp`) is **self-checking** and talk to the core over real UART frames (UARTBone
protocol). It checks:

1. that `ctrl_scratch` reads its reset value `0x12345678`;
2. a `ctrl_scratch` write followed by a readback;
3. a LiteScope capture: load a trigger, arm the storage (`done=0`), enable the trigger, and get `done=1`.

It exits non-zero on any failure.

> **Icarus support is disabled for now.** `test/tb_soc.v` has the same checks, but it is not
> wired into the Makefile. Icarus hangs or crawls on the generated comb logic (`always @(*)`
> blocks with default-then-override assignments re-trigger each other). Details are in that
> file's header.

```sh
# Optional: Yosys elaboration/structural smoke test
yosys -p "read_verilog build/virtual/gateware/soc.v; hierarchy -top soc; \
          proc; opt; check"  # -> "Found and reported 0 problems."
```

Resource estimate (Yosys, no vendor tools): `make -j synth-estimate` synthesizes `soc.v` for
Intel MAX10, Gowin, Xilinx 7-series and Lattice MachXO2 (`LATTICE_FAMILY=xo2`) and prints the
cell counts. Use `make synth-intel` (or `-gowin`, `-xilinx`, `-lattice`) to run a single target.
With the default config, MAX10 uses about 2.6k LUT4 / 1.7k FF (≈2.7–3.5k LEs) plus 93 RAM blocks.

## Host round-trip (UARTBone + LiteScope over real/simulated UART)

Once the IP is running (FPGA or simulation), a host can talk to it:

```sh
# TCP bridge to the SoC's UARTBone (baudrate must match the build)
litex_server --uart --uart-port=/dev/ttyUSB0 --uart-baudrate=115200

# Read/write CSRs by name, dump registers (no --ident: the core has no identifier)
litex_cli --csr-csv dist/csr.csv --read ctrl_scratch          # -> 0x12345678
litex_cli --csr-csv dist/csr.csv --write ctrl_scratch 0xcafebabe
litex_cli --csr-csv dist/csr.csv --regs

# Configure and run the ILA, dump a capture
litescope_cli --host localhost --port 1234 \
              --csv dist/analyzer.csv \
              --csr-csv dist/csr.csv \
              --rising-edge probe0 --dump dump.vcd
```

## Notes

- CPU-less by design: the host owns the bus through UARTBone; no software/BIOS runs inside.
- No integrated SRAM/identifier is instantiated, so `soc.v` has zero external file
  dependencies — it is literally one file.
- To target a real FPGA later, swap `VirtualPlatform` for a `litex_boards` platform
  (e.g. `LatticeECP5Platform`, `Xilinx7SeriesPlatform`, ...) — the SoC code stays unchanged.
