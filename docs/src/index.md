```@meta
CurrentModule = VeriJul
```

# VeriJul.jl

VeriJul lets you write hardware testbenches in Julia. It compiles a Verilog
design with [Verilator](https://www.veripool.org/verilator/), gives you its
ports as ordinary Julia properties, and drives the simulation from Julia
tasks, so you can check hardware against reference models, random stimulus
and everything else in the Julia ecosystem.

```julia
using VeriJul

dut = load_dut("filter.v", "filter")      # build (cached) and load
sim = Simulator(dut)                      # drives the `clk` input
start_clock!(sim)

dut.in_data = 0xFF
@tick sim 6                               # wait for 6 rising edges
dut.out_data                              # 0xff
```

## Features

- **One-call builds** with build caching, multiple source files, include
  directories, `` `define``s and parameter overrides.
- **Named port access**: `dut.port = value` and `dut.port`, for any width,
  including ports wider than 64 bits (as `BigInt`).
- **Clocks and time**: multiple clocks with their own periods and phases,
  `@tick sim n`, reset helpers, and timeouts so a stuck testbench fails
  instead of hanging.
- **Testbenches**: concurrent `@testbench` tasks in lockstep with the clock,
  waiting for conditions and signal edges, `@test` with simulation times,
  and a fast task-free `run!` for simple loops.
- **Verification tools**: valid/ready stream drivers and monitors, a
  scoreboard, internal signal access, functional coverage and reproducible
  random seeds.
- **Waveforms**: VCD or FST traces, and a recorder that saves just the
  cycles before a failure.

## Requirements

- Julia 1.10 or newer
- Verilator 4.200 or newer on your `PATH` (or set `VERIJUL_VERILATOR` to its path)
- A C++17 compiler (`g++` or `clang++`; set `CXX` to pick one)

VeriJul is tested on Linux and macOS. **Windows is not supported**: the
build relies on a POSIX toolchain, and the Verilator package for Julia
(Verilator_jll) isn't built for Windows either. On Windows, use WSL2, where
VeriJul works as on Linux.

```bash
# Ubuntu / Debian
sudo apt-get install verilator g++
# macOS
brew install verilator
```

## Installation

```julia
using Pkg
Pkg.add("VeriJul")
```

## Where to go next

1. [Getting started](@ref) walks through building, driving and tracing a
   small filter.
2. [Self-checking testbenches](@ref) shows how to compare a design against
   a Julia reference model with `Test`.
3. [Waiting for events](@ref) waits for conditions and signal edges in
   designs whose latency varies, with cycle limits.
4. [Testing with Test.jl](@ref) runs `@test` inside concurrent testbenches,
   with failures that report the simulation time.
5. [Streams and scoreboards](@ref) drives and checks valid/ready interfaces
   with random gaps and backpressure.
6. [Internal signals](@ref) reads and writes signals inside the design.
7. [Random stimulus and coverage](@ref) makes random tests reproducible and
   measures which cases they hit.
8. [Waveforms](@ref) writes VCD and FST traces, and records just the cycles
   before a failure.
9. [Build options and multiple clocks](@ref) covers multi-file designs,
   parameters, defines and clock domains.
10. [Ports and wide signals](@ref) explains port types, truncation and ports
   wider than 64 bits.

[Examples](@ref) has complete designs with testbenches, including a UART
and an AXI-Stream filter. [Performance](@ref) explains when to use `run!`
instead of tasks. To keep building and loading as separate steps, see
[Lower-level API](@ref).
