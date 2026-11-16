# Integration test for load_dut / DUT / multi-clock simulation on real Verilator builds.

examples = joinpath(dirname(@__DIR__), "examples")
counter_srcs = [joinpath(examples, "counter", "counter.v"), joinpath(examples, "counter", "inverter.v")]
counter_inc = [joinpath(examples, "counter", "include")]
build_root = mktempdir()

@testset "Build options and caching" begin
    dir = joinpath(build_root, "counter")
    dut = load_dut(counter_srcs, "counter"; build_dir=dir, include_dirs=counter_inc)
    lib = getfield(dut, :lib_path)
    mtime1 = mtime(lib)

    # Unchanged design: no rebuild
    lib2, _ = build_dut(counter_srcs, "counter"; build_dir=dir, include_dirs=counter_inc)
    @test lib2 == lib && mtime(lib2) == mtime1

    # force=true rebuilds into a new library file, so a design that is still
    # loaded can't make dlopen hand back the old code
    lib3, _ = build_dut(counter_srcs, "counter"; build_dir=dir, include_dirs=counter_inc, force=true)
    @test lib3 != lib && isfile(lib3) && !isfile(lib)
    fresh = load_dut(counter_srcs, "counter"; build_dir=dir, include_dirs=counter_inc)
    @test getfield(fresh, :lib_path) == lib3          # cache now points at the new build
    settle!(fresh); settle!(dut)                       # old and new both still work
    @test fresh.init_val == 7 && dut.init_val == 7
    destroy!(fresh)

    # Parameters and defines change the build
    dut12 = load_dut(counter_srcs, "counter"; build_dir=joinpath(build_root, "counter12"),
                     include_dirs=counter_inc, parameters=Dict("WIDTH" => 12),
                     defines=Dict("INIT_VAL" => "8'd42"))
    @test Dict(p.name => p.width for p in ports(dut12))["count"] == 12
    settle!(dut); settle!(dut12)
    @test dut.init_val == 7
    @test dut12.init_val == 42

    @test_throws ErrorException build_dut(counter_srcs, "counter"; build_dir=dir)  # missing include dir
    destroy!(dut12)
    destroy!(dut)
end

@testset "Ports, clocks, reset and waveforms" begin
    dut = load_dut(counter_srcs, "counter"; build_dir=joinpath(build_root, "counter"),
                   include_dirs=counter_inc)
    vcd = joinpath(build_root, "counter.vcd")
    enable_trace!(dut, vcd)

    sim = Simulator(dut)
    add_clock!(sim, :clk_slow; half_period=15)
    start_clock!(sim)
    reset!(sim)
    @test dut.count == 0 && dut.slow_count == 0

    dut.step = 3
    @tick sim 4
    @test dut.count == 12

    before = dut.slow_count
    @tick sim 3 clock=:clk_slow
    @test dut.slow_count == before + 3

    x = big(2)^99 + big(2)^70 + 0xabcdef
    dut.wide_in = x
    @tick sim
    @test dut.wide_in == x
    @test dut.wide_out == (big(2)^100 - 1) ⊻ x
    @test dut.upper === UInt64(x >> 36)

    @test_throws ErrorException dut.count = 1
    stop_clock!(sim)
    destroy!(dut)
    @test filesize(vcd) > 0
end

@testset "Two designs at once" begin
    filt = load_dut(joinpath(examples, "filter.v"), "filter"; build_dir=joinpath(build_root, "filter"))
    cnt = load_dut(counter_srcs, "counter"; build_dir=joinpath(build_root, "counter"),
                   include_dirs=counter_inc)
    fsim, csim = Simulator(filt), Simulator(cnt)
    start_clock!(fsim); start_clock!(csim)
    reset!(csim)
    filt.in_data = 0xFF
    cnt.step = 1
    @tick fsim 6
    @tick csim 2
    @test filt.out_data == 0xFF
    @test cnt.count >= 2
    stop_clock!(fsim); stop_clock!(csim)
    destroy!(filt); destroy!(cnt)
end

@testset "Reloading and duplicate models" begin
    # Each model has its own context, so a second model of the same design can
    # be created while the first is mid-simulation (and after it is destroyed,
    # even where the OS keeps the library loaded).
    args = (counter_srcs, "counter")
    kw = (build_dir=joinpath(build_root, "counter"), include_dirs=counter_inc)
    a = load_dut(args...; kw...)
    asim = Simulator(a); start_clock!(asim); reset!(asim)
    a.step = 1
    @tick asim 3
    stop_clock!(asim)
    @test a.count == 3 && asim.time > 0

    # Created while `a` is alive at a non-zero time
    b = load_dut(args...; kw...)
    bsim = Simulator(b); start_clock!(bsim); reset!(bsim)
    b.step = 2
    @tick bsim 2
    stop_clock!(bsim)
    @test b.count == 4
    @test a.count == 3                              # independent state
    destroy!(a); destroy!(b)

    c = load_dut(args...; kw...)
    @test c.count isa UInt8
    destroy!(c)
end

@testset "Default build location" begin
    # Without build_dir nothing is written to the working directory
    work = mktempdir()
    dut = cd(work) do
        load_dut(counter_srcs, "counter"; include_dirs=counter_inc)
    end
    @test isempty(readdir(work))
    lib = getfield(dut, :lib_path)
    @test startswith(lib, VeriJul.Builder.build_cache())
    @test isfile(joinpath(dirname(lib), VeriJul.Builder.BUILD_MARKER))

    # Cached: the same design loads from the same library
    again = load_dut(counter_srcs, "counter"; include_dirs=counter_inc)
    @test getfield(again, :lib_path) == lib
    # Different options get their own folder
    other = load_dut(counter_srcs, "counter"; include_dirs=counter_inc, parameters=Dict("WIDTH" => 4))
    @test dirname(getfield(other, :lib_path)) != dirname(lib)
    foreach(destroy!, (dut, again, other))

    # A user's non-empty directory is refused, and its files survive
    users = mktempdir()
    write(joinpath(users, "notes.txt"), "keep me")
    @test_throws ErrorException build_dut(counter_srcs, "counter"; include_dirs=counter_inc, build_dir=users)
    @test readdir(users) == ["notes.txt"]
end

@testset "Parallel builds of the same design" begin
    # Two Julia processes build into one directory at once: the lock makes the
    # second wait and reuse the first's build instead of deleting its files.
    dir = joinpath(mktempdir(), "shared")
    script = """
    using VeriJul
    lib, _ = build_dut($(repr(counter_srcs)), "counter"; build_dir=$(repr(dir)),
                       include_dirs=$(repr(counter_inc)))
    dut = VeriJul.Device.DUT(lib, "counter",
                             VeriJul.Builder.extract_ports(joinpath(dirname(lib), "Vcounter.h")))
    settle!(dut)
    dut.init_val == 7 || error("bad build")
    println(lib)
    """
    julia = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $script`
    outs = [IOBuffer() for _ in 1:2]
    procs = [run(pipeline(julia; stdout=o, stderr=o); wait=false) for o in outs]
    foreach(wait, procs)
    for (p, o) in zip(procs, outs)
        success(p) || println(String(take!(copy(o))))
        @test success(p)
    end
    libs = [last(split(strip(String(take!(o))), '\n')) for o in outs]
    @test libs[1] == libs[2]                           # one build, reused by the other
end

@testset "Lockstep: sleeping between ticks never skips an edge" begin
    dut = load_dut(joinpath(examples, "filter.v"), "filter"; build_dir=joinpath(build_root, "filter_lockstep"))
    sim = Simulator(dut)
    start_clock!(sim)
    dut.in_data = 0
    @tick sim 6                              # flush the history
    dut.in_data = 0xFF
    times, outs = Int[], Int[]
    for _ in 1:6
        @tick sim
        push!(times, sim.time); push!(outs, dut.out_data)
        sleep(0.002)                         # used to let ~1000 cycles slip by
    end
    stop_clock!(sim)
    destroy!(dut)
    @test all(==(10), diff(times))
    @test outs == [0, 63, 127, 191, 255, 255]
end

@testset "Waiting for events and @test in testbenches (gcd.v)" begin
    dut = load_dut(joinpath(examples, "gcd.v"), "gcd"; build_dir=joinpath(build_root, "gcd"))
    sim = Simulator(dut)
    start_clock!(sim)
    reset!(sim)

    function start!(sim, a, b)
        sim.dut.a = a; sim.dut.b = b; sim.dut.start = 1
        @tick sim
        sim.dut.start = 0
    end

    # Latency depends on the inputs; @wait_until returns the edges waited
    start!(sim, 48, 18)
    n1 = @wait_until sim dut.done == 1 max_cycles=100
    @test dut.result == 6
    start!(sim, 1000, 3)
    n2 = @wait_until sim dut.done == 1 max_cycles=1000
    @test dut.result == 1 && n2 > n1

    start!(sim, 12, 8)
    @test wait_edge(sim, :busy; edge=:falling, max_cycles=100) == 0
    @test dut.done == 1 && dut.result == 4

    @tick sim
    @test_throws WaitTimeout wait_edge(sim, :done; max_cycles=20)    # nothing started

    # Driver and checker testbenches; the checks land in this testset
    @testbench function driver(sim, jobs, pairs)
        for (a, b) in pairs
            put!(jobs, (a, b))
            start!(sim, a, b)
            @wait_until sim sim.dut.done == 1 max_cycles=5000
        end
        close(jobs)
    end
    @testbench function checker(sim, jobs, results)
        for (a, b) in jobs
            wait_edge(sim, :done; max_cycles=5000)
            push!(results, Int(sim.dut.result) == gcd(a, b))
            @test sim.dut.result == gcd(a, b)
        end
    end
    pairs = [(a, b) for a in (7, 64, 255) for b in (1, 12, 81)]
    jobs, results = Channel{Tuple{Int,Int}}(Inf), Bool[]
    d = launch_driver(sim, jobs, pairs)
    c = launch_checker(sim, jobs, results)
    wait(d); wait(c)
    @test length(results) == length(pairs) && all(results)

    stop_clock!(sim)
    destroy!(dut)
end

@testset "Internal signals, streams, scoreboard and coverage (fifo.v)" begin
    dut = load_dut(joinpath(examples, "fifo.v"), "fifo"; internals=true,
                   build_dir=joinpath(build_root, "fifo"))
    names = signals(dut)
    @test all(n -> n in names, ["count", "rd_ptr", "wr_ptr", "s_ready", "m_data"])
    cnt = signal(dut, "count")
    @test cnt.width == 3 && sprint(show, cnt) == "Signal(count, 3 bits)"
    @test_throws ErrorException signal(dut, "no_such_signal")
    @test signal(dut, "TOP.fifo.wr_ptr").width == 2               # full VPI names work too

    sim = Simulator(dut)
    start_clock!(sim)
    reset!(sim)
    @test cnt[] == 0 && dut["count"] == 0

    inp = StreamBus(data=:s_data, valid=:s_valid, ready=:s_ready)
    out = StreamBus(data=:m_data, valid=:m_valid, ready=:m_ready)

    # Fill it with nobody reading: it holds DEPTH words, then stops accepting
    send!(sim, inp, [0x11, 0x22, 0x33, 0x44])
    @test cnt[] == 4 && dut.s_ready == 0
    @test_throws WaitTimeout send!(sim, inp, [0x55]; max_cycles=5)
    @test dut.s_valid == 0                                        # left low, even after an error
    @test receive!(sim, out, 4) == [0x11, 0x22, 0x33, 0x44]
    @test cnt[] == 0 && dut.m_ready == 0
    @test_throws WaitTimeout receive!(sim, out, 1; max_cycles=5)

    # Random gaps and backpressure, checked by a monitor and a scoreboard,
    # with coverage of the internal occupancy
    rng = Random.Xoshiro(7)
    data = rand(rng, UInt8, 60)
    sb = expect!(Scoreboard("fifo"; sim), data...)
    mon = StreamMonitor(sim, out; on_item = x -> observe!(sb, x))
    cg = CoverGroup("occupancy", :count => 0:4, :full => [true, false]; cross=[(:count, :full)])
    @testbench function sample_occupancy(sim, cg, done)
        while !done[]
            @tick sim
            sample!(cg; count = Int(cnt[]), full = sim.dut.s_ready == 0)
        end
    end
    @testbench tx(sim, data, rng) = send!(sim, inp, data; idle=0.3, rng)
    @testbench rx(sim, n, rng) = receive!(sim, out, n; ready=0.4, rng)
    done = Ref(false)
    s = launch_sample_occupancy(sim, cg, done)
    t = launch_tx(sim, data, rng)
    r = launch_rx(sim, length(data), rng)
    wait(t)
    @test fetch(r) == data
    @tick sim
    done[] = true
    wait(s)
    @test stop!(mon) == data && length(mon.times) == length(data) && issorted(mon.times)
    @test passed(sb) && sb.matched == length(data)
    @test coverage(cg, :count) == 1                               # empty through full
    @test "count × full: (0, true)" in uncovered(cg)              # impossible combinations stay open

    # Writing an internal signal deposits a value until the logic changes it
    dut["count"] = 2
    @test cnt[] == 2 && dut.m_valid == 0                          # outputs update at the next evaluation
    settle!(dut)
    @test dut.m_valid == 1
    reset!(sim)
    @test cnt[] == 0
    @test_throws ErrorException signal(dut, "DEPTH")[] = 8        # parameters can't be written

    stop_clock!(sim)
    destroy!(dut)
end
