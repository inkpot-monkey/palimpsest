# The ONE spelling of `tea`'s config.yml — shared by the profile that renders it
# (./forge-client.nix) and the check that proves it still parses
# (parts/checks/forge-client), so the two can never drift into agreeing about a shape
# `tea` no longer accepts.
#
# A function, not a module: it takes the login's four facts and returns the file's text.
# The token comes in as a STRING because the profile passes a sops placeholder and the
# check passes a dummy — neither can be hardcoded here.
#
# ── Why YAML by hand, rather than builtins.toJSON ────────────────────────────────────
# YAML is a JSON superset and `tea` parses a JSON config file perfectly well (measured),
# so toJSON looks like the safer, quoting-proof choice. It is the WRONG one here, and the
# reason is the sops trailing-newline trap: the placeholder is substituted TEXTUALLY at
# activation, so a secret stored with a trailing newline injects a raw newline at that
# point. Inside a JSON string that is a syntax error and `tea` dies with
# "failed to parse config file". In the YAML below it lands after the last key's value and
# is simply whitespace at the end of the document — the token still reads back exactly.
#
# That is also why `token` is the LAST key of the mapping AND the last line of the file.
# Anything after it would be re-indented by that stray newline instead of absorbing it.
# The check pins this: it renders once with a clean token and once with a trailing
# newline and asserts the SAME value reaches the wire.
#
# ── version_check: false ─────────────────────────────────────────────────────────────
# `tea` 0.15.1 passes `SetGiteaVersion("")` to the Gitea SDK when this field is false,
# which skips the SDK's version negotiation — the source of the "version not supported"
# noise a Forgejo server can provoke (palimpsest#206). MEASURED on 0.15.1 against a stub
# server: NEITHER setting produces a /api/v1/version request, so today this changes
# nothing observable. Pinned anyway, because the field is what the upstream code branches
# on and the alternative is threading --no-version-check through every recipe in the
# tracker doc.
#
# Unquoted, deliberately. Forgejo's access tokens are 40 hex characters, so there is
# nothing for YAML to misread — and quoting would undo the paragraph above, since a
# newline inside double quotes is a folded scalar rather than trailing whitespace.
{
  loginName,
  url,
  user,
  token,
}:
''
  logins:
    - name: ${loginName}
      url: ${url}
      user: ${user}
      default: true
      version_check: false
      # `token` is last on purpose; see tea-login.nix.
      token: ${token}''
