# The shared qBittorrent WebUI client for kelpy's timer-driven reconcilers.
#
# qBittorrent keeps its settings in container-owned state and offers no way to take them
# from a file or an environment variable — the config is a mutable INI the application
# rewrites for itself, and the only supported way in from outside is the WebUI API. So
# anything here that wants to hold qBittorrent to a declared value has to log in and push
# it, and there is more than one such job (the forwarded-port sync, the preference
# reconciler). This is the one copy of the login dance they share.
#
# Two details are load-bearing and were both learned the hard way:
#
#   * The password goes to curl through a FILE, never through argv. These run on a timer
#     on a host with other logins, and `ps` is world-readable.
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

      qbt_login() {
        ${pkgs.coreutils}/bin/install -m 0600 /dev/null "$qbt_pw"
        ${pkgs.coreutils}/bin/tr -d '\n' < ${lib.escapeShellArg passwordFile} > "$qbt_pw"
        if ! ${pkgs.curl}/bin/curl -sS -m 10 -c "$qbt_jar" \
               -d "username=${username}" \
               --data-urlencode "password@$qbt_pw" \
               "${api}/api/v2/auth/login" | ${pkgs.gnugrep}/bin/grep -qx 'Ok.'; then
          echo "qbittorrent-api: WebUI login failed for user ${username}" >&2
          return 1
        fi
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
