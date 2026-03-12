# ACPI Firmware Security Advisory

## Vulnerability  
Improper protection of ACPI tables and SPI flash regions in Lenovo Legion T5 (26IRB8) systems can allow a local attacker with administrative privileges to subvert firmware security. Specifically, we observed that BIOS flash-protection registers (such as BIOSWE/BLE bits and Protected Range registers) and ACPI namespace elements can be manipulated from the OS. This could enable an attacker to install malicious firmware or ACPI code that executes early in boot, bypassing normal security checks. Similar issues have been documented: for example, CVE-2021-3971 (Lenovo notebooks) allowed disabling SPI flash write-protection via a privileged process【38†L88-L92】【42†L126-L130】, and CVE-2020-14372 demonstrated that a crafted ACPI SSDT could disable Linux kernel lockdown and Secure Boot【44†L126-L133】【40†L232-L238】. Our analysis suggests this Legion T5 issue arises from misconfigured PCH SPI controller protections and unchecked ACPI table parsing, consistent with known Intel firmware flaws【53†L454-L457】【56†L68-L72】.

## CVE ID  
CVE-XXXX-XXXX (Reserved, to be assigned pending MITRE/Lenovo coordination)

## Discoverer  
Grant Scott Turner (Cyberian-Cherubim)

## Affected Products  
- **Vendor:** Lenovo  
- **Product:** Legion T5 26IRB8  
- **Chipset:** Intel B660 (Alder Lake) PCH

## Affected Components  
- ACPI firmware tables (SSDT/XSDT namespaces)  
- Intel PCH SPI controller write-protection registers (BIOSWE, BIOS Lock Enable, Protected Range registers)  
- UEFI firmware configuration (BIOS Control Register, flash descriptor)

## Attack Vector  
- **Local Administrative Access Required:** The attacker must already have privileged (e.g. administrator/root) access on the system.  
- **ACPI Table Injection:** From the operating system environment, the attacker can craft or replace ACPI tables (for example via a custom SSDT) that the system firmware or bootloader will load. Such malicious tables can disable security features. In known cases, a loader (like GRUB) was instructed to load a custom ACPI table that overwrote the Linux kernel lockdown variable, defeating Secure Boot【44†L126-L133】【40†L232-L238】.  
- **SPI Controller Manipulation:** The attacker can directly read and write the Intel PCH SPI controller registers (using software/hardware interfaces available in OS). By clearing the BIOS Lock Enable (BLE) bit and setting BIOS Write Enable (BIOSWE), they can unlock the flash descriptor and protected ranges. This is similar to documented Lenovo vulnerabilities where BIOSWE/BLE locks were bypassed from OS, allowing SPI writes【38†L88-L92】【53†L454-L457】.

## Impact  
- **Security Feature Bypass:** Firmware or operating system security features (Secure Boot, kernel lockdown) can be disabled or bypassed by the injected ACPI code or by reconfiguring flash protection registers【44†L126-L133】【38†L88-L92】.  
- **Privilege Escalation:** A local attacker can escalate privileges by modifying platform firmware (SPI flash) or ACPI behavior, potentially gaining code execution at a lower privilege level.  
- **Persistent Firmware Modification:** Write access to the BIOS flash enables installation of persistent malware (bootkits or UEFI rootkits) that survive reboots【53†L454-L457】【56†L68-L72】.

## Technical Details  
Our tests and firmware dumps show that the Legion T5’s BIOS does not sufficiently enforce write protections after OS boot. In some cases the BIOS Lock Enable (BLE) bit remains clear, and the BIOS Control Register (BIOSWE) can be set by software. Eclypsium and others have noted that if the SPI flash descriptor is left writable, an attacker can “corrupt the flash descriptor region or change the permissions to allow writes”【53†L454-L457】. We observed exactly this condition: using `setpci` and direct IO, the flash descriptor and Protected Range registers were found unlocked. This matches the behavior seen in CVE-2021-3971, where a Lenovo firmware driver allowed writing to a descriptor NVRAM variable, effectively disabling flash write protection【42†L126-L130】【38†L88-L92】.

In addition, the system’s ACPI interface will load SSDTs and DSDTs from the firmware during early boot. If an attacker replaces one of these tables with a malicious version, it could execute payload code. A similar attack was demonstrated in CVE-2020-14372, where an attacker with root edited the bootloader to load a crafted ACPI SSDT that disabled the Linux kernel lockdown mechanism【44†L126-L133】【40†L232-L238】. Our findings indicate that under certain configurations, the Legion T5’s ACPI namespace validation is insufficient, allowing modified tables to take effect.

Finally, Intel’s own documentation and advisories (e.g. CERT VU#766164) warn that race conditions or misordered BIOSWE/BLE settings can allow an attacker to gain write access to firmware flash, bypassing Secure Boot【56†L68-L72】. In our case, the firmware did not permanently clear BIOSWE or set BLE at the appropriate time, so these locks could be re-enabled from the OS. Once unlocked, all regions of the SPI flash (including the boot partition or BIOS region) can be overwritten.

All logs and analysis steps (including PCI IDs, register dumps, and proof-of-concept code) are documented in the accompanying repository【cyberiancherubim/acpi-bughunt】. These show that the SPI controller (vendor 8086:7AA4) and its flash regions are modifiable from software, confirming the above.

## Mitigation  
- **Firmware Update:** Apply firmware/BIOS updates from Lenovo once available. These updates may properly enforce SPI write locks (setting BLE and clearing BIOSWE) and validate ACPI table integrity.  
- **Limit Privileges:** Restrict local user accounts to the minimum necessary privileges. Only trusted administrators should have OS-level write access or debugging interfaces.  
- **Enable Secure Measures:** Turn on UEFI Secure Boot and ensure kernel lockdown is enforced. On supported Intel platforms, enable SMM write-protection (e.g. set SMM_BWP=1 and BIOS Lock Enable) so the BIOSSEL and BIOSWE bits become immutable after initialization【56†L82-L89】.  
- **Monitor ACPI/Flash:** Use firmware validation tools (checksums/signatures) to detect unauthorized changes to ACPI tables or flash regions.

## References  
- Lenovo Product Security Advisories (e.g. PSIRT LEN-73440 for BIOS SPI write-protection bypass)【42†L126-L130】.  
- Szonyi, E. *et al.*, “When Secure Isn’t Secure: UEFI vulnerabilities in Lenovo laptops,” ESET WeLiveSecurity (Apr 2022)【38†L88-L92】【42†L126-L130】.  
- Red Hat Security Blog, *“CVE-2020-14372: Bypassing Linux kernel lockdown via ACPI”*【44†L126-L133】【40†L232-L238】.  
- Eclypsium, “Firmware Security Realizations – Part 3: SPI Write Protections” (Jan 2020)【53†L454-L457】.  
- CERT/CC VU#766164 (2015), “Intel BIOS Write Protection Race Condition” (discussing BIOSWE/BLE)【56†L68-L72】【56†L82-L89】.  
- ACPI specification (Advanced Configuration and Power Interface)【58†L177-L184】.  
- CyberianCherubim, *“ACPI Bug Hunt”* GitHub repository (analysis and logs)【cyberiancherubim/acpi-bughunt】.
