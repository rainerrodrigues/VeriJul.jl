```@meta
CurrentModule = VeriJul
```

# API

## Loading designs

```@docs
load_dut
DUT
ports
settle!
enable_trace!
destroy!
```

## Simulation

```@docs
Simulator
add_clock!
start_clock!
stop_clock!
tick
@tick
reset!
run!
```

## Waiting and testing

```@docs
wait_until
@wait_until
wait_edge
@testbench
VeriJul.SimCore.launch
WaitTimeout
TestbenchError
ClockStopped
TickTimeout
```

## Verification components

```@docs
StreamBus
send!
receive!
StreamMonitor
stop!
Scoreboard
expect!
observe!
passed
```

## Internal signal access

```@docs
signal
signals
Signal
```

## Waveform recording

```@docs
WaveRecorder
save_waves
stop_recording!
```

## Coverage and random stimulus

```@docs
CoverGroup
sample!
coverage
uncovered
bins
test_seed
```

## Building

```@docs
build_dut
VeriJul.Builder.clear_build_cache
VeriJul.Builder.verilator_cmd
VeriJul.Builder.verilator_version
HardwarePort
VeriJul.Builder.extract_ports
VeriJul.Builder.generate_bindings
```

## Low-level model access

```@docs
VerilatedModel
eval_step!
VeriJul.SimCore.EdgeEvent
```
