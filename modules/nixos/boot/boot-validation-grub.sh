# shellcheck shell=bash
# brainrotos boot validation - grub loader hooks
#
# Sourced by the shared core (boot-validation.sh). Functions and variables
# that look unassigned here (grubenv_*, generation_system, fail, GRUB_CONFIG, ...)
# are defined there.

grub_fallback_entry() {
  local system init
  system=$(generation_system "$1") || return 1
  [ -n "$system" ] && [ -r "$GRUB_CONFIG" ] || return 1
  [ -e "$system/kernel" ] && [ -e "$system/initrd" ] || return 1
  init=$(readlink -e "$system/init") || return 1

  # Track generated menu scopes, not reconstructed date/version titles.
  # Leading closing braces must pop scopes before parsing the next entry.
  awk -v init="init=$init" \
    -v all="$DISTRO_NAME - All configurations" \
    -v generation="$DISTRO_NAME - Configuration ${1%%/*}" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      while (line ~ /^}/) {
        delete title[depth]
        delete kind[depth]
        if (depth > 0) depth--
        sub(/^}[[:space:]]*/, "", line)
      }
      if (match(line, /^(submenu|menuentry)[[:space:]]+(["\047])/, header)) {
        rest = substr(line, RLENGTH + 1)
        end = index(rest, header[2])
        if (!end) next
        depth++
        kind[depth] = header[1]
        title[depth] = substr(rest, 1, end - 1)
      } else if (line ~ /{[[:space:]]*$/) {
        # Non-menu brace scopes (e.g. functions) must not pop a submenu.
        depth++
      }

      suffix = substr(title[2], length(generation) + 1)
      if (depth >= 2 && kind[depth] == "menuentry" &&
          kind[1] == "submenu" && title[1] == all &&
          index(title[2], generation) == 1 &&
          (suffix == "" || suffix ~ /^[[:space:]]/) &&
          line ~ /^(linux|linuxefi|module)[[:space:]]/) {
        for (i = 1; i <= NF; i++) {
          if ($i != init) continue
          path = title[1]
          for (j = 2; j <= depth; j++) path = path ">" title[j]
          print path
          found = 1
          exit
        }
      }
    }
    END { if (!found) exit 1 }
  ' "$GRUB_CONFIG"
}

loader_entry_exists() {
  grub_fallback_entry "$1" >/dev/null
}

loader_arm() {
  local candidate fallback
  candidate=$(grub_fallback_entry "$1") || {
    fail "cannot resolve installed grub entry for generation $1"
    return 1
  }
  fallback=$(grub_fallback_entry "$2") || {
    fail "cannot resolve installed grub fallback entry for generation $2"
    return 1
  }
  # Resolve both before writing; the core owns counters and cycle markers.
  grubenv_set bros_candidate_entry "$candidate" || return 1
  grubenv_set bros_fallback_entry "$fallback" || return 1
  grubenv_unset bros_boot_entry
}

loader_resume() {
  local target
  target=$(grubenv_get bros_fallback_target) || return 1
  loader_arm "$1" "$target" || return 1
  grubenv_unset bros_boot_entry
}

loader_prepare() {
  # GRUB already decremented the counter before entering userspace.
  :
}

loader_steer() {
  local title
  title=$(grub_fallback_entry "$1") || {
    fail "cannot resolve installed grub entry for generation $1"
    return 1
  }
  grubenv_set bros_boot_entry "$title"
}

loader_finish() {
  loader_steer "$1"
}

loader_disarm() {
  loader_steer "$1" || return 1
  loader_cleanup
}

loader_cleanup() {
  grubenv_unset bros_candidate_entry bros_fallback_entry
}
