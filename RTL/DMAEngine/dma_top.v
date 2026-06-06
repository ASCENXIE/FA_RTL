`timescale 1ns / 1ps
 
module dma_top #(
    parameter DATA_WIDTH = 32,
    parameter STRB_WIDTH = DATA_WIDTH / 8
    )(
    // 1. 全局时钟与复位
    input  wire        pclk,       // APB 控制面时钟
    input  wire        presetn,    // APB 控制面复位
    input  wire        aclk,       // AXI 数据面时钟
    input  wire        aresetn,    // AXI 数据面复位
 
    // 2. APB Slave 接口 
    input  wire [31:0] paddr,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] pwdata,
    output wire [31:0] prdata,
    output wire        pready,
 
    // 3. AXI4-Full Master Read 接口
    output wire [31:0]           m_axi_araddr,
    output wire [7:0]            m_axi_arlen,
    output wire [2:0]            m_axi_arsize,
    output wire [1:0]            m_axi_arburst,
    output wire                  m_axi_arvalid,
    input  wire                  m_axi_arready,
    input  wire [DATA_WIDTH-1:0] m_axi_rdata,
    input  wire                  m_axi_rlast,
    input  wire                  m_axi_rvalid,
    output wire                  m_axi_rready,
 
    // 4. AXI4-Full Master Write 接口
    output wire [31:0]           m_axi_awaddr,
    output wire [7:0]            m_axi_awlen,
    output wire [2:0]            m_axi_awsize,
    output wire [1:0]            m_axi_awburst,
    output wire                  m_axi_awvalid,
    input  wire                  m_axi_awready,
    output wire [DATA_WIDTH-1:0] m_axi_wdata,
    output wire [STRB_WIDTH-1:0] m_axi_wstrb,
    output wire                  m_axi_wlast,
    output wire                  m_axi_wvalid,
    input  wire                  m_axi_wready,
    input  wire [1:0]            m_axi_bresp,
    input  wire                  m_axi_bvalid,
    output wire                  m_axi_bready,
    
    // 芯片级硬件中断输出
    output wire        dma_irq
);
 
// --- CSR 与 AXI 模块的控制线 ---
wire        cmd_start_pclk, cmd_start_aclk;
wire [31:0] cmd_src_addr;
wire [31:0] cmd_xfer_len;
wire [31:0] cmd_dst_addr;
wire        src_fixed;
wire        dst_fixed;
 
// --- AXI 给 CSR 的状态反馈线 ---
wire        read_is_busy;
wire        write_is_busy;
wire        write_is_done; 
wire        write_is_done_aclk;
 
// AXI 读写只要有一个在忙，整个 DMA 就在忙；但只有写完，才算全干完
wire        dma_is_busy_aclk = read_is_busy | write_is_busy;
wire        dma_is_busy_pclk;
wire        dma_is_done_pclk; 
 
// --- 跨时钟域 FIFO 数据线 ---
wire [DATA_WIDTH-1:0] fifo_wdata;
wire                  fifo_wren;
wire                  fifo_full;
wire [DATA_WIDTH-1:0] fifo_rdata;
wire                  fifo_rden;
wire                  fifo_empty;
 
// apb to axi sync （慢到快CDC，打拍）
reg [2:0] start_sync_aclk;
always @(posedge aclk or negedge aresetn) begin
    if (!aresetn)
        start_sync_aclk <= 3'b0;
    else
        start_sync_aclk <= {start_sync_aclk[1:0], cmd_start_pclk};
end
assign cmd_start_aclk = start_sync_aclk[1] && ~start_sync_aclk[2];
 
// axi to apb sync （快到慢CDC，busy是电平信号，打拍即可）
// 在目的时钟域 (pclk) 准备一个两位的移位寄存器
reg [1:0] busy_sync_pclk;
always @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
        busy_sync_pclk <= 2'b0;
    end else begin
        // 经典两级打拍：
        busy_sync_pclk <= {busy_sync_pclk[0], dma_is_busy_aclk};
    end
end
assign dma_is_busy_pclk = busy_sync_pclk[1];
 
// done是脉冲信号，在快时钟下，把脉冲变成电平翻转
reg done_toggle_aclk;
always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) 
        done_toggle_aclk <= 1'b0;
    else if (write_is_done_aclk) 
        done_toggle_aclk <= ~done_toggle_aclk; // 抓到 done 就翻转一次
end
// 在慢时钟下，打两拍同步这个电平
reg [2:0] done_sync_pclk;
always @(posedge pclk or negedge presetn) begin
    if (!presetn)
        done_sync_pclk <= 3'b0;
    else
        done_sync_pclk <= {done_sync_pclk[1:0], done_toggle_aclk};
end
// 在慢时钟下提取翻转的边沿 (异或操作)
assign dma_is_done_pclk = done_sync_pclk[1] ^ done_sync_pclk[2];
 
// 模块 1
dma_csr u_dma_csr (
    .pclk         (pclk),
    .presetn      (presetn),
    .paddr        (paddr),
    .psel         (psel),
    .penable      (penable),
    .pwrite       (pwrite),
    .pwdata       (pwdata),
    .prdata       (prdata),
    .pready       (pready),
    .dma_start    (cmd_start_pclk),
    .dma_src_addr (cmd_src_addr),
    .dma_xfer_len (cmd_xfer_len),
    .dma_dst_addr (cmd_dst_addr),
    .src_fixed (src_fixed),
    .dst_fixed (dst_fixed),
    .dma_is_busy  (dma_is_busy_pclk),
    .dma_is_done  (dma_is_done_pclk),
    .dma_irq      (dma_irq)
);
 
// 模块 2
axi_read_out #(
    .DATA_WIDTH(DATA_WIDTH)
    ) u_axi_read_out (
    .aclk         (aclk),
    .aresetn      (aresetn),
    .dma_start    (cmd_start_aclk),
    .dma_src_addr (cmd_src_addr),
    .dma_xfer_len (cmd_xfer_len),
    .fixed_mode   (src_fixed),
    .dma_is_busy  (read_is_busy),
    .dma_is_done  (), // 读完不算完，悬空不管
    .m_axi_araddr (m_axi_araddr),
    .m_axi_arlen  (m_axi_arlen),
    .m_axi_arsize (m_axi_arsize),
    .m_axi_arburst(m_axi_arburst),
    .m_axi_arvalid(m_axi_arvalid),
    .m_axi_arready(m_axi_arready),
    .m_axi_rdata  (m_axi_rdata),
    .m_axi_rlast  (m_axi_rlast),
    .m_axi_rvalid (m_axi_rvalid),
    .m_axi_rready (m_axi_rready),
    .fifo_wdata   (fifo_wdata),
    .fifo_wren    (fifo_wren),
    .fifo_full    (fifo_full)
);
 
// 模块 3
asyn_fifo #(
    .DATA_WIDTH(DATA_WIDTH),
    .FIFO_DEPTH(16)
) u_asyn_fifo (
    .rst_n        (aresetn), 
    // 写端 (接 AXI Read)
    .clk_wr       (aclk),    // 目前先都接 aclk，支持异步
    .en_wr        (fifo_wren),
    .data_in      (fifo_wdata),
    .full         (fifo_full),
    // 读端 (接 AXI Write)
    .clk_rd       (aclk),    
    .en_rd        (fifo_rden),
    .data_out     (fifo_rdata),
    .empty        (fifo_empty)
);
 
// 模块 4
axi_write_out #(
    .DATA_WIDTH(DATA_WIDTH),
    .STRB_WIDTH(STRB_WIDTH) 
    ) u_axi_write_out (
    .aclk         (aclk),
    .aresetn      (aresetn),
    .dma_start    (cmd_start_aclk),
    .dma_dst_addr (cmd_dst_addr),
    .dma_xfer_len (cmd_xfer_len),
    .fixed_mode   (dst_fixed),
    .dma_is_busy  (write_is_busy),
    .dma_is_done  (write_is_done_aclk), // dma结束标志
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
    .fifo_rdata   (fifo_rdata),
    .fifo_rden    (fifo_rden),
    .fifo_empty   (fifo_empty)
);
 
endmodule