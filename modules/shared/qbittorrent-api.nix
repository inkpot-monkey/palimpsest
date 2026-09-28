# The shared qBittorrent WebUI client for kelpy's timer-driven reconcilers.
#
# qBittorrent keeps its settings in container-owned state and offers no way to take them
# from a file or an environment variable — the config is a mutable INI the application
# rewrites for itself, and the only supported way in from outside is the WebUI API. So
# anything here that wants to hold qBittorrent to a declared value has to log in and push
# it, and there is more than one such job (the forwarded-port sync, the preference
# reconciler). This is the one copy of the login dance they share.
#
# Three details are load-bearing and were each learned the hard way:
#
#   * The password goes to curl through a FILE, never through argv. These run on a timer
#     on a host with other logins, and `ps` is world-readable.
#   * A failed login reports the HTTP STATUS AND BODY, not just "login failed". qBittorrent
#     answers a Host-header mismatch with a bare 401 BEFORE it checks the password, so a
#     port misconfiguration is byte-identical to a wrong credential from out here — see
#     qbt_login below.
#   * sops leaves a trailing newline on the value; url-encoded into the form field it is
#     part of the password, and the login fails with a bare "Fails." that says nothing
#     about why. It is stripped here, once, rather than in each caller.
#
# Authenticating at all is a deliberate choice over `WebUI\LocalHostAuth=false`: podman's
# published-port DNAT makes host traffic arrive from the bridge address rather than
# loopback, so "trust localhost" would have meant trusting every process on kelpy — a far
# wider grant than the single credential it would have saved (ADR-0033).
#
# Callers get `qbt_up`, `qbt_login`, `qbt_get <path>` and `qbt_post <path> <field>` in
# scope, and must declare a `RuntimeDirectory` (the cookie jar and the stripped password
# live there, 0700).
{ lib, pkgs }:

{
  # api          — base url of the WebUI, e.g. http://127.0.0.1:8080
  # username     — WebUI account to authenticate as
  # passwordFile — path to its password (sops); trailing newline tolerated
  mkClient =
    {
      api,
      username,
      passwordFile,
    }:
    ''
      qbt_jar="$RUNTIME_DIRECTORY/cookies"
      qbt_pw="$RUNTIME_DIRECTORY/password"

      # Reachability is checked separately from authentication so a tick that lands
      # mid-restart can be skipped rather than reported as a failure: the container being
      # down is already the unit-state check's alarm, and a second alarm for one fault is
      # noise. Bad credentials are not transient and do fail.
      qbt_up() {
        ${pkgs.curl}/bin/curl -sS -m 10 -o /dev/null "${api}/api/v2/app/version" 2>/dev/null
      }

      # On failure this reports the HTTP STATUS AND BODY, and names the mode the status
      # implies. It used to say only "WebUI login failed", which flattened three unrelated
      # faults into one sentence naming just the first — and the two it did not name both
      # LOOK like a wrong password from here:
      #
      #   200 "Fails."  genuinely bad credentials.
      #   401           Host header validation. qBittorrent compares the Host header's port
      #                 against its own WebUI\Port and rejects a mismatch BEFORE looking at
      #                 the password, so a correct and an incorrect password return
      #                 byte-identical responses. Cost an hour on rk1b, where the published
      #                 port (8090) had diverged from the container's (8080).
      #   403           this IP is banned after repeated failures — which a failing timer
      #                 causes by itself, hiding the real fault behind a symptom of itself.
      qbt_login() {
        ${pkgs.coreutils}/bin/install -m 0600 /dev/null "$qbt_pw"
        ${pkgs.coreutils}/bin/tr -d '\n' < ${lib.escapeShellArg passwordFile} > "$qbt_pw"

        qbt_login_body="$RUNTIME_DIRECTORY/login-body"
        qbt_login_code="$(${pkgs.curl}/bin/curl -sS -m 10 -c "$qbt_jar" \
               -o "$qbt_login_body" -w '%{http_code}' \
               -d "username=${username}" \
               --data-urlencode "password@$qbt_pw" \
               "${api}/api/v2/auth/login" 2>/dev/null || echo 000)"

        if [ "$qbt_login_code" = 200 ] \
           && ${pkgs.gnugrep}/bin/grep -qx 'Ok.' "$qbt_login_body" 2>/dev/null; then
          return 0
        fi

        # Bounded and newline-stripped: this lands in the journal, one line per attempt.
        qbt_login_text="$(${pkgs.coreutils}/bin/head -c 200 "$qbt_login_body" 2>/dev/null \
          | ${pkgs.coreutils}/bin/tr -d '\r\n' || true)"
        echo "qbittorrent-api: WebUI login failed for user ${username} at ${api} — HTTP $qbt_login_code, body: '$qbt_login_text'" >&2

        case "$qbt_login_code" in
          200) echo "qbittorrent-api: a 200 'Fails.' is a genuine credential rejection — compare the sops value against WebUI\Password_PBKDF2 in qBittorrent.conf." >&2 ;;
          401) echo "qbittorrent-api: 401 is HOST HEADER validation, NOT credentials — qBittorrent rejects a Host whose port differs from its own WebUI\Port before checking the password. Compare the published port with custom.profiles.media.qbittorrent.webuiPort." >&2 ;;
          403) echo "qbittorrent-api: 403 means this IP is BANNED after repeated failed logins (WebUI\MaxAuthenticationFailCount). It clears on the ban timeout or a qBittorrent restart — fix the underlying fault first or the next tick re-bans." >&2 ;;
          000) echo "qbittorrent-api: no HTTP response at all — curl could not reach the WebUI (container down, or the published port moved)." >&2 ;;
        esac
        return 1
      }

      qbt_get() {
        ${pkgs.curl}/bin/curl -sS -m 10 -b "$qbt_jar" "${api}/api/v2/$1"
      }

      qbt_post() {
        ${pkgs.curl}/bin/curl -sS -m 10 -b "$qbt_jar" -o /dev/null \
          --data-urlencode "$2" "${api}/api/v2/$1"
      }
    '';
}
