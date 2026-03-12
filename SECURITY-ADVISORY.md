# ACPI Firmware Security Advisory

## Vulnerability
ACPI Firmware Table Parsing and SPI Protection Weakness

## CVE ID
CVE-XXXX-XXXX (Reserved, to be determined pending Mitre/Lenovo CVE requests)

## Discoverer
Grant Scott Turner (Cyberian-Cherubim)

## Summary
A firmware security weakness affecting Lenovo Legion T5 26IRB8 systems
allows improper protection of firmware or ACPI table handling under
certain configurations. The issue may allow a local attacker with
privileged access to manipulate ACPI tables or SPI flash protection
settings, potentially enabling persistence or execution prior to OS
initialization.

## Affected Products
Vendor: Lenovo  
Product: Legion T5 26IRB8  
Chipset: Intel B660 / Alder Lake platform

## Affected Components
ACPI firmware tables  
Intel PCH SPI controller protections  
UEFI firmware configuration

## Attack Vector
An attacker with local administrative privileges can interact with
ACPI table interfaces or SPI controller registers. If firmware
protections are not properly enforced, malicious firmware or ACPI
tables could be introduced and executed during early boot.

## Impact
Security Feature Bypass  
Privilege Escalation  
Persistent Firmware Modification

## Technical Details
The issue relates to improper enforcement of SPI flash write
protections or ACPI namespace validation. Observed behavior indicates
that BIOS protection registers or firmware regions may be modifiable
from the operating system environment under certain circumstances.

Further investigation logs and analysis are available in this
repository.

## Mitigation
Update firmware when vendor patches become available.  
Restrict local administrative access.  
Enable Secure Boot and firmware protection mechanisms.

## References
https://github.com/cyberiancherubim/acpi-bughunt
https://en.wikipedia.org/wiki/ACPI
