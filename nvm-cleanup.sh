#!/usr/bin/env bash
set -euo pipefail

# --- Self-update config ---
UPDATE_URL="https://raw.githubusercontent.com/Zwiqler94/Useful-Scripts/refs/heads/main/nvm-cleanup.sh"

if [[ "${1:-}" == "--update-self" ]]; then
  echo "Updating $0 from $UPDATE_URL ..."
  if curl -fsSL "$UPDATE_URL" -o "$0"; then
    chmod +x "$0"
    echo "Update complete."
  else
    echo "Update failed."
  fi
  exit 0
fi

# --- Shell-agnostic prompt ---
prompt_confirm() {
  local prompt="$1" ; local __var=$2
  if [ -n "${ZSH_VERSION-}" ]; then
    read "$__var?$prompt"
  else
    read -p "$prompt" "$__var"
  fi
}

# --- Load nvm ---
if [[ -z "${NVM_DIR:-}" ]]; then export NVM_DIR="$HOME/.nvm"; fi
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  source "$NVM_DIR/nvm.sh"
elif command -v brew >/dev/null 2>&1 && [[ -s "$(brew --prefix)/opt/nvm/nvm.sh" ]]; then
  source "$(brew --prefix)/opt/nvm/nvm.sh"
else
  echo "Could not find nvm. Set NVM_DIR or install nvm." >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage: nvm-clean.sh [--dry-run] [--yes] [--keep vX.Y.Z]... [--review-globals] [--update-self]

Removes Node versions managed by nvm, except your current version.

Options:
  --dry-run         Show what would happen. No uninstalls.
  --yes             Do not prompt. Uninstall all candidates.
  --keep vX.Y.Z     Keep a specific version. Repeat as needed.
  --review-globals  After uninstalls, review remaining versions' global npm packages
                    and optionally remove them package-by-package.
  --update-self     Replace this script with the latest version from GitHub.
EOF
}

# --- Args ---
DRY_RUN=false
ASSUME_YES=false
REVIEW_GLOBALS=false
KEEPS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --keep) [[ $# -ge 2 ]] || { echo "--keep needs a version"; exit 2; }
            KEEPS+=("${2#v}"); shift 2 ;;
    --review-globals) REVIEW_GLOBALS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

# --- Helpers for npm globals ---
list_globals_json() {
  npm -g ls --depth=0 --json 2>/dev/null || echo '{}'
}

review_globals_for_version() {
  local v="$1"
  echo "----- Global npm review for v$v -----"
  nvm use "$v" >/dev/null
  local json; json="$(list_globals_json)"
  local pkgs
  pkgs=$(printf '%s' "$json" | python3 - <<'PY'
import sys, json
data=json.load(sys.stdin)
deps=(data.get("dependencies") or {})
names=[k for k in deps.keys() if k!="npm"]
print("\n".join(names))
PY
)
  if [[ -z "${pkgs//[$'\t\r\n ']/}" ]]; then
    echo "No global packages (besides npm)."
    return
  fi
  echo "Found:"
  printf '  - %s\n' $pkgs
  for p in $pkgs; do
    local ans=""
    prompt_confirm "Remove global package '$p' from v$v? [y/N] " ans
    if [[ "$ans" == [Yy] ]]; then
      npm -g rm "$p" || echo "Failed to remove $p (continuing)."
    else
      echo "Keeping $p"
    fi
  done
}

# --- Current version ---
CURRENT="$(node -v 2>/dev/null | tr -d 'v' || true)"

# --- Installed versions ---
VERSIONS=()
while IFS= read -r line; do
  VERSIONS+=("$line")
done < <(
  nvm ls --no-colors \
    | sed -nE 's/^[[:space:]]*v([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' \
    | sort -u
)

# --- Filter uninstall candidates ---
CANDIDATES=()
for v in "${VERSIONS[@]}"; do
  keep=false
  [[ -n "$CURRENT" && "$v" == "$CURRENT" ]] && keep=true
  for k in "${KEEPS[@]}"; do
    [[ "$v" == "${k#v}" ]] && keep=true
  done
  $keep || CANDIDATES+=("$v")
done

echo "Installed via nvm: ${VERSIONS[*]:-none}"
[[ -n "$CURRENT" ]] && echo "Current in use: v$CURRENT"
[[ ${#KEEPS[@]} -gt 0 ]] && echo "Explicitly keeping: ${KEEPS[*]}"

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "Nothing to uninstall."
else
  echo "Will target for uninstall: ${CANDIDATES[*]}"
fi

if $DRY_RUN; then
  echo "[dry-run] No changes made."
  exit 0
fi

# --- Uninstall loop ---
REMAINING=("${VERSIONS[@]}")
for v in "${CANDIDATES[@]}"; do
  dir="$NVM_DIR/versions/node/v$v"
  if [[ ! -d "$dir" ]]; then
    echo "Not present in nvm dir: v$v  Skipping."
    continue
  fi
  if $ASSUME_YES; then
    echo "Uninstalling v$v"
    nvm uninstall "$v"
  else
    ans=""
    prompt_confirm "Uninstall Node v$v? [y/N] " ans
    if [[ "$ans" == [Yy] ]]; then
      nvm uninstall "$v"
    else
      echo "Skipping v$v"
      continue
    fi
  fi
  tmp=()
  for x in "${REMAINING[@]}"; do [[ "$x" != "$v" ]] && tmp+=("$x"); done
  REMAINING=("${tmp[@]}")
done

# --- Optional: review globals ---
if $REVIEW_GLOBALS; then
  echo
  echo "Reviewing global npm packages for remaining versions: ${REMAINING[*]:-none}"
  for v in "${REMAINING[@]}"; do
    review_globals_for_version "$v"
  done
fi

echo "Done."
