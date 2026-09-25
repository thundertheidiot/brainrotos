# shellcheck shell=bash
# brainrotos boot validation - systemd-boot loader hooks
#
# Sourced by the shared core (boot-validation.sh). Functions and variables
# that look unassigned here (grubenv_*, prev_gen, log/fail, GRUBENV,
# LOADER_CONF, ...) are defined there.

loader_set_default() {
  local entries_dir entry="" f
  if [ ! -f "$LOADER_CONF" ]; then
    return 1
  fi
  entries_dir="$(dirname "$LOADER_CONF")/entries"
  for f in "$entries_dir"/nixos-generation-"$1"*.conf; do
    [ -e "$f" ] || continue
    case "$f" in *specialisation*) continue ;; esac
    entry=$f
    break
  done
  [ -n "$entry" ] || return 1
  # replace any default line (nixos writes one on every rebuild)
  sed -i '/# brainrotos boot validation/d; /^default /d' "$LOADER_CONF"
  printf '# brainrotos boot validation\ndefault %s\n' "$(basename "$entry")" >> "$LOADER_CONF"
}

loader_clear_default() {
  if [ -f "$LOADER_CONF" ]; then
    sed -i '/# brainrotos boot validation/,+1d' "$LOADER_CONF"
  fi
}

loader_arm() {
  # the loader fallback is staged when the counter hits zero
  :
}

loader_retry() {
  # grub decrements the counter inside the bootloader; systemd-boot needs
  # a hand. when the counter hits zero the fallback is staged for the
  # next boot
  local gen="$1" counter target
  counter=$(grubenv_get boot_counter)
  counter=$((counter - 1))
  grubenv_set boot_counter "$counter"
  if [ "$counter" -eq 0 ]; then
    target=$(fallback_target_for "$gen")
    if [ -n "$target" ] && loader_set_default "$target"; then
      grubenv_set bros_fallback_target "$target"
      log "attempts exhausted; systemd-boot will fall back to generation $target"
    else
      fail "attempts exhausted but cannot select a fallback entry"
    fi
  fi
}

loader_exhausted_ensure() {
  # counter already exhausted (e.g. reset before the failure hook ran);
  # make sure the fallback selection is in place
  local gen="$1" prev
  if prev=$(prev_gen "$gen"); then
    loader_set_default "$prev" || true
  fi
}

loader_steer() {
  loader_set_default "$1" || {
    fail "cannot steer systemd-boot to generation $1"
    return 1
  }
}

loader_unsteer() {
  loader_clear_default
}

loader_exhausted_select() {
  local prev="$2"
  loader_set_default "$prev" || {
    fail "cannot write systemd-boot fallback; manual intervention required"
    return 1
  }
}
