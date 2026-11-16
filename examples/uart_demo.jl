# Send text through the UART transmitter in examples/uart_tx.v and decode the
# serial line in Julia. Run with:  julia --project=. examples/uart_demo.jl
using VeriJul

const CLKS_PER_BIT = 4

dut = load_dut(joinpath(@__DIR__, "uart_tx.v"), "uart_tx";
               parameters=Dict("CLKS_PER_BIT" => CLKS_PER_BIT), build_dir=mktempdir())
sim = Simulator(dut)
start_clock!(sim)
reset!(sim)

# A UART receiver: find the start bit, then sample each bit in its middle
function receive_byte(sim)
    wait_edge(sim, :tx; edge=:falling)
    tick(sim, CLKS_PER_BIT ÷ 2)
    byte = 0x00
    for i in 0:7
        tick(sim, CLKS_PER_BIT)
        byte |= UInt8(sim.dut.tx) << i
    end
    tick(sim, CLKS_PER_BIT)                 # stop bit
    return byte
end

message = "Hello from Verilog!"
@testbench sender(sim, bytes) = send!(sim, StreamBus(data=:data, valid=:valid, ready=:ready), bytes)
@testbench receiver(sim, n) = String([receive_byte(sim) for _ in 1:n])

r = launch_receiver(sim, ncodeunits(message))     # listen before anything is sent
s = launch_sender(sim, codeunits(message))
wait(s)
println("received: ", fetch(r), "  (", sim.cycle, " cycles)")

stop_clock!(sim)
destroy!(dut)
