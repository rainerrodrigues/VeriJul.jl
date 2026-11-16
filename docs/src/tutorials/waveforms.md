```@meta
CurrentModule = VeriJul
```

# Waveforms

A waveform shows every signal over time, and is usually the fastest way to
see why a design misbehaves. VeriJul can write waveforms in two ways:

- [`enable_trace!`](@ref) has Verilator record *every* signal for the whole
  run, as a VCD or FST file.
- A [`WaveRecorder`](@ref) keeps only the *last few cycles* of the signals
  you pick in memory, and writes them out when a check fails. Long runs get
  small, focused waveforms of exactly the moment things went wrong.

Open the files in [GTKWave](https://gtkwave.sourceforge.net/) or
[Surfer](https://surfer-project.org/).

## Full traces: VCD and FST

[Getting started](@ref) showed VCD tracing:

```julia
dut = load_dut("filter.v", "filter")
enable_trace!(dut, "filter.vcd")
```

VCD is plain text and gets big quickly: every change of every signal is a
line. FST stores the same information compressed, typically 10 to 50 times
smaller, and viewers open it faster. Choose it when building:

```julia
dut = load_dut("filter.v", "filter"; trace=:fst)
enable_trace!(dut, "filter.fst")
```

The format is fixed when the design is built, so `enable_trace!` refuses a
file name with the other extension rather than writing the wrong format.
FST needs the zlib development headers, and Verilator 5.032 or newer also
needs lz4's:

```bash
sudo apt-get install zlib1g-dev liblz4-dev   # Ubuntu / Debian
brew install lz4                             # macOS
```

## Just the moments before a failure

A full trace of a million-cycle run is huge, even as FST, and the
interesting part is usually the last few cycles before a check failed. A
`WaveRecorder` keeps a sliding window of the signals you choose:

```@example waves
using VeriJul, Test

dut = load_dut(joinpath(pkgdir(VeriJul), "examples", "gcd.v"), "gcd"; build_dir=mktempdir())
sim = Simulator(dut)
dir = mktempdir()
rec = WaveRecorder(sim; cycles=40, dir=dir)
start_clock!(sim)
reset!(sim)
nothing # hide
```

With `dir` set, the recorder writes a VCD file there by itself whenever a
`@test` inside a [`@testbench`](@ref) fails, or a testbench throws. Here a
deliberately wrong expectation triggers it:

```@example waves
@testbench function check_gcd(sim, a, b, expected)
    sim.dut.a = a; sim.dut.b = b; sim.dut.start = 1
    @tick sim
    sim.dut.start = 0
    @wait_until sim sim.dut.done == 1 max_cycles=1000
    @test sim.dut.result == expected
end

redirect_stdout(devnull) do # hide
try # hide
@testset "gcd" begin
    wait(launch_check_gcd(sim, 1071, 462, 21))     # right
    wait(launch_check_gcd(sim, 1071, 462, 7))      # wrong on purpose
end
catch # hide
end # hide
end # hide
readdir(dir)
```

The file holds just the last 40 cycles before the failure:

```@example waves
vcd = read(joinpath(dir, "failure_1.vcd"), String)
print(join(first(split(vcd, '\n'), 18), '\n'))
```

Options:

- `cycles`: how many cycles to keep.
- `signals`: what to record. By default, all ports. A list can mix port
  names (`:done`) and, for designs loaded with `internals=true`, internal
  signals (`"u_core.state"`; see [Internal signals](@ref)).
- `max_files`: at most this many failure files per run (default 5).

[`save_waves`](@ref) writes the current window at any time, for example
from your own error handling, and [`stop_recording!`](@ref) stops the
recorder. Recording costs a little time on every clock edge, so turn it on
for the tests that need it.

```@example waves
stop_clock!(sim) # hide
destroy!(dut) # hide
nothing # hide
```

Next: [Build options and multiple clocks](@ref).
