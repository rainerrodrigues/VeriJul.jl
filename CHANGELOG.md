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
- `run!(sim, n) do cycle ... end` runs cycles directly in the calling task,
  without the clock task: about 20× faster than ticking, for simple
  stimulus loops.
- A testbench that throws now stops the clock (unless the simulator was
  created with `stop_on_error=false`): every task waiting on it, including
  the main task, gets the same `TestbenchError`, and later waits report it
  too, so nothing hangs and the failure always reaches the caller.
- Waveforms: `trace=:fst` builds write FST files, much smaller than VCD.
  `WaveRecorder` keeps the last N cycles of chosen ports and internal
  signals in memory and writes a VCD file when a check inside a testbench
  fails or a testbench throws; `save_waves` writes it on demand.
- Faster scheduling: the lockstep checks no longer allocate, and every wait
  notifies the clock, including `wait(sim.rising_edge)` (now an
  `EdgeEvent`, which also reports a stopped clock instead of hanging). The
  clock only falls back to checking periodically while a testbench is busy.
  20–30% more cycles per second with tasks; `benchmark/scheduler.jl` runs
  in CI.
- Port reads are type-stable: `DUT` keeps its ports in a `NamedTuple` of
  typed handles, so `f(dut) = dut.count` infers `UInt8`.
- PrecompileTools: the first simulation in a session starts about 5× faster.
- **Breaking:** the generated `AutoBindings` Julia module is gone, and
  `build_dut` returns just the library path. Load it with the new
  `DUT(lib_path, top)`. `generate_bindings` returns only the C++ code.
- Removed fallbacks for libraries built by pre-0.1 development versions.
- Examples: `uart_tx.v` (with a UART receiver written in Julia) and
  `stream_filter.v` (AXI-Stream with backpressure), demo scripts, and an
  Examples page in the docs. New "Waveforms" tutorial and "Performance"
  guide; the lower-level guide is rewritten.
- The SimCore lockstep scheduler lives in its own file, with its own tests,
  and the wide-value conversions have property-based tests.
- Windows is documented as unsupported (use WSL2).
- `Test`, `Random` and `PrecompileTools` are now dependencies.

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
