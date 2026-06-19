# Smart bulbs run local ESPHome firmware, flashed via tuya-cloudcutter

The Antela smart bulbs are WiFi/Tuya devices, so the obvious path is Home Assistant's built-in `tuya` cloud integration. We instead flash them with ESPHome (LibreTiny) over-the-air using [tuya-cloudcutter](https://github.com/tuya-cloudcutter/tuya-cloudcutter) and adopt them through HA's native ESPHome integration. This keeps the fleet's local-first, tailnet-only posture — the bulbs never depend on Tuya's cloud — and makes each bulb's firmware a version-controlled ESPHome YAML, consistent with the declarative ethos.

## Considered Options

- **Official Tuya cloud integration** — rejected: every command round-trips Tuya's servers; an external dependency, and the bulbs phone home, contrary to the fleet's local-first posture.
- **`tuya_local` / `localtuya` (local control of stock Tuya firmware)** — rejected: keeps the proprietary firmware, requires extracting and managing a per-device local key, and `localtuya` has an open, unresolved discovery bug on this exact model (Antela Filament A60, rospogrigio/localtuya#1946).
- **OpenBeken/Tasmota over MQTT** — rejected: would require standing up a mosquitto broker (no MQTT on the fleet today) for no real gain over ESPHome here.

## Consequences

- Flashing is hard to reverse and carries bricking risk. It depends on the bulb's chip (Beken BK7231T/BK7231N or Realtek RTL8720CF) being cloudcutter-supported **and** its firmware being old enough to be exploitable — so the bulbs must **not** be updated in the Smart Life app before flashing.
- ESPHome firmware is built with network access via the `esphome` CLI (`nix run nixpkgs#esphome`), **not** a hermetic nix derivation, because LibreTiny/PlatformIO downloads its toolchain at build time. The per-bulb YAMLs are the repo's source of truth; their secrets (WiFi PSK, API encryption key, OTA password) live in stash (sops), decrypted to an ephemeral `secrets.yaml` at build time.
- HA discovers the bulbs over mDNS, so rk1b's firewall opens UDP 5353 on the LAN, and `"esphome"` is added to `services.home-assistant.extraComponents` (an integration HA cannot pip-install at runtime on NixOS).
