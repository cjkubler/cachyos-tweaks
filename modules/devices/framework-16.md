# Framework 16

Guidance and reversible fixes for the Framework Laptop 16 with AMD Ryzen
7040HS processors and the optional RX 7700S graphics module.

## Start with firmware

Use the BIOS guidance action before applying workarounds. Firmware and kernel
updates can make a workaround unnecessary, and keeping an LTS kernel available
provides a useful fallback for graphics regressions.

## Power, graphics, and display

- **power-profiles-daemon** uses the supported platform-profile and EPP path.
- **GTK renderer policy** avoids waking the discrete GPU for affected GTK
  applications.
- **Panel Replay / PSR disable** is an opt-in flicker workaround.
- **amdgpu runtime-PM off** is a high-cost escape hatch for a specific
  resume/disconnect failure, not a general performance setting.

## Input, networking, and sleep

The module includes targeted input-module permissions, Wi-Fi regulatory and
MediaTek stability choices, sleep input quirks, charge limiting, and keyboard
backlight restoration. Applicability checks hide or disable choices that do not
match installed hardware.

Read each live description before staging: several fixes exchange battery life
or power management for stability.
