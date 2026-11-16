# Changelog

## v0.2.0

- `@wait_until sim cond` and `wait_until(cond, sim)` wait until a condition
  holds, checking after every rising edge (or the `edge` of another
  `clock`), and return the number of edges waited.
- `wait_edge(sim, :port; edge=:rising)` waits for a rising or falling edge
  of a 1-bit port, or `edge=:change` for any change of a port of any width,
  and returns the new value.
- `max_cycles` on these throws a `WaitTimeout` that names what was awaited
  and the simulation time; `timeout` gives a wall-clock limit.
- `sim.cycle` counts rising edges of the main clock.
- `@test` inside `@testbench` tasks records into the `@testset` they were
  launched from, and failures carry a `Context:` line with the simulation
  time, cycle and testbench name.
- A testbench that throws now fails with a `TestbenchError` (inside the
  usual `TaskFailedException`) that says which testbench failed and when;
  the original exception is in its `error` field. **Breaking:** code that
  inspected `err.task.exception` directly must look at
  `err.task.exception.error`.
- `launch_<name>(sim, args...; kwargs...)` passes extra arguments on to the
  testbench function.
- Verification components for valid/ready (AXI-Stream style) interfaces:
  `StreamBus`, `send!` (with random idle cycles), `receive!` (with random
  backpressure) and `StreamMonitor`, plus a `Scoreboard` (`expect!`,
  `observe!`, `passed`) that reports mismatches with their simulation time.
- Internal signals: `load_dut(...; internals=true)` builds with Verilator's
  VPI, and `signals(dut)`, `signal(dut, "u_core.state")` (read with `sig[]`,
  write with `sig[] = v`) and `dut["name"]` access any signal in the
  hierarchy.
- Functional coverage: `CoverGroup` with bins given as ranges, collections,
  predicates or values, crosses, `sample!`, `coverage`, `uncovered`,
  `bins`, and a coverage report. `test_seed()` logs a random seed (or takes
  it from `VERIJUL_SEED`) so random tests can be reproduced.
- New `examples/gcd.v` and `examples/fifo.v`, and five tutorials: "Waiting
  for events", "Testing with Test.jl", "Streams and scoreboards",
  "Internal signals" and "Random stimulus and coverage".
- `Test` and `Random` are now dependencies (both are standard libraries).

## v0.1.0

First release.

- `load_dut(sources, top; ...)` builds and loads a Verilog design with
  Verilator and returns a `DUT` whose ports are properties:
  `dut.in_data = 0x42`, `dut.out_data`. Ports of any width are supported;
  ports wider than 64 bits are `BigInt`s. Any number of designs can be loaded
  at once.
- Build options: multiple source files, `include_dirs`, `defines`,
  `parameters`, `verilator_args`, `force`, `verbose`.
- Build caching. By default builds go into VeriJul's own scratch space, so
  nothing is written to the working directory; a `build_dir` you pass is
  only emptied if VeriJul created it. `clear_build_cache()` removes cached
  builds.
- Lockstep simulation: simulated time only advances while the testbench is
  waiting in `tick`, so printing, sleeping or other I/O between ticks never
  skips an edge. The clock also waits for every task launched with
  `@testbench`.
- `Simulator` with multiple clocks on one timeline (`add_clock!`),
  `tick`/`@tick sim n` with `clock`, `edge` and `timeout` options, and
  `reset!`. Waiting testbenches get `ClockStopped` or `TickTimeout` errors
  instead of hanging.
- `@testbench`, `settle!`, VCD waveforms with `enable_trace!`.
- A lower-level API: `build_dut`, the generated `AutoBindings` module, and
  `VerilatedModel`.
- `VERIJUL_VERILATOR` and `CXX` choose the Verilator and C++ compiler
  executables.
- Documentation with four tutorials, and runnable examples.
