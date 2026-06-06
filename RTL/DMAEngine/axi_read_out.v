`timescale 1ns / 1ps
module axi_read_out #(
    parameter DATA_WIDTH = 32
    )(
    input  wire                  aclk,
    input  wire                  aresetn,
 
    // 与 CSR 模块的接口
    input  wire                  dma_start,
    input  wire [31:0]           dma_src_addr,
    input  wire [31:0]           dma_xfer_len,  
    input  wire                  fixed_mode,
    output wire                  dma_is_busy,
    output wire                  dma_is_done,
    
    // AXI4-Full Master Read 通道
    // --- AR 地址通道 ---
    output reg  [31:0]           m_axi_araddr,
    output wire [7:0]            m_axi_arlen,
    output wire [2:0]            m_axi_arsize,
    output wire [1:0]            m_axi_arburst,
    output reg                   m_axi_arvalid,
    input  wire                  m_axi_arready,
 
    // --- R 数据通道  ---
    input  wire [DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [1:0]            m_axi_rresp,
    input  wire                  m_axi_rlast,   
    input  wire                  m_axi_rvalid,
    output wire                  m_axi_rready,
 
    // 与内部 FIFO 的接口 (写入 FIFO )
    output wire [DATA_WIDTH-1:0] fifo_wdata,    
    output wire                  fifo_wren,     
    input  wire                  fifo_full      
    );
    
localparam STRB_WIDTH = DATA_WIDTH / 8;
localparam ADDR_SHIFT = $clog2(STRB_WIDTH);
localparam AXI_SIZE   = ADDR_SHIFT[2:0];
 
reg [7:0] arlen_r; // 当前burst-1的长度寄存
assign m_axi_arsize  = AXI_SIZE; 
assign m_axi_arburst = fixed_mode ? 2'b00 : 2'b01;
assign m_axi_arlen = arlen_r;
 
// outstanding计数器，用AW握手和input的rlast控制计数逻辑
localparam OST_DEPTH = 4;           // 最大挂起4个请求（将一个transaction划分为多个burst请求）
reg [2:0] ost_cnt;                  // 未完成请求数量，AW握手但未收到m_axi_rlast
wire cmd_full = (ost_cnt == OST_DEPTH); 
 
reg dma_running;       // dma运行开关
reg [31:0] remain_len; // 还剩多少数据没发
 
wire [31:0] cur_burst_len = (remain_len >= 32'd16) ? 32'd16 : remain_len;
 
// 只要outstanding计数没满，就一直发地址
always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        m_axi_arvalid <= 1'b0;
        m_axi_araddr  <= 32'b0;
        arlen_r       <= 8'b0;
        remain_len    <= 32'b0;
    end 
    else begin
        // 预启动状态，目标初始地址传入，transaction总数据数
        if (dma_start && !dma_running) begin
            m_axi_araddr <= dma_src_addr;
            remain_len   <= dma_xfer_len >> ADDR_SHIFT;  // 将字节数转化为axi数据宽度匹配的宽度
        end
        // arvalid 0 1 0 1变化，实现arlen的写入与发出
        // 满足可以继续接收地址的条件，拉高arvalid
        else if (dma_running && (remain_len > 0) && !cmd_full && !m_axi_arvalid) begin
            m_axi_arvalid <= 1'b1;
            arlen_r       <= cur_burst_len - 1'b1;
        end
        // AW握手成功，更新remain_len
        else if (m_axi_arvalid && m_axi_arready) begin
            m_axi_arvalid <= 1'b0; 
            remain_len    <= remain_len - cur_burst_len;
            // 更新下一次地址
            if (!fixed_mode) begin
                m_axi_araddr <= m_axi_araddr + (cur_burst_len << ADDR_SHIFT);
            end
        end
    end
end
 
// R通道只要内部fifo !empty，rready=1
assign m_axi_rready = !fifo_full; 
// 总线数据写入fifo
assign fifo_wdata   = m_axi_rdata;
assign fifo_wren    = m_axi_rvalid && m_axi_rready; // R握手
 
// 判断一次完整的burst是否结束
wire ar_shake      = m_axi_arvalid && m_axi_arready;                // AW握手，发出一个读地址请求
wire r_burst_done  = m_axi_rvalid && m_axi_rready && m_axi_rlast;   // 判断一个burst请求完全结束
always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        ost_cnt     <= 3'b0;
        dma_running <= 1'b0;
    end else begin
        // DMA运行与停止
        if (dma_start)
            dma_running <= 1'b1;
        else if (dma_is_done)
            dma_running <= 1'b0;
        // 判断当前剩余请求数
        if (ar_shake && !r_burst_done) 
            ost_cnt <= ost_cnt + 1'b1;
        else if (!ar_shake && r_burst_done) 
            ost_cnt <= ost_cnt - 1'b1;
    end
end
 
// done必须满足本次transaction全发完（remain==0）+所有burst事件都结束（ost_cnt==0）
assign dma_is_busy = dma_running;
assign dma_is_done = dma_running && (remain_len == 0) && (ost_cnt == 0);
 
endmodule