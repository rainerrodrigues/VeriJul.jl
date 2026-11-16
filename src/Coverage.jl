module Coverage

using Random: RandomDevice

export CoverGroup, sample!, coverage, uncovered, bins, test_seed

# A bin matches a value if the value is in it (ranges, sets, vectors,
# tuples), if a predicate returns true for it, or if it is equal to it.
bin_matches(m::Function, x) = m(x) === true
bin_matches(m::Union{AbstractRange,AbstractSet,AbstractVector,Tuple}, x) = x in m
bin_matches(m, x) = isequal(m, x)

struct CoverPoint
    name::Symbol
    labels::Vector{String}
    matchers::Vector{Any}
    hits::Vector{Int}
end

# Bins as given: `"label" => matcher` pairs, or plain values (each its own bin)
function CoverPoint(name::Symbol, spec)
    labels, matchers = String[], Any[]
    for b in spec
        if b isa Pair
            push!(labels, string(first(b))); push!(matchers, last(b))
        else
            push!(labels, repr(b)); push!(matchers, b)
        end
    end
    isempty(labels) && throw(ArgumentError("Cover point `$name` has no bins"))
    allunique(labels) || throw(ArgumentError("Cover point `$name` has duplicate bin names"))
    return CoverPoint(name, labels, matchers, zeros(Int, length(labels)))
end

struct CoverCross
    names::Vector{Symbol}
    hits::Array{Int}
end

"""
    CoverGroup(name, :point => bins, ...; cross=[])

Functional coverage: which interesting cases a test has actually exercised.
Each cover point names a value you [`sample!`](@ref VeriJul.Coverage.sample!)
and lists its bins. A bin is

- `"label" => matcher`, where the matcher is a range or collection
  (`0:15`, `[1, 2, 4]`), a predicate (`iseven`, `x -> x > 100`) or a value;
- or just a value, which is its own bin (`0`, `:read`).

[`bins`](@ref VeriJul.Coverage.bins) splits a range into equal bins.
`cross` lists tuples of point names whose *combinations* of bins should be
covered.

```julia
cg = CoverGroup("gcd inputs",
    :a => ["zero" => 0, "small" => 1:15, "large" => 16:65535],
    :b => ["zero" => 0, "small" => 1:15, "large" => 16:65535],
    :equal => [true, false];
    cross = [(:a, :b)])

sample!(cg; a = 12, b = 300, equal = false)
coverage(cg)      # fraction of bins hit, 0.0 to 1.0
uncovered(cg)     # what is still missing
```

A sample counts towards every bin it matches. Showing the group prints a
report with the hits per bin.
"""
mutable struct CoverGroup
    name::String
    points::Vector{CoverPoint}
    crosses::Vector{CoverCross}
    samples::Int
end

function CoverGroup(name::AbstractString, points::Pair{Symbol}...; cross=())
    ps = [CoverPoint(first(p), last(p)) for p in points]
    allunique(p.name for p in ps) || throw(ArgumentError("Duplicate cover point names"))
    crosses = CoverCross[]
    for c in cross
        names = collect(Symbol, c)
        length(names) >= 2 || throw(ArgumentError("A cross needs at least two cover points"))
        dims = map(names) do n
            i = findfirst(p -> p.name == n, ps)
            i === nothing && throw(ArgumentError("Cross refers to unknown cover point `$n`"))
            length(ps[i].labels)
        end
        push!(crosses, CoverCross(names, zeros(Int, dims...)))
    end
    return CoverGroup(String(name), ps, crosses, 0)
end

function point(cg::CoverGroup, n::Symbol)
    i = findfirst(p -> p.name == n, cg.points)
    i === nothing && throw(ArgumentError("No cover point named `$n`"))
    return cg.points[i]
end

"""
    sample!(cg; point=value, ...) -> cg
    sample!(cg, (point=value, ...)) -> cg

Records one sample: each named point's value is matched against its bins.
Every point of the group must be given.
"""
function sample!(cg::CoverGroup, values::NamedTuple)
    matched = Dict{Symbol,Vector{Int}}()
    for p in cg.points
        haskey(values, p.name) || throw(ArgumentError("sample! is missing cover point `$(p.name)`"))
        x = values[p.name]
        idx = [i for i in eachindex(p.matchers) if bin_matches(p.matchers[i], x)]
        for i in idx
            p.hits[i] += 1
        end
        matched[p.name] = idx
    end
    for c in cg.crosses
        for combo in Iterators.product((matched[n] for n in c.names)...)
            c.hits[combo...] += 1
        end
    end
    cg.samples += 1
    return cg
end
sample!(cg::CoverGroup; values...) = sample!(cg, NamedTuple(values))

"""
    coverage(cg) -> Float64
    coverage(cg, point) -> Float64

The fraction of bins (and cross combinations) that have been hit at least
once, from `0.0` to `1.0`; or the fraction for one cover point.
"""
function coverage(cg::CoverGroup)
    total = sum(length(p.hits) for p in cg.points; init=0) + sum(length(c.hits) for c in cg.crosses; init=0)
    hit = sum(count(>(0), p.hits) for p in cg.points; init=0) + sum(count(>(0), c.hits) for c in cg.crosses; init=0)
    return total == 0 ? 1.0 : hit / total
end
coverage(cg::CoverGroup, n::Symbol) = (p = point(cg, n); count(>(0), p.hits) / length(p.hits))

"""
    uncovered(cg) -> Vector{String}

Descriptions of the bins and cross combinations not hit yet, such as
`"a: zero"` or `"a × b: (zero, large)"`.
"""
function uncovered(cg::CoverGroup)
    out = String[]
    for p in cg.points, i in eachindex(p.hits)
        p.hits[i] == 0 && push!(out, "$(p.name): $(p.labels[i])")
    end
    for c in cg.crosses
        ps = [point(cg, n) for n in c.names]
        for I in CartesianIndices(c.hits)
            c.hits[I] == 0 || continue
            labels = [ps[k].labels[I[k]] for k in eachindex(ps)]
            push!(out, "$(join(c.names, " × ")): ($(join(labels, ", ")))")
        end
    end
    return out
end

"""
    bins(range, n) -> Vector{Pair{String,UnitRange}}

Splits `range` into `n` bins of (nearly) equal size, labelled by their
bounds: `bins(0:255, 4)` gives `"0:63" => 0:63`, …, `"192:255" => 192:255`.
"""
function bins(r::AbstractUnitRange{<:Integer}, n::Integer)
    1 <= n <= length(r) || throw(ArgumentError("need 1 ≤ n ≤ length(range)"))
    edges = [first(r) + div((length(r)) * k, n) for k in 0:n]
    return [string(edges[k], ":", edges[k+1] - 1) => edges[k]:edges[k+1]-1 for k in 1:n]
end

Base.show(io::IO, cg::CoverGroup) =
    print(io, "CoverGroup(", cg.name, ", ", round(100 * coverage(cg); digits=1), "% covered, ",
          cg.samples, " samples)")

function Base.show(io::IO, ::MIME"text/plain", cg::CoverGroup)
    show(io, cg)
    for p in cg.points
        print(io, "\n  ", p.name, ": ", round(100 * coverage(cg, p.name); digits=1), "%")
        w = maximum(length, p.labels)
        for i in eachindex(p.labels)
            print(io, "\n    ", rpad(p.labels[i], w), "  ", lpad(p.hits[i], 6), p.hits[i] == 0 ? "  ← not hit" : "")
        end
    end
    for c in cg.crosses
        n = count(>(0), c.hits)
        print(io, "\n  ", join(c.names, " × "), ": ", n, " of ", length(c.hits), " combinations hit")
    end
end

"""
    test_seed(; env="VERIJUL_SEED") -> UInt64

A seed for a test's random number generator, logged so a failing run can
be reproduced. Takes the seed from the environment variable `env` if it is
set, and picks a fresh random one otherwise.

```julia
using Random
rng = Xoshiro(test_seed())
# [ Info: Random seed 0x5f3a…; rerun with VERIJUL_SEED=0x5f3a… to reproduce
```

Pass the `rng` to everything random in the test (`rand(rng, …)`,
[`send!`](@ref VeriJul.Components.send!), …) so the whole run repeats.
"""
function test_seed(; env::AbstractString="VERIJUL_SEED")
    given = get(ENV, env, "")
    seed = isempty(given) ? rand(RandomDevice(), UInt64) : parse(UInt64, given)
    hex = "0x" * string(seed, base=16)
    @info isempty(given) ? "Random seed $hex; rerun with $env=$hex to reproduce" :
                           "Random seed $hex (from $env)"
    return seed
end

end
