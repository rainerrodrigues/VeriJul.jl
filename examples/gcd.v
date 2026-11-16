// Greatest common divisor by repeated subtraction (Euclid's algorithm).
// Pulse `start` with `a` and `b` set; `busy` is high while it works, and
// `done` pulses for one cycle when `result` is ready. The number of cycles
// depends on the inputs, so a testbench has to wait for `done` rather than
// count cycles.
module gcd (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg         busy,
    output reg         done,
    output reg  [15:0] result
);
    reg [15:0] x, y;

    always @(posedge clk) begin
        if (rst) begin
            busy   <= 1'b0;
            done   <= 1'b0;
            result <= 16'd0;
            x      <= 16'd0;
            y      <= 16'd0;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                if (start) begin
                    x    <= a;
                    y    <= b;
                    busy <= 1'b1;
                end
            end else if (y == 16'd0) begin
                result <= x;
                busy   <= 1'b0;
                done   <= 1'b1;
            end else if (x >= y) begin
                x <= x - y;
            end else begin
                x <= y;            // swap so that x >= y
                y <= x;
            end
        end
    end
endmodule
