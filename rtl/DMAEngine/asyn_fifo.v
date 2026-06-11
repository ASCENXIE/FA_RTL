`timescale 1ns / 1ps
module asyn_fifo #(
    parameter FIFO_DEPTH = 16,
    parameter DATA_WIDTH = 16
) (
    input wire clk_wr,
    input wire en_wr,
    input wire [DATA_WIDTH-1:0] data_in,

    input wire clk_rd,
    input wire en_rd,
    output wire [DATA_WIDTH-1:0] data_out,

    input wire rst_n,

    //    output wire almost_full,
    output wire full,
    //    output wire almost_empty,
    output wire empty
);

  wire wren = en_wr && !full;
  wire rden = en_rd && !empty;
  wire [$clog2(FIFO_DEPTH):0] ptr_wr_gray;
  wire [$clog2(FIFO_DEPTH):0] ptr_rd_gray;
  wire [$clog2(FIFO_DEPTH)-1:0] addr_wr;
  wire [$clog2(FIFO_DEPTH)-1:0] addr_rd;

  reg [$clog2(FIFO_DEPTH):0] ptr_wr;
  reg [$clog2(FIFO_DEPTH):0] ptr_rd;
  reg [$clog2(FIFO_DEPTH):0] ptr_wr_gray_rdd1;  // sync in rd clk
  reg [$clog2(FIFO_DEPTH):0] ptr_wr_gray_rdd2;
  reg [$clog2(FIFO_DEPTH):0] ptr_rd_gray_wrd1;  // sync in wr clk
  reg [$clog2(FIFO_DEPTH):0] ptr_rd_gray_wrd2;

  //assign ptr_wr_gray = {ptr_wr[$clog2(FIFO_DEPTH)],ptr_wr[$clog2(FIFO_DEPTH):1]^ptr_wr[$clog2(FIFO_DEPTH)-1:0]};
  //assign ptr_rd_gray = {ptr_rd[$clog2(FIFO_DEPTH)],ptr_rd[$clog2(FIFO_DEPTH):1]^ptr_rd[$clog2(FIFO_DEPTH)-1:0]};
  assign ptr_wr_gray = ((ptr_wr >> 1) ^ ptr_wr);
  assign ptr_rd_gray = ((ptr_rd >> 1) ^ ptr_rd);
  assign addr_wr     = ptr_wr[$clog2(FIFO_DEPTH)-1:0];
  assign addr_rd     = ptr_rd[$clog2(FIFO_DEPTH)-1:0];

  // addr change
  always @(posedge clk_wr or negedge rst_n) begin
    if (!rst_n) ptr_wr <= {($clog2(FIFO_DEPTH) + 1) {1'b0}};
    else if (wren) ptr_wr <= ptr_wr + 1'b1;
  end

  always @(posedge clk_rd or negedge rst_n) begin
    if (!rst_n) ptr_rd <= {($clog2(FIFO_DEPTH) + 1) {1'b0}};
    else if (rden) ptr_rd <= ptr_rd + 1'b1;
  end

  // gray ptr sync
  always @(posedge clk_wr or negedge rst_n) begin
    if (!rst_n) begin
      ptr_rd_gray_wrd1 <= {($clog2(FIFO_DEPTH) + 1) {1'b0}};
      ptr_rd_gray_wrd2 <= {($clog2(FIFO_DEPTH) + 1) {1'b0}};
    end else begin
      ptr_rd_gray_wrd1 <= ptr_rd_gray;
      ptr_rd_gray_wrd2 <= ptr_rd_gray_wrd1;
    end
  end

  always @(posedge clk_rd or negedge rst_n) begin
    if (!rst_n) begin
      ptr_wr_gray_rdd1 <= {($clog2(FIFO_DEPTH) + 1) {1'b0}};
      ptr_wr_gray_rdd2 <= {($clog2(FIFO_DEPTH) + 1) {1'b0}};
    end else begin
      ptr_wr_gray_rdd1 <= ptr_wr_gray;
      ptr_wr_gray_rdd2 <= ptr_wr_gray_rdd1;
    end
  end

  assign full = ({~ptr_rd_gray_wrd2[$clog2(
      FIFO_DEPTH
  ):$clog2(
      FIFO_DEPTH
  )-1], ptr_rd_gray_wrd2[$clog2(
      FIFO_DEPTH
  )-2:0]} == ptr_wr_gray[$clog2(
      FIFO_DEPTH
  ):0]);
  assign empty = (ptr_wr_gray_rdd2 == ptr_rd_gray);

  dual_port_ram #(
      .FIFO_DEPTH(FIFO_DEPTH),
      .DATA_WIDTH(DATA_WIDTH)
  ) fifo_ram (
      .clk_a(clk_wr),
      .en_a(wren),
      .addr_a(addr_wr),
      .data_in(data_in),
      .clk_b(clk_rd),
      .en_b(rden),
      .addr_b(addr_rd),
      .data_out(data_out)
  );

endmodule

