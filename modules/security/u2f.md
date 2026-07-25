# U2F / FIDO2 authentication

Enroll an authenticator once, then enable it only for the detected PAM services
where you want to use it. SSH configuration is never changed.

## Enrollment and testing

- **Enroll** registers the key and proves it against an isolated PAM service
  before any login or unlock stack is changed.
- **Test the authenticator now** repeats that isolated test. It asks for one
  authenticator approval and does not touch a live login service.
- **Remove enrollment** becomes available after every managed service is off.

The first test of an existing enrollment may need administrator authorization
to install the suite-owned test service. Later tests run as the enrolled user.

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

Mapping and PAM state are stored with restrictive permissions. See
[SECURITY.md](../../SECURITY.md) for reporting security issues.
