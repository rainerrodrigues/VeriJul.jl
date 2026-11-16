module Components

using Random: AbstractRNG, default_rng
using ..Device: DUT
using ..SimCore: SimCore, Simulator, tick, launch, find_clock, ClockStopped, WaitTimeout

export StreamBus, send!, receive!, StreamMonitor, stop!, Scoreboard, expect!, observe!, passed

# ---------------------------------------------------------------------------
# Valid/ready streams

"""
    StreamBus(; data, valid, ready=nothing, clock=nothing)

Names the ports of one valid/ready (AXI-Stream style) interface: a word
moves on a rising clock edge when `valid` and `ready` are both high.
`ready=nothing` means the interface has no backpressure (always ready).
`clock` is the clock the interface belongs to (the main clock by default).

```julia
inp = StreamBus(data=:s_data, valid=:s_valid, ready=:s_ready)
out = StreamBus(data=:m_data, valid=:m_valid, ready=:m_ready)
```

Use it with [`send!`](@ref VeriJul.Components.send!),
[`receive!`](@ref VeriJul.Components.receive!) and
[`StreamMonitor`](@ref VeriJul.Components.StreamMonitor). They all sample
the handshake at the falling edge before each rising edge, when the inputs
set after the previous rising edge have settled, so they see exactly the
values the design sees at the edge.
"""
struct StreamBus
    data::Symbol
    valid::Symbol
    ready::Union{Symbol,Nothing}
    clock::Union{Symbol,Nothing}
end
StreamBus(; data::Symbol, valid::Symbol, ready::Union{Symbol,Nothing}=nothing,
          clock::Union{Symbol,Nothing}=nothing) = StreamBus(data, valid, ready, clock)

the_dut(sim::Simulator) = sim.dut isa DUT ? sim.dut :
    error("Stream components need a Simulator built from a DUT (see load_dut)")

# Make sure the next edge of the bus clock is a falling one, so inputs set
# now are seen at the coming rising edge.
function align(sim::Simulator, bus::StreamBus)
    find_clock(sim, bus.clock).value == 0x00 && tick(sim; clock=bus.clock)
    return nothing
end

handshake(dut, bus) = getproperty(dut, bus.valid) == 1 &&
                      (bus.ready === nothing || getproperty(dut, bus.ready) == 1)

"""
    send!(sim, bus, items; idle=0.0, rng=Random.default_rng(), max_cycles=nothing)

Drives `items` into the design through `bus`, one word per handshake, and
returns once the last one is accepted. Holds each word with `valid` high
until the design is ready, and leaves `valid` low afterwards.

`idle` is the probability of inserting an idle cycle (valid low) before
each word, to test that the design copes with gaps. `max_cycles` limits how
long one word may wait for `ready`; then a
[`WaitTimeout`](@ref VeriJul.SimCore.WaitTimeout) is thrown.

Call it from a [`@testbench`](@ref VeriJul.DSL.@testbench) task (or the
main task) while the clock runs.
"""
function send!(sim::Simulator, bus::StreamBus, items; idle::Real=0.0,
               rng::AbstractRNG=default_rng(), max_cycles::Union{Integer,Nothing}=nothing)
    dut = the_dut(sim)
    align(sim, bus)
    try
        for x in items
            while idle > 0 && rand(rng) < idle
                setproperty!(dut, bus.valid, 0)
                tick(sim; clock=bus.clock)
            end
            setproperty!(dut, bus.data, x)
            setproperty!(dut, bus.valid, 1)
            waited = 0
            while true
                tick(sim; clock=bus.clock, edge=:falling)
                accepted = handshake(dut, bus)
                tick(sim; clock=bus.clock)              # the word moves here if accepted
                accepted && break
                waited += 1
                max_cycles !== nothing && waited >= max_cycles &&
                    throw(WaitTimeout("`$(bus.ready)` accepting a word", max_cycles, sim.time, sim.cycle))
            end
        end
    finally
        sim.model.ptr == C_NULL || setproperty!(dut, bus.valid, 0)
    end
    return nothing
end

"""
    receive!(sim, bus, n; ready=1.0, rng=Random.default_rng(), max_cycles=nothing) -> Vector

Receives `n` words from the design through `bus` and returns them. Drives
the bus's `ready` input: with `ready < 1`, `ready` is high in each cycle
only with that probability, to test that the design handles backpressure.
`ready` is left low afterwards.

`max_cycles` limits how long to wait for each word; then a
[`WaitTimeout`](@ref VeriJul.SimCore.WaitTimeout) is thrown.
"""
function receive!(sim::Simulator, bus::StreamBus, n::Integer; ready::Real=1.0,
                  rng::AbstractRNG=default_rng(), max_cycles::Union{Integer,Nothing}=nothing)
    dut = the_dut(sim)
    items = Any[]
    align(sim, bus)
    try
        waited = 0
        while length(items) < n
            bus.ready === nothing || setproperty!(dut, bus.ready, ready >= 1 || rand(rng) < ready)
            tick(sim; clock=bus.clock, edge=:falling)
            got = handshake(dut, bus)
            x = got ? getproperty(dut, bus.data) : nothing
            tick(sim; clock=bus.clock)
            if got
                push!(items, x)
                waited = 0
            else
                waited += 1
                max_cycles !== nothing && waited >= max_cycles &&
                    throw(WaitTimeout("a word on `$(bus.valid)`", max_cycles, sim.time, sim.cycle))
            end
        end
    finally
        bus.ready === nothing || sim.model.ptr == C_NULL ||
            setproperty!(dut, bus.ready, 0)
    end
    return isempty(items) ? items : [x for x in items]   # narrow the element type
end

"""
    StreamMonitor(sim, bus; on_item=nothing) -> StreamMonitor

Watches `bus` without driving it, and records every word that moves: in
`mon.items`, with the simulation time of each transfer in `mon.times`.
`on_item(x)`, if given, is called for each word, for example to feed a
[`Scoreboard`](@ref VeriJul.Components.Scoreboard).

The monitor runs as a testbench task from the moment it is created. End it
with [`stop!`](@ref VeriJul.Components.stop!); it also ends quietly when the
clock stops.
"""
mutable struct StreamMonitor
    bus::StreamBus
    items::Vector{Any}
    times::Vector{Int64}
    task::Task
    running::Bool
    StreamMonitor(bus::StreamBus) = new(bus, Any[], Int64[])
end

function StreamMonitor(sim::Simulator, bus::StreamBus; on_item=nothing)
    dut = the_dut(sim)
    mon = StreamMonitor(bus)
    mon.running = true
    function monitor(sim)
        try
            align(sim, bus)
            while mon.running
                tick(sim; clock=bus.clock, edge=:falling)
                x = handshake(dut, bus) ? getproperty(dut, bus.data) : nothing
                tick(sim; clock=bus.clock)
                if x !== nothing
                    push!(mon.items, x)
                    push!(mon.times, sim.time)
                    on_item === nothing || on_item(x)
                end
            end
        catch err
            err isa ClockStopped || rethrow()
        end
        return mon.items
    end
    mon.task = launch(monitor, sim)
    return mon
end

"""
    stop!(mon::StreamMonitor) -> Vector

Stops the monitor after the current cycle and returns the words it saw.
"""
function stop!(mon::StreamMonitor)
    mon.running = false
    istaskdone(mon.task) || wait(mon.task)
    return mon.items
end

Base.show(io::IO, mon::StreamMonitor) =
    print(io, "StreamMonitor(", mon.bus.data, ", ", length(mon.items), " items",
          mon.running ? "" : ", stopped", ")")

# ---------------------------------------------------------------------------
# Scoreboard

struct Mismatch
    index::Int
    expected::Any
    got::Any
    time::Union{Int64,Nothing}
    unexpected::Bool      # nothing was expected at all
end

"""
    Scoreboard(name=""; sim=nothing, compare=isequal)

Checks that a design produces the expected values, in order. Queue what
should come out with [`expect!`](@ref VeriJul.Components.expect!), report
what did come out with [`observe!`](@ref VeriJul.Components.observe!), and
check the result with `@test passed(sb)`. Showing the scoreboard lists
every mismatch, with the simulation time when `sim` is given.

```julia
sb = Scoreboard("fifo"; sim)
expect!(sb, data...)
mon = StreamMonitor(sim, out; on_item = x -> observe!(sb, x))
...
@test passed(sb)
```

`compare(expected, got)` decides whether two values match.
"""
mutable struct Scoreboard
    name::String
    sim::Union{Simulator,Nothing}
    compare::Any
    pending::Vector{Any}
    matched::Int
    observed::Int
    mismatches::Vector{Mismatch}
end
Scoreboard(name::AbstractString=""; sim::Union{Simulator,Nothing}=nothing, compare=isequal) =
    Scoreboard(String(name), sim, compare, Any[], 0, 0, Mismatch[])

"""
    expect!(sb, values...) -> sb

Queues values the design should produce next, in order.
"""
function expect!(sb::Scoreboard, values...)
    append!(sb.pending, values)
    return sb
end

"""
    observe!(sb, value) -> Bool

Compares a value the design produced with the oldest expected one, records
a mismatch if they differ (or if nothing was expected), and returns whether
it matched.
"""
function observe!(sb::Scoreboard, value)
    sb.observed += 1
    t = sb.sim === nothing ? nothing : sb.sim.time
    if isempty(sb.pending)
        push!(sb.mismatches, Mismatch(sb.observed, nothing, value, t, true))
        return false
    end
    expected = popfirst!(sb.pending)
    ok = sb.compare(expected, value)
    ok ? (sb.matched += 1) : push!(sb.mismatches, Mismatch(sb.observed, expected, value, t, false))
    return ok
end

"""
    passed(sb) -> Bool

`true` when every observed value matched and nothing expected is still
outstanding.
"""
passed(sb::Scoreboard) = isempty(sb.mismatches) && isempty(sb.pending)

function Base.show(io::IO, sb::Scoreboard)
    print(io, "Scoreboard(", isempty(sb.name) ? "" : "$(sb.name): ", sb.matched, " matched, ",
          length(sb.mismatches), " mismatched, ", length(sb.pending), " still expected)")
end

function Base.show(io::IO, ::MIME"text/plain", sb::Scoreboard)
    show(io, sb)
    for m in first(sb.mismatches, 10)
        print(io, "\n  #", m.index, ": ")
        m.unexpected ? print(io, "got ", repr(m.got), " but nothing was expected") :
            print(io, "expected ", repr(m.expected), ", got ", repr(m.got))
        m.time === nothing || print(io, " (time ", m.time, ")")
    end
    length(sb.mismatches) > 10 && print(io, "\n  … and ", length(sb.mismatches) - 10, " more")
    isempty(sb.pending) || print(io, "\n  never seen: ", join(repr.(first(sb.pending, 5)), ", "),
                                 length(sb.pending) > 5 ? ", …" : "")
end

end
