# remote-ssh installer: downloads server-side components into $BASE.
# Inputs (set by the client before this text):
#   BASE              install directory
#   NVIM_URL NVIM_SUM_URL NVIM_ASSET NVIM_COMPAT_URL   (NVIM_URL empty = skip)
#   RG_URL RG_SUM_URL RG_ASSET                         (RG_URL empty = skip)
#   MASON_URL                                          (empty = skip)
#   ALLOW_UNVERIFIED  1 = the user accepted installing without a checksum
# Output protocol, one per line:
#   RSSH_PROGRESS <text> | RSSH_WARN <text> | RSSH_ERROR <code> <text> | RSSH_DONE
set -u
say() { echo "RSSH_PROGRESS $*"; }
warn() { echo "RSSH_WARN $*"; }
die() { code=$1; shift; echo "RSSH_ERROR $code $*"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

mkdir -p "$BASE" 2>/dev/null || die nowrite "cannot create $BASE"
t="$BASE/.exec-test.$$"
{ printf '#!/bin/sh\nexit 0\n' >"$t" && chmod +x "$t"; } 2>/dev/null || die nowrite "cannot write to $BASE"
if ! "$t" 2>/dev/null; then rm -f "$t"; die noexec "$BASE is on a filesystem that does not allow running programs (noexec)"; fi
rm -f "$t"

# One installer at a time; a lock older than 20 minutes is a crashed run.
LOCK="$BASE/.install.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +20 2>/dev/null)" ]; then
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || die locked "another installation is in progress on this host"
  else
    die locked "another installation is in progress on this host"
  fi
fi
TMP="$BASE/tmp.$$"
trap 'rm -rf "$TMP" "$LOCK"' EXIT
trap 'exit 1' INT TERM HUP
# Leftovers of interrupted runs (we hold the lock, so nobody is using them).
rm -rf "$BASE"/tmp.*
mkdir -p "$TMP" "$BASE/bin" || die nowrite "cannot write to $BASE"

dl() {
  if has curl; then
    curl -fsSL --retry 2 --connect-timeout 15 -o "$2" "$1" 2>"$TMP/dl.err"
  else
    wget -q --tries=3 --timeout=15 -O "$2" "$1" 2>"$TMP/dl.err"
  fi
}
sha() {
  if has sha256sum; then sha256sum "$1" | cut -d' ' -f1
  elif has shasum; then shasum -a 256 "$1" | cut -d' ' -f1
  elif has openssl; then openssl dgst -sha256 "$1" | sed 's/.*= *//'
  else return 1
  fi
}
# fetch URL SUM_URL ASSET DEST
#   0 ok (verified, or unverified with consent)   1 download failed
#   2 checksum mismatch                           3 cannot verify
fetch() {
  dl "$1" "$4" || return 1
  unverified() { if [ "${ALLOW_UNVERIFIED:-0}" = 1 ]; then return 0; else return 3; fi; }
  [ -n "$2" ] || { unverified; return $?; }
  dl "$2" "$4.sum" || { unverified; return $?; }
  want=$(grep -F "$3" "$4.sum" | head -n 1 | awk '{print $1}')
  if [ -z "$want" ] && [ "$(wc -w <"$4.sum" | tr -d ' ')" = 1 ]; then want=$(tr -d ' \n\r' <"$4.sum"); fi
  [ -n "$want" ] || { unverified; return $?; }
  have=$(sha "$4") || { unverified; return $?; }
  [ "$want" = "$have" ] && return 0
  return 2
}

# install_nvim URL SUM_URL  ->  0 ok, 4 downloaded but cannot run here
install_nvim() {
  fetch "$1" "$2" "$NVIM_ASSET" "$TMP/nvim.tgz"; rc=$?
  if [ $rc = 2 ]; then
    say "Checksum mismatch, downloading Neovim again"
    fetch "$1" "$2" "$NVIM_ASSET" "$TMP/nvim.tgz"; rc=$?
  fi
  case $rc in
    1) die download "could not download $1 ($(head -n 1 "$TMP/dl.err" 2>/dev/null))" ;;
    2) die checksum "the downloaded Neovim archive does not match its published checksum; refusing to install it" ;;
    3) die nosum "no checksum could be obtained for $1" ;;
  esac
  rm -rf "$TMP/nvim.x"; mkdir "$TMP/nvim.x"
  tar -xzf "$TMP/nvim.tgz" -C "$TMP/nvim.x" 2>/dev/null || die extract "could not unpack the Neovim archive"
  d=$(ls -d "$TMP"/nvim.x/*/ 2>/dev/null | head -n 1); d=${d%/}
  [ -n "$d" ] && [ -x "$d/bin/nvim" ] || die extract "unexpected layout in the Neovim archive"
  "$d/bin/nvim" --version >/dev/null 2>&1 || return 4
  rm -rf "$BASE/nvim"
  mv "$d" "$BASE/nvim" || die nowrite "could not move Neovim into $BASE"
  return 0
}

if [ -n "${NVIM_URL:-}" ]; then
  say "Downloading Neovim"
  install_nvim "$NVIM_URL" "${NVIM_SUM_URL:-}"; rc=$?
  if [ $rc = 4 ]; then
    [ -n "${NVIM_COMPAT_URL:-}" ] || die cantrun "the official Neovim build does not run on this system (C library too old?)"
    say "The official build does not run here (old C library); trying the compatibility build"
    install_nvim "$NVIM_COMPAT_URL" ""; rc=$?
    [ $rc = 0 ] || die cantrun "no Neovim build runs on this system; install Neovim 0.10+ with the system package manager and reconnect"
  fi
fi

if [ -n "${RG_URL:-}" ]; then
  say "Downloading ripgrep"
  fetch "$RG_URL" "${RG_SUM_URL:-}" "$RG_ASSET" "$TMP/rg.tgz"; rc=$?
  if [ $rc = 0 ]; then
    mkdir "$TMP/rg.x"
    if tar -xzf "$TMP/rg.tgz" -C "$TMP/rg.x" 2>/dev/null \
      && f=$(find "$TMP/rg.x" -type f -name rg | head -n 1) && [ -n "$f" ] \
      && chmod +x "$f" && "$f" --version >/dev/null 2>&1; then
      mv "$f" "$BASE/bin/rg"
    else
      warn "ripgrep could not be installed (archive unusable on this system); search will use grep/find"
    fi
  else
    case $rc in
      1) why="download failed" ;; 2) why="checksum mismatch" ;; *) why="no checksum available" ;;
    esac
    warn "ripgrep could not be installed ($why); search will use grep/find"
  fi
fi

if [ -n "${MASON_URL:-}" ]; then
  say "Downloading mason.nvim (language server installer)"
  mkdir "$TMP/mason"
  if dl "$MASON_URL" "$TMP/mason.tgz" && tar -xzf "$TMP/mason.tgz" --strip-components=1 -C "$TMP/mason" 2>/dev/null \
    && [ -f "$TMP/mason/lua/mason/init.lua" ]; then
    mkdir -p "$BASE/plugins"
    rm -rf "$BASE/plugins/mason.nvim"
    mv "$TMP/mason" "$BASE/plugins/mason.nvim"
  else
    warn "mason.nvim could not be installed; language servers will not be installed automatically"
  fi
fi

echo RSSH_DONE
