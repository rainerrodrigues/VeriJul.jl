module Waves

using ..Device: DUT, Signal, signal, ports
using ..SimCore: SimCore, Simulator

export WaveRecorder, save_waves, stop_recording!

"""
    WaveRecorder(sim; cycles=1000, signals=nothing, dir=nothing, max_files=5)

Keeps the last `cycles` clock cycles of signal values in memory, so that
when something goes wrong you get a small waveform of just the moments
before it, even in a run of millions of cycles.

- `signals`: what to record. By default all ports. Give a list of port
  names (`:count`) and, for designs loaded with `internals=true`, internal
  signal names (`"u_core.state"`).
- `dir`: when set, the recorder saves a VCD file there by itself whenever a
  [`@testbench`](@ref VeriJul.DSL.@testbench) task fails or a `@test` inside
  one fails, and logs the file's path. At most `max_files` files are written.

Save the window at any time with [`save_waves`](@ref VeriJul.Waves.save_waves),
and stop recording with [`stop_recording!`](@ref VeriJul.Waves.stop_recording!).

```julia
rec = WaveRecorder(sim; cycles=200, dir="failures")
# ... run the test; a failure writes failures/failure_1.vcd ...
```

The recorder samples after every evaluation (every clock edge), so it costs
a little time per edge; [`enable_trace!`](@ref VeriJul.Interop.enable_trace!)
records everything instead, for the whole run.
"""
mutable struct WaveRecorder
    sim::Simulator
    cycles::Int
    names::Vector{String}
    widths::Vector{Int}
    readers::Vector{Any}            # () -> value, one per signal
    times::Vector{Int64}
    cycle_of::Vector{Int64}         # sim.cycle at each sample
    values::Vector{Vector{BigInt}}  # one vector per sample
    dir::Union{String,Nothing}
    max_files::Int
    saved::Vector{String}
end

function WaveRecorder(sim::Simulator; cycles::Integer=1000, signals=nothing,
                      dir::Union{AbstractString,Nothing}=nothing, max_files::Integer=5)
    cycles > 0 || throw(ArgumentError("cycles must be positive"))
    dut = sim.dut
    dut isa DUT || error("WaveRecorder needs a Simulator built from a DUT (see load_dut)")
    names, widths, readers = String[], Int[], Any[]
    for s in something(signals, [Symbol(p.name) for p in ports(dut)])
        if s isa Symbol
            p = findfirst(p -> p.name == String(s), ports(dut))
            p === nothing && error("Design has no port named `$s`")
            push!(names, String(s)); push!(widths, ports(dut)[p].width)
            push!(readers, () -> getproperty(dut, s))
        else
            sig = signal(dut, String(s))
            push!(names, String(s)); push!(widths, sig.width)
            push!(readers, () -> sig[])
        end
    end
    rec = WaveRecorder(sim, cycles, names, widths, readers, Int64[], Int64[], Vector{BigInt}[],
                       dir === nothing ? nothing : String(dir), max_files, String[])
    push!(sim.hooks, rec)
    return rec
end


function SimCore.on_evaluate(rec::WaveRecorder, sim::Simulator)
    push!(rec.times, sim.time)
    push!(rec.cycle_of, sim.cycle)
    push!(rec.values, BigInt[big(r()) for r in rec.readers])
    # Drop samples older than the window
    while !isempty(rec.cycle_of) && rec.cycle_of[1] <= sim.cycle - rec.cycles
        popfirst!(rec.times); popfirst!(rec.cycle_of); popfirst!(rec.values)
    end
    return nothing
end

function SimCore.on_failure(rec::WaveRecorder, sim::Simulator, err)
    dir = rec.dir                    # a local, so the `nothing` check narrows its type
    dir === nothing && return nothing
    length(rec.saved) >= rec.max_files && return nothing
    isempty(rec.times) && return nothing
    mkpath(dir)
    path = joinpath(dir, "failure_$(length(rec.saved) + 1).vcd")
    save_waves(rec, path)
    push!(rec.saved, path)
    @info "Saved the last $(rec.cycles) cycles before the failure (time $(sim.time)) to $path"
    return nothing
end

"""
    save_waves(rec, path) -> path

Writes the recorded window to a VCD file that any waveform viewer
(GTKWave, Surfer, …) opens.
"""
function save_waves(rec::WaveRecorder, path::AbstractString)
    top = getfield(rec.sim.dut, :top)
    ids = [vcd_id(i) for i in eachindex(rec.names)]
    open(path, "w") do io
        println(io, "\$date ", Libc.strftime("%Y-%m-%d %H:%M:%S", time()), " \$end")
        println(io, "\$version VeriJul WaveRecorder \$end")
        println(io, "\$comment last $(rec.cycles) cycles up to time $(isempty(rec.times) ? 0 : last(rec.times)) \$end")
        println(io, "\$timescale 1ps \$end")
        println(io, "\$scope module ", top, " \$end")
        for (i, n) in enumerate(rec.names)
            w = rec.widths[i]
            # Hierarchical names become nested scopes in most viewers; keep them flat
            println(io, "\$var wire ", w, " ", ids[i], " ", replace(n, "." => "_"),
                    w > 1 ? " [$(w - 1):0]" : "", " \$end")
        end
        println(io, "\$upscope \$end")
        println(io, "\$enddefinitions \$end")
        prev = nothing
        for (k, t) in enumerate(rec.times)
            vals = rec.values[k]
            println(io, "#", t)
            prev === nothing && println(io, "\$dumpvars")
            for i in eachindex(vals)
                (prev === nothing || prev[i] != vals[i]) || continue
                w = rec.widths[i]
                println(io, w == 1 ? string(vals[i] & 1, ids[i]) :
                            string("b", string(vals[i], base=2), " ", ids[i]))
            end
            prev === nothing && println(io, "\$end")
            prev = vals
        end
    end
    return path
end

# VCD identifiers: printable ASCII from '!' to '~', in base 94
function vcd_id(i::Integer)
    i -= 1
    s = Char[]
    while true
        push!(s, Char(33 + i % 94))
        i = i ÷ 94 - 1
        i < 0 && break
    end
    return String(s)
end

"""
    stop_recording!(rec)

Stops the recorder. What it recorded can still be saved.
"""
function stop_recording!(rec::WaveRecorder)
    filter!(h -> h !== rec, rec.sim.hooks)
    return rec
end

Base.show(io::IO, rec::WaveRecorder) =
    print(io, "WaveRecorder(", length(rec.names), " signals, last ", rec.cycles, " cycles, ",
          length(rec.times), " samples)")

end
