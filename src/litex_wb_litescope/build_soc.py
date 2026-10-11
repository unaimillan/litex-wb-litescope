"""
Build the LiteX UARTBone + LiteScope standalone IP core.

Usage:  uv run simple-soc --output-dir build/virtual
"""

import argparse
import os

from litex.soc.integration.builder import Builder

from litex_wb_litescope.soc import PINS, ILA_PROBES, ILA_DEPTH, VirtualPlatform, BaseSoC


def main():
    parser = argparse.ArgumentParser(description="Build LiteX UARTBone+LiteScope IP core.")
    parser.add_argument("--output-dir", default="build/virtual",   help="Output directory.")
    parser.add_argument("--build-name", default="soc",             help="Top module / IP name.")
    parser.add_argument("--clk-freq",   type=float, default=50e6,  help="System clock frequency (Hz).")
    parser.add_argument("--baudrate",   type=int,   default=115200, help="UARTBone baudrate.")
    args = parser.parse_args()
    if args.clk_freq < 16 * args.baudrate:
        parser.error(f"--clk-freq ({args.clk_freq:g} Hz) must be >= 16 x --baudrate ({args.baudrate}) for UARTBone to work.")

    output_dir = os.path.abspath(args.output_dir)
    os.makedirs(output_dir, exist_ok=True)

    # Whole-system definition (pins + platform + SoC).
    platform = VirtualPlatform(PINS, name=args.build_name)
    soc = BaseSoC(platform,
        clk_freq     = args.clk_freq,
        baudrate     = args.baudrate,
        ila_probes   = ILA_PROBES,
        ila_depth    = ILA_DEPTH,
        analyzer_csv = os.path.join(output_dir, "analyzer.csv"))

    # Generate the single-file Verilog IP (+ csr.csv / analyzer.csv).
    # No software, no vendor toolchain: this only emits the netlist.
    builder = Builder(soc,
        output_dir       = output_dir,
        compile_software = False,
        compile_gateware = False)
    builder.build(run=False)

    # Report.
    print("")
    print("[simple-soc] Generated standalone IP core:")
    print(f"[simple-soc]   Verilog:         {os.path.join(output_dir, 'gateware', args.build_name + '.v')}")
    print(f"[simple-soc]   CSR map:         {os.path.join(output_dir, 'csr.csv')}")
    print(f"[simple-soc]   Analyzer config: {os.path.join(output_dir, 'analyzer.csv')}")
    print("")
    print(f"[simple-soc] Instantiate '{args.build_name}' in your external Verilog project and connect:")
    ports = [f"{name}_{sub}" if "subsignals" in spec else name
             for name, spec in PINS.items()
             for sub in spec.get("subsignals", [None])]
    print("[simple-soc]   " + ", ".join(ports))


if __name__ == "__main__":
    main()
