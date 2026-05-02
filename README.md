# hyprlock-howdy

Windows Hello-style face unlock for Hyprland's lock screen using an IR camera.

Lock your screen, look at the camera, and it unlocks — no password needed. Falls back to password if face isn't recognized within 5 seconds.

## How it works

```
Screen locks → hyprlock renders → sends Enter via ydotool → PAM triggers →
pam_howdy.so activates IR camera → face matched → instant unlock
                                 → no match → type password
```

## Tested on

| Component | Version |
|-----------|---------|
| Laptop | HP Envy x360 2-in-1 14-fa0xxx |
| Camera | HP 5MP Camera with IR (Chicony 04f2:b7fe) |
| OS | CachyOS (Arch-based) |
| Kernel | 7.0.2-1-cachyos |
| CPU | AMD Ryzen 7 8840HS |
| WM | Hyprland 0.54.3 |
| Lock screen | hyprlock 0.9.5 |
| Face auth | howdy-git r592.d3ab993 |

## Requirements

- Arch Linux (or derivative like CachyOS, EndeavourOS, Manjaro)
- Hyprland + hyprlock
- IR camera (check with `v4l2-ctl --list-devices`)
- AUR helper (paru or yay)

## Install

```bash
git clone https://github.com/elmaleek/hyprlock-howdy.git
cd hyprlock-howdy
chmod +x install.sh
./install.sh
```

The script will:
1. Install `python-dlib` (CPU-only build, skips the ~6GB CUDA dependency)
2. Install `howdy-git` (face recognition PAM module)
3. Install and configure `ydotool` (kernel-level key simulation for Wayland)
4. Auto-detect your IR camera
5. Configure howdy with optimal settings
6. Set up PAM for hyprlock
7. Install the face-unlock trigger script
8. Patch your hyprlock config
9. Prompt you to enroll your face

## Manual setup

If you prefer to do it step by step:

### 1. Install python-dlib without CUDA

The default AUR package pulls in CUDA (~6GB). Build CPU-only instead:

```bash
paru -G python-dlib
cd python-dlib
sed -i 's/_build_cuda=1/_build_cuda=0/' PKGBUILD
makepkg -si
```

### 2. Install howdy-git

```bash
paru -S howdy-git
```

### 3. Install ydotool

```bash
sudo pacman -S ydotool
sudo usermod -aG input $USER
echo 'KERNEL=="uinput", GROUP="input", MODE="0660"' | sudo tee /etc/udev/rules.d/80-uinput.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
sudo modprobe uinput
systemctl --user enable --now ydotool.service
```

You may need to log out and back in for the group change to take effect.

### 4. Find your IR camera

```bash
v4l2-ctl --list-devices
```

Look for "IR Camera" in the output. Note the `/dev/videoX` number, then find its stable path:

```bash
ls -la /dev/v4l/by-path/ | grep videoX
```

### 5. Configure howdy

```bash
sudo howdy config
```

Set these values:
```ini
[video]
device_path = /dev/v4l/by-path/YOUR-IR-CAMERA-PATH
dark_threshold = 90
timeout = 5
certainty = 3.5
```

### 6. Enroll your face

```bash
sudo howdy add
```

Look straight at the IR camera. Add multiple models for reliability:

```bash
sudo howdy add  # without glasses
sudo howdy add  # with glasses
sudo howdy add  # different angle
```

### 7. Configure PAM

Replace `/etc/pam.d/hyprlock` with:

```
auth      sufficient  /usr/lib/security/pam_howdy.so
auth      required    pam_unix.so try_first_pass
```

This is the critical part. Do NOT use `auth include system-login` — the `pam_faillock.so` and `pam_unix.so required` modules inside it will override howdy's `sufficient` success.

### 8. Install the face-unlock trigger

Save to `~/.local/bin/omarchy-face-unlock`:

```bash
#!/bin/bash
sleep 1
if pidof hyprlock > /dev/null 2>&1; then
    ydotool key 28:1 28:0
fi
```

Make it executable: `chmod +x ~/.local/bin/omarchy-face-unlock`

### 9. Configure hyprlock

In `~/.config/hypr/hyprlock.conf`:

1. Set `ignore_empty_input = false` in the `general` section
2. Add these labels:

```
# Trigger face unlock automatically when hyprlock starts
label {
    monitor =
    text = cmd[update:999999] omarchy-face-unlock
    font_size = 1
    color = rgba(0, 0, 0, 0)
    position = 0, 0
    halign = center
    valign = center
}
```

## How the PAM config works

```
auth  sufficient  /usr/lib/security/pam_howdy.so   ← try face first
auth  required    pam_unix.so try_first_pass       ← fallback to password
```

- `sufficient` means: if howdy succeeds, authentication is complete — skip everything else
- If howdy fails (timeout, no face detected), PAM continues to `pam_unix.so` which prompts for password
- Do NOT use `auth include system-login` as the fallback — it contains `required` modules that conflict with howdy's `sufficient` status

## Why ydotool?

Hyprlock only triggers PAM authentication when the user submits input (presses Enter). It doesn't auto-start face scanning like Windows Hello does natively.

The workaround: a hidden `cmd[]` label in hyprlock runs `omarchy-face-unlock` on render, which sends an Enter keypress via ydotool after 1 second. This triggers PAM → howdy → IR camera → face scan.

ydotool works at the kernel/evdev level, so it can send keys even through Wayland's session lock (unlike wtype which is blocked by ext-session-lock).

## Troubleshooting

### IR camera doesn't activate

Check if howdy works outside hyprlock:
```bash
sudo howdy test  # needs a display (may crash in pure Wayland)
python /usr/lib/howdy/compare.py $USER  # direct test, no GUI needed
```

### "Authentication failed" but camera never turns on

Your PAM config is wrong. Make sure `/etc/pam.d/hyprlock` uses the minimal config (see step 7). Do NOT include `system-login`.

### ydotool permission denied / face unlock stops working after reboot

```bash
ls -la /dev/uinput  # should be root:input 0660
groups              # should include 'input'
systemctl --user status ydotool.service  # should be active
```

If `/dev/uinput` is `root:root 0600`, the udev rule isn't applying. Fix:

```bash
sudo chmod 0660 /dev/uinput && sudo chgrp input /dev/uinput
systemctl --user reset-failed ydotool.service
systemctl --user start ydotool.service
```

The install script creates a systemd override that adds a 2-second delay before ydotool starts, giving udev time to apply permissions. If it still fails after reboot, check:

```bash
cat /etc/udev/rules.d/80-uinput.rules
# Should contain: KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", ...
```

If you just added yourself to the input group, log out and back in.

### Face not recognized reliably

- Add more face models: `sudo howdy add` (different angles, lighting, glasses)
- Increase certainty threshold: edit `/etc/howdy/config.ini`, set `certainty = 4.0`
- Check dark_threshold: set to `90` for HP IR cameras with flashing emitters

### Unlock takes too long

Reduce the sleep in `~/.local/bin/omarchy-face-unlock` from `1` to `0.5`:
```bash
sleep 0.5
```

### Want face unlock for sudo too?

Add to `/etc/pam.d/sudo` (before the existing auth line):
```
auth      sufficient  /usr/lib/security/pam_howdy.so
```

## Uninstall

```bash
./uninstall.sh
```

Or manually:
1. Restore PAM: `sudo cp /etc/pam.d/hyprlock.bak /etc/pam.d/hyprlock`
2. Remove script: `rm ~/.local/bin/omarchy-face-unlock`
3. Remove face unlock labels from `~/.config/hypr/hyprlock.conf`
4. Set `ignore_empty_input = true` back in hyprlock.conf
5. Optionally remove packages: `sudo pacman -Rns howdy-git python-dlib ydotool`

## License

MIT
