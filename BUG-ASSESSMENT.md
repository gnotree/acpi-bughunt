# ACPI Firmware Bug Assessment (CORRECTED)

## Classification

**This is a firmware quality defect (bug), NOT a security vulnerability.**

## Issue Summary

Lenovo Legion T5 26IRB8 firmware contains ACPI namespace collisions that cause `AE_ALREADY_EXISTS` errors during system boot. This is a firmware coding error in ACPI table generation, not a security vulnerability.

## Severity

**Medium** - Correctness/reliability defect with potential downstream impact where policy relies on accurate ACPI metadata. No code execution or privilege escalation is demonstrated or possible.

## Technical Description

### Root Cause
The firmware's XSDT table contains duplicate pointers to the same SSDT, causing the same AML (ACPI Machine Language) bytecode to be loaded twice. This creates namespace collisions when the ACPI interpreter tries to define objects that already exist.

### Observed Failures

1. **Static table-load collisions**:
   - Duplicate definitions of helper methods `\GPLD` and `\GUPC` at root scope
   - Duplicate USB port metadata objects `_UPC` and `_PLD` under `\_SB.PC00.XHCI.RHUB.HSxx/SSxx` devices

2. **Runtime idempotency bug**:
   - GPU `_DSM` method at `\_SB.PC00.PEG1.PEGP._DSM` creates buffer field `USRG` on each invocation
   - Subsequent calls fail with `AE_ALREADY_EXISTS` because the field persists in namespace
   - Method aborts, leaving GPU firmware state undefined

3. **Correlated hardware issues**:
   - PCIe AER (Advanced Error Reporting) events on root port 0000:00:01.0
   - Timing correlates with `_DSM` failures during GPU initialization
   - Suggests firmware-managed GPU state not being applied correctly

## Impact

### Functional Impact
- **USB port metadata loss**: Operating system may not receive correct USB capability and physical location data
- **GPU initialization issues**: Abort of GPU `_DSM` method may cause improper hardware configuration
- **Device initialization quirks**: Incomplete ACPI data may affect device enumeration and power management
- **Boot log noise**: Multiple ACPICA errors logged during each boot

### Security Impact
**None directly demonstrated.**

Potential indirect impact:
- If OS security policy depends on accurate USB port physical location metadata, loss of this data could theoretically affect access control decisions
- However, this is speculative and no concrete attack scenario has been identified

## Why This Is NOT a CVE

### No Exploit Primitive
- No code execution capability
- No privilege escalation path
- No memory corruption
- No unauthorized access to resources

### No Security Boundary Violated
- The bug exists entirely within firmware code executed with firmware privileges
- No attacker-controlled input influences the collision
- No privilege boundary is crossed

### Limitations Explicitly Documented
From LIMITATIONS.md:
1. "No exploit primitive has been demonstrated."
2. "No direct privilege escalation or arbitrary code execution path has been proven."
3. "Some impact statements remain inferential until validated by additional OS-level instrumentation or vendor confirmation."

## Affected Products

**Vendor:** Lenovo
**Product:** Legion T5 26IRB8
**Platform String:** LENOVO TC-O5T
**BIOS:** O5TKT3EA dated 2025-09-18
**ACPI Compiler:** INTL 20200717
**Chipset:** Intel B660 (Alder Lake) PCH

## Remediation

### For Users
1. **Check for BIOS updates** from Lenovo support
2. **Monitor boot logs** for persistent ACPI errors
3. **Report issues** to Lenovo if USB devices or GPU behave unexpectedly

### For Lenovo (Firmware Developers)
1. **Remove duplicate SSDT pointer** from XSDT so only one copy of AML is loaded
2. **Make GPU `_DSM` idempotent**: Guard `USRG` field creation with `CondRefOf` or use local buffer
3. **Centralize helper definitions**: Define `\GPLD` and `\GUPC` once in DSDT, remove from SSDTs
4. **Add build-time validation**: Check for namespace collisions in firmware build pipeline

## Disclosure Path

### Correct Approach
- Report to **Lenovo Product Support** as a firmware quality issue
- Provide sanitized ACPI dumps and boot logs
- Request BIOS update through normal support channels

### Incorrect Approach
- ❌ Do NOT report to Lenovo PSIRT (Product Security Incident Response Team)
- ❌ Do NOT request CVE assignment from MITRE
- ❌ Do NOT file GitHub Security Advisory (GHSA)
- ❌ Do NOT claim this is a security vulnerability in public disclosures

## Historical Precedent

From TIMELINE.md:
> "2018; Lenovo published a support notice acknowledging duplicate USB ACPI object definitions causing `AE_ALREADY_EXISTS` class errors on certain systems."

This confirms:
- Lenovo has encountered this class of bug before
- It was handled as a **quality/support issue**, not a security vulnerability
- No CVE was assigned for previous similar instances

## Comparison with Real Security Issues

### This Issue (Bug)
- ACPI namespace collisions from firmware coding error
- No attacker involvement
- No exploitation possible
- Impact: Device metadata reliability

### Unrelated Actual CVEs (Referenced Incorrectly in Original SECURITY-ADVISORY.md)

**CVE-2021-3971** - Lenovo SPI Flash Write-Protection Bypass:
- Allowed disabling write-protection via privileged process
- Enabled persistent firmware modification
- Required attacker with admin privileges
- **Completely different issue**

**CVE-2020-14372** - GRUB ACPI Table Loading Vulnerability:
- Allowed loading malicious ACPI SSDT via bootloader
- Disabled Linux kernel lockdown and Secure Boot
- Required attacker with root access and control of bootloader
- **Completely different issue**

The original SECURITY-ADVISORY.md incorrectly conflated this namespace collision bug with these unrelated vulnerabilities.

## Conclusion

**Classification:** Firmware quality defect (bug)
**CVE Assignment:** Not warranted
**Severity:** Medium (reliability/correctness)
**Security Impact:** None direct; speculative indirect impact only
**Disclosure:** Standard vendor bug report, not security disclosure

## Evidence

See the following files in this repository:
- `REPORT.md` - Detailed technical analysis
- `EVIDENCE.md` - Summarized observations (raw data removed for privacy)
- `ADVISORY.md` - Impact and reproduction guidance
- `GHSA-DRAFT.md` - Generic advisory template (use only if vendor confirms security impact)
- `LIMITATIONS.md` - Explicit statement of what was NOT found

## Credit

Independent researcher (identity withheld for privacy)

## Notes on Repository Cleanup

The original `SECURITY-ADVISORY.md` file contains incorrect security claims that should be disregarded:
- It falsely claims SPI flash protection bypass capability
- It references unrelated CVEs as if they were connected to this bug
- It describes attack scenarios that are not applicable to namespace collisions
- It should be removed or replaced with this corrected assessment

The accurate technical documentation is found in ADVISORY.md, REPORT.md, and EVIDENCE.md.
