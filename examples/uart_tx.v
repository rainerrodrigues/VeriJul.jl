// UART transmitter, 8 data bits, no parity, 1 stop bit (8N1).
// Hand it a byte with a valid/ready handshake; `tx` idles high, then sends a
// start bit (0), the 8 data bits LSB first and a stop bit (1), each held for
// CLKS_PER_BIT clock cycles.
module uart_tx #(parameter CLKS_PER_BIT = 4) (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       valid,
    output wire       ready,
    output reg        tx
);
    localparam CW = $clog2(CLKS_PER_BIT);

    reg [8:0]    frame;     // the bits still to send after the current one: data, then stop
    reg [3:0]    bits_left; // bits still to send, including the current one
    reg [CW-1:0] clks;      // cycles left in the current bit

    assign ready = bits_left == 4'd0;

    always @(posedge clk) begin
        if (rst) begin
            tx        <= 1'b1;
            bits_left <= 4'd0;
            clks      <= {CW{1'b0}};
            frame     <= 9'h1ff;
        end else if (ready) begin
            if (valid) begin
                frame     <= {1'b1, data};
                tx        <= 1'b0;                    // start bit
                bits_left <= 4'd10;
                clks      <= CW'(CLKS_PER_BIT - 1);
            end
        end else if (clks != {CW{1'b0}}) begin
            clks <= clks - 1'b1;
        end else begin
            // Next bit: data bits LSB first, then the stop bit; idle high after it
            bits_left <= bits_left - 4'd1;
            tx        <= bits_left == 4'd1 ? 1'b1 : frame[0];
            frame     <= {1'b1, frame[8:1]};
            clks      <= CW'(CLKS_PER_BIT - 1);
        end
    end
endmodule
