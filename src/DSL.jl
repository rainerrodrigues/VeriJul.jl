module DSL

using ..SimCore: Simulator, tick, launch, wait_until
export @tick, @testbench, @wait_until

"""
    @tick sim
    @tick sim n
    @tick sim n clock=:clk_b edge=:falling timeout=1.0

Waits for the next rising edge of the main clock, or `n` edges. Keywords are
passed to [`tick`](@ref VeriJul.SimCore.tick): `clock`, `edge` and `timeout`
(wall-clock seconds).
"""
macro tick(sim, args...)
    pos = Any[]
    kws = Any[]
    for a in args
        if a isa Expr && a.head === :(=)
            push!(kws, Expr(:kw, a.args[1], esc(a.args[2])))
        else
            isempty(kws) || throw(ArgumentError("@tick: the cycle count must come before keywords"))
            push!(pos, esc(a))
        end
    end
    length(pos) <= 1 || throw(ArgumentError("@tick takes at most one cycle count"))
    return Expr(:call, tick, Expr(:parameters, kws...), esc(sim), pos...)
end

"""
    @wait_until sim condition
    @wait_until sim condition max_cycles=100 clock=:clk_b edge=:falling timeout=1.0

Waits until `condition` (any Julia expression) is true, checking it now and
after every rising edge of the main clock. Returns the number of edges
waited. Keywords are passed to [`wait_until`](@ref VeriJul.SimCore.wait_until);
when `max_cycles` runs out, the [`WaitTimeout`](@ref VeriJul.SimCore.WaitTimeout)
message quotes the condition.

```julia
@wait_until sim dut.valid == 1 max_cycles=100
```
"""
macro wait_until(sim, cond, args...)
    kws = Any[]
    for a in args
        (a isa Expr && a.head === :(=)) ||
            throw(ArgumentError("@wait_until: expected keyword=value after the condition, got `$a`"))
        push!(kws, Expr(:kw, a.args[1], esc(a.args[2])))
    end
    push!(kws, Expr(:kw, :what, "`" * string(Base.remove_linenums!(cond)) * "`"))
    f = Expr(:->, Expr(:tuple), esc(cond))
    return Expr(:call, wait_until, Expr(:parameters, kws...), f, esc(sim))
end

"""
    @testbench func

Defines `func` as usual and also a `launch_<func>(sim::Simulator, args...; kwargs...)`
that runs `func(sim, args...; kwargs...)` as an asynchronous task, so it can wait on clock edges with [`@tick`](@ref VeriJul.DSL.@tick).

The clock waits for every launched testbench: no edge happens while any of
them is busy between two ticks, so a driver and a monitor running together
both see every edge. A finished testbench no longer holds the clock back.

`@test` inside a testbench records into the `@testset` that was active when
it was launched, and failures show the simulation time and cycle. If the
function throws, the task fails with a [`TestbenchError`](@ref VeriJul.SimCore.TestbenchError)
saying when; `wait` on the task inside a `@testset` to report it.

```julia
@testbench function drive(sim)
    sim.dut.in_data = 0xFF
    @tick sim
end

task = launch_drive(sim)
wait(task)
```
"""
macro testbench(expr)
    # Ensures the macro is applied to a function
    (expr isa Expr && (expr.head == :function || expr.head == :(=))) ||
        throw(ArgumentError("@testbench must be applied to a function definition"))

    # Strip a return-type annotation / where clause to reach the call signature
    sig = expr.args[1]
    while sig isa Expr && sig.head in (:where, :(::))
        sig = sig.args[1]
    end
    func_name = sig.args[1]

    return quote
        # Defines the user's function
        $(esc(expr))

        # Creates a launcher for it
        function $(esc(Symbol("launch_", func_name)))(sim::Simulator, args...; kwargs...)
            launch($(esc(func_name)), sim, args...; kwargs...)
        end
    end
end

end
