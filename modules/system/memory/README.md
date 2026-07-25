# Memory and swap

These presets change how readily Linux moves anonymous application memory to
swap. They are workload choices, not universal performance upgrades.

## Before choosing

Use **Inspect memory and swap** in the module. It reports available RAM, active
swap devices and priorities, zram statistics, and the virtual-memory values
managed here.

## Presets

### CachyOS defaults

Leaves memory policy to CachyOS. This is the safest baseline and the recommended
starting point.

### Keep application memory resident

Sets `vm.swappiness=60` and `vm.page-cluster=0`. This can suit systems with
ample RAM and latency-sensitive applications, but under pressure it may reclaim
useful file cache sooner and make stalls sharper.

### Favor compressed-swap capacity

Sets `vm.swappiness=180` and `vm.page-cluster=0`. It is offered only when zram
swap is active. More eager compressed reclaim can preserve file cache and help
memory-heavy multitasking, at the cost of compression work and possible swap-in
churn.

## What changes

An applied preset records the current live values and exact prior contents of
any affected files. It then installs:

- `/etc/sysctl.d/99-cachyos-tweaks-memory.conf`
- `/etc/udev/rules.d/99-cachyos-tweaks-memory.rules`

The udev rule preserves the chosen swappiness after CachyOS initializes zram.
Returning to **CachyOS defaults** restores the recorded files and live values.

These presets do not resize zram, create swap files, alter live swap devices, or
change OOM and dirty-page policy.

## References

- [Linux virtual-memory sysctls](https://docs.kernel.org/admin-guide/sysctl/vm.html)
- [CachyOS settings](https://github.com/CachyOS/CachyOS-Settings)
- [systemd zram-generator](https://github.com/systemd/zram-generator)
