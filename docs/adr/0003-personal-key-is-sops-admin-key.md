# The personal SSH key is the sops admin key; headless hosts get a dedicated signing key

`custom.users.inkpotmonkey.identity.sshKey` (the user's personal `~/.ssh/id_ed25519`) is also the sops `&admin` age recipient: `ssh-to-age` of it equals the `&admin` key in `secrets/.sops.yaml`, and `base.nix` feeds it to `sops.age.sshKeyPaths`. That one private key therefore decrypts **every** secret in the fleet and is the re-keying identity.

Because of this, the admin key must never be shipped to a multi-user or code-executing host — most pointedly `kelpy`, which runs the AionUi Claude Code agent as `inkpotmonkey`. Handing that host the key would give arbitrary executed code full decryption and re-key power over the whole fleet. For commit signing or any private-key need on headless/agent hosts, use the dedicated **non-admin** `signing_key` (in `users/inkpotmonkey.yaml`), deployed via system sops; `git.nix` keys off `osConfig.sops.secrets ? inkpotmonkey_signing_key` and falls back to `~/.ssh` elsewhere.

## Consequences

- Only `kelpy`/`stargazer`/`sawtoothShark` host keys are recipients of `users/inkpotmonkey.yaml`.
- This is a security boundary, not a convenience choice: treat any proposal to reuse the admin key on a headless host as a fleet compromise.
