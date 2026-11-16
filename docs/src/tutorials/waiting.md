```@meta
CurrentModule = VeriJul
```

# Waiting for events

[`@tick`](@ref) waits a fixed number of clock cycles. That's enough for the
filter, which always answers one cycle later, but many designs take as long
as they take: a divider, a bus that inserts wait states, a state machine
waiting for input. A testbench for them has to wait for something to
*happen*, not for a number of cycles.

This tutorial uses
[`examples/gcd.v`](https://github.com/rainerrodrigues/VeriJul.jl/blob/main/examples/gcd.v),
which computes the greatest common divisor of two numbers by repeated
subtraction. You pulse `start`; `busy` is high while it works, and `done`
pulses for one cycle when `result` is ready. How long that takes depends on
the numbers.

```@example wait
using VeriJul

dut = load_dut(joinpath(pkgdir(VeriJul), "examples", "gcd.v"), "gcd"; build_dir=mktempdir())
sim = Simulator(dut)
start_clock!(sim)
reset!(sim)
dut
```

A small helper starts a computation:

```@example wait
function start!(sim, a, b)
    sim.dut.a = a
    sim.dut.b = b
    sim.dut.start = 1
    @tick sim
    sim.dut.start = 0
end
nothing # hide
```

## Waiting for a condition

[`@wait_until`](@ref) checks a condition now and after every rising edge,
and returns once it is true. Its result is the number of edges it waited:

```@example wait
start!(sim, 48, 18)
cycles = @wait_until sim dut.done == 1
(cycles, dut.result)
```

Different inputs take a different number of cycles, which is why counting
cycles with `@tick` wouldn't work here:

```@example wait
start!(sim, 1000, 3)
cycles = @wait_until sim dut.done == 1
(cycles, dut.result)
```

The condition can be any Julia expression, for example
`@wait_until sim dut.busy == 0 && dut.result != 0`. If it is already true,
`@wait_until` returns `0` without waiting.

## Always set a limit

If the design never gets there, because of a bug or a missing `start`, an
unbounded wait hangs the test. Pass `max_cycles` and a
[`WaitTimeout`](@ref) is thrown instead. Its message quotes the condition
and says when it gave up:

```@example wait
@tick sim                                           # let the last `done` pulse end
try
    @wait_until sim dut.done == 1 max_cycles=50     # nothing was started
catch err
    sprint(showerror, err)
end
```

`timeout` is also available, as a wall-clock limit in seconds, the same as
for [`tick`](@ref).

## Waiting for a signal edge

[`wait_edge`](@ref) waits for a port to change. For 1-bit ports, `edge` is
`:rising` (the default) or `:falling`; `:change` works for ports of any
width. It returns the port's new value:

```@example wait
start!(sim, 12, 8)
wait_edge(sim, :busy; edge=:falling, max_cycles=100)
(dut.done, dut.result)
```

`sim.cycle` counts rising edges of the main clock, so it can measure how
long something takes:

```@example wait
dut.a = 255; dut.b = 15; dut.start = 1
wait_edge(sim, :busy)                  # the design accepted the request
dut.start = 0
c0 = sim.cycle
wait_edge(sim, :done; max_cycles=1000)
(latency = sim.cycle - c0, result = dut.result)
```

`wait_edge` samples the port after every evaluation of the design, that is
after each edge of any clock, which is when outputs change.

## The function form

[`wait_until`](@ref) is the function behind `@wait_until`. It takes the
condition as a function, which reads well as a `do` block when the
condition is longer than one line. It also takes `clock` and `edge`, so it
can check on another clock's edges:

```@example wait
start!(sim, 81, 27)
wait_until(sim; max_cycles=100) do
    dut.done == 1 && dut.result > 0
end
dut.result
```

## Which one to use

| To wait for… | Use |
|:--|:--|
| a fixed number of cycles | `@tick sim n` |
| a condition on one or more signals | `@wait_until sim cond max_cycles=…` |
| one signal to rise, fall or change | `wait_edge(sim, :port; edge=…)` |
| a condition that spans several lines | `wait_until(sim; max_cycles=…) do … end` |

All of them work inside [`@testbench`](@ref) tasks, and the clock waits for
them in lockstep like it does for `@tick`.

```@example wait
stop_clock!(sim) # hide
destroy!(dut) # hide
nothing # hide
```

Next: [Testing with Test.jl](@ref).
