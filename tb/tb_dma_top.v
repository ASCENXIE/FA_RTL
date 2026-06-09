`timescale 1ns/1ps

module tb_dma_top;

  localparam DATA_WIDTH = 32;
  localparam STRB_WIDTH = DATA_WIDTH / 8;
  localparam FIFO_DEPTH = 16;

  localparam [1:0] DMA_LOAD_Q  = 2'b00;
  localparam [1:0] DMA_LOAD_K  = 2'b01;
  localparam [1:0] DMA_LOAD_V  = 2'b10;
  localparam [1:0] DMA_STORE_O = 2'b11;

  reg pclk;
  reg presetn;
  reg aclk;
  reg aresetn;

  reg        dma_start;
  reg [1:0]  dma_op;
  reg [31:0] dma_addr;
  reg [31:0] dma_bytes;
  wire       dma_busy;
  wire       dma_done;
  wire       dma_error;

  wire                  buf_w_valid;
  wire [1:0]            buf_w_kind;
  wire [DATA_WIDTH-1:0] buf_w_data;
  wire                  buf_w_last;
  reg                   buf_w_ready;

  reg                   o_buf_valid;
  reg  [DATA_WIDTH-1:0] o_buf_data;
  wire                  o_buf_ready;

  wire [31:0]           m_axi_araddr;
  wire [7:0]            m_axi_arlen;
  wire [2:0]            m_axi_arsize;
  wire [1:0]            m_axi_arburst;
  wire                  m_axi_arvalid;
  reg                   m_axi_arready;
  reg  [DATA_WIDTH-1:0] m_axi_rdata;
  reg  [1:0]            m_axi_rresp;
  reg                   m_axi_rlast;
  reg                   m_axi_rvalid;
  wire                  m_axi_rready;

  wire [31:0]           m_axi_awaddr;
  wire [7:0]            m_axi_awlen;
  wire [2:0]            m_axi_awsize;
  wire [1:0]            m_axi_awburst;
  wire                  m_axi_awvalid;
  reg                   m_axi_awready;
  wire [DATA_WIDTH-1:0] m_axi_wdata;
  wire [STRB_WIDTH-1:0] m_axi_wstrb;
  wire                  m_axi_wlast;
  wire                  m_axi_wvalid;
  reg                   m_axi_wready;
  reg  [1:0]            m_axi_bresp;
  reg                   m_axi_bvalid;
  wire                  m_axi_bready;
  wire                  dma_irq;

  integer error_count;
  integer i;

  // Simple word-addressed memory model. AXI byte address [11:2] indexes words.
  reg [DATA_WIDTH-1:0] mem [0:1023];

  dma_top #(
      .DATA_WIDTH(DATA_WIDTH),
      .STRB_WIDTH(STRB_WIDTH),
      .FIFO_DEPTH(FIFO_DEPTH)
  ) dut (
      .pclk          (pclk),
      .presetn       (presetn),
      .aclk          (aclk),
      .aresetn       (aresetn),
      .dma_start     (dma_start),
      .dma_op        (dma_op),
      .dma_addr      (dma_addr),
      .dma_bytes     (dma_bytes),
      .dma_busy      (dma_busy),
      .dma_done      (dma_done),
      .dma_error     (dma_error),
      .buf_w_valid   (buf_w_valid),
      .buf_w_kind    (buf_w_kind),
      .buf_w_data    (buf_w_data),
      .buf_w_last    (buf_w_last),
      .buf_w_ready   (buf_w_ready),
      .o_buf_valid   (o_buf_valid),
      .o_buf_data    (o_buf_data),
      .o_buf_ready   (o_buf_ready),
      .m_axi_araddr  (m_axi_araddr),
      .m_axi_arlen   (m_axi_arlen),
      .m_axi_arsize  (m_axi_arsize),
      .m_axi_arburst (m_axi_arburst),
      .m_axi_arvalid (m_axi_arvalid),
      .m_axi_arready (m_axi_arready),
      .m_axi_rdata   (m_axi_rdata),
      .m_axi_rresp   (m_axi_rresp),
      .m_axi_rlast   (m_axi_rlast),
      .m_axi_rvalid  (m_axi_rvalid),
      .m_axi_rready  (m_axi_rready),
      .m_axi_awaddr  (m_axi_awaddr),
      .m_axi_awlen   (m_axi_awlen),
      .m_axi_awsize  (m_axi_awsize),
      .m_axi_awburst (m_axi_awburst),
      .m_axi_awvalid (m_axi_awvalid),
      .m_axi_awready (m_axi_awready),
      .m_axi_wdata   (m_axi_wdata),
      .m_axi_wstrb   (m_axi_wstrb),
      .m_axi_wlast   (m_axi_wlast),
      .m_axi_wvalid  (m_axi_wvalid),
      .m_axi_wready  (m_axi_wready),
      .m_axi_bresp   (m_axi_bresp),
      .m_axi_bvalid  (m_axi_bvalid),
      .m_axi_bready  (m_axi_bready),
      .dma_irq       (dma_irq)
  );

  // ---------------------------------------------------------------------------
  // Clock/reset
  // ---------------------------------------------------------------------------
  initial begin
    aclk = 1'b0;
    forever #5 aclk = ~aclk;
  end

  initial begin
    pclk = 1'b0;
    forever #5 pclk = ~pclk;
  end

  task apply_reset;
    begin
      presetn       = 1'b0;
      aresetn       = 1'b0;
      dma_start     = 1'b0;
      dma_op        = 2'b0;
      dma_addr      = 32'b0;
      dma_bytes     = 32'b0;
      buf_w_ready   = 1'b1;
      o_buf_valid   = 1'b0;
      o_buf_data    = 32'b0;
      m_axi_arready = 1'b0;
      m_axi_awready = 1'b0;
      m_axi_wready  = 1'b0;
      m_axi_rdata   = 32'b0;
      m_axi_rresp   = 2'b00;
      m_axi_rlast   = 1'b0;
      m_axi_rvalid  = 1'b0;
      m_axi_bresp   = 2'b00;
      m_axi_bvalid  = 1'b0;
      repeat (8) @(posedge aclk);
      presetn       = 1'b1;
      aresetn       = 1'b1;
      m_axi_arready = 1'b1;
      m_axi_awready = 1'b1;
      m_axi_wready  = 1'b1;
      repeat (4) @(posedge aclk);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Simple AXI read slave model
  // ---------------------------------------------------------------------------
  reg        rd_active;
  reg [31:0] rd_addr;
  reg [7:0]  rd_beats_left;

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      rd_active     <= 1'b0;
      rd_addr       <= 32'b0;
      rd_beats_left <= 8'b0;
      m_axi_rvalid  <= 1'b0;
      m_axi_rlast   <= 1'b0;
      m_axi_rdata   <= 32'b0;
      m_axi_rresp   <= 2'b00;
    end else begin
      if (m_axi_arvalid && m_axi_arready && !rd_active && !m_axi_rvalid) begin
        rd_active     <= 1'b1;
        rd_addr       <= m_axi_araddr;
        rd_beats_left <= m_axi_arlen + 8'd1;
        m_axi_rvalid  <= 1'b1;
        m_axi_rdata   <= mem[m_axi_araddr[11:2]];
        m_axi_rlast   <= (m_axi_arlen == 8'd0);
        m_axi_rresp   <= 2'b00;
      end else if (m_axi_rvalid && m_axi_rready) begin
        if (rd_beats_left == 8'd1) begin
          m_axi_rvalid  <= 1'b0;
          m_axi_rlast   <= 1'b0;
          rd_active     <= 1'b0;
          rd_beats_left <= 8'b0;
        end else begin
          rd_addr       <= rd_addr + STRB_WIDTH;
          rd_beats_left <= rd_beats_left - 8'd1;
          m_axi_rdata   <= mem[(rd_addr + STRB_WIDTH) >> 2];
          m_axi_rlast   <= (rd_beats_left == 8'd2);
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Simple AXI write slave model
  // ---------------------------------------------------------------------------
  reg        wr_active;
  reg [31:0] wr_addr;
  reg [7:0]  wr_beats_left;
  reg        wr_resp_pending;

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      wr_active       <= 1'b0;
      wr_addr         <= 32'b0;
      wr_beats_left   <= 8'b0;
      wr_resp_pending <= 1'b0;
      m_axi_bvalid    <= 1'b0;
      m_axi_bresp     <= 2'b00;
    end else begin
      if (m_axi_awvalid && m_axi_awready && !wr_active) begin
        wr_active     <= 1'b1;
        wr_addr       <= m_axi_awaddr;
        wr_beats_left <= m_axi_awlen + 8'd1;
      end

      if (m_axi_wvalid && m_axi_wready && wr_active) begin
        if (m_axi_wstrb !== {STRB_WIDTH{1'b1}}) begin
          $display("[%0t] ERROR: unexpected WSTRB %b", $time, m_axi_wstrb);
          error_count = error_count + 1;
        end
        mem[wr_addr[11:2]] <= m_axi_wdata;
        wr_addr <= wr_addr + STRB_WIDTH;

        if (wr_beats_left == 8'd1) begin
          if (!m_axi_wlast) begin
            $display("[%0t] ERROR: WLAST not asserted on final write beat", $time);
            error_count = error_count + 1;
          end
          wr_active       <= 1'b0;
          wr_beats_left   <= 8'b0;
          wr_resp_pending <= 1'b1;
        end else begin
          if (m_axi_wlast) begin
            $display("[%0t] ERROR: WLAST asserted before final write beat", $time);
            error_count = error_count + 1;
          end
          wr_beats_left <= wr_beats_left - 8'd1;
        end
      end

      if (wr_resp_pending && !m_axi_bvalid) begin
        m_axi_bvalid    <= 1'b1;
        m_axi_bresp     <= 2'b00;
        wr_resp_pending <= 1'b0;
      end else if (m_axi_bvalid && m_axi_bready) begin
        m_axi_bvalid <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // LOAD checker: verifies buffer side valid/kind/data/last.
  // ---------------------------------------------------------------------------
  reg        load_check_en;
  reg [1:0]  exp_kind;
  reg [31:0] exp_data [0:15];
  integer    exp_beats;
  integer    load_seen;

  always @(posedge aclk) begin
    if (aresetn && load_check_en && buf_w_valid && buf_w_ready) begin
      $display("[%0t] LOAD beat %0d: kind=%0d data=0x%08x last=%0b",
               $time, load_seen, buf_w_kind, buf_w_data, buf_w_last);
      if (buf_w_kind !== exp_kind) begin
        $display("[%0t] ERROR: buf_w_kind mismatch, got %0d expected %0d", $time, buf_w_kind, exp_kind);
        error_count = error_count + 1;
      end
      if (buf_w_data !== exp_data[load_seen]) begin
        $display("[%0t] ERROR: buf_w_data mismatch at beat %0d, got 0x%08x expected 0x%08x",
                 $time, load_seen, buf_w_data, exp_data[load_seen]);
        error_count = error_count + 1;
      end
      if (buf_w_last !== (load_seen == exp_beats - 1)) begin
        $display("[%0t] ERROR: buf_w_last mismatch at beat %0d", $time, load_seen);
        error_count = error_count + 1;
      end
      load_seen = load_seen + 1;
    end
  end

  task wait_done;
    integer timeout;
    begin
      timeout = 0;
      while (!dma_done && !dma_error && timeout < 1000) begin
        @(posedge aclk);
        timeout = timeout + 1;
      end
      if (timeout >= 1000) begin
        $display("[%0t] ERROR: timeout waiting for dma_done", $time);
        error_count = error_count + 1;
      end
      if (dma_error) begin
        $display("[%0t] ERROR: dma_error asserted", $time);
        error_count = error_count + 1;
      end
      @(posedge aclk);
    end
  endtask

  task start_dma;
    input [1:0]  op;
    input [31:0] addr;
    input [31:0] bytes;
    begin
      @(posedge aclk);
      dma_op    <= op;
      dma_addr  <= addr;
      dma_bytes <= bytes;
      dma_start <= 1'b1;
      @(posedge aclk);
      dma_start <= 1'b0;
      dma_op    <= 2'b0;
      dma_addr  <= 32'b0;
      dma_bytes <= 32'b0;
    end
  endtask

  task do_load_test;
    input [1:0]  op;
    input [31:0] base_addr;
    input [31:0] base_data;
    integer j;
    begin
      exp_kind      = op;
      exp_beats     = 4;
      load_seen     = 0;
      load_check_en = 1'b1;
      for (j = 0; j < 4; j = j + 1) begin
        exp_data[j] = base_data + j;
      end

      $display("[%0t] Start LOAD op=%0d addr=0x%08x", $time, op, base_addr);
      start_dma(op, base_addr, 32'd16);
      wait_done();

      if (load_seen != exp_beats) begin
        $display("[%0t] ERROR: LOAD beat count mismatch, got %0d expected %0d",
                 $time, load_seen, exp_beats);
        error_count = error_count + 1;
      end
      load_check_en = 1'b0;
      repeat (5) @(posedge aclk);
    end
  endtask

  reg [31:0] store_data [0:15];

  task do_store_test;
    input [31:0] dst_addr;
    integer j;
    integer sent;
    begin
      for (j = 0; j < 4; j = j + 1) begin
        store_data[j] = 32'hA500_0000 + j;
      end

      $display("[%0t] Start STORE_O addr=0x%08x", $time, dst_addr);
      fork
        begin
          start_dma(DMA_STORE_O, dst_addr, 32'd16);
        end
        begin
          sent = 0;
          o_buf_valid <= 1'b0;
          o_buf_data  <= store_data[0];
          @(posedge aclk);
          @(posedge aclk);
          o_buf_valid <= 1'b1;
          o_buf_data  <= store_data[0];
          while (sent < 4) begin
            @(posedge aclk);
            if (o_buf_valid && o_buf_ready) begin
              $display("[%0t] STORE source beat %0d accepted: data=0x%08x", $time, sent, o_buf_data);
              sent = sent + 1;
              if (sent < 4) begin
                o_buf_data <= store_data[sent];
              end else begin
                o_buf_valid <= 1'b0;
              end
            end
          end
        end
      join

      wait_done();

      for (j = 0; j < 4; j = j + 1) begin
        if (mem[(dst_addr >> 2) + j] !== store_data[j]) begin
          $display("[%0t] ERROR: STORE memory mismatch beat %0d, got 0x%08x expected 0x%08x",
                   $time, j, mem[(dst_addr >> 2) + j], store_data[j]);
          error_count = error_count + 1;
        end
      end
      repeat (5) @(posedge aclk);
    end
  endtask

  initial begin
    $fsdbDumpfile("tb_dma_top.fsdb");
    $fsdbDumpvars(0, tb_dma_top);

    error_count   = 0;
    load_check_en = 1'b0;
    exp_kind      = 2'b0;
    exp_beats     = 0;
    load_seen     = 0;

    for (i = 0; i < 1024; i = i + 1) begin
      mem[i] = 32'h0;
    end

    // Prepare external memory for Q/K/V load tests.
    for (i = 0; i < 4; i = i + 1) begin
      mem[(32'h0000_0100 >> 2) + i] = 32'h1111_0000 + i;
      mem[(32'h0000_0200 >> 2) + i] = 32'h2222_0000 + i;
      mem[(32'h0000_0300 >> 2) + i] = 32'h3333_0000 + i;
    end

    apply_reset();

    do_load_test(DMA_LOAD_Q, 32'h0000_0100, 32'h1111_0000);
    do_load_test(DMA_LOAD_K, 32'h0000_0200, 32'h2222_0000);
    do_load_test(DMA_LOAD_V, 32'h0000_0300, 32'h3333_0000);
    do_store_test(32'h0000_0400);

    if (error_count == 0) begin
      $display("[%0t] TEST PASSED", $time);
    end else begin
      $display("[%0t] TEST FAILED, error_count=%0d", $time, error_count);
    end

    #50;
    $finish;
  end

endmodule
