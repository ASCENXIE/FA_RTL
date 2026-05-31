`default_nettype none

module TOP #(
    parameter integer SEQ_LEN          = 256,
    parameter integer HEAD_DIM         = 64,
    parameter integer TILE_BR          = 16,
    parameter integer TILE_BC          = 16,
    parameter integer ARRAY_DIM        = 16,
    parameter integer ELEM_WIDTH       = 16,
    parameter integer ACC_WIDTH        = 40,
    parameter integer CFG_DATA_WIDTH   = 32,
    parameter integer MEM_ADDR_WIDTH   = 64,
    parameter integer MEM_DATA_WIDTH   = 128,
    parameter integer TILE_INDEX_WIDTH = 5,
    parameter integer BUF_KIND_WIDTH   = 2
) (
    input  wire                          clk,
    input  wire                          rst_n,
    output wire                          irq,

    input  wire [31:0]                   s_axil_awaddr,
    input  wire                          s_axil_awvalid,
    output wire                          s_axil_awready,
    input  wire [31:0]                   s_axil_wdata,
    input  wire [3:0]                    s_axil_wstrb,
    input  wire                          s_axil_wvalid,
    output wire                          s_axil_wready,
    output wire [1:0]                    s_axil_bresp,
    output wire                          s_axil_bvalid,
    input  wire                          s_axil_bready,
    input  wire [31:0]                   s_axil_araddr,
    input  wire                          s_axil_arvalid,
    output wire                          s_axil_arready,
    output wire [31:0]                   s_axil_rdata,
    output wire [1:0]                    s_axil_rresp,
    output wire                          s_axil_rvalid,
    input  wire                          s_axil_rready,

    output wire [MEM_ADDR_WIDTH-1:0]     m_axi_awaddr,
    output wire [7:0]                    m_axi_awlen,
    output wire [2:0]                    m_axi_awsize,
    output wire [1:0]                    m_axi_awburst,
    output wire                          m_axi_awvalid,
    input  wire                          m_axi_awready,
    output wire [MEM_DATA_WIDTH-1:0]     m_axi_wdata,
    output wire [(MEM_DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output wire                          m_axi_wlast,
    output wire                          m_axi_wvalid,
    input  wire                          m_axi_wready,
    input  wire [1:0]                    m_axi_bresp,
    input  wire                          m_axi_bvalid,
    output wire                          m_axi_bready,
    output wire [MEM_ADDR_WIDTH-1:0]     m_axi_araddr,
    output wire [7:0]                    m_axi_arlen,
    output wire [2:0]                    m_axi_arsize,
    output wire [1:0]                    m_axi_arburst,
    output wire                          m_axi_arvalid,
    input  wire                          m_axi_arready,
    input  wire [MEM_DATA_WIDTH-1:0]     m_axi_rdata,
    input  wire [1:0]                    m_axi_rresp,
    input  wire                          m_axi_rlast,
    input  wire                          m_axi_rvalid,
    output wire                          m_axi_rready
);

    localparam integer BUF_OP_WIDTH     = 3;
    localparam integer DMA_OP_WIDTH     = 2;
    localparam integer CORE_MODE_WIDTH  = 2;
    localparam integer VPU_OP_WIDTH     = 3;
    localparam integer STREAM_LANES     = ARRAY_DIM;
    localparam integer STREAM_DATA_W    = STREAM_LANES * ELEM_WIDTH;
    localparam integer STREAM_ACC_W     = STREAM_LANES * ACC_WIDTH;
    localparam integer ELEM_BYTES       = ELEM_WIDTH / 8;
    localparam integer MAX_TILE_ROWS    = (TILE_BR > TILE_BC) ? TILE_BR : TILE_BC;
    localparam integer MAX_TILE_BYTES   = MAX_TILE_ROWS * HEAD_DIM * ELEM_BYTES;
    localparam integer DMA_BYTES_WIDTH  = $clog2(MAX_TILE_BYTES + 1);
    localparam integer BUF_WORD_COUNT_W = 8;

    wire                          ip_rst_n;

    wire                          cfg_start_pulse;
    wire                          cfg_done_clr;
    wire                          cfg_soft_reset;
    wire                          cfg_irq_en;
    wire                          cfg_causal_en;
    wire [MEM_ADDR_WIDTH-1:0]     cfg_q_base;
    wire [MEM_ADDR_WIDTH-1:0]     cfg_k_base;
    wire [MEM_ADDR_WIDTH-1:0]     cfg_v_base;
    wire [MEM_ADDR_WIDTH-1:0]     cfg_o_base;
    wire [31:0]                   cfg_stride_bytes;
    wire [CFG_DATA_WIDTH-1:0]     cfg_neg_large;
    wire [CFG_DATA_WIDTH-1:0]     cfg_scale;

    wire                          status_idle;
    wire                          status_busy;
    wire                          status_done;
    wire                          status_error;
    wire [31:0]                   perf_cycles;
    wire [7:0]                    debug_q_tile;
    wire [7:0]                    debug_kv_tile;

    wire                          addrgen_start;
    wire [DMA_OP_WIDTH-1:0]       addrgen_mem_sel;
    wire [TILE_INDEX_WIDTH-1:0]   addrgen_tile_idx;
    wire                          addrgen_done;
    wire [MEM_ADDR_WIDTH-1:0]     addrgen_addr;
    wire [DMA_BYTES_WIDTH-1:0]    addrgen_bytes;

    wire                          dma_start;
    wire [DMA_OP_WIDTH-1:0]       dma_op;
    wire                          dma_busy;
    wire                          dma_done;
    wire                          dma_error;
    wire                          dma_buf_w_valid;
    wire [BUF_KIND_WIDTH-1:0]     dma_buf_w_kind;
    wire [MEM_DATA_WIDTH-1:0]     dma_buf_w_data;
    wire                          dma_buf_w_last;
    wire                          dma_buf_w_ready;

    wire                          buf_start;
    wire [BUF_OP_WIDTH-1:0]       buf_op;
    wire                          buf_pingpong_sel;
    wire [BUF_WORD_COUNT_W-1:0]   buf_word_count;
    wire                          buf_busy;
    wire                          buf_done;

    wire                          core_start;
    wire [CORE_MODE_WIDTH-1:0]    core_mode;
    wire                          core_busy;
    wire                          core_done;

    wire                          vpu_start;
    wire [VPU_OP_WIDTH-1:0]       vpu_op;
    wire [TILE_INDEX_WIDTH-1:0]   vpu_q_tile_idx;
    wire [TILE_INDEX_WIDTH-1:0]   vpu_kv_tile_idx;
    wire                          vpu_busy;
    wire                          vpu_done;

    wire                          q_stream_valid;
    wire [STREAM_DATA_W-1:0]      q_stream_data;
    wire                          q_stream_last;
    wire                          q_stream_ready;

    wire                          k_stream_valid;
    wire [STREAM_DATA_W-1:0]      k_stream_data;
    wire                          k_stream_last;
    wire                          k_stream_ready;

    wire                          v_stream_valid;
    wire [STREAM_DATA_W-1:0]      v_stream_data;
    wire                          v_stream_last;
    wire                          v_stream_ready;

    wire                          p_stream_valid;
    wire [STREAM_DATA_W-1:0]      p_stream_data;
    wire                          p_stream_last;
    wire                          p_stream_ready;

    wire                          score_stream_valid;
    wire [STREAM_ACC_W-1:0]       score_stream_data;
    wire                          score_stream_last;
    wire                          score_stream_ready;

    wire                          pv_stream_valid;
    wire [STREAM_ACC_W-1:0]       pv_stream_data;
    wire                          pv_stream_last;
    wire                          pv_stream_ready;

    wire                          o_stream_valid;
    wire [MEM_DATA_WIDTH-1:0]     o_stream_data;
    wire                          o_stream_last;
    wire                          o_stream_ready;

    initial begin
        if (SEQ_LEN <= 0) $error("SEQ_LEN must be > 0");
        if (HEAD_DIM <= 0) $error("HEAD_DIM must be > 0");
        if (TILE_BR <= 0) $error("TILE_BR must be > 0");
        if (TILE_BC <= 0) $error("TILE_BC must be > 0");
        if ((SEQ_LEN % TILE_BR) != 0) $error("SEQ_LEN must be divisible by TILE_BR");
        if ((SEQ_LEN % TILE_BC) != 0) $error("SEQ_LEN must be divisible by TILE_BC");
        if (TILE_BR > ARRAY_DIM) $error("TILE_BR must be <= ARRAY_DIM");
        if (TILE_BC > ARRAY_DIM) $error("TILE_BC must be <= ARRAY_DIM");
        if ((HEAD_DIM % ARRAY_DIM) != 0) $error("HEAD_DIM must be divisible by ARRAY_DIM");
    end

    assign ip_rst_n = rst_n & ~cfg_soft_reset;
    assign irq      = cfg_irq_en & status_done;

    fa_axi_lite_regs #(
        .CFG_DATA_WIDTH(CFG_DATA_WIDTH)
    ) u_fa_axi_lite_regs (
        .clk              (clk),
        .rst_n            (rst_n),
        .s_axil_awaddr    (s_axil_awaddr),
        .s_axil_awvalid   (s_axil_awvalid),
        .s_axil_awready   (s_axil_awready),
        .s_axil_wdata     (s_axil_wdata),
        .s_axil_wstrb     (s_axil_wstrb),
        .s_axil_wvalid    (s_axil_wvalid),
        .s_axil_wready    (s_axil_wready),
        .s_axil_bresp     (s_axil_bresp),
        .s_axil_bvalid    (s_axil_bvalid),
        .s_axil_bready    (s_axil_bready),
        .s_axil_araddr    (s_axil_araddr),
        .s_axil_arvalid   (s_axil_arvalid),
        .s_axil_arready   (s_axil_arready),
        .s_axil_rdata     (s_axil_rdata),
        .s_axil_rresp     (s_axil_rresp),
        .s_axil_rvalid    (s_axil_rvalid),
        .s_axil_rready    (s_axil_rready),
        .ctrl_start_pulse (cfg_start_pulse),
        .ctrl_done_clr    (cfg_done_clr),
        .ctrl_soft_reset  (cfg_soft_reset),
        .ctrl_irq_en      (cfg_irq_en),
        .ctrl_causal_en   (cfg_causal_en),
        .cfg_q_base       (cfg_q_base),
        .cfg_k_base       (cfg_k_base),
        .cfg_v_base       (cfg_v_base),
        .cfg_o_base       (cfg_o_base),
        .cfg_stride_bytes (cfg_stride_bytes),
        .cfg_neg_large    (cfg_neg_large),
        .cfg_scale        (cfg_scale),
        .status_busy      (status_busy),
        .status_done      (status_done),
        .status_error     (status_error),
        .perf_cycles      (perf_cycles),
        .debug_q_tile     (debug_q_tile),
        .debug_kv_tile    (debug_kv_tile)
    );

    fa_scheduler #(
        .SEQ_LEN         (SEQ_LEN),
        .HEAD_DIM        (HEAD_DIM),
        .TILE_BR         (TILE_BR),
        .TILE_BC         (TILE_BC),
        .TILE_INDEX_WIDTH(TILE_INDEX_WIDTH)
    ) u_fa_scheduler (
        .clk              (clk),
        .rst_n            (ip_rst_n),
        .start            (cfg_start_pulse),
        .done_clr         (cfg_done_clr),
        .causal_en        (cfg_causal_en),
        .addrgen_start    (addrgen_start),
        .addrgen_mem_sel  (addrgen_mem_sel),
        .addrgen_tile_idx (addrgen_tile_idx),
        .addrgen_done     (addrgen_done),
        .dma_start        (dma_start),
        .dma_op           (dma_op),
        .dma_busy         (dma_busy),
        .dma_done         (dma_done),
        .dma_error        (dma_error),
        .buf_start        (buf_start),
        .buf_op           (buf_op),
        .buf_pingpong_sel (buf_pingpong_sel),
        .buf_word_count   (buf_word_count),
        .buf_busy         (buf_busy),
        .buf_done         (buf_done),
        .core_start       (core_start),
        .core_mode        (core_mode),
        .core_busy        (core_busy),
        .core_done        (core_done),
        .vpu_start        (vpu_start),
        .vpu_op           (vpu_op),
        .vpu_q_tile_idx   (vpu_q_tile_idx),
        .vpu_kv_tile_idx  (vpu_kv_tile_idx),
        .vpu_busy         (vpu_busy),
        .vpu_done         (vpu_done),
        .status_idle      (status_idle),
        .status_busy      (status_busy),
        .status_done      (status_done),
        .status_error     (status_error),
        .perf_cycles      (perf_cycles),
        .debug_q_tile     (debug_q_tile),
        .debug_kv_tile    (debug_kv_tile)
    );

    fa_addr_gen #(
        .SEQ_LEN         (SEQ_LEN),
        .HEAD_DIM        (HEAD_DIM),
        .TILE_BR         (TILE_BR),
        .TILE_BC         (TILE_BC),
        .ELEM_BYTES      (ELEM_BYTES),
        .TILE_INDEX_WIDTH(TILE_INDEX_WIDTH),
        .DMA_BYTES_WIDTH (DMA_BYTES_WIDTH)
    ) u_fa_addr_gen (
        .clk          (clk),
        .rst_n        (ip_rst_n),
        .start        (addrgen_start),
        .mem_sel      (addrgen_mem_sel),
        .tile_idx     (addrgen_tile_idx),
        .q_base       (cfg_q_base),
        .k_base       (cfg_k_base),
        .v_base       (cfg_v_base),
        .o_base       (cfg_o_base),
        .stride_bytes (cfg_stride_bytes),
        .dma_addr     (addrgen_addr),
        .dma_bytes    (addrgen_bytes),
        .done         (addrgen_done)
    );

    fa_dma_engine #(
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH),
        .DMA_DATA_WIDTH (MEM_DATA_WIDTH),
        .DMA_BYTES_WIDTH(DMA_BYTES_WIDTH),
        .BUF_KIND_WIDTH (BUF_KIND_WIDTH)
    ) u_fa_dma_engine (
        .clk           (clk),
        .rst_n         (ip_rst_n),
        .start         (dma_start),
        .dma_op        (dma_op),
        .dma_addr      (addrgen_addr),
        .dma_bytes     (addrgen_bytes),
        .busy          (dma_busy),
        .done          (dma_done),
        .error         (dma_error),
        .buf_w_valid   (dma_buf_w_valid),
        .buf_w_kind    (dma_buf_w_kind),
        .buf_w_data    (dma_buf_w_data),
        .buf_w_last    (dma_buf_w_last),
        .buf_w_ready   (dma_buf_w_ready),
        .o_stream_valid(o_stream_valid),
        .o_stream_data (o_stream_data),
        .o_stream_last (o_stream_last),
        .o_stream_ready(o_stream_ready),
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
        .m_axi_rready  (m_axi_rready)
    );

    fa_buffer_cluster #(
        .HEAD_DIM       (HEAD_DIM),
        .TILE_BR        (TILE_BR),
        .TILE_BC        (TILE_BC),
        .ARRAY_DIM      (ARRAY_DIM),
        .ELEM_WIDTH     (ELEM_WIDTH),
        .DMA_DATA_WIDTH (MEM_DATA_WIDTH),
        .BUF_KIND_WIDTH (BUF_KIND_WIDTH)
    ) u_fa_buffer_cluster (
        .clk              (clk),
        .rst_n            (ip_rst_n),
        .start            (buf_start),
        .buf_op           (buf_op),
        .buf_pingpong_sel (buf_pingpong_sel),
        .word_count       (buf_word_count),
        .busy             (buf_busy),
        .done             (buf_done),
        .dma_w_valid      (dma_buf_w_valid),
        .dma_w_kind       (dma_buf_w_kind),
        .dma_w_data       (dma_buf_w_data),
        .dma_w_last       (dma_buf_w_last),
        .dma_w_ready      (dma_buf_w_ready),
        .q_stream_valid   (q_stream_valid),
        .q_stream_data    (q_stream_data),
        .q_stream_last    (q_stream_last),
        .q_stream_ready   (q_stream_ready),
        .k_stream_valid   (k_stream_valid),
        .k_stream_data    (k_stream_data),
        .k_stream_last    (k_stream_last),
        .k_stream_ready   (k_stream_ready),
        .v_stream_valid   (v_stream_valid),
        .v_stream_data    (v_stream_data),
        .v_stream_last    (v_stream_last),
        .v_stream_ready   (v_stream_ready)
    );

    fa_compute_core #(
        .SEQ_LEN    (SEQ_LEN),
        .HEAD_DIM   (HEAD_DIM),
        .TILE_BR    (TILE_BR),
        .TILE_BC    (TILE_BC),
        .ARRAY_DIM  (ARRAY_DIM),
        .ELEM_WIDTH (ELEM_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_fa_compute_core (
        .clk               (clk),
        .rst_n             (ip_rst_n),
        .start             (core_start),
        .core_mode         (core_mode),
        .busy              (core_busy),
        .done              (core_done),
        .q_stream_valid    (q_stream_valid),
        .q_stream_data     (q_stream_data),
        .q_stream_last     (q_stream_last),
        .q_stream_ready    (q_stream_ready),
        .k_stream_valid    (k_stream_valid),
        .k_stream_data     (k_stream_data),
        .k_stream_last     (k_stream_last),
        .k_stream_ready    (k_stream_ready),
        .p_stream_valid    (p_stream_valid),
        .p_stream_data     (p_stream_data),
        .p_stream_last     (p_stream_last),
        .p_stream_ready    (p_stream_ready),
        .v_stream_valid    (v_stream_valid),
        .v_stream_data     (v_stream_data),
        .v_stream_last     (v_stream_last),
        .v_stream_ready    (v_stream_ready),
        .score_stream_valid(score_stream_valid),
        .score_stream_data (score_stream_data),
        .score_stream_last (score_stream_last),
        .score_stream_ready(score_stream_ready),
        .pv_stream_valid   (pv_stream_valid),
        .pv_stream_data    (pv_stream_data),
        .pv_stream_last    (pv_stream_last),
        .pv_stream_ready   (pv_stream_ready)
    );

    fa_vpu #(
        .TILE_BR         (TILE_BR),
        .TILE_BC         (TILE_BC),
        .HEAD_DIM        (HEAD_DIM),
        .ARRAY_DIM       (ARRAY_DIM),
        .ELEM_WIDTH      (ELEM_WIDTH),
        .ACC_WIDTH       (ACC_WIDTH),
        .CFG_DATA_WIDTH  (CFG_DATA_WIDTH),
        .DMA_DATA_WIDTH  (MEM_DATA_WIDTH),
        .TILE_INDEX_WIDTH(TILE_INDEX_WIDTH)
    ) u_fa_vpu (
        .clk               (clk),
        .rst_n             (ip_rst_n),
        .start             (vpu_start),
        .vpu_op            (vpu_op),
        .busy              (vpu_busy),
        .done              (vpu_done),
        .q_tile_idx        (vpu_q_tile_idx),
        .kv_tile_idx       (vpu_kv_tile_idx),
        .score_stream_valid(score_stream_valid),
        .score_stream_data (score_stream_data),
        .score_stream_last (score_stream_last),
        .score_stream_ready(score_stream_ready),
        .pv_stream_valid   (pv_stream_valid),
        .pv_stream_data    (pv_stream_data),
        .pv_stream_last    (pv_stream_last),
        .pv_stream_ready   (pv_stream_ready),
        .p_stream_valid    (p_stream_valid),
        .p_stream_data     (p_stream_data),
        .p_stream_last     (p_stream_last),
        .p_stream_ready    (p_stream_ready),
        .o_stream_valid    (o_stream_valid),
        .o_stream_data     (o_stream_data),
        .o_stream_last     (o_stream_last),
        .o_stream_ready    (o_stream_ready),
        .neg_large         (cfg_neg_large),
        .scale             (cfg_scale)
    );

endmodule

`default_nettype wire
