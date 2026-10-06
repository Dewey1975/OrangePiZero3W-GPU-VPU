#!/bin/bash
# In-place GPU/VPU enablement for an Orange Pi Zero 3W already running
#   Orangepizero3w_1.0.0_ubuntu_jammy_desktop_xfce_linux6.6.98
#
# Adapted from scripts/build.sh in https://github.com/Incipiens/OrangePiZero3W-GPU-VPU
# (MIT). Instead of building a new image in Docker, it applies the same changes
# to the running system. No proprietary files are included here: they are copied
# from the Radxa Cubie A7S image you download yourself.
#
# Usage (on the board):
#   sudo bash opi-zero3w-gpu-inplace.sh /path/to/radxa-a733_bullseye_kde_r2.output_512.img
#
# Set SKIP_CHROMIUM=1 to skip installing Chromium from the saiarcot895 PPA.

set -euo pipefail

RADXA_IMG="${1:-radxa-a733_bullseye_kde_r2.output_512.img}"
RADXA_KVER=5.15.147-14-a733
OPI_KVER=6.6.98-sun60iw2
DKMS_SRC=img-bxm-dkms-0.1.0-2
R=/mnt/radxa
BACKUP=/root/gpu-inplace-backup-$(date +%Y%m%d-%H%M%S)

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------- sanity checks ----------
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ "$(uname -m)" = "aarch64" ] || die "this must run on the Orange Pi itself"
[ "$(uname -r)" = "$OPI_KVER" ] || die "kernel is $(uname -r), expected $OPI_KVER"
[ -f "$RADXA_IMG" ] || die "Radxa image not found: $RADXA_IMG (extract the .xz first)"
ls /opt/linux-headers-current-sun60iw2_*.deb >/dev/null 2>&1 \
  || die "kernel headers .deb not found in /opt (is this the stock 1.0.0 jammy image?)"

mkdir -p "$BACKUP"
echo ">> Backups of files this script overwrites go to $BACKUP"

# ---------- mount Radxa rootfs (GPT partition 3) read-only ----------
read -r RADXA_START RADXA_SECTORS < <(partx -g -b -o START,SECTORS -r --nr 3 "$RADXA_IMG")
: "${RADXA_START:?could not read Radxa partition 3 from $RADXA_IMG}"
: "${RADXA_SECTORS:?could not read Radxa partition 3 size from $RADXA_IMG}"

RADXA_LOOP=$(losetup -o $((RADXA_START * 512)) --sizelimit $((RADXA_SECTORS * 512)) -f --show "$RADXA_IMG")
mkdir -p "$R"
mount -o ro "$RADXA_LOOP" "$R"

cleanup() {
  umount -l "$R" 2>/dev/null || true
  losetup -d "$RADXA_LOOP" 2>/dev/null || true
}
trap cleanup EXIT

[ -d "$R/usr/src/$DKMS_SRC" ] || die "$DKMS_SRC not found in Radxa image (wrong image version?)"

# ---------- PowerVR kernel module source ----------
echo ">> Copying $DKMS_SRC source"
rm -rf "/usr/src/$DKMS_SRC"
cp -a "$R/usr/src/$DKMS_SRC" /usr/src/

# ---------- PowerVR userspace ----------
echo ">> Copying PowerVR userspace (xserver-xorg-img-bxm file list)"
LIST="$R/var/lib/dpkg/info/xserver-xorg-img-bxm-1.21.1-2.deb.list"
[ -f "$LIST" ] || die "package list not found: $LIST"
COPIED=0; SKIPPED=0
while read -r path; do
  [ -z "$path" ] && continue
  src="$R$path"
  case "$path" in
    # Keep Orange Pi's Xorg/lightdm setup.
    /usr/bin/Xorg|/etc/X11/*|/usr/lib/xorg/*|/usr/lib/systemd/*|/usr/lib/libxcvt*)
      SKIPPED=$((SKIPPED+1)); continue ;;
    # Keep Ubuntu's Vulkan loader (Radxa's lacks Wayland symbols).
    /usr/local/lib/libvulkan.so*)
      SKIPPED=$((SKIPPED+1)); continue ;;
  esac
  if [ -L "$src" ] || [ -f "$src" ]; then
    mkdir -p "$(dirname "$path")"
    cp -a "$src" "$path"
    COPIED=$((COPIED+1))
  elif [ -d "$src" ]; then
    mkdir -p "$path"
  fi
done < "$LIST"
echo "   copied $COPIED files, skipped $SKIPPED"

if [ -d /usr/lib/aarch64-linux-gnu/dri ]; then
  for dri in pvr_dri.so sunxi-drm_dri.so swrast_dri.so; do
    if [ -f "$R/usr/local/lib/dri/$dri" ] && [ ! -e "/usr/lib/aarch64-linux-gnu/dri/$dri" ]; then
      cp -a "$R/usr/local/lib/dri/$dri" /usr/lib/aarch64-linux-gnu/dri/
    fi
  done
fi

echo ">> Copying PowerVR firmware, Vulkan ICD, ld.so.conf entry"
mkdir -p /usr/lib/firmware /usr/share/vulkan/icd.d
cp -a "$R"/lib/firmware/rgx.* /usr/lib/firmware/
cp "$R/usr/share/vulkan/icd.d/img_icd.json" /usr/share/vulkan/icd.d/
cp "$R/etc/ld.so.conf.d/00_xserver-xorg-img-bxm.conf" /etc/ld.so.conf.d/

mkdir -p /etc/modules-load.d
echo "pvrsrvkm" > /etc/modules-load.d/pvr.conf

# ---------- Allwinner VPU userspace ----------
echo ">> Copying VPU userspace (libcedarc + gst-openmax)"
VPU_COPIED=0
for L in "$R/var/lib/dpkg/info/libcedarc-dev-2.0.0-arm64.list" \
         "$R/var/lib/dpkg/info/libgstreamer-openmax-allwinner.list"; do
  [ -f "$L" ] || { echo "   WARN: missing $L"; continue; }
  while read -r path; do
    [ -z "$path" ] && continue
    case "$path" in
      /usr/include/*|/usr/share/doc/*|/usr/share/metainfo/*|/usr/share/man/*) continue ;;
    esac
    src="$R$path"
    case "$path" in
      /lib/*) dst="/usr$path" ;;   # Jammy is merged-/usr
      *)      dst="$path" ;;
    esac
    if [ -L "$src" ] || [ -f "$src" ]; then
      mkdir -p "$(dirname "$dst")"
      cp -a "$src" "$dst"
      VPU_COPIED=$((VPU_COPIED+1))
    fi
  done < "$L"
done
echo "   VPU files copied: $VPU_COPIED"

if [ -f /etc/xdg/gstomx.conf ]; then
  cp -a /etc/xdg/gstomx.conf "$BACKUP/"
  HACKS="event-port-settings-changed-ndata-parameter-swap;event-port-settings-changed-port-0-to-1;no-disable-outport;no-component-reconfigure;no-component-role;no-empty-eos-buffer;pass-color-format-to-decoder;pass-profile-to-decoder;signals-premature-eos;height-multiple-16"
  sed -i "s|^hacks=.*|hacks=$HACKS|" /etc/xdg/gstomx.conf
  echo "   gstomx.conf patched"
fi

cat > /etc/udev/rules.d/99-cedar-ve.rules <<'EOF'
KERNEL=="cedar_dev*", MODE="0666"
SUBSYSTEM=="cedar_ve", TAG+="uaccess", MODE="0666"
SUBSYSTEM=="cedar_ve2", TAG+="uaccess", MODE="0666"
EOF

# ---------- Xorg: bind to sunxi-drm, software cursor + shadow FB ----------
echo ">> Writing Xorg modesetting config"
mkdir -p /etc/X11/xorg.conf.d
[ -f /etc/X11/xorg.conf.d/20-modesetting.conf ] && cp -a /etc/X11/xorg.conf.d/20-modesetting.conf "$BACKUP/"
cat > /etc/X11/xorg.conf.d/20-modesetting.conf <<'EOF'
Section "OutputClass"
    Identifier "sunxi-drm"
    MatchDriver "sun60i-display-engine"
    Driver "modesetting"
    Option "PrimaryGPU" "true"
    Option "kmsdev" "/dev/dri/card0"
    Option "SWcursor" "true"
    Option "ShadowFB" "true"
EndSection

Section "Device"
    Identifier "sunxi-drm-card0"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/card0"
    Option "SWcursor" "true"
    Option "ShadowFB" "true"
EndSection
EOF

# ---------- OpenCV SONAME compat for bundled YOLOv5 NPU demo ----------
LIBDIR=/usr/lib/aarch64-linux-gnu
for stem in libopencv_core libopencv_imgproc libopencv_imgcodecs; do
  if [ -e "$LIBDIR/${stem}.so.4.5d" ] && [ ! -e "$LIBDIR/${stem}.so.4.5" ]; then
    ln -sf "${stem}.so.4.5d" "$LIBDIR/${stem}.so.4.5"
  fi
done

# ---------- build the kernel module with DKMS ----------
echo ">> Installing build tools"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential dkms software-properties-common

echo ">> Installing Orange Pi kernel headers from /opt"
DEBIAN_FRONTEND=noninteractive dpkg -i /opt/linux-headers-current-sun60iw2_*.deb

mkdir -p "/usr/src/linux-headers-${OPI_KVER}/bsp/include"
cp "$R/usr/src/linux-headers-${RADXA_KVER}/bsp/include/sunxi-sid.h" \
   "/usr/src/linux-headers-${OPI_KVER}/bsp/include/"

echo ">> Building pvrsrvkm with DKMS (this takes several minutes)"
dkms add "/usr/src/$DKMS_SRC" 2>/dev/null || true
dkms install img-bxm-dkms/0.1.0-2 -k "$OPI_KVER"
dkms status

ls /lib/modules/${OPI_KVER}/updates/dkms/pvrsrvkm.ko* >/dev/null 2>&1 \
  || die "DKMS did not produce pvrsrvkm.ko; see /var/lib/dkms/img-bxm-dkms/0.1.0-2/build/make.log"

depmod "$OPI_KVER"
ldconfig
udevadm control --reload-rules && udevadm trigger

# ---------- Chromium (real .deb, not the snap redirector) ----------
if [ "${SKIP_CHROMIUM:-0}" != "1" ]; then
  echo ">> Installing Chromium from saiarcot895 PPA"
  mkdir -p /etc/apt/preferences.d
  cat > /etc/apt/preferences.d/saiarcot895-chromium <<'EOF'
Package: chromium-browser*
Pin: release o=LP-PPA-saiarcot895-chromium-beta
Pin-Priority: 1001
EOF
  add-apt-repository -y ppa:saiarcot895/chromium-beta
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades chromium-browser

  DESK=/home/orangepi/Desktop
  if [ -d /home/orangepi ]; then
    mkdir -p "$DESK"
    cat > "$DESK/chromium-webgl-test.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Chromium - WebGL Test (Aquarium)
Icon=chromium-browser
Exec=chromium-browser --use-gl=angle --use-angle=vulkan --enable-features=Vulkan,VulkanFromANGLE --ignore-gpu-blocklist --enable-unsafe-webgpu --new-window https://webglsamples.org/aquarium/aquarium.html
Terminal=false
Categories=Network;WebBrowser;
EOF
    cat > "$DESK/chromium-gpu-info.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Chromium - chrome://gpu
Icon=chromium-browser
Exec=chromium-browser --use-gl=angle --use-angle=vulkan --enable-features=Vulkan,VulkanFromANGLE --ignore-gpu-blocklist --new-window chrome://gpu
Terminal=false
Categories=Network;WebBrowser;
EOF
    chmod +x "$DESK"/chromium-*.desktop
    chown -R orangepi:orangepi "$DESK"
  fi
fi

echo
echo "Done. Reboot now:  sudo reboot"
