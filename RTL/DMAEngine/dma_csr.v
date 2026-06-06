`timescale 1ns / 1ps
module dma_csr(
    input  wire        pclk,    // APB 时钟
    input  wire        presetn, // APB 复位
    // APB Slave 接口 (连接 CPU 的 APB Bridge)
    input  wire [31:0] paddr,   // 地址
    input  wire        psel,    // 片选
    input  wire        penable, // 使能 
    input  wire        pwrite,  // 1: 写, 0: 读
    input  wire [31:0] pwdata,  // 写数据
    output wire [31:0] prdata,  // 读数据
    output wire        pready,  // Slave 准备好 (简单寄存器直接给 1 即可)
    // 内部用户接口 (输出给 DMA 读写AXI干活用的信号)
    output wire        dma_start,     // 启动脉冲
    output wire [31:0] dma_src_addr,  // 源地址
    output wire [31:0] dma_xfer_len,  // 传输长度，多少个字节，最大4GByte
    output wire [31:0] dma_dst_addr,
    output wire        src_fixed,     // 1: 源地址固定, 0: 源地址递增 read
    output wire        dst_fixed,     // 1: 目的地址固定, 0: 目的地址递增 write
    
    // 读写AXI干完活后，反馈给 CSR 的状态信号
    input  wire        dma_is_busy,   // 引擎正在搬运 (1: 忙碌)
    input  wire        dma_is_done,   // 引擎搬运完成脉冲 (用于置位状态寄存器)
    
    // 硬件中断输出线
    output wire        dma_irq
);
    
// 1. 定义内部寄存器
reg [31:0] ctrl_reg;  // 0x00: 控制寄存器 [bit0: start]
reg [31:0] state_reg; // 0x04: 状态寄存器 [bit0: busy, bit1: done] read only
reg [31:0] src_addr;  // 0x08: 源地址寄存器
reg [31:0] total_len; // 0x0C: 传输长度寄存器
reg [31:0] dst_addr;  // 0x10: 写目标地址寄存器
 
// 2. APB 读写使能
wire apb_write_en = psel &&  penable &&  pwrite;
wire apb_read_en  = psel && ~penable && ~pwrite;
 
// APB write
always @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
        ctrl_reg  <= 32'b0;
        src_addr  <= 32'b0;
        total_len <= 32'b0;
        dst_addr  <= 32'b0;
    end 
    else if (apb_write_en) begin
        case (paddr[7:0])
            8'h00: ctrl_reg  <= pwdata;
            8'h08: src_addr  <= pwdata;
            8'h0C: total_len <= pwdata;
            8'h10: dst_addr  <= pwdata;
        endcase
    end 
    else if (ctrl_reg[0] == 1'b1)  // 让 start 信号变成一个单周期脉冲（自动清零），防止 DMA 一直被重复启动
        ctrl_reg[0] <= 1'b0; 
end
 
// APB read
reg [31:0] rdata_reg;
always @(posedge pclk or negedge presetn) begin
    if (!presetn)
        rdata_reg  <= 32'b0;
    else if (apb_read_en) begin
        // 读地址解码
        case (paddr[7:0])
            8'h00: rdata_reg <= ctrl_reg;
            8'h04: rdata_reg <= state_reg; // CPU 读取硬件真实状态
            8'h08: rdata_reg <= src_addr;
            8'h0C: rdata_reg <= total_len;
            8'h10: rdata_reg <= dst_addr;
            default: rdata_reg <= 32'b0;
        endcase
    end
end
 
// 3. 硬件状态机反馈逻辑 (硬件更新 state_reg)
always @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
        state_reg <= 32'b0;
    end 
    else begin
        // bit 0 反映内部引擎是否忙碌，ctrl_reg[0]使得bit 0与dma_is_busy同步拉高
        state_reg[0] <= ctrl_reg[0] || dma_is_busy; 
        // bit 1 反映是否完成。如果硬件发来 done 脉冲，则置 1
        if (dma_is_done)
            state_reg[1] <= 1'b1;
        // 如果 CPU 读了一次状态寄存器，可以设计为自动清零 done 标志 (清除中断)
        else if (apb_read_en && paddr[7:0] == 8'h04) 
            state_reg[1] <= 1'b0; 
    end
end
 
// apb output
assign prdata = rdata_reg;
assign pready = 1'b1;
// dma output
assign dma_start    = ctrl_reg[0];
assign src_fixed    = ctrl_reg[1]; 
assign dst_fixed    = ctrl_reg[2];
assign dma_src_addr = src_addr;
assign dma_xfer_len = total_len;
assign dma_dst_addr = dst_addr;
 
assign dma_irq      = state_reg[1];
 
endmodule