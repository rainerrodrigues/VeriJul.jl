# Test.jl integration for testbench tasks (included in SimCore).
#
# A task launched with `launch` records `@test` results into the `@testset`
# that was active when it was launched, and every failure says when in the
# simulation it happened.
#
# Julia 1.10-1.12 keep the testset stack in task-local storage, which new
# tasks don't inherit, so it is copied over. Julia 1.13+ keep it in a
# ScopedValue, which tasks inherit by themselves.

using Test

"""
    TestbenchError

The error a [`@testbench`](@ref VeriJul.DSL.@testbench) task fails with when
its function throws. It says which testbench failed and when. Fields:
`testbench` (the function name), `time` and `cycle` (the simulation time and
cycle count), `error` (the original exception) and `backtrace`.

`wait(task)` and `fetch(task)` throw a `TaskFailedException` wrapping it, which
a surrounding `@testset` reports as an error.
"""
struct TestbenchError <: Exception
    testbench::Symbol
    time::Int64
    cycle::Int64
    error::Any
    backtrace::Any
end

function Base.showerror(io::IO, e::TestbenchError)
    print(io, "TestbenchError: testbench `", e.testbench, "` failed at simulation time ",
          e.time, " (cycle ", e.cycle, "):\n")
    showerror(io, e.error, e.backtrace)
end

function testbench_error(err, bt, sim, name::Symbol)
    # A testbench whose child testbench failed: pass the child's error on as is
    if err isa TaskFailedException && err.task.exception isa TestbenchError
        return err.task.exception
    end
    err isa TestbenchError && return err
    return TestbenchError(name, sim.time, sim.cycle, err, bt)
end

# Forwards results to the testset the task was launched from, adding the
# simulation context to failures and errors.
struct SimTestSet <: Test.AbstractTestSet
    parent::Test.AbstractTestSet
    sim::Any
    testbench::Symbol
end

sim_context(ts::SimTestSet) =
    "simulation time $(ts.sim.time), cycle $(ts.sim.cycle), testbench `$(ts.testbench)`"

Test.record(ts::SimTestSet, res) = Test.record(ts.parent, res)

function Test.record(ts::SimTestSet, res::Test.Fail)
    ctx = sim_context(ts)
    old = res.context
    new_ctx = old === nothing ? ctx : string(old, "\n", ctx)
    # Rebuild the Fail with the extra context; its fields are in constructor order
    args = [name === :context ? new_ctx : getfield(res, name) for name in fieldnames(Test.Fail)]
    return Test.record(ts.parent, Test.Fail(args...))
end

function Test.record(ts::SimTestSet, res::Test.Error)
    # Error's constructor differs between Julia versions, so rather than
    # rebuilding it, print the context right after Test prints the error.
    r = Test.record(ts.parent, res)
    printstyled("  Simulation context: ", sim_context(ts), "\n"; color=:red)
    return r
end

Test.finish(ts::SimTestSet) = ts

# The caller's testset stack (Julia < 1.13), or nothing.
function capture_testsets()
    stack = get(task_local_storage(), :__BASETESTNEXT__, nothing)
    return stack === nothing ? nothing : copy(stack)
end

function with_sim_testset(f, parent_stack, sim, name::Symbol)
    if isdefined(Test, :CURRENT_TESTSET)
        # Julia 1.13+: the testset is a ScopedValue the task already inherited
        current = Test.get_testset()
        current isa Test.FallbackTestSet && return f()
        return Base.ScopedValues.with(f, Test.CURRENT_TESTSET => SimTestSet(current, sim, name))
    end
    (parent_stack === nothing || isempty(parent_stack)) && return f()
    task_local_storage(:__BASETESTNEXT__, copy(parent_stack))
    Test.push_testset(SimTestSet(last(parent_stack), sim, name))
    return f()
end
