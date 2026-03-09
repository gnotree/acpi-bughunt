<<<<<<< HEAD
fb07f86 (HEAD -> main, origin/main) Organize ACPI artifacts and DSL disassembly
6a74208 (tag: v0.1-initial-disclosure) Initial disclosure: Lenovo ACPI namespace collision AE_ALREADY_EXISTS; USB RHUB and GPU _DSM artifacts
=======
# ACPI Namespace Collision Research

Research repository documenting reproducible ACPI namespace collisions observed
on a Lenovo platform.

The firmware exposes duplicate ACPI namespace objects which cause
ACPICA interpreter errors (AE_ALREADY_EXISTS) and abort certain hardware
methods during boot.

Current classification: firmware correctness defect with possible security relevance.

No privilege escalation or memory corruption has been demonstrated.

Contents:
- ACPI dumps
- DSL disassembly
- kernel logs
- reproduction steps
- analysis timeline

Researcher: Grant Scott Turner
>>>>>>> 1ef496e (Clean ignore rules and update ACPI disclosure artifacts)
