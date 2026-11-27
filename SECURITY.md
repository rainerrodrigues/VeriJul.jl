# Security Policy

## Supported versions

Security fixes go into the latest released version of VeriJul.jl. Older releases
are not patched; upgrade with `Pkg.update("VeriJul")`.

| Version | Supported |
| ------- | --------- |
| 0.2.x   | ✅        |
| < 0.2   | ❌        |

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub:
**Security → Report a vulnerability** on
[the repository page](https://github.com/rainerrodrigues/VeriJul.jl/security/advisories/new).
Don't open a public issue for a security problem.

Include the VeriJul, Julia and Verilator versions, what an attacker could do, and a
minimal way to reproduce it. You can expect an acknowledgement within a week. If the
report is confirmed, a fix and an advisory will be published together, and you'll
be credited unless you'd rather not be.

## Scope

VeriJul runs Verilator and a C++ compiler on the Verilog sources you give it, then
loads the resulting shared library into the Julia process. Building a design is
equivalent to running its code: only build designs you trust. Relevant reports
include build-cache or build-directory handling that could overwrite or delete
files outside the build directory, unsafe handling of generated code or tool
output, and issues in the CI workflows.
