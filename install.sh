#!/usr/bin/env bash
# Fedora post-install for this desktop.
# Install Fedora from USB yourself, boot it, log in as the user who should
# own the files, then:
#   git clone https://github.com/31337x/d0t.git
#   cd d0t
#   bash install.sh
# Files land in /home/<that user>. A curl launch clones the repo first.
# Override the address with D0T_REPO_URL.
set -euo pipefail

REPO_URL="${D0T_REPO_URL:-https://github.com/31337x/d0t.git}"
BRANCH="${D0T_BRANCH:-main}"

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

have_dotfiles() {
  local dir=$1
  [[ -f "$dir/.bashrc" && -d "$dir/.config" && -d "$dir/.local" && -d "$dir/Pictures" ]]
}

script_dir() {
  local source=${BASH_SOURCE[0]:-}
  [[ -n "$source" && -f "$source" ]] || return 1
  cd "$(dirname "$source")" && pwd
}

# curl | bash has no files beside the script, so clone the repo and re-run.
if [[ "${D0T_BOOTSTRAPPED:-0}" != 1 ]]; then
  SRC=""
  if DIR="$(script_dir)"; then
    if have_dotfiles "$DIR"; then
      SRC=$DIR
    fi
  fi
  if [[ -z "$SRC" ]]; then
    log "Cloning $REPO_URL"
    if ! command -v git >/dev/null 2>&1; then
      sudo dnf install -y git-core
    fi
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
    export D0T_BOOTSTRAPPED=1
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    trap - EXIT
    exec bash "$clone_dir/install.sh"
  fi
else
  SRC="$(script_dir)" || die "Could not find the cloned setup files."
  have_dotfiles "$SRC" || die "Cloned repo is missing .bashrc, .config, .local, or Pictures."
fi

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
sudo dnf install -y --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release

log "Updating the system"
sudo dnf upgrade --refresh -y

log "Installing the desktop, shell, and tools"
sudo dnf install -y \
  iwlwifi-mvm-firmware \
  plymouth-theme-spinner \
  google-noto-sans-arabic-vf-fonts \
  google-noto-naskh-arabic-vf-fonts \
  google-noto-color-emoji-fonts \
  google-noto-sans-symbols-vf-fonts \
  google-noto-sans-math-fonts \
  tuned \
  tuned-ppd \
  noctalia \
  noctalia-greeter \
  greetd \
  umbriel-nightly \
  kitty \
  yazi \
  helix \
  helix-parsers \
  gnome-keyring-pam \
  zen-browser \
  mpv \
  imv \
  btop \
  freerdp \
  openfortivpn \
  git-core \
  tar \
  bat \
  fzf \
  zoxide \
  starship \
  fastfetch \
  xdg-user-dirs \
  adw-gtk3-theme \
  cursor \
  upower \
  yt-dlp \
  pipewire-pulseaudio \
  pipewire-alsa

if rpm -q ffmpeg-free >/dev/null 2>&1; then
  log "Replacing ffmpeg-free with ffmpeg"
  sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
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
  BEGIN { in_appearance = 0; done = 0 }
  /^\[appearance\]/ { in_appearance = 1; print; next }
  /^\[/ {
    if (in_appearance && !done) {
      print "hide_logo = true"
      done = 1
    }
    in_appearance = 0
    print
    next
  }
  in_appearance && /^[[:space:]]*hide_logo[[:space:]]*=/ {
    print "hide_logo = true"
    done = 1
    next
  }
  { print }
  END {
    if (done) exit
    if (in_appearance) {
      print "hide_logo = true"
    } else {
      print ""
      print "[appearance]"
      print "hide_logo = true"
    }
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
xdg-user-dirs-update
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

log "Installing Codex"
curl -fsSL https://chatgpt.com/codex/install.sh | sh

log "Removing packages that are no longer needed"
sudo dnf autoremove -y

log "Setup finished for ${TARGET_USER} (${TARGET_HOME}). Rebooting in 15 seconds. Press Ctrl+C to stay on this console."
sleep 15
sudo systemctl reboot
