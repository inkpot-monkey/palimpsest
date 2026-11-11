# The Antela bulbs keep their stock firmware and are controlled locally over the Tuya protocol

[ADR-0015](0015-bulbs-run-esphome-via-cloudcutter.md) chose to flash the Antela bulbs with
ESPHome over the air using tuya-cloudcutter, and recorded the prerequisite that made the choice
contingent: the bulb's firmware had to be "old enough to be exploitable". That prerequisite
fails on the hardware we actually own, and it fails on a published list rather than on a failed
attempt.

The first bulb reports **Main Module v1.6.3**. Cloudcutter's known-patched-firmware list carries
that version verbatim, in its `BK7231N` section:

```
| 1.6.3 | oem_bk7231n_light_ty | Various Bulbs | 3.3.44 BUILD AT:2024_12_12_17_45_32 |
```

Tuya patched the exploit in their SDK in **February 2022**; this firmware was built against SDK
3.3.44 on **2024-12-12**, nearly three years later. Cloudcutter's own wording is that such
devices "will not be vulnerable to Tuya-CloudCutter". There is no attempt to make and no profile
to capture — the over-the-air path is closed on this hardware.

**Decision: the bulbs keep their Tuya firmware, and Home Assistant controls them directly on the
LAN with the `tuya_local` integration, declared in nix as a custom component.**

## Why this beats the alternatives now

ADR-0015 rejected local control of stock firmware on three grounds. Two of them have since
stopped holding, which is what makes this a reversal rather than a concession:

- **"Requires extracting and managing a per-device local key"** — still true, and still the real
  cost. But it is a one-time, per-bulb step through a free Tuya IoT account, not ongoing
  management. See the consequences below.
- **"`localtuya` has an open discovery bug on this exact model"** — that was `localtuya`.
  `tuya_local` is a different, actively maintained component, and the bug does not transfer.
- **"Keeps the proprietary firmware"** — unchanged and conceded. It is the price of the bulb
  staying intact.

What did change decisively is packaging. nixpkgs ships `home-assistant-custom-components.tuya_local`
(2026.10.0 on our pin) with its `tinytuya` dependency, so this is a `customComponents` entry on
the existing profile — no HACS, no runtime pip, no imperative step on the host. The objection
that local control meant leaving the declarative path no longer applies.

Local reachability is measured, not assumed: the bulb answers on **TCP 6668**, the Tuya local
control port, from its LAN address. Control never reaches Tuya's servers.

## Considered and rejected

- **Serial-flash ESPHome over UART** — keeps ADR-0015's design exactly, changing only how the
  firmware is delivered, and cloudcutter explicitly notes patched devices can still be serial
  flashed. Rejected *for now*, not on principle: it needs the bulb opened without destroying it
  and a USB-TTL adapter, `ltchiptool` is not in nixpkgs, and it risks the one bulb we have to
  learn on. It remains the upgrade path, which is why ADR-0015's groundwork is retained rather
  than removed.
- **Tuya's cloud integration** — rejected for the same reason ADR-0015 rejected it: every command
  would round-trip Tuya's servers, against the fleet's local-first posture. Nothing about the
  patched firmware changes that.
- **Replace the bulbs with hardware built for this** (Zigbee, or a module with unpatched
  firmware) — the clean long-term answer for anything bought *next*, but it spends money to
  strand a working bulb, and Zigbee would additionally mean standing up coordinator hardware the
  fleet does not have.

## Consequences

- **The bulb runs vendor firmware we cannot inspect.** It is no longer phoning home for control,
  but it is still Tuya's code on the chip. This is the substantive cost of the decision.
- **Each bulb is a Home Assistant config entry, created in the UI.** The integration is
  config-flow only and declares no discovery mechanism (no `dhcp`, `zeroconf` or `ssdp` in its
  manifest), so HA cannot find a bulb by itself: its LAN address, device id and local key are
  entered by hand. This is the same wall ADR-0015 hit for ESPHome adoption and the voice
  pipeline hit for Wyoming — HA has no declarative path for config entries. If the number of
  bulbs makes the UI step tedious, the established answer in this repo is a post-start
  provisioner driving HA's config-flow API, as `ha-provision-voice.py` already does.
- **The local key is a credential with no machine reader.** No NixOS service consumes it — it
  lives in HA's own `.storage` once entered. It therefore does not belong in a sops profile; the
  operator's vault is its home.
- **The bulb depends on a stable LAN address.** `tuya_local` is configured with a host, so the
  bulb wants a DHCP reservation; a lease change silently breaks control.
- **No firewall change.** HA dials the bulb outbound on TCP 6668 and the device pushes state back
  over that same connection, so the default egress policy already covers it. Note the contrast
  with ADR-0015, which needed inbound UDP 5353 for mDNS.
- **ADR-0015's groundwork is retained but currently unused**: `"esphome"` stays in
  `extraComponents`, the UDP 5353 mDNS rule stays open, and `esphome/antela-a60-1.yaml` plus the
  `profiles/esphome.yaml` build secrets stay in place. They cost almost nothing and are exactly
  what a later serial flash would need.

## What ADR-0015 got right

Two of its findings survived contact with the hardware and are worth keeping:

- **The chip is a Beken BK7231N**, as its research predicted from Antela's other devices.
- **The firmware class is `oem_bk7231n_light_ty`**, Tuya's *single-chip* light class. The bulb has
  no separate MCU despite the Smart Life app listing an "MCU Module" version alongside the main
  one — it reports the same image twice. So the direct-PWM and BP5758D light variants drafted in
  `esphome/antela-a60.yaml.template` are the right shape if the bulb is ever serial flashed.
