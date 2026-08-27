// Black-box C++ harness for the generated single-file LiteX IP (module `soc`).
//
// Build & run:
//   verilator --cc --exe --timing -Wall -Wno-fatal --top-module soc \
//             -Mdir build/verilator build/virtual/gateware/soc.v test/tb_soc.cpp
//   make -C build/verilator -f Vsoc.mk
//   ./build/verilator/Vsoc
#include "Vsoc.h"
#include "verilated.h"

#include <cstdio>
#include <cstring>

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vsoc *dut = new Vsoc;

    // Initial state.
    dut->clk       = 0;
    dut->rst       = 1;
    dut->serial_rx = 1;  // UART idle.
    dut->probe0    = 0;
    dut->probe1    = 0;
    dut->probe2    = 0;

    const unsigned CYCLES = 4000;  // >= ILA depth (4096) to exercise the analyzer.
    for (unsigned i = 0; i < CYCLES; i++) {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();

        if (i == 20)
            dut->rst = 0;  // Release reset.

        // Probe stimulus for the ILA.
        if (i > 20) {
            dut->probe0 = (i & 1u) ? 1u : 0u;
            dut->probe1 = (i >> 1) & 0xF;
            dut->probe2 = i;
            // probe3 is 128-bit: Verilator exposes it as 4 uint32 words
            // ([0] = bits 31:0 ... [3] = bits 127:96).
            dut->probe3[3] = i;        // bits 127:96
            dut->probe3[2] = i << 1;   // bits 95:64
            dut->probe3[1] = ~i;       // bits 63:32
            dut->probe3[0] = 0xDEADBEEFu; // bits 31:0
        }
    }

    dut->final();
    delete dut;
    printf("VERILATOR TB: PASS (%u cycles)\n", CYCLES);
    return 0;
}
