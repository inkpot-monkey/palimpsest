{
  self,
  inputs,
  pkgs,
  ...
}:
{
  imports = [
    # Hardware
    ./hardware-configuration.nix
    ./boot.nix
    inputs.nixos-hardware.nixosModules.dell-latitude-7490

    # Profiles
    self.nixosProfiles.bundle
    # Native aarch64 remote builder (rk1b — it has the NVMe-backed /nix/store; rk1a is
    # eMMC-only and stays out via enabledNodes below).
    self.nixosProfiles.piBuilder
  ];

  custom.profiles = {
    base.enable = true;
    # The floor (20 GiB) now comes from this host's `diskFloorGiB` in the fleet registry,
    # where it is measured and justified — only the ceiling is host-local. Collecting up to
    # 60 GiB free is sized for the work: this is the machine that builds the whole fleet, and
    # a system closure here is ~38 GiB, so stopping at the Pi-sized default would leave the
    # daemon collecting again on the very next build. See profiles/nixConfig.nix.
    nixConfig.freeSpaceCeiling = 60;
    sudo.enable = true;
    audio.enable = true;
    gui.enable = true;
    kanata.enable = true; # keyboard remap, host-side (contract ADR-0002 slice 11)
    backup.enable = false;
    direnv.enable = true;
    # Container runtime for local development. The `containers` affordance is already
    # granted to inkpotmonkey on this host (hosts/default.nix); the group it confers only
    # materializes once a runtime exists, which is what this enables.
    docker.enable = true;
    fonts.enable = true;
    gaming.enable = true;
    bluetooth.enable = true;
    impermanence.enable = false;
    litellm.enable = false;
    monitoring-client.enable = true;
    # rk1b now has an NVMe-backed /nix/store, so it serves as the fleet's native aarch64
    # remote builder (sd-images build there instead of under local QEMU). rk1a is eMMC-only
    # and excluded via enabledNodes. See modules/nixos/profiles/pi-builder.nix + hosts/rk1/nvme.nix.
    piBuilder.enable = true;
    piBuilder.enabledNodes = [ "rk1b" ];
    wireless.enable = true;
    tailscale = {
      enable = true;
      acceptDns = true;
    };
  };

  # Graphics
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # Remap CapsLock to Ctrl/Esc
  # services.interception-tools = {
  #   enable = true;
  #   plugins = [ pkgs.interception-tools-plugins.dual-function-keys ];
  #   udevmonConfig = ''
  #     - JOB: "${pkgs.interception-tools}/bin/intercept -g $DEVNODE | ${pkgs.interception-tools-plugins.dual-function-keys}/bin/dual-function-keys -c /etc/dual-function-keys.yaml | ${pkgs.interception-tools}/bin/uinput -d $DEVNODE"
  #       DEVICE:
  #         EVENTS:
  #           EV_KEY: [KEY_CAPSLOCK]
  #   '';
  # };

  # environment.etc."dual-function-keys.yaml".text = ''
  #   MAPPINGS:
  #     - KEY: KEY_CAPSLOCK
  #       TAP: KEY_ESC
  #       HOLD: KEY_LEFTCTRL
  # '';

  # WHAT the workstation would back up — ENUMERATED (ADR-0036). Declared now, inert until
  # `backup.enable` flips: #150's rollout reaches this host after kelpy.
  #
  # This is the host where bulk backup breaks down most obviously. /home/inkpotmonkey is
  # 143 GiB, against a 112 GiB soft quota at rsync.net — the old commented-out
  # `paths = [ "/persist" ]` could not have run even once. Nearly all of it is reconstructible:
  # Steam 18G, node/pnpm stores 3.5G, a KDE file index 2.5G, model caches 3.3G, five browser
  # profiles ~11G, 57G of `code` that is pushed to git, 14G of Downloads. What is actually
  # irreplaceable comes to roughly 2 GiB, and it is listed here.
  #
  # Unlike kelpy and porcupineFish this host has no impermanence root, so there is no
  # declarative enumeration of its state to check the list against — `classifyPersistence`
  # stays null and `notBackedUp` below is documentation of an audit rather than something the
  # build can verify. Re-walk ~ by size when this is enabled, and when it changes shape.
  custom.profiles.backup.reportJobs = [ "daily" ];
  custom.profiles.backup.jobs.daily = {
    paths = [
      # Personal documents. Not a git repository, not synced anywhere, and the largest single
      # irreplaceable thing on the machine.
      "/home/inkpotmonkey/Documents"
      # The live Anki collection: the scheduling history, which is the part that cannot be
      # rebuilt by re-importing decks. ~/anki-backups is deliberately left out below.
      "/home/inkpotmonkey/.local/share/Anki2"
      # The ~/Pictures git-annex. Small (22 files, 1.2M of annex objects) and content IS
      # present here. kelpy carries a replica, but a replica follows a delete — two live
      # copies are not a backup, which is the distinction CONTEXT.md's "Pictures annex"
      # entry turns on.
      "/home/inkpotmonkey/Pictures"
      # Artifacts and project material produced locally rather than fetched.
      "/home/inkpotmonkey/Claude"
    ];

    # The audit. Unchecked here (no impermanence root to compare against), so it is written
    # to be re-read: each entry says what makes the thing recoverable without us.
    notBackedUp = {
      "/home/inkpotmonkey/code" =
        "57G of working copies of repositories that live in git and are pushed, plus 96 node_modules/target/.direnv trees inside them. Uncommitted work is not protected — an argument for committing, not for a 57G nightly upload";
      "/home/inkpotmonkey/Downloads" =
        "14G of transient downloads; by the time something there matters it belongs somewhere else";
      "/home/inkpotmonkey/.local/share" =
        "28G of Steam, pnpm stores, a baloo index, agent and whisper model caches — all re-downloadable. The one exception, Anki2, is named in `paths` above";
      "/home/inkpotmonkey/.config" =
        "12G of browser, Slack and Electron profiles. The emacs config in here is a home-manager symlink farm, so the real configuration is in this repository; its 138M `var/` is package state";
      "/home/inkpotmonkey/Android" = "an SDK, re-downloadable";
      "/home/inkpotmonkey/Videos" =
        "re-acquirable media, on the same ADR-0028 reasoning that keeps the music library out of restic";
      "/home/inkpotmonkey/anki-backups" =
        "537M of exports OF the collection that is backed up above; restic's own snapshot history gives the same protection against Anki corrupting itself, without storing compressed duplicates that cannot dedup";
      "/home/inkpotmonkey/playground" =
        "scratch experiments, disposable by name and intent — anything here that stops being disposable belongs in code/ or Documents/";
      "/home/inkpotmonkey/scratch" = "as playground";
      "/home/inkpotmonkey/nltk_data" = "a downloadable corpus";
      "/home/inkpotmonkey/.ssh" =
        "⚠ NOT a judgement that these do not matter — they matter more than anything else here. This repository's restic password is one fleet-wide sops secret, so every host with the backup profile can read the repository; once #150 reaches kelpy, putting the admin key in there would hand it to a headless agent host, which AGENTS.md forbids outright. These keys need their own custody path, not this one";
      "/home/inkpotmonkey/.gnupg" = "as ~/.ssh — same shared-repository problem, same open question";
    };
  };

  networking.hostName = "sawtoothShark";
  nixpkgs = {
    hostPlatform = "x86_64-linux";
  };

  # Run unpatched dynamic binaries on NixOS. Claude Desktop's Cowork feature
  # downloads a generic-glibc Claude Code CLI at runtime (~/.config/Claude/
  # claude-code/) that expects /lib64/ld-linux-x86-64.so.2; nix-ld supplies it.
  programs.nix-ld.enable = true;

  # Claude Desktop's Cowork shells out to system tools through hardcoded FHS
  # paths (/usr/bin/git, /bin/bash, /usr/bin/curl, …) — its exec-capability
  # registry never consults $PATH, so on NixOS those lookups miss and tasks die
  # with "bash not found" / exit code 127. envfs mounts a FUSE /bin and
  # /usr/bin that resolves any binary on the SYSTEM PATH on demand, satisfying
  # the lookups (it keeps the stock /bin/sh and /usr/bin/env).
  services.envfs.enable = true;

  # envfs only exposes binaries that are in the system profile. Cowork's
  # registry expects git, notify-send (libnotify) and gdbus (glib), which were
  # otherwise only in inkpotmonkey's per-user profile (curl/which/xdg-open/
  # xdg-mime are already system-wide). Add them so /usr/bin/<tool> resolves.
  environment.systemPackages = with pkgs; [
    git
    libnotify
    glib
    gnome-network-displays
  ];

  # Input configuration (Kanata / uinput)
  services.udev.extraRules = ''
    KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"

    # Disable power management for Intel Bluetooth adapter
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="8087", ATTR{idProduct}=="0a2b", ATTR{power/control}="on"
  '';

  users.users.inkpotmonkey.extraGroups = [ "uinput" ];

  # Switch off node-exporter's `powersupplyclass` collector on THIS host only. It is a
  # DEFAULT collector (the monitoring-exporters profile's `enabledCollectors` adds to the
  # defaults, it does not restrict them), and it reads every attribute under
  # /sys/class/power_supply/*. On this Latitude 7490 one of those attributes,
  # BAT0/charge_types, is backed by dell_laptop → dell_smbios → ACPI WMI, and servicing the
  # read needs a 64K *contiguous* kernel allocation:
  #   node_exporter: page allocation failure: order:4, mode:0x40cc0(GFP_KERNEL|__GFP_COMP)
  #     acpi_ut_initialize_buffer → wmidev_evaluate_method [wmi]
  #     → run_smbios_call [dell_smbios] → charge_types_show [dell_laptop]
  # Under memory fragmentation that allocation fails and the kernel dumps a full stack —
  # twice in one week here, on a 5s scrape loop. Scoped to this host rather than the
  # profile because the trigger is the Dell SMBIOS/WMI path, so the other laptops keep
  # their battery metrics. Nothing in the stack consumes `node_power_supply_*` today
  # (no dashboard, no probe), so on this machine the collector was pure cost.
  services.prometheus.exporters.node.extraFlags = [ "--no-collector.powersupplyclass" ];

  # User grants live in the fleet grant matrix (hosts/default.nix), not here.

  system.stateVersion = "25.11";
}
