# Contributing

Thanks for improving Tweaks for CachyOS. This project changes system
configuration through a privileged backend, so small, reversible
changes with clear applicability checks are preferred.

## Set up

You need Bash, Go 1.25 or newer, ShellCheck, and GCC. On CachyOS:

```bash
sudo pacman -S --needed bash go shellcheck gcc
make check
```

`make check` runs Bash syntax checks, ShellCheck, Go vet, Go and shell tests,
and a static TUI build. Run `make fmt` after changing Go code.

## Add a tweak

Start with [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). In short:

1. Put general OS policy in a category directory under `modules/system/`,
   device-specific policy under `modules/devices/`, or cross-device hardware
   policy under `modules/hardware/`.
2. Put reusable mutation logic in `modules/common/` and call it through thin
   device wrappers.
3. Register the tweak ID in the module's ordered `*_TWEAKS` array.
4. Implement the six-function contract: title, description, applicability,
   status, apply, and revert.
5. Use the managed-file helpers. Never overwrite a system file without
   preserving its exact prior state.
6. Add or update the focused Markdown page beside the module. Keep detailed
   module guidance out of the root README.

For a new module, add its file and one `load_tweak_module` line to
`modules/index.sh`, then register at least one bundled help topic while the
module is sourced:

```bash
register_module_doc example Hardware 'Example device' \
    modules/devices/example.md
```

A module may register several topics. This is particularly useful for the
general OS module, where each category owns its implementation and
documentation below `modules/system/<category>/`.

`tests/shell_test.sh` validates the complete contract for every registered
tweak. General OS tweaks must also implement
`<module>_<tweak>_category`, using a concise display label such as
`Memory & swap`, `CPU`, `Storage`, or `Networking`; the TUI builds its section
headings from this backend metadata. Mutually exclusive presets may implement
the optional `<module>_<tweak>_group` function; every choice in a group must
operate on one shared, reversible managed state.

## Pull requests

Keep commits focused. In the PR, describe:

- the exact hardware and CachyOS/kernel versions tested;
- the symptom and source for the workaround;
- files, services, or kernel parameters changed;
- reboot, security, performance, and battery implications;
- how revert restores the previous state.

Do not include generated `build/` artifacts.
