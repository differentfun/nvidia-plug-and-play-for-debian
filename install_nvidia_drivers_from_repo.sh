#!/usr/bin/env bash
set -euo pipefail

PACKAGES=(
  cuda-drivers
  cuda-toolkit-12-6
  nvidia-settings
  nvidia-vaapi-driver
  "linux-headers-$(uname -r)"
)

MODPROBE_CONF="/etc/modprobe.d/nvidia-kms.conf"
GRUB_FILE="/etc/default/grub"
CMDLINE_KEY="GRUB_CMDLINE_LINUX_DEFAULT"
NVIDIA_MODESET_OPTION="nvidia-drm.modeset=1"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

backup_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    local stamp
    stamp="$(date +%Y%m%d%H%M%S)"
    cp --preserve=mode,ownership,timestamps "${file}" "${file}.bak.${stamp}"
    echo "Created backup: ${file}.bak.${stamp}"
  fi
}

ensure_modprobe_config() {
  local tmp
  tmp="$(mktemp)"
  printf 'options nvidia-drm modeset=1\n' > "${tmp}"
  if [[ ! -f "${MODPROBE_CONF}" ]] || ! cmp -s "${tmp}" "${MODPROBE_CONF}"; then
    backup_file "${MODPROBE_CONF}"
    install -m 0644 "${tmp}" "${MODPROBE_CONF}"
    echo "Set ${MODPROBE_CONF} with 'options nvidia-drm modeset=1'."
  else
    echo "${MODPROBE_CONF} already contains the required option."
  fi
  rm -f "${tmp}"
}

ensure_grub_cmdline() {
  if [[ -f "${GRUB_FILE}" ]]; then
    if grep -q "^${CMDLINE_KEY}=" "${GRUB_FILE}"; then
      if grep -q "${NVIDIA_MODESET_OPTION}" "${GRUB_FILE}"; then
        echo "${CMDLINE_KEY} already contains ${NVIDIA_MODESET_OPTION}."
        return
      fi
      backup_file "${GRUB_FILE}"
      sed -i "s/^\(${CMDLINE_KEY}=\"[^\"]*\)\"/\1 ${NVIDIA_MODESET_OPTION}\"/" "${GRUB_FILE}"
      echo "Added ${NVIDIA_MODESET_OPTION} to ${CMDLINE_KEY} in ${GRUB_FILE}."
    else
      backup_file "${GRUB_FILE}"
      printf '%s="%s"\n' "${CMDLINE_KEY}" "${NVIDIA_MODESET_OPTION}" >> "${GRUB_FILE}"
      echo "Created ${CMDLINE_KEY} in ${GRUB_FILE} with ${NVIDIA_MODESET_OPTION}."
    fi
  else
    echo "File ${GRUB_FILE} not found." >&2
    exit 1
  fi
}

export DEBIAN_FRONTEND=noninteractive

ensure_prerequisites() {
  echo "[1/8] Ensuring prerequisite tools (wget, ca-certificates, gnupg)..."
  apt-get update
  apt-get install -y wget ca-certificates gnupg
}

configure_nvidia_repo() {
  echo "[2/8] Configuring NVIDIA CUDA APT repository..."
  if ! source /etc/os-release 2>/dev/null; then
    echo "Unable to detect distribution via /etc/os-release." >&2
    exit 1
  fi

  if [[ "${ID}" != "debian" ]]; then
    echo "This script currently supports the NVIDIA repo setup only on Debian." >&2
    exit 1
  fi

  local keyring_pkg="cuda-keyring_1.1-1_all.deb"
  local base_url="https://developer.download.nvidia.com/compute/cuda/repos"
  local version_id="${VERSION_ID:-}"
  local codename="${VERSION_CODENAME:-}"
  local -a slug_candidates=()

  if [[ -n "${version_id}" ]]; then
    if [[ "${version_id}" =~ ^([0-9]+) ]]; then
      slug_candidates+=("debian${BASH_REMATCH[1]}")
    elif [[ "${version_id}" =~ ^([0-9]+)\. ]]; then
      slug_candidates+=("debian${BASH_REMATCH[1]}")
    fi
  fi

  if [[ -n "${codename}" ]]; then
    case "${codename}" in
      bookworm) slug_candidates+=("debian12") ;;
      bullseye) slug_candidates+=("debian11") ;;
      buster) slug_candidates+=("debian10") ;;
      trixie) slug_candidates+=("debian12") ;;
      sid|testing) slug_candidates+=("debian12") ;;
    esac
  fi

  slug_candidates+=("debian12" "debian11")

  local -A seen=()
  local -a unique_candidates=()
  for slug in "${slug_candidates[@]}"; do
    [[ -z "${slug}" ]] && continue
    if [[ -n "${seen[$slug]+_}" ]]; then
      continue
    fi
    unique_candidates+=("${slug}")
    seen["${slug}"]=1
  done

  if dpkg-query -W -f='${Status}' cuda-keyring 2>/dev/null | grep -q "install ok installed"; then
    echo "cuda-keyring already installed; NVIDIA repository present."
    return
  fi

  local success=0
  for slug in "${unique_candidates[@]}"; do
    local repo_url="${base_url}/${slug}/x86_64/${keyring_pkg}"
    echo "Attempting to download ${keyring_pkg} from ${slug}..."
    local tmp_deb
    tmp_deb="$(mktemp "/tmp/${keyring_pkg}.XXXXXX")"
    if wget -O "${tmp_deb}" "${repo_url}"; then
      dpkg -i "${tmp_deb}"
      rm -f "${tmp_deb}"
      echo "Installed ${keyring_pkg} from ${slug}."
      success=1
      break
    fi
    rm -f "${tmp_deb}"
    echo "Failed to fetch ${keyring_pkg} from ${slug}; trying next candidate..."
  done

  if [[ "${success}" -ne 1 ]]; then
    echo "Unable to download ${keyring_pkg} from NVIDIA repositories. Please verify network connectivity or update the script." >&2
    exit 1
  fi
}

ensure_prerequisites
configure_nvidia_repo

echo "[3/8] Updating package index..."
apt-get update

echo "[4/8] Installing NVIDIA proprietary driver and CUDA from NVIDIA repo..."
apt-get install -y "${PACKAGES[@]}"

if [[ -f /etc/X11/xorg.conf ]]; then
  backup="/etc/X11/xorg.conf.backup.$(date +%Y%m%d%H%M%S)"
  echo "[5/8] Backing up /etc/X11/xorg.conf to ${backup}"
  mv /etc/X11/xorg.conf "${backup}"
else
  echo "[5/8] No /etc/X11/xorg.conf to move"
fi

echo "[6/8] Enabling NVIDIA DRM KMS for Wayland..."
ensure_modprobe_config

echo "[7/8] Ensuring GRUB passes nvidia-drm.modeset=1..."
ensure_grub_cmdline

echo "[8/8] Refreshing initramfs and GRUB configuration..."
update-initramfs -u
update-grub

echo "Trying to run nvidia-smi (not an error if it fails the first time)..."
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi || true
else
  echo "nvidia-smi is not yet in PATH; reboot after installation." >&2
fi

if [[ -x /usr/local/cuda/bin/nvcc ]]; then
  echo "Registering nvcc with update-alternatives..."
  update-alternatives --install /usr/bin/nvcc nvcc /usr/local/cuda/bin/nvcc 100
else
  echo "nvcc not found at /usr/local/cuda/bin/nvcc; skipping update-alternatives." >&2
fi

echo "Done. A reboot is recommended to load the proprietary driver."
