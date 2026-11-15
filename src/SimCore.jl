module SimCore

using Libdl
using ..Interop
using ..Interop: VerilatedModel
using ..Device: Device, DUT

export Simulator, start_clock!, stop_clock!, add_clock!, tick, reset!,
       wait_until, wait_edge, ClockStopped, TickTimeout, WaitTimeout, TestbenchError

"""
    ClockStopped()

Thrown by [`tick`](@ref VeriJul.SimCore.tick) when the clock isn't running, or
stops while a task is waiting for an edge.
"""
struct ClockStopped <: Exception
    msg::String
end
ClockStopped() = ClockStopped("the simulator clock is not running; call start_clock!(sim)")
Base.showerror(io::IO, e::ClockStopped) = print(io, "ClockStopped: ", e.msg)

"""
    TickTimeout(seconds)

Thrown by [`tick`](@ref VeriJul.SimCore.tick) when the requested edges don't
arrive within `timeout` seconds of wall-clock time.
"""
struct TickTimeout <: Exception
    seconds::Float64
end
Base.showerror(io::IO, e::TickTimeout) =
    print(io, "TickTimeout: the wait did not finish within $(e.seconds) s of wall-clock time")

"""
    WaitTimeout

Thrown by [`wait_until`](@ref VeriJul.SimCore.wait_until),
[`@wait_until`](@ref VeriJul.DSL.@wait_until) and
[`wait_edge`](@ref VeriJul.SimCore.wait_edge) when what they wait for doesn't
happen within `max_cycles` clock cycles. Fields: `what` (a description),
`cycles` (the limit), `time` and `cycle` (the simulation time and cycle
count when it gave up).
"""
struct WaitTimeout <: Exception
    what::String
    cycles::Int
    time::Int64
    cycle::Int64
end
Base.showerror(io::IO, e::WaitTimeout) =
    print(io, "WaitTimeout: ", e.what, " did not happen within ", e.cycles,
          e.cycles == 1 ? " cycle" : " cycles", " (gave up at time ", e.time,
          ", cycle ", e.cycle, ")")

mutable struct Clock
    name::Symbol
    set_ptr::Ptr{Cvoid}
    half_period::Int64
    value::UInt8
    next_toggle::Int64
    rising::Condition
    falling::Condition
end

"""
    Simulator(dut; clock=:clk, half_period=5)

Simulation state for a [`DUT`](@ref VeriJul.Device.DUT) (or a bare
[`VerilatedModel`](@ref VeriJul.Interop.VerilatedModel)): the current time and
the clocks that drive it.

`clock` names the main clock input; [`tick`](@ref VeriJul.SimCore.tick) and
[`@tick`](@ref VeriJul.DSL.@tick) wait on it unless told otherwise. Add more
clocks with [`add_clock!`](@ref VeriJul.SimCore.add_clock!).

`sim.time` is the simulation time of the most recent clock edge, and
`sim.cycle` counts the rising edges of the main clock so far.

The clocks run in lockstep with the testbench: simulated time only advances
while testbench code is waiting in [`tick`](@ref VeriJul.SimCore.tick), so
printing, sleeping or any other I/O between ticks never skips an edge. Run
concurrent testbenches with [`@testbench`](@ref VeriJul.DSL.@testbench) so
the clock waits for all of them.
"""
mutable struct Simulator
    dut::Union{DUT,VerilatedModel}
    model::VerilatedModel
    time::Int64
    clocks::Vector{Clock}
    clock_task::Union{Task,Nothing}
    running::Bool
    started::Bool   # true once the clocks have evaluated the design at least once
    participants::Set{Task}   # @testbench tasks the clock waits for
    ready::Condition          # notified when a task starts waiting or a testbench ends
    cycle::Int64              # rising edges of the main clock so far
    evaluated::Condition      # notified after every evaluation (any clock edge)
end

model_of(m::VerilatedModel) = m
model_of(d::DUT) = Device.model(d)

# Setter for a 1-bit control input (clock or reset). DUTs already hold the
# pointers; bare models are looked up in the library. The setter is called
# with a UInt8, so anything but a 1-bit input would get the wrong argument
# type (wide ports even expect a pointer).
function input_setter(dut::DUT, ::VerilatedModel, name::Symbol, what::AbstractString)
    h = get(getfield(dut, :handles), name, nothing)
    (h === nothing || h.port.direction != :in) &&
        error("The design has no input port named `$name` to use as $what")
    h.port.width == 1 ||
        error("Port `$name` is $(h.port.width) bits wide; $what must be a 1-bit input")
    return h.set_ptr
end

function input_setter(::VerilatedModel, model::VerilatedModel, name::Symbol, what::AbstractString)
    f = Libdl.dlsym(model.lib_handle, Symbol("set_", name); throw_error=false)
    f === nothing && error("The design has no input port named `$name` to use as $what")
    return f
end

function Simulator(dut::Union{DUT,VerilatedModel}; clock::Symbol=:clk, half_period::Integer=5)
    sim = Simulator(dut, model_of(dut), 0, Clock[], nothing, false, false, Set{Task}(), Condition(),
                    0, Condition())
    add_clock!(sim, clock; half_period=half_period)
    return sim
end

# Main-clock fields for the lower-level API: rising_edge, falling_edge, clk_val
function Base.getproperty(sim::Simulator, s::Symbol)
    s === :rising_edge  && return getfield(sim, :clocks)[1].rising
    s === :falling_edge && return getfield(sim, :clocks)[1].falling
    s === :clk_val      && return getfield(sim, :clocks)[1].value
    return getfield(sim, s)
end

"""
    add_clock!(sim, name; half_period=5, phase=0)

Adds another 1-bit clock input. It toggles every `half_period` time units.
All clocks run on the same timeline, so their edges interleave correctly.
Wait for its edges with `tick(sim; clock=name)`.

`phase` is measured from the current simulation time: before the simulation
has started, the first toggle is at time `phase`; if clocks are added to a
stopped simulation, the first toggle is `phase` after `sim.time` (or one
`half_period` after it when `phase` is 0), so time never goes backwards.
The simulator must not be running.
"""
function add_clock!(sim::Simulator, name::Symbol; half_period::Integer=5, phase::Integer=0)
    sim.running && error("Stop the clock (stop_clock!) before adding another one")
    half_period > 0 || throw(ArgumentError("half_period must be positive"))
    phase >= 0 || throw(ArgumentError("phase must not be negative"))
    any(c -> c.name == name, sim.clocks) && error("Clock `$name` already exists")
    set_ptr = input_setter(sim.dut, sim.model, name, "a clock")
    first_toggle = sim.started ? sim.time + (phase > 0 ? phase : half_period) : Int64(phase)
    push!(sim.clocks, Clock(name, set_ptr, half_period, 0x00, first_toggle, Condition(), Condition()))
    return sim
end

function find_clock(sim::Simulator, name::Union{Symbol,Nothing})
    name === nothing && return sim.clocks[1]
    i = findfirst(c -> c.name == name, sim.clocks)
    i === nothing && error("No clock named `$name`; add it with add_clock!(sim, :$name)")
    return sim.clocks[i]
end

# Tasks currently waiting for an edge of any clock.
function waiting_tasks(sim::Simulator)
    waiting = Set{Task}()
    for c in sim.clocks
        union!(waiting, c.rising.waitq)
        union!(waiting, c.falling.waitq)
    end
    union!(waiting, sim.evaluated.waitq)
    return waiting
end

# Testbenches blocked in wait/fetch on another testbench (e.g. a parent
# waiting for a child it launched). They aren't busy, so they mustn't hold
# the clock back; the child's own state decides instead.
function waiting_on_testbenches(sim::Simulator)
    waiting = Set{Task}()
    for t in sim.participants
        done = getfield(t, :donenotify)
        done isa Base.GenericCondition && union!(waiting, done.waitq)
    end
    return waiting
end

# The next edge may happen once someone is waiting for an edge and no
# registered testbench is still busy between two ticks.
function can_advance(sim::Simulator)
    on_edge = waiting_tasks(sim)
    isempty(on_edge) && return false
    on_child = waiting_on_testbenches(sim)
    return all(t -> t in on_edge || t in on_child || istaskdone(t), sim.participants)
end

function wait_until_ready(sim::Simulator)
    while sim.running && !can_advance(sim)
        # Explicit notifications cover tick() and @testbench tasks; the timer
        # also catches tasks that wait on the edge Conditions directly.
        timer = Timer(_ -> notify(sim.ready), 0.01)
        try
            wait(sim.ready)
        finally
            close(timer)
        end
    end
end

"""
    launch(f, sim, args...; kwargs...) -> Task

Runs `f(sim, args...; kwargs...)` as a testbench task that the clock waits for: no edge happens
while it is busy between two ticks. [`@testbench`](@ref VeriJul.DSL.@testbench)
launchers use this.

The task records `@test` results into the `@testset` that was active when it
was launched, adding the simulation time and cycle to every failure. If `f`
throws, the task fails with a [`TestbenchError`](@ref VeriJul.SimCore.TestbenchError)
saying when.
"""
function launch(f, sim::Simulator, args...; kwargs...)
    name = Symbol(nameof(f))
    parent = capture_testsets()
    task = @task try
        with_sim_testset(parent, sim, name) do
            f(sim, args...; kwargs...)
        end
    catch err
        throw(testbench_error(err, catch_backtrace(), sim, name))
    finally
        delete!(sim.participants, current_task())
        notify(sim.ready)
    end
    push!(sim.participants, task)
    schedule(task)
    return task
end

function wake_all(sim::Simulator, err)
    for c in sim.clocks
        notify(c.rising, err; error=true)
        notify(c.falling, err; error=true)
    end
    notify(sim.evaluated, err; error=true)
end

"""
    start_clock!(sim[, half_period]) -> Task

Starts the clocks in a background task. Whenever the testbench is waiting
in [`tick`](@ref VeriJul.SimCore.tick), it toggles the clocks due at the
earliest time, evaluates the design (writing a waveform sample if tracing is
on) and wakes the waiting tasks. Simulated time does not advance while the
testbench is busy, so no edge is ever skipped.

Passing `half_period` changes the main clock's half period.
Throws if the clock is already running.
"""
function start_clock!(sim::Simulator, half_period::Union{Integer,Nothing}=nothing)
    sim.running && error("Clock is already running; call stop_clock!(sim) first")
    half_period === nothing || (sim.clocks[1].half_period = half_period)
    sim.running = true

    sim.clock_task = @async try
        toggled = Clock[]
        while sim.running
            wait_until_ready(sim)
            sim.running || break
            t = minimum(c.next_toggle for c in sim.clocks)
            sim.time = t
            empty!(toggled)
            for c in sim.clocks
                if c.next_toggle == t
                    c.value ⊻= 0x01
                    ccall(c.set_ptr, Cvoid, (Ptr{Cvoid}, UInt8), sim.model.ptr, c.value)
                    c.next_toggle += c.half_period
                    push!(toggled, c)
                end
            end
            Interop.eval_step!(sim.model, t)
            sim.started = true
            main = sim.clocks[1]
            any(c -> c === main, toggled) && main.value == 0x01 && (sim.cycle += 1)
            for c in toggled
                notify(c.value == 0x01 ? c.rising : c.falling)
            end
            notify(sim.evaluated)
            yield()
        end
    catch err
        # Never leave testbenches waiting on a clock that has died
        sim.running = false
        wake_all(sim, err)
        rethrow()
    end
    return sim.clock_task
end

"""
    stop_clock!(sim)

Stops the clocks and waits for the background task to finish. Tasks still
waiting in [`tick`](@ref VeriJul.SimCore.tick) get a
[`ClockStopped`](@ref VeriJul.SimCore.ClockStopped) error instead of hanging.
Call this before `destroy!`-ing the design.
"""
function stop_clock!(sim::Simulator)
    sim.running = false
    notify(sim.ready)
    t = sim.clock_task
    t === nothing || wait(t)
    sim.clock_task = nothing
    wake_all(sim, ClockStopped("the simulator clock was stopped"))
    return nothing
end

"""
    tick(sim, n=1; clock=nothing, edge=:rising, timeout=nothing)

Waits for `n` edges of a clock (the main clock unless `clock` is given).
`edge` is `:rising` or `:falling`. `timeout` is a wall-clock limit in seconds;
when it passes, a [`TickTimeout`](@ref VeriJul.SimCore.TickTimeout) is thrown.

Simulated time only advances while testbench code is waiting here, so
whatever the task does between ticks (printing, sleeping, I/O) never makes it
miss an edge.

Throws [`ClockStopped`](@ref VeriJul.SimCore.ClockStopped) if the clock isn't
running. [`@tick`](@ref VeriJul.DSL.@tick) is shorthand for this.
"""
function tick(sim::Simulator, n::Integer=1; clock::Union{Symbol,Nothing}=nothing,
              edge::Symbol=:rising, timeout::Union{Real,Nothing}=nothing)
    edge in (:rising, :falling) || throw(ArgumentError("edge must be :rising or :falling"))
    n >= 0 || throw(ArgumentError("n must be non-negative"))
    c = find_clock(sim, clock)
    cond = edge === :rising ? c.rising : c.falling
    n == 0 && return sim

    with_timeout(timeout) do
        for _ in 1:n
            wait_for(sim, cond)
        end
    end
    return sim
end

# Wait on one of the simulator's Conditions, letting the clock run meanwhile.
function wait_for(sim::Simulator, cond::Condition)
    sim.running || throw(ClockStopped())
    notify(sim.ready)   # the clock runs once this task is waiting
    return wait(cond)
end

# Run `f()`, interrupting it with a TickTimeout after `timeout` wall-clock seconds.
function with_timeout(f, timeout::Union{Real,Nothing})
    timeout === nothing && return f()
    done = Ref(false)
    waiter = current_task()
    timer = Timer(timeout) do _
        # Interrupt the wait unless the task has already moved on
        done[] || schedule(waiter, TickTimeout(timeout); error=true)
    end
    try
        return f()
    finally
        done[] = true
        close(timer)
    end
end

"""
    wait_until(cond, sim; max_cycles=nothing, clock=nothing, edge=:rising, timeout=nothing) -> Int

Waits until `cond()` returns `true`, checking it now and then after every
rising edge of the main clock (or the `edge` of `clock`). Returns the number
of edges waited, so `0` means the condition already held.

`max_cycles` limits how many edges to wait: when it runs out, a
[`WaitTimeout`](@ref VeriJul.SimCore.WaitTimeout) with the simulation time is
thrown. `timeout` is a wall-clock limit in seconds, as for
[`tick`](@ref VeriJul.SimCore.tick).

```julia
wait_until(sim; max_cycles=100) do
    dut.valid == 1
end
```

[`@wait_until`](@ref VeriJul.DSL.@wait_until) is shorthand that also puts the
condition's source text in the error message.
"""
function wait_until(cond, sim::Simulator; max_cycles::Union{Integer,Nothing}=nothing,
                    clock::Union{Symbol,Nothing}=nothing, edge::Symbol=:rising,
                    timeout::Union{Real,Nothing}=nothing, what::AbstractString="the condition")
    edge in (:rising, :falling) || throw(ArgumentError("edge must be :rising or :falling"))
    max_cycles === nothing || max_cycles >= 0 || throw(ArgumentError("max_cycles must be non-negative"))
    c = find_clock(sim, clock)
    edge_cond = edge === :rising ? c.rising : c.falling
    cond() && return 0
    return with_timeout(timeout) do
        n = 0
        while true
            max_cycles !== nothing && n >= max_cycles &&
                throw(WaitTimeout(what, max_cycles, sim.time, sim.cycle))
            wait_for(sim, edge_cond)
            n += 1
            cond() && return n
        end
    end
end

"""
    wait_edge(sim, port; edge=:rising, max_cycles=nothing, clock=nothing, timeout=nothing)

Waits for a port of the design to change, and returns its new value.
`edge` is `:rising` (0 → 1) or `:falling` (1 → 0) for 1-bit ports, or
`:change` for any change of a port of any width.

The port is sampled after every evaluation of the design, that is after each
edge of any clock, since that is when outputs change. Inputs set by another
testbench are seen at the next evaluation.

`max_cycles` counts rising edges of the main clock (or of `clock`); when it
runs out a [`WaitTimeout`](@ref VeriJul.SimCore.WaitTimeout) is thrown.
`timeout` is a wall-clock limit in seconds. Needs a simulator built from a
[`DUT`](@ref VeriJul.Device.DUT).

```julia
wait_edge(sim, :done)                     # wait for `done` to go high
wait_edge(sim, :state; edge=:change)      # wait for the FSM to move
```
"""
function wait_edge(sim::Simulator, port::Symbol; edge::Symbol=:rising,
                   max_cycles::Union{Integer,Nothing}=nothing,
                   clock::Union{Symbol,Nothing}=nothing, timeout::Union{Real,Nothing}=nothing)
    edge in (:rising, :falling, :change) ||
        throw(ArgumentError("edge must be :rising, :falling or :change"))
    max_cycles === nothing || max_cycles >= 0 || throw(ArgumentError("max_cycles must be non-negative"))
    dut = sim.dut
    dut isa DUT || error("wait_edge needs a Simulator built from a DUT (see load_dut)")
    h = Device.handle(dut, port)
    edge !== :change && h.port.width != 1 &&
        throw(ArgumentError("Port `$port` is $(h.port.width) bits wide; use edge=:change " *
                            "(rising and falling edges are for 1-bit ports)"))
    c = find_clock(sim, clock)
    fired(old, new) = edge === :change ? new != old :
                      edge === :rising ? (old == 0 && new != 0) : (old != 0 && new == 0)
    what = edge === :change ? "a change of `$port`" : "a $edge edge of `$port`"

    return with_timeout(timeout) do
        old = getproperty(dut, port)
        n = 0
        while true
            max_cycles !== nothing && n >= max_cycles &&
                throw(WaitTimeout(what, max_cycles, sim.time, sim.cycle))
            wait_for(sim, sim.evaluated)
            new = getproperty(dut, port)
            fired(old, new) && return new
            old = new
            # Count cycles of the chosen clock: did it just rise?
            (c.value == 0x01 && c.next_toggle - c.half_period == sim.time) && (n += 1)
        end
    end
end

"""
    reset!(sim, port=:rst; cycles=2, active_high=true)

Asserts a reset input for `cycles` rising edges of the main clock, then
releases it. The clock must be running. Use `active_high=false` for an
active-low reset such as `rst_n`.
"""
function reset!(sim::Simulator, port::Symbol=:rst; cycles::Integer=2, active_high::Bool=true)
    set_ptr = input_setter(sim.dut, sim.model, port, "a reset")
    set(v) = ccall(set_ptr, Cvoid, (Ptr{Cvoid}, UInt8), sim.model.ptr, UInt8(v == active_high))
    set(true)
    try
        tick(sim, cycles)
    finally
        sim.model.ptr == C_NULL || set(false)
    end
    return sim
end

include("testsets.jl")

end
