# Taming the Beast: Declarative HiFiBerry Configuration on NixOS Raspberry Pi 4

## Introduction

The Raspberry Pi 4 is a versatile SBC, but for audiophiles, the onboard audio is often the weakest link. Enter the **HiFiBerry DAC2 ADC Pro**—a high-end HAT featuring a Burr-Brown DAC and a high-performance ADC. 

On a standard Linux distribution, enabling this hardware is as simple as adding a line to `config.txt`. On **NixOS**, however, where every part of the system is meant to be defined declaratively, we enter a world of competing bootloaders, kernel mismatches, and the immutable nature of the hardware-software interface. This post chronicles the journey of getting this specific HAT working reliably on NixOS.

---

## The Challenge

Configuring a HAT on NixOS RPi4 presents three primary hurdles:

1.  **Mainline vs. Vendor Kernels**: Standard NixOS often pulls the mainline Linux kernel. While great for generic servers, mainline often lacks the specialized overlays and driver symbols required for HiFiBerry cards. 
2.  **U-Boot Overlay Ignorance**: Most NixOS SD images use U-Boot (`generic-extlinux-compatible`). By the time NixOS tries to patch the Device Tree (DTB) using `hardware.deviceTree.overlays`, U-Boot has already "baked in" the hardware state passed from the RPi firmware.
3.  **The Write-Access Problem**: The Raspberry Pi firmware looks for `config.txt` and overlays on a VFAT partition (usually `/boot/firmware`). NixOS manages its store in a read-only fashion, making direct declarative management of this partition non-trivial.

---

## The Solution: A Technical Deep Dive

After experimenting with manual patches and custom activation scripts, the "Cold Standard" solution was found by adopting the [nvmd/nixos-raspberrypi](https://github.com/nvmd/nixos-raspberrypi) flake. This flake treats the Raspberry Pi as a first-class citizen rather than a generic `aarch64` board.

### 1. Enabling the Specialized Builder

Instead of the generic `nixpkgs.lib.nixosSystem`, we use the flake's dedicated library in `flake.nix`:

```nix
porcupineFish = inputs.nixos-raspberrypi.lib.nixosSystem {
  modules = [
    ./nixos/porcupineFish/configuration.nix
  ];
  specialArgs = { inherit inputs self; };
};
```

This ensures the system is initialized with the correct Raspberry Pi vendor kernel (which contains the `snd-soc-hifiberry-...` modules) and the necessary firmware configuration tools.

### 2. Typed Hardware Configuration

The core of the solution lies in `audio.nix`. Instead of raw strings, we use a structured Nix option tree:

```nix
{ config, pkgs, lib, ... }:
{
  # Enable the specialized RPi bootloader manager
  boot.loader.raspberryPi.enable = true;

  # Declaratively define hardware overlays
  hardware.raspberry-pi.config.all.dt-overlays = {
    hifiberry-dacplusadcpro = {
      enable = true;
    };
    disable-bt = { # Highly recommended to reduce I2C interference
      enable = true;
    };
  };

  # Disable onboard audio to avoid device indexing conflicts
  hardware.raspberry-pi.config.all.base-dt-params.audio = {
    enable = true;
    value = "off";
  };
}
```

### 3. The Audio Stack

With the hardware enabled, we wire it into PipeWire for modern audio handling:

```nix
security.rtkit.enable = true;
services.pipewire = {
  enable = true;
  alsa.enable = true;
  pulse.enable = true;
};
```

---

## Troubleshooting: From "No Card" to Hi-Fi

During the implementation, several key issues were encountered. These logs serve as a guide for anyone following this path:

### Issue: "Card Not Found" in `aplay -l`
Even with the overlay enabled, the card might not appear if the necessary I2C codecs aren't loaded into the kernel early enough.
**Fix**: Explicitly add the modules to `boot.kernelModules`:
```nix
boot.kernelModules = [ 
  "snd-soc-hifiberry-dacplusadcpro"
  "snd-soc-pcm512x-i2c"
  "snd-soc-pcm186x-i2c"
];
```

### Issue: Device Tree Mismatch
If you see `dmesg` errors like `failed to load overlay 'hifiberry-dacplusadcpro'`, it usually means you are running a mainline kernel while trying to use vendor overlays.
**Resolution**: Using the `nixos-raspberrypi` flake ensures you are using the matched vendor kernel and firmware tree.

---

## Verification

Once configured, verify the hardware detection:

```bash
$ aplay -l
card 0: sndrpihifiberry [snd_rpi_hifiberry_dacplusadcpro], device 0: HiFiBerry DAC+ADC Pro HiFi multicodec-0
```

To perform a quick audio test (requires `sox`):
```bash
play -n synth 1 sin 440
```

---

## Conclusion

The "Nix Way" for Raspberry Pi has evolved. While you *can* manage things with manual activation scripts and firmware partition hacks, using a specialized flake like `nvmd/nixos-raspberrypi` provides the most stable, declarative, and technically precise experience. By utilizing the vendor kernel and structured `config.txt` options, your HiFiBerry setup becomes just another reproducible component of your NixOS infrastructure.
