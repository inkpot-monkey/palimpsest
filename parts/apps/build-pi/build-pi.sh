#!/usr/bin/env bash
set -euo pipefail

APP_NAME="build-pi"
DEFAULT_HOST="porcupineFish"
TARGET_HOST="$DEFAULT_HOST"
DEVICE=""

# Find the real repository root even if running from a Nix store
if [[ -z "${NIXOS_REPO_ROOT:-}" ]]; then
    NIXOS_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
REPO_ROOT="$NIXOS_REPO_ROOT"
cd "$REPO_ROOT"

if [[ ! -f "$REPO_ROOT/flake.nix" ]]; then
    echo "Error: Could not locate flake.nix in $REPO_ROOT" >&2
    exit 1
fi

print_usage() {
    cat <<EOF
Usage:
  ${APP_NAME} provision [device] [config_name]
  ${APP_NAME} targets
  ${APP_NAME} devices

Notes:
  - 'provision' runs bootstrap, build, and flash in one go, then cleans up.
EOF
}

discover_all_hosts() {
    local config
    for config in hosts/*/configuration.nix; do
        [[ -f "$config" ]] || continue
        basename "$(dirname "$config")"
    done | sort -u
}

host_has_sd_target() {
    local host="$1"
    local result
    if result="$(
        nix eval --raw \
          ".#nixosConfigurations.${host}.config.system.build" \
          --apply 'build: if builtins.hasAttr "sdImage" build || (builtins.hasAttr "images" build && builtins.hasAttr "sd-card" build.images) then "1" else "0"' \
          2>/dev/null
    )"; then
        [[ "$result" == "1" ]]
    else
        return 1
    fi
}

discover_sd_targets() {
    local -a hosts=()
    local host
    mapfile -t hosts < <(discover_all_hosts)
    for host in "${hosts[@]}"; do
        if host_has_sd_target "$host"; then
            printf '%s\n' "$host"
        fi
    done
}

ordered_sd_targets() {
    local -a discovered=()
    local -a ordered=()
    local -a remaining=()
    local host
    local default_present=0
    declare -A seen

    mapfile -t discovered < <(discover_sd_targets | sed '/^$/d')
    if (( ${#discovered[@]} == 0 )); then
        mapfile -t discovered < <(discover_all_hosts | sed '/^$/d')
    fi

    for host in "${discovered[@]}"; do
        if [[ "$host" == "$DEFAULT_HOST" ]]; then
            default_present=1
            break
        fi
    done

    if (( default_present == 1 )); then
        ordered+=("$DEFAULT_HOST")
        seen["$DEFAULT_HOST"]=1
    fi

    for host in "${discovered[@]}"; do
        if [[ "$host" =~ (pi|rpi|porcupine) ]] && [[ -z "${seen[$host]:-}" ]]; then
            ordered+=("$host")
            seen["$host"]=1
        fi
    done

    for host in "${discovered[@]}"; do
        if [[ -z "${seen[$host]:-}" ]]; then
            remaining+=("$host")
        fi
    done

    if (( ${#remaining[@]} > 0 )); then
        while IFS= read -r host; do
            if [[ -z "${seen[$host]:-}" ]]; then
                ordered+=("$host")
                seen["$host"]=1
            fi
        done < <(printf '%s\n' "${remaining[@]}" | sort)
    fi

    if (( ${#ordered[@]} > 0 )); then
        printf '%s\n' "${ordered[@]}"
    fi
}

target_hint() {
    local host="$1"
    if [[ "$host" == "$DEFAULT_HOST" ]]; then
        printf 'default'
    elif [[ "$host" =~ (pi|rpi|porcupine) ]]; then
        printf 'pi-like'
    else
        printf 'other'
    fi
}

choose_target() {
    local requested="${1:-}"
    local -a targets=()
    local selection idx found=0

    mapfile -t targets < <(ordered_sd_targets)

    if (( ${#targets[@]} == 0 )); then
        echo "Error: no SD-card-capable targets discovered in flake outputs." >&2
        exit 1
    fi

    if [[ -n "$requested" ]]; then
        TARGET_HOST="$requested"
        for idx in "${!targets[@]}"; do
            if [[ "${targets[$idx]}" == "$requested" ]]; then
                found=1
                break
            fi
        done
        return
    fi

    echo "Select target host configuration to build (most likely first):"
    for idx in "${!targets[@]}"; do
        printf "  %d) %s [%s]\n" "$((idx + 1))" "${targets[$idx]}" "$(target_hint "${targets[$idx]}")"
    done

    read -r -p "Selection [1]: " selection
    selection="${selection:-1}"
    TARGET_HOST="${targets[$((selection - 1))]}"
}

discover_flash_devices() {
    lsblk -dn -o PATH,TYPE,SIZE,RM,RO,TRAN,MODEL | while read -r path type size rm ro tran model; do
        [[ "$type" == "disk" ]] || continue
        [[ "${ro:-0}" == "0" ]] || continue
        
        # --- SAFETY FILTERS ---
        # Hide NVMe (usually internal system drives)
        [[ "$tran" == "nvme" ]] && continue
        # Hide non-removable drives
        { [[ "${rm:-0}" == "0" ]] || [[ "$tran" == "sata" ]]; } && continue
        # Hide virtual/ram devices
        [[ "$path" == /dev/loop* ]] && continue

        local score=100
        [[ "$path" == /dev/mmcblk* ]] && score=10
        [[ "${tran:-}" == "usb" ]] && score=20

        printf "%03d|%s|%s|%s|%s|%s\n" \
          "$score" "$path" "${size:-?}" "${rm:-?}" "${tran:-?}" "${model:-unknown}"
    done | sort -t'|' -k1,1n -k2,2
}

choose_device() {
    local requested="${1:-}"
    local -a candidates=()
    local selection score path size rm tran model

    if [[ -n "$requested" ]]; then
        DEVICE="$requested"
        return
    fi

    mapfile -t candidates < <(discover_flash_devices)
    if (( ${#candidates[@]} == 0 )); then
        echo "No safe writable block devices detected." >&2
        exit 1
    fi

    echo "Select target block device to flash (most likely first):"
    for selection in "${!candidates[@]}"; do
        IFS='|' read -r score path size rm tran model <<<"${candidates[$selection]}"
        printf "  %d) %s (%s, rm=%s, tran=%s, model=%s)\n" \
          "$((selection + 1))" "$path" "$size" "$rm" "$tran" "$model"
    done

    read -r -p "Selection [1]: " selection
    selection="${selection:-1}"
    IFS='|' read -r score path size rm tran model <<<"${candidates[$((selection - 1))]}"
    DEVICE="$path"
}

init_vars() {
    echo "=> Target Configuration: $TARGET_HOST"
    KEY_DIR="/tmp/pi-bootstrap-${TARGET_HOST}/keys"
    mkdir -p "$KEY_DIR"
    chmod 700 "/tmp/pi-bootstrap-${TARGET_HOST}"

    SSH_KEY="$KEY_DIR/ssh_host_ed25519_key"
    PUB_KEY="$SSH_KEY.pub"

    # Secrets live in the separate `secrets/` stash repo (the `secrets` flake input),
    # NOT the main repo. We re-key there, push, then bump the flake input.
    SECRETS_DIR="${REPO_ROOT}/secrets"
    SOPS_CONFIG_PATH="${SECRETS_DIR}/.sops.yaml"

    # Pi images are exposed as `system.build.sdImage` (the older `images.sd-card`
    # attribute does not exist on the pinned nixos-raspberrypi).
    IMAGE_FLAKE_TARGET=".#nixosConfigurations.${TARGET_HOST}.config.system.build.sdImage"

    HOST="root@${TARGET_HOST}"
}

do_bootstrap_logic() {
    # Generate a fresh host key, point the host's SOPS anchor at its derived age key,
    # re-key every secret file the host needs (in the separate `secrets/` stash repo),
    # verify completeness, push, and bump the `secrets` flake input so the build sees it.
    if [[ ! -d "$SECRETS_DIR/.git" ]]; then
        echo "Error: $SECRETS_DIR is not a git checkout of the secrets (stash) repo." >&2
        echo "       It is the 'secrets' flake input — clone it there first." >&2
        exit 1
    fi
    if [[ ! -f "$SOPS_CONFIG_PATH" ]]; then
        echo "Error: Cannot find $SOPS_CONFIG_PATH" >&2
        exit 1
    fi

    echo "=> [1/4] Key Generation ($KEY_DIR)"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "$HOST"

    if ! command -v ssh-to-age > /dev/null 2>&1; then
        echo "Error: ssh-to-age not found" >&2
        exit 1
    fi
    AGE_KEY="$(ssh-to-age -i "$PUB_KEY")"
    echo "Age Public Key: $AGE_KEY"

    echo "=> [2/4] Pointing &${TARGET_HOST} anchor at the new key in $SOPS_CONFIG_PATH"
    local ANCHOR="&${TARGET_HOST}"
    if grep -q "$ANCHOR" "$SOPS_CONFIG_PATH"; then
        # Replace the key value after the anchor (anchor + whitespace + token).
        sed -i -E "s|(${ANCHOR}[[:space:]]+)[^[:space:]]+|\1${AGE_KEY}|" "$SOPS_CONFIG_PATH"
        grep -q "$AGE_KEY" "$SOPS_CONFIG_PATH" || {
            echo "ERROR: failed to update the $ANCHOR anchor in .sops.yaml" >&2
            exit 1
        }
        echo "Updated $ANCHOR -> $AGE_KEY"
    else
        echo "ERROR: anchor '$ANCHOR' not found in $SOPS_CONFIG_PATH." >&2
        echo "       This host is not declared yet. Add a 'keys:' entry" >&2
        echo "       '- $ANCHOR age1...' and reference '*${TARGET_HOST}' in the" >&2
        echo "       creation_rules of every profile this host uses, then re-run." >&2
        exit 1
    fi

    echo "=> [3/4] Re-keying secrets + verifying completeness"
    pushd "$SECRETS_DIR" > /dev/null

    # updatekeys only rewrites a file when its recipient set changed — i.e. exactly the
    # files whose creation_rule references *${TARGET_HOST} (whose key value we just
    # changed). Files the host isn't in report "up to date" and are left untouched, so
    # this re-keys everything the host needs without churning unrelated secrets.
    while IFS= read -r -d '' f; do
        sops updatekeys -y "$f"
    done < <(find . -type f -name '*.yaml' ! -name '.sops.yaml' -print0)

    # Hard gate: sops-install-secrets is all-or-nothing, so every file the host
    # references MUST now carry its key. Enumerate them from the host config and check.
    echo "Verifying every required secret file is keyed to ${TARGET_HOST}..."
    local required missing=0 bn path
    # Anchor the eval to the main repo flake — cwd is currently $SECRETS_DIR.
    required=$(
        nix eval --json "${REPO_ROOT}#nixosConfigurations.${TARGET_HOST}.config.sops.secrets" \
            --apply 's: map (v: baseNameOf v.sopsFile) (builtins.attrValues s)' 2>/dev/null \
        | tr -d '[]" ' | tr ',' '\n' | sort -u
    )
    if [[ -z "$required" ]]; then
        echo "WARNING: could not enumerate ${TARGET_HOST} sops files; skipping verification." >&2
    else
        for bn in $required; do
            path=$(find . -type f -name "$bn" ! -name '.sops.yaml' | head -n1)
            if [[ -n "$path" ]] && grep -q "$AGE_KEY" "$path"; then
                echo "  OK       $bn"
            else
                echo "  MISSING  $bn — not keyed to ${TARGET_HOST}" >&2
                missing=1
            fi
        done
        if [[ "$missing" = 1 ]]; then
            echo "ERROR: some required secret files are not keyed to ${TARGET_HOST}." >&2
            echo "       Add '*${TARGET_HOST}' to their creation_rules in .sops.yaml, then re-run." >&2
            popd > /dev/null
            exit 1
        fi
    fi

    echo "=> [3/4] Publishing re-keyed secrets"
    if git diff --quiet && git diff --cached --quiet; then
        echo "No secret changes to commit (already up to date for this key)."
    else
        git add -A
        git commit -m "build-pi: re-key ${TARGET_HOST} (new host key ${AGE_KEY})"
        git push
    fi
    popd > /dev/null

    # Bump the 'secrets' flake input so the image build picks up the re-keyed files.
    # (nix build tolerates a dirty flake.lock, so this need not be committed to build.)
    echo "Bumping 'secrets' flake input..."
    nix flake update secrets
}

do_flash_logic() {
    echo "=> Building SD image ($IMAGE_FLAKE_TARGET)..."
    nix build "$IMAGE_FLAKE_TARGET" -L
    
    # Use 'find' to locate the .img.zst file reliably across different Nix versions
    # This replaces the failing 'compgen' logic
    local IMG
    IMG=$(find result/ -name "*.img.zst" | head -n1)

    if [[ -z "$IMG" ]]; then
        echo "Error: Could not find built image (.img.zst) under result/" >&2
        exit 1
    fi

    echo "=> [4/4] Flashing to $DEVICE"
    echo "Using image: $IMG"
    echo "WARNING: ALL DATA ON $DEVICE WILL BE LOST."
    
    # Notify the user via desktop notification if available
    if command -v notify-send > /dev/null 2>&1; then
        notify-send -u critical "Build-Pi: Ready to flash!" "The build is complete. Please confirm flashing to $DEVICE in the terminal."
    fi

    read -r -p "Continue? (y/N) " -n 1 REPLY
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi

    # Use the discovered IMG path
    zstdcat "$IMG" | sudo dd of="$DEVICE" bs=4M status=progress conv=fsync

    echo "=> Injecting SSH host keys"
    local partition="${DEVICE}2"
    # Handle NVMe/MMC naming (p2) vs SATA (2)
    [[ "$DEVICE" =~ [0-9]$ ]] && partition="${DEVICE}p2"
    
    MOUNT_POINT="/mnt/pi_bootstrap"
    sudo mkdir -p "$MOUNT_POINT"
    echo "Mounting $partition..."
    sleep 2
    sudo mount "$partition" "$MOUNT_POINT"

    # Inject keys into the mounted filesystem
    sudo mkdir -p "${MOUNT_POINT}/etc/ssh"
    sudo cp "$SSH_KEY" "${MOUNT_POINT}/etc/ssh/"
    sudo cp "$PUB_KEY" "${MOUNT_POINT}/etc/ssh/"
    sudo chmod 600 "${MOUNT_POINT}/etc/ssh/ssh_host_ed25519_key"
    sudo chmod 644 "${MOUNT_POINT}/etc/ssh/ssh_host_ed25519_key.pub"

    echo "Unmounting..."
    sudo umount "$MOUNT_POINT"
}

cmd_provision() {
    choose_device "${1:-}"
    choose_target "${2:-}"
    init_vars
    
    cleanup_provision() {
        echo -e "\n=> [Cleanup] Scrubbing temporary keys..."
        if [[ -d "$KEY_DIR" ]]; then
            find "$KEY_DIR" -type f -exec shred -u {} + 2>/dev/null || true
            rm -rf "$(dirname "$KEY_DIR")"
        fi

        ssh-keygen -R "$TARGET_HOST" 2>/dev/null || true
        ssh-keygen -R "${TARGET_HOST}.local" 2>/dev/null || true
    }
    trap cleanup_provision EXIT INT TERM

    do_bootstrap_logic
    do_flash_logic

    # Final notification
    if command -v notify-send > /dev/null 2>&1; then
        notify-send "Build-Pi: Success!" "The SD card for $TARGET_HOST has been successfully flashed and is ready to use."
    fi
}

case "${1:-}" in
    provision) cmd_provision "${2:-}" "${3:-}" ;;
    targets)   ordered_sd_targets ;;
    devices)   discover_flash_devices ;;
    *)         print_usage; exit 1 ;;
esac
