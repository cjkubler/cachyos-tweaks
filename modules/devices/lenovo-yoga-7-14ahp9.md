# Lenovo Yoga 7 14AHP9

Reversible fixes and guidance for the Ryzen 7 8840HS Yoga 7 14AHP9.

## Input and convertible behavior

- **Disable touchpad while the lid is closed** prevents ghost input and restores
  only devices the hook inhibited itself.
- **Accelerometer / auto-rotate** is an opt-in sensor workaround.
- The fingerprint and BIOS actions are read-only guidance tailored to detected
  hardware.

## Power, display, and firmware

- **Battery conservation** controls the firmware-backed charge cap.
- **Panel Replay / PSR disable** is an opt-in flicker or resume workaround.
- **Silent WMI boot errors** is cosmetic and should only be used when the
  described messages match.

## Wireless

Realtek and MediaTek rows have separate applicability checks. Powersave or ASPM
workarounds trade power use for stability and should be selected only for the
matching adapter and symptom. The Bluetooth autosuspend choice similarly
targets devices that fail at boot or after resume.

Use the details pane for the current status, affected files, and specific
tradeoffs before staging a change.
