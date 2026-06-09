`timescale 1ns / 1ps
module axi_read_out #(
    parameter DATA_WIDTH = 32
) (
    input wire aclk,
    input wire aresetn,

    // DMA control interface, synchronous to aclk
    input  wire        dma_start,
    input  wire [31:0] dma_src_addr,
    input  wire [31:0] dma_xfer_len,   // bytes, must be DATA_WIDTH/8 aligned in this baseline
    input  wire        fixed_mode,
    output wire        dma_is_busy,
    output wire        dma_is_done,
    output reg         dma_is_error,

    // AXI4-Full Master Read channel
    output reg  [31:0] m_axi_araddr,
    output wire [ 7:0] m_axi_arlen,
    output wire [ 2:0] m_axi_arsize,
    output wire [ 1:0] m_axi_arburst,
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,

    input  wire [DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [           1:0] m_axi_rresp,
    input  wire                  m_axi_rlast,
    input  wire                  m_axi_rvalid,
    output wire                  m_axi_rready,

    // Read-data FIFO write side
    output wire [DATA_WIDTH-1:0] fifo_wdata,
    output wire                  fifo_wren,
    input  wire                  fifo_full
);

  localparam STRB_WIDTH = DATA_WIDTH / 8;
  localparam ADDR_SHIFT = $clog2(STRB_WIDTH);
  localparam AXI_SIZE = ADDR_SHIFT[2:0];
  localparam [1:0] AXI_RESP_OKAY = 2'b00;

  reg [7:0] arlen_r;
  assign m_axi_arsize  = AXI_SIZE;
  assign m_axi_arburst = fixed_mode ? 2'b00 : 2'b01;
  assign m_axi_arlen   = arlen_r;

  localparam OST_DEPTH = 4;
  reg  [2:0] ost_cnt;
  wire       cmd_full = (ost_cnt == OST_DEPTH);

  reg        dma_running;
  reg [31:0] remain_len;  // remaining beats not yet issued on AR

  wire [31:0] cur_burst_len = (remain_len >= 32'd16) ? 32'd16 : remain_len;

  // AR channel: split one DMA request into 16-beat bursts in this baseline.
  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      m_axi_arvalid <= 1'b0;
      m_axi_araddr  <= 32'b0;
      arlen_r       <= 8'b0;
      remain_len    <= 32'b0;
    end else begin
      if (dma_start && !dma_running) begin
        m_axi_arvalid <= 1'b0;
        m_axi_araddr  <= dma_src_addr;
        remain_len    <= dma_xfer_len >> ADDR_SHIFT;
      end else if (dma_running && (remain_len > 0) && !cmd_full && !m_axi_arvalid) begin
        m_axi_arvalid <= 1'b1;
        arlen_r       <= cur_burst_len[7:0] - 8'd1;
      end else if (m_axi_arvalid && m_axi_arready) begin
        m_axi_arvalid <= 1'b0;
        remain_len    <= remain_len - cur_burst_len;
        if (!fixed_mode) begin
          m_axi_araddr <= m_axi_araddr + (cur_burst_len << ADDR_SHIFT);
        end
      end
    end
  end

  // R channel: keep accepting data while the request is running and FIFO has space.
  assign m_axi_rready = dma_running && !fifo_full;
  assign fifo_wdata   = m_axi_rdata;
  assign fifo_wren    = m_axi_rvalid && m_axi_rready;

  wire ar_shake     = m_axi_arvalid && m_axi_arready;
  wire r_shake      = m_axi_rvalid  && m_axi_rready;
  wire r_burst_done = r_shake && m_axi_rlast;

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      ost_cnt      <= 3'b0;
      dma_running  <= 1'b0;
      dma_is_error <= 1'b0;
    end else begin
      if (dma_start && !dma_running) begin
        dma_running  <= 1'b1;
        dma_is_error <= 1'b0;
        ost_cnt      <= 3'b0;
      end else if (dma_is_done) begin
        dma_running <= 1'b0;
      end

      if (ar_shake && !r_burst_done) begin
        ost_cnt <= ost_cnt + 1'b1;
      end else if (!ar_shake && r_burst_done) begin
        ost_cnt <= ost_cnt - 1'b1;
      end

      if (r_shake && (m_axi_rresp != AXI_RESP_OKAY)) begin
        dma_is_error <= 1'b1;
      end
    end
  end

  assign dma_is_busy = dma_running;
  assign dma_is_done = dma_running && (remain_len == 0) && (ost_cnt == 0);

endmodule
