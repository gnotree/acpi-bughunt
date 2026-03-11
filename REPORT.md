# Technical Report: ACPI Namespace Collisions (Sanitized)

## Executive summary
A Lenovo firmware build defining ACPI tables for platform string `LENOVO TC-O5T` exhibits duplicate namespace objects. During OS boot the ACPI interpreter raises `AE_ALREADY_EXISTS` while creating helper methods (`\GPLD`, `\GUPC`), USB root-hub metadata objects (`_UPC`, `_PLD` under `\_SB.PC00.XHCI.RHUB.HSxx/SSxx`), and a buffer field in a GPU `_DSM` method (`\_SB.PC00.PEG1.PEGP._DSM.USRG`). The behavior indicates a firmware correctness defect; no privilege escalation or memory-corruption primitive has been demonstrated.

## Vendor troubleshooting snapshot (identifiers redacted where unique)
- **Platform / DMI:** Lenovo TC-O5T (tag `R3J4G*** / 3769`; format retained, unique characters masked).
- **BIOS:** O5TKT3EA dated 2025-09-18.
- **CPU:** 13th Gen Intel Core i5-13400F.
- **Kernel:** Linux 6.12.0-124.40.1.el10_1.x86_64 with Secure Boot enabled; ACPI revision 2.0 (RSDP at `0x758FB014`).
- **Critical table observation:** XSDT pointed to the same SSDT twice (`0x75835000` and `0x75831000`, size `0x0039DA`), causing redundant AML loading and namespace collisions during the catalog phase.

### Failure category A: static table-load namespace collisions
- `AE_ALREADY_EXISTS` while creating `\GPLD` and `\GUPC` during table load, followed by duplicate `_UPC/_PLD` objects under `_SB.PC00.XHCI.RHUB.HS01–HS14` and `SS01–SS07`.
- ACPICA output showed skipped AML and `OpcodeName unavailable` near the end of `SS07`, indicating the parser abandoned duplicated sections and left port metadata incomplete.

### Failure category B: runtime idempotency bug in GPU `_DSM`
- Path: `_SB.PC00.PEG1.PEGP._DSM`.
- Symptom: `CreateBufferField` for `USRG` executed on every invocation; because the named object persists in the namespace, subsequent callers hit `AE_ALREADY_EXISTS` (ACPI core 20240827 at `dswload2-477`) and the method aborts.
- Observation timing: repeats in the log (e.g., around `16:49:35`), consistent with multiple subsystem callers such as GPU driver probes and pcieport services.

### Correlation with PCIe AER events
- Root port `0000:00:01.0` (PEG1) hosting GPU `0000:01:00.0` reported AER with IRQ 121.
- Abort of the PEGP `_DSM` leaves firmware-managed GPU state undefined during pcieport attachment, a known trigger for spurious AER and link-training instability.

### Actionable remediation for OEM firmware
- Remove the duplicate SSDT pointer from the XSDT so that only one copy of the AML binary is loaded.
- Make the PEGP `_DSM` idempotent (e.g., guard `USRG` with `CondRefOf` or convert the field to a local buffer).
- Centralize single definitions of `\GPLD` and `\GUPC` in DSDT and strip any redundant declarations from ancillary SSDTs.

## Evidence (summarized, raw data removed)
- Prior disassembly identified `Method (GPLD, 2, Serialized)` and `Method (GUPC, 2, Serialized)` at root scope, referenced throughout XHCI RHUB port devices.
- Boot logs recorded repeated `AE_ALREADY_EXISTS` errors for `_UPC` and `_PLD` objects across HSxx/SSxx ports and for `USRG` within the PEGP `_DSM`, causing method aborts.
- Table headers showed compiler ID `INTL 20200717` and OEM string `LENOVO TC-O5T`; raw headers and dumps have been purged.

## Impact assessment
- **Correctness/reliability:** Duplicate ACPI objects are rejected, potentially dropping USB port capability/physical-location metadata and aborting GPU-specific behavior.
- **Security relevance:** Currently indirect; loss of accurate metadata could affect policy enforcement that depends on ACPI-sourced topology, but no direct exploit chain is known.

## Redaction notes
All raw artifacts (ACPI dumps, kernel logs, hardware inventories, screenshots, MSDM content) were removed to protect host-specific identifiers and keys. Only high-level summaries remain. Researchers should keep full evidence privately when engaging with vendors.

## Reproduction guidance (execute privately)
1. Capture boot logs on the target platform and filter for `AE_ALREADY_EXISTS`.
2. Dump ACPI tables with `acpidump` and split using `acpixtract`.
3. Disassemble with `iasl -d dsdt.dat ssdt*.dat`.
4. Confirm duplicate definitions or repeated `Create*Field` operations for the objects listed above.

## Next steps for vendors or reviewers
- Validate table generation pipelines for duplicate definitions across DSDT/SSDT sets.
- Provide firmware updates that remove overlapping objects or make runtime methods idempotent.
- Request private access to the redacted evidence if additional confirmation is required.
