```@meta
CurrentModule = VeriJul
```

# Internal signals

Ports are what a design shows the outside world, but when you're debugging,
or checking that a design does the right thing for the right reason, you
often want to see inside it: the state of a state machine, a counter, a
pointer. Load the design with `internals=true` and every signal in the
hierarchy can be read and written by its name.

```@example internals
using VeriJul

dut = load_dut(joinpath(pkgdir(VeriJul), "examples", "fifo.v"), "fifo";
               internals=true, build_dir=mktempdir())
sim = Simulator(dut)
start_clock!(sim)
reset!(sim)
nothing # hide
```

`internals=true` makes Verilator keep every signal accessible (it passes
`--vpi --public-flat-rw`). That makes the model slower and the build
bigger, so it is off by default. Turn it on for the test runs that need
it.

## Finding signals

[`signals`](@ref) lists the hierarchical names, relative to the top
module. Signals in submodules look like `"u_core.state"`.

```@example internals
signals(dut)
```

## Reading

`dut["name"]` reads a signal once. For a signal you read often, get a
[`Signal`](@ref) handle with [`signal`](@ref) and read it with `sig[]`,
since looking up the name is the slow part:

```@example internals
inp = StreamBus(data=:s_data, valid=:s_valid, ready=:s_ready)
count = signal(dut, "count")

send!(sim, inp, [0xA1, 0xA2, 0xA3])
(count[], dut["wr_ptr"], dut["rd_ptr"])
```

Values have the same types as ports: `UInt8` up to `UInt64`, and `BigInt`
for signals wider than 64 bits.

A natural use is checking an invariant on every cycle, here that the FIFO
never claims to hold more than four words:

```@example internals
using Test

@testbench function occupancy_check(sim, count, n)
    for _ in 1:n
        @tick sim
        @test count[] <= 4
        @test (sim.dut.s_ready == 0) == (count[] == 4)
    end
end

out = StreamBus(data=:m_data, valid=:m_valid, ready=:m_ready)
@testbench tx(sim, data) = send!(sim, inp, data)
@testbench rx(sim, n) = receive!(sim, out, n; ready=0.3)   # a slow reader: the FIFO fills up

@testset "occupancy" begin
    c = launch_occupancy_check(sim, count, 40)
    t = launch_tx(sim, 1:8)
    r = launch_rx(sim, 11)            # the three from before and the eight new ones
    wait(t); wait(r); wait(c)
end
nothing # hide
```

## Writing

Writing a signal *deposits* a value: it stays until the design's own logic
assigns that signal again. For a register, that's usually the next clock
edge. That's handy for putting a design straight into a state that would
take many cycles to reach:

```@example internals
dut["count"] = 2        # pretend two words are stored
settle!(dut)            # update the logic that depends on it
(dut.m_valid, count[])
```

Without `settle!`, outputs that depend on the signal only update at the
next clock edge. Parameters and constants can't be written.

```@example internals
reset!(sim)
count[]
```

```@example internals
stop_clock!(sim) # hide
destroy!(dut) # hide
nothing # hide
```

Next: [Random stimulus and coverage](@ref).
