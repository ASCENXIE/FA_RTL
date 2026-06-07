`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Self-checking testbench for fa_axi_lite_regs_no_func.v
//
// Coverage intent:
//   1. Reset/default CSR values
//   2. Basic AXI-Lite write/read
//   3. AW/W same-cycle write
//   4. AW-before-W write
//   5. W-before-AW write
//   6. WSTRB byte-write behavior
//   7. CTRL pulse fields: START / SOFT_RESET
//   8. STATUS W1C pulse field: DONE_CLR
//   9. RO status/performance mapping
//  10. Undefined address read/write behavior
//
// Compile example:
//   vcs -full64 -sverilog fa_axi_lite_regs_no_func.v tb_fa_axi_lite_regs_no_func.v -l comp.log
//   ./simv -l sim.log
//
// Or with Icarus Verilog:
//   iverilog -g2012 -o simv fa_axi_lite_regs_no_func.v tb_fa_axi_lite_regs_no_func.v
//   vvp simv
// -----------------------------------------------------------------------------

module tb_fa_axi_lite_regs;

    // -------------------------------------------------------------------------
    // Register offsets
    // -------------------------------------------------------------------------
    localparam [31:0] ADDR_CTRL         = 32'h0000_0000;
    localparam [31:0] ADDR_STATUS       = 32'h0000_0004;
    localparam [31:0] ADDR_CFG          = 32'h0000_0008;
    localparam [31:0] ADDR_Q_BASE_L     = 32'h0000_0014;
    localparam [31:0] ADDR_Q_BASE_H     = 32'h0000_0018;
    localparam [31:0] ADDR_K_BASE_L     = 32'h0000_001C;
    localparam [31:0] ADDR_K_BASE_H     = 32'h0000_0020;
    localparam [31:0] ADDR_V_BASE_L     = 32'h0000_0024;
    localparam [31:0] ADDR_V_BASE_H     = 32'h0000_0028;
    localparam [31:0] ADDR_O_BASE_L     = 32'h0000_002C;
    localparam [31:0] ADDR_O_BASE_H     = 32'h0000_0030;
    localparam [31:0] ADDR_STRIDE_BYTES = 32'h0000_0034;
    localparam [31:0] ADDR_NEG_LARGE    = 32'h0000_0038;
    localparam [31:0] ADDR_SCALE        = 32'h0000_003C;
    localparam [31:0] ADDR_CYCLES       = 32'h0000_0040;
    localparam [31:0] ADDR_UNDEFINED    = 32'h0000_00FC;

    localparam [31:0] RESET_STRIDE_BYTES = 32'h0000_0080;
    localparam [31:0] RESET_NEG_LARGE    = 32'hFFFF_8000;
    localparam [31:0] RESET_SCALE        = 32'h0000_0020;

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    reg clk;
    reg rst_n;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // AXI-Lite signals
    // -------------------------------------------------------------------------
    reg  [31:0] s_axil_awaddr;
    reg         s_axil_awvalid;
    wire        s_axil_awready;

    reg  [31:0] s_axil_wdata;
    reg  [3:0]  s_axil_wstrb;
    reg         s_axil_wvalid;
    wire        s_axil_wready;

    wire [1:0]  s_axil_bresp;
    wire        s_axil_bvalid;
    reg         s_axil_bready;

    reg  [31:0] s_axil_araddr;
    reg         s_axil_arvalid;
    wire        s_axil_arready;

    wire [31:0] s_axil_rdata;
    wire [1:0]  s_axil_rresp;
    wire        s_axil_rvalid;
    reg         s_axil_rready;

    // -------------------------------------------------------------------------
    // Hardware-side signals
    // -------------------------------------------------------------------------
    wire        ctrl_start_pulse;
    wire        ctrl_soft_reset;
    wire        ctrl_done_clr;
    wire        ctrl_irq_en;
    wire        ctrl_causal_en;

    wire [63:0] cfg_q_base;
    wire [63:0] cfg_k_base;
    wire [63:0] cfg_v_base;
    wire [63:0] cfg_o_base;
    wire [31:0] cfg_stride_bytes;
    wire [31:0] cfg_neg_large;
    wire [31:0] cfg_scale;

    reg         status_busy;
    reg         status_done;
    reg         status_error;
    reg  [31:0] perf_cycles;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    fa_axi_lite_regs #(
        .ADDR_WIDTH         (32),
        .HEAD_DIM           (64),
        .ELEM_BYTES         (2),
        .RESET_STRIDE_BYTES (RESET_STRIDE_BYTES),
        .RESET_NEG_LARGE    (RESET_NEG_LARGE),
        .RESET_SCALE        (RESET_SCALE)
    ) u_dut (
        .clk                (clk),
        .rst_n              (rst_n),

        .s_axil_awaddr      (s_axil_awaddr),
        .s_axil_awvalid     (s_axil_awvalid),
        .s_axil_awready     (s_axil_awready),

        .s_axil_wdata       (s_axil_wdata),
        .s_axil_wstrb       (s_axil_wstrb),
        .s_axil_wvalid      (s_axil_wvalid),
        .s_axil_wready      (s_axil_wready),

        .s_axil_bresp       (s_axil_bresp),
        .s_axil_bvalid      (s_axil_bvalid),
        .s_axil_bready      (s_axil_bready),

        .s_axil_araddr      (s_axil_araddr),
        .s_axil_arvalid     (s_axil_arvalid),
        .s_axil_arready     (s_axil_arready),

        .s_axil_rdata       (s_axil_rdata),
        .s_axil_rresp       (s_axil_rresp),
        .s_axil_rvalid      (s_axil_rvalid),
        .s_axil_rready      (s_axil_rready),

        .ctrl_start_pulse   (ctrl_start_pulse),
        .ctrl_soft_reset    (ctrl_soft_reset),
        .ctrl_done_clr      (ctrl_done_clr),
        .ctrl_irq_en        (ctrl_irq_en),
        .ctrl_causal_en     (ctrl_causal_en),

        .cfg_q_base         (cfg_q_base),
        .cfg_k_base         (cfg_k_base),
        .cfg_v_base         (cfg_v_base),
        .cfg_o_base         (cfg_o_base),
        .cfg_stride_bytes   (cfg_stride_bytes),
        .cfg_neg_large      (cfg_neg_large),
        .cfg_scale          (cfg_scale),

        .status_busy        (status_busy),
        .status_done        (status_done),
        .status_error       (status_error),
        .perf_cycles        (perf_cycles)
    );

    // -------------------------------------------------------------------------
    // Test status counters
    // -------------------------------------------------------------------------
    integer test_count;
    integer error_count;
    integer start_pulse_count;
    integer soft_reset_count;
    integer done_clr_count;

    always @(posedge clk) begin
        #1;
        if (rst_n) begin
            if (ctrl_start_pulse) begin
                start_pulse_count = start_pulse_count + 1;
                $display("[%0t] INFO: ctrl_start_pulse asserted", $time);
            end

            if (ctrl_soft_reset) begin
                soft_reset_count = soft_reset_count + 1;
                $display("[%0t] INFO: ctrl_soft_reset asserted", $time);
            end

            if (ctrl_done_clr) begin
                done_clr_count = done_clr_count + 1;
                $display("[%0t] INFO: ctrl_done_clr asserted", $time);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Common check tasks
    // -------------------------------------------------------------------------
    task check32;
        input [1023:0] name;
        input [31:0]   got;
        input [31:0]   exp;
        begin
            test_count = test_count + 1;
            if (got !== exp) begin
                error_count = error_count + 1;
                $display("[%0t] FAIL: %0s got=0x%08h exp=0x%08h", $time, name, got, exp);
            end else begin
                $display("[%0t] PASS: %0s = 0x%08h", $time, name, got);
            end
        end
    endtask

    task check64;
        input [1023:0] name;
        input [63:0]   got;
        input [63:0]   exp;
        begin
            test_count = test_count + 1;
            if (got !== exp) begin
                error_count = error_count + 1;
                $display("[%0t] FAIL: %0s got=0x%016h exp=0x%016h", $time, name, got, exp);
            end else begin
                $display("[%0t] PASS: %0s = 0x%016h", $time, name, got);
            end
        end
    endtask

    task check1;
        input [1023:0] name;
        input          got;
        input          exp;
        begin
            test_count = test_count + 1;
            if (got !== exp) begin
                error_count = error_count + 1;
                $display("[%0t] FAIL: %0s got=%0b exp=%0b", $time, name, got, exp);
            end else begin
                $display("[%0t] PASS: %0s = %0b", $time, name, got);
            end
        end
    endtask

    task check_int;
        input [1023:0] name;
        input integer  got;
        input integer  exp;
        begin
            test_count = test_count + 1;
            if (got != exp) begin
                error_count = error_count + 1;
                $display("[%0t] FAIL: %0s got=%0d exp=%0d", $time, name, got, exp);
            end else begin
                $display("[%0t] PASS: %0s = %0d", $time, name, got);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // AXI-Lite master tasks
    // -------------------------------------------------------------------------
    task wait_bresp_okay;
        begin
            while (s_axil_bvalid !== 1'b1) begin
                @(posedge clk);
                #1;
            end

            check32("BRESP", {30'd0, s_axil_bresp}, 32'h0000_0000);

            @(negedge clk);
            s_axil_bready = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            s_axil_bready = 1'b0;
        end
    endtask

    task axil_write;
        input [31:0] addr;
        input [31:0] data;
        input [3:0]  strb;
        begin
            $display("[%0t] AXI WRITE same-cycle: addr=0x%08h data=0x%08h strb=0x%1h", $time, addr, data, strb);

            @(negedge clk);
            s_axil_awaddr  = addr;
            s_axil_awvalid = 1'b1;
            s_axil_wdata   = data;
            s_axil_wstrb   = strb;
            s_axil_wvalid  = 1'b1;

            @(posedge clk);
            @(negedge clk);
            s_axil_awvalid = 1'b0;
            s_axil_wvalid  = 1'b0;
            s_axil_awaddr  = 32'h0000_0000;
            s_axil_wdata   = 32'h0000_0000;
            s_axil_wstrb   = 4'h0;

            wait_bresp_okay();
        end
    endtask

    task axil_write_aw_first;
        input [31:0] addr;
        input [31:0] data;
        input [3:0]  strb;
        input integer gap_cycles;
        begin
            $display("[%0t] AXI WRITE AW-first: addr=0x%08h data=0x%08h strb=0x%1h gap=%0d", $time, addr, data, strb, gap_cycles);

            @(negedge clk);
            s_axil_awaddr  = addr;
            s_axil_awvalid = 1'b1;

            @(posedge clk);
            @(negedge clk);
            s_axil_awvalid = 1'b0;
            s_axil_awaddr  = 32'h0000_0000;

            repeat (gap_cycles) begin
                @(posedge clk);
            end

            @(negedge clk);
            s_axil_wdata  = data;
            s_axil_wstrb  = strb;
            s_axil_wvalid = 1'b1;

            @(posedge clk);
            @(negedge clk);
            s_axil_wvalid = 1'b0;
            s_axil_wdata  = 32'h0000_0000;
            s_axil_wstrb  = 4'h0;

            wait_bresp_okay();
        end
    endtask

    task axil_write_w_first;
        input [31:0] addr;
        input [31:0] data;
        input [3:0]  strb;
        input integer gap_cycles;
        begin
            $display("[%0t] AXI WRITE W-first: addr=0x%08h data=0x%08h strb=0x%1h gap=%0d", $time, addr, data, strb, gap_cycles);

            @(negedge clk);
            s_axil_wdata  = data;
            s_axil_wstrb  = strb;
            s_axil_wvalid = 1'b1;

            @(posedge clk);
            @(negedge clk);
            s_axil_wvalid = 1'b0;
            s_axil_wdata  = 32'h0000_0000;
            s_axil_wstrb  = 4'h0;

            repeat (gap_cycles) begin
                @(posedge clk);
            end

            @(negedge clk);
            s_axil_awaddr  = addr;
            s_axil_awvalid = 1'b1;

            @(posedge clk);
            @(negedge clk);
            s_axil_awvalid = 1'b0;
            s_axil_awaddr  = 32'h0000_0000;

            wait_bresp_okay();
        end
    endtask

    task axil_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            $display("[%0t] AXI READ : addr=0x%08h", $time, addr);

            @(negedge clk);
            s_axil_araddr  = addr;
            s_axil_arvalid = 1'b1;
            s_axil_rready  = 1'b0;

            @(posedge clk);
            @(negedge clk);
            s_axil_arvalid = 1'b0;
            s_axil_araddr  = 32'h0000_0000;

            while (s_axil_rvalid !== 1'b1) begin
                @(posedge clk);
                #1;
            end

            data = s_axil_rdata;
            check32("RRESP", {30'd0, s_axil_rresp}, 32'h0000_0000);

            @(negedge clk);
            s_axil_rready = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            s_axil_rready = 1'b0;
        end
    endtask

    task expect_read;
        input [1023:0] name;
        input [31:0]   addr;
        input [31:0]   exp;
        reg   [31:0]   rd;
        begin
            axil_read(addr, rd);
            check32(name, rd, exp);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    reg [31:0] rd_data;

    initial begin
        // $dumpfile("tb_fa_axi_lite_regs_no_func.vcd");
        // $dumpvars(0, tb_fa_axi_lite_regs_no_func);
        $fsdbDumpfile("tb_fa_axi_lite_regs.fsdb");
        $fsdbDumpvars(0, tb_fa_axi_lite_regs.u_dut);

        test_count        = 0;
        error_count       = 0;
        start_pulse_count = 0;
        soft_reset_count  = 0;
        done_clr_count    = 0;

        rst_n             = 1'b0;
        s_axil_awaddr     = 32'h0000_0000;
        s_axil_awvalid    = 1'b0;
        s_axil_wdata      = 32'h0000_0000;
        s_axil_wstrb      = 4'h0;
        s_axil_wvalid     = 1'b0;
        s_axil_bready     = 1'b0;
        s_axil_araddr     = 32'h0000_0000;
        s_axil_arvalid    = 1'b0;
        s_axil_rready     = 1'b0;
        status_busy       = 1'b0;
        status_done       = 1'b0;
        status_error      = 1'b0;
        perf_cycles       = 32'h0000_0000;

        repeat (5) begin
            @(posedge clk);
        end
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) begin
            @(posedge clk);
        end

        // ---------------------------------------------------------------------
        // 1. Reset/default values
        // ---------------------------------------------------------------------
        expect_read("CTRL reset",         ADDR_CTRL,         32'h0000_0000);
        expect_read("CFG reset",          ADDR_CFG,          32'h0000_0000);
        expect_read("Q_BASE_L reset",     ADDR_Q_BASE_L,     32'h0000_0000);
        expect_read("Q_BASE_H reset",     ADDR_Q_BASE_H,     32'h0000_0000);
        expect_read("STRIDE reset",       ADDR_STRIDE_BYTES, RESET_STRIDE_BYTES);
        expect_read("NEG_LARGE reset",    ADDR_NEG_LARGE,    RESET_NEG_LARGE);
        expect_read("SCALE reset",        ADDR_SCALE,        RESET_SCALE);
        check1("ctrl_irq_en reset",       ctrl_irq_en,       1'b0);
        check1("ctrl_causal_en reset",    ctrl_causal_en,    1'b0);

        // ---------------------------------------------------------------------
        // 2. Basic RW registers and output mapping
        // ---------------------------------------------------------------------
        axil_write(ADDR_CFG, 32'h0000_0001, 4'h1);
        expect_read("CFG causal_en", ADDR_CFG, 32'h0000_0001);
        check1("ctrl_causal_en", ctrl_causal_en, 1'b1);

        axil_write(ADDR_CTRL, 32'h0000_0004, 4'h1);
        expect_read("CTRL irq_en", ADDR_CTRL, 32'h0000_0004);
        check1("ctrl_irq_en", ctrl_irq_en, 1'b1);

        axil_write(ADDR_Q_BASE_L, 32'h89AB_CDEF, 4'hF);
        axil_write(ADDR_Q_BASE_H, 32'h0123_4567, 4'hF);
        expect_read("Q_BASE_L", ADDR_Q_BASE_L, 32'h89AB_CDEF);
        expect_read("Q_BASE_H", ADDR_Q_BASE_H, 32'h0123_4567);
        check64("cfg_q_base", cfg_q_base, 64'h0123_4567_89AB_CDEF);

        // ---------------------------------------------------------------------
        // 3. AW-before-W and W-before-AW writes
        // ---------------------------------------------------------------------
        axil_write_aw_first(ADDR_K_BASE_L, 32'hA5A5_5A5A, 4'hF, 3);
        expect_read("K_BASE_L AW-first", ADDR_K_BASE_L, 32'hA5A5_5A5A);

        axil_write_w_first(ADDR_K_BASE_H, 32'h1357_2468, 4'hF, 2);
        expect_read("K_BASE_H W-first", ADDR_K_BASE_H, 32'h1357_2468);
        check64("cfg_k_base", cfg_k_base, 64'h1357_2468_A5A5_5A5A);

        // ---------------------------------------------------------------------
        // 4. WSTRB byte update
        // Initial value: 0x11223344
        // Write data   : 0xAABBCCDD, WSTRB=0101 updates byte0 and byte2 only
        // Expected     : 0x11BB33DD
        // ---------------------------------------------------------------------
        axil_write(ADDR_V_BASE_L, 32'h1122_3344, 4'hF);
        axil_write(ADDR_V_BASE_L, 32'hAABB_CCDD, 4'b0101);
        expect_read("V_BASE_L WSTRB", ADDR_V_BASE_L, 32'h11BB_33DD);

        // ---------------------------------------------------------------------
        // 5. Other config registers
        // ---------------------------------------------------------------------
        axil_write(ADDR_O_BASE_L,     32'h0000_1000, 4'hF);
        axil_write(ADDR_O_BASE_H,     32'h0000_2000, 4'hF);
        axil_write(ADDR_STRIDE_BYTES, 32'h0000_0100, 4'hF);
        axil_write(ADDR_NEG_LARGE,    32'hFFFF_0000, 4'hF);
        axil_write(ADDR_SCALE,        32'h0000_0040, 4'hF);
        check64("cfg_o_base", cfg_o_base, 64'h0000_2000_0000_1000);
        check32("cfg_stride_bytes", cfg_stride_bytes, 32'h0000_0100);
        check32("cfg_neg_large", cfg_neg_large, 32'hFFFF_0000);
        check32("cfg_scale", cfg_scale, 32'h0000_0040);

        // ---------------------------------------------------------------------
        // 6. CTRL pulse fields
        // Note: In current RTL, writing CTRL byte updates IRQ_EN from WDATA[2].
        // Therefore START-only write 0x1 will also clear IRQ_EN.
        // ---------------------------------------------------------------------
        axil_write(ADDR_CTRL, 32'h0000_0001, 4'h1);
        repeat (2) @(posedge clk);
        check_int("start pulse count", start_pulse_count, 1);
        expect_read("CTRL after START-only write", ADDR_CTRL, 32'h0000_0000);
        check1("ctrl_irq_en after START-only write", ctrl_irq_en, 1'b0);

        axil_write(ADDR_CTRL, 32'h0000_0002, 4'h1);
        repeat (2) @(posedge clk);
        check_int("soft reset pulse count", soft_reset_count, 1);

        // Re-enable IRQ_EN with bit2.
        axil_write(ADDR_CTRL, 32'h0000_0004, 4'h1);
        check1("ctrl_irq_en re-enabled", ctrl_irq_en, 1'b1);

        // ---------------------------------------------------------------------
        // 7. STATUS and CYCLES external read mapping
        // ---------------------------------------------------------------------
        @(negedge clk);
        status_busy  = 1'b1;
        status_done  = 1'b1;
        status_error = 1'b1;
        perf_cycles  = 32'h1234_5678;
        expect_read("STATUS external mapping", ADDR_STATUS, 32'h0000_0007);
        expect_read("CYCLES external mapping", ADDR_CYCLES, 32'h1234_5678);

        axil_write(ADDR_STATUS, 32'h0000_0002, 4'h1);
        repeat (2) @(posedge clk);
        check_int("done clear pulse count", done_clr_count, 1);
        // STATUS itself is external-driven, so it remains 0x7 until status_done changes outside this block.
        expect_read("STATUS still external-driven", ADDR_STATUS, 32'h0000_0007);

        @(negedge clk);
        status_done = 1'b0;
        expect_read("STATUS after external done cleared", ADDR_STATUS, 32'h0000_0005);

        // Write to RO CYCLES should be ignored.
        axil_write(ADDR_CYCLES, 32'hDEAD_BEEF, 4'hF);
        expect_read("CYCLES ignores write", ADDR_CYCLES, 32'h1234_5678);

        // ---------------------------------------------------------------------
        // 8. Undefined address behavior
        // ---------------------------------------------------------------------
        expect_read("undefined addr read", ADDR_UNDEFINED, 32'h0000_0000);
        axil_write(ADDR_UNDEFINED, 32'hCAFE_BABE, 4'hF);
        expect_read("undefined addr read after write", ADDR_UNDEFINED, 32'h0000_0000);

        // ---------------------------------------------------------------------
        // Final result
        // ---------------------------------------------------------------------
        repeat (5) begin
            @(posedge clk);
        end

        $display("============================================================");
        $display("fa_axi_lite_regs_no_func basic CSR test finished");
        $display("TOTAL CHECKS = %0d", test_count);
        $display("ERRORS       = %0d", error_count);
        $display("============================================================");

        if (error_count == 0) begin
            $display("TEST PASS");
        end else begin
            $display("TEST FAIL");
        end

        $finish;
    end

endmodule
