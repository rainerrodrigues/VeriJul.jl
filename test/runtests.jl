using Test
using Aqua
using VeriJul
using Random
using VeriJul.Builder: extract_ports, generate_bindings, verilator_version, verilator_cmd,
                       prepare_build_dir, claim_build_dir, clear_build_dir, cached_build,
                       cxx_cmd, build_cache, clear_build_cache, BUILD_MARKER, BUILD_LOCK, BUILD_RECORD
using VeriJul.Interop: words_to_int, int_to_words

include("mock.jl")

# A testset that keeps every result and never fails its parent
mutable struct Capture <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    Capture(desc; kwargs...) = new(desc, Any[])
end
Test.record(ts::Capture, r) = (push!(ts.results, r); r)
function Test.finish(ts::Capture)
    # A nested Capture records into its parent, but never into a DefaultTestSet,
    # so the failures it keeps don't fail the suite
    parent = Test.get_testset()
    parent isa Union{Test.DefaultTestSet,Test.FallbackTestSet} || Test.record(parent, ts)
    return ts
end

have_toolchain() = (try verilator_cmd(); cxx_cmd(); true catch; false end)

@testset "VeriJul.jl" begin
    @testset "Port extraction" begin
        ports = extract_ports(joinpath(@__DIR__, "fixtures", "Vports.h"))
        @test ports == [
            HardwarePort("clk", :in, 1),
            HardwarePort("in_data", :in, 8),
            HardwarePort("word", :in, 16),
            HardwarePort("bus", :in, 4),
            HardwarePort("wide", :out, 41),
            HardwarePort("out_data", :out, 8),   # pre-4.200 style without `&`
            HardwarePort("huge", :out, 100),
        ]
        empty_header = tempname()
        write(empty_header, "class Vnothing {};")
        @test_throws ErrorException extract_ports(empty_header)
    end

    @testset "Build directories never delete user files" begin
        root = mktempdir()
        new = joinpath(root, "new", "nested")
        prepare_build_dir(new)
        @test isfile(joinpath(new, BUILD_MARKER))

        empty_dir = mkpath(joinpath(root, "empty"))
        prepare_build_dir(empty_dir)
        @test isfile(joinpath(empty_dir, BUILD_MARKER))

        users = mkpath(joinpath(root, "users"))
        write(joinpath(users, "notes.txt"), "keep me")
        err = try prepare_build_dir(users); nothing catch e; e end
        @test err isa ErrorException && occursin("Refusing", err.msg)
        @test read(joinpath(users, "notes.txt"), String) == "keep me"

        # A directory VeriJul created is emptied and reused
        write(joinpath(new, "old_build.o"), "stale")
        prepare_build_dir(new)
        @test readdir(new) == [BUILD_MARKER]

        # Clearing keeps the marker and the lock file
        write(joinpath(new, BUILD_LOCK), "")
        write(joinpath(new, "lib.so"), "x")
        clear_build_dir(new)
        @test sort(readdir(new)) == sort([BUILD_MARKER, BUILD_LOCK])

        # Only a complete build for the same key counts as cached
        @test cached_build(new, "abc") === nothing
        write(joinpath(new, "libVx_1.so"), "x"); write(joinpath(new, "bindings.jl"), "")
        write(joinpath(new, BUILD_RECORD), "abc\nlibVx_1.so\n")
        @test cached_build(new, "abc") == (joinpath(new, "libVx_1.so"), joinpath(new, "bindings.jl"))
        @test cached_build(new, "other") === nothing
        rm(joinpath(new, "libVx_1.so"))
        @test cached_build(new, "abc") === nothing

        @test isdir(build_cache())
        @test startswith(build_cache(), first(DEPOT_PATH))
    end

    @testset "Toolchain lookup" begin
        withenv("VERIJUL_VERILATOR" => "/no/such/verilator") do
            err = try verilator_cmd(); nothing catch e; e end
            @test err isa ErrorException && occursin("VERIJUL_VERILATOR", err.msg)
        end
        withenv("VERIJUL_VERILATOR" => nothing, "PATH" => "") do
            err = try verilator_cmd(); nothing catch e; e end
            @test err isa ErrorException && occursin("apt install verilator", err.msg)
        end
        withenv("CXX" => "no-such-compiler-xyz") do
            err = try cxx_cmd(); nothing catch e; e end
            @test err isa ErrorException && occursin("C++17", err.msg)
        end
        sh = Sys.which("sh")
        withenv("CXX" => "$sh -c") do
            @test cxx_cmd() == `$sh -c`        # multi-word CXX, e.g. "ccache g++"
        end
    end

    @testset "Binding generation" begin
        ports = [HardwarePort("clk", :in, 1), HardwarePort("word", :in, 16),
                 HardwarePort("wide", :out, 41), HardwarePort("huge", :in, 100)]
        cpp, jl = generate_bindings(ports, "dut")
        @test occursin("#include \"Vdut.h\"", cpp)
        @test occursin("void set_word(Handle* h, uint16_t val)", cpp)
        @test occursin("uint16_t get_word(Handle* h)", cpp)          # inputs are readable too
        @test occursin("uint64_t get_wide(Handle* h)", cpp)
        @test !occursin("set_wide", cpp)                             # outputs have no setter
        @test occursin("void set_huge(Handle* h, const uint32_t* in)", cpp)
        @test occursin("void get_huge(Handle* h, uint32_t* out)", cpp)
        @test occursin("void top_settle(Handle* h)", cpp)
        @test occursin("double sc_time_stamp()", cpp)
        @test occursin("new VerilatedContext", cpp)          # one context per model
        @test Meta.parse(jl) isa Expr
        @test occursin("set_huge!(model::VerilatedModel, val::Integer)", jl)
    end

    @testset "Wide value conversion" begin
        x = big(2)^99 + big(2)^64 + 0xdeadbeef
        @test int_to_words(x, 100) == UInt32[0xdeadbeef, 0, 1, 0x8]
        @test words_to_int(int_to_words(x, 100)) == x
        @test words_to_int(int_to_words(-1, 100)) == big(2)^100 - 1   # two's complement
        @test words_to_int(int_to_words(big(2)^100, 100)) == 0       # truncated
    end

    @testset "Macros" begin
        ex = @macroexpand @testbench function my_tb(sim) end
        @test occursin("launch_my_tb", string(ex))
        @test_throws Exception @eval @testbench 42
        @test occursin("tick", string(@macroexpand @tick sim 3 clock=:b))
        @test_throws Exception @eval @macroexpand @tick sim clock=:b 3
    end

    @testset "DUT port access (mock design)" begin
        dut = MockDesign.make_dut()
        @test propertynames(dut) == (:clk, :clk_slow, :rst, :step, :wide_in, :wide_out, :count, :slow_count)
        @test length(ports(dut)) == 8
        dut.step = 0x1ff                       # truncated to 8 bits
        @test dut.step === 0xff
        dut.step = -1
        @test dut.step === 0xff
        dut.step = true
        @test dut.step === 0x01
        x = big(2)^99 + 12345
        dut.wide_in = x
        @test dut.wide_in == x
        @test dut.wide_out == (big(2)^100 - 1) ⊻ x
        @test_throws ErrorException dut.count = 1        # output
        @test_throws ErrorException dut.nope             # unknown port
        @test_throws ArgumentError dut.step = 1.5
        @test occursin("DUT(mock, 8 ports)", sprint(show, dut))
        @test occursin("input   wide_in          100 bits", sprint(show, MIME"text/plain"(), dut))
    end

    @testset "Simulator (mock design)" begin
        dut = MockDesign.make_dut()
        sim = Simulator(dut)
        add_clock!(sim, :clk_slow; half_period=15)
        @test_throws ErrorException add_clock!(sim, :clk_slow)   # duplicate
        @test_throws ErrorException add_clock!(sim, :count)      # not an input
        @test_throws ClockStopped tick(sim)                      # not started

        start_clock!(sim)
        @test_throws ErrorException start_clock!(sim)

        reset!(sim)
        @test dut.rst == 0 && dut.count == 0 && dut.slow_count == 0

        dut.step = 3
        @tick sim 4
        @test dut.count == 12

        before = dut.slow_count
        @tick sim 3 clock=:clk_slow
        @test dut.slow_count == before + 3

        @tick sim edge=:falling
        @test sim.clk_val == 0x00                                # lower-level API field
        t0 = sim.time
        @tick sim
        @test sim.time > t0 && sim.time % 10 == 0                # rising edges at multiples of 10

        @test_throws TickTimeout tick(sim, 10^9; timeout=0.2)
        @tick sim                                                # still usable after a timeout

        # A waiting task gets ClockStopped instead of hanging
        waiter = @async try
            tick(sim, 10^9)
            :finished
        catch e
            e
        end
        yield()
        stop_clock!(sim)
        @test fetch(waiter) isa ClockStopped
        @test_throws ClockStopped tick(sim)

        # Clocks can be restarted
        start_clock!(sim, 2)
        @tick sim 2
        stop_clock!(sim)
        @test sim.clock_task === nothing
    end

    @testset "Clock and reset inputs must be 1 bit (mock design)" begin
        dut = MockDesign.make_dut()
        sim = Simulator(dut)
        err = try add_clock!(sim, :wide_in); nothing catch e; e end
        @test err isa ErrorException && occursin("100 bits wide", err.msg)
        @test_throws ErrorException add_clock!(sim, :step)          # 8 bits
        @test_throws ErrorException Simulator(dut; clock=:step)
        start_clock!(sim)
        @test_throws ErrorException reset!(sim, :wide_in)
        @test_throws ErrorException reset!(sim, :step)
        stop_clock!(sim)
    end

    @testset "Adding a clock later never rewinds time (mock design)" begin
        dut = MockDesign.make_dut()
        sim = Simulator(dut)
        start_clock!(sim)
        @tick sim 5
        stop_clock!(sim)
        t_stop = sim.time
        @test t_stop > 0
        @test_throws ArgumentError add_clock!(sim, :clk_slow; phase=-1)
        add_clock!(sim, :clk_slow; half_period=7)
        start_clock!(sim)
        times = Int[]
        for _ in 1:6
            @tick sim edge=:rising clock=:clk_slow
            push!(times, sim.time)
        end
        stop_clock!(sim)
        @test first(times) > t_stop
        @test issorted(times) && allunique(times)
        @test all(diff(times) .== 14)                # rising edges one period apart
    end

    # Run `f` in a task and fail (instead of hanging the suite) if it takes too long
    function within(f, seconds)
        t = @async f()
        timedwait(() -> istaskdone(t), seconds) === :ok || error("timed out after $seconds s")
        return fetch(t)
    end

    @testset "Lockstep: busy testbenches never miss edges (mock design)" begin
        dut = MockDesign.make_dut()
        sim = Simulator(dut)
        start_clock!(sim)
        sleep(0.05)
        @test !sim.started && sim.time == 0          # nobody waiting: time stands still

        reset!(sim)
        dut.step = 1
        times, counts = Int[], Int[]
        within(10) do
            for i in 1:8
                @tick sim
                push!(times, sim.time); push!(counts, dut.count)
                isodd(i) ? sleep(0.003) : flush(stdout)   # I/O between ticks
            end
        end
        @test all(==(10), diff(times))
        @test counts == 1:8
        stop_clock!(sim)
    end

    @testset "Lockstep: @testbench driver and monitor see every edge (mock design)" begin
        dut = MockDesign.make_dut()
        sim = Simulator(dut)
        @testbench function driver(sim)
            reset!(sim; cycles=1)
            sim.dut.step = 2
            for _ in 1:5
                sleep(0.003)                         # busy: the clock must wait
                @tick sim
            end
        end
        @testbench function monitor(sim)
            seen = Tuple{Int,Int}[]
            for _ in 1:12                            # keeps going after the driver ends
                @tick sim
                push!(seen, (sim.time, Int(sim.dut.count)))
                sleep(0.001)
            end
            return seen
        end
        start_clock!(sim)
        d = launch_driver(sim)
        m = launch_monitor(sim)
        seen = within(20) do
            wait(d)
            fetch(m)
        end
        @test all(==(10), diff(first.(seen)))       # no edge skipped
        @test istaskdone(d) && isempty(sim.participants)
        stop_clock!(sim)
    end

    @testset "Lockstep: a testbench can wait for a child testbench (mock design)" begin
        dut = MockDesign.make_dut()
        sim = Simulator(dut)
        @testbench function child(sim)
            @tick sim 3
            return sim.time
        end
        @testbench function parent(sim)
            @tick sim
            t_child = fetch(launch_child(sim))     # parent waits on the child, not an edge
            @tick sim 2
            return (t_child, sim.time)
        end
        start_clock!(sim)
        t_child, t_end = within(10) do
            fetch(launch_parent(sim))
        end
        @test t_end == t_child + 20
        @test isempty(sim.participants)
        stop_clock!(sim)
    end

    @testset "Lockstep: waiting on sim.rising_edge directly still works (mock design)" begin
        dut = MockDesign.make_dut()
        sim = Simulator(dut)
        start_clock!(sim)
        t0 = within(5) do
            wait(sim.rising_edge)
            sim.time
        end
        within(5) do
            wait(sim.rising_edge)
        end
        @test sim.time == t0 + 10
        stop_clock!(sim)
    end

    @testset "@testbench with a DUT (mock design)" begin
        dut = MockDesign.make_dut()
        sim = Simulator(dut)
        @testbench function count_to(sim)
            reset!(sim; cycles=1)
            sim.dut.step = 1
            @tick sim 5
            return sim.dut.count
        end
        @testbench function count_by(sim, step, n; reset=true)
            reset && reset!(sim; cycles=1)
            sim.dut.step = step
            @tick sim n
            return sim.dut.count
        end
        start_clock!(sim)
        @test fetch(launch_count_to(sim)) == 5
        @test fetch(launch_count_by(sim, 3, 4)) == 12                 # extra arguments
        @test fetch(launch_count_by(sim, 1, 2; reset=false)) == 14    # and keywords
        stop_clock!(sim)
    end

    @testset "wait_until and @wait_until (mock design)" begin
        dut = MockDesign.make_dut()
        sim = Simulator(dut)
        add_clock!(sim, :clk_slow; half_period=15)
        start_clock!(sim)
        within(10) do
            reset!(sim; cycles=1)
            c0 = sim.cycle
            @tick sim 3
            @test sim.cycle == c0 + 3                        # cycle counts main-clock rising edges

            dut.step = 1
            start = dut.count
            @test (@wait_until sim dut.count == start + 5 max_cycles=20) == 5
            @test (@wait_until sim dut.count >= 1) == 0      # already true: no edge waited

            # Function form with a do-block, on another clock
            s0 = dut.slow_count
            n = wait_until(sim; clock=:clk_slow) do
                dut.slow_count >= s0 + 2
            end
            @test n == 2 && dut.slow_count == s0 + 2

            # Running out of cycles names the condition and the time
            dut.step = 0
            c1 = sim.cycle
            err = try
                @wait_until sim dut.count == 0xff max_cycles=3
                nothing
            catch e
                e
            end
            @test err isa WaitTimeout
            @test err.cycles == 3 && err.cycle == c1 + 3 && err.time == sim.time
            msg = sprint(showerror, err)
            @test occursin("`dut.count == 0xff`", msg) && occursin("within 3 cycles", msg)

            # Wall-clock timeout
            @test_throws TickTimeout wait_until(() -> false, sim; timeout=0.2)
            @tick sim                                        # still usable afterwards
        end
        @test_throws ArgumentError wait_until(() -> true, sim; edge=:both)
        @test_throws ArgumentError wait_until(() -> true, sim; max_cycles=-1)
        stop_clock!(sim)
        @test_throws ClockStopped wait_until(() -> false, sim)
        @test wait_until(() -> true, sim) == 0               # no need for the clock
    end

    @testset "wait_edge (mock design)" begin
        dut = MockDesign.make_dut()
        sim = Simulator(dut)
        @testbench function pulse_reset(sim)
            @tick sim 3
            sim.dut.rst = 1
            @tick sim 2
            sim.dut.rst = 0
        end
        @testbench function watch_reset(sim)
            c0 = sim.cycle
            rose = wait_edge(sim, :rst)
            c_rise = sim.cycle
            fell = wait_edge(sim, :rst; edge=:falling)
            return rose, fell, c_rise - c0, sim.cycle - c_rise
        end
        start_clock!(sim)
        within(10) do
            @test wait_edge(sim, :clk) == 0x01 && sim.clk_val == 0x01

            dut.step = 2
            old = dut.count
            @test wait_edge(sim, :count; edge=:change) == old + 2

            p = launch_pulse_reset(sim)
            rose, fell, to_rise, to_fall = fetch(launch_watch_reset(sim))
            wait(p)
            @test (rose, fell) == (0x01, 0x00)
            @test to_rise <= 4 && 1 <= to_fall <= 3

            dut.step = 0
            c0 = sim.cycle
            err = try wait_edge(sim, :count; edge=:change, max_cycles=4); nothing catch e; e end
            @test err isa WaitTimeout && err.cycle == c0 + 4
            @test occursin("a change of `count`", sprint(showerror, err))
        end
        @test_throws ArgumentError wait_edge(sim, :count)                 # 8 bits: needs :change
        @test_throws ArgumentError wait_edge(sim, :wide_out; edge=:falling)
        @test_throws ArgumentError wait_edge(sim, :rst; edge=:both)
        @test_throws ErrorException wait_edge(sim, :nope)
        stop_clock!(sim)
    end

    @testset "@test inside a testbench reports simulation time (mock design)" begin
        dut = MockDesign.make_dut()
        sim = Simulator(dut)
        @testbench function checker(sim)
            @tick sim 2
            @test sim.cycle >= 2
            @test sim.cycle == 1000                  # fails
            @test error("boom")                      # errors
        end
        start_clock!(sim)
        ts = redirect_stdout(devnull) do             # hide the expected error printout
            @testset Capture "captured" begin
                t = launch_checker(sim)              # launched inside the testset
                within(10) do
                    wait(t)
                end
            end
        end
        kinds = map(typeof, ts.results)
        @test kinds == [Test.Pass, Test.Fail, Test.Error]
        fail = ts.results[2]
        @test occursin("cycle 2, testbench `checker`", fail.context)
        @test occursin("simulation time 10", fail.context)   # first rising edge is at 0
        stop_clock!(sim)
    end

    @testset "Nested @testset inside a testbench (mock design)" begin
        dut = MockDesign.make_dut()
        sim = Simulator(dut)
        @testbench function grouped(sim)
            @tick sim
            @testset "group" begin
                @test true
                @tick sim
                @test sim.cycle == 1000              # fails
                @testset "subgroup $i" for i in 1:2
                    @test i > 0
                end
            end
        end
        start_clock!(sim)
        ts = @testset Capture "captured" begin
            t = launch_grouped(sim)
            within(10) do
                wait(t)
            end
        end
        @test length(ts.results) == 1                # the nested set, recorded once
        group = only(ts.results)
        @test group isa Capture && group.description == "group"
        kinds = map(typeof, group.results)
        @test kinds == [Test.Pass, Test.Fail, Capture, Capture]
        @test occursin("cycle 2, testbench `grouped`", group.results[2].context)
        @test [r.description for r in group.results[3:4]] == ["subgroup 1", "subgroup 2"]
        @test isempty(sim.participants)
        stop_clock!(sim)

        # The same with Julia's DefaultTestSet as the enclosing testset
        sim = Simulator(MockDesign.make_dut())
        @testbench function passes(sim)
            @tick sim
            @testset "inner" begin
                @test sim.cycle == 1
            end
        end
        start_clock!(sim)
        inner = nothing
        @testset "outer" begin
            t = launch_passes(sim)
            within(10) do
                wait(t)
            end
            inner = Test.get_testset().results[end]
        end
        @test inner isa Test.DefaultTestSet && inner.description == "inner"
        stop_clock!(sim)

        # A child testbench (launched by a testbench) with its own nested @testset
        sim = Simulator(MockDesign.make_dut())
        @testbench function child_group(sim)
            @tick sim
            @testset "child group" begin
                @test true
                @test sim.cycle == 1000              # fails
            end
        end
        @testbench function parent_tb(sim)
            wait(launch_child_group(sim))
        end
        start_clock!(sim)
        ts = @testset Capture "captured" begin
            t = launch_parent_tb(sim)
            within(10) do
                wait(t)
            end
        end
        group = only(ts.results)
        @test group isa Capture && group.description == "child group"
        @test map(typeof, group.results) == [Test.Pass, Test.Fail]
        @test occursin("testbench `child_group`", group.results[2].context)
        stop_clock!(sim)
    end

    @testset "A throwing testbench fails with TestbenchError (mock design)" begin
        dut = MockDesign.make_dut()
        sim = Simulator(dut)
        @testbench function crashes(sim)
            @tick sim 2
            error("boom")
        end
        @testbench function waits_for_crash(sim)
            @tick sim
            wait(launch_crashes(sim))
        end
        start_clock!(sim)
        err = within(10) do
            try wait(launch_crashes(sim)); nothing catch e; e end
        end
        @test err isa TaskFailedException
        tb = err.task.exception
        @test tb isa TestbenchError && tb.testbench == :crashes && tb.cycle == 2
        @test tb.error isa ErrorException && tb.error.msg == "boom"
        msg = sprint(showerror, tb)
        @test occursin("testbench `crashes` failed at simulation time 10 (cycle 2)", msg)
        @test occursin("boom", msg)

        # A parent passes its child's error on instead of wrapping it again
        err = within(10) do
            try wait(launch_waits_for_crash(sim)); nothing catch e; e end
        end
        @test err.task.exception isa TestbenchError && err.task.exception.testbench == :crashes
        @test isempty(sim.participants)
        stop_clock!(sim)
    end

    @testset "Coverage" begin
        cg = CoverGroup("inputs",
            :a => ["zero" => 0, "small" => 1:15, "large" => x -> x >= 16],
            :op => [:add, :sub];
            cross = [(:a, :op)])
        @test coverage(cg) == 0 && length(uncovered(cg)) == 3 + 2 + 6
        sample!(cg; a = 0, op = :add)
        sample!(cg, (a = 300, op = :sub))
        @test coverage(cg, :a) ≈ 2 / 3 && coverage(cg, :op) == 1
        @test coverage(cg) ≈ (2 + 2 + 2) / 11
        @test "a: small" in uncovered(cg) && "a × op: (small, :add)" in uncovered(cg)
        for a in (0, 5, 20), op in (:add, :sub)
            sample!(cg; a, op)
        end
        @test coverage(cg) == 1 && isempty(uncovered(cg)) && cg.samples == 8
        report = sprint(show, MIME"text/plain"(), cg)
        @test occursin("100.0% covered, 8 samples", report) && occursin("6 of 6 combinations", report)

        # A value can fall into several bins; all of them count
        overlap = CoverGroup("overlap", :x => ["low" => 0:10, "even" => iseven])
        sample!(overlap; x = 4)
        @test coverage(overlap) == 1

        @test bins(0:255, 4) == ["0:63" => 0:63, "64:127" => 64:127, "128:191" => 128:191, "192:255" => 192:255]
        @test bins(1:10, 3) == ["1:3" => 1:3, "4:6" => 4:6, "7:10" => 7:10]
        @test_throws ArgumentError bins(1:3, 5)
        @test_throws ArgumentError sample!(cg; a = 1)                  # `op` missing

        # A rejected sample changes nothing
        strict = CoverGroup("strict", :a => [1], :b => ["big" => x -> x > 0])
        @test_throws ArgumentError sample!(strict; a = 1)
        @test_throws MethodError sample!(strict; a = 1, b = "text")   # predicate throws
        @test coverage(strict) == 0 && strict.samples == 0
        @test_throws ArgumentError CoverGroup("bad", :x => [])
        @test_throws ArgumentError CoverGroup("bad", :x => [1, 1])
        @test_throws ArgumentError CoverGroup("bad", :x => [1]; cross = [(:x, :y)])
        @test_throws ArgumentError coverage(cg, :nope)

        withenv("VERIJUL_SEED" => "0x2a") do
            @test (@test_logs (:info, r"from VERIJUL_SEED") test_seed()) == 0x2a
        end
        withenv("VERIJUL_SEED" => nothing) do
            @test (@test_logs (:info, r"rerun with VERIJUL_SEED=0x") test_seed()) isa UInt64
        end
    end

    @testset "Scoreboard" begin
        sb = Scoreboard("demo")
        expect!(sb, 1, 2, 3)
        @test observe!(sb, 1) && !observe!(sb, 5) && observe!(sb, 3)
        @test !passed(sb) && sb.matched == 2
        observe!(sb, 9)                                            # nothing expected any more
        report = sprint(show, MIME"text/plain"(), sb)
        @test occursin("demo: 2 matched, 2 mismatched, 0 still expected", report)
        @test occursin("#2: expected 2, got 5", report)
        @test occursin("#4: got 9 but nothing was expected", report)

        sb2 = expect!(Scoreboard(; compare = (e, g) -> abs(e - g) <= 1), 10, 20, 30)
        observe!(sb2, 11); observe!(sb2, 19)
        @test !passed(sb2)                                         # 30 never seen
        @test occursin("never seen: 30", sprint(show, MIME"text/plain"(), sb2))
        observe!(sb2, 30)
        @test passed(sb2)
    end

    @testset "Stream components (mock design)" begin
        # `rst` serves as a valid signal without ready, `step` and `count` as data
        dut = MockDesign.make_dut()
        sim = Simulator(dut)
        start_clock!(sim)
        bus = StreamBus(data=:step, valid=:rst)
        @test_throws ArgumentError send!(sim, bus, [1]; idle=1.0)
        @test_throws ArgumentError send!(sim, bus, [1]; idle=-0.1)
        @test_throws ArgumentError receive!(sim, bus, 1; ready=0)
        @test_throws ArgumentError receive!(sim, bus, 1; ready=1.5)
        within(10) do
            send!(sim, bus, [3, 4, 5])                   # no ready: one word per cycle
            @test dut.rst == 0 && dut.step == 5
        end

        # A monitor whose callback fails reports it from stop!, even if it
        # finished before stop! was called
        mon = StreamMonitor(sim, StreamBus(data=:count, valid=:rst); on_item = x -> error("bad item"))
        dut.rst = 1
        within(10) do
            @tick sim 3
        end
        @test istaskdone(mon.task)
        err = try stop!(mon); nothing catch e; e end
        @test err isa TaskFailedException
        @test err.task.exception isa TestbenchError && err.task.exception.error.msg == "bad item"
        dut.rst = 0
        stop_clock!(sim)
    end

    @testset "Internal signals need internals=true (mock design)" begin
        dut = MockDesign.make_dut()
        err = try signal(dut, "count"); nothing catch e; e end
        @test err isa ErrorException && occursin("internals=true", err.msg)
        @test_throws ErrorException dut["count"]
        @test_throws ErrorException signals(dut)
        cpp, _ = generate_bindings([HardwarePort("clk", :in, 1)], "top"; internals=true,
                                   constants=["TOP.top.P"])
        @test occursin("top_signal_read", cpp) && occursin("verilated_vpi.h", cpp)
        @test occursin("\"TOP.top.P\",", cpp)

        # Constants are found in the generated headers, whatever VPI says about them
        dir = mktempdir()
        write(joinpath(dir, "Vtop___024root.h"), """
            class Vtop___024root {
                static const ::IData/*31:0*/ top__DOT__DEPTH;
                static constexpr CData/*7:0*/ top__DOT__u_sub__DOT__MODE = 3U;
                CData/*0:0*/ top__DOT__count;
                static const int notASignal;
            };
            """)
        write(joinpath(dir, "Other.h"), "static const IData top__DOT__IGNORED;")
        @test VeriJul.Builder.extract_constants(dir, "top") == ["TOP.top.DEPTH", "TOP.top.u_sub.MODE"]
        cpp, _ = generate_bindings([HardwarePort("clk", :in, 1)], "top")
        @test !occursin("vpi", cpp)
    end

    @testset "Aqua quality checks" begin
        Aqua.test_all(VeriJul)
    end

    if have_toolchain()
        @testset "Hardware: lower-level API (filter.v)" begin
            @test verilator_version() >= v"4.200"
            include("test_run.jl")
        end
        @testset "Hardware: DUT API (counter)" begin
            include("test_dut.jl")
        end
    else
        @warn "verilator or a C++ compiler not found; skipping hardware integration tests"
    end
end
