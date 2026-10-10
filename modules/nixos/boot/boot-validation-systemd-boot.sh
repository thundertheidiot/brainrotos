# shellcheck shell=bash
# Private BLS aliases let a single default glob select the candidate until
# its native boot count is exhausted, then the exact snapshotted fallback.

loader_entry() {
  local system entry init boot_root payload hash bare="" counted=""
  system=$(generation_system "$1") || return 1
  [ -d "$system" ] || return 1
  init=$(readlink -e "$system/init") || return 1
  boot_root=$(dirname "$(dirname "$ENTRIES_DIR")")
  for entry in "$ENTRIES_DIR"/nixos-*.conf; do
    [ -f "$entry" ] || break
    # Entries are content-addressed (nixos-<sha256>[+N-M].conf) and shared by
    # closures with identical boot configuration. Like the native builder,
    # ignore files whose content no longer matches the hash in their name.
    hash=${entry##*/}
    hash=${hash#nixos-}
    hash=${hash%.conf}
    hash=${hash%%+*}
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || continue
    [ "$(sha256sum "$entry" | awk '{print $1}')" = "$hash" ] || continue
    # Check the closure identity, not just the filename left by an old install.
    awk -v init="init=$init" '
      $1 == "options" { for (i = 2; i <= NF; i++) if ($i == init) matched = 1 }
      $1 == "linux" && NF == 2 { kernel = 1 }
      $1 == "initrd" && NF == 2 { initrd = 1 }
      END { exit !(matched && kernel && initrd) }
    ' "$entry" || continue
    while IFS= read -r payload; do
      case "$payload" in /*) ;; *) return 1 ;; esac
      [ -f "$boot_root$payload" ] || return 1
    done < <(awk '$1 == "linux" || $1 == "initrd" || $1 == "devicetree" { print $2 }' "$entry")
    # Prefer the uncounted entry; counted variants share its content.
    case "${entry##*/}" in
      *+*) counted=${counted:-$entry} ;;
      *)
        bare=$entry
        break
        ;;
    esac
  done
  entry=${bare:-$counted}
  [ -n "$entry" ] || return 1
  echo "$entry"
}

loader_entry_exists() {
  loader_entry "$1" >/dev/null
}

loader_set_default() {
  local default="$1" tmp
  [ -f "$LOADER_CONF" ] || return 1
  tmp=$(mktemp "${LOADER_CONF}.XXXXXX") || return 1
  if ! sed '/^default[[:space:]]/d; /^preferred[[:space:]]/d; /# brainrotos boot validation/d; /# brainrotos boot recovery/d' "$LOADER_CONF" > "$tmp" ||
    ! printf '# brainrotos boot recovery\ndefault %s\n' "$default" >> "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$LOADER_CONF" || return 1
  sync "$LOADER_CONF" "$(dirname "$LOADER_CONF")" || return 1
  # EFI overrides take precedence over loader.conf, including exact defaults
  # that would keep selecting an exhausted counted candidate.
  # An install chroot sees the host's firmware, not the target's boot loader.
  if [ -e /run/booted-system ] &&
    [ -f /sys/firmware/efi/efivars/LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f ]; then
    bootctl set-default "" && bootctl set-oneshot "" || return 1
  fi
}

loader_write_alias() {
  local source="$1" destination="$2" sort_key="$3" tmp
  tmp=$(mktemp "$ENTRIES_DIR/.brainrotos-XXXXXX") || return 1
  if ! sed '/^sort-key[[:space:]]/d' "$source" > "$tmp" ||
    ! printf 'sort-key %s\n' "$sort_key" >> "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$destination" || return 1
  sync "$destination" "$ENTRIES_DIR"
}

loader_cleanup() {
  local entry
  for entry in "$ENTRIES_DIR"/brainrotos-validation-*.conf; do
    [ ! -e "$entry" ] || rm -f "$entry" || return 1
  done
  sync "$ENTRIES_DIR"
}

loader_arm() {
  local candidate fallback
  candidate=$(loader_entry "$1") || return 1
  fallback=$(loader_entry "$2") || return 1
  loader_cleanup || return 1
  loader_write_alias "$fallback" "$ENTRIES_DIR/brainrotos-validation-fallback.conf" brainrotos-validation-1 || return 1
  loader_write_alias "$candidate" "$ENTRIES_DIR/brainrotos-validation-candidate+$3.conf" brainrotos-validation-0 || return 1
  loader_set_default 'brainrotos-validation-*.conf'
}

loader_resume() {
  local entry found=false target
  target=$(grubenv_get bros_fallback_target)
  # Native reinstall recreates the normal entries, not our counted aliases.
  for entry in "$ENTRIES_DIR"/brainrotos-validation-candidate+*.conf; do
    [ ! -f "$entry" ] || found=true
  done
  if [ "$found" != true ] || ! loader_entry_exists "$target" ||
    [ ! -f "$ENTRIES_DIR/brainrotos-validation-fallback.conf" ]; then
    fail "pending systemd-boot counting entries are missing; refusing to reset the budget"
    return 1
  fi
  loader_set_default 'brainrotos-validation-*.conf'
}

loader_prepare() {
  local entry name remaining=""
  for entry in "$ENTRIES_DIR"/brainrotos-validation-candidate+*.conf; do
    [ -f "$entry" ] || continue
    name=${entry##*candidate+}
    name=${name%.conf}
    remaining=${name%%-*}
    [[ "$remaining" =~ ^[0-9]+$ ]] || return 1
    break
  done
  if [ -n "$remaining" ]; then
    grubenv_set boot_counter "$remaining"
  fi
}

loader_steer() {
  local entry id
  entry=$(loader_entry "$1") || return 1
  id=${entry##*/}
  id=${id%.conf}
  id=${id%%+*}
  # Match as a glob so boot-counting suffixes renamed into the file name by
  # systemd-boot cannot break an exact selection.
  loader_set_default "$id*.conf"
}

loader_finish() {
  loader_steer "$1" || return 1
  loader_cleanup
}

loader_disarm() {
  loader_finish "$1"
}
