# Measures the simulator's scheduling overhead with a mock design written in
# Julia (no Verilator), so only VeriJul's own cost is timed.
#   julia --project benchmark/scheduler.jl
using VeriJul
include(joinpath(@__DIR__, "..", "test", "mock.jl"))

const DUT_ = MockDesign.make_dut()        # building the mock is slow; do it once

# `f(sim, n)` runs n cycles; the simulator is set up outside the timing
function bench(label, n, f; clock=true)
    rates = map(1:3) do _
        sim = Simulator(DUT_)
        clock && start_clock!(sim)
        f(sim, 10)                         # compile and warm up
        t = @elapsed f(sim, n)
        clock && stop_clock!(sim)
        n / t
    end
    rate = maximum(rates)
    println(rpad(label, 40), lpad(round(Int, rate), 12), " cycles/s")
    return rate
end

n = parse(Int, get(ENV, "VERIJUL_BENCH_CYCLES", "50000"))

@testbench tb(sim, k) = for _ in 1:k; @tick sim; end
@testbench drv(sim, k) = for i in 1:k; sim.dut.step = i % 256; @tick sim; end
@testbench mon(sim, k) = for _ in 1:k; @tick sim; sim.dut.count; end

bench("run! (no tasks)", 10n, (sim, k) -> run!(c -> (sim.dut.step = c % 256), sim, k); clock=false)
bench("tick(sim, n) from the main task", n, (sim, k) -> tick(sim, k))
bench("@tick in a loop", n, (sim, k) -> for _ in 1:k; @tick sim; end)
bench("one @testbench", n, (sim, k) -> wait(launch_tb(sim, k)))
bench("driver + monitor testbenches", n, (sim, k) -> (d = launch_drv(sim, k); m = launch_mon(sim, k); wait(d); wait(m)))
bench("wait_edge(:clk)", n ÷ 2, (sim, k) -> for _ in 1:k; wait_edge(sim, :clk); end)
