#!/usr/bin/env bash
# Shared lifecycle; loader hooks own menu selection and bootloader counting.

GRUBENV="${BRAINROTOS_GRUBENV:-@grubenv@}"
LEGACY_GRUBENV="${BRAINROTOS_LEGACY_GRUBENV:-@legacyGrubenv@}"
STATE_DIR="${BRAINROTOS_STATE_DIR:-/run/brainrotos-boot-validation}"
HEALTH_ENV="$STATE_DIR/greenboot.grubenv"
PROFILES_DIR="${BRAINROTOS_PROFILES_DIR:-/nix/var/nix/profiles}"
BOOTED_SYSTEM="${BRAINROTOS_BOOTED_SYSTEM:-/run/booted-system}"
GCROOT="${BRAINROTOS_GCROOT:-/nix/var/nix/gcroots/brainrotos-last-good}"
# shellcheck disable=SC2034
LOADER_CONF="${BRAINROTOS_LOADER_CONF:-@loaderConf@}"
# shellcheck disable=SC2034
ENTRIES_DIR="${BRAINROTOS_ENTRIES_DIR:-@entriesDir@}"
# shellcheck disable=SC2034
GRUB_CONFIG="${BRAINROTOS_GRUB_CONFIG:-/boot/grub/grub.cfg}"
# shellcheck disable=SC2034
DISTRO_NAME=@distroName@
ATTEMPTS=@attempts@
TIMEOUT=@timeout@

log() {
  echo "brainrotos-boot-validation: $*"
  logger -t brainrotos-boot-validation "$*" 2>/dev/null || true
}

fail() {
  echo "brainrotos-boot-validation: $*" >&2
  logger -t brainrotos-boot-validation -p daemon.warning "$*" 2>/dev/null || true
}

# shellcheck disable=SC1091
source @loaderLib@

grubenv_get() {
  grub-editenv "$GRUBENV" list | sed -n "s/^$1=//p"
}

grubenv_set() {
  grub-editenv "$GRUBENV" set "$1=$2"
}

grubenv_unset() {
  grub-editenv "$GRUBENV" unset "$@"
}

grubenv_init() {
  local lastgood
  mkdir -p "$(dirname "$GRUBENV")"
  if [ ! -f "$GRUBENV" ]; then
    grub-editenv "$GRUBENV" create
    if [ -f "$LEGACY_GRUBENV" ]; then
      # Keep the previous validated identity, not its userspace-only budget.
      lastgood=$(grub-editenv "$LEGACY_GRUBENV" list | sed -n 's/^bros_last_good_gen=//p')
      [ -z "$lastgood" ] || grubenv_set bros_last_good_gen "$lastgood"
    fi
  fi
}

# A reference is a generation number, optionally followed by /specialisation.
generation_system() {
  local gen="${1%%/*}" specialisation=""
  [[ "$gen" =~ ^[1-9][0-9]*$ ]] || return 1
  if [[ "$1" = */* ]]; then
    specialisation="${1#*/}"
    case "$specialisation" in "" | . | .. | */*) return 1 ;; esac
    printf '%s/system-%s-link/specialisation/%s\n' "$PROFILES_DIR" "$gen" "$specialisation"
  else
    printf '%s/system-%s-link\n' "$PROFILES_DIR" "$gen"
  fi
}

profile_gen() {
  local link
  link=$(readlink "$PROFILES_DIR/system") || return 1
  [[ "$link" =~ system-([0-9]+)-link$ ]] || return 1
  echo "${BASH_REMATCH[1]}"
}

generation_for_system() {
  local system link gen specialisation preferred
  system=$(readlink -e "$1") || return 1
  preferred=$(profile_gen) || preferred=""
  # Prefer the active profile when closures are shared by multiple generations.
  for link in "$PROFILES_DIR/system-$preferred-link" "$PROFILES_DIR"/system-*-link; do
    [ -d "$link" ] || continue
    gen=${link##*/system-}
    gen=${gen%-link}
    [[ "$gen" =~ ^[1-9][0-9]*$ ]] || continue
    if [ "$(readlink -e "$link")" = "$system" ]; then
      echo "$gen"
      return 0
    fi
    for specialisation in "$link"/specialisation/*; do
      [ -d "$specialisation" ] || continue
      if [ "$(readlink -e "$specialisation")" = "$system" ]; then
        printf '%s/%s\n' "$gen" "${specialisation##*/}"
        return 0
      fi
    done
  done
  fail "system $system is not in the system profile"
  return 1
}

gen_number() {
  generation_for_system "$BOOTED_SYSTEM"
}

fallback_target_for() {
  local lastgood link gen best=0
  lastgood=$(grubenv_get bros_last_good_gen)
  if [ -n "$lastgood" ] && [ "$lastgood" != "$1" ] && loader_entry_exists "$lastgood"; then
    echo "$lastgood"
    return 0
  fi
  if [ -n "$lastgood" ] && [ "$lastgood" != "$1" ]; then
    fail "last-good generation $lastgood has no installed boot entry"
  fi
  for link in "$PROFILES_DIR"/system-*-link; do
    [ -d "$link" ] || continue
    gen=${link##*/system-}
    gen=${gen%-link}
    [[ "$gen" =~ ^[1-9][0-9]*$ ]] || continue
    if [ "$gen" -lt "${1%%/*}" ] && [ "$gen" -gt "$best" ] && loader_entry_exists "$gen"; then
      best=$gen
    fi
  done
  [ "$best" -eq 0 ] || echo "$best"
}

arm_cycle() {
  local gen="$1" remaining="$2" target
  target=$(fallback_target_for "$gen")
  if [ -n "$target" ]; then
    loader_arm "$gen" "$target" "$remaining" || return 1
  else
    loader_disarm "$gen" || return 1
    remaining=0
    fail "no installed fallback for generation $gen; automatic reboots disabled"
  fi
  grubenv_set bros_armed_gen "$gen" || return 1
  grubenv_set bros_fallback_target "$target" || return 1
  grubenv_unset bros_manual_target || return 1
  grubenv_set boot_success 0 || return 1
  grubenv_set boot_counter "$remaining" || return 1
  log "armed generation $gen ($remaining attempts remaining, fallback: ${target:-none})"
}

stage() {
  # Runs AFTER the native installer, while the old system is still running.
  local gen armed counter target
  gen=$(generation_for_system "${1:-$PROFILES_DIR/system}") || return 1
  loader_entry_exists "$gen" || {
    fail "generation $gen has no installed boot entry"
    return 1
  }
  if [ "$LEGACY_GRUBENV" != "$GRUBENV" ] && [ -f "$LEGACY_GRUBENV" ]; then
    # A boot-mode rebuild leaves old PAM/Greenboot hooks running until reboot.
    # Remove their landing marker so they cannot explicitly steer loader.conf;
    # their remaining writes go to a separate, no-longer-authoritative file.
    grub-editenv "$LEGACY_GRUBENV" unset bros_fallback_target bros_fallback_entry bros_boot_entry boot_counter
  fi
  armed=$(grubenv_get bros_armed_gen)
  counter=$(grubenv_get boot_counter)
  target=$(grubenv_get bros_fallback_target)
  if [ "$gen" = "$armed" ] && [ -n "$counter" ] && [ -n "$target" ] && loader_entry_exists "$target"; then
    # Reinstalling a pending generation must not replenish its boot budget.
    loader_resume "$gen" || return 1
    grubenv_unset bros_manual_target || return 1
  else
    arm_cycle "$gen" "$ATTEMPTS" || return 1
  fi
}

prepare() {
  local gen armed counter target manual
  gen=$(gen_number) || return 1
  armed=$(grubenv_get bros_armed_gen)
  target=$(grubenv_get bros_fallback_target)
  manual=$(grubenv_get bros_manual_target)
  # Snapshot Greenboot's budget for THIS boot. Its status writes must not
  # modify a newer cycle staged while this system is running.
  grub-editenv "$HEALTH_ENV" create
  if [ "$gen" = "$target" ] || [ "$gen" = "$manual" ]; then
    loader_steer "$gen" || return 1
    counter=0
    log "landed on fallback generation $gen; selection persisted"
  elif [ -n "$manual" ] || { [ -n "$armed" ] && [ "$armed" != "$gen" ]; }; then
    counter=0
  else
    counter=$(grubenv_get boot_counter)
    if [ -z "$counter" ] || [ -z "$armed" ]; then
      # A healthy previous boot cleared the cycle; this boot has already
      # consumed its first attempt, including when upgrading from old state.
      arm_cycle "$gen" "$((ATTEMPTS - 1))" || return 1
    fi
    loader_prepare "$gen" || return 1
    counter=$(grubenv_get boot_counter)
    [ -n "$counter" ] || counter=0
  fi
  grub-editenv "$HEALTH_ENV" set "boot_counter=$counter" boot_success=0
  grubenv_get bros_armed_gen > "$STATE_DIR/boot-cycle"
}

desktop_health() {
  local deadline=$((SECONDS + TIMEOUT)) last="" g dm state
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(systemctl is-failed display-manager.service 2>/dev/null)" = "failed" ]; then
      fail "display-manager.service failed; declaring boot failed"
      return 1
    fi
    g=$(systemctl is-active graphical.target 2>/dev/null) || true
    dm=$(systemctl is-active display-manager.service 2>/dev/null) || true
    state="$g/$dm"
    if [ "$state" != "$last" ]; then
      log "waiting for desktop: graphical.target=$g display-manager=$dm"
      last="$state"
    fi
    if [ "$g" = "active" ] && [ "$dm" = "active" ]; then
      return 0
    fi
    sleep 5
  done
  fail "desktop did not come up within $TIMEOUT s"
  return 1
}

event_dir() {
  local boot_id
  boot_id=$(cat /proc/sys/kernel/random/boot_id)
  mkdir -p "$STATE_DIR/events/$boot_id"
  echo "$STATE_DIR/events/$boot_id"
}

record_last_good() {
  local gen="$1" events system
  events=$(event_dir)
  system=$(readlink -e "$BOOTED_SYSTEM") || return 1
  [ -f "$events/login" ] && [ -f "$events/healthy" ] || return 0
  [ "$(cat "$events/login")" = "$system" ] && [ "$(cat "$events/healthy")" = "$system" ] || return 0
  mkdir -p "$(dirname "$GCROOT")"
  ln -sfn "$system" "$GCROOT"
  grubenv_set bros_last_good_gen "$gen"
  log "generation $gen passed all checks and received a user login; recorded as last good"
}

on_success() {
  local gen events system
  gen=$(gen_number) || return 0
  events=$(event_dir)
  system=$(readlink -e "$BOOTED_SYSTEM") || return 0
  echo "$system" > "$events/login"
  # Remember early logins too (e.g. autologin before graphical.target). The
  # required health checks are the other half, and own desktop validation.
  record_last_good "$gen"
}

on_green() {
  local gen target armed manual events system boot_cycle
  gen=$(gen_number) || return 0
  target=$(grubenv_get bros_fallback_target)
  armed=$(grubenv_get bros_armed_gen)
  manual=$(grubenv_get bros_manual_target)
  boot_cycle=$(cat "$STATE_DIR/boot-cycle" 2>/dev/null) || boot_cycle=""
  if [ "$armed" != "$boot_cycle" ]; then
    # The current system may be the fallback of a NEW trial. That is not
    # evidence it landed there: never cancel a cycle staged after prepare.
    log "generation $armed was staged during this boot; preserving its selection"
  elif [ "$gen" = "$target" ] || [ "$gen" = "$manual" ]; then
    loader_steer "$gen" || return 1
  elif [ "$gen" = "$armed" ] && [ -z "$manual" ]; then
    # Healthy unattended boots must stop counting too, without becoming a
    # human-validated fallback or overwriting a newer staged generation.
    loader_finish "$gen" || return 1
    grubenv_set boot_success 1
    grubenv_unset boot_counter
  fi
  events=$(event_dir)
  system=$(readlink -e "$BOOTED_SYSTEM") || return 1
  echo "$system" > "$events/healthy"
  record_last_good "$gen"
}

on_fail() {
  local gen armed target manual counter events
  gen=$(gen_number) || return 0
  events=$(event_dir)
  rm -f "$events/healthy"
  armed=$(grubenv_get bros_armed_gen)
  target=$(grubenv_get bros_fallback_target)
  manual=$(grubenv_get bros_manual_target)
  if [ "$gen" != "$armed" ] || [ "$gen" = "$target" ] || [ -n "$manual" ] ||
    [ -z "$target" ] || ! loader_entry_exists "$target"; then
    grub-editenv "$HEALTH_ENV" set boot_counter=0
    fail "no safe automatic retry for generation $gen; manual intervention required"
    return 0
  fi
  counter=$(grub-editenv "$HEALTH_ENV" list | sed -n 's/^boot_counter=//p')
  if [ -n "$counter" ] && [ "$counter" -gt 0 ]; then
    return 0 # Greenboot requests retries using its per-boot environment.
  fi
  loader_steer "$target" || {
    grub-editenv "$HEALTH_ENV" set boot_counter=0
    fail "cannot select fallback generation $target; manual intervention required"
    return 0
  }
  log "validation exhausted for generation $gen; rebooting into generation $target"
  if [ -z "${BRAINROTOS_BOOT_VALIDATION_DRY_RUN:-}" ]; then
    systemd-run --on-active=15 --unit=brainrotos-fallback-reboot systemctl reboot
  fi
}

rollback() {
  local gen target
  gen=$(gen_number) || return 1
  target="${1:-}"
  [ -n "$target" ] || target=$(fallback_target_for "$gen")
  if [ -z "$target" ] || [ "$target" = "$gen" ] || ! loader_entry_exists "$target"; then
    fail "rollback target must be a different, installed generation (N or N/specialisation)"
    return 1
  fi
  loader_steer "$target" || return 1
  grubenv_set bros_manual_target "$target"
  grubenv_set bros_fallback_target "$target"
  log "steered next boot to generation $target; reboot to apply"
}

case "${1:-}" in
  desktop-health) desktop_health ;;
  gen-number) gen_number ;;
  prepare | on-success | on-green | on-fail | rollback | stage)
    umask 077
    mkdir -p "$STATE_DIR"
    exec 9> "$STATE_DIR/lock"
    flock 9
    grubenv_init
    case "$1" in
      prepare) prepare ;;
      on-success) on_success ;;
      on-green) on_green ;;
      on-fail) on_fail ;;
      rollback) rollback "${2:-}" ;;
      stage) stage "${2:-}" ;;
    esac
    sync "$GRUBENV" "$(dirname "$GRUBENV")"
    ;;
  *)
    fail "usage: brainrotos-boot-validation {prepare|desktop-health|on-success|on-green|on-fail|rollback [N[/specialisation]]|stage [system]|gen-number}"
    exit 2
    ;;
esac
