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

    # Use the absolute path discovered via git
    SOPS_CONFIG_PATH="${REPO_ROOT}/.sops.yaml"
    
    # Determine the correct build target (sd-card image vs direct sdImage)
    if nix eval --raw ".#nixosConfigurations.${TARGET_HOST}.config.system.build" --apply 'b: if builtins.hasAttr "sdImage" b then "1" else "0"' 2>/dev/null | grep -q "1"; then
        IMAGE_FLAKE_TARGET=".#nixosConfigurations.${TARGET_HOST}.config.system.build.sdImage"
    else
        IMAGE_FLAKE_TARGET=".#nixosConfigurations.${TARGET_HOST}.config.system.build.images.sd-card"
    fi
    
    HOST="root@${TARGET_HOST}"
}

do_bootstrap_logic() {
    echo "=> [1/4] Key Generation ($KEY_DIR)"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "$HOST"

    if ! command -v ssh-to-age > /dev/null 2>&1; then
        echo "Error: ssh-to-age not found" >&2
        exit 1
    fi
    AGE_KEY="$(ssh-to-age -i "$PUB_KEY")"
    echo "Age Public Key: $AGE_KEY"

    echo "=> [2/4] Updating $SOPS_CONFIG_PATH"
    ANCHOR="&${TARGET_HOST}"
    
    if [[ ! -f "$SOPS_CONFIG_PATH" ]]; then
        echo "Error: Cannot find $SOPS_CONFIG_PATH" >&2
        exit 1
    fi

    # Create a safe temporary file
    local tmp_file
    tmp_file=$(mktemp)
    
    if grep -q "$ANCHOR" "$SOPS_CONFIG_PATH"; then
        echo "Updating $ANCHOR in $SOPS_CONFIG_PATH..."
        # Use -i for in-place edit, and use a simpler but robust regex
        # This matches the line with the anchor and replaces everything after the anchor+space
        sed -i -E "s/($ANCHOR[[:space:]]+)[^[:space:]]+/\1$AGE_KEY/" "$SOPS_CONFIG_PATH"
        
        # Verify the change
        if grep -q "$AGE_KEY" "$SOPS_CONFIG_PATH"; then
            echo "Successfully updated .sops.yaml with the new key."
        else
            echo "ERROR: Failed to update .sops.yaml. The key was not found after sed." >&2
            exit 1
        fi
    else
        echo "Warning: $ANCHOR anchor not found in $SOPS_CONFIG_PATH."
        echo "Key not updated in .sops.yaml. Secrets update might fail."
    fi
    rm -f "$tmp_file"

    echo "=> [3/4] Updating secrets"
    # Move to repo root so SOPS can find .sops.yaml automatically via relative paths
    pushd "$REPO_ROOT" > /dev/null
    
    # We use 'find' to update every secrets file. 
    # Since .sops.yaml is now fixed, updatekeys will find the creation_rules.
    if command -v sops-update-all > /dev/null 2>&1; then
        sops-update-all
    else
        find . -name "secrets.yaml" -exec sops updatekeys -y {} \;
    fi

    # CRITICAL: We MUST stage the changes to .sops.yaml and secrets files.
    # Flake builds only see what is in the git index.
    echo "Staging secret changes for Nix build..."
    git add "$SOPS_CONFIG_PATH"
    find . -name "secrets.yaml" -exec git add {} \;
    
    popd > /dev/null
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
