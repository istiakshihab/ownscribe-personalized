#!/usr/bin/env bash
# Install or update Earshot, the ownscribe recorder app, on this Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/istiakshihab/ownscribe-personalized/main/install.sh | bash
#
# Everything is built here, so macOS never sees a downloaded unsigned app. It sets up what's
# missing (Command Line Tools, uv, ffmpeg via Homebrew), fetches the source, installs the Python
# backend, builds the capture helper and Earshot.app, and puts the app in /Applications.
# Run it again to update. Recordings, settings and downloaded models are never touched.
#
# Options (after `bash -s --` when piping from curl):
#   --dir DIR       where the source lives (default ~/.local/share/earshot/ownscribe).
#                   Run from inside a checkout (bash install.sh) to build that checkout instead.
#   --branch NAME   branch to install (default main)
#   --app-dir DIR   where Earshot.app goes (default /Applications, or ~/Applications)
#   --no-open       don't open Earshot at the end
#   --uninstall     remove Earshot.app and the downloaded source (asks first)
#
# Written for macOS's bash 3.2. Nothing runs until the last line, so when piped into bash the
# script only starts once all of it has arrived, and no command can read the rest of it from stdin.

main() {
    set -euo pipefail

    local repo="${EARSHOT_REPO:-https://github.com/istiakshihab/ownscribe-personalized.git}"
    local branch="main" src="" app_dir="" open_app=1 uninstall=0 checkout=0 managed=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir) src="${2:?--dir needs a folder}"; shift ;;
            --branch) branch="${2:?--branch needs a name}"; shift ;;
            --app-dir) app_dir="${2:?--app-dir needs a folder}"; shift ;;
            --no-open) open_app=0 ;;
            --uninstall) uninstall=1 ;;
            -h|--help) usage; return 0 ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done

    # Run as `bash install.sh` from a checkout: build that one, and leave its git state alone.
    local here=""
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    if [ -z "$src" ] && [ -n "$here" ] && [ -f "$here/app/build.sh" ] && [ -f "$here/swift/build.sh" ]; then
        src="$here"
        checkout=1
    fi
    if [ -z "$src" ]; then src="$HOME/.local/share/earshot/ownscribe"; managed=1; fi
    case "$src" in /*) ;; *) src="$PWD/$src" ;; esac
    if [ -z "$app_dir" ]; then
        if [ -w /Applications ]; then app_dir="/Applications"; else app_dir="$HOME/Applications"; fi
    fi

    if [ "$uninstall" = 1 ]; then
        do_uninstall "$src" "$app_dir" "$checkout"
        return 0
    fi

    printf '\n%sInstalling Earshot%s\n\n' "$BOLD" "$RESET"
    check_mac
    check_command_line_tools
    local uv
    uv="$(find_or_install_uv)"
    check_ffmpeg
    get_source "$repo" "$branch" "$src" "$checkout" "$managed"

    local log
    log="$(mktemp -t earshot-install)"

    step "Installing the Python backend (the first time downloads about 2 GB)"
    # Keep uv's download progress, drop its list of every installed package. In your own
    # checkout, only add what's missing: never remove packages you installed yourself.
    local sync=("$uv" sync --frozen --project "$src")
    if [ "$checkout" = 1 ]; then sync+=(--inexact); fi
    if ! "${sync[@]}" </dev/null 2>&1 | { grep -v '^ [-+~] ' || true; }; then
        die "Installing the Python backend failed (see above)."
    fi
    ok "Backend ready in $(short "$src")/.venv"

    step "Building the capture helper"
    run_logged "$log" "Building the capture helper failed" bash "$src/swift/build.sh"
    ok "Built $(short "$src")/bin/ownscribe-audio"

    step "Building Earshot (a few minutes the first time)"
    run_logged "$log" "Building Earshot failed" bash "$src/app/build.sh" release
    ok "Built Earshot.app"
    rm -f "$log"

    install_app "$src/app/build/Earshot.app" "$app_dir"
    report_doctor "$uv" "$src"

    printf '\n%sDone.%s Earshot is in %s.\n' "$BOLD" "$RESET" "$(short "$app_dir")"
    printf '  • The first recording asks for Microphone and System Audio Recording access.\n'
    printf '  • Models download the first time you transcribe (Whisper is about 1.6 GB).\n'
    printf '  • To update later, run the same command again.\n\n'
    if [ "$open_app" = 1 ]; then open "$app_dir/Earshot.app"; fi
}

usage() {
    cat <<'EOF'
Install or update Earshot on this Mac.

  curl -fsSL https://raw.githubusercontent.com/istiakshihab/ownscribe-personalized/main/install.sh | bash
  curl -fsSL .../install.sh | bash -s -- [options]
  bash install.sh [options]          (from a checkout: builds that checkout)

  --dir DIR       where the source lives (default ~/.local/share/earshot/ownscribe)
  --branch NAME   branch to install (default main)
  --app-dir DIR   where Earshot.app goes (default /Applications, or ~/Applications)
  --no-open       don't open Earshot at the end
  --uninstall     remove Earshot.app and the downloaded source (asks first)
EOF
}

# ---------------------------------------------------------------- output

if [ -t 1 ]; then
    BOLD=$'\033[1m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' RESET=$'\033[0m'
else
    BOLD="" GREEN="" YELLOW="" RED="" RESET=""
fi
step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
ok() { printf '    %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '    %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
die() { printf '\n%s✗ %s%s\n\n' "$RED" "$*" "$RESET" >&2; exit 1; }
# ~/path for display. (Not ${1/#$HOME/~}: bash 5.2 expands that ~ back to $HOME, 3.2 doesn't.)
short() {
    case "$1" in
        "$HOME") printf '~' ;;
        "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Run a noisy command quietly; on failure show the end of its output and stop.
run_logged() {
    local log="$1" message="$2"
    shift 2
    if ! "$@" >"$log" 2>&1 </dev/null; then
        tail -n 30 "$log" >&2
        die "$message (full log: $log)"
    fi
}

# ---------------------------------------------------------------- steps

check_mac() {
    step "Checking this Mac"
    if [ "$(uname -s)" != Darwin ]; then die "Earshot runs on macOS only."; fi
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != 1 ]; then
        die "Earshot needs an Apple silicon Mac: transcription runs on Apple's MLX."
    fi
    if [ "$(uname -m)" != arm64 ]; then
        die "This terminal runs under Rosetta. Open Terminal natively and run the command again."
    fi
    local version
    version="$(sw_vers -productVersion)"
    if [ "${version%%.*}" -lt 26 ]; then die "Earshot needs macOS 26 or later; this Mac has $version."; fi
    ok "macOS $version on Apple silicon"
}

check_command_line_tools() {
    if xcode-select -p >/dev/null 2>&1 && xcrun --find swiftc >/dev/null 2>&1; then
        ok "Command Line Tools"
        return 0
    fi
    step "Installing Apple's Command Line Tools"
    xcode-select --install >/dev/null 2>&1 || true
    die "Finish the Command Line Tools install in the window that opened, then run this command again."
}

# Prints uv's path on stdout; messages go to stderr, so $(...) captures only the path.
find_or_install_uv() {
    local uv=""
    if command -v uv >/dev/null 2>&1; then
        uv="$(command -v uv)"
    elif [ -x "$HOME/.local/bin/uv" ]; then
        uv="$HOME/.local/bin/uv"
    else
        step "Installing uv, the Python package manager, into ~/.local/bin" >&2
        # Download first, then run: piping curl into `sh </dev/null` would hand sh an empty script.
        local installer
        installer="$(mktemp -t uv-install)"
        if ! curl -LsSf https://astral.sh/uv/install.sh -o "$installer"; then
            rm -f "$installer"
            die "Couldn't download uv's installer from astral.sh. Check the connection and run this again."
        fi
        if ! sh "$installer" --quiet --no-modify-path </dev/null >&2; then
            rm -f "$installer"
            die "Installing uv failed. See https://docs.astral.sh/uv/getting-started/installation/"
        fi
        rm -f "$installer"
        uv="$HOME/.local/bin/uv"
        if [ ! -x "$uv" ]; then die "uv was installed but isn't at $uv."; fi
    fi
    ok "uv $("$uv" --version | awk '{print $2}')" >&2
    printf '%s\n' "$uv"
}

check_ffmpeg() {
    local p
    if command -v ffmpeg >/dev/null 2>&1; then ok "ffmpeg"; return 0; fi
    for p in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
        if [ -x "$p" ]; then ok "ffmpeg"; return 0; fi
    done
    local brew=""
    if command -v brew >/dev/null 2>&1; then
        brew="$(command -v brew)"
    elif [ -x /opt/homebrew/bin/brew ]; then
        brew=/opt/homebrew/bin/brew
    fi
    if [ -n "$brew" ]; then
        step "Installing ffmpeg with Homebrew"
        if "$brew" install --quiet ffmpeg </dev/null; then ok "ffmpeg"; else warn "brew install ffmpeg failed; transcription needs it."; fi
        return 0
    fi
    warn "ffmpeg is missing and Homebrew isn't installed. Transcription needs ffmpeg:"
    warn "install Homebrew from https://brew.sh, then run: brew install ffmpeg"
}

get_source() {
    local repo="$1" branch="$2" src="$3" checkout="$4" managed="$5"
    if [ "$checkout" = 1 ]; then
        step "Using this checkout: $(short "$src")"
        return 0
    fi
    if [ -d "$src/.git" ]; then
        step "Updating the source in $(short "$src")"
        if [ -n "$(git -C "$src" status --porcelain)" ]; then
            die "$(short "$src") has local changes. Commit or discard them, or pass --dir to use another folder."
        fi
        git -C "$src" fetch --quiet origin "$branch" </dev/null
        if [ "$managed" = 1 ]; then
            # The installer's own copy (no local changes, checked above) just mirrors the branch,
            # even if its history was rewritten.
            git -C "$src" checkout --quiet -B "$branch" "origin/$branch" </dev/null
        else
            if ! git -C "$src" checkout --quiet "$branch" </dev/null 2>/dev/null; then
                git -C "$src" checkout --quiet -b "$branch" "origin/$branch" </dev/null
            fi
            if ! git -C "$src" merge --ff-only --quiet "origin/$branch" </dev/null 2>/dev/null; then
                die "Can't fast-forward $(short "$src") to origin/$branch: it has commits of its own."
            fi
        fi
    elif [ -e "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
        die "$(short "$src") exists and isn't a git checkout. Move it away or pass --dir."
    else
        step "Downloading the source to $(short "$src")"
        mkdir -p "$(dirname "$src")"
        git clone --quiet --branch "$branch" "$repo" "$src" </dev/null
    fi
    ok "$(git -C "$src" log -1 --format='%h %s' | cut -c1-72)"
}

is_earshot() {
    [ "$(defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null || true)" = com.ownscribe.earshot ]
}

install_app() {
    local built="$1" app_dir="$2" target="$2/Earshot.app"
    step "Installing Earshot.app in $(short "$app_dir")"
    if pgrep -xq Earshot; then
        die "Earshot is open. Quit it first (a recording in progress would stop), then run this again."
    fi
    mkdir -p "$app_dir"
    if [ -e "$target" ]; then
        # Only ever replace an Earshot bundle, never something else that happens to have the name.
        if ! is_earshot "$target"; then die "$target exists and isn't Earshot; not replacing it."; fi
        rm -rf "$target"
    fi
    ditto "$built" "$target"
    # Let Spotlight and Launchpad find the new copy right away.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$target" >/dev/null 2>&1 || true
    ok "Installed $(short "$target")"
}

report_doctor() {
    local uv="$1" src="$2" json
    step "Checking the setup"
    json="$("$uv" run --frozen --project "$src" ownscribe doctor --json 2>/dev/null </dev/null || true)"
    if [ -z "$json" ]; then
        warn "ownscribe doctor gave no report; Earshot lists setup problems when it opens."
        return 0
    fi
    "$src/.venv/bin/python" -I -c '
import json, sys
checks = json.loads(sys.argv[1]).get("checks", {})
color = sys.stdout.isatty()
def say(good, text):
    mark = "✓" if good else "!"
    if color:
        mark = ("\033[32m" if good else "\033[33m") + mark + "\033[0m"
    print("    " + mark + " " + text)

c = checks.get("ffmpeg", {})
say(c.get("ok"), "ffmpeg" if c.get("ok") else "ffmpeg is missing; transcription needs it (brew install ffmpeg)")
c = checks.get("hf_token", {})
if c.get("ok"):
    say(True, "Hugging Face token")
else:
    say(False, "No Hugging Face token yet. Telling speakers apart needs one: in Earshot, open")
    print("      Settings > Hugging Face and paste a token from https://huggingface.co/settings/tokens,")
    print("      then accept the model terms at https://huggingface.co/pyannote/speaker-diarization-community-1")
c = checks.get("summarizer", {})
if c:
    name = "{} ({})".format(c.get("backend"), c.get("model"))
    say(c.get("ok"), "Summaries: " + name if c.get("ok") else "Summaries: " + name + " is not available yet")
c = checks.get("capture_helper", {})
say(c.get("ok") and c.get("session_mode"), "Capture helper" if c.get("ok") else "Capture helper is missing")
c = checks.get("disk", {})
if c.get("free_bytes") is not None:
    free = c["free_bytes"] / 1e9
    say(free > 5, "{:.0f} GB free".format(free) + ("" if free > 5 else "; models and recordings need several GB"))
' "$json" || warn "Couldn't read the setup report."
}

do_uninstall() {
    local src="$1" app_dir="$2" checkout="$3" p answer
    local items=()
    for p in "$app_dir/Earshot.app" "/Applications/Earshot.app" "$HOME/Applications/Earshot.app"; do
        if [ -d "$p" ] && is_earshot "$p"; then
            case " ${items[*]-} " in *" $p "*) ;; *) items+=("$p") ;; esac
        fi
    done
    # A checkout you ran this from is yours; only the folder this script downloads is removed.
    if [ "$checkout" = 0 ] && [ -d "$src/.git" ]; then items+=("$src"); fi
    if [ -d "$HOME/Library/Logs/Earshot" ]; then items+=("$HOME/Library/Logs/Earshot"); fi

    if [ ${#items[@]} -eq 0 ]; then
        printf 'Nothing to remove: no Earshot.app or downloaded source found.\n'
        return 0
    fi
    if pgrep -xq Earshot; then die "Earshot is open. Quit it first, then run this again."; fi
    printf '\nThis removes:\n'
    for p in "${items[@]}"; do printf '  %s\n' "$(short "$p")"; done
    printf "  Earshot's own settings (mixer levels, recent folders)\n"
    printf '\nIt keeps your recordings, ~/.config/ownscribe and downloaded models (~/.cache/huggingface).\n'
    printf 'Remove them? [y/N] '
    if ! read -r answer </dev/tty 2>/dev/null; then die "Run --uninstall in a terminal so it can ask first."; fi
    case "$answer" in
        y|Y|yes|YES) ;;
        *) printf 'Nothing removed.\n'; return 0 ;;
    esac
    for p in "${items[@]}"; do rm -rf "$p"; done
    defaults delete com.ownscribe.earshot >/dev/null 2>&1 || true
    printf 'Removed. Microphone and System Audio Recording access can be cleared in System Settings > Privacy & Security.\n'
}

main "$@"
