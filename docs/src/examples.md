```@meta
CurrentModule = VeriJul
```

# Examples

Complete designs with testbenches, all in the
[`examples/`](https://github.com/rainerrodrigues/VeriJul.jl/tree/main/examples)
folder. Each Verilog file is small and commented, and each script runs with
`julia --project=. examples/<name>.jl`.

| Design | Shows | Script / tutorial |
|:--|:--|:--|
| [`uart_tx.v`](https://github.com/rainerrodrigues/VeriJul.jl/blob/main/examples/uart_tx.v) | a serial protocol, decoded by a receiver written in Julia | `uart_demo.jl`, below |
| [`stream_filter.v`](https://github.com/rainerrodrigues/VeriJul.jl/blob/main/examples/stream_filter.v) | AXI-Stream interfaces, backpressure, a reference model | `stream_filter_demo.jl`, below |
| [`fifo.v`](https://github.com/rainerrodrigues/VeriJul.jl/blob/main/examples/fifo.v) | valid/ready streams, internal signals, coverage | [Streams and scoreboards](@ref), [Internal signals](@ref) |
| [`gcd.v`](https://github.com/rainerrodrigues/VeriJul.jl/blob/main/examples/gcd.v) | variable latency, random stimulus, coverage | [Waiting for events](@ref), [Random stimulus and coverage](@ref) |
| [`filter.v`](https://github.com/rainerrodrigues/VeriJul.jl/blob/main/examples/filter.v) | the basics: ports, clocks, waveforms | `filter_demo.jl`, [Getting started](@ref) |
| [`counter/`](https://github.com/rainerrodrigues/VeriJul.jl/tree/main/examples/counter) | multiple files, includes, parameters, two clocks, wide ports | `counter_demo.jl`, [Build options and multiple clocks](@ref) |

## A UART transmitter

[`uart_tx.v`](https://github.com/rainerrodrigues/VeriJul.jl/blob/main/examples/uart_tx.v)
takes bytes through a valid/ready handshake and sends each one on a single
wire, `tx`: a start bit (0), eight data bits starting with the lowest, and a
stop bit (1), each held for `CLKS_PER_BIT` clock cycles.

The testbench needs a UART *receiver* to read `tx` back. In Julia that is a
short function: wait for the start bit, move to the middle of it, then
sample each following bit in its middle.

```@example uart
using VeriJul

const CLKS_PER_BIT = 4
dut = load_dut(joinpath(pkgdir(VeriJul), "examples", "uart_tx.v"), "uart_tx";
               parameters=Dict("CLKS_PER_BIT" => CLKS_PER_BIT), build_dir=mktempdir())
sim = Simulator(dut)
start_clock!(sim)
reset!(sim)

function receive_byte(sim)
    wait_edge(sim, :tx; edge=:falling, max_cycles=1000)   # the start bit begins
    tick(sim, CLKS_PER_BIT ÷ 2)                          # middle of the start bit
    byte = 0x00
    for i in 0:7
        tick(sim, CLKS_PER_BIT)
        byte |= UInt8(sim.dut.tx) << i
    end
    tick(sim, CLKS_PER_BIT)                              # stop bit
    return byte
end
nothing # hide
```

A sender testbench feeds the transmitter while a receiver testbench decodes
the line. Start the receiver first: launched one after the other at the
REPL, the sender could otherwise begin a byte before anyone is listening.

```@example uart
message = "Hello from Verilog!"
@testbench sender(sim, bytes) = send!(sim, StreamBus(data=:data, valid=:valid, ready=:ready), bytes)
@testbench receiver(sim, n) = String([receive_byte(sim) for _ in 1:n])

r = launch_receiver(sim, ncodeunits(message))
s = launch_sender(sim, codeunits(message))
wait(s)
fetch(r)
```

```@example uart
stop_clock!(sim) # hide
destroy!(dut) # hide
nothing # hide
```

The test suite runs all 256 byte values through it.

## An AXI-Stream filter

[`stream_filter.v`](https://github.com/rainerrodrigues/VeriJul.jl/blob/main/examples/stream_filter.v)
is a moving-average filter with AXI-Stream interfaces: each input sample
produces one output, the average of that sample and the three before it.
The output is registered, and the filter stops accepting input while an
output waits, so it has to handle backpressure correctly.

The check is a reference model in two lines of Julia and a
[`Scoreboard`](@ref), fed by a [`StreamMonitor`](@ref), while random gaps and
backpressure exercise the handshakes:

```@example filter
using VeriJul, Random

dut = load_dut(joinpath(pkgdir(VeriJul), "examples", "stream_filter.v"), "stream_filter";
               build_dir=mktempdir())
sim = Simulator(dut)
start_clock!(sim)
reset!(sim)

s_axis = StreamBus(data=:s_axis_tdata, valid=:s_axis_tvalid, ready=:s_axis_tready)
m_axis = StreamBus(data=:m_axis_tdata, valid=:m_axis_tvalid, ready=:m_axis_tready)

moving_average(x) = [UInt8(sum(Int, [zeros(UInt8, 3); x][i:i+3]) ÷ 4) for i in eachindex(x)]

rng = Xoshiro(1)
data = rand(rng, UInt8, 500)
sb = expect!(Scoreboard("stream_filter"; sim), moving_average(data)...)
mon = StreamMonitor(sim, m_axis; on_item = x -> observe!(sb, x))

@testbench source(sim, d, rng) = send!(sim, s_axis, d; idle=0.3, rng)
@testbench sink(sim, n, rng) = receive!(sim, m_axis, n; ready=0.5, rng)
s = launch_source(sim, data, rng)
k = launch_sink(sim, length(data), rng)
wait(s); wait(k)
stop!(mon)
sb
```

```@example filter
stop_clock!(sim) # hide
destroy!(dut) # hide
nothing # hide
```
