# U2F / FIDO2 authentication

Enroll an authenticator once, then enable it only for the detected PAM services
where you want to use it. Add spare authenticators at any time; any enrolled
key works for every enabled service. SSH configuration is never changed.

## Enrollment and testing

- **Enroll** appears once for each connected authenticator. It registers that
  key and proves it against an isolated PAM service before any login or unlock
  stack is changed.
- **Test the authenticator now** repeats that isolated test. It asks for one
  approval on any enrolled authenticator and does not touch a live login
  service.
- **Add authenticator** appears once for each connected authenticator. It
  registers that key and proves it with the same isolated test. If the test
  fails, the key mapping is restored. A key that is already enrolled cannot be
  added again.
- **Remove authenticator** appears for each enrolled key and is marked
  *connected* while that key is plugged in. The last key can only go with
  **Remove enrollment**.

The screen follows authenticators as they are plugged in or removed. It asks
each connected key, without a touch, which enrolled credential it holds.
- **Remove enrollment** removes every enrolled key. It becomes available after
  every managed service is off.

Any number of authenticators can stay connected. Registration uses only the
key you picked, and the menu labels each enrolled key with that device's name.
Keys enrolled before labels existed show as `Authenticator` with their ID.

Enabling a service before enrollment enrolls the connected authenticator
first. With several connected, pick one with its **Enroll** action instead.

A user can have at most 24 keys. pam_u2f reads only that many (its
`max_devices` default) and silently ignores the rest.

The first test of an existing enrollment may need administrator authorization
to install the suite-owned test service. Later tests run as the enrolled user.

From the command line, `u2f keys` lists the enrolled keys with their IDs,
`u2f add-key [DEVICE]` adds one, and `u2f remove-key ID` removes one.
`u2f enroll` and `u2f add-key` take a device such as `hidraw3`; it is optional
when only one authenticator is connected.

## Service behavior

Only PAM services present on the machine appear. Login services consume a typed
password first so KWallet or GNOME Keyring can still unlock, with U2F available
as the configured authentication path. Pure screen lockers can unlock from an
authenticator touch alone.

Password and fingerprint authentication remain available as fallbacks. A
key-only login cannot unlock a password-backed wallet; that is a property of
the wallet design rather than PAM configuration.

## Status and removal

Rules created outside this suite are shown as **EXTERN**. Removal strips only
the exact block this module recognizes and verifies that the PAM stack retains
an authentication rule. Managed rules whose contents changed afterward are
shown as **DRIFT** and require review before replacement or removal.

Adding or removing a key requires the suite-managed mapping. A mapping created
outside the suite, or edited since, must be changed by hand or re-enrolled.

Mapping and PAM state are stored with restrictive permissions. See
[SECURITY.md](../../SECURITY.md) for reporting security issues.
