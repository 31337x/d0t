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

if [[ "$INSTALL_CODEX" == true ]]; then
  log "Installing Codex"
  curl -fsSL https://chatgpt.com/codex/install.sh | sh
else
  log "Skipping Codex"
fi

log "Removing packages that are no longer needed"
sudo dnf autoremove -y

log "Setup finished for ${TARGET_USER} (${TARGET_HOME}). Rebooting in 15 seconds. Press Ctrl+C to stay on this console."
sleep 15
sudo systemctl reboot
