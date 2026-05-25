#!/usr/bin/env bash
# Usage:
#   setup      - install wrappers + patch shell rc
#   remove     - remove all wrappers + shell patches
#   status     - show what's active
#   help       - show this

set -euo pipefail

WRAP_DIR="${SAFEINSTALL_DIR:-$HOME/.local/bin}"
MARKER="# safeinstall managed"
VERSION="1.0"

VERBOSE=0
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "-v" || "$arg" == "--verbose" ]]; then
    VERBOSE=1
  else
    ARGS+=("$arg")
  fi
done

# Restore positional parameters without the verbose flags
set -- "${ARGS[@]:-}"

if [[ -t 1 ]]; then
  OK=$'\033[1;32m'
  INFO=$'\033[1;34m'
  WARN=$'\033[1;33m'
  ERR=$'\033[1;31m'
  DIM=$'\033[2m'
  BOLD=$'\033[1m'
  RST=$'\033[0m'
else
  OK="" INFO="" WARN="" ERR="" DIM="" BOLD="" RST=""
fi

log() { printf "${INFO}[ INFO  ]${RST} %s\n" "$*"; }
ok() { printf "${OK}[  OK   ]${RST} %s\n" "$*"; }
warn() { printf "${WARN}[ WARN  ]${RST} %s\n" "$*"; }
fail() { printf "${ERR}[ FAIL  ]${RST} %s\n" "$*" >&2; }
dim() { printf "${DIM}%s${RST}\n" "$*"; }
bold() { printf "\n${BOLD}%s${RST}\n" "$*"; }

log_v() { if [[ $VERBOSE -eq 1 ]]; then log "$*"; fi; }
ok_v() { if [[ $VERBOSE -eq 1 ]]; then ok "$*"; fi; }
warn_v() { if [[ $VERBOSE -eq 1 ]]; then warn "$*"; fi; }
dim_v() { if [[ $VERBOSE -eq 1 ]]; then dim "$*"; fi; }

declare -a WRAPPED_TOOLS=()
declare -a CREATED_PASS=()

PATH_WITHOUT_WRAP=""
old_ifs="${IFS:-}"
IFS=: read -r -a path_arr <<<"$PATH"
new_path=()
for p in "${path_arr[@]}"; do
  if [[ -n "$p" && "$p" != "$WRAP_DIR" ]]; then
    new_path+=("$p")
  fi
done
IFS=:
PATH_WITHOUT_WRAP="${new_path[*]}"
if [[ -n "$old_ifs" ]]; then
  IFS="$old_ifs"
else
  unset IFS
fi

# Format: "wrapper_name|real_name|extra_args"
declare -A PM_ARGS=(
  [npm]="--ignore-scripts"
  [pnpm]="--ignore-scripts"
  [yarn]="--ignore-scripts"
  [bun]="--ignore-scripts"
  [npx]="--ignore-scripts"
  [bunx]="--ignore-scripts"
)

# pip/uv handled separately

_pip_uv_block_msg() {
  local _name="$1"
  local _reason="$2"
  local RED="\033[1;31m" BOLD="\033[1m" RST="\033[0m"

  printf "\n${RED}safeinstall: BLOCKED source-based installation${RST}\n\n" >&2
  printf "Reason:\n" >&2
  printf "  %s\n\n" "$_reason" >&2
  printf "  Python package managers execute package build code from local directories\n" >&2
  printf "  during metadata discovery and wheel building. This may run arbitrary code\n" >&2
  printf "  from:\n" >&2
  printf "    - setup.py\n" >&2
  printf "    - pyproject.toml build backends\n" >&2
  printf "    - PEP 517 hooks\n\n" >&2
  printf "  This execution happens BEFORE safety restrictions like --only-binary\n" >&2
  printf "  can be enforced.\n\n" >&2
  printf "Next steps:\n" >&2
  printf "  1. Review the package source and build configuration.\n" >&2
  printf "  2. Inspect:\n" >&2
  printf "       - ${BOLD}pyproject.toml${RST}\n" >&2
  printf "       - ${BOLD}setup.py${RST}\n" >&2
  printf "       - custom build backends\n" >&2
  printf "  3. If you trust this package, use:\n" >&2
  printf "       ${BOLD}unsafe-$_name${RST}\n\n" >&2
  printf "Tip:\n" >&2
  printf "  Local path installs are treated as trusted source execution by pip and uv.\n\n" >&2
}

is_intercepted() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local line
  {
    read -r line || true
    if [[ "$line" == *"$MARKER"* ]]; then return 0; fi
    read -r line || true
    if [[ "$line" == *"$MARKER"* ]]; then return 0; fi
    read -r line || true
    if [[ "$line" == *"$MARKER"* ]]; then return 0; fi
  } <"$file"
  return 1
}

real_bin() {
  local cmd="$1"
  PATH="$PATH_WITHOUT_WRAP" command -v "$cmd" 2>/dev/null || true
}

write_wrapper() {
  local name="$1"
  local real="$2"
  local extra_args="$3"
  local dest="$WRAP_DIR/$name"

  if [[ -z "$real" ]]; then
    warn "$name not found on system - skipping"
    return
  fi

  local template
  read -r -d '' template <<'WRAPPER_EOF' || true
#!/usr/bin/env bash
# SAFEINSTALL_MARKER
# Intercepts SAFEINSTALL_NAME to block lifecycle script execution.
# To bypass: use `unsafe-SAFEINSTALL_NAME` or call the real binary directly.
# Resolves real binary at runtime - works with nvm, volta, pyenv, etc.

WRAP_DIR="SAFEINSTALL_WRAP_DIR"
_SAFE_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$WRAP_DIR" | tr '\n' ':')"
REAL="$(PATH="$_SAFE_PATH" command -v SAFEINSTALL_NAME 2>/dev/null)"
if [[ -z "$REAL" ]]; then echo "safeinstall: SAFEINSTALL_NAME not found in PATH" >&2; exit 1; fi

# Audit: find node_modules with suppressed lifecycle scripts
_audit_blocked_scripts() {
  local search_dir="${1:-.}"
  local nm="$search_dir/node_modules"
  local root_pkg="$search_dir/package.json"

  local YELLOW="\033[1;33m" BOLD="\033[1m" RST="\033[0m"
  local warned=0

  _check_pkg() {
    local pkg_json="$1"
    [[ -f "$pkg_json" ]] || return 0

    # Extract scripts block keys using only bash+grep (no jq required)
    local scripts
    scripts=$(grep -A 50 '"scripts"' "$pkg_json" 2>/dev/null \
      | grep -oP '"(preinstall|install|postinstall|prepare|prepack|prepublish)"\s*:' \
      | grep -oP '"[^"]+"' | tr -d '"' || true)

    if [[ -n "$scripts" ]]; then
      local pkg_name
      pkg_name=$(grep -oP '"name"\s*:\s*"\K[^"]+' "$pkg_json" | head -n1 || true)
      if [[ -z "$pkg_name" ]]; then pkg_name="$(basename "$(dirname "$pkg_json")")"; fi

      if [[ $warned -eq 0 ]]; then
        printf "\n${BOLD}safeinstall: lifecycle scripts were BLOCKED for:${RST}\n" >&2
        warned=1
      fi
      printf "  ${YELLOW}! %-35s${RST} suppressed: %s\n" "$pkg_name" "$(echo "$scripts" | tr '\n' ' ')" >&2
    fi
  }

  _check_pkg "$root_pkg"

  if [[ -d "$nm" ]]; then
    while IFS= read -r -d '' p; do
      _check_pkg "$p"
    done < <(find "$nm" -maxdepth 3 -name "package.json" -not -path "*/node_modules/*/node_modules/*" -print0 2>/dev/null)
  fi

  if [[ $warned -eq 1 ]]; then
    printf "  ${BOLD}-> run \`unsafe-SAFEINSTALL_NAME\` if you trust these packages and need scripts to run.${RST}\n\n" >&2
  fi
}

# Only audit after install/ci/add subcommands
case "${1:-}" in
  install|i|ci|add|update|upgrade)
    "$REAL" "$1" SAFEINSTALL_EXTRA_ARGS "${@:2}"
    _EXIT=$?
    _audit_blocked_scripts "$(pwd)"
    exit $_EXIT
    ;;
  "")
    if [[ "SAFEINSTALL_NAME" == "pnpm" || "SAFEINSTALL_NAME" == "yarn" ]]; then
      "$REAL" SAFEINSTALL_EXTRA_ARGS
      _EXIT=$?
      _audit_blocked_scripts "$(pwd)"
      exit $_EXIT
    else
      exec "$REAL" "$@"
    fi
    ;;
  *)
    if [[ "SAFEINSTALL_NAME" == "npx" || "SAFEINSTALL_NAME" == "bunx" ]]; then
      exec "$REAL" SAFEINSTALL_EXTRA_ARGS "$@"
    else
      exec "$REAL" "$@"
    fi
    ;;
esac
WRAPPER_EOF

  local content
  content="${template//SAFEINSTALL_MARKER/$MARKER - $name wrapper}"
  content="${content//SAFEINSTALL_NAME/$name}"
  content="${content//SAFEINSTALL_WRAP_DIR/$WRAP_DIR}"
  content="${content//SAFEINSTALL_EXTRA_ARGS/$extra_args}"

  printf '%s\n' "$content" >"$dest"
  chmod +x "$dest"
  ok_v "Wrapped $name (runtime-resolved, audited) +$extra_args"
  WRAPPED_TOOLS+=("$name")
}

write_pip_wrapper() {
  local name="$1"
  local real="$2"
  local dest="$WRAP_DIR/$name"

  if [[ -z "$real" ]]; then
    warn_v "$name not found on system - skipping"
    return
  fi

  local template
  read -r -d '' template <<'WRAPPER_EOF' || true
#!/usr/bin/env bash
# SAFEINSTALL_MARKER
# Resolves real binary at runtime - works with pyenv, conda, venv, etc.

WRAP_DIR="SAFEINSTALL_WRAP_DIR"
_SAFE_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$WRAP_DIR" | tr '\n' ':')"
REAL="$(PATH="$_SAFE_PATH" command -v SAFEINSTALL_NAME 2>/dev/null)"
if [[ -z "$REAL" ]]; then echo "safeinstall: SAFEINSTALL_NAME not found in PATH" >&2; exit 1; fi

SAFEINSTALL_MSG_FUNC

case "${1:-}" in
  install|download)
    _is_unsafe=0
    _reason=""
    _skip=0
    for arg in "$@"; do
      if [[ $_skip -eq 1 ]]; then _skip=0; continue; fi
      case "$arg" in
        -e|--editable) _is_unsafe=1; _reason="Editable installs are blocked (they execute code during build)"; break ;;
        -r|--requirement|-c|--constraint) _skip=1; continue ;;
        -*) continue ;;
      esac

      # Check for source patterns: local paths, VCS, or non-wheel URLs
      if [[ "$arg" == "." || "$arg" == ".." || "$arg" == */* || "$arg" == *://* || "$arg" == git+* ]]; then
        if [[ "$arg" != *.whl && "$arg" != *.whl#* ]]; then
          _is_unsafe=1
          _reason="Direct source install detected: $arg"
          break
        fi
      fi
      # Catch directories even if no slash (e.g. 'pip install mydir')
      if [[ -d "$arg" ]]; then
        _is_unsafe=1; _reason="Local directory detected: $arg"; break
      fi
    done

    if [[ $_is_unsafe -eq 1 ]]; then
      _pip_uv_block_msg "SAFEINSTALL_NAME" "$_reason"
      exit 1
    fi

    # Capture stderr to detect packages with no wheel available
    _TMPOUT="$(mktemp)"
    "$REAL" "$@" --only-binary=:all: 2>&1 | tee "$_TMPOUT"
    _EXIT=${PIPESTATUS[0]}

    # Warn on any packages that couldn't be installed due to no wheel
    _SKIPPED=$(grep -oP "(?<=No matching distribution found for )[^\s]+" "$_TMPOUT" \
               || grep -oP "(?<=ERROR: Could not find a version that satisfies the requirement )[^\s]+" "$_TMPOUT" \
               || true)
    _SOURCE_ONLY=$(grep -iP "no .* wheel|only source|requires.*build|no binary" "$_TMPOUT" || true)

    if [[ -n "$_SKIPPED" || -n "$_SOURCE_ONLY" ]]; then
      YELLOW="\033[1;33m" BOLD="\033[1m" RST="\033[0m"
      printf "\n${BOLD}safeinstall: some packages may need source builds (no wheel available):${RST}\n" >&2
      [[ -n "$_SKIPPED" ]] && printf "  \033[1;33m! %s\033[0m\n" "$_SKIPPED" >&2
      printf "  ${BOLD}-> run \`unsafe-SAFEINSTALL_NAME\` if you trust these and need source builds.${RST}\n\n" >&2
    fi

    rm -f "$_TMPOUT"
    exit $_EXIT
    ;;
  *)
    exec "$REAL" "$@"
    ;;
esac
WRAPPER_EOF

  local msg_func_content
  msg_func_content=$(declare -f _pip_uv_block_msg)

  local content
  content="${template//SAFEINSTALL_MARKER/$MARKER - $name wrapper}"
  content="${content//SAFEINSTALL_NAME/$name}"
  content="${content//SAFEINSTALL_WRAP_DIR/$WRAP_DIR}"
  content="${content//SAFEINSTALL_MSG_FUNC/$msg_func_content}"

  printf '%s\n' "$content" >"$dest"
  chmod +x "$dest"
  ok_v "Wrapped $name (runtime-resolved, audited) install: --only-binary=:all:"
  WRAPPED_TOOLS+=("$name")
}

write_uv_wrapper() {
  local real
  real=$(real_bin uv)
  local dest="$WRAP_DIR/uv"

  if [[ -z "$real" ]]; then
    warn_v "uv not found on system - skipping"
    return
  fi

  local template
  read -r -d '' template <<'WRAPPER_EOF' || true
#!/usr/bin/env bash
# SAFEINSTALL_MARKER
# Resolves real binary at runtime.

WRAP_DIR="SAFEINSTALL_WRAP_DIR"
_SAFE_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$WRAP_DIR" | tr '\n' ':')"
REAL="$(PATH="$_SAFE_PATH" command -v uv 2>/dev/null)"
if [[ -z "$REAL" ]]; then echo "safeinstall: uv not found in PATH" >&2; exit 1; fi

SAFEINSTALL_MSG_FUNC

_check_source_args() {
  local _is_unsafe=0
  local _reason=""
  local _skip=0
  for arg in "$@"; do
    if [[ $_skip -eq 1 ]]; then _skip=0; continue; fi
    case "$arg" in
      -e|--editable) _is_unsafe=1; _reason="Editable installs are blocked (they execute code during build)"; break ;;
      -r|--requirement|-c|--constraint) _skip=1; continue ;;
      -*) continue ;;
    esac
    if [[ "$arg" == "." || "$arg" == ".." || "$arg" == */* || "$arg" == *://* || "$arg" == git+* ]]; then
      if [[ "$arg" != *.whl && "$arg" != *.whl#* ]]; then
        _is_unsafe=1; _reason="Direct source install detected: $arg"; break
      fi
    fi
    if [[ -d "$arg" ]]; then
      _is_unsafe=1; _reason="Local directory detected: $arg"; break
    fi
  done

  if [[ $_is_unsafe -eq 1 ]]; then
    _pip_uv_block_msg "uv" "$_reason"
    exit 1
  fi
}

case "${1:-}" in
  pip)
    case "${2:-}" in
      install|download)
        _check_source_args "${@:3}"
        exec "$REAL" pip "$2" --only-binary=:all: "${@:3}"
        ;;
      *)
        exec "$REAL" "$@"
        ;;
    esac
    ;;
  add|sync|run)
    _check_source_args "${@:2}"
    if [[ "$1" == "run" ]]; then
      has_pip=0
      is_install=0
      prev=""
      for arg in "${@:2}"; do
        if [[ $has_pip -eq 1 ]]; then
          if [[ "$arg" == "install" || "$arg" == "download" ]]; then
            is_install=1
            break
          fi
        elif [[ "$arg" == "pip" || "$arg" == "pip3" ]]; then
          if [[ "$prev" != "--package" && "$prev" != "-p" && "$prev" != "--with" ]]; then
            has_pip=1
          fi
        fi
        prev="$arg"
      done
      if [[ $has_pip -eq 1 && $is_install -eq 1 ]]; then
        printf "\n\033[1;31msafeinstall: BLOCKED running pip install/download via uv run\033[0m\n\n" >&2
        printf "Reason:\n" >&2
        printf "  Running pip install/download via 'uv run' bypasses the safeinstall wrapper\n" >&2
        printf "  and executes the raw pip binary without safety restrictions.\n\n" >&2
        printf "Next steps:\n" >&2
        printf "  Use 'uv pip install' or 'uv add' instead.\n" >&2
        printf "  If you must run this exact command, use:\n" >&2
        printf "    unsafe-uv run pip ...\n\n" >&2
        exit 1
      fi
    fi
    exec "$REAL" "$1" --no-build "${@:2}"
    ;;
  tool)
    case "${2:-}" in
      install|upgrade)
        _check_source_args "${@:3}"
        exec "$REAL" tool "$2" --no-build "${@:3}"
        ;;
      *)
        exec "$REAL" "$@"
        ;;
    esac
    ;;
  *)
    exec "$REAL" "$@"
    ;;
esac
WRAPPER_EOF

  local msg_func_content
  msg_func_content=$(declare -f _pip_uv_block_msg)

  local content
  content="${template//SAFEINSTALL_MARKER/$MARKER - uv wrapper}"
  content="${content//SAFEINSTALL_NAME/uv}"
  content="${content//SAFEINSTALL_WRAP_DIR/$WRAP_DIR}"
  content="${content//SAFEINSTALL_MSG_FUNC/$msg_func_content}"

  printf '%s\n' "$content" >"$dest"
  chmod +x "$dest"
  ok_v "Wrapped uv (runtime-resolved) - build restrictions enabled"
  WRAPPED_TOOLS+=("uv")
}

write_uvx_wrapper() {
  local real
  real=$(real_bin uvx)
  local dest="$WRAP_DIR/uvx"

  if [[ -z "$real" ]]; then
    warn_v "uvx not found on system - skipping"
    return
  fi

  local template
  read -r -d '' template <<'WRAPPER_EOF' || true
#!/usr/bin/env bash
# SAFEINSTALL_MARKER
# Resolves real binary at runtime.

WRAP_DIR="SAFEINSTALL_WRAP_DIR"
_SAFE_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$WRAP_DIR" | tr '\n' ':')"
REAL="$(PATH="$_SAFE_PATH" command -v uvx 2>/dev/null)"
if [[ -z "$REAL" ]]; then echo "safeinstall: uvx not found in PATH" >&2; exit 1; fi

exec "$REAL" --no-build "$@"
WRAPPER_EOF

  local content
  content="${template//SAFEINSTALL_MARKER/$MARKER - uvx wrapper}"
  content="${content//SAFEINSTALL_WRAP_DIR/$WRAP_DIR}"

  printf '%s\n' "$content" >"$dest"
  chmod +x "$dest"
  ok_v "Wrapped uvx (runtime-resolved) - build restrictions enabled"
  WRAPPED_TOOLS+=("uvx")
}

write_unsafe_passthrough() {
  local name="$1"
  local real="$2"
  local dest="$WRAP_DIR/unsafe-$name"

  [[ -z "$real" ]] && return

  local template
  read -r -d '' template <<'WRAPPER_EOF' || true
#!/usr/bin/env bash
# SAFEINSTALL_MARKER - unsafe passthrough for SAFEINSTALL_NAME
# WARNING: Bypasses safeinstall protections. Use deliberately.
_SAFE_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "SAFEINSTALL_WRAP_DIR" | tr '\n' ':')"
REAL="$(PATH="$_SAFE_PATH" command -v SAFEINSTALL_NAME 2>/dev/null)"
if [[ -z "$REAL" ]]; then echo "safeinstall: SAFEINSTALL_NAME not found in PATH" >&2; exit 1; fi
exec "$REAL" "$@"
WRAPPER_EOF

  local content
  content="${template//SAFEINSTALL_MARKER/$MARKER}"
  content="${content//SAFEINSTALL_NAME/$name}"
  content="${content//SAFEINSTALL_WRAP_DIR/$WRAP_DIR}"

  printf '%s\n' "$content" >"$dest"
  chmod +x "$dest"
  ok_v "  unsafe-$name passthrough created"
  CREATED_PASS+=("unsafe-$name")
}

get_rc_files() {
  local files=()
  [[ -f "$HOME/.bashrc" ]] && files+=("$HOME/.bashrc")
  [[ -f "$HOME/.zshrc" ]] && files+=("$HOME/.zshrc")
  [[ -f "$HOME/.config/fish/config.fish" ]] && files+=("$HOME/.config/fish/config.fish")
  # Also check profile for login shells
  [[ -f "$HOME/.profile" ]] && files+=("$HOME/.profile")
  [[ -f "$HOME/.bash_profile" ]] && files+=("$HOME/.bash_profile")
  echo "${files[@]:-}"
}

path_line_for() {
  local rc="$1"
  if [[ "$rc" == *.fish ]]; then
    echo "fish_add_path $WRAP_DIR  $MARKER"
  else
    echo "export PATH=\"$WRAP_DIR:\$PATH\"  $MARKER"
  fi
}

patch_shell_rc() {
  local rc="$1"
  local line
  line=$(path_line_for "$rc")

  if grep -qF "$MARKER" "$rc" 2>/dev/null; then
    dim_v "  $rc - already patched, skipping"
    return
  fi

  printf '\n%s\n' "$line" >>"$rc"
  ok_v "Patched $rc"
}

remove_from_rc() {
  local rc="$1"
  if grep -qF "$MARKER" "$rc" 2>/dev/null; then
    # Portable: create temp file and replace
    local tmp
    tmp=$(mktemp)
    grep -vF "$MARKER" "$rc" >"$tmp"
    mv "$tmp" "$rc"
    ok_v "Cleaned $rc"
  fi
}

cmd_setup() {
  bold "  safeinstall v$VERSION - setup"

  log_v "Creating wrapper directory: $WRAP_DIR"
  mkdir -p "$WRAP_DIR"
  ok_v "Directory ready"

  local dest_bin="$WRAP_DIR/safeinstall"
  if [[ -f "$0" ]]; then
    if [[ "$(basename "$0")" != "safeinstall" ]]; then
      cp "$0" "$dest_bin"
      chmod +x "$dest_bin"
      ok_v "Installed 'safeinstall' command utility to $dest_bin"
    fi
  elif command -v curl >/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/adityabavadekar/safeinstall/master/safeinstall.sh -o "$dest_bin"
    chmod +x "$dest_bin"
    ok_v "Downloaded and installed 'safeinstall' utility to $dest_bin"
  fi

  log "Detecting and wrapping package managers..."

  # JS ecosystem
  for pm in npm pnpm yarn bun npx bunx; do
    local real
    real=$(real_bin "$pm")
    write_wrapper "$pm" "$real" "${PM_ARGS[$pm]}"
    write_unsafe_passthrough "$pm" "$real"
  done

  # Python ecosystem
  for py in pip pip3; do
    local real
    real=$(real_bin "$py")
    write_pip_wrapper "$py" "$real"
    write_unsafe_passthrough "$py" "$real"
  done

  # uv and uvx
  write_uv_wrapper
  local uv_real
  uv_real=$(real_bin uv)
  write_unsafe_passthrough "uv" "$uv_real"

  write_uvx_wrapper
  local uvx_real
  uvx_real=$(real_bin uvx)
  write_unsafe_passthrough "uvx" "$uvx_real"

  # Summary of wrapping
  if [[ ${#WRAPPED_TOOLS[@]} -gt 0 ]]; then
    ok "Protected: $(local IFS=', '; echo "${WRAPPED_TOOLS[*]}")"
    bold "  Temporarily bypass protections with: unsafe-[manager]"
  fi

  # Patch shell rc files
  log_v "Patching shell rc files to prepend $WRAP_DIR to PATH..."
  local rcs
  rcs=$(get_rc_files)
  if [[ -z "$rcs" ]]; then
    warn "No shell rc files found. Add this to your shell config manually:"
    printf "  export PATH=\"%s:\$PATH\"\n" "$WRAP_DIR"
  else
    for rc in $rcs; do
      patch_shell_rc "$rc"
    done
  fi

  # Check if WRAP_DIR is already in PATH
  if [[ ":$PATH:" == *":$WRAP_DIR:"* ]]; then
    ok_v "$WRAP_DIR is already active in current PATH"
  else
    warn "Restart your shell (or run: source ~/.zshrc) to activate"
  fi

  dim "  Run \`safeinstall status\` to verify protection status."
  printf "\n\n${OK}✔${RST} Done. Your system is now more secure.\n"
}

cmd_remove() {
  bold "  safeinstall - remove (taking down defenses)"

  log_v "Removing wrappers from $WRAP_DIR..."
  local removed=0
  local removed_list=()
  for f in "$WRAP_DIR"/*; do
    [[ -f "$f" ]] || continue
    if is_intercepted "$f"; then
      local base
      base=$(basename "$f")
      rm "$f"
      ok_v "Removed wrapper: $base"
      removed_list+=("$base")
      ((removed++)) || true
    fi
  done

  if [[ ${#removed_list[@]} -gt 0 ]]; then
    ok "Removed: $(local IFS=', '; echo "${removed_list[*]}")"
  fi

  [[ $removed -eq 0 ]] && warn "No managed wrappers found"
  ok "Defenses removed. safeinstall utility remains available."
}

cmd_uninstall() {
  bold "  safeinstall - uninstall"

  log_v "Removing all wrappers, patches, and self..."
  
  for f in "$WRAP_DIR"/*; do
    [[ -f "$f" ]] || continue
    if is_intercepted "$f"; then
      rm "$f"
    fi
  done

  if [[ -f "$WRAP_DIR/safeinstall" ]]; then
    rm -f "$WRAP_DIR/safeinstall"
    ok "Removed safeinstall command utility"
  fi

  log "Cleaning shell rc files..."
  local rcs
  rcs=$(get_rc_files)
  for rc in $rcs; do
    remove_from_rc "$rc"
  done

  printf "\n"
  ok "safeinstall fully uninstalled from system"
}

cmd_status() {
  bold "  safeinstall v$VERSION - status"

  local active_count=0
  for pm in npm pnpm yarn bun npx bunx pip pip3 uv uvx; do
    local resolved
    resolved=$(command -v "$pm" 2>/dev/null || true)
    if [[ -n "$resolved" ]] && is_intercepted "$resolved"; then
      ok "$pm -> $resolved (intercepted)"
      ((active_count++)) || true
    elif [[ -n "$resolved" ]]; then
      warn "$pm -> $resolved (NOT intercepted)"
    else
      dim "  $pm - not installed"
    fi
  done

  printf "\n"
  if [[ $active_count -gt 0 ]]; then
    ok "$active_count package manager(s) protected"
  else
    warn "No interceptors active. Run: setup"
  fi
}

cmd_help() {
  cat <<EOF

  ${BOLD}safeinstall v$VERSION${RST}
  Portable package manager script-execution interceptor

  ${BOLD}Usage:${RST}
    setup            Install wrappers + patch shell rc files
    remove           Take down defenses (remove wrappers)
    uninstall        Remove all wrappers, shell patches, and self
    status           Show interception status
    help             Show this help
    -v, --verbose    Show detailed logs

  ${BOLD}What it does:${RST}
    Installs thin wrapper scripts in ~/.local/bin/ (or \$SAFEINSTALL_DIR)
    that shadow npm, pnpm, yarn, bun, npx, bunx, pip, pip3, uv, uvx
    injecting safety flags.

  ${BOLD}Bypass (when you need scripts to run):${RST}
    unsafe-npm install        Explicit opt-in to run lifecycle scripts
    unsafe-pip install        Explicit opt-in for source builds
    unsafe-uv pip install     Explicit opt-in for source builds
    /usr/bin/npm install      Call the real binary directly

  ${BOLD}Env:${RST}
    SAFEINSTALL_DIR    Override wrapper dir

EOF
}

case "${1:-help}" in
setup) cmd_setup ;;
remove) cmd_remove ;;
uninstall) cmd_uninstall ;;
status) cmd_status ;;
help | --help | -h) cmd_help ;;
*)
  fail "Unknown command: $1"
  cmd_help
  exit 1
  ;;
esac
