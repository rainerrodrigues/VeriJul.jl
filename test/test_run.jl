# Integration test: the lower-level API. Build filter.v with build_dut, load
# the library with DUT(lib, top), and drive a Simulator built on the bare
# VerilatedModel. Included from runtests.jl inside a @testset.

project_root = dirname(@__DIR__)
verilog_file = joinpath(project_root, "examples", "filter.v")
build_dir = mktempdir()

lib = VeriJul.Builder.build_dut(verilog_file, "filter"; build_dir=build_dir)
@test lib isa String && isfile(lib)
@test VeriJul.Builder.build_dut(verilog_file, "filter"; build_dir=build_dir) == lib   # cached

dut = DUT(lib, "filter")
@test [p.name for p in ports(dut)] == ["clk", "in_data", "out_data"]
vcd_path = joinpath(build_dir, "waveform.vcd")
@test_throws ErrorException enable_trace!(dut, joinpath(build_dir, "waveform.fst"))  # built for VCD
enable_trace!(dut, vcd_path)
@test dut.out_data == 0x00

# A Simulator on the bare model drives the clock through the library's setter
sim = Simulator(VeriJul.Device.model(dut))
start_clock!(sim)
@test_throws ErrorException start_clock!(sim)   # double-start is rejected

outputs = UInt8[]
dut.in_data = 0xFF                 # hold long enough to fill the 4-tap pipeline and output register
for _ in 1:6
    @tick sim
    push!(outputs, dut.out_data)
end
@test outputs[end] == 0xFF
@test issorted(outputs)            # the moving average ramps up monotonically
@test any(<(0xFF), outputs)        # ...and isn't instantly at full scale

dut.in_data = 0
@tick sim 6
@test dut.out_data == 0x00

stop_clock!(sim)
@test sim.clock_task === nothing && sim.time > 0

destroy!(dut)
@test isfile(vcd_path) && filesize(vcd_path) > 0
