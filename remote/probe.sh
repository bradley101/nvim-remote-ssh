# remote-ssh probe: describes this server. Read-only: creates nothing.
# Input: RSSH_DIR (optional install directory override).
BASE=${RSSH_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/nvim-remote-ssh}
has() { command -v "$1" >/dev/null 2>&1; }
kv() { printf '%s=%s\n' "$1" "$2"; }
yn() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }

kv os "$(uname -s 2>/dev/null)"
kv arch "$(uname -m 2>/dev/null)"
kv home "$HOME"
kv base "$BASE"
kv user "$(id -un 2>/dev/null)"

libc=unknown
if [ "$(uname -s 2>/dev/null)" = Linux ]; then
  if v=$(getconf GNU_LIBC_VERSION 2>/dev/null); then
    libc="glibc ${v#glibc }"
  elif ldd --version 2>&1 | grep -qi musl; then
    libc=musl
  fi
fi
kv libc "$libc"

# Nearest existing ancestor of BASE decides writability and free space.
d=$BASE
while [ ! -d "$d" ] && [ "$d" != / ] && [ -n "$d" ]; do d=$(dirname "$d"); done
kv writable "$(yn test -w "$d")"
kv free_kb "$(df -Pk "$d" 2>/dev/null | awk 'NR==2 {print $4}')"

for t in curl wget tar gzip; do kv "has_$t" "$(yn has "$t")"; done
if has sha256sum || has shasum || has openssl; then kv has_sha yes; else kv has_sha no; fi

if [ -x "$BASE/nvim/bin/nvim" ]; then
  kv nvim_own "$("$BASE/nvim/bin/nvim" --version 2>/dev/null | head -n 1)"
fi
if has nvim; then
  kv nvim_sys_path "$(command -v nvim)"
  kv nvim_sys "$(nvim --version 2>/dev/null | head -n 1)"
fi
if [ -x "$BASE/bin/rg" ]; then kv rg own; elif has rg; then kv rg system; else kv rg none; fi
kv mason "$(yn test -f "$BASE/plugins/mason.nvim/lua/mason/init.lua")"
