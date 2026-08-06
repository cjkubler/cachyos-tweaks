# shellcheck shell=bash
# Remote-access (OpenSSH) category for CachyOS.
#
# Two independent toggles: run the OpenSSH server, and harden its
# configuration with a managed drop-in. The hardening drop-in is useful on
# its own — it also protects a server enabled outside this suite — so the
# toggles do not depend on each other.

register_module_doc system 'General OS' 'Remote access (SSH)' \
    modules/system/remote/README.md

SYSTEM_TWEAKS+=(
    ssh-server
    ssh-hardening
)

system_ssh_category() { printf 'Remote access'; }

: "${SYSTEM_SSH_UNIT:=sshd.service}"
: "${SYSTEM_SSH_UNIT_FILE:=/usr/lib/systemd/system/sshd.service}"
: "${SYSTEM_SSH_DROPIN:=/etc/ssh/sshd_config.d/20-cachyos-tweaks-hardening.conf}"
readonly SYSTEM_SSH_UNIT SYSTEM_SSH_UNIT_FILE SYSTEM_SSH_DROPIN

system_ssh_installed() {
    [[ -e "$SYSTEM_SSH_UNIT_FILE" || -e "/etc/systemd/system/$SYSTEM_SSH_UNIT" ]]
}

system_ssh_summary() {
    local enabled active
    enabled=$(systemctl is-enabled "$SYSTEM_SSH_UNIT" 2>/dev/null || true)
    active=$(systemctl is-active "$SYSTEM_SSH_UNIT" 2>/dev/null || true)
    printf 'Current state:\n- Service: %s, %s' \
        "${enabled:-not installed}" "${active:-inactive}"
}

# Accounts that could accept an SSH login: root plus regular users with an
# interactive shell, as user:home lines. Tests override the listing.
system_ssh_login_accounts() {
    if [[ -n ${SYSTEM_SSH_ACCOUNTS:-} ]]; then
        printf '%s\n' "$SYSTEM_SSH_ACCOUNTS"
        return
    fi
    getent passwd |
        awk -F: '($3 == 0 || $3 >= 1000) && $7 !~ /(nologin|false)$/ { print $1 ":" $6 }'
}

# Echo the number of usable key lines, or fail when the file is unreadable.
system_ssh_account_key_count() {
    local file=$1 count
    [[ -r "$file" ]] || return 1
    count=$(grep -cvE '^[[:space:]]*(#|$)' "$file" 2>/dev/null) || count=0
    printf '%s' "$count"
}

# Whether any login account holds a usable authorized key. Only a privileged
# caller can read every account's file, so the hardening apply (which runs as
# root) uses this as its safety gate.
system_ssh_any_authorized_key() {
    local line count
    while IFS= read -r line; do
        count=$(system_ssh_account_key_count "${line#*:}/.ssh/authorized_keys") ||
            continue
        (( count > 0 )) && return 0
    done < <(system_ssh_login_accounts)
    return 1
}

system_ssh_key_report() {
    local line user home count
    while IFS= read -r line; do
        user=${line%%:*}
        home=${line#*:}
        if count=$(system_ssh_account_key_count "$home/.ssh/authorized_keys"); then
            if (( count > 0 )); then
                printf -- '- %s: %s authorized key(s)\n' "$user" "$count"
            else
                printf -- '- %s: authorized_keys exists but holds no keys\n' "$user"
            fi
        elif [[ -e "$home/.ssh/authorized_keys" ]]; then
            printf -- '- %s: authorized_keys not readable from this session\n' "$user"
        else
            printf -- '- %s: no authorized keys\n' "$user"
        fi
    done < <(system_ssh_login_accounts)
}

system_ssh_firewall_summary() {
    local unit
    for unit in firewalld.service ufw.service nftables.service iptables.service; do
        if systemctl is-active "$unit" >/dev/null 2>&1; then
            printf -- '- Firewall: %s is active; SSH needs TCP port 22 allowed there.' \
                "${unit%.service}"
            return
        fi
    done
    printf -- '- Firewall: no active firewall service detected; nothing blocks port 22.'
}

system_ssh_server_title() { printf 'Run the OpenSSH server (sshd)'; }
system_ssh_server_category() { system_ssh_category; }
system_ssh_server_desc() {
    cat <<EOF
Enables and starts sshd.service so this machine accepts incoming SSH
connections. Missing host keys are generated automatically.

Remote login is a real attack surface: prefer key-based authentication
(see the hardening toggle below). Firewall state is detected below;
"Inspect SSH status" shows the full picture at any time.

Turning this off restores the exact prior service state — a server that
was already enabled outside this application is reported as external and
left alone.

$(system_ssh_summary)
$(system_ssh_firewall_summary)
EOF
}
system_ssh_server_applicable() { system_ssh_installed; }
system_ssh_server_status() { service_tweak_status ssh-server "$SYSTEM_SSH_UNIT"; }
system_ssh_server_apply() {
    # Arch's sshd.service does not create host keys on first start.
    ssh-keygen -A
    service_tweak_apply ssh-server "$SYSTEM_SSH_UNIT"
}
system_ssh_server_revert() { service_tweak_revert ssh-server "$SYSTEM_SSH_UNIT"; }

system_ssh_hardening_content() {
    cat <<EOF
# Managed by Tweaks for CachyOS. Toggle "Harden the OpenSSH server" in the
# application instead of editing this file.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
}

system_ssh_hardening_title() { printf 'Harden the OpenSSH server'; }
system_ssh_hardening_category() { system_ssh_category; }
system_ssh_hardening_desc() {
    cat <<EOF
Installs $SYSTEM_SSH_DROPIN
with a conservative baseline:

- PermitRootLogin no — administrators log in as themselves.
- PasswordAuthentication no — keys only; passwords cannot be brute-forced.
- KbdInteractiveAuthentication no — closes the interactive password path.

${C_YELLOW}Once applied, password logins over SSH are rejected.${C_RESET}
Applying refuses to proceed unless at least one login account already has
a usable ~/.ssh/authorized_keys entry, so this cannot silently lock every
key-less account out. The "Add authorized keys" action below imports a
key for you — from a GitHub username, other providers, or a pasted key.
Detected right now:

$(system_ssh_key_report)

The drop-in loads before other configuration, and sshd keeps the first
value it reads, so these settings win without editing existing files. The
configuration is validated with sshd -t before a running server is
reloaded; turning the toggle off removes the drop-in again.

$(system_ssh_summary)
EOF
}
system_ssh_hardening_applicable() { system_ssh_installed; }
system_ssh_hardening_status() {
    tweak_file_status ssh-hardening "$SYSTEM_SSH_DROPIN"
}
system_ssh_hardening_apply() {
    # Refuse to disable password logins when nobody could log in with a key
    # afterwards. This runs as root, so every account's file is readable.
    system_ssh_any_authorized_key ||
        die 'no login account has a usable ~/.ssh/authorized_keys entry; add a client public key first (see the Remote access help page)'
    system_ssh_hardening_content |
        managed_write ssh-hardening "$SYSTEM_SSH_DROPIN" 0644 ||
        die 'could not install the SSH hardening drop-in'
    # Host keys may not exist yet on a machine that never ran sshd; sshd -t
    # needs them to validate the configuration.
    ssh-keygen -A
    if ! sshd -t; then
        managed_revert_all ssh-hardening
        die 'sshd rejected the hardened configuration; the drop-in was removed'
    fi
    systemctl try-reload-or-restart "$SYSTEM_SSH_UNIT"
}
system_ssh_hardening_revert() {
    managed_revert_all ssh-hardening
    systemctl try-reload-or-restart "$SYSTEM_SSH_UNIT"
}

system_ssh_extra_build() {
    EX_IDS+=(ssh-report)
    EX_LABELS+=('Inspect SSH status')
    EX_DISABLED+=(0)
    EX_CAPTURE+=(1)
    EX_PRIVILEGED+=(0)
    EX_DESC+=('Show the sshd service state, host keys, listening TCP ports, firewall'$'\n''state, per-account authorized keys, and the drop-in configuration files'$'\n''sshd reads. This is read-only.')
    EX_IDS+=(ssh-import-keys)
    EX_LABELS+=('Add authorized keys')
    EX_DISABLED+=(0)
    EX_CAPTURE+=(1)
    EX_PRIVILEGED+=(0)
    EX_DESC+=('Import public keys into your ~/.ssh/authorized_keys so the hardened,'$'\n''key-only configuration can let you in. Accepted sources:'$'\n\n''- a GitHub username (fetches https://github.com/USER.keys)'$'\n''- gitlab:USER or sourcehut:USER'$'\n''- any https:// URL serving authorized_keys lines'$'\n''- a full public key line pasted directly'$'\n\n''Every candidate is validated with ssh-keygen, keys already present are'$'\n''skipped, and the added fingerprints are shown for review. Only your own'$'\n''account is modified; nothing else changes.')
    # Prompt metadata: the frontend collects this one line of input and passes
    # it to the action as CACHYOS_TWEAKS_EXTRA_INPUT.
    # shellcheck disable=SC2034 # consumed by the frontend protocol dump
    EX_PROMPT[${#EX_IDS[@]}-1]='GitHub username — or gitlab:USER, sourcehut:USER, an https:// URL, or a public key line'
}

# The account whose authorized_keys the import manages: the invoking user,
# resolved through sudo when the backend was elevated.
system_ssh_import_account() {
    local user
    if (( EUID == 0 )) && [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then
        user=$SUDO_USER
    else
        user=$(id -un)
    fi
    getent passwd "$user" | awk -F: '{ print $1 ":" $6; exit }'
}

system_ssh_import_url() {
    local spec=$1 provider name
    provider=${spec%%:*}
    name=${spec#*:}
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || return 1
    case $provider in
        github) printf 'https://github.com/%s.keys' "$name" ;;
        gitlab) printf 'https://gitlab.com/%s.keys' "$name" ;;
        sourcehut|srht) printf 'https://meta.sr.ht/~%s.keys' "$name" ;;
        *) return 1 ;;
    esac
}

# Echo "SIZE HASH TYPE" fingerprint output for one key line, or fail when
# ssh-keygen does not accept it as a public key.
system_ssh_key_fingerprint() {
    local line=$1 tmp out
    tmp=$(mktemp) || return 1
    printf '%s\n' "$line" >"$tmp"
    if ! out=$(ssh-keygen -lf "$tmp" 2>/dev/null); then
        rm -f -- "$tmp"
        return 1
    fi
    rm -f -- "$tmp"
    printf '%s' "$out"
}

system_ssh_trim() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}

system_ssh_import_keys() {
    local spec source_label='' url=''
    spec=$(system_ssh_trim "${CACHYOS_TWEAKS_EXTRA_INPUT:-}")
    [[ -n "$spec" && "$spec" != *$'\n'* && "$spec" != *$'\r'* ]] ||
        die 'provide one key source: USER, github:USER, gitlab:USER, sourcehut:USER, an https:// URL, or a public key line'

    local account user home
    account=$(system_ssh_import_account) && [[ "$account" == *:/* ]] ||
        die 'could not determine the account to add keys for'
    user=${account%%:*}
    home=${account#*:}
    [[ -d "$home" ]] || die "the home directory of $user does not exist: $home"

    local -a candidates=()
    if [[ "$spec" == ssh-* || "$spec" == ecdsa-sha2-* || "$spec" == sk-* ]]; then
        candidates=("$spec")
        source_label=''
    else
        if [[ "$spec" == https://* ]]; then
            [[ "$spec" =~ ^https://[^[:space:]]+$ ]] ||
                die "invalid key URL: $spec"
            url=$spec
        else
            [[ "$spec" == *:* ]] || spec="github:$spec"
            url=$(system_ssh_import_url "$spec") ||
                die "unrecognized key source: $spec"
        fi
        source_label=$spec
        command -v curl >/dev/null || die 'curl is required to fetch keys'
        msg "Fetching $url"
        local fetched
        fetched=$(curl -fsSL --max-time 15 --max-filesize 65536 "$url") ||
            die "could not fetch keys from $url"
        mapfile -t candidates <<<"$fetched"
    fi

    local file="$home/.ssh/authorized_keys"
    [[ ! -L "$file" ]] || die "refusing to modify a symlinked $file"
    local -a existing_ids=()
    if [[ -e "$file" ]]; then
        mapfile -t existing_ids < <(awk '/^[^#[:space:]]/ { print $1 ":" $2 }' "$file")
    fi

    local line fingerprint key_id known existing already=0 rejected=0
    local -a additions=() fingerprints=()
    for line in "${candidates[@]}"; do
        line=$(system_ssh_trim "$line")
        [[ -n "$line" && "$line" != '#'* ]] || continue
        if ! fingerprint=$(system_ssh_key_fingerprint "$line"); then
            rejected=$((rejected + 1))
            continue
        fi
        key_id=$(awk '{ print $1 ":" $2 }' <<<"$line")
        known=0
        for existing in "${existing_ids[@]}"; do
            [[ "$existing" == "$key_id" ]] && known=1
        done
        if (( known )); then
            already=$((already + 1))
            continue
        fi
        # A key without a comment gets its source recorded as one, so the
        # authorized_keys file stays reviewable later.
        if [[ -n "$source_label" ]] &&
            (( $(awk '{ print NF }' <<<"$line") < 3 )); then
            line+=" $source_label"
        fi
        additions+=("$line")
        fingerprints+=("$fingerprint")
        existing_ids+=("$key_id")
    done

    if (( ${#additions[@]} == 0 )); then
        if (( already > 0 )); then
            msg "Nothing to do: $already key(s) from that source are already present."
            return 0
        fi
        die 'that source contained no valid public keys'
    fi

    install -d -m 700 "$home/.ssh"
    if [[ ! -e "$file" ]]; then
        install -m 600 /dev/null "$file"
    fi
    if (( EUID == 0 )); then
        chown "$user:" "$home/.ssh" "$file"
    fi
    # Guard against an existing file without a trailing newline.
    if [[ -s "$file" && -n $(tail -c1 "$file") ]]; then
        printf '\n' >>"$file"
    fi
    printf '%s\n' "${additions[@]}" >>"$file"

    msg "Added ${#additions[@]} key(s) to $file:"
    printf '%s\n' "${fingerprints[@]}"
    (( already == 0 )) || msg "$already key(s) were already present and skipped."
    (( rejected == 0 )) || warn "$rejected line(s) were not valid public keys and were ignored"
}

system_ssh_report() {
    local enabled active
    enabled=$(systemctl is-enabled "$SYSTEM_SSH_UNIT" 2>/dev/null || true)
    active=$(systemctl is-active "$SYSTEM_SSH_UNIT" 2>/dev/null || true)
    printf 'Service\n'
    printf 'sshd.service: %s, %s\n' \
        "${enabled:-not installed}" "${active:-inactive}"
    printf '\nHost keys\n'
    if compgen -G '/etc/ssh/ssh_host_*_key.pub' >/dev/null; then
        ls -l /etc/ssh/ssh_host_*_key.pub
    else
        printf 'none yet (generated automatically when the server is enabled)\n'
    fi
    printf '\nLogin accounts and authorized keys\n'
    system_ssh_key_report
    printf '\n%s\n' "$(system_ssh_firewall_summary)"
    if command -v ss >/dev/null 2>&1; then
        printf '\nListening TCP sockets\n'
        ss -ltn
    fi
    printf '\nConfiguration drop-ins (/etc/ssh/sshd_config.d)\n'
    if compgen -G '/etc/ssh/sshd_config.d/*.conf' >/dev/null; then
        ls -l /etc/ssh/sshd_config.d/*.conf
    else
        printf 'none\n'
    fi
    printf '\nManaged hardening drop-in\n'
    if tweak_has_state ssh-hardening; then
        printf '%s (managed by this application)\n' "$SYSTEM_SSH_DROPIN"
    elif [[ -e "$SYSTEM_SSH_DROPIN" ]]; then
        printf '%s exists but is not managed by this application\n' "$SYSTEM_SSH_DROPIN"
    else
        printf 'not installed\n'
    fi
}
