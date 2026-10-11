#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# Color setup. Enable when stdout is a tty, or FORCE_COLOR is set. NO_COLOR wins.
USE_COLOR=0
[[ -t 1 ]] && USE_COLOR=1
[[ -n "${FORCE_COLOR:-}" ]] && USE_COLOR=1
[[ -n "${NO_COLOR:-}" ]] && USE_COLOR=0

C_RESET="" C_DIM="" C_ROOT="" C_TREE="" C_DIR="" C_GREEN="" C_YELLOW="" C_RED="" C_MAGENTA=""
if [[ "$USE_COLOR" -eq 1 ]]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[90m'      # bright black (labels)
  C_ROOT=$'\033[1;34m'   # bold blue (".")
  C_TREE=$'\033[1;90m'   # bright black (glyphs + following space)
  C_DIR=$'\033[34m'      # blue (directories)
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_MAGENTA=$'\033[35m'
fi

# Namespace where update preserves history that the remote deleted or rewrote.
BACKUP_REFSPEC='^refs/mirror-backup/*'

usage() {
  cat >&2 <<EOF
usage: $0 <command> [args]

commands:
  clone <git-url> [<git-url> ...]   mirror clone repo(s) into <owner>/<repo>.git
  list                              list mirrors (eza -T style)
  update                            fetch --prune for every mirror, with details
                                    (deleted/rewritten refs are preserved under
                                     refs/mirror-backup/<utc-timestamp>/...)
EOF
}

# Extract OWNER/REPO from a github remote URL
# Supports git@github.com:OWNER/REPO.git, https://github.com/OWNER/REPO.git, etc.
parse_slug() {
  local url="$1"
  url="${url%.git}"
  url="${url#git@github.com:}"
  url="${url#https://github.com/}"
  url="${url#http://github.com/}"
  url="${url#ssh://git@github.com/}"
  printf '%s' "$url"
}

# Make sure refs/mirror-backup/* is excluded from the mirror refspec so that
# `remote update --prune` never deletes our backup refs.
ensure_backup_refspec() {
  local dir="$1"
  if ! git -C "$dir" config --get-all remote.origin.fetch 2>/dev/null | grep -qxF "$BACKUP_REFSPEC"; then
    git -C "$dir" config --add remote.origin.fetch "$BACKUP_REFSPEC"
  fi
}

mirror_info() {
  local dir="$1"
  local remote head_branch head_sha head n_branches n_tags size
  remote="$(git -C "$dir" remote get-url origin 2>/dev/null || echo '-')"
  head_branch="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  head_sha="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || true)"
  if [[ -n "$head_branch" && -n "$head_sha" ]]; then
    head="${head_branch} @ ${head_sha}"
  else
    head="-"
  fi
  n_branches="$(git -C "$dir" for-each-ref --format=x refs/heads | wc -l | tr -d ' ')"
  n_tags="$(git -C "$dir" for-each-ref --format=x refs/tags | wc -l | tr -d ' ')"
  size="$(du -sh "$dir" 2>/dev/null | awk '{print $1}')"

  echo "  ${C_DIM}remote${C_RESET}   $remote"
  echo "  ${C_DIM}head${C_RESET}     $head"
  echo "  ${C_DIM}refs${C_RESET}     ${n_branches} branches, ${n_tags} tags"
  echo "  ${C_DIM}size${C_RESET}     $size"
}

cmd_clone() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  local failed=0
  while [[ $# -gt 0 ]]; do
    local url="$1"
    shift

    local slug target
    slug="$(parse_slug "$url")"
    target="$ROOT_DIR/${slug}.git"

    if [[ -e "$target" ]]; then
      echo "${C_TREE}[skip]${C_RESET}  ${C_DIR}${slug}.git${C_RESET} ${C_DIM}(already exists)${C_RESET}"
      continue
    fi

    echo "${C_TREE}[clone]${C_RESET} ${C_DIR}${slug}.git${C_RESET}"
    mkdir -p "$(dirname "$target")"

    local log rc
    log="$(mktemp)"
    git clone --mirror "$url" "$target" >"$log" 2>&1 && rc=0 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "  ${C_RED}failed${C_RESET}" >&2
      sed 's/^/    /' "$log" >&2
      rm -f "$log"
      rm -rf "$target"
      failed=$((failed + 1))
      continue
    fi

    rm -f "$log"
    ensure_backup_refspec "$target"
    mirror_info "$target"
  done

  if [[ "$failed" -gt 0 ]]; then
    exit 1
  fi
}

cmd_list() {
  local repos=() dir
  for dir in */*.git; do
    [[ -d "$dir" ]] || continue
    repos+=("$dir")
  done

  local count=${#repos[@]}
  if [[ "$count" -eq 0 ]]; then
    echo "no mirrors found"
    return 0
  fi

  local maxw=0
  for dir in "${repos[@]}"; do
    (( ${#dir} > maxw )) && maxw=${#dir}
  done

  printf '%s%-*s  %-18s  %-20s  %-9s  %s%s\n' \
    "$C_DIM" "$maxw" "MIRROR" "HEAD" "REFS" "UPDATED" "SIZE" "$C_RESET"

  local now head_branch head_sha head n_branches n_tags refs mtime d rel size
  now="$(date +%s)"
  for dir in "${repos[@]}"; do
    head_branch="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || true)"
    head_sha="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || true)"
    if [[ -n "$head_branch" && -n "$head_sha" ]]; then
      head="${head_branch}@${head_sha}"
    else
      head="-"
    fi

    n_branches="$(git -C "$dir" for-each-ref --format=x refs/heads | wc -l | tr -d ' ')"
    n_tags="$(git -C "$dir" for-each-ref --format=x refs/tags | wc -l | tr -d ' ')"
    refs="${n_branches} branches, ${n_tags} tags"

    mtime="$(stat -f %m "$dir/FETCH_HEAD" 2>/dev/null || stat -f %m "$dir" 2>/dev/null || echo 0)"
    d=$((now - mtime))
    if [[ "$mtime" -eq 0 ]]; then
      rel="-"
    elif [[ "$d" -lt 60 ]]; then
      rel="${d}s ago"
    elif [[ "$d" -lt 3600 ]]; then
      rel="$((d / 60))m ago"
    elif [[ "$d" -lt 86400 ]]; then
      rel="$((d / 3600))h ago"
    else
      rel="$((d / 86400))d ago"
    fi

    size="$(du -sh "$dir" 2>/dev/null | awk '{print $1}')"

    printf '%s%-*s%s  %-18s  %-20s  %s%-9s  %s%s\n' \
      "$C_DIR" "$maxw" "$dir" "$C_RESET" "$head" "$refs" "$C_DIM" "$rel" "$size" "$C_RESET"
  done
}

update_one() {
  local name="$1" dir="$2"
  local before after

  ensure_backup_refspec "$dir"

  before="$(mktemp)"
  after="$(mktemp)"

  git -C "$dir" show-ref > "$before" 2>/dev/null || true

  local out rc
  out="$(git -C "$dir" remote update --prune 2>&1)" && rc=0 || rc=$?

  git -C "$dir" show-ref > "$after" 2>/dev/null || true

  echo "${C_TREE}[update]${C_RESET} ${C_DIR}${name}${C_RESET}"

  if [[ "$rc" -ne 0 ]]; then
    echo "  ${C_RED}failed${C_RESET}"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    rm -f "$before" "$after"
    return 1
  fi

  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"

  local changes="" updated=0 added=0 deleted=0
  local backups="" n_backups=0
  local sha ref old bref

  # refs that moved or were added
  while read -r sha ref; do
    [[ -n "$ref" ]] || continue
    old="$(awk -v r="$ref" '$2==r{print $1}' "$before")"
    if [[ -z "$old" ]]; then
      added=$((added + 1))
      changes+="  ${C_GREEN}+ ${ref}  ${sha}${C_RESET}"$'\n'
    elif [[ "$old" != "$sha" ]]; then
      updated=$((updated + 1))
      changes+="  ${C_YELLOW}~ ${ref}  ${old:0:7}..${sha:0:7}${C_RESET}"$'\n'
      # non-fast-forward (history rewritten) -> preserve the old tip
      if ! git -C "$dir" merge-base --is-ancestor "$old" "$sha" 2>/dev/null; then
        bref="refs/mirror-backup/${ts}/${ref#refs/}"
        git -C "$dir" update-ref "$bref" "$old"
        n_backups=$((n_backups + 1))
        backups+="  ${C_MAGENTA}${ref}  ${old:0:7} -> ${bref}${C_RESET}"$'\n'
      fi
    fi
  done < "$after"

  # refs that were deleted on the remote
  while read -r sha ref; do
    [[ -n "$ref" ]] || continue
    if ! awk -v r="$ref" '$2==r{found=1} END{exit !found}' "$after"; then
      deleted=$((deleted + 1))
      changes+="  ${C_RED}- ${ref}${C_RESET}"$'\n'
      bref="refs/mirror-backup/${ts}/${ref#refs/}"
      git -C "$dir" update-ref "$bref" "$sha"
      n_backups=$((n_backups + 1))
      backups+="  ${C_MAGENTA}${ref}  ${sha:0:7} -> ${bref}${C_RESET}"$'\n'
    fi
  done < "$before"

  mirror_info "$dir"

  if [[ "$updated" -eq 0 && "$added" -eq 0 && "$deleted" -eq 0 ]]; then
    echo "  ${C_GREEN}up to date${C_RESET}"
  else
    echo "  ${C_DIM}changes${C_RESET}  ${updated} updated, ${added} added, ${deleted} deleted"
    printf '%s' "$changes"
  fi

  if [[ "$n_backups" -gt 0 ]]; then
    echo "  ${C_MAGENTA}backup${C_RESET}   ${n_backups} ref(s) preserved"
    printf '%s' "$backups"
  fi

  rm -f "$before" "$after"
}

cmd_update() {
  local failed=0 total=0 dir name
  # Layout: <owner>/<repo>.git/
  for dir in */*.git/; do
    [[ -d "$dir" ]] || continue
    name="${dir%/}"
    total=$((total + 1))

    if ! update_one "$name" "$dir"; then
      failed=$((failed + 1))
    fi
  done

  if [[ "$failed" -gt 0 ]]; then
    echo "${C_RED}${failed}/${total} mirror(s) failed${C_RESET}" >&2
    exit 1
  fi
  echo "${C_DIM}${total} mirror(s) updated${C_RESET}"
}

[[ $# -eq 0 ]] && { usage; exit 1; }

command="$1"
shift

case "$command" in
  clone)  cmd_clone "$@" ;;
  list)   cmd_list ;;
  update) cmd_update ;;
  -h|--help|help) usage ;;
  *) echo "unknown command: $command" >&2; usage; exit 1 ;;
esac
