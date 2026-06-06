`timescale 1ns / 1ps
module dual_port_ram #(
    parameter FIFO_DEPTH = 16,
    parameter DATA_WIDTH = 16
    )(
    // port a
    input  wire clk_a,
    input  wire en_a,
    input  wire [$clog2(FIFO_DEPTH)-1:0] addr_a,
    input  wire [DATA_WIDTH-1:0] data_in,
    // port b
    input  wire clk_b,
    input  wire en_b,
    input  wire [$clog2(FIFO_DEPTH)-1:0] addr_b,
    output wire  [DATA_WIDTH-1:0] data_out
    );
    
reg [DATA_WIDTH-1:0] mem[FIFO_DEPTH-1:0];
 
always @(posedge clk_a) begin
    if (en_a)
        mem[addr_a] <= data_in;
end
    
assign data_out = mem[addr_b];
 
endmodule