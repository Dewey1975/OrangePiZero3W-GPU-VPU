# Orange Pi Zero 3W GPU/VPU: in-place installer

Turn on the GPU and hardware video on an Orange Pi Zero 3W **that is already running the stock Ubuntu image**. No Docker, no second computer, no reflashing. One script, about 10 minutes.

This is a fork of [Incipiens/OrangePiZero3W-GPU-VPU](https://github.com/Incipiens/OrangePiZero3W-GPU-VPU). The original builds a brand-new SD card image on a PC. This fork adds `opi-zero3w-gpu-inplace.sh`, which applies the same changes directly to a board you have already set up. All credit for working out the method goes to the original author; the background is in [his XDA article](https://www.xda-developers.com/orange-pi-zero-3w-beats-raspberry-pi-5-cant-use-half-hardware/).

## The problem

The Zero 3W's Allwinner A733 chip has a PowerVR GPU and a hardware video engine, but Orange Pi's Ubuntu image ships without the software needed to use them. Everything graphical runs on the CPU.

Radxa sells a board with the same chip (the Cubie A7S) and its image does include that software. The script copies the missing pieces out of a Radxa image you download yourself and builds the GPU kernel driver for Orange Pi's kernel.

## What you get

| | Before | After |
| --- | --- | --- |
| GPU driver (`pvrsrvkm`) | not loaded | loaded at boot |
| Vulkan | none | Vulkan 1.3 on PowerVR BXM-4-64 |
| OpenGL ES / OpenCL libraries | none | installed |
| Hardware video codecs (GStreamer OMX) | unusable | registered |
| Chromium | Snap placeholder | real build with GPU launch icons |

Wi-Fi, Bluetooth, the bootloader, the kernel, your user account and your files are left alone.

## Requirements

- Orange Pi Zero 3W running **`Orangepizero3w_1.0.0_ubuntu_jammy_desktop_xfce_linux6.6.98`**. This exact image is the only one tested.
- Kernel `6.6.98-sun60iw2`. Check with `uname -r`.
- About 10 GB of free space. Check with `df -h /`.
- Internet access on the board.
- A terminal on the board, either on its own screen or over SSH.

The script checks the kernel and stops with a clear message if it doesn't match.

## Install

Run all of this on the Orange Pi.

**1. Download and unpack the Radxa image** (1.1 GB download, 6.5 GB unpacked). The unpack step prints nothing and takes a few minutes.

```
cd ~
wget https://github.com/radxa-build/radxa-a733/releases/download/rsdk-r2/radxa-a733_bullseye_kde_r2.output_512.img.xz
xz -d radxa-a733_bullseye_kde_r2.output_512.img.xz
```

**2. Download the script.**

```
wget https://raw.githubusercontent.com/YOUR-USERNAME/OrangePiZero3W-GPU-VPU-inplace/main/opi-zero3w-gpu-inplace.sh
```

**3. Run it.**

```
sudo bash ~/opi-zero3w-gpu-inplace.sh ~/radxa-a733_bullseye_kde_r2.output_512.img
```

It goes quiet for several minutes while building the driver, and again while installing Chromium. Wait for `Done. Reboot now`.

To skip Chromium, put `SKIP_CHROMIUM=1` in front: `sudo SKIP_CHROMIUM=1 bash ~/opi-zero3w-gpu-inplace.sh ...`

**4. Reboot.**

```
sudo reboot
```

## Check that it worked

```
lsmod | grep pvrsrvkm
sudo apt install -y vulkan-tools
vulkaninfo --summary 2>/dev/null | grep -E "deviceName|driverName"
gst-inspect-1.0 | grep -c omx
```

A pass looks like this:

```
pvrsrvkm             1302528  17
        deviceName         = PowerVR B-Series BXM-4-64 MC1
        driverName         = PowerVR B-Series Vulkan Driver
12
```

- A `pvrsrvkm` line means the driver is loaded.
- `PowerVR B-Series BXM-4-64 MC1` means Vulkan is using the real GPU.
- A number above zero on the last line means hardware video codecs are available.

Two icons also appear on the desktop: **Chromium - WebGL Test (Aquarium)** and **Chromium - chrome://gpu**. They launch Chromium with the flags it needs to use the GPU.

Once you're happy, get 6.5 GB back:

```
rm ~/radxa-a733_bullseye_kde_r2.output_512.img
```

## Limitations

- **Firefox** still renders in software. Use the Chromium icons.
- **mpv** and other FFmpeg-based players can't use the hardware decoder. Hardware video goes through GStreamer or Chromium.
- **Don't run `sudo apt upgrade`** or upgrade the Ubuntu release. Updates to graphics and video packages can overwrite parts of this setup, and the driver is built for kernel 6.6.98 only. Installing individual programs with `apt install` is fine.
- **Tested on one board** with the one image listed above. Video playback and the NPU demo were not tested beyond confirming the codecs register.

## If something goes wrong

**The script stops with an error.** Nothing is half-working in a dangerous way; read the last line. The common causes are the wrong image version, a kernel that isn't `6.6.98-sun60iw2`, or the Radxa file still being a `.xz`.

**No desktop after reboot.** Log in over SSH, or press Ctrl+Alt+F2 on the board, then:

```
sudo rm /etc/X11/xorg.conf.d/20-modesetting.conf
sudo reboot
```

**The board hangs or won't boot.** Reflash the stock Orange Pi image and start again. There is no uninstall script. Files the script overwrites are saved in `/root/gpu-inplace-backup-<date>`.

**You tried a manual GPU install before this.** Leftovers can block the driver. Before running the script, make sure this prints "No such file" and nothing else:

```
ls /etc/modprobe.d/*pvrsrvkm* ; sudo dkms status
```

## Why doing it by hand tends to fail

Loading the GPU driver adds a second graphics device (`card1`) that can render but has no display output. Left alone, Xorg may pick it as the screen, fail with `KMS doesn't support dumb interface`, and leave you with no desktop. The script writes an Xorg config that pins the display to `card0`, and turns on `ShadowFB` and a software cursor so the X server itself stays off the PowerVR driver. That config comes from the original project.

## What the script changes

- Copies PowerVR libraries, firmware and the Vulkan ICD from the Radxa image.
- Copies the Allwinner video libraries and GStreamer OMX plugin, and patches `/etc/xdg/gstomx.conf`.
- Installs the kernel headers that ship in `/opt` and builds `pvrsrvkm` with DKMS.
- Loads `pvrsrvkm` at boot (`/etc/modules-load.d/pvr.conf`).
- Writes `/etc/X11/xorg.conf.d/20-modesetting.conf` and a udev rule for the video device.
- Adds the saiarcot895 Chromium PPA, installs Chromium and adds two desktop icons.

## License

The scripts are MIT licensed, same as the original project. The Radxa, Imagination Technologies and Allwinner files the script copies are **not** included here and stay under their own licenses. They come from the Radxa image you download yourself. Please don't upload those files, the Radxa image, or copies of them to this repository.
