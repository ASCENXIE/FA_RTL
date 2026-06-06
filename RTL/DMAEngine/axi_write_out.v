`timescale 1ns / 1ps
module axi_write_out #(
    parameter DATA_WIDTH = 32,
    parameter STRB_WIDTH = DATA_WIDTH / 8
    )(
    input  wire                  aclk,
    input  wire                  aresetn,
 
    // 与 CSR 模块的接口
    input  wire                  dma_start,
    input  wire [31:0]           dma_dst_addr,  
    input  wire [31:0]           dma_xfer_len,  
    input  wire                  fixed_mode,
    output wire                  dma_is_busy,
    output wire                  dma_is_done,
    
    // --- AW 地址通道 ---
    output reg  [31:0]           m_axi_awaddr,
    output wire [7:0]            m_axi_awlen,
    output wire [2:0]            m_axi_awsize,
    output wire [1:0]            m_axi_awburst,
    output reg                   m_axi_awvalid,
    input  wire                  m_axi_awready,
 
    // --- W 数据通道 --- 
    output wire [DATA_WIDTH-1:0] m_axi_wdata,
    output wire [STRB_WIDTH-1:0] m_axi_wstrb,   
    output wire                  m_axi_wlast,   
    output wire                  m_axi_wvalid,
    input  wire                  m_axi_wready,
 
    // --- B 响应通道 --- 
    input  wire [1:0]            m_axi_bresp,
    input  wire                  m_axi_bvalid,
    output wire                  m_axi_bready,
 
    // 与内部 FIFO 的接口 （读出）
    input  wire [DATA_WIDTH-1:0] fifo_rdata,    
    output wire                  fifo_rden,     
    input  wire                  fifo_empty     
    );
// transaction -- N*burt -- M*transfer， N, M >= 1
localparam ADDR_SHIFT = $clog2(STRB_WIDTH);
localparam AXI_SIZE   = ADDR_SHIFT[2:0];
 
// 不采用状态机，而是三通道独立
reg [7:0] awlen_r; // 当前burst-1的长度寄存
assign m_axi_awsize  = AXI_SIZE; 
assign m_axi_awburst = fixed_mode ? 2'b00 : 2'b01;
assign m_axi_wstrb   = {STRB_WIDTH{1'b1}};
assign m_axi_awlen = awlen_r;
 
// 迷你4深度cmdfifo，fifo宽度表示当前burst传多少个数据
localparam OST_DEPTH = 4;            // 最大挂起4个请求（将一个transaction划分为多个burst请求）
reg [7:0] cmd_fifo [0:OST_DEPTH-1]; // 用来存awlen，即当前burst传输长度
reg [2:0] cmd_wr_ptr;               // AW通道写入地址
reg [2:0] cmd_rd_ptr;               // W通道读出地址
reg [2:0] ost_cnt;                  // 未完成请求数量，AW握手但对应的B还未响应
 
wire cmd_full  = (ost_cnt == OST_DEPTH);     // AW和B通道握手，决定目前有几个挂起，与W通道无关
wire cmd_empty = (cmd_wr_ptr == cmd_rd_ptr); // 读写指针追尾，只为W通道更块
 
reg        dma_running;       // DMA运行状态
reg [31:0] remain_len; // 当前transaction剩余数据数量
 
// AW通道，remain_len>0 （当前transaction剩余数据数量），且!cmd_full（请求没满），就发地址
wire [31:0] cur_burst_len = (remain_len >= 32'd16) ? 32'd16 : remain_len; // 当前burst传输的长度
always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        m_axi_awvalid <= 1'b0;
        m_axi_awaddr  <= 32'b0;
        awlen_r       <= 8'b0;
        remain_len    <= 32'b0;
        cmd_wr_ptr    <= 3'b0;
    end 
    else begin
        // 预启动状态，目标初始地址传入，transaction总数据数
        if (dma_start && !dma_running) begin
            m_axi_awaddr <= dma_dst_addr;
            remain_len   <= dma_xfer_len >> ADDR_SHIFT; // 算出总字数
        end
        // awvalid 0 1 0 1变化，实现awlen的写入与发出
        // 满足可以继续接收地址的条件，拉高awvalid
        else if (dma_running && (remain_len > 0) && !cmd_full && !m_axi_awvalid) begin
            m_axi_awvalid <= 1'b1;
            awlen_r       <= cur_burst_len - 1'b1; // 填好这单的数量
        end
        // AW握手，地址传输完成，burst长度写入cmdfifo，更新写指针，更新剩余数据数量，更新地址，拉低awvalid
        else if (m_axi_awvalid && m_axi_awready) begin
            m_axi_awvalid <= 1'b0; 
            // 把当前burst长度写进cmdfifo记录
            cmd_fifo[cmd_wr_ptr[1:0]] <= awlen_r;
            cmd_wr_ptr <= cmd_wr_ptr + 1'b1;
            // remain_len表示当前transaction中还未写入cmdfifo的数量
            remain_len <= remain_len - cur_burst_len;
            // 更新下一次地址
            if (!fixed_mode) begin
                m_axi_awaddr <= m_axi_awaddr + (cur_burst_len << ADDR_SHIFT);
            end
            else
                m_axi_awaddr <= m_axi_awaddr;
        end
    end
end
 
// W通道，cmdfifo非空（有地址挂起）就发送数据
reg [7:0] wdata_cnt;  // 倒数计数器，计aw_len（burstlen-1）
reg       w_active;   // w通道传输中标志
// 处于传输过程且数据fifo非空，就拉高wvalid
assign m_axi_wvalid = w_active && !fifo_empty;
assign m_axi_wdata  = fifo_rdata;
assign fifo_rden    = m_axi_wvalid && m_axi_wready; // AXI 握手了，FIFO 指针才走
assign m_axi_wlast  = (wdata_cnt == 0);             // 倒数到 0 自动拉高
 
always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        w_active   <= 1'b0;
        wdata_cnt  <= 8'b0;
        cmd_rd_ptr <= 3'b0;
    end else begin
        // W通道还处于静态且cmdfifo非空（有待传输请求），开始W通道传输
        if (!w_active && !cmd_empty) begin
            w_active   <= 1'b1; // W通道传输标志
            wdata_cnt  <= cmd_fifo[cmd_rd_ptr[1:0]]; // 从cmdfifo读出本次burst（请求）要传的数量
            cmd_rd_ptr <= cmd_rd_ptr + 1'b1;
        end 
        // W握手开始发数据
        else if (w_active && m_axi_wvalid && m_axi_wready) begin
            if (wdata_cnt == 0)
                w_active  <= 1'b0; // 当前burst传输完毕，回到上一判断条件，看是否还有传输请求
            else
                wdata_cnt <= wdata_cnt - 1'b1; 
        end
    end
end
 
// B响应（判断一次完整的burst是否结束）
assign m_axi_bready = 1'b1;                     
wire aw_shake = m_axi_awvalid && m_axi_awready; // 发出一个地址，AW握手
wire b_shake  = m_axi_bvalid  && m_axi_bready;  // 收回一个响应，B握手，一个地址事件结束
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
        // 类似fifo，AW握手为burst起点，B握手为终点
        if (aw_shake && !b_shake) 
            ost_cnt <= ost_cnt + 1'b1;
        else if (!aw_shake && b_shake) 
            ost_cnt <= ost_cnt - 1'b1;
    end
end
 
// done必须满足本次transaction全发完（remain==0）+所有burst事件都结束（B都响应）（ost_cnt==0）+W通道无数据传输
assign dma_is_busy = dma_running;
assign dma_is_done = dma_running && (remain_len == 0) && (ost_cnt == 0) && !w_active;
 
endmodule