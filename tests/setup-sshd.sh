#!/bin/sh
# Starts a throwaway sshd on 127.0.0.1 for the test suite and writes an ssh
# config with direct, jump-host, password and broken hosts.
# Usage: tests/setup-sshd.sh <workdir>     (needs root; prints nothing on success)
set -eu
W=$1
PORT=${RSSH_TEST_PORT:-2222}
mkdir -p "$W" /run/sshd
chmod 700 "$W"
[ -f "$W/hostkey" ] || ssh-keygen -q -t ed25519 -N '' -f "$W/hostkey"
[ -f "$W/id" ] || ssh-keygen -q -t ed25519 -N '' -f "$W/id"

# Password-only test account with a noisy shell profile.
if ! id rsshpw >/dev/null 2>&1; then
  useradd -m -s /bin/sh rsshpw
fi
echo 'rsshpw:test-password' | chpasswd
echo 'echo "noise from profile"' > /home/rsshpw/.profile

cat > "$W/authorized_keys" <<K
$(cat "$W/id.pub")
K
chmod 600 "$W/authorized_keys"

cat > "$W/sshd_config" <<C
Port $PORT
ListenAddress 127.0.0.1
HostKey $W/hostkey
PidFile $W/sshd.pid
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin yes
UsePAM no
StrictModes no
AllowTcpForwarding yes
Match User root
  AuthorizedKeysFile $W/authorized_keys
  PasswordAuthentication no
Match User rsshpw
  AuthorizedKeysFile /dev/null
C

if [ -f "$W/sshd.pid" ] && kill -0 "$(cat "$W/sshd.pid")" 2>/dev/null; then
  kill "$(cat "$W/sshd.pid")"; sleep 0.3
fi
/usr/sbin/sshd -f "$W/sshd_config" -E "$W/sshd.log"

cat > "$W/ssh_config" <<C
Host direct
  HostName 127.0.0.1
  Port $PORT
  User root
  IdentityFile $W/id
Host jumped
  HostName 127.0.0.1
  Port $PORT
  User root
  IdentityFile $W/id
  ProxyJump direct
Host doublejump
  HostName 127.0.0.1
  Port $PORT
  User root
  IdentityFile $W/id
  ProxyJump direct,jumped
Host pw
  HostName 127.0.0.1
  Port $PORT
  User rsshpw
  PreferredAuthentications password
  PubkeyAuthentication no
Host behindpw
  HostName 127.0.0.1
  Port $PORT
  User root
  IdentityFile $W/id
  ProxyJump pw
Host fresh1 fresh2 fresh3 fresh4 fresh5 fresh6
  HostName 127.0.0.1
  Port $PORT
  User root
  IdentityFile $W/id
Host refused
  HostName 127.0.0.1
  Port 1
  User root
Host badjump
  HostName 127.0.0.1
  Port $PORT
  User root
  IdentityFile $W/id
  ProxyJump refused
Host nodns
  HostName does-not-exist.invalid
Host unused-*
  User nobody
Host *
  IdentitiesOnly yes
  UserKnownHostsFile $W/known_hosts
  StrictHostKeyChecking ask
C
