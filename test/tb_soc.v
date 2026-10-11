// Self-checking Icarus Verilog testbench for the generated single-file LiteX IP.
//
// Same scenario as test/tb_soc.cpp (Verilator): drives real UARTBone traffic
// into serial_rx, decodes serial_tx, and checks:
//   1. ctrl_scratch reset value (0x12345678) over UARTBone,
//   2. ctrl_scratch write/readback,
//   3. a LiteScope capture: storage_done drops when armed, rises after the trigger.
// Calls $fatal on any failure.
//
// STATUS: not wired into the Makefile (Icarus support disabled, to be fixed). Manual run:
//   iverilog -g2012 -DCLK_FREQ=50000000 -DBAUDRATE=115200 -s tb_soc -o build/iverilog/sim \
//            build/virtual/gateware/soc.v test/tb_soc.v && vvp -n build/iverilog/sim
//
// Known issue: the generated soc.v uses `always @(*)` blocks that first assign defaults and
// then the real values with non-blocking `<=`. Each evaluation glitches its outputs, and in
// Icarus pairs of such blocks re-trigger each other within the same timestep:
//   * ILA input mux <-> storage FSM: with non-zero probe data this never settles (hang at t~0);
//   * UARTBone FSM <-> wishbone2csr: settles, but ~100x slower (~600 cycles/s), so a full run
//     takes ~15 min.
// Verilator's static scheduling is unaffected. Untested idea: rewrite `<=` as `=` inside
// `always @(*)` blocks of a sim-only copy of soc.v.
`timescale 1ns/1ps

`ifndef CLK_FREQ
`define CLK_FREQ 50000000
`endif
`ifndef BAUDRATE
`define BAUDRATE 115200
`endif
`ifndef TOP
`define TOP soc
`endif

module tb_soc;

    // CSR byte addresses (from build/virtual/csr.csv; update if _io/SoC change).
    localparam CSR_CTRL_SCRATCH           = 32'h804;
    localparam CSR_ANALYZER_TRIGGER_EN    = 32'h004;
    localparam CSR_ANALYZER_TRIGGER_DONE  = 32'h008;
    localparam CSR_ANALYZER_TRIGGER_MEMWR = 32'h00c;
    localparam CSR_ANALYZER_STORAGE_EN    = 32'h048;
    localparam CSR_ANALYZER_STORAGE_DONE  = 32'h04c;
    localparam CSR_ANALYZER_STORAGE_LEN   = 32'h050;
    localparam CSR_ANALYZER_STORAGE_OFS   = 32'h054;

    localparam integer BIT      = `CLK_FREQ / `BAUDRATE;  // clk cycles per UART bit.
    localparam real    CLK_HALF = 1.0e9 / `CLK_FREQ / 2.0;  // ns.

    reg          clk = 0, rst = 1, serial_rx = 1;  // UART idle high.
    wire         serial_tx;
    reg  [31:0]  cycle = 0;
    reg          probe0 = 0;
    reg  [3:0]   probe1 = 0;
    reg  [31:0]  probe2 = 0;
    reg  [127:0] probe3 = 0;

    `TOP dut (
        .clk       (clk),
        .rst       (rst),
        .serial_rx (serial_rx),
        .serial_tx (serial_tx),
        .probe0    (probe0),
        .probe1    (probe1),
        .probe2    (probe2),
        .probe3    (probe3)
    );

    always #(CLK_HALF) clk = ~clk;

    // Probes are held at 0 (non-zero probe data hangs Icarus, see the header).
    always @(posedge clk) cycle <= cycle + 1;

    // Host-side UART.
    task send_byte(input [7:0] b);
        integer i;
        begin
            serial_rx = 0; repeat (BIT) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                serial_rx = b[i]; repeat (BIT) @(posedge clk);
            end
            serial_rx = 1; repeat (BIT) @(posedge clk);
        end
    endtask

    task recv_byte(output [7:0] b);
        integer i;
        begin
            @(negedge serial_tx);
            repeat (BIT / 2) @(posedge clk);  // middle of start bit.
            for (i = 0; i < 8; i = i + 1) begin
                repeat (BIT) @(posedge clk);
                b[i] = serial_tx;
            end
            repeat (BIT) @(posedge clk);      // stop bit.
        end
    endtask

    task send_u32(input [31:0] v);
        begin
            send_byte(v[31:24]); send_byte(v[23:16]); send_byte(v[15:8]); send_byte(v[7:0]);
        end
    endtask

    // UARTBone: cmd (0x01 write / 0x02 read), length, 32-bit big-endian word address, [data].
    task csr_write(input [31:0] addr, input [31:0] value);
        begin
            send_byte(8'h01); send_byte(8'd1); send_u32(addr >> 2); send_u32(value);
            repeat (4 * BIT) @(posedge clk);
        end
    endtask

    task csr_read(input [31:0] addr, output [31:0] value);
        begin
            // Start listening before the command ends so the first response byte is not missed.
            fork
                begin send_byte(8'h02); send_byte(8'd1); send_u32(addr >> 2); end
                begin
                    recv_byte(value[31:24]); recv_byte(value[23:16]);
                    recv_byte(value[15:8]);  recv_byte(value[7:0]);
                end
            join
        end
    endtask

    integer failures = 0;

    task check(input [8*34-1:0] what, input [31:0] addr, input [31:0] expected);
        reg [31:0] got;
        begin
            csr_read(addr, got);
            if (got !== expected) failures = failures + 1;
            $display("[tb] %-34s 0x%08x (expected 0x%08x) %s",
                     what, got, expected, (got === expected) ? "OK" : "FAIL");
        end
    endtask

    // Watchdog: a lost UART byte must not hang the simulation.
    initial begin
        repeat (200 * 10 * BIT) @(posedge clk);
        $fatal(1, "ICARUS TB: FAIL (timeout at cycle %0d)", cycle);
    end

    initial begin
        repeat (20) @(posedge clk);
        rst = 0;
        repeat (100) @(posedge clk);

        check("ctrl_scratch reset value", CSR_CTRL_SCRATCH, 32'h12345678);
        csr_write(CSR_CTRL_SCRATCH, 32'hCAFEBABE);
        check("ctrl_scratch readback", CSR_CTRL_SCRATCH, 32'hCAFEBABE);

        // LiteScope: load one trigger condition (mask/value = 0 -> matches any sample once
        // the trigger is enabled). With no condition loaded, LiteScope triggers immediately.
        csr_write(CSR_ANALYZER_TRIGGER_MEMWR, 1);
        check("analyzer trigger loaded (done=0)", CSR_ANALYZER_TRIGGER_DONE, 0);
        csr_write(CSR_ANALYZER_STORAGE_LEN, 16);
        csr_write(CSR_ANALYZER_STORAGE_OFS, 0);
        csr_write(CSR_ANALYZER_STORAGE_EN,  1);
        check("analyzer armed (done=0)", CSR_ANALYZER_STORAGE_DONE, 0);
        csr_write(CSR_ANALYZER_TRIGGER_EN,  1);
        repeat (1000) @(posedge clk);
        check("analyzer triggered (done=1)", CSR_ANALYZER_TRIGGER_DONE, 1);
        check("analyzer captured (done=1)", CSR_ANALYZER_STORAGE_DONE, 1);

        if (failures != 0)
            $fatal(1, "ICARUS TB: FAIL (%0d check(s) failed, %0d cycles)", failures, cycle);
        $display("ICARUS TB: PASS (%0d cycles)", cycle);
        $finish;
    end

endmodule
