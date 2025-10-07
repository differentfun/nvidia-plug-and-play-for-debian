# NVIDIA Plug-and-Play for Debian

This repository provides a single Bash script, `install_nvidia_drivers_from_repo.sh`, that automates the installation of NVIDIA's proprietary GPU driver, the NVIDIA Settings utility, and the CUDA toolkit on Debian-based systems.

## Features
- Adds the official NVIDIA CUDA APT repository (via `cuda-keyring`) so the latest drivers and CUDA toolkit are installed directly from NVIDIA.
- Installs `cuda-drivers`, `cuda-toolkit-12-6`, `nvidia-settings`, and `nvidia-vaapi-driver` in one go.
- Backs up any existing `/etc/X11/xorg.conf` before replacing it by letting the driver reconfigure X11 automatically.
- Ensures `nvidia-drm.modeset=1` is set via `/etc/modprobe.d` and GRUB for Wayland compatibility.
- Regenerates the initramfs so the new kernel modules are available on next boot.
- Registers `/usr/local/cuda/bin/nvcc` with `update-alternatives` so `nvcc` is available as `/usr/bin/nvcc`.
- Optionally runs `nvidia-smi` at the end to verify that the driver is ready (or to hint that a reboot is still required).

## Requirements
- Debian 11/12 (or derivatives) with internet access so the NVIDIA repository can be added.
- Root privileges (`sudo`) to install packages and modify system files and bootloader configuration.
- An internet connection to download packages.

## Usage
1. Review the script to ensure it fits your environment.
2. Make the script executable: `chmod +x install_nvidia_drivers_from_repo.sh`.
3. Run it with root privileges:
   ```bash
   sudo ./install_nvidia_drivers_from_repo.sh
   ```
4. Reboot when prompted so the proprietary driver loads correctly.

## Notes
- The script runs in non-interactive mode and will automatically answer `apt` prompts.
- Messages printed by the script are in Italian.
- If `nvidia-smi` fails immediately after installation, reboot and try again.
- The script touches GRUB, initramfs, and adds files under `/etc/modprobe.d`, so keep the generated backups if you need to revert.
- Keep the generated `/etc/X11/xorg.conf.backup.*` file if you need to restore your previous configuration.

## Troubleshooting
- Ensure any previous NVIDIA or Nouveau drivers are removed if they conflict.
- Check `/var/log/apt/term.log` or the system journal (`journalctl -xe`) for detailed error output if the installation fails.
- After reboot, you can verify the driver is active with `nvidia-smi`.
