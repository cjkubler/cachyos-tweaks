# Tweaks for CachyOS

A focused terminal interface for reviewing, applying, and reverting CachyOS
system tweaks. Changes are staged before they run, protected by confirmations,
and backed by exact prior-state records.

> [!IMPORTANT]
> This is an independent community project. It is not affiliated with,
> maintained by, or endorsed by the CachyOS project.

## Install

Install the latest portable release for your user:

```bash
curl -fsSL https://raw.githubusercontent.com/cjkubler/cachyos-tweaks/main/scripts/install-portable.sh | bash
```

This installs entirely below your home directory and provides the
`tweaks-for-cachyos` command. It does not use or modify pacman’s package
database. The application requests administrator authorization only when a
system change needs it.

Update from the General OS actions in the TUI or from a terminal:

```bash
tweaks-for-cachyos update
```

Updates download the latest complete release, verify its published SHA-256
checksum, and atomically switch the active version. Previous versions remain
under `~/.local/share/tweaks-for-cachyos/versions/` for manual rollback.

Revert any active tweaks before uninstalling. Then remove
`~/.local/bin/tweaks-for-cachyos` and
`~/.local/share/tweaks-for-cachyos/`. Uninstall does not guess which active
system changes should be reverted.

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [Interface](#interface)
- [Safety model](#safety-model)
- [Built-in documentation](#built-in-documentation)
- [Project layout](#project-layout)
- [Development](#development)
- [License](#license)

## Quick start

After installation, launch:

```bash
tweaks-for-cachyos
```

For development from a source checkout instead:

```bash
make
./tweaks.sh
```

Or pair a source checkout with the latest prebuilt TUI:

```bash
./tweaks.sh get-tui
./tweaks.sh
```

Useful entry points:

```bash
./tweaks.sh --no-sudo   # defer administrator authorization
./tweaks.sh status      # print detected state
./tweaks.sh --help      # show scriptable commands
```

The default launch asks for administrator authorization inside the TUI and
keeps the interface visible. `--no-sudo` is available for inspection-only
sessions or environments where authorization should be deferred.

Authenticator enrollment compiles a small isolated PAM verifier at runtime;
that optional feature requires GCC and the PAM development files.

## Interface

The interface uses Bubble Tea, Bubbles, Lip Gloss, and Glamour. It adapts from
compact terminals to centered two-pane dashboards on wide displays.

- Arrow keys or `j`/`k` move through rows.
- Enter stages a setting or runs an action.
- `a` reviews and confirms staged changes.
- `s` reviews and confirms a standalone snapshot.
- `i` opens the offline help center.
- `?` shows the complete shortcut list.
- Mouse movement softly highlights clickable rows and controls.
- Mouse clicks select first and activate on a second click.
- Focused labels gently scroll in place when their text does not fit.

The header includes a faint build revision so support reports can identify the
exact executable.

## Safety model

Nothing runs when a setting is toggled. The requested state is staged and shown
in the details pane until it is applied or discarded. Mutually exclusive
presets cannot be staged together.

Before applying, the TUI shows the exact operations and calls out files that
were changed elsewhere. Managed files are never silently overwritten after
drift is detected.

Every managed change records the prior file contents and relevant runtime state
under `/var/lib/cachyos-tweaks/`. Revert restores that state rather than
guessing a default.

When Snapper is configured, an apply is wrapped in a pre/post snapshot pair.
Standalone snapshots are also available from the main screen and always require
confirmation.

The TUI itself remains unprivileged. Only backend actions that need system
access use cached sudo authorization. Interactive authorization follows the
host's configured sudo/PAM order, so security keys and fingerprint readers are
offered before their configured fallbacks. If sudo eventually requests a
password or other hidden response, its masked input remains inside the
alternate-screen interface.

## Built-in documentation

The help center is a category-and-topic browser rendered with Glamour. Project
documents are always available, while detected modules add their own bundled
pages dynamically.

Module documentation lives beside the code it explains:

| Category | Topic |
| --- | --- |
| General OS | [Memory and swap](modules/system/memory/README.md) |
| Security | [U2F / FIDO2 authentication](modules/security/u2f.md) |
| Hardware | [Framework 13](modules/devices/framework-13.md) |
| Hardware | [Framework 16](modules/devices/framework-16.md) |
| Hardware | [Lenovo Yoga 7 14AHP9](modules/devices/lenovo-yoga-7-14ahp9.md) |
| Hardware | [eGPU / USB4](modules/hardware/egpu.md) |

This keeps the landing page readable and lets a module ship, register, and
display its documentation without editing the frontend.

## Project layout

```text
tweaks.sh                  entrypoint and backend protocol
lib/                       state, managed-file, and snapshot helpers
modules/
  common/                  shared implementations used by several devices
  system/
    index.sh               general OS category manifest
    memory/                memory policy and its documentation
  devices/                 model-specific policy
  hardware/                cross-device hardware tools
  security/                authentication integrations
  index.sh                 ordered module manifest
tui/                       Charm frontend
```

Shared fixes are centralized in `modules/common/`. Device modules keep only
their detection, applicability, and device-specific wording. General OS policy
uses one subdirectory per category so future CPU, storage, or networking policy
does not grow into one large file. Each General OS tweak declares its category
to the backend, and the TUI renders those labels as section headings.

See the repository's
[contributor guide](https://github.com/cjkubler/cachyos-tweaks/blob/main/CONTRIBUTING.md)
for the module contract and
[architecture guide](https://github.com/cjkubler/cachyos-tweaks/blob/main/docs/ARCHITECTURE.md)
for the privilege boundary, state engine, and frontend protocol.

## Development

Install Bash, Go 1.25 or newer, ShellCheck, and GCC, then run:

```bash
make check
```

Pushing a semantic `vMAJOR.MINOR.PATCH` tag builds amd64 and arm64 releases.
Each archive contains only the executable, portable installer, Bash runtime,
modules and their help pages, PAM test source, README, license, security
policy, attributions, and third-party license notices.

## License

Released under the permissive [MIT License](LICENSE).
