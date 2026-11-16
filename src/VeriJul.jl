module VeriJul

include("Interop.jl")
include("Builder.jl")
include("Device.jl")
include("SimCore.jl")
include("DSL.jl")
include("Components.jl")
include("Coverage.jl")
include("Waves.jl")

# Re-export the user-facing tools
using .Interop: VerilatedModel, eval_step!, settle!, destroy!, enable_trace!
using .Builder: build_dut, HardwarePort
using .Device: DUT, load_dut, ports, Signal, signal, signals
using .SimCore: Simulator, start_clock!, stop_clock!, add_clock!, tick, reset!,
                wait_until, wait_edge, run!, ClockStopped, TickTimeout, WaitTimeout, TestbenchError
using .DSL: @tick, @testbench, @wait_until
using .Components: StreamBus, send!, receive!, StreamMonitor, stop!, Scoreboard, expect!, observe!, passed
using .Coverage: CoverGroup, sample!, coverage, uncovered, bins, test_seed
using .Waves: WaveRecorder, save_waves, stop_recording!

export load_dut, DUT, ports, HardwarePort, settle!, enable_trace!, destroy!,
       Simulator, start_clock!, stop_clock!, add_clock!, tick, reset!,
       wait_until, wait_edge, run!, ClockStopped, TickTimeout, WaitTimeout, TestbenchError,
       @tick, @testbench, @wait_until,
       Signal, signal, signals,
       StreamBus, send!, receive!, StreamMonitor, stop!, Scoreboard, expect!, observe!, passed,
       CoverGroup, sample!, coverage, uncovered, bins, test_seed,
       WaveRecorder, save_waves, stop_recording!,
       build_dut, VerilatedModel, eval_step!

include("precompile.jl")

end
