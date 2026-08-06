# Magic SysRq keys

The Magic SysRq keys are handled directly by the kernel, so they keep working
when the desktop — or most of the kernel — is wedged. Which functions are
permitted is controlled by the `kernel.sysrq` bitmask. systemd ships a default
of `16` (sync only), and CachyOS keeps that default.

## Presets

These are mutually exclusive choices over one managed file.

### System default (sync only)

Leaves the policy alone (`kernel.sysrq = 16`). Selecting this after another
preset removes the suite's sysctl file and restores the exact recorded live
value.

### Emergency keys (REISUB)

Sets `kernel.sysrq = 244` — keyboard control (4), sync (16), read-only
remount (32), process termination (64), and reboot/poweroff (128). This is
the subset needed for the classic recovery sequence on a frozen machine:

> hold **Alt+SysRq**, then slowly type **R E I S U B**

which terminates processes, syncs and remounts disks read-only, and reboots
without losing filesystem consistency. Diagnostic functions stay disabled.

### All SysRq functions

Sets `kernel.sysrq = 1`, enabling everything: the emergency subset plus debug
dumps, console log-level control, OOM-killer invocation, and the rest. Useful
while debugging kernel or driver problems.

## Security note

SysRq functions are available to anyone with physical keyboard access (and on
some setups over serial consoles). On shared or kiosk machines, keep the
default.

## What changes

An applied preset records the current live value, installs
`/etc/sysctl.d/99-cachyos-tweaks-sysrq.conf`, and applies the value
immediately. Returning to **System default** removes the file and restores
the recorded value.

## References

- [Linux Magic SysRq documentation](https://docs.kernel.org/admin-guide/sysrq.html)
- [Arch Wiki: Magic SysRq key](https://wiki.archlinux.org/title/Keyboard_shortcuts#Kernel_(SysRq))
