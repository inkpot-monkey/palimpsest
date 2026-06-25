# Shared builder for a bridge's "management DM" auto-provisioner.
#
# Each bridge that wants an admin/management DM with its bot (the room where the
# interactive login is run — WhatsApp QR, hookshot `github login`, …) declares
# its OWN service next to the bridge instead of registering in a central list:
#
#   systemd.services."matrix-dm-<bot>" =
#     (import ./dm-provision.nix { inherit pkgs config; }) {
#       bot = "<bot>"; afterUnit = "<bridge>.service"; encrypted = …; topic = …; welcomeCommand = …;
#     };
#
# The provisioner creates a `is_direct` room and invites the bot; the bridge bot
# auto-joins the invite (that join is the bridge's own behaviour). Idempotency is
# a PERSISTED marker in the service StateDirectory — tuwunel doesn't reliably
# round-trip m.direct, so the marker (not account data) is the source of truth.
# The marker dir shares the homeserver's persistence lifetime: kept together
# across reboots, wiped together by `matrix-reset`. That coupling is what stops
# the "markers say the DM exists but the homeserver was wiped" desync.
#
# Per-bridge knobs:
#   encrypted       create the room with m.room.encryption on. REQUIRED for
#                   mautrix bridges that set encryption.require = true (otherwise
#                   the bot drops every command as an unencrypted event).
#   topic           room topic, set as plain state — visible even in an e2ee room,
#                   so it's the reliable "what do I type here" hint.
#   welcomeCommand  a command posted into the room so the bridge replies with its
#                   own help/welcome. Only sent into UNENCRYPTED rooms — the
#                   provisioner has no e2ee keys, so it can't speak in an encrypted
#                   room (there the topic carries the instructions instead).
{
  pkgs,
  config,
}:

{
  bot,
  afterUnit,
  encrypted ? false,
  topic ? "",
  welcomeCommand ? "",
}:
let
  g = config.services.matrix-tuwunel.settings.global;
  domain = g.server_name;
  address = builtins.head g.address;
  matrixPort = builtins.head g.port;
  adminLocalpart = config.custom.profiles.matrix.adminLocalpart;

  # Extra createRoom fields built in Nix and merged by jq via --argjson, so no
  # bash-quoting of the topic/encryption JSON is needed.
  createExtra = builtins.toJSON (
    (if topic != "" then { inherit topic; } else { })
    // (
      if encrypted then
        {
          initial_state = [
            {
              type = "m.room.encryption";
              state_key = "";
              content.algorithm = "m.megolm.v1.aes-sha2";
            }
          ];
        }
      else
        { }
    )
  );

  # Welcome is best-effort and only for unencrypted rooms (see header).
  sendWelcome = welcomeCommand != "" && !encrypted;

  provision = pkgs.writeShellScript "matrix-provision-dm-${bot}" ''
    set -eu
    url="http://${address}:${toString matrixPort}"
    me="@${adminLocalpart}:${domain}"
    bot="@${bot}:${domain}"
    marker="$STATE_DIRECTORY/dm-created"

    # Log in up front — needed whether we create the DM or just re-assert its
    # favourite tag below (so an already-provisioned DM still gets favourited on a
    # later deploy, not only on first creation). createRoom is still gated on the
    # marker, so this stays idempotent — no second room.
    for _ in $(seq 1 30); do
      ${pkgs.curl}/bin/curl -sf "$url/_matrix/client/versions" >/dev/null && break
      sleep 2
    done

    pass="$(cat "$CREDENTIALS_DIRECTORY/admin_password")"
    at="$(${pkgs.curl}/bin/curl -s -X POST "$url/_matrix/client/v3/login" \
      -H 'content-type: application/json' \
      -d "$(${pkgs.jq}/bin/jq -nc --arg u "${adminLocalpart}" --arg p "$pass" \
        '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')" \
      | ${pkgs.jq}/bin/jq -r '.access_token // empty')"
    [ -n "$at" ] || { echo "dm-provision[$bot]: admin login failed" >&2; exit 1; }
    auth=(-H "Authorization: Bearer $at")
    meenc="$(${pkgs.jq}/bin/jq -rn --arg m "$me" '$m|@uri')"

    if [ -s "$marker" ]; then
      rid="$(cat "$marker")"
      echo "dm-provision[$bot]: already created -> $rid"
    else
      # Create the DM and invite the bot — the bridge bot auto-joins the invite.
      # createExtra carries the topic and (for require-encryption bridges) turns on
      # e2ee so the bot doesn't drop the user's commands as unencrypted.
      rid="$(${pkgs.curl}/bin/curl -s "''${auth[@]}" -X POST "$url/_matrix/client/v3/createRoom" \
        -H 'content-type: application/json' \
        -d "$(${pkgs.jq}/bin/jq -nc --arg b "$bot" --argjson extra '${createExtra}' \
          '{is_direct:true,invite:[$b],preset:"trusted_private_chat"} + $extra')" \
        | ${pkgs.jq}/bin/jq -r '.room_id // empty')"
      [ -n "$rid" ] || { echo "dm-provision[$bot]: createRoom failed" >&2; exit 1; }
      printf '%s' "$rid" > "$marker"
      echo "dm-provision[$bot]: created DM -> $rid"
      ridenc="$(${pkgs.jq}/bin/jq -rn --arg r "$rid" '$r|@uri')"

      # Best-effort m.direct tag so clients file the room under People. tuwunel's
      # account-data handling is unreliable, so this never fails the unit.
      #
      # m.direct is a SINGLE object keyed by bot, shared across every DM
      # provisioner, so concurrent read-modify-write races (one bot reads stale,
      # then clobbers another's entry). Serialize the RMW under a shared advisory
      # lock so co-booting provisioners take turns. The lock fd is opened READ-ONLY
      # (flock needs only an open fd, not a writable one) since these DynamicUser
      # units see /run read-only. Best-effort: proceed unlocked if it's missing.
      exec 9</run/matrix-dm-mdirect.lock 2>/dev/null && ${pkgs.util-linux}/bin/flock 9 || true
      direct="$(${pkgs.curl}/bin/curl -s "''${auth[@]}" \
        "$url/_matrix/client/v3/user/$meenc/account_data/m.direct" \
        | ${pkgs.jq}/bin/jq -c 'if (type=="object" and (has("errcode")|not)) then . else {} end' \
          2>/dev/null || echo '{}')"
      direct="$(printf '%s' "$direct" | ${pkgs.jq}/bin/jq -c --arg b "$bot" --arg r "$rid" \
        '.[$b] = ((.[$b] // []) + [$r])')"
      ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
        "$url/_matrix/client/v3/user/$meenc/account_data/m.direct" \
        -H 'content-type: application/json' -d "$direct" >/dev/null \
        && echo "dm-provision[$bot]: m.direct updated" \
        || echo "dm-provision[$bot]: m.direct update failed (non-fatal)" >&2
      exec 9>&- 2>/dev/null || true
      ${pkgs.lib.optionalString sendWelcome ''

        # Welcome: wait for the bot to join, then post its own help command so the
        # room opens with usage instructions (unencrypted rooms only).
        for _ in $(seq 1 20); do
          in_room="$(${pkgs.curl}/bin/curl -s "''${auth[@]}" \
            "$url/_matrix/client/v3/rooms/$ridenc/joined_members" \
            | ${pkgs.jq}/bin/jq -r --arg b "$bot" '.joined | has($b)' 2>/dev/null || echo false)"
          [ "$in_room" = "true" ] && break
          sleep 2
        done
        txn="welcome-$(${pkgs.coreutils}/bin/date +%s)"
        ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
          "$url/_matrix/client/v3/rooms/$ridenc/send/m.room.message/$txn" \
          -H 'content-type: application/json' \
          -d "$(${pkgs.jq}/bin/jq -nc --arg c '${welcomeCommand}' '{msgtype:"m.text",body:$c}')" >/dev/null \
          && echo "dm-provision[$bot]: sent welcome command '${welcomeCommand}'" \
          || echo "dm-provision[$bot]: welcome send failed (non-fatal)" >&2
      ''}
    fi

    # Favourite the DM so it's easy to find — re-asserted every run (idempotent;
    # personal account data, so it works regardless of power level). Best-effort.
    ridenc="$(${pkgs.jq}/bin/jq -rn --arg r "$rid" '$r|@uri')"
    ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
      "$url/_matrix/client/v3/user/$meenc/rooms/$ridenc/tags/m.favourite" \
      -H 'content-type: application/json' -d '{"order":0.1}' >/dev/null \
      && echo "dm-provision[$bot]: marked favourite" \
      || echo "dm-provision[$bot]: favourite failed (non-fatal)" >&2
    ${pkgs.lib.optionalString (topic != "") ''

      # Keep the topic current on EXISTING rooms too (not just at creation) — it's
      # plain room state (not encrypted), so a changed/added topic lands on deploy.
      ${pkgs.curl}/bin/curl -sf "''${auth[@]}" -X PUT \
        "$url/_matrix/client/v3/rooms/$ridenc/state/m.room.topic" \
        -H 'content-type: application/json' \
        -d "$(${pkgs.jq}/bin/jq -nc --arg t ${pkgs.lib.escapeShellArg topic} '{topic:$t}')" >/dev/null \
        && echo "dm-provision[$bot]: topic ensured" \
        || echo "dm-provision[$bot]: topic update failed (non-fatal)" >&2
    ''}
  '';
in
{
  description = "Auto-create the @${bot} management DM with @${adminLocalpart}:${domain}";
  after = [
    "tuwunel.service"
    "tuwunel-register-admin.service"
    afterUnit
  ];
  requires = [
    "tuwunel.service"
    "tuwunel-register-admin.service"
  ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    DynamicUser = true;
    # Persisted marker dir — see the per-bridge environment.persistence entry.
    StateDirectory = "matrix-dm-${bot}";
    StateDirectoryMode = "0700";
    LoadCredential = [ "admin_password:${config.sops.secrets.matrix_admin_password.path}" ];
    ExecStart = provision;
  };
}
