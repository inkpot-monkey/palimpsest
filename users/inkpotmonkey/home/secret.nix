# The "Operator read" path onto the Stash (CONTEXT.md → Secrets): a `pass`-style,
# by-hand read of a single secret at the terminal. It deliberately names sops and
# the stash layout — the backend-agnostic rule (platform interface, contract
# ADR-0005) governs feature *provisioning onto hosts*, not a human reading their own
# stash. Installed gui-scoped (users/inkpotmonkey/home/gui.nix), the only place the
# admin key, the working-tree checkout, and the clipboard all live. Reads the editable
# working-tree checkout, NOT the flake-pinned/deployed value — so it answers "what's
# in my stash", never "what is host X running". Decrypts in memory, writes nothing to
# disk. Nest through maps with `/`; a literal key may itself contain `.` (e.g.
# apikey@api.anthropic.com). Stash root defaults to ~/code/nixos/secrets, overridable
# via $SECRET_STORE_DIR.
#   secret cloudflare/api_token             # from users/<you>.yaml (the default)
#   secret apikey@api.anthropic.com         # dotted top-level key, taken verbatim
#   secret -f profiles/monitoring.yaml key  # from another stash file
#   secret -c cloudflare/api_token          # to clipboard, auto-clears ($SECRET_CLIP_TIME, 45s)
#   secret -l                               # list keys (no decrypt); -f <file> -l for another file
#
# Factored out of gui.nix so parts/checks/secret-read exercises the real derivation
# (not a copy). Parameterised only by the identity that sets the default file path;
# both parameters are runtime-overridable ($SECRET_STORE_DIR, -f), so the check can
# drive it against a throwaway fixture.
{
  pkgs,
  username,
  homeDirectory,
}:
pkgs.writeShellApplication {
  name = "secret";
  runtimeInputs = [
    pkgs.sops
    pkgs.yq-go
  ];
  text = ''
    store="''${SECRET_STORE_DIR:-${homeDirectory}/code/nixos/secrets}"
    file="$store/users/${username}.yaml"

    clip=0; list=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -c) clip=1; shift ;;
        -l) list=1; shift ;;
        -f) [ -n "''${2:-}" ] || { echo "secret: -f needs a stash-relative path" >&2; exit 2; }
            file="$store/$2"; shift 2 ;;
        --) shift; break ;;
        -*) echo "secret: unknown flag $1" >&2; exit 2 ;;
        *)  break ;;
      esac
    done

    # -l: list the key tree straight from the ciphertext — sops keeps map keys in
    # plaintext, so this never decrypts a value (the `pass ls` analogue).
    if [ "$list" -eq 1 ]; then
      exec yq 'del(.sops) | (.. | select(tag != "!!map" and tag != "!!seq")) |= "***"' "$file"
    fi

    key="''${1:-}"
    [ -n "$key" ] || {
      echo "usage: secret [-c] [-f <stash-relative.yaml>] <key[/nested]>" >&2
      echo "       secret [-f <stash-relative.yaml>] -l    # list keys, no decrypt" >&2
      exit 2
    }
    extract=""
    IFS='/' read -ra parts <<< "$key"
    for p in "''${parts[@]}"; do extract+="[\"$p\"]"; done

    if [ "$clip" -eq 0 ]; then
      exec sops -d --extract "$extract" "$file"
    fi

    # -c: copy to clipboard via stdin (never argv, so it stays out of `ps`), then a
    # detached watcher clears it after $SECRET_CLIP_TIME — but only if the selection
    # still holds our value, so we never clobber something copied since. Clearing is
    # "copy an empty string": wl-copy --clear is a no-op on some compositors, whereas
    # emptying the selection is portable to both wl-copy and xclip.
    val="$(sops -d --extract "$extract" "$file")"
    clip_time="''${SECRET_CLIP_TIME:-45}"
    if [ -n "''${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then
      copy=(wl-copy); paste=(wl-paste --no-newline)
    elif [ -n "''${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1; then
      copy=(xclip -selection clipboard -in); paste=(xclip -selection clipboard -out)
    else
      echo "secret: no clipboard tool (need wl-copy on Wayland or xclip on X11)" >&2
      exit 1
    fi
    printf '%s' "$val" | "''${copy[@]}"
    # trap HUP + detach stdio so closing the terminal can't strand the secret unwiped.
    ( trap "" HUP
      sleep "$clip_time"
      now="$("''${paste[@]}" 2>/dev/null || true)"
      [ "$now" = "$val" ] && printf "" | "''${copy[@]}"
    ) </dev/null >/dev/null 2>&1 &
    echo "secret: copied to clipboard, clears in ''${clip_time}s" >&2
  '';
}
