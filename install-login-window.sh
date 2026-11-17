#!/bin/bash
# Register only the bundled, signed login helper, under the current console user.
set -euo pipefail
export LC_ALL=C
umask 077

usage() {
    echo 'Install: sudo bash install-login-window.sh "/path/to/Final Fusion.app"' >&2
    echo 'Remove: sudo bash install-login-window.sh --remove "/path/to/Final Fusion.app"' >&2
    exit 2
}

action=install
case "${1:-}" in
    --check|--status|--remove) action="${1#--}"; shift ;;
esac
[[ $# -eq 1 || ( "$action" == install && $# -eq 3 ) ]] || usage
app="$1"
info="$app/Contents/Info.plist"
source_helper="$app/Contents/Helpers/StudioLink"

read_info() {
    /usr/bin/plutil -extract "$1" raw -o - "$info" 2>/dev/null
}

[[ "$app" == /*.app && "$(read_info CFBundleExecutable || true)" == StudioRemote &&
   "$(read_info StudioReceiverOnly || true)" != true ]] || usage
identifier="$(read_info CFBundleIdentifier)"
directory="$(read_info FinalFusionSettingsDirectory)"
build="$(read_info CFBundleVersion)"
[[ "$identifier" =~ ^[[:alnum:]][[:alnum:].-]+$ && "$identifier" == *.* &&
   "$directory" =~ ^[[:alnum:]][[:alnum:]\ ._-]*$ && "$build" =~ ^[0-9]+$ ]] || usage
label="$identifier.login-window"
helper_name="$(read_info FinalFusionLoginWindowHelperName || true)"
[[ -z "$helper_name" || "$helper_name" == FinalFusionLoginWindow ]] || usage
helper="/Library/PrivilegedHelperTools/${helper_name:-$label}"
job="/Library/LaunchDaemons/$label.plist"
service="system/$label"
owner="$(/usr/bin/stat -f %Su /dev/console)"
[[ -z "${3:-}" || "$owner" == "$3" ]] || exit 1

is_loaded() {
    /bin/launchctl print "$service" >/dev/null 2>&1
}

if [[ "$action" == status ]]; then
    if [[ ! -e "$job" && ! -e "$helper" ]]; then
        echo off
    elif [[ -f "$job" && -x "$helper" ]] &&
         [[ "$(/usr/bin/plutil -extract UserName raw -o - "$job" 2>/dev/null)" == "$owner" ]] &&
         [[ "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$job" 2>/dev/null)" == "$helper" ]] &&
         [[ "$(/usr/bin/plutil -extract EnvironmentVariables.FINAL_FUSION_HELPER_BUILD raw -o - "$job" 2>/dev/null)" == "$build" ]] &&
         /usr/bin/cmp -s "$source_helper" "$helper" && is_loaded; then
        echo current
    else
        echo reinstall
    fi
    exit 0
fi

check_requirements() {
    if [[ -z "$owner" || "$owner" == root || "$owner" == loginwindow ]]; then
        echo console
        return
    fi
    if [[ "$(/usr/bin/id -u)" != 0 && "$(/usr/bin/id -un)" != "$owner" ]]; then
        echo console
        return
    fi
    account_home="$(/usr/bin/dscacheutil -q user -a name "$owner" | /usr/bin/sed -n 's/^dir: //p')"
    if [[ "$account_home" != /* || "$account_home" == / ]]; then
        echo console
        return
    fi
    settings="$account_home/Library/Application Support/$directory"
    screen_sharing="$(/bin/launchctl print system/com.apple.screensharing 2>/dev/null || true)"
    if [[ "$screen_sharing" != *"service name = vnc-server"* ]]; then
        echo screen-sharing
    elif access_group="$(/usr/bin/dscl . -read /Groups/com.apple.access_screensharing RecordName 2>&1)"; then
        allowed="$(/usr/sbin/dseditgroup -o checkmember -m "$owner" com.apple.access_screensharing 2>/dev/null || true)"
        if [[ "$allowed" != "yes "* ]]; then echo screen-account; fi
    elif [[ "$access_group" != *eDSRecordNotFound* ]]; then
        echo screen-account
    fi
    if [[ ! -s "$settings/relay.json" || ! -s "$settings/relay.key" || ! -s "$settings/host-state.json" ]]; then
        echo start-sharing
    else
        as_owner=()
        if [[ "$(/usr/bin/id -u)" == 0 ]]; then as_owner=(/usr/bin/sudo -u "$owner" --); fi
        # Bash 3.2 under nounset considers an empty array unset.
        trusted="$("${as_owner[@]+"${as_owner[@]}"}" /usr/bin/plutil -extract trusted xml1 -o - "$settings/host-state.json" 2>/dev/null || true)"
        if [[ "$trusted" != *'<true/>'* ]]; then echo pair-viewer; fi
    fi
}

if [[ "$action" == check ]]; then
    check_requirements
    exit 0
fi

[[ "$(/usr/bin/id -u)" == 0 ]] || usage
/usr/bin/codesign --verify --strict --deep "$app"
# Serialize the settings switch and the terminal fallback for this app.
exec 9>>"/var/run/$label.lock"
/usr/bin/lockf -t 15 9
stop_job() {
    /bin/launchctl bootout "$service" 2>/dev/null || ! is_loaded
}

if [[ "$action" == remove ]]; then
    stop_job
    /bin/rm -f -- "$job" "$helper"
    exit 0
fi

issues="$(check_requirements)"
if [[ -n "$issues" ]]; then
    printf '%s\n' 'Check these items in the Final Fusion host settings:' "$issues" >&2
    exit 1
fi
# The function ran in a subshell for its output. Read this account's path again
# and reject a console change while the authorization dialog was open.
[[ "$owner" == "$(/usr/bin/stat -f %Su /dev/console)" ]] || exit 1
account_home="$(/usr/bin/dscacheutil -q user -a name "$owner" | /usr/bin/sed -n 's/^dir: //p')"
[[ "$account_home" == /* && "$account_home" != / ]] || exit 1
settings="$account_home/Library/Application Support/$directory"
expected_digest="${2:-$(/usr/bin/shasum -a 256 < "$source_helper")}"
expected_digest="${expected_digest%% *}"
[[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || exit 1

temp="$(/usr/bin/mktemp -d /private/tmp/final-fusion-login.XXXXXX)"
trap '/bin/rm -rf -- "$temp"' EXIT
staged="$temp/job.plist"
/usr/bin/install -o root -g wheel -m 755 "$source_helper" "$temp/helper"
staged_digest="$(/usr/bin/shasum -a 256 < "$temp/helper")"
[[ "${staged_digest%% *}" == "$expected_digest" ]] || exit 1
/usr/bin/codesign --verify --strict "$temp/helper"
/usr/bin/plutil -create xml1 "$staged"
/usr/bin/plutil -insert Label -string "$label" "$staged"
/usr/bin/plutil -insert UserName -string "$owner" "$staged"
/usr/bin/plutil -insert ProgramArguments -array "$staged"
/usr/bin/plutil -insert ProgramArguments.0 -string "$helper" "$staged"
/usr/bin/plutil -insert ProgramArguments.1 -string login-window-host "$staged"
/usr/bin/plutil -insert ProgramArguments.2 -string "$settings" "$staged"
/usr/bin/plutil -insert EnvironmentVariables -dictionary "$staged"
/usr/bin/plutil -insert EnvironmentVariables.FINAL_FUSION_HELPER_BUILD -string "$build" "$staged"
/usr/bin/plutil -insert RunAtLoad -bool true "$staged"
/usr/bin/plutil -insert KeepAlive -bool true "$staged"
/usr/bin/plutil -lint "$staged" >/dev/null

if [[ -f "$job" ]]; then /bin/cp -- "$job" "$temp/previous.plist"; fi
if [[ -f "$helper" ]]; then /bin/cp -- "$helper" "$temp/previous-helper"; fi
stop_job
if /usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools \
    && /usr/bin/install -o root -g wheel -m 755 "$temp/helper" "$helper" \
    && /usr/bin/install -o root -g wheel -m 644 "$staged" "$job" \
    && /bin/launchctl bootstrap system "$job"; then
    exit 0
fi

stop_job
if [[ -f "$temp/previous-helper" ]]; then
    /usr/bin/install -o root -g wheel -m 755 "$temp/previous-helper" "$helper"
else
    /bin/rm -f -- "$helper"
fi
if [[ -f "$temp/previous.plist" ]]; then
    /usr/bin/install -o root -g wheel -m 644 "$temp/previous.plist" "$job"
    /bin/launchctl bootstrap system "$job" || true
else
    /bin/rm -f -- "$job"
fi
exit 1
