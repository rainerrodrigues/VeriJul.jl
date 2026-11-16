module Device

using Libdl
using ..Interop
using ..Interop: VerilatedModel, read_port, write_port, check_alive, nwords, words_to_int, int_to_words
using ..Builder: Builder, HardwarePort, build_dut, extract_ports

export DUT, load_dut, ports, Signal, signal, signals

struct PortHandle
    port::HardwarePort
    get_ptr::Ptr{Cvoid}
    set_ptr::Ptr{Cvoid}   # C_NULL for outputs
end

"""
    DUT

A loaded hardware design. Read and write its ports as properties:

```julia
dut.in_data = 0x42      # set an input (truncated to the port width)
dut.out_data            # read an output (or an input)
```

Ports up to 64 bits read back as `UInt8`/`UInt16`/`UInt32`/`UInt64`; wider
ports read back as `BigInt` and accept any `Integer`.

Create one with [`load_dut`](@ref VeriJul.Device.load_dut). List its ports
with [`ports`](@ref VeriJul.Device.ports).
"""
struct DUT
    model::VerilatedModel
    top::String
    lib_path::String
    handles::Dict{Symbol,PortHandle}
    order::Vector{Symbol}
end

function DUT(lib_path::AbstractString, top::AbstractString, port_list::Vector{HardwarePort})
    model = VerilatedModel(lib_path)
    handles = Dict{Symbol,PortHandle}()
    for p in port_list
        get_ptr = Libdl.dlsym(model.lib_handle, Symbol("get_", p.name); throw_error=false)
        get_ptr === nothing && error("Library $lib_path has no getter for port `$(p.name)`. ",
                                     "It was probably built by an older VeriJul; rebuild with force=true.")
        set_ptr = p.direction == :in ? Libdl.dlsym(model.lib_handle, Symbol("set_", p.name)) : C_NULL
        handles[Symbol(p.name)] = PortHandle(p, get_ptr, set_ptr)
    end
    return DUT(model, String(top), String(lib_path), handles, [Symbol(p.name) for p in port_list])
end

"""
    load_dut(sources, top_module; kwargs...) -> DUT

Builds the design (or reuses a cached build) and loads it. Takes the same
keywords as [`build_dut`](@ref VeriJul.Builder.build_dut): `build_dir`,
`include_dirs`, `defines`, `parameters`, `verilator_args`, `internals`,
`force`, `verbose`. With `internals=true`, internal signals can be read and
written too (see [`signal`](@ref VeriJul.Device.signal)).

```julia
dut = load_dut("filter.v", "filter")
dut.in_data = 0xFF
```

By default the build goes into VeriJul's build cache, one folder per design
and set of options, so nothing is written to the current directory.
"""
function load_dut(sources, top_module::AbstractString;
                  build_dir::Union{AbstractString,Nothing}=nothing, kwargs...)
    lib, _ = build_dut(sources, top_module; build_dir=build_dir, kwargs...)
    header = joinpath(dirname(lib), "V$(top_module).h")
    return DUT(lib, top_module, extract_ports(header))
end

handle(d::DUT, name::Symbol) =
    get(getfield(d, :handles), name) do
        error("Design `$(getfield(d, :top))` has no port named `$name`. Ports: ",
              join(getfield(d, :order), ", "))
    end

function Base.getproperty(d::DUT, name::Symbol)
    h = handle(d, name)
    return read_port(h.get_ptr, getfield(d, :model), h.port.width)
end

function Base.setproperty!(d::DUT, name::Symbol, val::Integer)
    h = handle(d, name)
    h.port.direction == :in || error("Port `$name` is an output and cannot be written")
    write_port(h.set_ptr, getfield(d, :model), h.port.width, val)
    return val
end

Base.setproperty!(d::DUT, name::Symbol, val) =
    throw(ArgumentError("Port values must be integers (or Bool), got $(typeof(val))"))

Base.propertynames(d::DUT, private::Bool=false) = Tuple(getfield(d, :order))

"""
    ports(dut) -> Vector{HardwarePort}

The design's top-level ports, in declaration order.
"""
ports(d::DUT) = [getfield(d, :handles)[n].port for n in getfield(d, :order)]

# ---------------------------------------------------------------------------
# Internal signals (designs built with internals=true)

"""
    Signal

A handle to a signal anywhere in the design hierarchy, from
[`signal`](@ref VeriJul.Device.signal). Read it with `sig[]` and write it
with `sig[] = value`. Values have the same types as ports: `UInt8` to
`UInt64` up to 64 bits, `BigInt` above.
"""
struct Signal
    dut::DUT
    name::String          # as given, relative to the top module
    handle::Ptr{Cvoid}
    width::Int
    writable::Bool        # false for parameters
end

# VPI object types (from vpi_user.h)
const VPI_PARAMETER = 41
const VPI_NET = 36
const VPI_REG = 48

function vpi_function(d::DUT, sym::Symbol)
    lib = model(d).lib_handle
    f = lib == C_NULL ? nothing : Libdl.dlsym(lib, sym; throw_error=false)
    f === nothing && error("Design `$(getfield(d, :top))` was built without internal signal access. ",
                           "Load it with load_dut(...; internals=true).")
    return f
end

# Hierarchical names are relative to the top module ("u_core.state");
# full VPI names ("TOP.top.u_core.state") are accepted as well.
vpi_name(d::DUT, name::AbstractString) =
    startswith(name, "TOP.") ? String(name) : "TOP.$(getfield(d, :top)).$name"

"""
    signal(dut, name) -> Signal

Looks up a signal anywhere in the design by its hierarchical name, relative
to the top module: `"count"`, `"u_core.state"`, `"inv.y"`. The design must
be loaded with `load_dut(...; internals=true)`. [`signals`](@ref VeriJul.Device.signals)
lists the names.

```julia
dut = load_dut("fifo.v", "fifo"; internals=true)
occupancy = signal(dut, "count")
occupancy[]          # read
occupancy[] = 0      # write
```

`dut["count"]` and `dut["count"] = 0` are shorthand for one-off access;
keep the `Signal` when reading the same signal often, since the lookup is
the slow part. Parameters can be read but not written; arrays and memories
(`reg [7:0] mem [0:3]`) are listed by `signals` but can't be accessed yet.

A write deposits a value: it holds until the design's own logic next
assigns the signal (for a register, typically the next clock edge). Call
[`settle!`](@ref VeriJul.Interop.settle!) to update logic that depends on
it before the next edge.
"""
function signal(d::DUT, name::AbstractString)
    f = vpi_function(d, :top_signal)
    m = check_alive(model(d))
    h = ccall(f, Ptr{Cvoid}, (Ptr{Cvoid}, Cstring), m.ptr, vpi_name(d, name))
    h == C_NULL && error("Design `$(getfield(d, :top))` has no signal named `$name`. ",
                         "List them with signals(dut).")
    kind = ccall(vpi_function(d, :top_signal_type), Int32, (Ptr{Cvoid}, Ptr{Cvoid}), m.ptr, h)
    kind in (VPI_REG, VPI_NET, VPI_PARAMETER) ||
        error("`$name` is an array or memory, not a single signal; its elements can't be accessed yet")
    width = ccall(vpi_function(d, :top_signal_width), Int32, (Ptr{Cvoid}, Ptr{Cvoid}), m.ptr, h)
    return Signal(d, String(name), h, Int(width), kind != VPI_PARAMETER)
end

"""
    signals(dut) -> Vector{String}

The hierarchical names of all signals in the design (ports included),
relative to the top module, for use with [`signal`](@ref VeriJul.Device.signal).
Needs a design loaded with `internals=true`.
"""
function signals(d::DUT)
    f = vpi_function(d, :top_signal_names)
    p = ccall(f, Cstring, (Ptr{Cvoid},), check_alive(model(d)).ptr)
    prefix = "TOP.$(getfield(d, :top))."
    return [String(startswith(n, prefix) ? n[length(prefix)+1:end] : n)
            for n in split(unsafe_string(p), '\n'; keepempty=false)]
end

function Base.getindex(s::Signal)
    m = check_alive(model(s.dut))
    buf = zeros(UInt32, nwords(s.width))
    ccall(vpi_function(s.dut, :top_signal_read), Cvoid,
          (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt32}, Int32), m.ptr, s.handle, buf, length(buf))
    s.width > 64 && return words_to_int(buf)
    v = UInt64(buf[1]) | (length(buf) > 1 ? UInt64(buf[2]) << 32 : UInt64(0))
    s.width <= 8  && return v % UInt8
    s.width <= 16 && return v % UInt16
    s.width <= 32 && return v % UInt32
    return v
end

function Base.setindex!(s::Signal, val::Integer)
    s.writable || error("`$(s.name)` is a parameter and can't be written")
    m = check_alive(model(s.dut))
    buf = int_to_words(val, s.width)
    err = ccall(vpi_function(s.dut, :top_signal_write), Int32,
                (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt32}, Int32), m.ptr, s.handle, buf, length(buf))
    err == 0 || error("Could not write signal `$(s.name)`")
    return s
end

Base.show(io::IO, s::Signal) = print(io, "Signal(", s.name, ", ", s.width, s.width == 1 ? " bit)" : " bits)")

Base.getindex(d::DUT, name::AbstractString) = signal(d, name)[]
function Base.setindex!(d::DUT, val::Integer, name::AbstractString)
    signal(d, name)[] = val
    return d
end

# The underlying VerilatedModel
model(d::DUT) = getfield(d, :model)

Interop.settle!(d::DUT) = (Interop.settle!(model(d)); d)
Interop.enable_trace!(d::DUT, filename::AbstractString) = (Interop.enable_trace!(model(d), filename); d)
Interop.destroy!(d::DUT) = Interop.destroy!(model(d))

function Base.show(io::IO, d::DUT)
    alive = model(d).ptr != C_NULL
    print(io, "DUT(", getfield(d, :top), ", ", length(getfield(d, :order)), " ports",
          alive ? "" : ", destroyed", ")")
end

function Base.show(io::IO, ::MIME"text/plain", d::DUT)
    show(io, d)
    for p in ports(d)
        print(io, "\n  ", rpad(p.direction == :in ? "input" : "output", 7), " ",
              rpad(p.name, 16), " ", p.width, p.width == 1 ? " bit" : " bits")
    end
end

end
