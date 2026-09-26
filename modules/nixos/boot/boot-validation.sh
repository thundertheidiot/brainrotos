#!/usr/bin/env bash
# brainrotos boot validation helper - shared core
#
# The placeholders in this file are substituted by pkgs.replaceVars in
# boot/validation.nix. Bootloader-specific functions (the loader_* hooks
# below) come from a per-bootloader library, sourced right after the
# variables; only the library matching this system's bootloader is shipped.

# greenboot reads grubenv, so state is stored in a grubenv file even on systemd-boot systems

GRUBENV="${BRAINROTOS_GRUBENV:-@grubenv@}"
# consumed by the per-bootloader library sourced below
# shellcheck disable=SC2034
LOADER_CONF="${BRAINROTOS_LOADER_CONF:-@loaderConf@}"
ATTEMPTS=@attempts@
TIMEOUT=@timeout@

# greenboot swallows successful script output, so everything also goes to
# the journal directly (logger is best-effort; may be absent in tests)
log() {
  echo "brainrotos-boot-validation: $*"
  logger -t brainrotos-boot-validation "$*" 2>/dev/null || true
}

fail() {
  echo "brainrotos-boot-validation: $*" >&2
  logger -t brainrotos-boot-validation -p daemon.warning "$*" 2>/dev/null || true
}

# the per-bootloader library implements the loader_* hooks used below
# shellcheck disable=SC1091
source @loaderLib@

grubenv_get() {
  grub-editenv "$GRUBENV" list 2>/dev/null | sed -n "s/^$1=//p" | head -n 1 || true
}

grubenv_set() {
  grub-editenv "$GRUBENV" set "$1=$2"
}

grubenv_unset() {
  grub-editenv "$GRUBENV" unset "$1"
}

gen_number() {
  # the profile symlink points at the LAST BUILT generation (nixos-rebuild
  # boot moves it before reboot), not the running one - derive the booted
  # generation by matching /run/booted-system against the profile links
  local booted link
  booted=$(readlink -f /run/booted-system 2>/dev/null) || return 1
  [ -n "$booted" ] || return 1
  for link in /nix/var/nix/profiles/system-*-link; do
    [ -e "$link" ] || continue
    if [ "$(readlink -f "$link")" = "$booted" ]; then
      sed -n 's/^.*system-\([0-9]\+\)-link$/\1/p' <<< "$link"
      return 0
    fi
  done
  fail "booted system $booted is not in the system profile"
  return 1
}

prev_gen() {
  local link n best=0
  for link in /nix/var/nix/profiles/system-*-link; do
    [ -e "$link" ] || continue
    n=${link##*system-}
    n=${n%-link}
    if [ "$n" -lt "$1" ] 2>/dev/null && [ "$n" -gt "$best" ]; then
      best=$n
    fi
  done
  if [ "$best" -gt 0 ]; then
    echo "$best"
  fi
}

profile_gen() {
  # what the profile points at: the last staged generation. only used by
  # reset-cycle (bootloader-update time), where the profile has already
  # moved to the newly staged generation while the booted one is older
  local link
  link=$(readlink /nix/var/nix/profiles/system) || return 1
  sed -n 's/^.*system-\([0-9]\+\)-link$/\1/p' <<< "$link"
}

# the generation to fall back to: the last one a human validated. the
# generation below the booted one is only a guess - with two broken
# generations in a row it would bounce between them instead of reaching
# the working one. falls back to that guess when nothing has been
# validated yet, or when the validated generation no longer exists.
fallback_target_for() {
  local lastgood
  lastgood=$(grubenv_get bros_last_good_gen)
  if
    [ -n "$lastgood" ] && [ "$lastgood" != "$1" ] &&
      [ -d "/nix/var/nix/profiles/system-$lastgood-link" ]
  then
    echo "$lastgood"
    return 0
  fi
  prev_gen "$1"
}

# the state file lives in a directory that may not exist yet on a fresh
# install; make sure it does before any write
grubenv_init() {
  mkdir -p "$(dirname "$GRUBENV")"
  [ -f "$GRUBENV" ] || grub-editenv "$GRUBENV" create
}

prepare() {
  grubenv_init
  local gen armed lastgood counter target
  gen=$(gen_number) || {
    fail "cannot determine system generation"
    return 1
  }
  armed=$(grubenv_get bros_armed_gen)
  lastgood=$(grubenv_get bros_last_good_gen)
  counter=$(grubenv_get boot_counter)

  if [ "$gen" = "$lastgood" ]; then
    return 0
  fi

  if [ "$gen" != "$armed" ]; then
    # first boot (or first switch) of an unvalidated generation:
    # clear any stale cycle, then arm a fresh one
    target=$(fallback_target_for "$gen")
    if [ -z "$target" ]; then
      # without a fallback target, failure handling must never reboot:
      # greenboot would set its own counter on first failure and loop
      # forever, so neutralize it
      grubenv_unset boot_counter
      fail "no previous generation to fall back to; boot validation not armed"
      return 0
    fi
    grubenv_unset boot_counter
    grubenv_unset bros_fallback_entry
    grubenv_unset bros_fallback_target
    grubenv_unset bros_boot_entry
    grubenv_set bros_armed_gen "$gen"
    # attempts counts total boots of the broken generation (this one plus
    # retries); greenboot reboots on its own while the counter is positive
    grubenv_set boot_counter "$((ATTEMPTS - 1))"
    loader_arm "$gen" "$target"
    log "armed validation for generation $gen ($ATTEMPTS boots, fallback: generation $target)"
  elif [ -n "$counter" ] && [ "$counter" -gt 0 ] 2>/dev/null; then
    # retry boot of the armed generation
    loader_retry "$gen"
  elif [ -n "$counter" ]; then
    # counter already exhausted (e.g. reset before the failure hook
    # ran); make sure the fallback selection is in place
    loader_exhausted_ensure "$gen"
  fi
}

desktop_health() {
  # machine startup time, NOT time for a user to log in: a machine whose
  # desktop came up never times out, no matter when (or whether) someone
  # logs in. failure here is positive evidence that the generation cannot
  # bring up a desktop at all.
  local deadline=$((SECONDS + TIMEOUT))
  local last=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(systemctl is-failed display-manager.service 2>/dev/null)" = "failed" ]; then
      fail "display-manager.service failed; declaring boot failed"
      return 1
    fi
    local g dm state
    # systemctl exits non-zero for every non-active state; swallow that or
    # errexit kills the poll loop before the desktop ever comes up
    g=$(systemctl is-active graphical.target 2>/dev/null) || true
    dm=$(systemctl is-active display-manager.service 2>/dev/null) || true
    state="$g/$dm"
    if [ "$state" != "$last" ]; then
      log "waiting for desktop: graphical.target=$g display-manager=$dm"
      last="$state"
    fi
    if [ "$g" = "active" ] && [ "$dm" = "active" ]; then
      log "desktop came up; generation validated once a user logs in"
      return 0
    fi
    sleep 5
  done
  # without a previous generation there is nothing to fall back to, and
  # reporting failure would make greenboot reboot-loop the machine
  if [ -z "$(prev_gen "$(gen_number)")" ]; then
    fail "desktop did not come up within $TIMEOUT s and no previous generation exists; not marking boot failed"
    return 0
  fi
  fail "desktop did not come up within $TIMEOUT s; declaring boot failed"
  return 1
}

on_success() {
  local gen target
  gen=$(gen_number) || return 0
  # a session opening is not proof the boot is good: refuse to record
  # anything until the desktop is actually up - crash-looping display
  # managers open sessions too (autologin, greeter churn)
  if
    [ "$(systemctl is-active graphical.target 2>/dev/null)" != "active" ] ||
      [ "$(systemctl is-active display-manager.service 2>/dev/null)" != "active" ]
  then
    fail "desktop not up yet; not recording generation $gen as last good"
    return 0
  fi
  grubenv_init
  grubenv_set bros_last_good_gen "$gen"
  target=$(grubenv_get bros_fallback_target)
  if [ -n "$target" ] && [ "$target" = "$gen" ]; then
    # this is a rollback landing: keep steering to this generation across
    # reboots - greenboot's success writes (boot_success=1, counter unset)
    # would otherwise make the bootloader pick the broken newest one again
    if loader_steer "$gen"; then
      log "steering persisted to generation $gen"
    else
      fail "cannot steer bootloader to generation $gen"
    fi
  else
    loader_unsteer
  fi
  log "generation $gen recorded as last good"
}

on_fail() {
  local counter gen target
  grubenv_init
  counter=$(grubenv_get boot_counter)
  # greenboot reboots on its own while retries remain
  if [ -z "$counter" ] || [ "$counter" -gt 0 ] 2>/dev/null; then
    return 0
  fi
  gen=$(gen_number) || return 0
  target=$(grubenv_get bros_fallback_target)
  if [ -n "$target" ] && [ "$target" = "$gen" ]; then
    fail "already booting the fallback generation; manual intervention required"
    return 0
  fi
  target=$(fallback_target_for "$gen")
  if [ -z "$target" ]; then
    fail "no previous generation to fall back to; manual intervention required"
    return 0
  fi
  if ! loader_exhausted_select "$gen" "$target"; then
    fail "cannot stage the fallback; manual intervention required"
    return 0
  fi
  grubenv_set bros_fallback_target "$target"
  log "boot validation exhausted for generation $gen; rebooting into generation $target"
  if [ -n "${BRAINROTOS_BOOT_VALIDATION_DRY_RUN:-}" ]; then
    log "dry run: would reboot into generation $target"
  else
    # short delay so greenboot finishes its own grubenv bookkeeping before
    # the reboot tears everything down
    systemd-run --on-active=15 --unit=brainrotos-fallback-reboot \
      systemctl reboot
  fi
}

on_green() {
  # runs from green.d inside greenboot's success path, BEFORE it writes
  # boot_success=1 and clears the boot counter. on a rollback landing the
  # steering must be re-asserted here, otherwise the next boot would go
  # back to the broken newest generation (steering only survives via this
  # var, and greenboot just removed the counter that was steering)
  local gen target
  gen=$(gen_number) || return 0
  target=$(grubenv_get bros_fallback_target)
  if [ -n "$target" ] && [ "$target" = "$gen" ]; then
    if loader_steer "$gen"; then
      log "steering persisted to generation $gen"
    else
      fail "cannot steer bootloader to generation $gen"
    fi
  fi
}

rollback() {
  # manually steer the next boot to a generation. stages only; the caller
  # reboots when ready.
  local gen target
  gen=$(gen_number) || {
    fail "cannot determine system generation"
    return 1
  }
  # called from the dispatcher as `rollback "$2"` - the target arrives as
  # this function's first positional
  target="${1:-}"
  if [ -z "$target" ]; then
    target=$(fallback_target_for "$gen")
  fi
  if [ -z "$target" ]; then
    fail "no previous generation to roll back to"
    return 1
  fi
  if [ ! -d "/nix/var/nix/profiles/system-$target-link" ]; then
    fail "generation $target does not exist"
    return 1
  fi
  if [ "$target" = "$gen" ]; then
    fail "generation $target is the running generation"
    return 1
  fi
  grubenv_init
  if ! loader_steer "$target"; then
    return 1
  fi
  grubenv_set bros_fallback_target "$target"
  log "steered boot to generation $target - reboot to apply"
}

reset_cycle() {
  # clear validation state when a different generation is staged/activated
  # (nixos-rebuild switch/boot of a new gen): steering and counters from
  # the old cycle must not survive. guarded by mountpoint in the caller -
  # at boot time /boot may not be mounted yet and the prepare unit takes
  # over.
  local gen armed
  gen=$(profile_gen) || return 0
  armed=$(grubenv_get bros_armed_gen)
  if [ "$gen" != "$armed" ]; then
    grubenv_unset boot_counter
    grubenv_unset bros_armed_gen
    grubenv_unset bros_fallback_entry
    grubenv_unset bros_fallback_target
    grubenv_unset bros_boot_entry
    log "validation cycle reset for staged generation $gen"
  fi
}

case "${1:-}" in
  prepare) prepare ;;
  desktop-health) desktop_health ;;
  on-success) on_success ;;
  on-green) on_green ;;
  on-fail) on_fail ;;
  rollback) rollback "${2:-}" ;;
  reset-cycle) reset_cycle ;;
  gen-number) gen_number ;;
  *)
    fail "usage: brainrotos-boot-validation {prepare|desktop-health|on-success|on-green|on-fail|rollback [gen]|reset-cycle|gen-number}"
    exit 2
    ;;
esac
