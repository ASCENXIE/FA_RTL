`timescale 1ns / 1ps
 
module tb_dma_top();
 
    // ==========================================
    // 1. 全局信号与参数
    // ==========================================
    parameter DATA_WIDTH = 32;
    parameter STRB_WIDTH = DATA_WIDTH / 8; // 32-bit 为 4
 
    reg pclk;
    reg presetn;
    reg aclk;
    reg aresetn;
 
    // ==========================================
    // 2. APB 接口信号
    // ==========================================
    reg  [31:0] paddr;
    reg         psel;
    reg         penable;
    reg         pwrite;
    reg  [31:0] pwdata;
    wire [31:0] prdata;
    wire        pready;
 
    // ==========================================
    // 3. AXI Read 接口信号
    // ==========================================
    wire [31:0] m_axi_araddr;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire [1:0]  m_axi_arburst;
    wire        m_axi_arvalid;
    reg         m_axi_arready;
    wire [31:0] m_axi_rdata;
    wire        m_axi_rlast;
    wire        m_axi_rvalid;
    wire        m_axi_rready;
 
    // ==========================================
    // 4. AXI Write 接口信号
    // ==========================================
    wire [31:0] m_axi_awaddr;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire        m_axi_awvalid;
    reg         m_axi_awready;
    wire [31:0] m_axi_wdata;
    wire [3:0]  m_axi_wstrb;
    wire        m_axi_wlast;
    wire        m_axi_wvalid;
    reg         m_axi_wready;
    reg  [1:0]  m_axi_bresp;
    wire        m_axi_bvalid;
    wire        m_axi_bready;
 
    wire        dma_irq;
 
    // ==========================================
    // 5. 实例化 DMA Top
    // ==========================================
    dma_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .STRB_WIDTH(STRB_WIDTH)
    ) u_dma_top (
        .pclk         (pclk),
        .presetn      (presetn),
        .aclk         (aclk),
        .aresetn      (aresetn),
 
        .paddr        (paddr),        .psel         (psel),
        .penable      (penable),      .pwrite       (pwrite),
        .pwdata       (pwdata),       .prdata       (prdata),
        .pready       (pready),       .dma_irq      (dma_irq),
 
        .m_axi_araddr (m_axi_araddr), .m_axi_arlen  (m_axi_arlen),
        .m_axi_arsize (m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),
        .m_axi_rdata  (m_axi_rdata),  .m_axi_rlast  (m_axi_rlast),
        .m_axi_rvalid (m_axi_rvalid), .m_axi_rready (m_axi_rready),
 
        .m_axi_awaddr (m_axi_awaddr), .m_axi_awlen  (m_axi_awlen),
        .m_axi_awsize (m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),
        .m_axi_wdata  (m_axi_wdata),  .m_axi_wstrb  (m_axi_wstrb),
        .m_axi_wlast  (m_axi_wlast),  .m_axi_wvalid (m_axi_wvalid),
        .m_axi_wready (m_axi_wready), .m_axi_bresp  (m_axi_bresp),
        .m_axi_bvalid (m_axi_bvalid), .m_axi_bready (m_axi_bready)
    );
 
    // ==========================================
    // 6. 异构时钟生成 (25M APB, 100M AXI)
    // ==========================================
    initial begin pclk = 0; forever #20 pclk = ~pclk; end
    initial begin aclk = 0; forever #5 aclk = ~aclk; end
 
    // ==========================================
    // ? 7. 智能虚拟 RAM (支持 Outstanding 与 INCR/FIXED)
    // ==========================================
    reg [31:0] ram [0:8191]; // 32KB 内存空间
    integer i;
 
    initial begin
        // 清空全盘
        for(i=0; i<8192; i=i+1) ram[i] = 32'h0;
        // 在源地址 (0x1000) 埋下 100 个规律测试数据
        // 比如数据为: 0xAABB0000, 0xAABB0001 ...
        for(i=0; i<100; i=i+1) begin
            ram[(32'h1000 >> 2) + i] = 32'hAABB_0000 + i;
        end
    end
 
    // --- RAM AXI Read Slave (带 30 拍延迟与 FIFO) ---
    always @(posedge aclk) m_axi_arready <= 1'b1;
 
    reg [41:0] slv_ar_fifo [0:15]; // {arburst[1:0], arlen[7:0], araddr[31:0]}
    reg [3:0] slv_ar_wr_ptr = 0, slv_ar_rd_ptr = 0;
 
    always @(posedge aclk) begin
        if (m_axi_arvalid && m_axi_arready) begin
            slv_ar_fifo[slv_ar_wr_ptr] <= {m_axi_arburst, m_axi_arlen, m_axi_araddr};
            slv_ar_wr_ptr <= slv_ar_wr_ptr + 1'b1;
        end
    end
 
    reg        slv_r_active = 0;
    reg [31:0] cur_r_addr;
    reg [7:0]  cur_r_len;
    reg [1:0]  cur_r_burst;
    reg [7:0]  slv_r_delay = 0;
 
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            slv_r_active <= 0;
            slv_r_delay  <= 0;
        end else begin
            if (!slv_r_active && (slv_ar_wr_ptr != slv_ar_rd_ptr)) begin
                if (slv_r_delay < 30) slv_r_delay <= slv_r_delay + 1; // 延迟掩盖测试
                else begin
                    slv_r_active <= 1;
                    cur_r_addr   <= slv_ar_fifo[slv_ar_rd_ptr][31:0];
                    cur_r_len    <= slv_ar_fifo[slv_ar_rd_ptr][39:32];
                    cur_r_burst  <= slv_ar_fifo[slv_ar_rd_ptr][41:40];
                    slv_ar_rd_ptr <= slv_ar_rd_ptr + 1;
                    slv_r_delay  <= 0;
                end
            end else if (slv_r_active && m_axi_rready && m_axi_rvalid) begin
                if (cur_r_len == 0) slv_r_active <= 0;
                else begin
                    cur_r_len <= cur_r_len - 1;
                    if (cur_r_burst == 2'b01) cur_r_addr <= cur_r_addr + STRB_WIDTH; // INCR
                end
            end
        end
    end
    assign m_axi_rvalid = slv_r_active;
    assign m_axi_rlast  = slv_r_active && (cur_r_len == 0);
    assign m_axi_rdata  = ram[cur_r_addr >> 2]; // 实时映射出当前地址的 RAM 数据
 
    // --- RAM AXI Write Slave (吸收 AW 连发) ---
    always @(posedge aclk) m_axi_awready <= 1'b1;
    always @(posedge aclk) m_axi_wready  <= 1'b1;
 
    reg [41:0] slv_aw_fifo [0:15];
    reg [3:0] slv_aw_wr_ptr = 0, slv_aw_rd_ptr = 0;
 
    always @(posedge aclk) begin
        if (m_axi_awvalid && m_axi_awready) begin
            slv_aw_fifo[slv_aw_wr_ptr] <= {m_axi_awburst, m_axi_awlen, m_axi_awaddr};
            slv_aw_wr_ptr <= slv_aw_wr_ptr + 1'b1;
        end
    end
 
    reg        slv_w_active = 0;
    reg [31:0] cur_w_addr;
    reg [1:0]  cur_w_burst;
 
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) slv_w_active <= 0;
        else begin
            if (!slv_w_active && (slv_aw_wr_ptr != slv_aw_rd_ptr)) begin
                slv_w_active <= 1;
                cur_w_addr   <= slv_aw_fifo[slv_aw_rd_ptr][31:0];
                cur_w_burst  <= slv_aw_fifo[slv_aw_rd_ptr][41:40];
                slv_aw_rd_ptr <= slv_aw_rd_ptr + 1;
            end else if (slv_w_active && m_axi_wvalid && m_axi_wready) begin
                ram[cur_w_addr >> 2] <= m_axi_wdata; // 真金白银写进 RAM 数组！
                if (cur_w_burst == 2'b01) cur_w_addr <= cur_w_addr + STRB_WIDTH; // INCR
                if (m_axi_wlast) slv_w_active <= 0;
            end
        end
    end
 
    // 延迟 30 拍的 B 响应
    reg [31:0] b_delay_pipe;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin b_delay_pipe <= 0; m_axi_bresp <= 2'b00; end 
        else b_delay_pipe <= {b_delay_pipe[30:0], (m_axi_wvalid && m_axi_wready && m_axi_wlast)};
    end
    assign m_axi_bvalid = b_delay_pipe[31];
 
    // ==========================================
    // 8. APB Task (精简版)
    // ==========================================
    task apb_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge pclk); paddr <= addr; pwdata <= data; pwrite <= 1; psel <= 1; penable <= 0;
            @(posedge pclk); penable <= 1;
            wait(pready); @(posedge pclk); psel <= 0; penable <= 0;
            $display("[%0t] APB 写入: Addr=0x%h, Data=0x%h", $time, addr, data);
        end
    endtask
    task apb_read(input [31:0] addr, output [31:0] data);
        begin
            @(posedge pclk); paddr <= addr; pwrite <= 0; psel <= 1; penable <= 0;
            @(posedge pclk); penable <= 1;
            wait(pready); data = prdata; @(posedge pclk); psel <= 0; penable <= 0;
            $display("[%0t] APB 读出: Addr=0x%h, Data=0x%h", $time, addr, data);
        end
    endtask
 
    // ==========================================
    // ? 9. 主舞台：发起挑战与数据校验
    // ==========================================
    reg [31:0] read_data;
    integer err_cnt;
 
    initial begin
        presetn = 0; aresetn = 0; paddr = 0; psel = 0; penable = 0; pwrite = 0; pwdata = 0;
        #100; presetn = 1; aresetn = 1; #100;
 
        $display("\n=======================================================");
        $display("[%0t] 准备就绪：全链路 Outstanding 数据搬运测试", $time);
        $display("=======================================================");
 
        // 搬运 82 个数据 (328 字节)
        apb_write(32'h08, 32'h0000_1000); // SRC: 0x1000_0000
        apb_write(32'h10, 32'h0000_2000); // DST: 0x2000_0000
        apb_write(32'h0C, 32'd328);       // LEN: 328 Bytes (82 个 32-bit 字)
        
        apb_write(32'h00, 32'h0000_0001); // 启动 DMA！(默认 INCR 模式)
 
        wait(dma_irq == 1'b1);
        $display("[%0t] 收到 DMA_IRQ 中断！DMA 搬运彻底完成！", $time);
        apb_read(32'h04, read_data); // 清除中断
 
        // ==========================================
        // ? 终极审判：内存数据对比
        // ==========================================
        $display("\n=======================================================");
        $display("开始自动校验 RAM 目标区域的数据完整性...");
        $display("=======================================================");
        err_cnt = 0;
 
        // 打印前 3 个和最后 2 个数据展示一下
        $display("源头数据 (0x1000): %h, %h, %h ... %h, %h", 
            ram[32'h1000>>2], ram[(32'h1000>>2)+1], ram[(32'h1000>>2)+2], ram[(32'h1000>>2)+80], ram[(32'h1000>>2)+81]);
        $display("目标数据 (0x2000): %h, %h, %h ... %h, %h", 
            ram[32'h2000>>2], ram[(32'h2000>>2)+1], ram[(32'h2000>>2)+2], ram[(32'h2000>>2)+80], ram[(32'h2000>>2)+81]);
 
        // 循环校验 82 个数据
        for (i = 0; i < 82; i = i + 1) begin
            if (ram[(32'h2000 >> 2) + i] !== ram[(32'h1000 >> 2) + i]) begin
                $display("校验失败！地址偏移 0x%h 处数据不匹配！", i*4);
                $display("期望: %h, 实际: %h", ram[(32'h1000 >> 2) + i], ram[(32'h2000 >> 2) + i]);
                err_cnt = err_cnt + 1;
            end
        end
 
        // 校验是否越界污染了第 83 个数据 (应该是 0)
        if (ram[(32'h2000 >> 2) + 82] !== 32'h0) begin
            $display("越界污染失败！写到了不该写的地方！");
            err_cnt = err_cnt + 1;
        end
        if (err_cnt == 0) begin
            $display("恭喜！82 个字全部校验通过，数据丝毫不差！");
            $display("Outstanding 交叉握手防错逻辑完美无瑕！\n");
        end else begin
            $display("测试失败！共发现 %0d 处错误，请查看波形定位问题。\n", err_cnt);
        end
 
        #200;
        $finish;
    end
 
endmodule