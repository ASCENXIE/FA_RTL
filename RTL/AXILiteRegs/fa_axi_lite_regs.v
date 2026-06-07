`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// Module: fa_axi_lite_regs
// Description:
//   AXI4-Lite CSR/register block for Flash Attention accelerator.
//
// Notes:
//   - 32-bit AXI4-Lite data bus
//   - One outstanding write response and one outstanding read response
//   - AW and W channels may arrive in different cycles
//   - All accesses return OKAY
//   - Undefined addresses read as zero and ignore writes
//   - WSTRB byte-write semantics are supported for writable 32-bit CSRs
//   - START / SOFT_RESET / DONE_CLR are one-cycle pulses
// -----------------------------------------------------------------------------

module fa_axi_lite_regs #(
    parameter integer        ADDR_WIDTH         = 32,
    parameter integer        HEAD_DIM           = 64,
    parameter integer        ELEM_BYTES         = 2,
    parameter         [31:0] RESET_STRIDE_BYTES = HEAD_DIM * ELEM_BYTES,

    // Default values below are examples for Q8.8 fixed-point format.
    // RESET_NEG_LARGE = -128.0 in signed Q8.8, sign-extended to 32 bits.
    // RESET_SCALE     = 1/sqrt(64) = 0.125 = 32/256 in Q8.8.
    parameter [31:0] RESET_NEG_LARGE = 32'hFFFF_8000,
    parameter [31:0] RESET_SCALE     = 32'd32
) (
    input wire clk,
    input wire rst_n,

    // AXI4-Lite write address channel
    input  wire [ADDR_WIDTH-1:0] s_axil_awaddr,
    input  wire                  s_axil_awvalid,
    output wire                  s_axil_awready,

    // AXI4-Lite write data channel
    input  wire [31:0] s_axil_wdata,
    input  wire [ 3:0] s_axil_wstrb,
    input  wire        s_axil_wvalid,
    output wire        s_axil_wready,

    // AXI4-Lite write response channel
    output reg  [1:0] s_axil_bresp,
    output reg        s_axil_bvalid,
    input  wire       s_axil_bready,

    // AXI4-Lite read address channel
    input  wire [ADDR_WIDTH-1:0] s_axil_araddr,
    input  wire                  s_axil_arvalid,
    output wire                  s_axil_arready,

    // AXI4-Lite read data channel
    output reg  [31:0] s_axil_rdata,
    output reg  [ 1:0] s_axil_rresp,
    output reg         s_axil_rvalid,
    input  wire        s_axil_rready,

    // Hardware-side control/config outputs
    output reg  ctrl_start_pulse,
    output reg  ctrl_soft_reset,
    output reg  ctrl_done_clr,
    output wire ctrl_irq_en,
    output wire ctrl_causal_en,

    output wire [63:0] cfg_q_base,
    output wire [63:0] cfg_k_base,
    output wire [63:0] cfg_v_base,
    output wire [63:0] cfg_o_base,
    output wire [31:0] cfg_stride_bytes,
    output wire [31:0] cfg_neg_large,
    output wire [31:0] cfg_scale,

    // Hardware-side status/performance inputs
    input wire        status_busy,
    input wire        status_done,
    input wire        status_error,
    input wire [31:0] perf_cycles
);

  // -------------------------------------------------------------------------
  // Register offset index, using byte address bits [7:2].
  // Each CSR is 32-bit word aligned.
  // -------------------------------------------------------------------------
  localparam [5:0] REG_CTRL = 6'h00;  // 0x00
  localparam [5:0] REG_STATUS = 6'h01;  // 0x04
  localparam [5:0] REG_CFG = 6'h02;  // 0x08
  localparam [5:0] REG_Q_BASE_L = 6'h05;  // 0x14
  localparam [5:0] REG_Q_BASE_H = 6'h06;  // 0x18
  localparam [5:0] REG_K_BASE_L = 6'h07;  // 0x1C
  localparam [5:0] REG_K_BASE_H = 6'h08;  // 0x20
  localparam [5:0] REG_V_BASE_L = 6'h09;  // 0x24
  localparam [5:0] REG_V_BASE_H = 6'h0A;  // 0x28
  localparam [5:0] REG_O_BASE_L = 6'h0B;  // 0x2C
  localparam [5:0] REG_O_BASE_H = 6'h0C;  // 0x30
  localparam [5:0] REG_STRIDE_BYTES = 6'h0D;  // 0x34
  localparam [5:0] REG_NEG_LARGE = 6'h0E;  // 0x38
  localparam [5:0] REG_SCALE = 6'h0F;  // 0x3C
  localparam [5:0] REG_CYCLES = 6'h10;  // 0x40

  localparam [1:0] AXIL_RESP_OKAY = 2'b00;

  // -------------------------------------------------------------------------
  // Internal CSR storage
  // -------------------------------------------------------------------------
  reg                  reg_irq_en;
  reg                  reg_causal_en;

  reg [          31:0] reg_q_base_l;
  reg [          31:0] reg_q_base_h;
  reg [          31:0] reg_k_base_l;
  reg [          31:0] reg_k_base_h;
  reg [          31:0] reg_v_base_l;
  reg [          31:0] reg_v_base_h;
  reg [          31:0] reg_o_base_l;
  reg [          31:0] reg_o_base_h;
  reg [          31:0] reg_stride_bytes;
  reg [          31:0] reg_neg_large;
  reg [          31:0] reg_scale;

  // -------------------------------------------------------------------------
  // AXI write channel temporary storage
  // -------------------------------------------------------------------------
  reg [ADDR_WIDTH-1:0] awaddr_reg;
  reg                  awaddr_valid;
  reg [          31:0] wdata_reg;
  reg [           3:0] wstrb_reg;
  reg                  wdata_valid;

  assign s_axil_awready = (!awaddr_valid) && (!s_axil_bvalid);
  assign s_axil_wready  = (!wdata_valid) && (!s_axil_bvalid);
  assign s_axil_arready = (!s_axil_rvalid);

  wire aw_fire = s_axil_awvalid && s_axil_awready;
  wire w_fire = s_axil_wvalid && s_axil_wready;
  wire ar_fire = s_axil_arvalid && s_axil_arready;

  wire write_fire = (!s_axil_bvalid) && (awaddr_valid || aw_fire) && (wdata_valid || w_fire);

  wire [ADDR_WIDTH-1:0] write_addr = aw_fire ? s_axil_awaddr : awaddr_reg;
  wire [31:0] write_data = w_fire ? s_axil_wdata : wdata_reg;
  wire [3:0] write_strb = w_fire ? s_axil_wstrb : wstrb_reg;

  // WSTRB mask. Each bit of WSTRB maps to one byte of WDATA.
  wire [31:0] write_mask = {
    {8{write_strb[3]}}, {8{write_strb[2]}}, {8{write_strb[1]}}, {8{write_strb[0]}}
  };

  // -------------------------------------------------------------------------
  // Hardware-side output mapping
  // -------------------------------------------------------------------------
  assign ctrl_irq_en      = reg_irq_en;
  assign ctrl_causal_en   = reg_causal_en;

  assign cfg_q_base       = {reg_q_base_h, reg_q_base_l};
  assign cfg_k_base       = {reg_k_base_h, reg_k_base_l};
  assign cfg_v_base       = {reg_v_base_h, reg_v_base_l};
  assign cfg_o_base       = {reg_o_base_h, reg_o_base_l};
  assign cfg_stride_bytes = reg_stride_bytes;
  assign cfg_neg_large    = reg_neg_large;
  assign cfg_scale        = reg_scale;

  // -------------------------------------------------------------------------
  // CSR read mux
  // -------------------------------------------------------------------------
  reg [31:0] csr_rdata;

  always @(*) begin
    case (s_axil_araddr[7:2])
      REG_CTRL: begin
        // START and SOFT_RESET are pulse fields, read as 0.
        csr_rdata = {29'd0, reg_irq_en, 2'b00};
      end

      REG_STATUS: begin
        csr_rdata = {29'd0, status_error, status_done, status_busy};
      end

      REG_CFG: begin
        csr_rdata = {31'd0, reg_causal_en};
      end

      REG_Q_BASE_L: begin
        csr_rdata = reg_q_base_l;
      end

      REG_Q_BASE_H: begin
        csr_rdata = reg_q_base_h;
      end

      REG_K_BASE_L: begin
        csr_rdata = reg_k_base_l;
      end

      REG_K_BASE_H: begin
        csr_rdata = reg_k_base_h;
      end

      REG_V_BASE_L: begin
        csr_rdata = reg_v_base_l;
      end

      REG_V_BASE_H: begin
        csr_rdata = reg_v_base_h;
      end

      REG_O_BASE_L: begin
        csr_rdata = reg_o_base_l;
      end

      REG_O_BASE_H: begin
        csr_rdata = reg_o_base_h;
      end

      REG_STRIDE_BYTES: begin
        csr_rdata = reg_stride_bytes;
      end

      REG_NEG_LARGE: begin
        csr_rdata = reg_neg_large;
      end

      REG_SCALE: begin
        csr_rdata = reg_scale;
      end

      REG_CYCLES: begin
        csr_rdata = perf_cycles;
      end

      default: begin
        csr_rdata = 32'h0000_0000;
      end
    endcase
  end

  // -------------------------------------------------------------------------
  // Sequential logic
  // -------------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // AXI state
      awaddr_reg       <= {ADDR_WIDTH{1'b0}};
      awaddr_valid     <= 1'b0;
      wdata_reg        <= 32'h0000_0000;
      wstrb_reg        <= 4'h0;
      wdata_valid      <= 1'b0;

      s_axil_bresp     <= AXIL_RESP_OKAY;
      s_axil_bvalid    <= 1'b0;
      s_axil_rdata     <= 32'h0000_0000;
      s_axil_rresp     <= AXIL_RESP_OKAY;
      s_axil_rvalid    <= 1'b0;

      // Pulse outputs
      ctrl_start_pulse <= 1'b0;
      ctrl_soft_reset  <= 1'b0;
      ctrl_done_clr    <= 1'b0;

      // RW CSRs
      reg_irq_en       <= 1'b0;
      reg_causal_en    <= 1'b0;
      reg_q_base_l     <= 32'h0000_0000;
      reg_q_base_h     <= 32'h0000_0000;
      reg_k_base_l     <= 32'h0000_0000;
      reg_k_base_h     <= 32'h0000_0000;
      reg_v_base_l     <= 32'h0000_0000;
      reg_v_base_h     <= 32'h0000_0000;
      reg_o_base_l     <= 32'h0000_0000;
      reg_o_base_h     <= 32'h0000_0000;
      reg_stride_bytes <= RESET_STRIDE_BYTES;
      reg_neg_large    <= RESET_NEG_LARGE;
      reg_scale        <= RESET_SCALE;
    end else begin
      // Default: pulse outputs are deasserted unless a matching write occurs.
      ctrl_start_pulse <= 1'b0;
      ctrl_soft_reset  <= 1'b0;
      ctrl_done_clr    <= 1'b0;

      // Write response channel
      if (s_axil_bvalid && s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
        s_axil_bresp  <= AXIL_RESP_OKAY;
      end

      // Read data channel
      if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end

      if (ar_fire) begin
        s_axil_rdata  <= csr_rdata;
        s_axil_rresp  <= AXIL_RESP_OKAY;
        s_axil_rvalid <= 1'b1;
      end

      // Write address/data capture and CSR write commit
      if (write_fire) begin
        case (write_addr[7:2])
          REG_CTRL: begin
            if (write_strb[0]) begin
              if (write_data[0]) begin
                ctrl_start_pulse <= 1'b1;
              end

              if (write_data[1]) begin
                ctrl_soft_reset <= 1'b1;
              end

              reg_irq_en <= write_data[2];
            end
          end

          REG_STATUS: begin
            if (write_strb[0] && write_data[1]) begin
              ctrl_done_clr <= 1'b1;
            end
          end

          REG_CFG: begin
            if (write_strb[0]) begin
              reg_causal_en <= write_data[0];
            end
          end

          REG_Q_BASE_L: begin
            reg_q_base_l <= (reg_q_base_l & ~write_mask) | (write_data & write_mask);
          end

          REG_Q_BASE_H: begin
            reg_q_base_h <= (reg_q_base_h & ~write_mask) | (write_data & write_mask);
          end

          REG_K_BASE_L: begin
            reg_k_base_l <= (reg_k_base_l & ~write_mask) | (write_data & write_mask);
          end

          REG_K_BASE_H: begin
            reg_k_base_h <= (reg_k_base_h & ~write_mask) | (write_data & write_mask);
          end

          REG_V_BASE_L: begin
            reg_v_base_l <= (reg_v_base_l & ~write_mask) | (write_data & write_mask);
          end

          REG_V_BASE_H: begin
            reg_v_base_h <= (reg_v_base_h & ~write_mask) | (write_data & write_mask);
          end

          REG_O_BASE_L: begin
            reg_o_base_l <= (reg_o_base_l & ~write_mask) | (write_data & write_mask);
          end

          REG_O_BASE_H: begin
            reg_o_base_h <= (reg_o_base_h & ~write_mask) | (write_data & write_mask);
          end

          REG_STRIDE_BYTES: begin
            reg_stride_bytes <= (reg_stride_bytes & ~write_mask) | (write_data & write_mask);
          end

          REG_NEG_LARGE: begin
            reg_neg_large <= (reg_neg_large & ~write_mask) | (write_data & write_mask);
          end

          REG_SCALE: begin
            reg_scale <= (reg_scale & ~write_mask) | (write_data & write_mask);
          end

          default: begin
            // Undefined / reserved address: ignore write, still return OKAY.
          end
        endcase

        awaddr_valid  <= 1'b0;
        wdata_valid   <= 1'b0;
        s_axil_bresp  <= AXIL_RESP_OKAY;
        s_axil_bvalid <= 1'b1;
      end else begin
        if (aw_fire) begin
          awaddr_reg   <= s_axil_awaddr;
          awaddr_valid <= 1'b1;
        end

        if (w_fire) begin
          wdata_reg   <= s_axil_wdata;
          wstrb_reg   <= s_axil_wstrb;
          wdata_valid <= 1'b1;
        end
      end
    end
  end

endmodule
