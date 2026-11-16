# Precompile the common simulation paths, so the first simulation in a
# session starts quickly. The workload drives a tiny design written in
# Julia (exposed through C function pointers, like a Verilated model), so it
# needs neither Verilator nor a C++ compiler.

module PrecompileDesign

using ..Interop: VerilatedModel
using ..Builder: HardwarePort
using ..Device: DUT, PortHandle

mutable struct State
    clk::UInt8; prev::UInt8; rst::UInt8; data::UInt8; valid::UInt8; count::UInt16
    wide::Vector{UInt32}
end
const S = State(0, 0, 0, 0, 0, 0, zeros(UInt32, 3))

function eval_model(::Ptr{Cvoid}, ::UInt64)::Cvoid
    if S.clk == 1 && S.prev == 0
        S.count = S.rst == 1 ? 0x0000 : S.count + S.data
    end
    S.prev = S.clk
    return nothing
end
settle_model(::Ptr{Cvoid})::Cvoid = nothing
set_clk(::Ptr{Cvoid}, v::UInt8)::Cvoid = (S.clk = v; nothing)
set_rst(::Ptr{Cvoid}, v::UInt8)::Cvoid = (S.rst = v; nothing)
set_data(::Ptr{Cvoid}, v::UInt8)::Cvoid = (S.data = v; nothing)
set_valid(::Ptr{Cvoid}, v::UInt8)::Cvoid = (S.valid = v; nothing)
get_clk(::Ptr{Cvoid})::UInt8 = S.clk
get_rst(::Ptr{Cvoid})::UInt8 = S.rst
get_data(::Ptr{Cvoid})::UInt8 = S.data
get_valid(::Ptr{Cvoid})::UInt8 = S.valid
get_count(::Ptr{Cvoid})::UInt16 = S.count
function set_wide(::Ptr{Cvoid}, p::Ptr{UInt32})::Cvoid
    for i in 1:3; S.wide[i] = unsafe_load(p, i); end
    return nothing
end
function get_wide(::Ptr{Cvoid}, p::Ptr{UInt32})::Cvoid
    for i in 1:3; unsafe_store!(p, S.wide[i], i); end
    return nothing
end

function make_dut()
    model = VerilatedModel(Ptr{Cvoid}(1), @cfunction(eval_model, Cvoid, (Ptr{Cvoid}, UInt64)),
                           @cfunction(settle_model, Cvoid, (Ptr{Cvoid},)))
    specs = [
        ("clk", :in, 1, @cfunction(get_clk, UInt8, (Ptr{Cvoid},)), @cfunction(set_clk, Cvoid, (Ptr{Cvoid}, UInt8))),
        ("rst", :in, 1, @cfunction(get_rst, UInt8, (Ptr{Cvoid},)), @cfunction(set_rst, Cvoid, (Ptr{Cvoid}, UInt8))),
        ("data", :in, 8, @cfunction(get_data, UInt8, (Ptr{Cvoid},)), @cfunction(set_data, Cvoid, (Ptr{Cvoid}, UInt8))),
        ("valid", :in, 1, @cfunction(get_valid, UInt8, (Ptr{Cvoid},)), @cfunction(set_valid, Cvoid, (Ptr{Cvoid}, UInt8))),
        ("wide", :in, 70, @cfunction(get_wide, Cvoid, (Ptr{Cvoid}, Ptr{UInt32})), @cfunction(set_wide, Cvoid, (Ptr{Cvoid}, Ptr{UInt32}))),
        ("count", :out, 16, @cfunction(get_count, UInt16, (Ptr{Cvoid},)), C_NULL),
    ]
    handles = Dict{Symbol,PortHandle}(Symbol(n) => PortHandle(HardwarePort(n, d, w), g, s) for (n, d, w, g, s) in specs)
    return DUT(model, "precompile", "", handles, [Symbol(s[1]) for s in specs])
end

end

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    @compile_workload begin
        dut = PrecompileDesign.make_dut()
        sim = Simulator(dut)
        start_clock!(sim)
        reset!(sim)
        dut.data = 1
        dut.wide = big(2)^65 + 1
        dut.wide; dut.count
        tick(sim, 2)
        tick(sim; edge=:falling)
        wait_until(() -> dut.count >= 3, sim; max_cycles=10)
        wait_edge(sim, :count; edge=:change, max_cycles=4)
        @testbench function precompile_tb(sim, n)
            for _ in 1:n
                @tick sim
            end
            return sim.dut.count
        end
        fetch(launch_precompile_tb(sim, 3))
        send!(sim, StreamBus(data=:data, valid=:valid), [1, 2])
        stop_clock!(sim)
        run!(c -> (dut.data = c % 4), sim, 4)

        sb = expect!(Scoreboard("s"), 1, 2)
        observe!(sb, 1); observe!(sb, 2); passed(sb)
        sprint(show, MIME"text/plain"(), sb)
        cg = CoverGroup("c", :x => bins(0:255, 4), :y => [true, false]; cross=[(:x, :y)])
        sample!(cg; x = 10, y = true); coverage(cg); uncovered(cg)
        sprint(show, MIME"text/plain"(), cg)
    end
end
