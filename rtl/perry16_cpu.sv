// perry16_cpu.sv - PERRY-16 CPU core (multi-cycle, synthesizable SystemVerilog)
`timescale 1ns/1ps
//
// Implements exactly the ISA executed by emu/cpu.cpp (see docs/ISA.md):
// 8 x 16-bit registers, PC, FLAGS (CF bit0, ZF bit6, SF bit7, IF bit9, OF bit11),
// two-operand ALU group with 8 addressing modes, control flow, stack,
// interrupts through the IVT at 0x0000, port I/O, string operations and
// the BIOS trap used for high-level emulated firmware.
//
// Memory interface: 64 KB byte-addressed RAM organised as two interleaved
// 8-bit banks, so a byte or an (unaligned) 16-bit word is transferred in a
// single cycle. Reads are asynchronous: mem_rdata is valid in the same
// cycle as mem_addr / mem_rd (as with on-chip LUT RAM or an async SRAM).
//
// Timing: FETCH (opcode + mode byte) 1 cycle, immediate 1 cycle, then
// 1-3 cycles of execute / memory access depending on the instruction.
// MUL/DIV use the combinational * and / operators for clarity; a size-
// optimised implementation would iterate them over 16 cycles.
module perry16_cpu #(
  parameter logic [15:0] RESET_PC    = 16'h1000,
  parameter logic [15:0] RESET_SP    = 16'h1000,
  parameter logic [15:0] RESET_FLAGS = 16'h0200
) (
  input  logic        clk,
  input  logic        rst_n,
  // memory
  output logic [15:0] mem_addr,
  output logic        mem_rd,
  output logic        mem_wr,
  output logic        mem_word,     // 1 = 16-bit access, 0 = byte
  output logic [15:0] mem_wdata,
  input  logic [15:0] mem_rdata,
  // port I/O
  output logic [15:0] io_addr,
  output logic        io_rd,
  output logic        io_wr,
  output logic [15:0] io_wdata,
  input  logic [15:0] io_rdata,
  // maskable interrupt request (level), delivered when IF = 1
  input  logic        irq,
  input  logic [7:0]  irq_vector,
  output logic        irq_ack,
  // BIOS trap: firmware services implemented outside the core
  output logic        bios_req,
  output logic [7:0]  bios_vector,
  input  logic        bios_done,
  // status / debug
  output logic        halted,
  output logic        insn_start,   // 1 in the cycle an instruction is fetched
  output logic [15:0] dbg_pc,
  output logic [127:0] dbg_regs,    // {DI,SI,BP,SP,DX,CX,BX,AX}
  output logic [15:0] dbg_flags
);

  // ---------------------------------------------------------------- constants
  localparam int AX = 0, BX = 1, CX = 2, DX = 3, SP = 4, BP = 5, SI = 6, DI = 7;
  localparam int F_CF = 0, F_ZF = 6, F_SF = 7, F_IF = 9, F_OF = 11;

  typedef enum logic [4:0] {
    OP_MOV, OP_ADD, OP_SUB, OP_CMP, OP_AND, OP_OR, OP_XOR, OP_TEST, OP_ADC, OP_SBB,
    OP_MUL, OP_IMUL, OP_DIV, OP_IDIV, OP_SHL, OP_SHR, OP_SAR, OP_ROL, OP_ROR,
    OP_LEA, OP_XCHG, OP_MOVSX
  } alu_op_e;
  localparam int ALU_COUNT = 22;

  typedef enum logic [4:0] {
    S_FETCH, S_IMM, S_EXEC, S_RD_SRC, S_RD_DST, S_ALU, S_WR, S_XCHG_WR,
    S_PUSH, S_POP, S_INT1, S_INT2, S_INT3, S_PUSHA, S_POPA,
    S_STR_RD, S_STR_WR, S_BIOS, S_HALT
  } state_e;

  // pop destinations
  localparam logic [3:0] PD_PC = 4'd8, PD_FLAGS = 4'd9, PD_IRET = 4'd10;

  // ---------------------------------------------------------------- state
  state_e      state;
  logic [15:0] R [8];
  logic [15:0] pc, flags, ipc;      // ipc = address of the current instruction
  logic [7:0]  op, m;
  logic [15:0] imm;
  logic [15:0] src, dst, ea;
  logic [15:0] push_val;
  state_e      push_next;
  logic [3:0]  pop_dst;
  logic [7:0]  int_vec;
  logic [2:0]  seq;                 // PUSHA / POPA index
  logic [15:0] sp_orig;

  // ---------------------------------------------------------------- decode
  wire        is_alu  = op < 8'hC0;
  wire [4:0]  alu_op  = op[7:3];
  wire [2:0]  mode    = op[2:0];
  wire        bmode   = m[7];
  wire [2:0]  rd      = m[6:4];
  wire [2:0]  rs      = m[2:0];
  wire        mode_imm = (mode == 3'd1) || (mode == 3'd3) || (mode == 3'd4) ||
                         (mode == 3'd6) || (mode == 3'd7);
  wire        src_mem = (mode == 3'd2) || (mode == 3'd3) || (mode == 3'd4);
  wire        dst_mem = mode >= 3'd5;
  wire        misc_imm = (op == 8'hC2) || (op == 8'hC4) || (op == 8'hCB) || (op == 8'hD0) ||
                         (op == 8'hD2) || (op == 8'hDC) || (op == 8'hDD);
  wire        has_imm = is_alu ? mode_imm : misc_imm;

  function automatic logic [15:0] calc_ea(input logic [2:0] md, input logic [15:0] r_s,
                                          input logic [15:0] r_d, input logic [15:0] im);
    case (md)
      3'd2: calc_ea = r_s;
      3'd3: calc_ea = r_s + im;
      3'd4: calc_ea = im;
      3'd5: calc_ea = r_d;
      3'd6: calc_ea = r_d + im;
      default: calc_ea = im;
    endcase
  endfunction

  function automatic logic cond(input logic [3:0] cc, input logic [15:0] f);
    logic cf, zf, sf, of;
    cf = f[F_CF]; zf = f[F_ZF]; sf = f[F_SF]; of = f[F_OF];
    case (cc)
      4'd0:  cond = 1'b1;
      4'd1:  cond = zf;
      4'd2:  cond = !zf;
      4'd3:  cond = cf;
      4'd4:  cond = !cf;
      4'd5:  cond = sf;
      4'd6:  cond = !sf;
      4'd7:  cond = of;
      4'd8:  cond = !of;
      4'd9:  cond = !cf && !zf;
      4'd10: cond = cf || zf;
      4'd11: cond = sf != of;
      4'd12: cond = sf == of;
      4'd13: cond = !zf && (sf == of);
      4'd14: cond = zf || (sf != of);
      default: cond = 1'b0;
    endcase
  endfunction

  // ---------------------------------------------------------------- ALU
  typedef struct packed {
    logic [15:0] res;
    logic [15:0] flags;
    logic [15:0] hi;       // MUL high word / DIV remainder
    logic        write;    // store the result (0 for CMP/TEST)
    logic        hi_valid; // hi is meaningful (MUL/IMUL/DIV/IDIV)
    logic        div0;     // divide by zero
  } alu_out_t;

  function automatic alu_out_t alu(input logic [4:0] o, input logic [15:0] d_in,
                                   input logic [15:0] s_in, input logic byte_op,
                                   input logic [15:0] f_in);
    alu_out_t r;
    logic [16:0] mask, sign;
    logic [16:0] d, s, res;
    logic [31:0] p;
    logic signed [31:0] sp32, sa, sb;
    logic [15:0] q, rem;
    int n, width;
    logic out_bit;
    r = '0;
    r.flags = f_in;
    r.write = 1'b1;
    mask  = byte_op ? 17'h000FF : 17'h0FFFF;
    sign  = byte_op ? 17'h00080 : 17'h08000;
    width = byte_op ? 8 : 16;
    d = {1'b0, d_in} & mask;
    s = {1'b0, s_in} & mask;
    res = '0;
    case (o)
      OP_MOV: res = s;
      OP_ADD, OP_ADC: begin
        res = d + s + ((o == OP_ADC && f_in[F_CF]) ? 17'd1 : 17'd0);
        r.flags[F_CF] = res > mask;
        r.flags[F_OF] = ((~(d ^ s) & (d ^ res) & sign) != 0);
      end
      OP_SUB, OP_SBB, OP_CMP: begin
        logic [16:0] c;
        c = (o == OP_SBB && f_in[F_CF]) ? 17'd1 : 17'd0;
        res = d - s - c;
        r.flags[F_CF] = d < (s + c);
        r.flags[F_OF] = (((d ^ s) & (d ^ res) & sign) != 0);
        if (o == OP_CMP) r.write = 1'b0;
      end
      OP_AND, OP_TEST: res = d & s;
      OP_OR:  res = d | s;
      OP_XOR: res = d ^ s;
      OP_MUL: begin
        p = d[15:0] * s[15:0];
        res = {1'b0, p[15:0]};
        r.hi = p[31:16];
        r.hi_valid = 1'b1;
        r.flags[F_CF] = byte_op ? (p[31:8] != 0) : (p[31:16] != 0);
        r.flags[F_OF] = r.flags[F_CF];
      end
      OP_IMUL: begin
        sa = byte_op ? {{24{d[7]}}, d[7:0]} : {{16{d[15]}}, d[15:0]};
        sb = byte_op ? {{24{s[7]}}, s[7:0]} : {{16{s[15]}}, s[15:0]};
        sp32 = sa * sb;
        p = sp32;
        res = {1'b0, p[15:0]};
        r.hi = p[31:16];
        r.hi_valid = 1'b1;
        if (byte_op) r.flags[F_CF] = $signed({{24{p[7]}}, p[7:0]}) != sp32;
        else         r.flags[F_CF] = $signed({{16{p[15]}}, p[15:0]}) != sp32;
        r.flags[F_OF] = r.flags[F_CF];
      end
      OP_DIV, OP_IDIV: begin
        if (s == 0) begin
          r.div0 = 1'b1;
          r.write = 1'b0;
        end else begin
          if (o == OP_DIV) begin
            q = d[15:0] / s[15:0];
            rem = d[15:0] % s[15:0];
          end else begin
            sa = byte_op ? {{24{d[7]}}, d[7:0]} : {{16{d[15]}}, d[15:0]};
            sb = byte_op ? {{24{s[7]}}, s[7:0]} : {{16{s[15]}}, s[15:0]};
            sp32 = sa / sb;
            q = sp32[15:0];
            sp32 = sa % sb;
            rem = sp32[15:0];
          end
          res = {1'b0, q};
          r.hi = rem;
          r.hi_valid = 1'b1;
        end
      end
      OP_SHL, OP_SHR, OP_SAR, OP_ROL, OP_ROR: begin
        n = int'(s[4:0]);
        res = d;
        if (n != 0) begin
          for (int i = 0; i < 31; i++) begin
            if (i < n) begin
              case (o)
                OP_SHL: begin out_bit = (res & sign) != 0; res = (res << 1) & mask; end
                OP_SHR: begin out_bit = res[0]; res = res >> 1; end
                OP_SAR: begin out_bit = res[0]; res = (res >> 1) | (res & sign); end
                OP_ROL: begin out_bit = (res & sign) != 0; res = ((res << 1) | {16'd0, out_bit}) & mask; end
                default: begin out_bit = res[0]; res = (res >> 1) | (out_bit ? sign : 17'd0); end
              endcase
              r.flags[F_CF] = out_bit;
            end
          end
          r.flags[F_OF] = ((res ^ d) & sign) != 0;
        end
      end
      default: res = d;
    endcase
    // zero / sign flags
    if (o == OP_AND || o == OP_TEST || o == OP_OR || o == OP_XOR) begin
      r.flags[F_CF] = 1'b0;
      r.flags[F_OF] = 1'b0;
      if (o == OP_TEST) r.write = 1'b0;
    end
    if (o != OP_MOV && !r.div0 && !((o == OP_ROL || o == OP_ROR)) &&
        !((o == OP_SHL || o == OP_SHR || o == OP_SAR) && s[4:0] == 0)) begin
      r.flags[F_ZF] = (res & mask) == 0;
      r.flags[F_SF] = (res & sign) != 0;
    end
    if ((o == OP_MUL || o == OP_IMUL)) begin
      // C++ model: ZF/SF from the full product, masked to the operand width
      r.flags[F_ZF] = (p[16:0] & mask) == 0;
      r.flags[F_SF] = (p[16:0] & sign) != 0;
    end
    r.res = res[15:0] & mask[15:0];
    return r;
  endfunction

  // ---------------------------------------------------------------- bus drive
  always_comb begin
    mem_addr  = 16'h0;
    mem_rd    = 1'b0;
    mem_wr    = 1'b0;
    mem_word  = 1'b1;
    mem_wdata = 16'h0;
    io_addr   = 16'h0;
    io_rd     = 1'b0;
    io_wr     = 1'b0;
    io_wdata  = 16'h0;
    irq_ack   = 1'b0;
    bios_req  = 1'b0;
    bios_vector = m;
    case (state)
      S_FETCH: begin
        if (irq && flags[F_IF]) irq_ack = 1'b1;
        else begin mem_addr = pc; mem_rd = 1'b1; end
      end
      S_IMM:    begin mem_addr = pc; mem_rd = 1'b1; end
      S_RD_SRC: begin
        mem_addr = ea; mem_rd = 1'b1;
        mem_word = !(bmode || alu_op == OP_MOVSX);
      end
      S_RD_DST: begin mem_addr = ea; mem_rd = 1'b1; mem_word = !bmode; end
      S_WR: begin
        mem_addr = ea; mem_wr = 1'b1; mem_word = !bmode; mem_wdata = dst;
      end
      S_XCHG_WR: begin
        mem_addr = ea; mem_wr = 1'b1; mem_word = !bmode; mem_wdata = src;
      end
      S_PUSH: begin
        mem_addr = R[SP] - 16'd2; mem_wr = 1'b1; mem_wdata = push_val;
      end
      S_POP, S_POPA: begin mem_addr = R[SP]; mem_rd = 1'b1; end
      S_INT1: begin mem_addr = R[SP] - 16'd2; mem_wr = 1'b1; mem_wdata = flags; end
      S_INT2: begin mem_addr = R[SP] - 16'd2; mem_wr = 1'b1; mem_wdata = pc; end
      S_INT3: begin mem_addr = {6'd0, int_vec, 2'b00}; mem_rd = 1'b1; end
      S_PUSHA: begin
        mem_addr = R[SP] - 16'd2; mem_wr = 1'b1;
        case (seq)
          3'd0: mem_wdata = R[AX];
          3'd1: mem_wdata = R[CX];
          3'd2: mem_wdata = R[DX];
          3'd3: mem_wdata = R[BX];
          3'd4: mem_wdata = sp_orig;
          3'd5: mem_wdata = R[BP];
          3'd6: mem_wdata = R[SI];
          default: mem_wdata = R[DI];
        endcase
      end
      S_STR_RD: begin
        mem_addr = R[SI]; mem_rd = 1'b1;
        mem_word = (op == 8'hE1) || (op == 8'hE5) || (op == 8'hE7);
      end
      S_STR_WR: begin
        mem_addr = R[DI]; mem_wr = 1'b1;
        mem_word = (op == 8'hE1) || (op == 8'hE3) || (op == 8'hE7) || (op == 8'hE9);
        mem_wdata = (op == 8'hE2 || op == 8'hE3 || op == 8'hE8 || op == 8'hE9) ? R[AX] : src;
      end
      S_EXEC: begin
        case (op)
          8'hD0: begin io_addr = imm;   io_rd = 1'b1; end
          8'hD1: begin io_addr = R[rs]; io_rd = 1'b1; end
          8'hD2: begin io_addr = imm;   io_wr = 1'b1; io_wdata = R[rs]; end
          8'hD3: begin io_addr = R[rd]; io_wr = 1'b1; io_wdata = R[rs]; end
          default: ;
        endcase
      end
      S_BIOS: bios_req = 1'b1;
      default: ;
    endcase
  end

  assign halted     = (state == S_HALT);
  assign insn_start = (state == S_FETCH) && !(irq && flags[F_IF]);
  assign dbg_pc     = pc;
  assign dbg_flags  = flags;
  assign dbg_regs   = {R[DI], R[SI], R[BP], R[SP], R[DX], R[CX], R[BX], R[AX]};

  // ---------------------------------------------------------------- sequencer
  alu_out_t a;
  always_comb a = alu(alu_op, dst, src, bmode, flags);

  task automatic raise(input logic [7:0] vec);
    int_vec <= vec;
    state   <= S_INT1;
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_FETCH;
      for (int i = 0; i < 8; i++) R[i] <= 16'h0;
      R[SP] <= RESET_SP;
      pc    <= RESET_PC;
      ipc   <= RESET_PC;
      flags <= RESET_FLAGS;
      op <= 8'h0; m <= 8'h0; imm <= 16'h0; src <= 16'h0; dst <= 16'h0; ea <= 16'h0;
      push_val <= 16'h0; push_next <= S_FETCH; pop_dst <= 4'd0; int_vec <= 8'h0;
      seq <= 3'd0; sp_orig <= 16'h0;
    end else begin
      case (state)
        // ------------------------------------------------------------ fetch
        S_FETCH: begin
          if (irq && flags[F_IF]) begin
            raise(irq_vector);
          end else begin
            ipc <= pc;
            op  <= mem_rdata[7:0];
            m   <= mem_rdata[15:8];
            pc  <= pc + 16'd2;
            if (mem_rdata[7:0] < 8'hC0) begin
              logic [2:0] md;
              md = mem_rdata[2:0];
              state <= (md == 3'd1 || md == 3'd3 || md == 3'd4 || md == 3'd6 || md == 3'd7) ? S_IMM : S_EXEC;
            end else begin
              logic [7:0] o;
              o = mem_rdata[7:0];
              state <= (o == 8'hC2 || o == 8'hC4 || o == 8'hCB || o == 8'hD0 || o == 8'hD2 ||
                        o == 8'hDC || o == 8'hDD) ? S_IMM : S_EXEC;
            end
          end
        end
        S_IMM: begin
          imm   <= mem_rdata;
          pc    <= pc + 16'd2;
          state <= S_EXEC;
        end
        // ------------------------------------------------------------ execute
        S_EXEC: begin
          state <= S_FETCH;
          if (is_alu) begin
            ea <= calc_ea(mode, R[rs], R[rd], imm);
            if (alu_op >= ALU_COUNT) begin
              pc <= ipc;
              raise(8'h06);
            end else if (alu_op == OP_LEA) begin
              if (src_mem) R[rd] <= calc_ea(mode, R[rs], R[rd], imm);
              else begin pc <= ipc; raise(8'h06); end
            end else if (alu_op == OP_MOVSX) begin
              if (dst_mem) begin pc <= ipc; raise(8'h06); end
              else if (src_mem) state <= S_RD_SRC;
              else R[rd] <= {{8{(mode == 3'd0 ? R[rs][7] : imm[7])}},
                             (mode == 3'd0 ? R[rs][7:0] : imm[7:0])};
            end else if (alu_op == OP_XCHG) begin
              if (src_mem || dst_mem) state <= S_RD_SRC;
              else begin R[rd] <= R[rs]; R[rs] <= R[rd]; end
            end else begin
              // source operand
              if (mode == 3'd0) src <= bmode ? {8'h0, R[rs][7:0]} : R[rs];
              else if (mode == 3'd1) src <= bmode ? {8'h0, imm[7:0]} : imm;
              else if (dst_mem) src <= bmode ? {8'h0, R[rs][7:0]} : R[rs];
              // destination operand
              if (!dst_mem) dst <= R[rd];
              if (src_mem) state <= S_RD_SRC;
              else if (dst_mem && alu_op != OP_MOV) state <= S_RD_DST;
              else state <= S_ALU;
            end
          end else begin
            case (op)
              8'hC0: ;                                              // NOP
              8'hC1: state <= S_HALT;                               // HLT
              8'hC2: if (cond(m[3:0], flags)) pc <= imm;            // Jcc
              8'hC3: pc <= R[rd];                                   // JMP reg
              8'hC4: begin push_val <= pc; pc <= imm; push_next <= S_FETCH; state <= S_PUSH; end
              8'hC5: begin push_val <= pc; pc <= R[rd]; push_next <= S_FETCH; state <= S_PUSH; end
              8'hC6: begin pop_dst <= PD_PC; state <= S_POP; end   // RET
              8'hC7: begin pop_dst <= PD_IRET; state <= S_POP; end // IRET
              8'hC8: raise(m);                                      // INT n
              8'hC9: begin push_val <= R[rd]; push_next <= S_FETCH; state <= S_PUSH; end
              8'hCA: begin pop_dst <= {1'b0, rd}; state <= S_POP; end
              8'hCB: begin push_val <= imm; push_next <= S_FETCH; state <= S_PUSH; end
              8'hCC: begin push_val <= flags; push_next <= S_FETCH; state <= S_PUSH; end
              8'hCD: begin pop_dst <= PD_FLAGS; state <= S_POP; end
              8'hCE: begin sp_orig <= R[SP]; seq <= 3'd0; state <= S_PUSHA; end
              8'hCF: begin seq <= 3'd0; state <= S_POPA; end
              8'hD0: R[rd] <= io_rdata;                             // IN reg, imm
              8'hD1: R[rd] <= io_rdata;                             // IN reg, reg
              8'hD2, 8'hD3: ;                                       // OUT (driven combinationally)
              8'hD4: R[rd] <= ~R[rd];                               // NOT
              8'hD5: begin                                          // NEG
                alu_out_t t;
                t = alu(OP_SUB, 16'h0, R[rd], 1'b0, flags);
                R[rd] <= t.res; flags <= t.flags;
              end
              8'hD6, 8'hD7: begin                                   // INC / DEC (CF kept)
                alu_out_t t;
                t = alu(op == 8'hD6 ? OP_ADD : OP_SUB, R[rd], 16'h1, 1'b0, flags);
                R[rd] <= t.res;
                flags <= {t.flags[15:1], flags[F_CF]};
              end
              8'hD8: flags[F_IF] <= 1'b0;
              8'hD9: flags[F_IF] <= 1'b1;
              8'hDA: flags[F_CF] <= 1'b0;
              8'hDB: flags[F_CF] <= 1'b1;
              8'hDC: begin                                          // LOOP
                R[CX] <= R[CX] - 16'd1;
                if (R[CX] != 16'd1) pc <= imm;
              end
              8'hDD: if (R[CX] == 16'd0) pc <= imm;                 // JCXZ
              8'hDF: state <= S_BIOS;                               // BIOS n
              8'hE0, 8'hE1, 8'hE4, 8'hE5: state <= S_STR_RD;        // MOVS / LODS
              8'hE2, 8'hE3: state <= S_STR_WR;                      // STOS
              8'hE6, 8'hE7: if (R[CX] != 0) state <= S_STR_RD;      // REP MOVS
              8'hE8, 8'hE9: if (R[CX] != 0) state <= S_STR_WR;      // REP STOS
              default: begin pc <= ipc; raise(8'h06); end           // invalid opcode
            endcase
          end
        end
        // ------------------------------------------------------------ operands
        S_RD_SRC: begin
          if (alu_op == OP_MOVSX) begin
            R[rd] <= {{8{mem_rdata[7]}}, mem_rdata[7:0]};
            state <= S_FETCH;
          end else if (alu_op == OP_XCHG) begin
            // src_mem: register is rd; dst_mem: register is rs
            logic [2:0] rr;
            rr = dst_mem ? rs : rd;
            src <= bmode ? {8'h0, R[rr][7:0]} : R[rr];
            R[rr] <= bmode ? {8'h0, mem_rdata[7:0]} : mem_rdata;
            state <= S_XCHG_WR;
          end else begin
            src   <= bmode ? {8'h0, mem_rdata[7:0]} : mem_rdata;
            state <= S_ALU;
          end
        end
        S_RD_DST: begin
          dst   <= bmode ? {8'h0, mem_rdata[7:0]} : mem_rdata;
          state <= S_ALU;
        end
        S_ALU: begin
          state <= S_FETCH;
          if (alu_op != OP_MOV) flags <= a.flags;
          if (a.div0) begin
            raise(8'h00);
          end else if (a.write) begin
            if (dst_mem) begin
              dst   <= a.res;
              state <= S_WR;
            end else begin
              R[rd] <= a.res;
            end
          end
          if (a.hi_valid && !bmode && !dst_mem && rd != 3'd3 && !a.div0) R[DX] <= a.hi;
        end
        S_WR:      state <= S_FETCH;
        S_XCHG_WR: state <= S_FETCH;
        // ------------------------------------------------------------ stack
        S_PUSH: begin
          R[SP] <= R[SP] - 16'd2;
          state <= push_next;
        end
        S_POP: begin
          R[SP] <= R[SP] + 16'd2;
          state <= S_FETCH;
          case (pop_dst)
            PD_PC:    pc <= mem_rdata;
            PD_FLAGS: flags <= mem_rdata;
            PD_IRET:  begin pc <= mem_rdata; pop_dst <= PD_FLAGS; state <= S_POP; end
            default:  R[pop_dst[2:0]] <= mem_rdata;
          endcase
        end
        S_PUSHA: begin
          R[SP] <= R[SP] - 16'd2;
          seq   <= seq + 3'd1;
          if (seq == 3'd7) state <= S_FETCH;
        end
        S_POPA: begin
          R[SP] <= R[SP] + 16'd2;
          seq   <= seq + 3'd1;
          case (seq)
            3'd0: R[DI] <= mem_rdata;
            3'd1: R[SI] <= mem_rdata;
            3'd2: R[BP] <= mem_rdata;
            3'd3: ;                                  // saved SP is discarded
            3'd4: R[BX] <= mem_rdata;
            3'd5: R[DX] <= mem_rdata;
            3'd6: R[CX] <= mem_rdata;
            default: begin R[AX] <= mem_rdata; state <= S_FETCH; end
          endcase
        end
        // ------------------------------------------------------------ interrupts
        S_INT1: begin                                // push FLAGS
          R[SP] <= R[SP] - 16'd2;
          state <= S_INT2;
        end
        S_INT2: begin                                // push return PC
          R[SP] <= R[SP] - 16'd2;
          state <= S_INT3;
        end
        S_INT3: begin                                // PC = IVT[vector]
          pc <= mem_rdata;
          flags[F_IF] <= 1'b0;
          state <= S_FETCH;
        end
        // ------------------------------------------------------------ strings
        S_STR_RD: begin
          logic w;
          w = (op == 8'hE1) || (op == 8'hE5) || (op == 8'hE7);
          R[SI] <= R[SI] + (w ? 16'd2 : 16'd1);
          if (op == 8'hE4 || op == 8'hE5) begin      // LODS
            R[AX] <= w ? mem_rdata : {8'h0, mem_rdata[7:0]};
            state <= S_FETCH;
          end else begin
            src   <= w ? mem_rdata : {8'h0, mem_rdata[7:0]};
            state <= S_STR_WR;
          end
        end
        S_STR_WR: begin
          logic w, rep;
          w   = (op == 8'hE1) || (op == 8'hE3) || (op == 8'hE7) || (op == 8'hE9);
          rep = op >= 8'hE6;
          R[DI] <= R[DI] + (w ? 16'd2 : 16'd1);
          state <= S_FETCH;
          if (rep) begin
            R[CX] <= R[CX] - 16'd1;
            if (R[CX] != 16'd1) state <= (op == 8'hE6 || op == 8'hE7) ? S_STR_RD : S_STR_WR;
          end
        end
        // ------------------------------------------------------------ misc
        S_BIOS: if (bios_done) state <= S_FETCH;
        S_HALT: if (irq && flags[F_IF]) state <= S_FETCH;
        default: state <= S_FETCH;
      endcase
    end
  end

endmodule
