```@meta
CurrentModule = VeriJul
```

# Streams and scoreboards

Most designs talk through standard interfaces, and the most common one is a
*valid/ready stream* (the handshake used by AXI-Stream): the sender raises
`valid` when it has a word, the receiver raises `ready` when it can take
one, and the word moves on a rising clock edge when both are high. Writing
the driver for that by hand in every testbench is tedious and easy to get
subtly wrong, so VeriJul has components for it:

- [`StreamBus`](@ref) names the ports of one interface.
- [`send!`](@ref) drives words into the design, waiting for `ready`.
- [`receive!`](@ref) takes words out, driving `ready`.
- [`StreamMonitor`](@ref) passively records every word that moves.
- [`Scoreboard`](@ref) checks that the right words come out, in order.

This tutorial tests
[`examples/fifo.v`](https://github.com/rainerrodrigues/VeriJul.jl/blob/main/examples/fifo.v),
a 4-word FIFO with a stream on each side.

```@example streams
using VeriJul, Test, Random

dut = load_dut(joinpath(pkgdir(VeriJul), "examples", "fifo.v"), "fifo"; build_dir=mktempdir())
sim = Simulator(dut)
start_clock!(sim)
reset!(sim)
dut
```

## Describing the interfaces

A `StreamBus` just names the ports. Interfaces without backpressure leave
out `ready`.

```@example streams
inp = StreamBus(data=:s_data, valid=:s_valid, ready=:s_ready)
out = StreamBus(data=:m_data, valid=:m_valid, ready=:m_ready)
nothing # hide
```

## Sending and receiving

`send!` returns once the design has accepted every word, and `receive!`
returns the words once it has `n` of them:

```@example streams
send!(sim, inp, [0x11, 0x22, 0x33])
receive!(sim, out, 3)
```

The FIFO holds four words. With nobody reading, a fifth word is never
accepted. `max_cycles` turns that into an error instead of a hang:

```@example streams
send!(sim, inp, [0x01, 0x02, 0x03, 0x04])
try
    send!(sim, inp, [0x05]; max_cycles=10)
catch err
    sprint(showerror, err)
end
```

```@example streams
receive!(sim, out, 4)
```

## Gaps and backpressure

A design that works when data arrives every cycle can still break when it
doesn't. `send!` inserts idle cycles with probability `idle`, and
`receive!` only raises `ready` with probability `ready`, so the design
sees irregular traffic and full and empty states. Both take an `rng`, so
the traffic can be reproduced (see [Random stimulus and coverage](@ref)).

Sender and receiver run at the same time, so start them as
[`@testbench`](@ref) tasks:

```@example streams
@testbench tx(sim, data, rng) = send!(sim, inp, data; idle=0.3, rng)
@testbench rx(sim, n, rng) = receive!(sim, out, n; ready=0.4, rng)

rng = Xoshiro(1)
data = rand(rng, UInt8, 50)
t = launch_tx(sim, data, rng)
r = launch_rx(sim, length(data), rng)
wait(t)
fetch(r) == data
```

## Monitors and scoreboards

In bigger testbenches, the code that drives a design and the code that
checks it are kept apart. A `StreamMonitor` watches an interface without
driving it, and calls `on_item` for every word that moves. Connecting it
to a `Scoreboard` checks the output against what you expect:

```@example streams
sb = Scoreboard("fifo"; sim)
expect!(sb, data...)                        # a FIFO returns its input in order
mon = StreamMonitor(sim, out; on_item = x -> observe!(sb, x))

t = launch_tx(sim, data, rng)
r = launch_rx(sim, length(data), rng)
wait(t); wait(r)
stop!(mon)
sb
```

Use `@test passed(sb)` in a test. When something goes wrong, showing the
scoreboard lists the mismatches with their simulation time:

```@example streams
bad = Scoreboard("demo"; sim)
expect!(bad, 1, 2, 3)
observe!(bad, 1); observe!(bad, 7)
bad
```

`Scoreboard(; compare = (expected, got) -> ...)` changes what counts as a
match, for example to allow rounding errors.

## How the timing works

All stream components look at the handshake at the falling edge just
before each rising edge. By then the inputs set after the previous rising
edge have been evaluated, so they see exactly the values the design sees
at the edge. Words move at rising edges as usual. Change a bus's inputs
only between a rising edge and the next falling edge (which is what
happens when your testbench code runs right after `@tick`), and the
components will agree with the design about which words moved.

For an interface on another clock, pass `StreamBus(...; clock=:clk_b)`.

```@example streams
stop_clock!(sim) # hide
destroy!(dut) # hide
nothing # hide
```

Next: [Internal signals](@ref).
