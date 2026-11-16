// A small FIFO with valid/ready handshakes (AXI-Stream style) on both sides.
// A word moves on a rising clock edge when its valid and ready are both high.
//  - input side:  s_data, s_valid (from the sender), s_ready (to the sender)
//  - output side: m_data, m_valid (to the receiver), m_ready (from the receiver)
// DEPTH must be a power of two. `count` (internal) is the number of words held.
module fifo #(parameter WIDTH = 8, parameter DEPTH = 4) (
    input  wire             clk,
    input  wire             rst,
    input  wire [WIDTH-1:0] s_data,
    input  wire             s_valid,
    output wire             s_ready,
    output wire [WIDTH-1:0] m_data,
    output wire             m_valid,
    input  wire             m_ready
);
    localparam AW = $clog2(DEPTH);

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW-1:0]    rd_ptr, wr_ptr;
    reg [AW:0]      count;

    wire push = s_valid && s_ready;
    wire pop  = m_valid && m_ready;

    assign s_ready = count != DEPTH[AW:0];
    assign m_valid = count != {(AW+1){1'b0}};
    assign m_data  = mem[rd_ptr];

    always @(posedge clk) begin
        if (rst) begin
            rd_ptr <= {AW{1'b0}};
            wr_ptr <= {AW{1'b0}};
            count  <= {(AW+1){1'b0}};
        end else begin
            if (push) begin
                mem[wr_ptr] <= s_data;
                wr_ptr      <= wr_ptr + {{(AW-1){1'b0}}, 1'b1};
            end
            if (pop)
                rd_ptr <= rd_ptr + {{(AW-1){1'b0}}, 1'b1};
            if (push && !pop)
                count <= count + {{AW{1'b0}}, 1'b1};
            else if (pop && !push)
                count <= count - {{AW{1'b0}}, 1'b1};
        end
    end
endmodule
