# ACPI namespace collisions in Lenovo `TC-O5T` firmware tables trigger `AE_ALREADY_EXISTS`, USB metadata conflicts, and GPU `_DSM` aborts

## Summary

A Lenovo platform with ACPI tables identifying as `LENOVO TC-O5T` exhibits firmware-level ACPI namespace collisions during table loading and method evaluation on Linux. The failures are consistent with duplicate AML object definitions across DSDT and SSDT content, producing `AE_ALREADY_EXISTS` conditions in ACPICA.

Observed collisions include:

- root-scope helper methods `\GPLD` and `\GUPC`
- USB XHCI root hub objects under `\_SB.PC00.XHCI.RHUB.HSxx` and `SSxx`, involving `_UPC` and `_PLD`
- a GPU `_DSM` path under `\_SB.PC00.PEG1.PEGP` where creation of `USRG` fails and `_DSM` aborts

This is a firmware defect. Linux is surfacing it while interpreting vendor-supplied AML, not causing it. ACPI is the standard firmware interface used by operating systems to discover and configure hardware, and the DSDT and SSDTs together form a single ACPI namespace that must remain internally consistent. :contentReference[oaicite:0]{index=0}

## Severity

**Medium**

The current evidence supports a firmware correctness and reliability issue with potential downstream security implications where policy, topology, or device-state decisions rely on accurate ACPI metadata. This advisory does **not** currently claim direct code execution.

## Affected system

Confirmed on a Lenovo system whose extracted ACPI table headers identify:

- OEM / family string: `LENOVO TC-O5T`
- AML compiler stamp in extracted tables: `INTL 20200717`

Other systems shipping the same or closely related DSDT and SSDT set may also be affected.

## Affected environment

- Linux systems using ACPICA during ACPI table load and AML execution
- likely any OS environment that strictly rejects duplicate namespace object creation
- root cause resides in platform firmware AML, not user space

## Background

ACPI defines a firmware-to-OS interface through ACPI tables such as the RSDP, XSDT, FADT, DSDT, and SSDTs. The DSDT and SSDTs are definition blocks containing AML, and together they populate one hierarchical ACPI namespace. Duplicate or conflicting named objects in that namespace are invalid and may be rejected by the interpreter. Linux documents this model explicitly; the XSDT points to the FADT and SSDTs, the FADT points to the DSDT, and all definition blocks load into one namespace. :contentReference[oaicite:1]{index=1}

## Technical details

### 1. Duplicate root helper methods

Disassembly and grep evidence show the following methods in the extracted DSDT:

- `Method (GPLD, 2, Serialized)`
- `Method (GUPC, 2, Serialized)`

Cross-table resolution attempts then fail with duplicate object creation, including:

- `Failure creating named object [GPLD], AE_ALREADY_EXISTS`
- `Could not parse ACPI tables, AE_ALREADY_EXISTS`

This is consistent with the same or overlapping helper objects being defined more than once across the effective ACPI table set.

### 2. USB `_UPC` and `_PLD` conflicts under XHCI RHUB

The extracted DSL content shows extensive USB port definitions under:

- `\_SB.PC00.XHCI.RHUB.HS01` through `HS14`
- `\_SB.PC00.XHCI.RHUB.SS01` through `SS10`

The same evidence shows repeated use of `_UPC` and `_PLD` semantics for these ports. In ACPI, `_UPC` describes USB port capabilities and `_PLD` conveys physical location metadata. That metadata can matter to OS-side enumeration, port mapping, and policy decisions. Linux ACPI documentation notes that ACPI namespace data is converted into Linux device objects and linked into the kernel device tree. :contentReference[oaicite:2]{index=2}

If colliding objects are rejected, the OS may lose intended port metadata or accept only a partial namespace state.

### 3. GPU `_DSM` abort

Observed notes and extracted evidence identify a GPU control path under:

- `\_SB.PC00.PEG1.PEGP._DSM`

where creation of a field or object named `USRG` fails due to `AE_ALREADY_EXISTS`, causing `_DSM` to abort.

That behavior is consistent with an AML logic defect where a field is created more than once without a guard, or where overlapping namespace content causes runtime object creation to collide.

## Reproduction

### Extract the firmware tables

```bash
sudo acpidump > acpi_dump.txt
acpixtract -a acpi_dump.txt
