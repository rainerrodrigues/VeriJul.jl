// Moving-average filter with AXI-Stream style interfaces.
// Every input sample produces one output: the average of that sample and
// the three before it, rounded down. The output is registered, and the
// filter stops accepting input while an output waits for m_axis_tready.
module stream_filter (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] s_axis_tdata,
    input  wire       s_axis_tvalid,
    output wire       s_axis_tready,
    output reg  [7:0] m_axis_tdata,
    output reg        m_axis_tvalid,
    input  wire       m_axis_tready
);
    reg  [7:0] h1, h2, h3;                       // the three previous samples
    /* verilator lint_off UNUSEDSIGNAL */      // dividing by 4 drops the low two bits
    wire [9:0] sum = {2'b00, s_axis_tdata} + {2'b00, h1} + {2'b00, h2} + {2'b00, h3};
    /* verilator lint_on UNUSEDSIGNAL */

    // Room for a new output when the register is empty or being emptied
    assign s_axis_tready = !m_axis_tvalid || m_axis_tready;
    wire take = s_axis_tvalid && s_axis_tready;

    always @(posedge clk) begin
        if (rst) begin
            {h1, h2, h3}  <= 24'd0;
            m_axis_tdata  <= 8'd0;
            m_axis_tvalid <= 1'b0;
        end else begin
            if (take) begin
                {h1, h2, h3}  <= {s_axis_tdata, h1, h2};
                m_axis_tdata  <= sum[9:2];
                m_axis_tvalid <= 1'b1;
            end else if (m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
            end
        end
    end
endmodule
