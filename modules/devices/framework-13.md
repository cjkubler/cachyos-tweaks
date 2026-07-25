# Framework 13

Guidance and reversible fixes for the Framework Laptop 13 with AMD Ryzen
7040-series processors. Only applicable rows are actionable.

## Power and charging

- **power-profiles-daemon** uses the platform-supported profile and EPP path.
- **Charge limit** manages an EC-backed battery cap when the required Framework
  tooling is available.
- **Keyboard backlight restore** restores the recorded brightness after resume.

## Display, audio, and sleep

- **ABM color fix** addresses adaptive-backlight color behavior.
- **Panel Replay / PSR disable** is an opt-in diagnostic fix for panel flicker
  or resume freezes.
- **Headphone pops** and **rfkill before sleep** are symptom-specific workarounds.

## Networking and storage

- **Wi-Fi regulatory domain** makes an explicit country selection persistent.
- **MediaTek powersave** targets recurring RZ616/MT7922 disconnects.
- **Expansion-card UAS quirk** is limited to the affected storage-card path.

Prefer firmware updates and current kernels before applying symptom-specific
workarounds. The module descriptions state the exact applicability and tradeoff
for each row.
