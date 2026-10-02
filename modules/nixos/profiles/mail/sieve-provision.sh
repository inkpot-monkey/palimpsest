# Run via pkgs.writeShellApplication from ./sieve.nix — no shebang here, it supplies one.
# Converge ONE per-user Sieve script into Stalwart over JMAP (RFC 9661).
#
# WHY JMAP, AND NOT THE CONFIG FILE. Stalwart has no config-file route for
# per-user Sieve: scripts are account data, reachable only over ManageSieve or
# JMAP. JMAP needs no extra listener (ManageSieve would mean opening 4190 and
# punching the firewall), and the account's own password is enough — no admin
# credential. The trusted/system-script alternative was rejected on three
# counts: it sits at MTA policy level rather than user-filing level, it would
# have to claim `session.data.script` which the spam filter may already own, and
# its interpreter does not document imap4flags (so `addflag` may be a no-op
# there). The untrusted/per-user interpreter does support it — verified with
# SieveScript/validate against this server.
#
# IDEMPOTENT. The server is the source of truth: the active script is read back
# and compared, so an unchanged activation writes nothing. That also means a
# wiped Stalwart database self-heals on the next activation, which is the whole
# reason this is a unit and not a one-off by hand.
#
# Required env: JMAP_URL  SIEVE_USER  SIEVE_NAME  SIEVE_FILE
# Credential:   $CREDENTIALS_DIRECTORY/account_password
set -euo pipefail

pw="$(cat "$CREDENTIALS_DIRECTORY/account_password")"
auth=(--silent --show-error --user "$SIEVE_USER:$pw")
want="$(cat "$SIEVE_FILE")"
api="$JMAP_URL/jmap/"

# Stalwart's unit reports active before its JMAP listener accepts connections,
# so After=stalwart.service alone loses the boot race. Wait, bounded, rather
# than failing and leaving the script unprovisioned until the next activation.
for i in $(seq 1 30); do
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --user "$SIEVE_USER:$pw" "$JMAP_URL/jmap/session" || true)"
  [ "$code" = "200" ] && break
  if [ "$i" -eq 30 ]; then
    echo "mail-sieve: JMAP never became reachable at $JMAP_URL (last HTTP $code)" >&2
    exit 1
  fi
  sleep 2
done

sess="$(curl "${auth[@]}" "$JMAP_URL/jmap/session")"
# primaryAccounts is the correct source; fall back to the sole account id for
# servers that omit it rather than guessing a literal.
acc="$(jq -r '.primaryAccounts["urn:ietf:params:jmap:mail"] // (.accounts | keys[0]) // empty' <<<"$sess")"
[ -n "$acc" ] || {
  echo "mail-sieve: could not determine the mail account id from the session" >&2
  exit 1
}

# Rewrite the host out of the session's URL templates. Stalwart advertises them
# against the PUBLIC name on the INTERNAL port (mail.<domain>:8081), which does
# not resolve to this loopback listener even from the host itself. The runbook
# documents this for apiUrl; it applies to uploadUrl and downloadUrl too. Keep
# the path shape — that is the server's to define — and replace only the origin.
upload="$(jq -r '.uploadUrl' <<<"$sess" | sed -E "s#^[a-z]+://[^/]+#$JMAP_URL#")"
download="$(jq -r '.downloadUrl' <<<"$sess" | sed -E "s#^[a-z]+://[^/]+#$JMAP_URL#")"

using='["urn:ietf:params:jmap:core","urn:ietf:params:jmap:sieve"]'
jmap() { curl "${auth[@]}" -X POST "$api" -H 'content-type: application/json' --data "$1"; }

expand() {
  local u="$1"
  u="${u//\{accountId\}/$acc}"
  u="${u//\{blobId\}/$2}"
  u="${u//\{type\}/application%2Fsieve}"
  u="${u//\{name\}/$SIEVE_NAME}"
  printf '%s' "$u"
}

cur="$(jmap "$(jq -nc --argjson u "$using" --arg a "$acc" \
  '{using:$u,methodCalls:[["SieveScript/get",{accountId:$a},"0"]]}')")"
# $n here is a *jq* variable bound by --arg below, not a shell expansion, so the
# single quotes are deliberate.
# shellcheck disable=SC2016
sel='.methodResponses[0][1].list[]? | select(.name==$n)'
id="$(jq -r --arg n "$SIEVE_NAME" "$sel | .id // empty" <<<"$cur")"
blob="$(jq -r --arg n "$SIEVE_NAME" "$sel | .blobId // empty" <<<"$cur")"
active="$(jq -r --arg n "$SIEVE_NAME" "$sel | .isActive // false" <<<"$cur")"

# Already correct AND active? Nothing to do.
if [ -n "$id" ] && [ -n "$blob" ] && [ "$active" = "true" ]; then
  if got="$(curl "${auth[@]}" "$(expand "$download" "$blob")")" && [ "$got" = "$want" ]; then
    echo "mail-sieve: '$SIEVE_NAME' already active and up to date"
    exit 0
  fi
fi

newblob="$(curl "${auth[@]}" -X POST "$(expand "$upload" "")" \
  -H 'content-type: application/sieve' --data-binary "@$SIEVE_FILE" |
  jq -r '.blobId // empty')"
[ -n "$newblob" ] || {
  echo "mail-sieve: blob upload failed" >&2
  exit 1
}

# Validate before activating. A script that does not compile on THIS server is
# not worth installing, and the error here is far more useful than a silent
# delivery-time failure later.
verr="$(jmap "$(jq -nc --argjson u "$using" --arg a "$acc" --arg b "$newblob" \
  '{using:$u,methodCalls:[["SieveScript/validate",{accountId:$a,blobId:$b},"0"]]}')" |
  jq -r '.methodResponses[0][1].error // empty')"
[ -z "$verr" ] || {
  echo "mail-sieve: '$SIEVE_NAME' does not compile: $verr" >&2
  exit 1
}

if [ -n "$id" ]; then
  req="$(jq -nc --argjson u "$using" --arg a "$acc" --arg i "$id" --arg b "$newblob" \
    '{using:$u,methodCalls:[["SieveScript/set",
      {accountId:$a,update:{($i):{blobId:$b}},onSuccessActivateScript:$i},"0"]]}')"
else
  req="$(jq -nc --argjson u "$using" --arg a "$acc" --arg n "$SIEVE_NAME" --arg b "$newblob" \
    '{using:$u,methodCalls:[["SieveScript/set",
      {accountId:$a,create:{s:{name:$n,blobId:$b}},onSuccessActivateScript:"#s"},"0"]]}')"
fi

res="$(jmap "$req")"
err="$(jq -r '.methodResponses[0][1]
  | (.notCreated // {}) * (.notUpdated // {})
  | to_entries[]? | "\(.key): \(.value.type) \(.value.description // "")"' <<<"$res")"
[ -z "$err" ] || {
  echo "mail-sieve: SieveScript/set rejected the script: $err" >&2
  exit 1
}

echo "mail-sieve: '$SIEVE_NAME' provisioned and activated for $SIEVE_USER"
