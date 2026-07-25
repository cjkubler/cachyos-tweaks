# Architecture

The suite has one unprivileged frontend and a Bash backend that is elevated
only for operations that require administrator access:

```text
tweaks.sh
├── lib/                    state engine and snapshots
├── modules/
│   ├── common/             shared mutation and revert implementations
│   ├── system/             category manifests, policy, and colocated docs
│   ├── devices/            device detection, policy, and descriptions
│   ├── hardware/           cross-device hardware such as eGPU/USB4
│   ├── security/           authentication integrations
│   └── index.sh            ordered module manifest
└── tui/                    unprivileged presentation logic (Bubble Tea)
```

The Charm frontend obtains state from `tweaks.sh dump`, sends staged
operations to `tweaks.sh batch`, launches non-toggle actions through
`tweaks.sh extra`, and creates restore points through `tweaks.sh snapshot
create`. It never edits the system directly. Read-only state inspection uses
public hashes rather than protected backup contents, so opening and browsing do
not authenticate. By default the frontend validates sudo once at startup
inside the alternate screen, while `--no-sudo` defers that validation until a
privileged action. The TUI itself is never elevated. Mutating backend
subprocesses use the cached authorization after an in-app confirmation. A
non-interactive refresh keeps the cache alive while the app is open; failure
silently marks it unavailable so the next privileged action can prompt safely.

## Module-owned documentation

Each module calls `register_module_doc` while it is sourced:

```bash
register_module_doc example Hardware 'Example device' \
    modules/devices/example.md
```

The manifest validates that the page exists below `modules/`. The dump protocol
emits a `DOC` record only for a detected module, and the TUI adds that page to
its category-and-topic help browser. A module may register multiple pages.

General OS policy has an additional source boundary. `modules/system/index.sh`
owns the public module adapter and sources one directory per policy category,
such as `modules/system/memory/`. A new category appends its tweak IDs to
`SYSTEM_TWEAKS`, implements `<module>_<tweak>_category` for each row, and
registers its own documentation from within that directory. The category
function returns the display heading used by the TUI. If a categorized module
contains a row without metadata, the frontend places it under `Other` so it
cannot silently appear category-less.

## Tweak contract

A tweak module with ID `example` declares a global
`declare -ga EXAMPLE_TWEAKS=()` array and implements:

```text
example_detect
example_model_line
example_<tweak>_title
example_<tweak>_desc
example_<tweak>_applicable
example_<tweak>_status
example_<tweak>_apply
example_<tweak>_revert
```

IDs use kebab case in arrays and commands; function names replace dashes with
underscores. Status is one of `on`, `off`, `drifted`, or `unmanaged`.
Applicability is separate: an inapplicable tweak is exposed to frontends as
`n/a`.

Modules own policy: whether a change is appropriate, how it is explained, and
when it appears. `modules/system/` holds general OS policy;
`modules/devices/` and `modules/hardware/` hold hardware policy.
`modules/common/` owns mechanics shared across modules. This avoids the two
common failure modes of centralization:
duplicated root mutations and generic descriptions that erase hardware
differences.

A tweak may optionally expose `<module>_<tweak>_group`. Non-empty equal group
IDs make those rows mutually exclusive policy choices in the frontend. The
backend still receives an ordinary `on` operation for the selected choice, so
the module must update one shared managed state atomically. Selecting the
module’s default choice should restore that shared state. Bulk on/off staging
skips grouped choices.

General OS tweaks additionally expose `<module>_<tweak>_category`. Categories
are backend-owned presentation metadata, so adding future CPU, storage, or
networking policy does not require a frontend edit.

## State and reversibility

Managed state lives under `/var/lib/cachyos-tweaks/<tweak-id>/`. Before the
first write, the engine records:

- the original file or its absence;
- mode, owner, and group;
- a SHA-256 of the installed content for unprivileged drift detection;
- any small service-state notes needed for revert.

The installed-content hash powers drift detection. Revert refuses to overwrite
later edits unless the caller explicitly forces it. A shared tweak ID intentionally
uses the same state directory across device modules because only one matching
device module can be active on a machine.

## Frontend protocol

`dump` is a record stream: records are separated by byte `0x1e` and fields by
`0x1f`. Record types are `SUITE`, `MODULE`, `DOC`, `TWEAK`, and `EXTRA`.
Descriptions may contain newlines. `DOC` associates a module-owned category,
title, and safe relative Markdown path with its parent module. A `TWEAK`
record carries optional mutual-exclusion group and display-category fields. The
Go parser rejects unknown, duplicate, orphaned, unsafe, and malformed records
so protocol drift fails visibly.

`EXTRA` records also declare whether an action needs root and whether captured
section headings should become output tabs. Read-only
diagnostics and guidance run directly; privileged actions first probe the
sudo timestamp. When authentication is necessary, sudo starts immediately with
its normal PAM ordering and streams its conversation into the TUI, allowing a
security key or fingerprint reader to run before any configured password
fallback. A masked response field appears only when sudo requests hidden input.
Backend stdout and stderr stream into a modal, so the alternate screen is never
torn down for authorization or action output.

Authenticator enrollment owns one minimal, U2F-only PAM service. Tests execute
that service as the enrolled account, so they never traverse sudo’s own U2F
stack and request one key approval. Existing enrollments install the service
once through the privileged backend; subsequent tests are unprivileged.

All operations remain staged in the frontend until confirmation. A batch is
newline-delimited `module<TAB>id<TAB>on|off` and is wrapped in one snapper
pre/post pair when available. Inputs needed by a staged operation, such as the
Wi-Fi regulatory country code, are collected by the frontend and passed
explicitly to the backend.
