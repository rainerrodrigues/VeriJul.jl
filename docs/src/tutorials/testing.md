```@meta
CurrentModule = VeriJul
```

# Testing with Test.jl

VeriJul testbenches are ordinary Julia code, so the standard `Test`
library works with them. Inside [`@testbench`](@ref) tasks it also knows
about simulated time:

- `@test` inside a testbench records into the `@testset` the testbench was
  launched from, so its results appear in the normal test summary.
- A failing `@test` says *when* in the simulation it failed: the simulation
  time, the cycle and the testbench.
- A testbench that throws fails with a [`TestbenchError`](@ref) that says
  the same.

This tutorial tests the GCD unit from [Waiting for events](@ref).

```@example test
using VeriJul, Test, Random

dut = load_dut(joinpath(pkgdir(VeriJul), "examples", "gcd.v"), "gcd"; build_dir=mktempdir())
sim = Simulator(dut)
start_clock!(sim)
reset!(sim)
nothing # hide
```

## `@test` inside testbenches

A driver testbench sends random pairs to the design, and a checker
testbench compares every answer with Julia's own `gcd`. They talk through a
`Channel`, so the checker knows which inputs each answer belongs to:

```@example test
@testbench function driver(sim, jobs, n)
    for _ in 1:n
        a, b = rand(1:500), rand(1:500)
        put!(jobs, (a, b))
        sim.dut.a = a
        sim.dut.b = b
        sim.dut.start = 1
        @tick sim
        sim.dut.start = 0
        @wait_until sim sim.dut.done == 1 max_cycles=5000
    end
    close(jobs)
end

@testbench function checker(sim, jobs)
    for (a, b) in jobs
        wait_edge(sim, :done; max_cycles=5000)
        @test sim.dut.result == gcd(a, b)
    end
end
nothing # hide
```

`@testbench` launchers pass extra arguments on to the function. Launch them
inside a `@testset` and `wait` for them there:

```@example test
Random.seed!(42)
jobs = Channel{Tuple{Int,Int}}(Inf)
@testset "gcd matches Base.gcd" begin
    d = launch_driver(sim, jobs, 50)
    c = launch_checker(sim, jobs)
    wait(d)
    wait(c)
end
nothing # hide
```

All 50 checks are counted in the `@testset`, even though they ran in a
separate task.

## What a failure looks like

When a check inside a testbench fails, Test prints the usual report with a
`Context` line that tells you where to look in the waveform:

```text
gcd matches Base.gcd: Test Failed at test/runtests.jl:24
  Expression: sim.dut.result == gcd(a, b)
   Evaluated: 0x0004 == 5
     Context: simulation time 180, cycle 19, testbench `checker`
```

With [`enable_trace!`](@ref) on, jump to time 180 in the VCD file.

## A testbench that throws

If a testbench throws, for example when a `max_cycles` limit runs out,
`wait` and `fetch` throw a `TaskFailedException` that wraps a
[`TestbenchError`](@ref). Inside a `@testset` that counts as an error, and
the message names the testbench and the simulation time. You can also look
at the fields:

```@example test
@testbench function never_started(sim)
    @tick sim                                       # let the last `done` pulse end
    @wait_until sim sim.dut.done == 1 max_cycles=20
end

err = try
    wait(launch_never_started(sim))
catch e
    e
end
tb = err.task.exception
(tb.testbench, tb.time, tb.cycle, typeof(tb.error))
```

The message of the original error is kept:

```@example test
sprint(showerror, tb.error)
```

A testbench that waits for a failed child testbench passes the child's
`TestbenchError` on unchanged, so the report always points at the
testbench where things went wrong.

## Organizing a test suite

A `test/runtests.jl` for a design usually builds the design once and runs a
fresh simulator per test set:

```julia
using VeriJul, Test

const SRC = joinpath(@__DIR__, "..", "rtl", "gcd.v")

function with_sim(f)
    dut = load_dut(SRC, "gcd")          # cached after the first build
    sim = Simulator(dut)
    start_clock!(sim)
    reset!(sim)
    try
        f(sim)
    finally
        stop_clock!(sim)
        destroy!(dut)
    end
end

@testset "gcd" begin
    @testset "small numbers" begin
        with_sim() do sim
            wait(launch_checker(sim, ...))
        end
    end
    @testset "random numbers" begin
        # ...
    end
end
```

Things to keep in mind:

- Launch testbenches from inside the `@testset` they belong to. On Julia
  1.10–1.12, a task started with plain `@async` doesn't know the
  surrounding test set, so testbenches launched from it record their
  results outside it.
- Always `wait` (or `fetch`) the testbenches you launch. Otherwise an error
  in one of them goes unnoticed and the test set ends before they finish.
- A `@testset` *inside* a testbench works, but failures recorded in it
  don't get the simulation context.
- Give every wait a `max_cycles` (or `timeout`), so a stuck design fails the
  test instead of hanging it.

```@example test
stop_clock!(sim) # hide
destroy!(dut) # hide
nothing # hide
```

Next: [Build options and multiple clocks](@ref).
