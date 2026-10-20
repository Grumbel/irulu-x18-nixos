# NixOS SD image for the iRULU X18

Boots mainline Linux 6.18 from microSD. The internal NAND/Android stays
untouched; remove the card and the tablet boots Android again.

## Build

```sh
cd nixos
nix build path:.#sdImage -L
```

Use `path:.#…`, not `.#…`. With the latter, Nix copies the whole git
repository, including the multi-GB `dump/`, into the store.

Requirements: an x86_64 NixOS host with
`boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`. The kernel and U-Boot
are cross-compiled; the rest is native aarch64 and comes from
cache.nixos.org.

Other outputs: `.#kernel`, `.#uboot`, `.#toplevel`.

## Flash

```sh
sudo dd if=result/sd-image/*.img of=/dev/sdX bs=4M conv=fsync status=progress
```

Then, to set up Wi-Fi, mount the card's FAT partition (`FIRMWARE`), copy
`wifi.conf.example` to `wifi.conf` and edit SSID and password. The root
partition grows to fill the card on first boot.

## Boot

Insert the card and power on. The A64 boot ROM tries the microSD before NAND.

There's no serial console without opening the case, so:

- **Screen**: the DSI panel driver loads from the initrd, so kernel messages
  should appear on the panel a few seconds after power-on. If the screen
  stays black, look at the USB link next.
- **USB**: connect the tablet's micro-USB port to a PC. The tablet runs
  `g_ether`, the PC gets an address via DHCP, then `ssh root@10.42.0.1`.
- **Wi-Fi**: `ssh root@irulu-x18.local` (mDNS), or look up the DHCP lease
  on your router. `wifi.conf` must contain only `network={...}` blocks.

SSH accepts the keys in `authorized_keys`. The console password for root
is `irulu`.

## What's in here

| File | Purpose |
|------|---------|
| `flake.nix` | Outputs; cross kernel/U-Boot plus native aarch64 system |
| `configuration.nix` | Kernel config, initrd modules, SD layout, networking |
| `patches/0001-irulu-x18-dts-and-panel.patch` | Adds `sun50i-a64-irulu-x18.dts` and the JD9365 panel entry. Regenerate it when `../mainline/*.dts` changes |
| `firmware/silead/` | Touch firmware extracted from the vendor driver |
| `wifi.conf.example`, `README-SDCARD.txt` | Copied to the FAT partition |

U-Boot is the stock nixpkgs `ubootPine64` (`pine64_plus_defconfig`). Its A64
defaults (DDR3-1333, 672 MHz, ZQ 0x3b3bbb, ODT on, PMIC left at power-on
defaults) match the vendor DRAM settings. It uses its own Pine64+ DT; the
kernel gets the X18 DT through `extlinux.conf`.

## Bring-up findings

| Symptom | Cause | Fix |
|---------|-------|-----|
| No USB gadget | `usb_power_supply` disabled, so usbphy deferred forever | Enabled in DTS |
| No USB gadget (2) | `ehci0`/`ohci0` share PHY 0 with MUSB; probing them switches the port to host mode | Left disabled; `usb_otg` forced to `peripheral` |
| No Wi-Fi | `mmc-pwrseq-simple` fails on 6.18 with a single reset GPIO (`-ENOENT`) | WL_REG_ON (PL2) as `regulator-fixed` vmmc |
| Black panel, backlight on | Panel needs **non-burst** DSI video mode (vendor `lcd_dsi_if = 0`) | `mode_flags` per Jadard panel desc |
| Touch probe fails ("Registers clear error -11") | The GSL chip resets as soon as it latches the reset command; the I2C controller sees a bus error | `patches/0002`: ignore that one write error |
| Touch coordinates off | Firmware reports 0..1151 x 35..1698 (raw, after swap), not 800x1280 | `touchscreen-min-x/size-x/size-y` in DTS |
| Wi-Fi associates rarely (`ASSOC-REJECT status_code=1`) | r8723bs "inactive power save" turns the RF off while unassociated; associations then fail ~90% of the time | `rtw_ips_mode=0` |
| Wi-Fi uncalibrated, random MAC | Android replaces the module's eFuse with `wifi_efuse_8723bs_vq0.map` (antenna on S0/path B, TX power, BT coexistence) | `patches/0003` adds `rtw_efuse_file`; map converted to binary firmware; `rtw_initmac=<factory MAC>` |
| SDL/GBM: `DRM_IOCTL_MODE_CREATE_DUMB failed: Cannot allocate memory` | Lean config had no CMA pool; scanout buffers need contiguous memory | `CMA_SIZE_MBYTES=128` |
| Only s2idle, no deep sleep | nixpkgs builds Allwinner U-Boot with `SCP=/dev/null` (no crust) | Build crust (or1k, libc-less GCC; newlib fails with GCC 15) and pass it as `SCP` |
| First lean kernel died after a few seconds | `allnoconfig` disabled the A64 timer erratum and Cortex-A53 errata | Generate from `alldefconfig` |

Mainline runs the DSI lanes at 500 Mbit/s (A64 `pll-mipi` minimum) instead
of the vendor's 424 Mbit/s; the panel doesn't mind. Vendor vs. mainline
register dumps are in `../dump/regs/`.

## Updating a running tablet

After the first flash, deploy changes over the USB link instead of
reflashing:

```sh
./deploy.sh boot --reboot   # new kernel/DTB: install and reboot
./deploy.sh switch          # userspace-only changes, no reboot
```

It finds the tablet's IPv6 link-local address on the USB interface and runs
`nixos-rebuild --target-host` through a temporary SSH host alias.

## Graphics (KMS/DRM, no display server)

Mesa's `lima` renders on the Mali-400; `kmsro` pairs it with the
display-only `sun4i-drm`. SDL2 (sdl2-compat on SDL3) uses its KMSDRM
backend:

```sh
SDL_VIDEODRIVER=kmsdrm sdl2-kms-test 20   # GLES2 triangle + touch squares
kmscube
eglinfo -p gbm
```

Expect OpenGL ES 2.0 on `Mali400` and a vsync-locked 64 fps: the DSI link
runs at 500 Mbit/s (A64 `pll-mipi` minimum) instead of the vendor's
424 Mbit/s, so the panel refreshes at 64 Hz rather than the nominal 54 Hz.

## Suspend

U-Boot is built with **crust** (firmware for the A64's AR100 management
core, `pkgs/crust`), so `/sys/power/mem_sleep` offers `deep` (suspend to
RAM) instead of only `s2idle`. A short power-key press suspends, another
press wakes, a long press powers off. The RTC also wakes it
(`rtcwake -m mem -s 20`). After resume, wpa_supplicant is restarted.

U-Boot sits in the raw SD area, which `nixos-rebuild` doesn't update. After
changing U-Boot, run `irulu-install-uboot` on the tablet (it keeps a backup
of the old boot area in `/root`). The pre-crust U-Boot is in
`../dump/uboot-backup/` for recovery from a PC:
`dd if=uboot-before-crust.bin of=/dev/sdX bs=1024 seek=8 conv=fsync`.

## Debugging over USB

The host may not get a DHCP lease, but IPv6 link-local always works:

```sh
ping -6 -c2 ff02::1%enp2s0f0u9     # find the tablet's fe80:: address
ssh root@fe80::...%enp2s0f0u9
```

`../tools/` has small out-of-tree modules for DSI experiments
(`dsidbg`, `paneldbg`, `dsihost`); build them against
`.#kernel`'s `dev` output with the cross compiler.

## Lean kernel (prepared, not wired in yet)

The nixpkgs generic kernel builds ~7,400 modules for hardware this tablet
doesn't have. `kernel/x18-lean.fragment` lists only what the X18 and
NixOS/systemd need. `kernel/x18-lean.config` is generated from it
(about 1,240 `=y`, 200 `=m`).

To regenerate it after editing the fragment (from an unpacked 6.18 tree):

```sh
make ARCH=arm64 CROSS_COMPILE=aarch64-unknown-linux-gnu- \
     KCONFIG_ALLCONFIG=.../kernel/x18-lean.fragment alldefconfig
python3 .../kernel/check-lean-config.py .../kernel/x18-lean.fragment .config
cp .config .../kernel/x18-lean.config
```

`check-lean-config.py` lists fragment options that Kconfig silently dropped
(usually a missing parent menu). The next step is building it with
`linuxManualConfig { configfile = ./kernel/x18-lean.config; }` instead of
`linux_6_18.override`.

## Known unknowns

- Backlight PWM polarity (`PWM_POLARITY_INVERTED`) works but hasn't been
  checked against brightness levels.
- SD card: `sunxi-mmc data error` messages under heavy writes.
