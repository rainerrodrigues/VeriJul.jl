```@meta
CurrentModule = VeriJul
```

# Lower-level API

[`load_dut`](@ref) builds a design and loads it in one step. The two steps
are also available separately, for example to build once in a setup script
and load the library in several processes:

```julia
lib = build_dut("filter.v", "filter")    # compile (cached); returns the library path
dut = DUT(lib, "filter")                 # load it
```

[`build_dut`](@ref) takes the same keywords as `load_dut` and returns the
path of the compiled shared library. `DUT(lib, top)` reads the port list
from the Verilator header next to the library and loads it. Each `DUT` has
its own copy of the model, so a library can be loaded any number of times.

## What a build contains

Each build directory holds the Verilator output, a generated C++ shim
(`wrapper.cpp`) and the shared library. The shim gives the model a plain C
interface:

| C function | Used for |
|:--|:--|
| `top_create`, `top_destroy` | creating and freeing a model (each with its own `VerilatedContext`) |
| `top_eval`, `top_settle` | evaluating, with and without a waveform sample |
| `top_enable_trace`, `top_trace_format` | waveform output |
| `get_<port>`, `set_<port>` | reading every port, writing inputs |
| `top_signal…` | internal signals (only with `internals=true`) |

[`generate_bindings`](@ref VeriJul.Builder.generate_bindings) shows the
generated code for a list of ports.

## The bare model

[`VerilatedModel`](@ref) is the loaded library without named ports.
[`Simulator`](@ref) works on one too, driving clocks through the library's
`set_<clock>` functions, which is all that some tools built on VeriJul
need:

```julia
m = VerilatedModel(lib)
sim = Simulator(m)
```

`VeriJul.Device.model(dut)` returns a `DUT`'s model.

## Simulator fields

`sim.rising_edge` and `sim.falling_edge` are events for the main clock:
`wait(sim.rising_edge)` waits for the next rising edge, just like
`tick(sim)`, and throws [`ClockStopped`](@ref) when the clock isn't
running. `sim.clk_val` is the main clock's current value, `sim.time` the
time of the last edge and `sim.cycle` the number of rising edges so far.
