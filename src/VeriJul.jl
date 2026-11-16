module VeriJul

include("Interop.jl")
include("Builder.jl")
include("Device.jl")
include("SimCore.jl")
include("DSL.jl")

# Re-export the user-facing tools
using .Interop: VerilatedModel, eval_step!, settle!, destroy!, enable_trace!
using .Builder: build_dut, HardwarePort
using .Device: DUT, load_dut, ports
using .SimCore: Simulator, start_clock!, stop_clock!, add_clock!, tick, reset!,
                wait_until, wait_edge, ClockStopped, TickTimeout, WaitTimeout, TestbenchError
using .DSL: @tick, @testbench, @wait_until

export load_dut, DUT, ports, HardwarePort, settle!, enable_trace!, destroy!,
       Simulator, start_clock!, stop_clock!, add_clock!, tick, reset!,
       wait_until, wait_edge, ClockStopped, TickTimeout, WaitTimeout, TestbenchError,
       @tick, @testbench, @wait_until,
       build_dut, VerilatedModel, eval_step!

end
