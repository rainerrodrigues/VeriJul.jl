# Drive the AXI-Stream filter in examples/stream_filter.v with random data,
# gaps and backpressure, and check it against a reference model.
# Run with:  julia --project=. examples/stream_filter_demo.jl
using VeriJul, Random

dut = load_dut(joinpath(@__DIR__, "stream_filter.v"), "stream_filter"; build_dir=mktempdir())
sim = Simulator(dut)
start_clock!(sim)
reset!(sim)

s_axis = StreamBus(data=:s_axis_tdata, valid=:s_axis_tvalid, ready=:s_axis_tready)
m_axis = StreamBus(data=:m_axis_tdata, valid=:m_axis_tvalid, ready=:m_axis_tready)

# Reference model: the average of each sample and the three before it
moving_average(x) = [UInt8(sum(Int, [zeros(UInt8, 3); x][i:i+3]) ÷ 4) for i in eachindex(x)]

rng = Xoshiro(test_seed())
data = rand(rng, UInt8, 1000)
sb = expect!(Scoreboard("stream_filter"; sim), moving_average(data)...)
mon = StreamMonitor(sim, m_axis; on_item = x -> observe!(sb, x))

@testbench source(sim, d, rng) = send!(sim, s_axis, d; idle=0.3, rng)
@testbench sink(sim, n, rng) = receive!(sim, m_axis, n; ready=0.6, rng)
s = launch_source(sim, data, rng)
k = launch_sink(sim, length(data), rng)
wait(s); wait(k)
stop!(mon)

show(stdout, MIME"text/plain"(), sb); println()
println(passed(sb) ? "PASS" : "FAIL", " after ", sim.cycle, " cycles")

stop_clock!(sim)
destroy!(dut)
