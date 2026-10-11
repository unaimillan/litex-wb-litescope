// Self-checking Verilator harness for the generated single-file LiteX IP.
//
// Drives real UARTBone traffic into serial_rx, decodes serial_tx, and checks:
//   1. ctrl_scratch reset value (0x12345678) over UARTBone,
//   2. ctrl_scratch write/readback,
//   3. a LiteScope capture: storage_done drops when armed, rises after the trigger.
// Exits non-zero on any failure. Same scenario as test/tb_soc.v (Icarus).
//
// Build & run: make simulate   (verilator --prefix Vdut, -DCLK_FREQ/-DBAUDRATE via -CFLAGS)
#include "Vdut.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <vector>

#ifndef CLK_FREQ
#define CLK_FREQ 50000000
#endif
#ifndef BAUDRATE
#define BAUDRATE 115200
#endif

// CSR byte addresses (from build/virtual/csr.csv; update if _io/SoC change).
static const uint32_t CSR_CTRL_SCRATCH           = 0x804;
static const uint32_t CSR_ANALYZER_TRIGGER_EN    = 0x004;
static const uint32_t CSR_ANALYZER_TRIGGER_DONE  = 0x008;
static const uint32_t CSR_ANALYZER_TRIGGER_MEMWR = 0x00c;
static const uint32_t CSR_ANALYZER_STORAGE_EN    = 0x048;
static const uint32_t CSR_ANALYZER_STORAGE_DONE  = 0x04c;
static const uint32_t CSR_ANALYZER_STORAGE_LEN   = 0x050;
static const uint32_t CSR_ANALYZER_STORAGE_OFS   = 0x054;

static const unsigned BIT     = CLK_FREQ / BAUDRATE;  // clk cycles per UART bit.
static const unsigned TIMEOUT = 64 * BIT;             // max wait for a response byte.

static Vdut    *dut;
static uint64_t cycle = 0;

// serial_tx decoder state (host-side UART receiver).
static std::vector<uint8_t> rx_bytes;
static int      rx_state = 0;
static unsigned rx_cnt   = 0, rx_bit = 0;
static uint8_t  rx_shift = 0;

static void uart_rx_step(int tx) {
    switch (rx_state) {
    case 0: if (!tx) { rx_state = 1; rx_cnt = BIT / 2; } break;          // start bit edge.
    case 1: if (--rx_cnt == 0) {                                         // mid start bit.
                if (tx) rx_state = 0;
                else { rx_state = 2; rx_cnt = BIT; rx_bit = 0; rx_shift = 0; }
            } break;
    case 2: if (--rx_cnt == 0) {                                         // data bits, LSB first.
                rx_shift |= tx << rx_bit; rx_cnt = BIT;
                if (++rx_bit == 8) rx_state = 3;
            } break;
    case 3: if (--rx_cnt == 0) { rx_bytes.push_back(rx_shift); rx_state = 0; } break;  // stop bit.
    }
}

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    cycle++;
    // Probe stimulus for the ILA.
    dut->probe0    = cycle & 1;
    dut->probe1    = (cycle >> 1) & 0xF;
    dut->probe2    = (uint32_t)cycle;
    dut->probe3[0] = 0xDEADBEEFu;          // Verilator: >64-bit ports are uint32 word arrays.
    dut->probe3[1] = ~(uint32_t)cycle;
    dut->probe3[2] = (uint32_t)cycle << 1;
    dut->probe3[3] = (uint32_t)cycle;
    uart_rx_step(dut->serial_tx);
}

static void wait(unsigned n) { while (n--) tick(); }

static void send_byte(uint8_t b) {
    dut->serial_rx = 0; wait(BIT);
    for (int i = 0; i < 8; i++) { dut->serial_rx = (b >> i) & 1; wait(BIT); }
    dut->serial_rx = 1; wait(BIT);
}

static void send_u32(uint32_t v) { for (int i = 3; i >= 0; i--) send_byte(v >> (8 * i)); }

// UARTBone: cmd (0x01 write / 0x02 read), length, 32-bit big-endian word address, [data].
static void csr_write(uint32_t addr, uint32_t value) {
    send_byte(0x01); send_byte(1); send_u32(addr >> 2); send_u32(value);
    wait(4 * BIT);
}

static bool csr_read(uint32_t addr, uint32_t &value) {
    rx_bytes.clear();
    send_byte(0x02); send_byte(1); send_u32(addr >> 2);
    for (unsigned t = 0; rx_bytes.size() < 4 && t < 4 * TIMEOUT; t++) tick();
    if (rx_bytes.size() < 4) return false;
    value = (rx_bytes[0] << 24) | (rx_bytes[1] << 16) | (rx_bytes[2] << 8) | rx_bytes[3];
    return true;
}

static int failures = 0;

static void check(const char *what, uint32_t addr, uint32_t expected) {
    uint32_t got = 0;
    bool ok = csr_read(addr, got) && got == expected;
    if (!ok) failures++;
    printf("[tb] %-34s 0x%08x (expected 0x%08x) %s\n", what, got, expected, ok ? "OK" : "FAIL");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vdut;

    // Initial state: every input defined before reset is released.
    dut->clk = 0; dut->rst = 1; dut->serial_rx = 1;  // UART idle high.
    dut->probe0 = 0; dut->probe1 = 0; dut->probe2 = 0;
    for (int i = 0; i < 4; i++) dut->probe3[i] = 0;

    wait(20);
    dut->rst = 0;
    wait(100);

    check("ctrl_scratch reset value", CSR_CTRL_SCRATCH, 0x12345678);
    csr_write(CSR_CTRL_SCRATCH, 0xCAFEBABE);
    check("ctrl_scratch readback", CSR_CTRL_SCRATCH, 0xCAFEBABE);

    // LiteScope: load one trigger condition (mask/value = 0 -> matches any sample once
    // the trigger is enabled). With no condition loaded, LiteScope triggers immediately.
    csr_write(CSR_ANALYZER_TRIGGER_MEMWR, 1);
    check("analyzer trigger loaded (done=0)", CSR_ANALYZER_TRIGGER_DONE, 0);
    csr_write(CSR_ANALYZER_STORAGE_LEN, 16);
    csr_write(CSR_ANALYZER_STORAGE_OFS, 0);
    csr_write(CSR_ANALYZER_STORAGE_EN,  1);
    check("analyzer armed (done=0)", CSR_ANALYZER_STORAGE_DONE, 0);
    csr_write(CSR_ANALYZER_TRIGGER_EN,  1);
    wait(1000);
    check("analyzer triggered (done=1)", CSR_ANALYZER_TRIGGER_DONE, 1);
    check("analyzer captured (done=1)", CSR_ANALYZER_STORAGE_DONE, 1);

    dut->final();
    delete dut;
    printf("VERILATOR TB: %s (%llu cycles)\n", failures ? "FAIL" : "PASS", (unsigned long long)cycle);
    return failures ? 1 : 0;
}
