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
  on your router.

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

## Known unknowns

- Panel: the init sequence and timings come from the vendor driver, but
  the reset/power timing follows the mainline Jadard driver.
- Backlight PWM polarity (`PWM_POLARITY_INVERTED`) is a guess. If the screen
  is dark but USB works, try `echo 1000 > /sys/class/backlight/*/brightness`
  and flip the polarity in the DTS.
- Touch axes: check with `evtest`.
- If the tablet doesn't power up from SD at all: U-Boot/DRAM. Without UART
  there's no way to see why. Next options are FEL mode (`sunxi-fel`) or
  opening the case for the UART pads.
