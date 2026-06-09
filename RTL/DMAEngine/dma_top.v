`timescale 1ns / 1ps

module dma_top #(
    parameter DATA_WIDTH = 32,
    parameter STRB_WIDTH = DATA_WIDTH / 8,
    parameter FIFO_DEPTH = 16
) (
    // 1. Global clocks and reset
    // Baseline assumption: scheduler, DMA, buffer and AXI master are all in aclk domain.
    // pclk/presetn are reserved for later CSR/control-plane integration.
    input wire pclk,
    input wire presetn,
    input wire aclk,
    input wire aresetn,

    // 2. Scheduler interface, synchronous to aclk
    input  wire        dma_start,
    input  wire [1:0]  dma_op,     // 00: LOAD_Q, 01: LOAD_K, 10: LOAD_V, 11: STORE_O
    input  wire [31:0] dma_addr,   // LOAD: AXI read address; STORE_O: AXI write address
    input  wire [31:0] dma_bytes,  // bytes, baseline requires DATA_WIDTH/8 alignment
    output wire        dma_busy,
    output wire        dma_done,
    output wire        dma_error,

    // 3. AXI read data -> one input buffer
    // Only one physical input-buffer write interface is exposed; buf_w_kind marks Q/K/V.
    output wire                  buf_w_valid,
    output wire [1:0]            buf_w_kind,   // 00: Q, 01: K, 10: V; valid only with buf_w_valid
    output wire [DATA_WIDTH-1:0] buf_w_data,
    output wire                  buf_w_last,   // tile-last, not AXI burst-last
    input  wire                  buf_w_ready,

    // 4. O buffer / compute output -> DMA write FIFO
    // DMA accepts exactly dma_bytes/(DATA_WIDTH/8) beats for one STORE_O request.
    input  wire                  o_buf_valid,
    input  wire [DATA_WIDTH-1:0] o_buf_data,
    output wire                  o_buf_ready,

    // 5. AXI4-Full Master Read interface
    output wire [          31:0] m_axi_araddr,
    output wire [           7:0] m_axi_arlen,
    output wire [           2:0] m_axi_arsize,
    output wire [           1:0] m_axi_arburst,
    output wire                  m_axi_arvalid,
    input  wire                  m_axi_arready,
    input  wire [DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [           1:0] m_axi_rresp,
    input  wire                  m_axi_rlast,
    input  wire                  m_axi_rvalid,
    output wire                  m_axi_rready,

    // 6. AXI4-Full Master Write interface
    output wire [          31:0] m_axi_awaddr,
    output wire [           7:0] m_axi_awlen,
    output wire [           2:0] m_axi_awsize,
    output wire [           1:0] m_axi_awburst,
    output wire                  m_axi_awvalid,
    input  wire                  m_axi_awready,
    output wire [DATA_WIDTH-1:0] m_axi_wdata,
    output wire [STRB_WIDTH-1:0] m_axi_wstrb,
    output wire                  m_axi_wlast,
    output wire                  m_axi_wvalid,
    input  wire                  m_axi_wready,
    input  wire [           1:0] m_axi_bresp,
    input  wire                  m_axi_bvalid,
    output wire                  m_axi_bready,

    // 7. Interrupt/status pulse
    output wire dma_irq
);

  // ---------------------------------------------------------------------------
  // dma_op encoding
  // ---------------------------------------------------------------------------
  localparam [1:0] DMA_LOAD_Q  = 2'b00;
  localparam [1:0] DMA_LOAD_K  = 2'b01;
  localparam [1:0] DMA_LOAD_V  = 2'b10;
  localparam [1:0] DMA_STORE_O = 2'b11;

  localparam ADDR_SHIFT = $clog2(STRB_WIDTH);

  wire is_store_req = (dma_op == DMA_STORE_O);
  wire is_load_req  = ~is_store_req;

  wire src_fixed = 1'b0;
  wire dst_fixed = 1'b0;

  // Baseline requires dma_bytes to be aligned to the AXI data width in bytes.
  // Partial final-beat WSTRB is not implemented in axi_write_out.
  wire [31:0] dma_xfer_beats_comb = dma_bytes >> ADDR_SHIFT;

  // busy high means the top must not accept another request.
  wire dma_req_accept = dma_start & ~dma_busy;

  reg [31:0] dma_addr_latched;
  reg [31:0] dma_bytes_latched;
  reg [31:0] dma_beats_latched;

  reg load_start_pulse;
  reg store_start_pulse;

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      dma_addr_latched  <= 32'd0;
      dma_bytes_latched <= 32'd0;
      dma_beats_latched <= 32'd0;
      load_start_pulse  <= 1'b0;
      store_start_pulse <= 1'b0;
    end else begin
      load_start_pulse  <= 1'b0;
      store_start_pulse <= 1'b0;

      if (dma_req_accept) begin
        dma_addr_latched  <= dma_addr;
        dma_bytes_latched <= dma_bytes;
        dma_beats_latched <= dma_xfer_beats_comb;

        if (is_load_req) begin
          load_start_pulse <= 1'b1;
        end else begin
          store_start_pulse <= 1'b1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // LOAD_Q/K/V path: AXI read -> read FIFO -> single input buffer
  // ---------------------------------------------------------------------------
  wire                  read_is_busy;
  wire                  read_axi_done;
  wire                  read_axi_error;
  wire [DATA_WIDTH-1:0] read_fifo_wdata;
  wire                  read_fifo_wren;
  wire                  read_fifo_full;
  wire [DATA_WIDTH-1:0] read_fifo_rdata;
  wire                  read_fifo_rden;
  wire                  read_fifo_empty;

  reg                   load_active;
  reg  [31:0]           load_beats_left;
  reg  [1:0]            load_kind_latched;
  reg                   load_done_pulse;

  assign buf_w_valid    = load_active & ~read_fifo_empty;
  assign buf_w_kind     = load_kind_latched;
  assign buf_w_data     = read_fifo_rdata;
  assign buf_w_last     = buf_w_valid & (load_beats_left == 32'd1);
  assign read_fifo_rden = buf_w_valid & buf_w_ready;

  wire load_last_beat_to_buffer = read_fifo_rden & (load_beats_left == 32'd1);

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      load_active       <= 1'b0;
      load_beats_left   <= 32'd0;
      load_kind_latched <= DMA_LOAD_Q;
      load_done_pulse   <= 1'b0;
    end else begin
      load_done_pulse <= 1'b0;

      if (dma_req_accept & is_load_req) begin
        load_active       <= 1'b1;
        load_beats_left   <= dma_xfer_beats_comb;
        load_kind_latched <= dma_op;
      end else if (load_last_beat_to_buffer) begin
        load_active     <= 1'b0;
        load_beats_left <= 32'd0;
        load_done_pulse <= 1'b1;
      end else if (read_fifo_rden && (load_beats_left != 32'd0)) begin
        load_beats_left <= load_beats_left - 32'd1;
      end
    end
  end

  axi_read_out #(
      .DATA_WIDTH(DATA_WIDTH)
  ) u_axi_read_out (
      .aclk         (aclk),
      .aresetn      (aresetn),
      .dma_start    (load_start_pulse),
      .dma_src_addr (dma_addr_latched),
      .dma_xfer_len (dma_bytes_latched),
      .fixed_mode   (src_fixed),
      .dma_is_busy  (read_is_busy),
      .dma_is_done  (read_axi_done),
      .dma_is_error (read_axi_error),
      .m_axi_araddr (m_axi_araddr),
      .m_axi_arlen  (m_axi_arlen),
      .m_axi_arsize (m_axi_arsize),
      .m_axi_arburst(m_axi_arburst),
      .m_axi_arvalid(m_axi_arvalid),
      .m_axi_arready(m_axi_arready),
      .m_axi_rdata  (m_axi_rdata),
      .m_axi_rresp  (m_axi_rresp),
      .m_axi_rlast  (m_axi_rlast),
      .m_axi_rvalid (m_axi_rvalid),
      .m_axi_rready (m_axi_rready),
      .fifo_wdata   (read_fifo_wdata),
      .fifo_wren    (read_fifo_wren),
      .fifo_full    (read_fifo_full)
  );

  asyn_fifo #(
      .DATA_WIDTH(DATA_WIDTH),
      .FIFO_DEPTH(FIFO_DEPTH)
  ) u_read_fifo (
      .rst_n   (aresetn),
      .clk_wr  (aclk),
      .en_wr   (read_fifo_wren),
      .data_in (read_fifo_wdata),
      .full    (read_fifo_full),
      .clk_rd  (aclk),
      .en_rd   (read_fifo_rden),
      .data_out(read_fifo_rdata),
      .empty   (read_fifo_empty)
  );

  // ---------------------------------------------------------------------------
  // STORE_O path: O buffer / compute output -> write FIFO -> AXI write
  // ---------------------------------------------------------------------------
  wire                  write_is_busy;
  wire                  write_is_done_aclk;
  wire                  write_axi_error;
  wire [DATA_WIDTH-1:0] write_fifo_rdata;
  wire                  write_fifo_rden;
  wire                  write_fifo_empty;
  wire                  write_fifo_full;
  wire                  write_fifo_wren;

  reg                   store_active;
  reg  [31:0]           store_beats_to_accept;
  reg                   store_done_pulse;

  assign o_buf_ready     = store_active & (store_beats_to_accept != 32'd0) & ~write_fifo_full;
  assign write_fifo_wren = o_buf_valid & o_buf_ready;

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      store_active          <= 1'b0;
      store_beats_to_accept <= 32'd0;
      store_done_pulse      <= 1'b0;
    end else begin
      store_done_pulse <= 1'b0;

      if (dma_req_accept & is_store_req) begin
        store_active          <= 1'b1;
        store_beats_to_accept <= dma_xfer_beats_comb;
      end else begin
        if (write_fifo_wren && (store_beats_to_accept != 32'd0)) begin
          store_beats_to_accept <= store_beats_to_accept - 32'd1;
        end

        if (write_is_done_aclk) begin
          store_active     <= 1'b0;
          store_done_pulse <= 1'b1;
        end
      end
    end
  end

  axi_write_out #(
      .DATA_WIDTH(DATA_WIDTH),
      .STRB_WIDTH(STRB_WIDTH)
  ) u_axi_write_out (
      .aclk         (aclk),
      .aresetn      (aresetn),
      .dma_start    (store_start_pulse),
      .dma_dst_addr (dma_addr_latched),
      .dma_xfer_len (dma_bytes_latched),
      .fixed_mode   (dst_fixed),
      .dma_is_busy  (write_is_busy),
      .dma_is_done  (write_is_done_aclk),
      .dma_is_error (write_axi_error),
      .m_axi_awaddr (m_axi_awaddr),
      .m_axi_awlen  (m_axi_awlen),
      .m_axi_awsize (m_axi_awsize),
      .m_axi_awburst(m_axi_awburst),
      .m_axi_awvalid(m_axi_awvalid),
      .m_axi_awready(m_axi_awready),
      .m_axi_wdata  (m_axi_wdata),
      .m_axi_wstrb  (m_axi_wstrb),
      .m_axi_wlast  (m_axi_wlast),
      .m_axi_wvalid (m_axi_wvalid),
      .m_axi_wready (m_axi_wready),
      .m_axi_bresp  (m_axi_bresp),
      .m_axi_bvalid (m_axi_bvalid),
      .m_axi_bready (m_axi_bready),
      .fifo_rdata   (write_fifo_rdata),
      .fifo_rden    (write_fifo_rden),
      .fifo_empty   (write_fifo_empty)
  );

  asyn_fifo #(
      .DATA_WIDTH(DATA_WIDTH),
      .FIFO_DEPTH(FIFO_DEPTH)
  ) u_write_fifo (
      .rst_n   (aresetn),
      .clk_wr  (aclk),
      .en_wr   (write_fifo_wren),
      .data_in (o_buf_data),
      .full    (write_fifo_full),
      .clk_rd  (aclk),
      .en_rd   (write_fifo_rden),
      .data_out(write_fifo_rdata),
      .empty   (write_fifo_empty)
  );

  // ---------------------------------------------------------------------------
  // Status
  // ---------------------------------------------------------------------------
  reg dma_error_r;

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      dma_error_r <= 1'b0;
    end else begin
      if (dma_req_accept) begin
        dma_error_r <= 1'b0;
      end else if (read_axi_error | write_axi_error) begin
        dma_error_r <= 1'b1;
      end
    end
  end

  assign dma_busy  = load_active | store_active | load_start_pulse | store_start_pulse | read_is_busy | write_is_busy;
  assign dma_error = dma_error_r | read_axi_error | write_axi_error;
  assign dma_done  = (load_done_pulse | store_done_pulse) & ~dma_error;
  assign dma_irq   = dma_done;

  wire unused_pclk          = pclk;
  wire unused_presetn       = presetn;
  wire unused_read_axi_done = read_axi_done;
  wire [31:0] unused_beats  = dma_beats_latched;

endmodule
