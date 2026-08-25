# The shared alert-delivery function for the fleet's timer-driven watchers.
#
# Every bespoke check here (unit-state, git-annex, dmarc, tlsrpt, disk-space, …) had its
# own byte-identical copy of a `post()` that curl'd the #infra-alerts hookshot webhook and
# shrugged off failure with a log line. That copy carried a blind spot none of them could
# see past: the webhook is `https://hookshot.<domain>/webhook/<id>`, which resolves to
# KELPY. Every alert those checks raise is delivered *through* the host most likely to be
# the subject of the alert, so when kelpy is unwell the message saying so cannot arrive.
#
# It is not hypothetical. rk1b's git-annex watcher logged ten of these in 30 days, and
# every one was trying to say `remote 'kelpy' is unreachable`:
#
#   git-annex-alert: failed to POST alert (hookshot down?): 🚨 [rk1b] git-annex —
#     repo 'music': remote 'kelpy' is unreachable — …
#
# The alert that mattered most was the one guaranteed to be dropped.
#
# So `post()` gains a second leg: if the in-band POST fails, fall back to the out-of-band
# push relay (ADR-0020), which is a Cloudflare Worker and therefore shares none of kelpy's
# failure domain. Fallback, NOT duplication — ADR-0020 is explicit that the phone should
# buzz "exactly when the in-band Matrix path can't carry the message, not for an ordinary
# 'a service is down while kelpy is up'". An ordinary alert still goes to Matrix alone.
#
# WHERE IT APPLIES. The relay's publish token and topic are sops secrets currently keyed
# for rk1b only, so `outOfBand` is passed on rk1b's checks and omitted on kelpy's. That
# asymmetry is the right one anyway: kelpy's own checks run ON kelpy and post to its
# LOOPBACK hookshot, so a kelpy outage stops the checks themselves — there is no message
# left to rescue. The rescuable case is precisely rk1b observing kelpy, which is what the
# ten dropped alerts were. Extending it to kelpy would need monitoring.yaml re-keyed for
# that host, and sops here is all-or-nothing per host (AGENTS.md).
#
# Callers get `url` (the in-band webhook, read from its file) and `post <text>` in scope.
{ lib, pkgs }:

{
  # Derive the out-of-band channel from whatever this host already has, so no check needs
  # its own option or secret. The uptime watcher (rk1b) is what declares the relay's
  # publish token and topic; a host that does not run it — or runs it with the channel
  # off — yields null and its checks keep their previous in-band-only behaviour exactly.
  # `or`-guarded throughout so reading the watcher's options is safe where undeclared.
  oobFromWatcher =
    config:
    let
      watcher = config.custom.profiles.monitoring-watcher or null;
      oob = if watcher != null then (watcher.outOfBand or null) else null;
      secrets = config.sops.secrets or { };
      hasSecrets = (secrets ? push_relay_publish_token) && (secrets ? push_relay_topic);
    in
    if oob != null && (oob.enable or false) && hasSecrets then
      {
        inherit (oob) relayUrl;
        tokenFile = secrets.push_relay_publish_token.path;
        topicFile = secrets.push_relay_topic.path;
      }
    else
      null;

  # name       — log prefix, so a failure line still says which watcher produced it
  # webhookUrlFile — file holding the #infra-alerts webhook url (may be null)
  # outOfBand  — null, or { relayUrl; tokenFile; topicFile; } for the ADR-0020 relay
  mkPost =
    {
      name,
      webhookUrlFile,
      outOfBand ? null,
    }:
    let
      readUrl =
        if webhookUrlFile == null then
          ''url=""''
        else
          ''url="$(cat ${lib.escapeShellArg webhookUrlFile} 2>/dev/null || true)"'';

      # ntfy publish shape, as the relay expects it (and as Gatus's stock alerter sends):
      # the topic travels in the JSON BODY rather than the URL path, and the token is
      # presented with the `tk_` prefix Gatus validates — the relay accepts either form.
      oobLeg =
        if outOfBand == null then
          ''
            echo "${name}: no out-of-band channel configured on this host; alert dropped" >&2
            return 0
          ''
        else
          ''
            oob_token="$(cat ${lib.escapeShellArg outOfBand.tokenFile} 2>/dev/null || true)"
            oob_topic="$(cat ${lib.escapeShellArg outOfBand.topicFile} 2>/dev/null || true)"
            if [ -z "$oob_token" ] || [ -z "$oob_topic" ]; then
              echo "${name}: out-of-band secrets unavailable; alert dropped: $1" >&2
              return 0
            fi
            if ${pkgs.curl}/bin/curl -sS -m 15 -o /dev/null \
              -H "Authorization: Bearer tk_$oob_token" \
              -H 'content-type: application/json' \
              --data "$(${pkgs.jq}/bin/jq -nc --arg t "$oob_topic" --arg m "$1" \
                          '{topic:$t, title:"fleet alert (in-band down)", message:$m}')" \
              ${lib.escapeShellArg outOfBand.relayUrl}; then
              echo "${name}: in-band POST failed; delivered out-of-band instead" >&2
            else
              echo "${name}: BOTH delivery paths failed; alert dropped: $1" >&2
            fi
            return 0
          '';
    in
    ''
      ${readUrl}

      post() { # $1 = message text
        if [ -n "$url" ] && ${pkgs.curl}/bin/curl -sS -m 10 -o /dev/null \
          -H 'content-type: application/json' \
          --data "$(${pkgs.jq}/bin/jq -nc --arg t "$1" '{text:$t}')" \
          "$url"; then
          return 0
        fi
        if [ -z "$url" ]; then
          echo "${name}: webhook url not available yet" >&2
        else
          echo "${name}: failed to POST alert in-band (hookshot down?)" >&2
        fi
        ${oobLeg}
      }
    '';
}
