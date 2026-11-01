# d0t

Post-install for a Fedora system you already installed from USB.

Log in as the user who should own the files, then:

```bash
git clone https://github.com/31337x/d0t.git
cd d0t
bash install.sh
```

Running it as `x` installs into `/home/x`. Running it as `t00r` installs into `/home/t00r`. The script asks for sudo for system changes, then reboots.
