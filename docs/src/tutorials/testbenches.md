```@meta
CurrentModule = VeriJul
```

# Self-checking testbenches

Printing values is fine for exploring, but tests should check themselves.
This tutorial drives the moving-average filter from [Getting started](@ref)
with random data and compares every output against a model written in Julia.

## A reference model

The filter outputs the average of the four samples taken *before* the
current edge, rounded down:

```@example tb
function reference(history)
    last4 = history[max(end - 4, 1):end-1]       # samples from the previous 4 edges
    return UInt8(sum(Int, last4; init=0) ÷ 4)
end
nothing # hide
```

## Comparing against the design

Each iteration sets an input, waits for the rising edge that samples it, and
checks the output. `@testset` and `@test` come from Julia's standard `Test`
library, so this runs unchanged under `Pkg.test()`.

```@example tb
using VeriJul, Test, Random

src = joinpath(pkgdir(VeriJul), "examples", "filter.v")
dut = load_dut(src, "filter"; build_dir=mktempdir())
sim = Simulator(dut)
start_clock!(sim)

# Flush the history with zeros so the design and the model agree
dut.in_data = 0
@tick sim 5

Random.seed!(1)
history = zeros(UInt8, 4)
@testset "filter matches reference" begin
    for _ in 1:200
        x = rand(UInt8)
        dut.in_data = x
        @tick sim
        push!(history, x)
        @test dut.out_data == reference(history)
    end
end
```

## Testbenches as tasks

[`@testbench`](@ref) defines a function and a `launch_<name>(sim)` that runs
it as a task. That's useful when several things should happen in parallel,
for example a driver and a monitor.

The clock waits for every launched testbench: no edge happens while any of
them is busy between two ticks, so both see every edge even if one of them
prints or sleeps. A testbench that has finished no longer holds the clock
back. Launch monitors and receivers before the drivers: at the REPL, each
line runs on its own, and a driver launched first may already be a few
cycles ahead when the next line launches the monitor. Tasks started with plain `@async` aren't waited for, so launch
concurrent testbenches with `@testbench`.

```@example tb
@testbench function driver(sim)
    for x in (0x40, 0x40, 0x40, 0x40, 0x00)
        sim.dut.in_data = x
        @tick sim
    end
end

@testbench function monitor(sim)
    seen = UInt8[]
    for _ in 1:8
        @tick sim
        push!(seen, sim.dut.out_data)
    end
    return seen
end

d = launch_driver(sim)
m = launch_monitor(sim)
wait(d)
fetch(m)
```

`fetch` returns the monitor's result once it finishes. If a task throws, the
error is rethrown by `wait`/`fetch`, wrapped in a [`TestbenchError`](@ref)
that says when it happened, so failures are never silently lost. A failing
testbench also stops the clock: every task still waiting on it, including
your main task, gets that same error instead of hanging. Create the
simulator with `Simulator(dut; stop_on_error=false)` to keep the clock
running instead. Extra
arguments to a launcher are passed on: `launch_driver(sim, data)` runs
`driver(sim, data)`. [Testing with Test.jl](@ref) shows how `@test` works
inside testbenches.

## Don't hang: timeouts and stopped clocks

A testbench waiting for an edge that never comes would hang forever. Two
things prevent that:

- `timeout` (wall-clock seconds) on [`tick`](@ref) or `@tick` throws a
  [`TickTimeout`](@ref).
- `max_cycles` on [`@wait_until`](@ref) and [`wait_edge`](@ref) throws a
  [`WaitTimeout`](@ref) when the design doesn't respond in time (see
  [Waiting for events](@ref)).
- [`stop_clock!`](@ref) wakes every waiting task with a
  [`ClockStopped`](@ref) error, and `tick` throws `ClockStopped` if the clock
  isn't running.

```@example tb
try
    @tick sim 10^9 timeout=0.5      # far more cycles than 0.5 s allows
catch err
    err
end
```

```@example tb
stop_clock!(sim)
try
    @tick sim
catch err
    err
end
```

```@example tb
destroy!(dut) # hide
nothing # hide
```

## Resetting a design

Designs with a reset input can use [`reset!`](@ref), which holds the reset
for a number of rising edges and then releases it:

```julia
reset!(sim)                                  # port :rst, active high, 2 cycles
reset!(sim, :rst_n; active_high=false, cycles=4)
```

The clock must be running. The next tutorial uses it.

Next: [Waiting for events](@ref).
