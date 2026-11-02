# shellcheck shell=bash
# U2F/FIDO2 PAM module for Tweaks for CachyOS. Sourced by tweaks.sh.
#
# Enrollment (the key mapping) and per-service PAM rules are separate:
# enroll once, add or remove further keys, then toggle U2F per service.
# Services whose rules were applied outside the suite are detected as
# "unmanaged" and can still be removed safely by stripping exactly the
# inserted block.

register_module_doc u2f Security 'U2F / FIDO2 authentication' \
    modules/security/u2f.md

readonly U2F_ID=u2f
readonly U2F_MAPPING=/etc/security/u2f_mappings
readonly U2F_PAM_DIR=/etc/pam.d
readonly U2F_VENDOR_PAM_DIR=/usr/lib/pam.d
readonly U2F_MARKER='# cachyos-u2f-pam managed rule'
readonly U2F_TEST_SERVICE=cachyos-u2f-pam-test
# pam_u2f's max_devices default; it silently ignores credentials beyond it.
readonly U2F_MAX_KEYS=24
# Readable by the unprivileged listing, unlike root-only tweak notes.
U2F_KEY_LABELS="$(tweak_dir "$U2F_ID")/key-labels"
readonly U2F_KEY_LABELS
# Persistent ownership metadata used to distinguish the suite-owned test
# service from an unrelated PAM configuration.
readonly U2F_TEST_MARKER='# Managed by Tweaks for CachyOS; isolated authenticator verification only.'

# Candidate PAM services across the desktops/WMs/login managers CachyOS
# offers (Plasma, GNOME, XFCE, Cinnamon, Mate, Budgie, LXQt, COSMIC, i3,
# bspwm, Openbox, Qtile, Sway, Hyprland, Niri, Wayfire, River, ...). Only
# services whose PAM stack exists on THIS system are offered — nothing is
# assumed about which desktop is installed.
readonly -a U2F_CANDIDATE_SERVICES=(
    # Always-relevant
    system-local-login sudo polkit-1
    # Graphical/console login managers
    plasmalogin sddm gdm-password lightdm lxdm ly greetd lemurs cosmic-greeter
    # Screen lockers
    kde swaylock hyprlock gtklock waylock
    i3lock xscreensaver xsecurelock physlock
    cinnamon-screensaver mate-screensaver xfce4-screensaver
)
U2F_SERVICES=()
for _u2f_s in "${U2F_CANDIDATE_SERVICES[@]}"; do
    if [[ -f "$U2F_PAM_DIR/$_u2f_s" || -f "$U2F_VENDOR_PAM_DIR/$_u2f_s" ]]; then
        U2F_SERVICES+=("$_u2f_s")
    fi
done
unset _u2f_s
readonly -a U2F_SERVICES

u2f_service_label() {
    case $1 in
        system-local-login)   printf 'Console/TTY login' ;;
        plasmalogin)          printf 'Plasma login and KDE lock screen' ;;
        sddm)                 printf 'SDDM graphical login' ;;
        gdm-password)         printf 'GNOME login and lock screen (GDM)' ;;
        lightdm)              printf 'LightDM graphical login' ;;
        lxdm)                 printf 'LXDM graphical login' ;;
        ly)                   printf 'ly console login' ;;
        greetd)               printf 'greetd graphical login' ;;
        lemurs)               printf 'Lemurs console login' ;;
        cosmic-greeter)       printf 'COSMIC login and lock screen' ;;
        kde)                  printf 'KDE lock screen (kscreenlocker)' ;;
        swaylock)             printf 'swaylock (Sway/wlroots lock)' ;;
        hyprlock)             printf 'hyprlock (Hyprland lock)' ;;
        gtklock)              printf 'gtklock (Wayland lock)' ;;
        waylock)              printf 'waylock (Wayland lock)' ;;
        i3lock)               printf 'i3lock (X11 lock)' ;;
        xscreensaver)         printf 'XScreenSaver lock' ;;
        xsecurelock)          printf 'xsecurelock (X11 lock)' ;;
        physlock)             printf 'physlock (console lock)' ;;
        cinnamon-screensaver) printf 'Cinnamon lock screen' ;;
        mate-screensaver)     printf 'MATE lock screen' ;;
        xfce4-screensaver)    printf 'Xfce lock screen' ;;
        sudo)                 printf 'sudo on the command line' ;;
        polkit-1)             printf 'PolicyKit privilege prompts' ;;
        *)                    printf '%s' "$1" ;;
    esac
}

# Session-opening services: consume a typed password first so wallet/
# keyring modules (KWallet, GNOME Keyring) still receive PAM_AUTHTOK; U2F
# takes over when the password is left empty. Pure screen lockers unlock an
# already-open session (the wallet is open), so they get the plain rule
# and a key touch alone unlocks.
u2f_service_is_login() {
    case $1 in
        system-local-login|plasmalogin|sddm|gdm-password|lightdm|lxdm|ly|greetd|lemurs|cosmic-greeter) return 0 ;;
        *) return 1 ;;
    esac
}

u2f_effective_source() {
    local service=$1
    if [[ -f "$U2F_PAM_DIR/$service" ]]; then
        printf '%s\n' "$U2F_PAM_DIR/$service"
    elif [[ -f "$U2F_VENDOR_PAM_DIR/$service" ]]; then
        printf '%s\n' "$U2F_VENDOR_PAM_DIR/$service"
    else
        return 1
    fi
}

u2f_origin() {
    local host
    if [[ -r /proc/sys/kernel/hostname ]]; then
        IFS= read -r host </proc/sys/kernel/hostname
    else
        host=${HOSTNAME:-$(hostname)}
    fi
    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "unsupported hostname: $host"
    printf 'pam://%s' "$host"
}

u2f_rule() {
    local origin=$1
    printf 'auth sufficient pam_u2f.so authfile=%s origin=%s appid=%s cue' \
        "$U2F_MAPPING" "$origin" "$origin"
}

u2f_test_service_content() {
    local origin=$1
    printf '%s\n' \
        '#%PAM-1.0' \
        "$U2F_TEST_MARKER" \
        "auth required pam_u2f.so authfile=$U2F_MAPPING origin=$origin appid=$origin cue" \
        'account required pam_permit.so'
}

u2f_test_service_ready() {
    local origin expected
    [[ -r "$U2F_PAM_DIR/$U2F_TEST_SERVICE" ]] || return 1
    origin=$(tweak_read "$U2F_ID" origin "$(u2f_origin)")
    expected=$(u2f_test_service_content "$origin")
    [[ $(<"$U2F_PAM_DIR/$U2F_TEST_SERVICE") == "$expected" ]]
}

u2f_install_test_service() {
    local origin=$1
    u2f_test_service_content "$origin" |
        managed_write "$U2F_ID" "$U2F_PAM_DIR/$U2F_TEST_SERVICE" 0644
}

u2f_enrolled() { [[ -s "$U2F_MAPPING" ]]; }

# A mapping line is `user:cred1:cred2:...`; credentials never contain ':'.
# Print USER's credentials from MAPPING in order, one per line.
u2f_credentials() {
    local mapping=$1 user=$2 line cred
    local -a fields=()
    [[ -r "$mapping" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$user":* ]] || continue
        IFS=: read -ra fields <<<"${line#"$user":}"
        for cred in "${fields[@]}"; do
            [[ -z "$cred" ]] || printf '%s\n' "$cred"
        done
        return 0
    done <"$mapping"
}

u2f_credential_id() {
    local hash
    hash=$(printf '%s' "$1" | sha256sum)
    printf '%s' "${hash:0:12}"
}

# Print MAPPING with CRED appended to USER's line; other lines are verbatim.
u2f_mapping_append() {
    local mapping=$1 user=$2 cred=$3 line found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( ! found )) && [[ "$line" == "$user":* ]]; then
            line+=":$cred"
            found=1
        fi
        printf '%s\n' "$line"
    done <"$mapping"
    (( found ))
}

# Print MAPPING without USER's credential ID. Fails rather than leave USER
# with no credentials.
u2f_mapping_remove() {
    local mapping=$1 user=$2 id=$3 line cred found=0 removed=0
    local -a fields=() kept=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( ! found )) && [[ "$line" == "$user":* ]]; then
            found=1
            IFS=: read -ra fields <<<"${line#"$user":}"
            for cred in "${fields[@]}"; do
                [[ -n "$cred" ]] || continue
                if [[ $(u2f_credential_id "$cred") == "$id" ]]; then
                    removed=1
                else
                    kept+=("$cred")
                fi
            done
            (( removed && ${#kept[@]} > 0 )) || return 1
            line=$user$(printf ':%s' "${kept[@]}")
        fi
        printf '%s\n' "$line"
    done <"$mapping"
    (( found ))
}

# Print `ID<TAB>LABEL` for USER's credentials in mapping order. Credentials
# enrolled before labels were recorded get a generic label.
u2f_key_list() {
    local mapping=$1 user=$2 labels=$3 cred id key label
    local -A stored=()
    if [[ -r "$labels" ]]; then
        while IFS=$'\t' read -r key label; do
            [[ -z "$key" ]] || stored[$key]=$label
        done <"$labels"
    fi
    while IFS= read -r cred; do
        id=$(u2f_credential_id "$cred")
        printf '%s\t%s\n' "$id" "${stored[$id]:-Authenticator $id}"
    done < <(u2f_credentials "$mapping" "$user")
}

# Replace ID's line in the LABELS file atomically; an empty LABEL drops it.
u2f_label_store() {
    local labels=$1 id=$2 label=${3:-} tmp
    label=${label//[[:cntrl:]]/ }
    tmp=$(mktemp "${labels%/*}/.key-labels.XXXXXX") || return 1
    if ! { if [[ -f "$labels" ]]; then grep -v "^$id"$'\t' "$labels" || true; fi
            [[ -z "$label" ]] || printf '%s\t%s\n' "$id" "$label"; } >"$tmp" ||
        ! chmod 0644 "$tmp" ||
        ! mv -fT -- "$tmp" "$labels"; then
        rm -f -- "$tmp"
        return 1
    fi
}

# Insert the managed block above the first auth line. login-type services get
# a password-consuming rule first so KWallet still receives PAM_AUTHTOK.
u2f_insert_rule() {
    local source=$1 destination=$2 rule=$3 prefer_password=$4
    awk -v marker="$U2F_MARKER" -v rule="$rule" -v prefer_password="$prefer_password" '
        !inserted && $0 ~ /^[[:space:]]*auth[[:space:]]+/ {
            print marker
            if (prefer_password) {
                print "# Consume a supplied password first so wallet modules receive PAM_AUTHTOK."
                print "auth [success=1 default=ignore] pam_unix.so try_first_pass nullok"
            }
            print rule
            inserted = 1
        }
        { print }
        END { if (!inserted) exit 42 }
    ' "$source" >"$destination"
}

u2f_live_has_rule() {
    local service=$1
    [[ -f "$U2F_PAM_DIR/$service" ]] &&
        grep -Eq "^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_u2f\.so([[:space:]]|$)|^$U2F_MARKER\$" \
            "$U2F_PAM_DIR/$service" 2>/dev/null &&
        grep -q 'pam_u2f\.so' "$U2F_PAM_DIR/$service"
}

U2F_EXTERNAL_BLOCK_START=0
U2F_EXTERNAL_BLOCK_END=0

# Locate either one bare generated rule or one complete generated block.
# Anything custom, repeated, or only partially matching remains manual work.
u2f_external_rule_bounds() {
    local service=$1 pam_file=${2:-"$U2F_PAM_DIR/$1"}
    local origin rule exact_count all_count marker_count i rule_index=-1
    local password_comment='# Consume a supplied password first so wallet modules receive PAM_AUTHTOK.'
    local password_rule='auth [success=1 default=ignore] pam_unix.so try_first_pass nullok'
    local -a lines=()
    [[ -f "$pam_file" && ! -L "$pam_file" ]] ||
        return 1
    origin=$(tweak_read "$U2F_ID" origin "$(u2f_origin)")
    rule=$(u2f_rule "$origin")
    mapfile -t lines <"$pam_file"
    exact_count=$(grep -Fxc -- "$rule" "$pam_file" 2>/dev/null || true)
    all_count=$(grep -Ec '^[[:space:]]*auth[[:space:]]+.*pam_u2f\.so([[:space:]]|$)' \
        "$pam_file" 2>/dev/null || true)
    marker_count=$(grep -Fxc -- "$U2F_MARKER" "$pam_file" 2>/dev/null || true)
    [[ "$exact_count" == 1 && "$all_count" == 1 && "$marker_count" -le 1 ]] ||
        return 1
    for i in "${!lines[@]}"; do
        [[ "${lines[i]}" == "$rule" ]] && rule_index=$i
    done
    (( rule_index >= 0 )) || return 1
    U2F_EXTERNAL_BLOCK_START=$((rule_index + 1))
    U2F_EXTERNAL_BLOCK_END=$((rule_index + 1))
    if (( marker_count == 0 )); then
        return 0
    fi
    if u2f_service_is_login "$service"; then
        (( rule_index >= 3 )) &&
            [[ "${lines[rule_index-3]}" == "$U2F_MARKER" &&
                "${lines[rule_index-2]}" == "$password_comment" &&
                "${lines[rule_index-1]}" == "$password_rule" ]] ||
            return 1
        U2F_EXTERNAL_BLOCK_START=$((rule_index - 2))
    else
        (( rule_index >= 1 )) && [[ "${lines[rule_index-1]}" == "$U2F_MARKER" ]] ||
            return 1
        U2F_EXTERNAL_BLOCK_START=$rule_index
    fi
}

u2f_external_rule_removable() {
    u2f_external_rule_bounds "$1"
}

u2f_strip_external_block() {
    local source=$1 destination=$2 start=$3 end=$4
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ &&
        "$start" -ge 1 && "$end" -ge "$start" ]] || return 1
    awk -v start="$start" -v end="$end" \
        'NR < start || NR > end { print }' "$source" >"$destination"
}

# off | on | drifted | unmanaged
u2f_service_status() {
    local service=$1 recorded
    recorded=$(managed_file_status "$U2F_ID" "$U2F_PAM_DIR/$service")
    case $recorded in
        on|drifted) printf '%s' "$recorded"; return ;;
    esac
    if u2f_live_has_rule "$service"; then
        printf 'unmanaged'
    else
        printf 'off'
    fi
}

u2f_enrollment_status() {
    if u2f_enrolled; then
        if [[ $(managed_file_status "$U2F_ID" "$U2F_MAPPING") == on ]]; then
            printf 'on'
        else
            printf 'unmanaged'
        fi
    else
        printf 'off'
    fi
}

u2f_target_user() {
    local user=${SUDO_USER:-}
    if [[ -z "$user" || "$user" == root ]]; then
        local tty_uid
        tty_uid=$(stat -c %u /dev/tty 2>/dev/null || printf '0')
        if [[ "$tty_uid" =~ ^[0-9]+$ ]] && (( tty_uid >= 1000 )); then
            user=$(getent passwd "$tty_uid" | cut -d: -f1)
        fi
    fi
    [[ -n "$user" && "$user" != root ]] ||
        die 'cannot determine the account to enroll; launch the TUI as that user'
    id "$user" >/dev/null 2>&1 || die "local account does not exist: $user"
    [[ $(id -u "$user") -ge 1000 ]] || die 'refusing to enroll a system account'
    [[ "$user" != *:* && "$user" != *$'\n'* ]] || die 'unsupported account name'
    printf '%s' "$user"
}

u2f_enrollment_fail() {
    local package_added=$1 reason=$2
    managed_revert_all "$U2F_ID"
    if [[ "$package_added" == 1 ]] && pacman -Q pam-u2f >/dev/null 2>&1; then
        if ! pacman -R --noconfirm pam-u2f; then
            tweak_note "$U2F_ID" package-installed-by-suite 1
            warn 'pam-u2f could not be removed after the failed enrollment.'
        fi
    fi
    die "$reason"
}

u2f_enroll() {
    need_root
    u2f_enrolled && { warn 'a U2F mapping already exists; add another authenticator instead'; return 0; }
    [[ ! -e "$U2F_PAM_DIR/$U2F_TEST_SERVICE" ]] || die "temporary PAM service already exists: $U2F_PAM_DIR/$U2F_TEST_SERVICE"

    command -v runuser >/dev/null || die 'runuser is required'
    u2f_select_device "${1:-}"

    local user origin work cred label package_added=0
    user=$(u2f_target_user) || die 'cancelled'
    origin=$(u2f_origin)
    label="$U2F_DEVICE_NAME, added $(date +%F)"
    work=$(mktemp -d -p "$SUITE_WORK")
    chmod 0755 "$work"

    # Verify the runtime compiler/PAM development environment before
    # installing pam-u2f or asking the user to touch a key.
    u2f_build_pam_test "$work"

    if ! pacman -Q pam-u2f >/dev/null 2>&1; then
        msg 'Installing pam-u2f from the CachyOS repositories...'
        pacman -S --needed --noconfirm pam-u2f
        tweak_note "$U2F_ID" package-installed-by-suite 1
        package_added=1
    fi
    [[ -x /usr/lib/security/pam_u2f.so ]] ||
        u2f_enrollment_fail "$package_added" 'pam_u2f.so is missing'

    msg ''
    msg "Approve the registration request on $U2F_DEVICE_NAME (/dev/$U2F_DEVICE)."
    cred=$(u2f_register "$user" "$origin" "$U2F_DEVICE" "$work") ||
        u2f_enrollment_fail "$package_added" 'authenticator enrollment was cancelled or failed'
    install -o root -g root -m 0600 /dev/null "$work/mapping"
    printf '%s:%s\n' "$user" "$cred" >"$work/mapping"

    # Prove the credential works with an isolated PAM stack before recording.
    managed_write_owned "$U2F_ID" "$U2F_MAPPING" 0600 \
        "$(id -u "$user")" "$(id -g "$user")" <"$work/mapping" ||
        u2f_enrollment_fail "$package_added" 'could not install the U2F mapping safely'
    u2f_install_test_service "$origin" ||
        u2f_enrollment_fail "$package_added" 'could not install the isolated PAM test service'
    msg ''
    msg 'Testing the enrolled credential with an isolated, U2F-only PAM stack.'
    msg "Touch $U2F_DEVICE_NAME now (when it begins blinking)."
    if ! runuser -u "$user" -- "$work/pam-auth-test" "$U2F_TEST_SERVICE" "$user"; then
        warn ''
        warn 'The enrolled credential failed the isolated PAM test.'
        warn 'Enrollment was rolled back; no live login service was changed.'
        u2f_enrollment_fail "$package_added" \
            'the enrolled credential failed the isolated PAM test'
    fi
    tweak_note "$U2F_ID" target-user "$user"
    tweak_note "$U2F_ID" origin "$origin"
    u2f_label_store "$U2F_KEY_LABELS" "$(u2f_credential_id "$cred")" "$label" ||
        warn 'could not record the authenticator label'
    msg ''
    msg "Enrolled. Enable U2F per service from the menu; nothing is active yet."
}

u2f_require_managed_mapping() {
    [[ $(managed_file_status "$U2F_ID" "$U2F_MAPPING") == on ]] ||
        die "$U2F_MAPPING was not enrolled by this suite or was edited since; edit it manually or re-enroll"
}

u2f_add_key() {
    need_root
    u2f_enrolled || die 'enroll an authenticator first'
    u2f_require_managed_mapping
    command -v runuser >/dev/null || die 'runuser is required'

    local user origin work cred existing id label uid gid
    local -a creds=()
    user=$(u2f_enrolled_user) || die 'cannot determine the enrolled account'
    mapfile -t creds < <(u2f_credentials "$U2F_MAPPING" "$user")
    (( ${#creds[@]} < U2F_MAX_KEYS )) ||
        die "$U2F_MAX_KEYS authenticators are already enrolled; pam_u2f ignores any more"
    u2f_select_device "${1:-}"
    label="$U2F_DEVICE_NAME, added $(date +%F)"
    origin=$(tweak_read "$U2F_ID" origin "$(u2f_origin)")
    for existing in "${creds[@]}"; do
        ! u2f_device_holds "$U2F_DEVICE" "$origin" "$existing" ||
            die "$U2F_DEVICE_NAME is already enrolled (ID $(u2f_credential_id "$existing"))"
    done
    uid=$(id -u "$user")
    gid=$(id -g "$user")
    work=$(mktemp -d -p "$SUITE_WORK")
    chmod 0755 "$work"
    u2f_build_pam_test "$work"
    u2f_ensure_test_service "$origin"

    msg ''
    msg "Approve the registration request on $U2F_DEVICE_NAME (/dev/$U2F_DEVICE)."
    cred=$(u2f_register "$user" "$origin" "$U2F_DEVICE" "$work") ||
        die 'registration was cancelled or failed'
    for existing in "${creds[@]}"; do
        [[ "$existing" != "$cred" ]] || die 'this credential is already enrolled'
    done
    id=$(u2f_credential_id "$cred")

    install -m 0600 "$U2F_MAPPING" "$work/previous"
    install -m 0600 /dev/null "$work/mapping"
    u2f_mapping_append "$U2F_MAPPING" "$user" "$cred" >"$work/mapping" ||
        die 'could not build the new U2F mapping'
    managed_write_owned "$U2F_ID" "$U2F_MAPPING" 0600 "$uid" "$gid" <"$work/mapping" ||
        die 'could not install the U2F mapping safely'
    msg ''
    msg 'Testing the new credential with an isolated, U2F-only PAM stack.'
    msg "Touch $U2F_DEVICE_NAME now (when it begins blinking)."
    if ! runuser -u "$user" -- "$work/pam-auth-test" "$U2F_TEST_SERVICE" "$user"; then
        managed_write_owned "$U2F_ID" "$U2F_MAPPING" 0600 "$uid" "$gid" <"$work/previous" ||
            die "the new credential failed the PAM test and $U2F_MAPPING could not be restored"
        warn ''
        warn 'The new credential failed the isolated PAM test and was not added.'
        die 'the new authenticator failed the isolated PAM test'
    fi
    u2f_label_store "$U2F_KEY_LABELS" "$id" "$label" ||
        warn 'could not record the authenticator label'
    msg ''
    msg "Added: $label. $(( ${#creds[@]} + 1 )) of $U2F_MAX_KEYS authenticators enrolled."
}

u2f_remove_key() {
    need_root
    local id=$1 user key label='' work
    local -a keys=()
    [[ "$id" =~ ^[0-9a-f]{12}$ ]] || die "invalid authenticator id: $id"
    u2f_enrolled || die 'no enrollment present'
    u2f_require_managed_mapping
    user=$(u2f_enrolled_user) || die 'cannot determine the enrolled account'
    mapfile -t keys < <(u2f_key_list "$U2F_MAPPING" "$user" "$U2F_KEY_LABELS")
    for key in "${keys[@]}"; do
        [[ "${key%%$'\t'*}" != "$id" ]] || label=${key#*$'\t'}
    done
    [[ -n "$label" ]] || die "no enrolled authenticator has id $id"
    (( ${#keys[@]} > 1 )) ||
        die 'this is the only enrolled authenticator; use Remove enrollment instead'
    work=$(mktemp -p "$SUITE_WORK")
    u2f_mapping_remove "$U2F_MAPPING" "$user" "$id" >"$work" ||
        die 'could not build the reduced U2F mapping'
    managed_write_owned "$U2F_ID" "$U2F_MAPPING" 0600 \
        "$(id -u "$user")" "$(id -g "$user")" <"$work" ||
        die 'could not install the U2F mapping safely'
    u2f_label_store "$U2F_KEY_LABELS" "$id" ||
        warn 'could not drop the authenticator label'
    msg "Removed: $label. $(( ${#keys[@]} - 1 )) of $U2F_MAX_KEYS authenticators enrolled."
}

u2f_enable_service() {
    need_root
    local service=$1 status source work prefer_password=0 origin
    status=$(u2f_service_status "$service")
    case $status in
        on)        msg "already enabled: $service"; return 0 ;;
        drifted)   die "live file for $service was edited after apply; disable with force first" ;;
        unmanaged) die "$service already has a U2F rule not managed by this suite; disable it first to adopt" ;;
    esac
    u2f_enrolled || die 'enroll an authenticator first'
    origin=$(tweak_read "$U2F_ID" origin "$(u2f_origin)")
    source=$(u2f_effective_source "$service") || die "missing PAM service: $service"
    u2f_service_is_login "$service" && prefer_password=1

    if [[ "$service" == sudo || "$service" == system-local-login ]]; then
        warn 'Keep a working root shell or spare TTY open while testing this.'
    fi

    work=$(mktemp -p "$SUITE_WORK")
    u2f_insert_rule "$source" "$work" "$(u2f_rule "$origin")" "$prefer_password" \
        || die "could not add a U2F rule to PAM service: $service"
    managed_install "$U2F_ID" "$U2F_PAM_DIR/$service" 0644 "$work"
    msg "U2F enabled for: $(u2f_service_label "$service")"
}

u2f_disable_service() {
    need_root
    local service=$1 force=${2:-} status work
    status=$(u2f_service_status "$service")
    case $status in
        off) msg "already disabled: $service"; return 0 ;;
        drifted)
            [[ "$force" == --force ]] || die "live file for $service was edited after apply; inspect it or use force"
            ;;&
        on|drifted)
            managed_restore "$U2F_ID" "$U2F_PAM_DIR/$service"
            ;;
        unmanaged)
            # Hand-applied rule: only the one exact rule produced by this
            # suite is eligible. Custom arguments or multiple U2F rules need
            # manual review and remain non-toggleable in the frontend.
            u2f_external_rule_bounds "$service" ||
                die "$service has a custom U2F rule; review it manually"
            work=$(mktemp -p "$SUITE_WORK")
            u2f_strip_external_block "$U2F_PAM_DIR/$service" "$work" \
                "$U2F_EXTERNAL_BLOCK_START" "$U2F_EXTERNAL_BLOCK_END"
            grep -Eq '^[[:space:]]*-?auth[[:space:]]' "$work" ||
                die "refusing: stripping would leave $service without an auth line"
            if [[ -f "$U2F_VENDOR_PAM_DIR/$service" ]] && cmp -s "$work" "$U2F_VENDOR_PAM_DIR/$service" \
                && ! pacman -Qo "$U2F_PAM_DIR/$service" >/dev/null 2>&1; then
                # Unowned override that matches vendor content: drop it entirely.
                rm -f -- "$U2F_PAM_DIR/$service"
            else
                atomic_replace_preserving_metadata "$U2F_PAM_DIR/$service" "$work"
            fi
            ;;
    esac
    msg "U2F disabled for: $(u2f_service_label "$service")"
}

u2f_remove_enrollment() {
    need_root
    local service status
    for service in "${U2F_SERVICES[@]}"; do
        status=$(u2f_service_status "$service")
        [[ "$status" == off ]] || die "disable U2F for $service first (status: $status)"
    done
    u2f_enrolled || { msg 'no enrollment present'; return 0; }
    if [[ $(managed_file_status "$U2F_ID" "$U2F_PAM_DIR/$U2F_TEST_SERVICE") == drifted ]]; then
        die "the isolated test service was edited after installation; inspect it before removing enrollment"
    fi
    managed_restore "$U2F_ID" "$U2F_PAM_DIR/$U2F_TEST_SERVICE"
    # Older releases installed this service without an ownership record; the
    # marker line still identifies it, and re-enrollment refuses to overwrite it.
    if [[ -f "$U2F_PAM_DIR/$U2F_TEST_SERVICE" ]] &&
        grep -qxF -- "$U2F_TEST_MARKER" "$U2F_PAM_DIR/$U2F_TEST_SERVICE"; then
        rm -f -- "$U2F_PAM_DIR/$U2F_TEST_SERVICE"
    fi
    if [[ $(managed_file_status "$U2F_ID" "$U2F_MAPPING") == off ]]; then
        # The explicit "Remove enrollment" action is the confirmation. All
        # live services are already off before this branch is reachable.
        rm -f -- "$U2F_MAPPING"
    else
        managed_restore "$U2F_ID" "$U2F_MAPPING"
    fi
    if [[ $(tweak_read "$U2F_ID" package-installed-by-suite 0) == 1 ]] \
        && pacman -Q pam-u2f >/dev/null 2>&1; then
        pacman -R --noconfirm pam-u2f
    fi
    rm -rf -- "$(tweak_dir "$U2F_ID")"
    msg 'U2F enrollment removed.'
}

u2f_print_status() {
    local service status
    printf '%s %sU2F enrollment%s (key mapping: %s)\n' \
        "$(status_badge "$(u2f_enrollment_status)")" "$C_BOLD" "$C_RESET" "$U2F_MAPPING"
    u2f_keys | while IFS=$'\t' read -r id label; do
        printf '      %s  %s\n' "$id" "$label"
    done
    for service in "${U2F_SERVICES[@]}"; do
        status=$(u2f_service_status "$service")
        printf '  %s %-22s %s\n' "$(status_badge "$status")" "$service" \
            "$(u2f_service_label "$service")"
    done
}

U2F_DEVICES=()
U2F_DEVICE_NAMES=()
# Fill U2F_DEVICES (hidrawN) and U2F_DEVICE_NAMES from `fido2-token -L`
# lines: `/dev/hidrawN: vendor=0x..., product=0x... (Manufacturer Product)`.
u2f_detect_keys() {
    local line path name
    U2F_DEVICES=() U2F_DEVICE_NAMES=()
    command -v fido2-token >/dev/null 2>&1 || return 0
    while IFS= read -r line; do
        path=${line%%:*}
        [[ "$path" =~ ^/dev/hidraw[0-9]+$ ]] || continue
        name=${line#*, product=* (}
        name=${name%)}
        [[ "$name" != "$line" && "$name" == *[![:space:]]* ]] || name='FIDO2 device'
        U2F_DEVICES+=("${path#/dev/}")
        U2F_DEVICE_NAMES+=("$name")
    done < <(fido2-token -L 2>/dev/null)
}

U2F_DEVICE=''
U2F_DEVICE_NAME=''
# Select DEVICE (hidrawN or /dev/hidrawN) from the connected authenticators,
# or the only one connected when DEVICE is empty.
u2f_select_device() {
    local device=${1#/dev/} i choices=''
    u2f_detect_keys
    (( ${#U2F_DEVICES[@]} )) || die 'no FIDO2/U2F authenticator is connected'
    if [[ -z "$device" ]]; then
        if (( ${#U2F_DEVICES[@]} > 1 )); then
            for i in "${!U2F_DEVICES[@]}"; do
                choices+="${choices:+, }${U2F_DEVICES[i]} (${U2F_DEVICE_NAMES[i]})"
            done
            die "${#U2F_DEVICES[@]} authenticators are connected; pick one with its Enroll or Add authenticator action, or pass its device: $choices"
        fi
        device=${U2F_DEVICES[0]}
    fi
    [[ "$device" =~ ^hidraw[0-9]+$ ]] || die "invalid authenticator device: $1"
    for i in "${!U2F_DEVICES[@]}"; do
        if [[ "${U2F_DEVICES[i]}" == "$device" ]]; then
            U2F_DEVICE=$device
            U2F_DEVICE_NAME=${U2F_DEVICE_NAMES[i]}
            return 0
        fi
    done
    die "no FIDO2/U2F authenticator is connected at /dev/$device"
}

# DER SubjectPublicKeyInfo prefix of every P-256 key, up to the 0x04 point tag.
readonly U2F_P256_SPKI_PREFIX=3059301306072a8648ce3d020106082a8648ce3d03010703420004

# Print the pam_u2f credential for VERIFIED, the output of `fido2-cred -V`
# (credential id, then the PEM public key). pam_u2f stores an es256 key as
# libfido2's raw 64-byte X||Y, the SPKI tail after the fixed prefix.
u2f_credential_from_verified() {
    local verified=$1 id der hex
    der="$verified.der"
    IFS= read -r id <"$verified" || return 1
    [[ "$id" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
    tail -n +2 -- "$verified" |
        openssl pkey -pubin -inform PEM -outform DER -out "$der" 2>/dev/null || return 1
    hex=$(od -An -v -tx1 -- "$der" | tr -d ' \n')
    [[ ${#hex} == 182 && "$hex" == "$U2F_P256_SPKI_PREFIX"* ]] || return 1
    printf '%s,%s,es256,+presence' "$id" "$(tail -c 64 -- "$der" | base64 -w0)"
}

# Register a new non-resident es256 credential for USER on /dev/DEVICE and
# print it in pam_u2f's mapping format. Runs uncaptured: fido2-cred asks for
# the PIN on the tty when the authenticator has one.
u2f_register() {
    local user=$1 origin=$2 device=$3 work=$4
    command -v fido2-cred >/dev/null || die 'fido2-cred is missing (install libfido2)'
    command -v openssl >/dev/null || die 'openssl is required'
    printf '%s\n' "$(head -c 32 /dev/urandom | base64 -w0)" "$origin" "$user" \
        "$(head -c 32 /dev/urandom | base64 -w0)" |
        runuser -u "$user" -- fido2-cred -M "/dev/$device" es256 >"$work/made" ||
        return 1
    fido2-cred -V -i "$work/made" -o "$work/verified" es256 || return 1
    u2f_credential_from_verified "$work/verified"
}

# Succeed when /dev/DEVICE holds the mapping credential CRED, asking without
# user presence so nothing blinks. FIDO2 keys answer with an assertion; U2F
# keys answer a check-only request with "user presence required".
u2f_device_holds() {
    local device=$1 origin=$2 cred=$3 err
    command -v fido2-assert >/dev/null 2>&1 || return 1
    err=$(printf '%s\n' "$(head -c 32 /dev/urandom | base64 -w0)" "$origin" "${cred%%,*}" |
        timeout 10 fido2-assert -G -t up=false "/dev/$device" 2>&1 >/dev/null) && return 0
    [[ "$err" == *FIDO_ERR_USER_PRESENCE_REQUIRED* ]]
}

U2F_DEVICE_KEYS=()
# Fill U2F_DEVICE_KEYS, parallel to U2F_DEVICES, with the ID of the enrolled
# key each connected authenticator holds, or '' for a key not enrolled.
u2f_match_devices() {
    local user origin cred i
    local -a creds=()
    U2F_DEVICE_KEYS=()
    for i in "${!U2F_DEVICES[@]}"; do U2F_DEVICE_KEYS+=(''); done
    user=$(u2f_enrolled_user) || return 0
    mapfile -t creds < <(u2f_credentials "$U2F_MAPPING" "$user")
    origin=$(tweak_read "$U2F_ID" origin "$(u2f_origin)")
    for i in "${!U2F_DEVICES[@]}"; do
        for cred in "${creds[@]}"; do
            if u2f_device_holds "${U2F_DEVICES[i]}" "$origin" "$cred"; then
                U2F_DEVICE_KEYS[i]=$(u2f_credential_id "$cred")
                break
            fi
        done
    done
}

# The target-user note is root-only. Unprivileged listings fall back to the
# mapping, which the suite creates holding only the enrolled user's line.
u2f_enrolled_user() {
    local user first=''
    user=$(tweak_read "$U2F_ID" target-user '')
    if [[ -z "$user" ]]; then
        [[ -s "$U2F_MAPPING" && -r "$U2F_MAPPING" ]] || return 1
        IFS= read -r first <"$U2F_MAPPING" || true
        user=${first%%:*}
    fi
    [[ -n "$user" ]] || return 1
    printf '%s' "$user"
}

u2f_keys() {
    local user
    user=$(u2f_enrolled_user) || return 0
    u2f_key_list "$U2F_MAPPING" "$user" "$U2F_KEY_LABELS"
}

u2f_build_pam_test() {
    local work=$1
    command -v cc >/dev/null || die 'a C compiler is required for the isolated PAM test (install gcc)'
    [[ -r "$SUITE_DIR/pam-auth-test.c" ]] || die 'pam-auth-test.c is missing from the suite directory'
    cc -Wall -Wextra -Werror -O2 "$SUITE_DIR/pam-auth-test.c" -lpam -o "$work/pam-auth-test" ||
        die 'could not build the isolated PAM test (install GCC and PAM development files)'
    chmod 0755 "$work/pam-auth-test"
}

u2f_ensure_test_service() {
    local origin=$1
    u2f_test_service_ready && return 0
    need_root
    [[ ! -e "$U2F_PAM_DIR/$U2F_TEST_SERVICE" ]] ||
        die "the test PAM service exists but is not managed by this suite"
    u2f_install_test_service "$origin"
}

# Test the enrolled credentials against the suite's minimal, U2F-only PAM
# service. New enrollments install it once; existing enrollments migrate on
# their first privileged test. Once present, the test itself needs no sudo.
u2f_test_credential() {
    u2f_enrolled || die 'no enrollment to test'

    local user origin work current_user rc=0
    local -a test_command=()
    user=$(u2f_enrolled_user) || die 'cannot determine the enrolled account'
    origin=$(tweak_read "$U2F_ID" origin "$(u2f_origin)")
    work=$(mktemp -d -p "$SUITE_WORK")
    if (( EUID == 0 )); then
        chmod 0755 "$work"
    fi
    u2f_build_pam_test "$work"
    u2f_ensure_test_service "$origin"
    msg "Testing the enrolled credentials for '$user' against an isolated PAM stack."
    msg 'Touch any enrolled authenticator now (when it begins blinking).'
    current_user=$(id -un)
    if [[ "$current_user" == "$user" ]]; then
        test_command=("$work/pam-auth-test" "$U2F_TEST_SERVICE" "$user")
    else
        (( EUID == 0 )) || die "run this test as the enrolled account: $user"
        command -v runuser >/dev/null || die 'runuser is required'
        test_command=(runuser -u "$user" -- "$work/pam-auth-test" "$U2F_TEST_SERVICE" "$user")
    fi
    if "${test_command[@]}"; then
        msg ''
        msg 'Authenticator test PASSED — an enrolled key authenticates correctly.'
    else
        warn ''
        warn 'Authenticator test FAILED — the key did not authenticate.'
        rc=1
    fi
    return "$rc"
}
