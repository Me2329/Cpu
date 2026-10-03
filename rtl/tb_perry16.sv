// tb_perry16.sv - testbench for perry16_cpu
//
//   iverilog -g2012 -o build/tb rtl/perry16_cpu.sv rtl/tb_perry16.sv
//   vvp build/tb +image=build/selftest.hex [+trace=build/rtl_trace.txt]
//
// Loads a raw binary (as a hex file, one byte per line) at 0x1000, runs the
// core and models the bare-metal devices used by tests/cpu/*.asm:
//   OUT 0xE9  -> character to the simulation log
//   OUT 0xF4  -> stop, value = exit code (printed as "EXIT <n>")
// With +trace, every instruction's PC and registers are written in the
// same order as the C++ emulator's --trace output, so the two models can
// be compared in lockstep (tests/run_tests.py does this).
`timescale 1ns/1ps
module tb_perry16;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // 64 KB RAM as two interleaved byte banks: one-cycle unaligned word access
  logic [7:0]   mem [0:65535];
  logic [15:0]  mem_addr, mem_wdata, mem_rdata;
  logic         mem_rd, mem_wr, mem_word;
  logic [15:0]  io_addr, io_wdata, io_rdata;
  logic         io_rd, io_wr;
  logic         irq_ack, bios_req, halted, insn_start;
  logic [7:0]   bios_vector;
  logic [15:0]  dbg_pc, dbg_flags;
  logic [127:0] dbg_regs;

  assign mem_rdata = {mem[mem_addr + 16'd1], mem[mem_addr]};
  assign io_rdata  = 16'hFFFF;

  always @(posedge clk) begin
    if (mem_wr) begin
      mem[mem_addr] <= mem_wdata[7:0];
      if (mem_word) mem[mem_addr + 16'd1] <= mem_wdata[15:8];
    end
  end

  perry16_cpu #(.RESET_PC(16'h1000), .RESET_SP(16'h1000), .RESET_FLAGS(16'h0200)) dut (
    .clk(clk), .rst_n(rst_n),
    .mem_addr(mem_addr), .mem_rd(mem_rd), .mem_wr(mem_wr), .mem_word(mem_word),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata),
    .io_addr(io_addr), .io_rd(io_rd), .io_wr(io_wr), .io_wdata(io_wdata), .io_rdata(io_rdata),
    .irq(1'b0), .irq_vector(8'h00), .irq_ack(irq_ack),
    .bios_req(bios_req), .bios_vector(bios_vector), .bios_done(1'b1),
    .halted(halted), .insn_start(insn_start),
    .dbg_pc(dbg_pc), .dbg_regs(dbg_regs), .dbg_flags(dbg_flags));

  integer trace_fd = 0;
  longint unsigned cycles = 0, insns = 0;

  always @(posedge clk) begin
    if (rst_n) begin
      cycles <= cycles + 1;
      if (insn_start) begin
        insns <= insns + 1;
        if (trace_fd != 0)
          $fdisplay(trace_fd, "%04X AX=%04X BX=%04X CX=%04X DX=%04X SP=%04X BP=%04X SI=%04X DI=%04X F=%04X",
                    dbg_pc, dbg_regs[15:0], dbg_regs[31:16], dbg_regs[47:32], dbg_regs[63:48],
                    dbg_regs[79:64], dbg_regs[95:80], dbg_regs[111:96], dbg_regs[127:112], dbg_flags);
      end
      if (io_wr && io_addr == 16'h00E9) $write("%c", io_wdata[7:0]);
      if (io_wr && io_addr == 16'h00F4) begin
        $display("EXIT %0d  (%0d instructions, %0d cycles, %.2f CPI)", io_wdata[7:0], insns, cycles,
                 real'(cycles) / real'(insns));
        if (trace_fd != 0) $fclose(trace_fd);
        $finish;
      end
      if (halted) begin
        $display("EXIT 255  (halted with interrupts disabled at %04X)", dbg_pc);
        $finish;
      end
    end
  end

  initial begin
    string image, trace;
    for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
    if (!$value$plusargs("image=%s", image)) image = "build/selftest.hex";
    $readmemh(image, mem);              // file starts with an @1000 address record
    if ($value$plusargs("trace=%s", trace)) trace_fd = $fopen(trace, "w");
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (5000000) @(posedge clk);
    $display("EXIT 254  (timeout)");
    $finish;
  end
endmodule
