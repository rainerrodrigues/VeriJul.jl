```@meta
CurrentModule = VeriJul
```

# Performance

Most of a VeriJul simulation's time goes to switching between Julia tasks
on every clock edge, not to the Verilated model itself. That cost is what
makes concurrent testbenches easy to write, but simple stimulus loops don't
need it.

## Tasks or `run!`

[`tick`](@ref), [`@testbench`](@ref) and the waiting functions run the clock
in a background task, in lockstep with your testbench tasks. [`run!`](@ref)
instead drives the clocks directly in the calling task and calls a function
after every rising edge:

```julia
sim = Simulator(dut)          # no start_clock!
run!(sim, 100_000) do cycle
    dut.in_data = rand(UInt8)
    cycle > 4 && @assert dut.out_data <= 0xff
end
```

On a typical laptop, with a trivial design so that only VeriJul's own
overhead is measured (`benchmark/scheduler.jl`):

| Style | Cycles per second |
|:--|--:|
| `run!` | ~11 000 000 |
| `tick` from the main task | ~600 000 |
| one `@testbench` | ~570 000 |
| driver and monitor `@testbench`es | ~420 000 |
| `wait_edge` | ~370 000 |

Use `run!` for long, simple stimulus loops, and tasks when several things
must happen at the same time (a driver and a monitor, a sender and a
receiver). The two can be mixed: `run!` with the clock stopped, then
`start_clock!` for the concurrent part. CI runs the benchmark on every
change and shows the numbers in the job summary.

## Other costs

- **`internals=true`** builds with Verilator's VPI and keeps every signal
  accessible, which makes the model slower. Turn it on only where you read
  internal signals.
- **Tracing.** [`enable_trace!`](@ref) writes every signal on every edge.
  FST (`trace=:fst`) is smaller than VCD but costs compression time. A
  [`WaveRecorder`](@ref) reads its signals on every edge, so record only
  what you need.
- **Port reads are type-stable**, so in a function like
  `f(dut) = dut.count`, the compiler knows the result type. Work on ports
  inside functions rather than at global scope, as usual in Julia.
- **First run in a session.** VeriJul precompiles its simulation paths, so
  the first simulation starts in a fraction of a second. Building a design
  the first time takes longer (Verilator and the C++ compiler run), but
  builds are cached.
