"""
LiteX UARTBone + LiteScope standalone IP core — whole-system definition.

This single file describes the entire system:
  * _io              - user-editable top-level pin/probe list (LiteX Pins/Subsignal).
  * VirtualPlatform  - tool-agnostic "virtual" platform that emits ONE
                       self-contained Verilog file (no vendor toolchain).
  * BaseSoC          - CPU-less SoC with UARTBone (host UART->Wishbone bridge)
                       and LiteScope ILA (user probes, 4k samples).

Build with:  uv run simple-soc --output-dir build/virtual
"""

import os

from migen.fhdl.structure import _Fragment

from litex.build.generic_platform import GenericPlatform, Pins, Subsignal
from litex.build.io import CRG
from litex.soc.integration.soc_core import SoCCore
from litescope import LiteScopeAnalyzer

# IOs ----------------------------------------------------------------------------------------------
# Every top-level port of the generated Verilog IP comes from an entry here (LiteX board-style io
# list, see litex_boards/platforms/*.py). Pins(<width>) = <width> unplaced pins (no package
# locations on a virtual platform); migen infers the actual port directions. Subsignals become
# <name>_<subsignal> ports (e.g. serial_tx).
# ILA probes are sampled directly in the clk domain (no synchronizers): drive them from logic
# synchronous to clk.

_io = [
    # Clk / Rst.
    ("clk", 0, Pins(1)),
    ("rst", 0, Pins(1)),  # active-high.

    # UARTBone serial link (host <-> SoC over UART).
    ("serial", 0,
        Subsignal("tx", Pins(1)),  # out.
        Subsignal("rx", Pins(1)),  # in.
    ),

    # LiteScope ILA probes (signals to observe with the logic analyzer).
    ("probe0", 0, Pins(1)),
    ("probe1", 0, Pins(4)),
    ("probe2", 0, Pins(32)),
    ("probe3", 0, Pins(128)),
]

# LiteScope ILA configuration.
ILA_PROBES = ["probe0", "probe1", "probe2", "probe3"]  # io groups tapped by the analyzer.
ILA_DEPTH  = 4096                                      # number of samples (4k).


def io_ports(io):
    """Top-level Verilog port names generated from an io list (<name> or <name>_<subsignal>)."""
    ports = []
    for name, _, *constraints in io:
        subs = [c.name for c in constraints if isinstance(c, Subsignal)]
        ports += [f"{name}_{sub}" for sub in subs] if subs else [name]
    return ports


# Virtual platform ---------------------------------------------------------------------------------

class VirtualPlatform(GenericPlatform):
    """Tool-agnostic "virtual" platform: emits a single standalone Verilog netlist.

    The whole SoC is lowered into ONE Verilog module whose top-level ports are
    exactly the pins declared in the io list, ready to be instantiated as a black-box
    IP core in an external Verilog project.
    """

    def __init__(self, io=_io, name="virtual", device="virtual"):
        GenericPlatform.__init__(self, device, io, name=name)

    def build(self, fragment, build_dir="build", build_name=None, build=True, run=False, **kwargs):
        # (Mirrors litex.build.sim.verilator.SimVerilatorToolchain.build but only
        #  produces the Verilog netlist -- no C++/Verilator compilation.)
        if not isinstance(fragment, _Fragment):
            fragment = fragment.get_fragment()
        self.finalize(fragment)
        os.makedirs(build_dir, exist_ok=True)
        name     = build_name or self.name
        v_output = self.get_verilog(fragment,
            name         = name,
            regular_comb = kwargs.get("regular_comb", True),
            hierarchical = kwargs.get("hierarchical", False))
        v_output.write(os.path.join(build_dir, name + ".v"))
        return v_output.ns


# SoC ----------------------------------------------------------------------------------------------

class BaseSoC(SoCCore):
    """CPU-less Wishbone-bus SoC: UARTBone + LiteScope ILA (+ ctrl CSRs, no SRAM)."""

    def __init__(self, platform, clk_freq=50e6, baudrate=115200,
                 ila_probes=None, ila_depth=4096, analyzer_csv="analyzer.csv", **kwargs):
        # CRG: drive the sys clock/reset from the user clk/rst pins
        # (vendor-agnostic, with power-on reset).
        rst = platform.request("rst", loose=True)
        self.crg = CRG(platform.request("clk"), 0 if rst is None else rst)

        SoCCore.__init__(self, platform, clk_freq,
            cpu_type   = "None",   # CPU-less bus SoC.
            with_uart  = False,    # serial pins are used by UARTBone below.
            with_timer = False,
            # No identifier module, no integrated SRAM/ROM: keeps the emitted
            # Verilog a truly self-contained single file (no external
            # .init/$readmem dependencies).
            ident                = "",
            integrated_sram_size = 0,
            **kwargs)

        # UARTBone: host access to the Wishbone bus / CSRs over UART.
        self.add_uartbone(name="uartbone", uart_name="serial", clk_freq=clk_freq, baudrate=baudrate)

        # LiteScope ILA: capture the user probes.
        probes = [platform.request(name) for name in (ila_probes or ILA_PROBES)]
        self.analyzer = LiteScopeAnalyzer(
            groups       = {0: probes},
            depth        = ila_depth,
            clock_domain = "sys",
            samplerate   = clk_freq,
            csr_csv      = analyzer_csv)
