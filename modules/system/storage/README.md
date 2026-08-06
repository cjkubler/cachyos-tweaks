# Storage maintenance

## Periodic TRIM

`fstrim.timer` runs `fstrim` weekly on every mounted filesystem that supports
discard. TRIM tells SSDs and other thinly provisioned storage which blocks
are no longer in use, letting the firmware manage wear-leveling and keep
write performance stable.

CachyOS installations normally ship with the timer already enabled; it then
shows as **external** here and needs nothing from you. The toggle exists for
setups where it was disabled or removed.

Enabling records the prior timer state; turning the toggle off restores
exactly that state. Periodic TRIM is the generally recommended approach —
continuous discard via the `discard` mount option can cost performance on
some drives.

## References

- [Arch Wiki: Solid state drive — TRIM](https://wiki.archlinux.org/title/Solid_state_drive#TRIM)
- [fstrim(8)](https://man7.org/linux/man-pages/man8/fstrim.8.html)
