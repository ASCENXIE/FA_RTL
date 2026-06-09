`timescale 1ns / 1ps
module axi_write_out #(
    parameter DATA_WIDTH = 32,
    parameter STRB_WIDTH = DATA_WIDTH / 8
) (
    input wire aclk,
    input wire aresetn,

    // DMA control interface, synchronous to aclk
    input  wire        dma_start,
    input  wire [31:0] dma_dst_addr,
    input  wire [31:0] dma_xfer_len,   // bytes, must be STRB_WIDTH aligned in this baseline
    input  wire        fixed_mode,
    output wire        dma_is_busy,
    output wire        dma_is_done,
    output reg         dma_is_error,

    // AXI4-Full Master Write address channel
    output reg  [31:0] m_axi_awaddr,
    output wire [ 7:0] m_axi_awlen,
    output wire [ 2:0] m_axi_awsize,
    output wire [ 1:0] m_axi_awburst,
    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,

    // AXI4-Full Master Write data channel
    output wire [DATA_WIDTH-1:0] m_axi_wdata,
    output wire [STRB_WIDTH-1:0] m_axi_wstrb,
    output wire                  m_axi_wlast,
    output wire                  m_axi_wvalid,
    input  wire                  m_axi_wready,

    // AXI4-Full Master Write response channel
    input  wire [1:0] m_axi_bresp,
    input  wire       m_axi_bvalid,
    output wire       m_axi_bready,

    // Write-data FIFO read side
    input  wire [DATA_WIDTH-1:0] fifo_rdata,
    output wire                  fifo_rden,
    input  wire                  fifo_empty
);

  localparam ADDR_SHIFT = $clog2(STRB_WIDTH);
  localparam AXI_SIZE = ADDR_SHIFT[2:0];
  localparam [1:0] AXI_RESP_OKAY = 2'b00;

  reg [7:0] awlen_r;
  assign m_axi_awsize  = AXI_SIZE;
  assign m_axi_awburst = fixed_mode ? 2'b00 : 2'b01;
  assign m_axi_wstrb   = {STRB_WIDTH{1'b1}};
  assign m_axi_awlen   = awlen_r;

  localparam OST_DEPTH = 4;
  reg [7:0] cmd_fifo[0:OST_DEPTH-1];
  reg [2:0] cmd_wr_ptr;
  reg [2:0] cmd_rd_ptr;
  reg [2:0] ost_cnt;

  wire cmd_full  = (ost_cnt == OST_DEPTH);
  wire cmd_empty = (cmd_wr_ptr == cmd_rd_ptr);

  reg        dma_running;
  reg [31:0] remain_len;  // remaining beats not yet issued on AW

  wire [31:0] cur_burst_len = (remain_len >= 32'd16) ? 32'd16 : remain_len;

  // AW channel: split one DMA request into 16-beat bursts in this baseline.
  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      m_axi_awvalid <= 1'b0;
      m_axi_awaddr  <= 32'b0;
      awlen_r       <= 8'b0;
      remain_len    <= 32'b0;
      cmd_wr_ptr    <= 3'b0;
    end else begin
      if (dma_start && !dma_running) begin
        m_axi_awvalid <= 1'b0;
        m_axi_awaddr  <= dma_dst_addr;
        remain_len    <= dma_xfer_len >> ADDR_SHIFT;
        cmd_wr_ptr    <= 3'b0;
      end else if (dma_running && (remain_len > 0) && !cmd_full && !m_axi_awvalid) begin
        m_axi_awvalid <= 1'b1;
        awlen_r       <= cur_burst_len[7:0] - 8'd1;
      end else if (m_axi_awvalid && m_axi_awready) begin
        m_axi_awvalid <= 1'b0;
        cmd_fifo[cmd_wr_ptr[1:0]] <= awlen_r;
        cmd_wr_ptr <= cmd_wr_ptr + 1'b1;
        remain_len <= remain_len - cur_burst_len;
        if (!fixed_mode) begin
          m_axi_awaddr <= m_axi_awaddr + (cur_burst_len << ADDR_SHIFT);
        end
      end
    end
  end

  // W channel: send one burst according to the AW-length command FIFO.
  reg [7:0] wdata_cnt;
  reg       w_active;

  assign m_axi_wvalid = w_active && !fifo_empty;
  assign m_axi_wdata  = fifo_rdata;
  assign fifo_rden    = m_axi_wvalid && m_axi_wready;
  assign m_axi_wlast  = w_active && (wdata_cnt == 0);

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      w_active   <= 1'b0;
      wdata_cnt  <= 8'b0;
      cmd_rd_ptr <= 3'b0;
    end else begin
      if (dma_start && !dma_running) begin
        w_active   <= 1'b0;
        wdata_cnt  <= 8'b0;
        cmd_rd_ptr <= 3'b0;
      end else if (!w_active && !cmd_empty) begin
        w_active   <= 1'b1;
        wdata_cnt  <= cmd_fifo[cmd_rd_ptr[1:0]];
        cmd_rd_ptr <= cmd_rd_ptr + 1'b1;
      end else if (w_active && m_axi_wvalid && m_axi_wready) begin
        if (wdata_cnt == 0) begin
          w_active <= 1'b0;
        end else begin
          wdata_cnt <= wdata_cnt - 1'b1;
        end
      end
    end
  end

  assign m_axi_bready = 1'b1;
  wire aw_shake = m_axi_awvalid && m_axi_awready;
  wire b_shake  = m_axi_bvalid  && m_axi_bready;

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

      if (aw_shake && !b_shake) begin
        ost_cnt <= ost_cnt + 1'b1;
      end else if (!aw_shake && b_shake) begin
        ost_cnt <= ost_cnt - 1'b1;
      end

      if (b_shake && (m_axi_bresp != AXI_RESP_OKAY)) begin
        dma_is_error <= 1'b1;
      end
    end
  end

  assign dma_is_busy = dma_running;
  assign dma_is_done = dma_running && (remain_len == 0) && (ost_cnt == 0) && !w_active;

endmodule
