#!/bin/sh
# Runs the test suite against a throwaway local sshd. Needs root (sshd, test
# user) and nvim, ssh, sshd, python3 on PATH.
set -eu
cd "$(dirname "$0")/.."
W=${RSSH_TEST_DIR:-/tmp/rssh-test}
# Shared connections left over from an earlier run would skip authentication.
pkill -f "ControlPath=/tmp/rssh-$(id -u)/" 2>/dev/null || true
rm -rf "/tmp/rssh-$(id -u)"
rm -rf "$W/known_hosts" "$W"/remote* "$W/data" "$W/www" /home/rsshpw/apps
tests/setup-sshd.sh "$W"
tests/make-fixtures.sh "$W/www"
HTTP_PORT=${RSSH_TEST_HTTP_PORT:-8765}
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$W/www" >/dev/null 2>&1 &
HTTP_PID=$!
trap 'kill $HTTP_PID 2>/dev/null || true' EXIT
sleep 0.5
RSSH_TEST_HTTP=http://127.0.0.1:$HTTP_PORT RSSH_TEST_DIR=$W XDG_DATA_HOME=$W/data XDG_STATE_HOME=$W/data XDG_CACHE_HOME=$W/data \
  nvim --headless -u NONE --cmd "set rtp^=$(pwd)" -c "autocmd VimEnter * ++once ++nested luafile tests/run.lua"
