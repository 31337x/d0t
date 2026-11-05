#!/usr/bin/env bash
#   git clone https://github.com/31337x/d0t.git
#   cd d0t
#   bash install.sh
# Files land in /home/<that user>. A curl launch clones the repo first.
set -euo pipefail

# When launched with curl | bash, save and syntax-check the entire script
# before running commands that could consume its standard-input stream.
if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
  installer_tmp="$(mktemp)"
  curl -fsSL https://raw.githubusercontent.com/31337x/d0t/main/install.sh -o "$installer_tmp" </dev/null
  bash -n "$installer_tmp" || { rm -f "$installer_tmp"; exit 1; }
  bash "$installer_tmp"
  result=$?
  rm -f "$installer_tmp"
  exit "$result"
fi

REPO_URL="https://github.com/31337x/d0t.git"
BRANCH="main"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [[ "$(id -u)" -eq 0 ]]; then
  die "Run this as the normal user (the one who should own /home/USER). The script will ask for sudo."
fi

TARGET_USER="$(id -un)"
TARGET_HOME="/home/${TARGET_USER}"
[[ -d "$TARGET_HOME" ]] || die "Expected a home directory at ${TARGET_HOME}."
export HOME="$TARGET_HOME"
export USER="$TARGET_USER"
cd "$HOME"

[[ -f /etc/fedora-release ]] || die "This script is for Fedora, after you have installed it and booted it."

# Collect optional choices before starting the installation.
ask_yes_no() {
  local prompt=$1 default=$2 reply
  while true; do
    read -r -p "$prompt" reply < /dev/tty || die "Cannot read from terminal."
    reply="${reply:-$default}"
    case "$reply" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
      *) printf 'Please answer y or n.\n' > /dev/tty ;;
    esac
  done
}
log "Choose optional components before installation"
INSTALL_INTEL_WIFI=false
INSTALL_AMD_ROCM=false
if ask_yes_no "Install Intel Wi-Fi firmware? [y/N]: " n; then INSTALL_INTEL_WIFI=true; fi
if ask_yes_no "Install AMD ROCm utilities? [y/N]: " n; then INSTALL_AMD_ROCM=true; fi
log "Choices saved. Starting installation."

sudo -v
sudo_keepalive() {
  while true; do
    sudo -n true
    sleep 50
  done
}
sudo_keepalive &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

write_root_file() {
  local dest=$1
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  sudo cp "$tmp" "$dest"
  sudo chmod 644 "$dest"
  rm -f "$tmp"
}

log "Pointing dnf at faster mirrors and skipping weak dependencies"
sudo cat /etc/dnf/dnf.conf | awk '
  function emit_missing() {
    if (!seen_weak) print "install_weak_deps=False"
    if (!seen_parallel) print "max_parallel_downloads=20"
    if (!seen_fast) print "fastestmirror=True"
    seen_weak = seen_parallel = seen_fast = 1
  }
  BEGIN { inmain = 0; seen_weak = 0; seen_parallel = 0; seen_fast = 0; saw_main = 0 }
  /^\[main\][[:space:]]*$/ { inmain = 1; saw_main = 1; print; next }
  /^\[/ {
    if (inmain) emit_missing()
    inmain = 0
    print
    next
  }
  inmain && /^[[:space:]]*install_weak_deps[[:space:]]*=/ { print "install_weak_deps=False"; seen_weak = 1; next }
  inmain && /^[[:space:]]*max_parallel_downloads[[:space:]]*=/ { print "max_parallel_downloads=20"; seen_parallel = 1; next }
  inmain && /^[[:space:]]*fastestmirror[[:space:]]*=/ { print "fastestmirror=True"; seen_fast = 1; next }
  { print }
  END {
    if (!saw_main) {
      print "[main]"
      emit_missing()
    } else if (inmain) {
      emit_missing()
    }
  }
' | write_root_file /etc/dnf/dnf.conf

log "Enabling RPM Fusion and Terra"
release="$(rpm -E %fedora)"
sudo dnf install -y "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${release}.noarch.rpm"
sudo dnf install -y "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${release}.noarch.rpm"
if rpm -q terra-release >/dev/null 2>&1 || grep -Rqs '^\[terra\]' /etc/yum.repos.d/; then
  log "Terra already configured; skipping bootstrap"
else
  sudo dnf install -y --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release
fi

log "Updating the system"
sudo dnf upgrade --refresh -y

log "Installing oo7 secrets management"
sudo dnf install -y oo7-daemon pam_oo7

log "Installing greetd"
sudo dnf install -y greetd

log "Installing the desktop environment"
sudo dnf install -y noctalia-nightly umbriel-nightly noctalia-greeter adw-gtk3-theme

log "Installing audio components"
sudo dnf install -y pipewire pipewire-alsa pipewire-pulseaudio pipewire-utils wireplumber

log "Installing system and boot components"
sudo dnf install -y plymouth-theme-spinner tuned tuned-ppd

log "Installing fonts"
sudo dnf install -y \
  google-noto-sans-arabic-vf-fonts \
  google-noto-naskh-arabic-vf-fonts \
  google-noto-color-emoji-fonts \
  google-noto-sans-symbols-vf-fonts \
  google-noto-sans-math-fonts

log "Installing applications and utilities"
sudo dnf install -y \
  cursor zen-browser kitty yazi helix btop bat fzf zoxide starship \
  fastfetch git-core tar ripgrep fd-find mpv imv freerdp \
  openfortivpn yt-dlp upower grim slurp ddcutil

log "Installing full FFmpeg from RPM Fusion"
if rpm -q ffmpeg-free >/dev/null 2>&1; then
  sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
else
  sudo dnf install -y ffmpeg --allowerasing
fi
sudo dnf install -y ffmpeg-libs --allowerasing

log "Installing selected hardware packages"
if [[ "$INSTALL_INTEL_WIFI" == true ]]; then
  sudo dnf install -y iwlwifi-mvm-firmware
fi
if [[ "$INSTALL_AMD_ROCM" == true ]]; then
  sudo dnf install -y rocm-smi
fi

have_dotfiles() {
  local dir=$1
  [[ -f "$dir/.bashrc" && -d "$dir/.config" && -d "$dir/.local" && -d "$dir/Pictures" ]]
}

script_dir() {
  local source=${BASH_SOURCE[0]:-}
  [[ -n "$source" && -f "$source" ]] || return 1
  cd "$(dirname "$source")" && pwd
}

# Resolve dotfiles after Git has been installed with the applications.
SRC=""
if DIR="$(script_dir)" && have_dotfiles "$DIR"; then
  SRC="$DIR"
else
  log "Cloning $REPO_URL"
  clone_dir="${XDG_CACHE_HOME:-$HOME/.cache}/d0t"
  mkdir -p "$(dirname "$clone_dir")"
  if [[ -d "$clone_dir/.git" ]]; then
    git -C "$clone_dir" fetch --depth 1 origin "$BRANCH"
    git -C "$clone_dir" checkout "$BRANCH"
    git -C "$clone_dir" reset --hard "origin/$BRANCH"
  else
    rm -rf "$clone_dir"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$clone_dir"
  fi
  SRC="$clone_dir"
  have_dotfiles "$SRC" || die "Cloned repo is missing .bashrc, .config, .local, or Pictures."
fi

log "Shortening the boot menu"
sudo cat /etc/default/grub | awk '
  BEGIN { saw_timeout = 0; saw_style = 0 }
  /^[[:space:]]*GRUB_TIMEOUT=/ { print "GRUB_TIMEOUT=2"; saw_timeout = 1; next }
  /^[[:space:]]*GRUB_TIMEOUT_STYLE=/ { print "GRUB_TIMEOUT_STYLE=hidden"; saw_style = 1; next }
  { print }
  END {
    if (!saw_timeout) print "GRUB_TIMEOUT=2"
    if (!saw_style) print "GRUB_TIMEOUT_STYLE=hidden"
  }
' | write_root_file /etc/default/grub
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

log "Using the Noctalia greeter"
if sudo test -f /etc/greetd/config.toml; then
  sudo cat /etc/greetd/config.toml
fi | awk '
  BEGIN { in_session = 0; done = 0 }
  /^\[default_session\]/ { in_session = 1; print; next }
  /^\[/ {
    if (in_session && !done) {
      print "command = \"/usr/bin/noctalia-greeter-session\""
      done = 1
    }
    in_session = 0
    print
    next
  }
  in_session && /^[[:space:]]*command[[:space:]]*=/ {
    print "command = \"/usr/bin/noctalia-greeter-session\""
    done = 1
    next
  }
  { print }
  END {
    if (done) exit
    if (in_session) {
      print "command = \"/usr/bin/noctalia-greeter-session\""
    } else {
      print ""
      print "[default_session]"
      print "command = \"/usr/bin/noctalia-greeter-session\""
      print "user = \"greetd\""
    }
  }
' | write_root_file /etc/greetd/config.toml

log "Setting the boot splash"
sudo plymouth-set-default-theme -R spinner

log "Preparing the greeter data directory"
sudo install -d -o greetd -g "$(id -gn greetd)" -m 0750 /var/lib/noctalia-greeter
sudo env GREETER_USER=greetd noctalia-greeter-apply-appearance --setup-system

greeter_file=/var/lib/noctalia-greeter/greeter.toml
if sudo test -f "$greeter_file"; then
  sudo cat "$greeter_file"
else
  printf ''
fi | awk '
  function finish_section() {
    if (section == "appearance" && !seen_hide) print "hide_logo = true"
    if (section == "clock") {
      if (!seen_enabled) print "enabled = true"
      if (!seen_format) print "time_format = \"{:%-I:%M %p}\""
    }
  }
  /^\[/ {
    finish_section()
    section = ""
    if ($0 == "[appearance]") { section = "appearance"; has_appearance = 1; seen_hide = 0 }
    if ($0 == "[clock]") { section = "clock"; has_clock = 1; seen_enabled = 0; seen_format = 0 }
    print
    next
  }
  section == "appearance" && /^[[:space:]]*hide_logo[[:space:]]*=/ {
    print "hide_logo = true"; seen_hide = 1; next
  }
  section == "clock" && /^[[:space:]]*enabled[[:space:]]*=/ {
    print "enabled = true"; seen_enabled = 1; next
  }
  section == "clock" && /^[[:space:]]*time_format[[:space:]]*=/ {
    print "time_format = \"{:%-I:%M %p}\""; seen_format = 1; next
  }
  { print }
  END {
    finish_section()
    if (!has_appearance) print "\n[appearance]\nhide_logo = true"
    if (!has_clock) print "\n[clock]\nenabled = true\ntime_format = \"{:%-I:%M %p}\""
  }
' | write_root_file "$greeter_file"
sudo chown greetd:"$(id -gn greetd)" "$greeter_file"

log "Enabling services and a graphical boot"
sudo systemctl enable --now tuned tuned-ppd
sudo systemctl enable greetd.service
sudo systemctl set-default graphical.target
sudo systemctl enable --now upower
sudo loginctl enable-linger "$TARGET_USER"

log "Starting PipeWire for this user"
systemctl --user daemon-reload
systemctl --user enable --now pipewire-pulse.socket
systemctl --user restart pipewire wireplumber pipewire-pulse

log "Installing your files into ${TARGET_HOME}"
mkdir -p "$TARGET_HOME/.config" "$TARGET_HOME/.local" "$TARGET_HOME/Pictures/Screenshots"
cp -a "$SRC/.bashrc" "$TARGET_HOME/.bashrc"
cp -a "$SRC/.config/." "$TARGET_HOME/.config/"
cp -a "$SRC/.local/." "$TARGET_HOME/.local/"
cp -a "$SRC/Pictures/." "$TARGET_HOME/Pictures/"

while IFS= read -r -d '' file; do
  sed -i "s|/home/r00t|${TARGET_HOME}|g" "$file"
done < <(grep -rlZ --binary-files=without-match /home/r00t \
  "$TARGET_HOME/.config" "$TARGET_HOME/.local" "$TARGET_HOME/.bashrc" || true)

fc-cache -f
sudo setcap cap_perfmon=+ep "$(readlink -f "$(command -v btop)")"

log "Removing packages that are no longer needed"
sudo dnf autoremove -y

log "Setup finished for ${TARGET_USER} (${TARGET_HOME}). Rebooting in 15 seconds. Press Ctrl+C to stay on this console."
sleep 15
sudo systemctl reboot
