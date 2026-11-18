# The personal SSH key is the sops admin key; headless hosts get a dedicated signing key

`contract.users.inkpotmonkey.identity.sshKey` (the user's personal `~/.ssh/id_ed25519`) is also the sops `&admin` age recipient: `ssh-to-age` of it equals the `&admin` key in `secrets/.sops.yaml`, and `base.nix` feeds it to `sops.age.sshKeyPaths`. That one private key therefore decrypts **every** secret in the fleet and is the re-keying identity.

Because of this, the admin key must never be shipped to a multi-user or code-executing host — most pointedly `kelpy`, which runs the AionUi Claude Code agent as `inkpotmonkey`, and now `rk1b`, which runs opencode's server-side agent sessions as the same account. Handing either host the key would give arbitrary executed code full decryption and re-key power over the whole fleet. For commit signing or any private-key need on headless/agent hosts, use the dedicated **non-admin** `signing_key` (in `users/inkpotmonkey.yaml`), deployed via system sops.

## Amendment, 2026-11-18: how the key is actually delivered

This record previously said *"`git.nix` keys off `osConfig.sops.secrets ? inkpotmonkey_signing_key` and falls back to `~/.ssh` elsewhere."* **That mechanism did not exist.** No such branch was in `git.nix`, and nothing anywhere in either repository referenced the secret — it sat in `users/inkpotmonkey.yaml` read by nobody. The decision above was right; its stated implementation was fiction, and it went unnoticed because no headless seat had yet been asked to commit.

It cannot work that way either, for a reason worth recording: a home **cannot** read NixOS sops (the confinement invariant makes `sops.*` unexpressible in a home), and homes are built per **mode**, not per host — so a home can neither branch on which host it is on nor point `signing.key` at a path only one host has.

The **private** half's delivery is therefore entirely host-side, in `profiles/agent-signing.nix`: the host places the dedicated key at `~/.ssh/id_ed25519` via a sops secret plus a `systemd.tmpfiles` `L+` symlink (the same self-healing shape `forge-client.nix` uses, which survives an impermanence tmpfs home).

**The public half could not be, and the first attempt at this was wrong.** It was written on the premise that the home could be left completely alone, with its existing assumption — that the key is at `~/.ssh/id_ed25519` — merely made true on that host. That premise was false: the home *declares* `~/.ssh/id_ed25519.pub` itself (`home.file`, from `identity.sshKey`), so the host's private key landed beside the home's **personal** public key. `ssh-keygen -Y sign` neither falls back nor warns on a mismatch — it fails every commit with `Public key … doesn't match private …`. The configuration evaluated and deployed green throughout; only an actual `git commit` on the host surfaced it.

So the home does change, and the change is a mode split rather than a host condition, since a home cannot know which host binds it: `users/inkpotmonkey/cli.nix` joins `gui.nix` as a mode root, and each declares its own `.pub` — the personal key for a desktop seat that holds it, the agent key for a headless one that must not. The key's public half is declared once in `users/inkpotmonkey/agent-signing-key.nix` and read twice (that `.pub`, and `git.nix`'s `allowed_signers`), because those two disagreeing is precisely the failure above.

Verified the way it should have been the first time — a real signed commit on `rk1b`, reporting `G` against `allowed_signers`.

Two consequences of that choice, both deliberate:

- **The same filename holds a different key on different hosts.** On `sawtoothShark` `~/.ssh/id_ed25519` is the admin key; on an agent host it is the non-admin signing key. `ssh-keygen -lf` distinguishes them (the agent key's comment reads `kelpy-aionui-signing`). The alternative was a different filename plus a home change to point at it, which would have cost the zero-home-change property.
- **The public half is declared in `identities.nix` as `agentSigningKey`**, because two consumers need it and neither can derive it: the host writes it beside the private key, and the operator's `git.nix` needs it as a second `allowed_signers` entry to verify what those hosts signed. The contract does not carry it into a home, so `git.nix` holds a documented literal; carrying it properly is a change to the contract repo.

## Consequences

- `kelpy`, `sawtoothShark` and `rk1b` host keys are recipients of `users/inkpotmonkey.yaml`. `rk1b` was already one — widened for the qBittorrent WebUI password — so agent signing there needed no re-key.
- This is a security boundary, not a convenience choice: treat any proposal to reuse the admin key on a headless host as a fleet compromise.
- The planned host↔user split extends this boundary to feature granularity: a user's master key never reaches a host, which receives only the narrow per-feature secrets it grants — so a host granting only a login shell holds no private key material. See [contract ADR-0001](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0001-host-user-contract.md).
