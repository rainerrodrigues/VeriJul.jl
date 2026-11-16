```@meta
CurrentModule = VeriJul
```

# Random stimulus and coverage

Random inputs find bugs that hand-written tests miss, because they try
combinations nobody thought of. Two things make random testing practical:

1. **Reproducibility.** When a random test fails, you need to run exactly
   the same inputs again to debug it.
2. **Coverage.** Random doesn't mean thorough. You need to know which
   interesting cases the inputs actually hit, and which they never did.

This tutorial uses the GCD unit from [Waiting for events](@ref).

```@example cov
using VeriJul, Test, Random

dut = load_dut(joinpath(pkgdir(VeriJul), "examples", "gcd.v"), "gcd"; build_dir=mktempdir())
sim = Simulator(dut)
start_clock!(sim)
reset!(sim)

function run_gcd(sim, a, b)
    sim.dut.a = a; sim.dut.b = b; sim.dut.start = 1
    @tick sim
    sim.dut.start = 0
    cycles = @wait_until sim sim.dut.done == 1 max_cycles=100_000
    return sim.dut.result, cycles
end
nothing # hide
```

## Reproducible random numbers

Give each test its own random number generator, seeded by
[`test_seed`](@ref). It logs the seed, and takes it from the
`VERIJUL_SEED` environment variable when that is set, so a failing run can
be repeated exactly:

```@example cov
rng = Xoshiro(test_seed())
nothing # hide
```

Pass `rng` to everything random in the test: `rand(rng, ...)`, and the
`rng` keyword of [`send!`](@ref) and [`receive!`](@ref). Then a failure in CI
can be replayed on your machine with
`VERIJUL_SEED=0x… julia --project -e 'using Pkg; Pkg.test()'`, using the
seed from the log.

(This page uses a fixed seed, so it shows the same numbers every time it's
built.)

```@example cov
rng = Xoshiro(2024)
nothing # hide
```

## Describing what to cover

A [`CoverGroup`](@ref) lists the values to watch and sorts them into
*bins*: the cases that should each happen at least once. For the GCD unit,
interesting cases are zero inputs, small and large inputs, equal inputs,
and how long the computation took:

```@example cov
size_bins = ["zero" => 0, "one" => 1, "small" => 2:15, "medium" => 16:255, "large" => 256:65535]

cg = CoverGroup("gcd",
    :a => size_bins,
    :b => size_bins,
    :equal => [true, false],
    :cycles => ["fast" => 0:4, "normal" => 5:50, "slow" => x -> x > 50];
    cross = [(:a, :b)])          # every combination of a's and b's size
nothing # hide
```

A bin is `"label" => matcher`, where the matcher is a range or collection,
a predicate like `iseven`, or a single value, or just a value on its own.
[`bins`](@ref) splits a range into equal parts: `bins(0:255, 4)`.

## Sampling

Run random inputs and [`sample!`](@ref) each case:

```@example cov
@testset "random gcd" begin
    for _ in 1:100
        a, b = rand(rng, UInt16), rand(rng, UInt16)
        result, cycles = run_gcd(sim, a, b)
        @test result == gcd(a, b)
        sample!(cg; a, b, equal = a == b, cycles)
    end
end
coverage(cg)
```

Uniformly random 16-bit numbers are almost always "large", so 100 runs left
most of the plan untested. Showing the group gives the details:

```@example cov
show(stdout, MIME"text/plain"(), cg)
```

[`uncovered`](@ref) lists what's missing:

```@example cov
first(uncovered(cg), 8)
```

## Closing the gaps

Rather than more of the same, pick inputs that aim at what's missing.
Choosing a bin first and then a value inside it spreads the tests across
all the cases. Keep going until everything is covered, with a limit so the
loop always ends:

```@example cov
pick_size(rng) = rand(rng, (0:0, 1:1, 2:15, 16:255, 256:65535))

@testset "coverage-driven gcd" begin
    n = 0
    while coverage(cg) < 1 && n < 5_000
        a = rand(rng, pick_size(rng))
        b = rand(rng) < 0.1 ? a : rand(rng, pick_size(rng))     # sometimes equal
        result, cycles = run_gcd(sim, a, b)
        @test result == gcd(a, b)
        sample!(cg; a, b, equal = a == b, cycles)
        n += 1
    end
    @test coverage(cg) == 1
end
cg
```

Every bin and every size combination has now been tried at least once, and
the design matched Julia's `gcd` on all of them.

Coverage goals belong in the test itself: a `@test coverage(cg) == 1` at
the end fails the test run if a change to the stimulus quietly stops
reaching a case.

```@example cov
stop_clock!(sim) # hide
destroy!(dut) # hide
nothing # hide
```

Next: [Waveforms](@ref).
