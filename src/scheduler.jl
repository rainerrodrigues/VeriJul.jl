# The lockstep scheduler (included in SimCore).
#
# The clock task advances simulated time one edge at a time, and only when
#   1. some task is waiting for an edge, and
#   2. every @testbench task (a "participant") is waiting for an edge, is
#      waiting for another testbench to finish, or has finished.
# So testbench code that is busy between two ticks (printing, sleeping,
# talking to a channel) never makes anyone miss an edge.
#
# Waiting goes through `wait_for`, which notifies `sim.ready` so the clock
# re-checks the rule at once. The only wait the scheduler isn't told about is
# a testbench blocking in `wait`/`fetch` on another testbench's task; while
# some testbench is busy, a slow timer covers that case.

# ---------------------------------------------------------------------------
# Who is waiting for what

anyone_waiting(sim::Simulator) =
    !isempty(sim.evaluated.waitq) ||
    any(c -> !isempty(c.rising.waitq) || !isempty(c.falling.waitq), sim.clocks)

function waiting_on_edge(sim::Simulator, t::Task)
    for c in sim.clocks
        (t in c.rising.waitq || t in c.falling.waitq) && return true
    end
    return t in sim.evaluated.waitq
end

# Blocked in wait/fetch on another testbench (e.g. a parent waiting for a
# child it launched). Not busy, so it mustn't hold the clock back.
function waiting_on_testbench(sim::Simulator, t::Task)
    for p in sim.participants
        done = getfield(p, :donenotify)
        done isa Base.GenericCondition && t in done.waitq && return true
    end
    return false
end

busy(sim::Simulator, t::Task) =
    !istaskdone(t) && !waiting_on_edge(sim, t) && !waiting_on_testbench(sim, t)

can_advance(sim::Simulator) =
    anyone_waiting(sim) && !any(t -> busy(sim, t), sim.participants)

function wait_until_ready(sim::Simulator)
    # Tasks woken by the last edge usually reach their next wait right away
    for _ in 1:3
        (sim.running && !can_advance(sim)) || return
        yield()
    end
    while sim.running && !can_advance(sim)
        if any(t -> busy(sim, t), sim.participants)
            # A busy testbench may start waiting on another testbench, which
            # sends no notification, so check again after a while
            timer = Timer(_ -> notify(sim.ready), 0.01)
            try
                wait(sim.ready)
            finally
                close(timer)
            end
        else
            wait(sim.ready)     # the next wait_for notifies
        end
    end
end

# Wait on one of the simulator's Conditions, letting the clock run meanwhile.
function wait_for(sim::Simulator, cond::Condition)
    sim.running || throw(stopped_error(sim))
    notify(sim.ready)   # the clock may run once this task is waiting
    return wait(cond)
end

# The error for waiting on a clock that isn't running: the testbench failure
# that stopped it, if there was one.
stopped_error(sim::Simulator) = something(sim.failure, ClockStopped())

"""
    EdgeEvent

What `sim.rising_edge` and `sim.falling_edge` return: `wait(sim.rising_edge)`
waits for the next rising edge of the main clock, like `tick(sim)`.
"""
struct EdgeEvent
    sim::Simulator
    cond::Condition
end
Base.wait(e::EdgeEvent) = wait_for(e.sim, e.cond)

# ---------------------------------------------------------------------------
# Testbench tasks

"""
    launch(f, sim, args...; kwargs...) -> Task

Runs `f(sim, args...; kwargs...)` as a testbench task that the clock waits for: no edge happens
while it is busy between two ticks. [`@testbench`](@ref VeriJul.DSL.@testbench)
launchers use this.

The task records `@test` results into the `@testset` that was active when it
was launched, adding the simulation time and cycle to every failure. If `f`
throws, the task fails with a [`TestbenchError`](@ref VeriJul.SimCore.TestbenchError)
saying when, and (unless the simulator was created with `stop_on_error=false`)
the clock stops: every task waiting on it gets that same error, so nothing
is left hanging and the failure reaches whoever is waiting.
"""
function launch(f, sim::Simulator, args...; kwargs...)
    name = Symbol(nameof(f))
    parent = capture_testsets()
    task = @task try
        with_sim_testset(parent, sim, name) do
            f(sim, args...; kwargs...)
        end
    catch err
        tberr = testbench_error(err, catch_backtrace(), sim, name)
        # Errors caused by an ordinary stop_clock! (ClockStopped) aren't
        # failures. A real failure is reported to the hooks (e.g. a
        # WaveRecorder) and, unless stop_on_error=false, stops the clock.
        if sim.running
            run_failure_hooks(sim, tberr)
            sim.stop_on_error && fail!(sim, tberr)
        end
        throw(tberr)
    finally
        delete!(sim.participants, current_task())
        notify(sim.ready)
    end
    push!(sim.participants, task)
    schedule(task)
    return task
end

# Stop the clock because a testbench failed, and hand the error to everyone waiting.
function fail!(sim::Simulator, err)
    sim.failure === nothing || return
    sim.failure = err
    sim.running = false
    notify(sim.ready)
    wake_all(sim, err)
end

# Tell the hooks about a failure (a testbench error or a failed @test). A
# hook that throws, such as a recorder that can't write its file, is logged
# and never stops the failure itself from being reported.
function run_failure_hooks(sim::Simulator, err)
    for h in sim.hooks
        try
            on_failure(h, sim, err)
        catch hook_err
            @error "A simulator hook failed while handling a failure" hook = h exception = (hook_err, catch_backtrace())
        end
    end
end

function wake_all(sim::Simulator, err)
    for c in sim.clocks
        notify(c.rising, err; error=true)
        notify(c.falling, err; error=true)
    end
    notify(sim.evaluated, err; error=true)
end

# Hooks: objects in `sim.hooks` (such as a WaveRecorder) get these calls.
on_evaluate(hook, sim::Simulator) = nothing
on_failure(hook, sim::Simulator, err) = nothing

# ---------------------------------------------------------------------------
# The clocks

# Toggle the clocks due at the earliest time, evaluate the design and wake
# the waiting tasks. `sim.toggled` holds the clocks that changed.
function step_edge!(sim::Simulator)
    t = minimum(c.next_toggle for c in sim.clocks)
    sim.time = t
    toggled = sim.toggled
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
    main.value == 0x01 && main in toggled && (sim.cycle += 1)
    for h in sim.hooks
        on_evaluate(h, sim)
    end
    for c in toggled
        notify(c.value == 0x01 ? c.rising : c.falling)
    end
    notify(sim.evaluated)
    return toggled
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
    sim.failure = nothing
    sim.running = true

    sim.clock_task = @async try
        while sim.running
            wait_until_ready(sim)
            sim.running || break
            step_edge!(sim)
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
    run!(sim, n; clock=nothing) do cycle ... end
    run!(sim, n)

Runs `n` cycles of the main clock (or `clock`) directly in the calling task,
calling `f(cycle)` after each rising edge with `cycle` counting from 1. No
background task and no task switches are involved, so this is the fastest
way to run simple stimulus loops:

```julia
run!(sim, 1000) do cycle
    dut.in_data = rand(UInt8)
end
```

The clock must not be running (no `start_clock!`), since `run!` drives the
clocks itself; `tick` and `@testbench` tasks don't work inside it. Use
`tick` and `@testbench` when you need several things to happen
concurrently. All clocks keep running on the same timeline, and hooks such
as a [`WaveRecorder`](@ref VeriJul.Waves.WaveRecorder) see every edge.
"""
function run!(f, sim::Simulator, n::Integer; clock::Union{Symbol,Nothing}=nothing)
    sim.running && error("run! drives the clocks itself; stop the clock (stop_clock!) first")
    n >= 0 || throw(ArgumentError("n must be non-negative"))
    c = find_clock(sim, clock)
    for cycle in 1:n
        while true
            toggled = step_edge!(sim)
            c.value == 0x01 && c in toggled && break
        end
        f(cycle)
    end
    return sim
end
run!(sim::Simulator, n::Integer; kwargs...) = run!(_ -> nothing, sim, n; kwargs...)
