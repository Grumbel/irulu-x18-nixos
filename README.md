# NixOS for the iRULU X18 / eXpro X1S tablet

Run a current mainline Linux (6.18) with NixOS on the **iRULU eXpro X1S**,
an 8" Android tablet from around 2016. The system boots from a microSD
card; Android on the internal flash stays untouched. Take the card out and
the tablet boots Android again.

On Amazon this tablet was sold as *"iRULU eXpro X1S Tablet PC, Android 5.1
Lollipop, Quad Core, 16 GB Nand Flash, 8 Zoll mit HD-Auflösung 1280 \* 800,
weiss und silber mit Metallgehäuse"*. Internally it calls itself **X18**.

## Is this my tablet?

Under Android, *Settings → About tablet* should show:

| | |
|---|---|
| Model | **X18** |
| Android version | 5.1.1 |
| Build number | LVY48E.OGS.20160127 (or similar) |

Inside: Allwinner **A64** (4× Cortex-A53, Mali-400 MP2 GPU), 1 GB RAM,
16 GB NAND, 800×1280 MIPI-DSI panel, Silead touchscreen, RTL8723BS Wi-Fi
and Bluetooth, X-Powers AXP803 power management.

Other A64 tablets may be similar, but the display, touch and Wi-Fi setup
are specific to this board. Booting from SD is harmless to try, though.

## What works

| | Status |
|---|---|
| Display (800×1280) and backlight | ✅ |
| Touchscreen (multi-touch) | ✅ |
| GPU: OpenGL ES 2.0 (Mesa lima), KMS/DRM | ✅ about 64 fps vsync |
| Wi-Fi (2.4 GHz) | ✅ |
| Bluetooth | ✅ firmware loads, little tested |
| Speaker | ✅ |
| Battery level, power-off at 3.3 V | ✅ |
| Suspend to RAM (deep sleep), power-button wake | ✅ |
| USB networking to a PC (micro-USB port) | ✅ |
| Volume buttons | ⚠️ configured, voltages not verified |
| Headphones, charging with a wall charger | ❓ untested |
| Microphone, accelerometer, cameras | ❌ not yet |

See [Known issues](#known-issues) for details.

## What you need

- A **microSD card**, 8 GB or larger (the image is about 4 GB). Use a good
  brand; cheap cards show I/O errors under load.
- A **Linux PC with [Nix](https://nixos.org/download/)** and flakes enabled
- To build on an x86_64 PC: aarch64 emulation. On NixOS:
  `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];`
  The kernel and bootloader are cross-compiled; everything else comes
  prebuilt from the NixOS binary cache.
- A **micro-USB cable** (for SSH access without Wi-Fi)

## Installation

### 1. Build the SD card image

```sh
git clone https://github.com/Grumbel/irulu-x18-nixos.git
cd irulu-x18-nixos
nix build .#sdImage -L
```

The first build takes a while (mainly the kernel, about 6 minutes, and the
crust firmware toolchain, about 20 minutes once). The image ends up in
`result/sd-image/`.

### 2. Write it to the microSD card

Check the device name of your card reader first (`lsblk`), then:

```sh
sudo dd if=result/sd-image/nixos-image-sd-card-*.img of=/dev/sdX bs=4M conv=fsync status=progress
```

### 3. Wi-Fi and SSH key

Plug the card back into the PC. It has a small FAT partition called
`FIRMWARE`, readable on any computer. Put two files there:

- **`wifi.conf`**: copy `wifi.conf.example` and fill in your network:
  ```
  network={
      ssid="MyNetwork"
      psk="MyPassword"
  }
  ```
- **`authorized_keys`**: your SSH public key, e.g. a copy of
  `~/.ssh/id_ed25519.pub`. Without it you can't log in over SSH.

### 4. Boot

Insert the card into the tablet and switch it on. The tablet's boot ROM
prefers the SD card, so NixOS starts instead of Android. Boot messages
appear on the screen after a few seconds; the first boot takes about
2 minutes, because the root partition is grown to fill the card.

## Using it

### Logging in

- **Over Wi-Fi**: `ssh root@irulu-x18.local`
- **Over USB**: connect the tablet's micro-USB port to your PC. A new
  network interface appears on the PC; then `ssh root@10.42.0.1`.
  If your PC doesn't pick up an address, use the IPv6 link-local address
  (replace `usb0` with the name of the new interface):
  ```sh
  ping -6 -c2 ff02::1%usb0    # shows the tablet's fe80:: address
  ssh root@fe80::...%usb0
  ```
- **On the tablet**: with a USB keyboard on an OTG adapter, log in as
  `root`, password `irulu`. Change it with `passwd`.

### Power button

- Short press: suspend (deep sleep); press again to wake up
- Long press: power off

### Graphics test

```sh
SDL_VIDEODRIVER=kmsdrm sdl2-kms-test 20   # spinning triangle, white squares under your fingers
kmscube
```

This uses the GPU directly through KMS/DRM, without X11 or Wayland.

### Back to Android

Switch off, remove the SD card, switch on.

## Updating

After changing the configuration, update the running tablet over USB or
Wi-Fi instead of reflashing:

```sh
./deploy.sh switch            # most changes
./deploy.sh boot --reboot     # kernel or device tree changes
```

`deploy.sh` finds the tablet on the USB link, or as `irulu-x18.local` on
Wi-Fi, and runs `nixos-rebuild` against it.

The bootloader (U-Boot) is not updated by `nixos-rebuild`. If it changed,
run `irulu-install-uboot` on the tablet; it saves a backup of the old one
in `/root`.

## Using it in your own configuration

The hardware support is a NixOS module:

```nix
{
  inputs.irulu-x18.url = "github:Grumbel/irulu-x18-nixos";

  outputs = { nixpkgs, irulu-x18, ... }: {
    nixosConfigurations.mytablet = nixpkgs.lib.nixosSystem {
      modules = [
        irulu-x18.nixosModules.default
        {
          hardware.irulu-x18.enable = true;
          # Cross-compile kernel and U-Boot on your x86_64 PC (recommended)
          hardware.irulu-x18.kernelBuildPlatform = "x86_64-linux";
          # Optional: fixed Wi-Fi MAC address, see below
          # hardware.irulu-x18.wifiMacAddress = "02:12:34:56:78:9a";
        }
        ./configuration.nix
      ];
    };
  };
}
```

| Option | Default | |
|---|---|---|
| `hardware.irulu-x18.enable` | `false` | Enable hardware support |
| `hardware.irulu-x18.kernelBuildPlatform` | `null` | Build kernel, DTB and U-Boot on this platform (e.g. `"x86_64-linux"`); `null` builds natively |
| `hardware.irulu-x18.leanKernel` | `true` | Minimal kernel config (builds in minutes) instead of the generic nixpkgs kernel |
| `hardware.irulu-x18.wifiMacAddress` | `null` | Wi-Fi MAC address; `null` derives a stable one from `/etc/machine-id` |

The Wi-Fi module has no MAC address of its own. Android reads the factory
MAC from its *private* partition (`ULI/factory/mac.txt`); set it with
`wifiMacAddress` if you want the tablet to keep the same address as under
Android.

`configuration.nix` in this repository is the example system used for the
SD card image (networking, SSH, test tools).

## Known issues

- **Wi-Fi** is 2.4 GHz only (hardware). The driver (`r8723bs`) is from the
  kernel's staging area.
- **Refresh rate** is 64 Hz instead of the panel's nominal 54 Hz; mainline
  can't clock the display link as low as the vendor kernel. No visible
  problem.
- **SD card errors** (`sunxi-mmc ... data error`) appear under heavy writes
  with some cards.
- **Not supported yet**: microphone, accelerometer (screen rotation),
  cameras, headphone jack detection.
- **No serial console** without opening the case. During boot, `dmesg` is
  written to `dmesg-initrd.txt` and `dmesg-stage2.txt` on the `FIRMWARE`
  partition, so early failures can be read on a PC.

## How it works

| Part | |
|---|---|
| `modules/irulu-x18.nix` | Hardware support (kernel, device tree, firmware, U-Boot, Wi-Fi, audio, power) |
| `configuration.nix` | Example system for the SD card image |
| `dts/sun50i-a64-irulu-x18.dts` | Device tree for the board |
| `patches/` | Kernel patches (panel, touchscreen, Wi-Fi calibration) |
| `kernel/` | Lean kernel config and the fragment it is generated from |
| `pkgs/crust/` | crust firmware for deep sleep |
| `firmware/` | Touchscreen firmware and Wi-Fi calibration data from the stock Android |
| `pkgs/sdl2-kms-test/` | Small SDL2/OpenGL ES test program |
| `tools/` | Firmware extraction from the stock Android |

### What needed fixing

| Problem | Cause | Fix |
|---|---|---|
| Panel black, backlight on | Panel needs **non-burst** DSI video mode (vendor `lcd_dsi_if = 0`) | `patches/0001`: JD9365 entry with per-panel `mode_flags` |
| Touch probe fails ("Registers clear error -11") | The GSL chip resets as soon as it latches the reset command; the I2C controller sees a bus error | `patches/0002`: ignore that one write error |
| Touch coordinates off | The firmware reports 0..1151 × 35..1698, not 800×1280 | Ranges in the device tree |
| Wi-Fi rarely associates (`ASSOC-REJECT status_code=1`) | `r8723bs` "inactive power save" turns the radio off while unassociated | `rtw_ips_mode=0` |
| Wi-Fi uncalibrated | Android replaces the module's eFuse with `wifi_efuse_8723bs_vq0.map` (antenna path B, TX power, BT coexistence) | `patches/0003` adds `rtw_efuse_file` |
| No USB gadget | `usb_power_supply` disabled; `ehci0`/`ohci0` share PHY 0 and switch it to host mode | Enabled / disabled in the device tree |
| No Wi-Fi power-up | `mmc-pwrseq-simple` fails on 6.18 with a single reset GPIO | WL_REG_ON as `regulator-fixed` |
| Only s2idle, no deep sleep | nixpkgs builds Allwinner U-Boot without crust | crust built with the libc-less or1k GCC (newlib fails with GCC 15) |
| Lean kernel died after seconds | `allnoconfig` also disabled the A64 timer erratum and CPU errata | Config generated from `alldefconfig` |
| GPU scanout fails (`CREATE_DUMB ... Cannot allocate memory`) | No CMA pool | `CMA_SIZE_MBYTES=128` |
| Battery could deep-discharge | PMIC power-off at 2.6 V by default | `simple-battery` node: 3.3 V, 4000 mAh |

### Lean kernel

The generic nixpkgs kernel builds about 7,400 modules for hardware this
tablet doesn't have. `kernel/x18-lean.fragment` lists only what the tablet
and NixOS need; `kernel/x18-lean.config` (about 1,240 `=y`, 200 `=m`) is
generated from it. To regenerate after editing the fragment, in an
unpacked Linux 6.18 source tree:

```sh
make ARCH=arm64 CROSS_COMPILE=aarch64-unknown-linux-gnu- \
     KCONFIG_ALLCONFIG=/path/to/kernel/x18-lean.fragment alldefconfig
python3 /path/to/kernel/check-lean-config.py /path/to/kernel/x18-lean.fragment .config
cp .config /path/to/kernel/x18-lean.config
```

`check-lean-config.py` lists options Kconfig silently dropped (usually a
missing parent menu). Use `alldefconfig`, not `allnoconfig`: the latter
also turns off default-on safety options like CPU errata workarounds.

### Firmware files

`firmware/` contains two **binary blobs** taken from the tablet's stock
Android 5.1 system. They are not covered by this repository's licenses;
they are included because the hardware doesn't work properly without them:

| File | What | Source in Android |
|---|---|---|
| `silead/gsl1680-irulu-x18.fw` | Touch controller firmware | Array `GSL1680E_86OGS_FW` in the vendor touchscreen driver `/system/vendor/modules/gslX680new.ko` |
| `rtl8723bs/rtl8723bs_efuse_irulu_x18.bin` | Wi-Fi calibration data (eFuse map: TX power, antenna, BT coexistence) | `/system/etc/wifi/wifi_efuse_8723bs_vq0.map`, hex text converted to binary |

All other firmware comes from `linux-firmware`.

To extract them yourself from your own tablet, boot Android, enable USB
debugging (*Settings → About tablet*, tap *Build number* seven times, then
*Developer options → USB debugging*), connect it via USB and run:

```sh
tools/extract-firmware.sh adb
```

Or from a copy of Android's `/system` directory (for example a mounted
backup of the system partition):

```sh
tools/extract-firmware.sh dir /path/to/system
```

The script writes the files to `firmware-extracted/` and checks them
against the SHA-256 sums of the files in `firmware/`.

## License

The files in this repository are dual-licensed under the
[GNU GPL 2.0 or later](LICENSES/GPL-2.0.txt) or the [MIT license](LICENSES/MIT.txt),
at your choice (`SPDX-License-Identifier: GPL-2.0-or-later OR MIT`),
except for:

- the kernel patches in `patches/` (GPL-2.0, like the kernel)
- the generated kernel config `kernel/x18-lean.config` (GPL-2.0)
- the binary blobs in `firmware/` (see [Firmware files](#firmware-files))

See [LICENSE](LICENSE) for details.
