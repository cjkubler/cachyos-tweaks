# Remote access (SSH)

Two independent settings for the OpenSSH server: run it, and harden it. The
hardening drop-in is useful on its own — it also protects a server that was
enabled outside this application.

## What the application checks for you

- **Host keys** are generated automatically when the server is enabled or the
  hardened configuration is validated; nothing to prepare.
- **Firewall state** is detected and shown in the setting descriptions and in
  **Inspect SSH status**. If a firewall service is active, allow TCP port 22
  in it; the report names which firewall that is.
- **Authorized keys** are inventoried per login account, and the
  **Add authorized keys** action imports them for you (see below). Hardening
  **refuses to apply** unless at least one account has a usable
  `~/.ssh/authorized_keys` entry, so switching to key-only authentication
  cannot silently lock every key-less account out.
- The hardened configuration is validated with `sshd -t` before a running
  server is reloaded, and rolls back automatically if sshd rejects it.

## Adding client keys without leaving the app

The **Add authorized keys** action imports public keys into your own
`~/.ssh/authorized_keys`. It accepts:

- a **GitHub username** — fetches `https://github.com/USER.keys`
- `gitlab:USER` or `sourcehut:USER`
- any `https://` URL serving `authorized_keys` lines
- a full public key line pasted directly

Every candidate is validated with `ssh-keygen`, keys already present are
skipped, and the added fingerprints are shown for review. Keys fetched
without a comment are tagged with their source so the file stays auditable.
The same action works from a terminal:

```bash
CACHYOS_TWEAKS_EXTRA_INPUT=your-github-name ./tweaks.sh extra system ssh-import-keys
```

If the client key is not published anywhere, either paste its public key
line into the action, or run `ssh-copy-id user@this-machine` from the client
while password login still works. **Inspect SSH status** confirms the key is
seen either way.

## Run the OpenSSH server (sshd)

Enables and starts `sshd.service`. Turning the setting off restores the exact
prior service state; a server that was already enabled elsewhere is reported
as external and left alone.

## Harden the OpenSSH server

Installs `/etc/ssh/sshd_config.d/20-cachyos-tweaks-hardening.conf` with:

```text
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
```

sshd keeps the first value it reads for each keyword, and drop-ins load in
lexical order before the main configuration, so this file wins without editing
anything else. Once active, password logins over SSH are rejected — local
console logins are unaffected. Turning the toggle off removes the drop-in and
reloads a running server.

## References

- [OpenSSH manual: sshd_config](https://man.openbsd.org/sshd_config)
- [Arch Wiki: OpenSSH](https://wiki.archlinux.org/title/OpenSSH)
