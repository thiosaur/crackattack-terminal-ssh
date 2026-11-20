#!/bin/sh
# Prepares what depends on the environment, then runs sshd in the foreground.
#   AUTH_MODE     keys (default): only the public keys in AUTHORIZED_KEYS (the keys themselves,
#                 one per line) or, failing that, in the files of /players (the directory of
#                 the players' keys, mounted read-only)
#                 open: anyone may connect, no password asked; never the default
#   IDLE_TIMEOUT  seconds without a key press before the game stops (default 300)
#   MAX_TIME      seconds of play per connection (default 1800)
#   MAX_PLAYERS   games at once; a further connection is told the server is full (default 10)
#   COMPACT       1: the game draws the 80x24 screen (default 0)
#   INVITES       1: a player with a key is shown a command to give a friend, who plays with it
#                 without a key (an invitation lasts 24 hours and renews itself; default 0)
#   INVITE_HOST   the name of this server, as the friend reaches it (shown in the command)
#   INVITE_PORT   the port of this server, as the friend reaches it (default 2222)
set -eu

# First of all, before anything that looks an account up (ssh-keygen does): the list of
# accounts is a link to this file, and the invitations are added to it later.
cp /usr/share/passwd.base /run/passwd

AUTH_MODE=${AUTH_MODE:-keys}
IDLE_TIMEOUT=${IDLE_TIMEOUT:-300}
MAX_TIME=${MAX_TIME:-1800}
MAX_PLAYERS=${MAX_PLAYERS:-10}
COMPACT=${COMPACT:-0}
INVITES=${INVITES:-0}
INVITE_HOST=${INVITE_HOST:-}
INVITE_PORT=${INVITE_PORT:-2222}

# A wrong value would otherwise make every connection fail while the container looks healthy.
for setting in IDLE_TIMEOUT MAX_TIME MAX_PLAYERS INVITE_PORT; do
    eval "value=\$$setting"
    case "$value" in
    ''|*[!0-9]*|0*)
        echo "entrypoint: $setting must be a positive whole number, not '$value'" >&2
        exit 1
        ;;
    esac
done

# Runs as `play`, with a read-only root: /run is a tmpfs owned by `play`, and everything
# written below goes there.

# Host keys live in a volume, so that the fingerprint survives a rebuild of the image.
if [ ! -s /keys/ssh_host_ed25519_key ]; then
    ssh-keygen -q -t ed25519 -N '' -f /keys/ssh_host_ed25519_key
    echo "entrypoint: new host key, fingerprint:" >&2
    ssh-keygen -l -f /keys/ssh_host_ed25519_key.pub >&2
fi

case "$COMPACT" in
0|1) ;;
*) echo "entrypoint: COMPACT must be 0 or 1, not '$COMPACT'" >&2; exit 1 ;;
esac

case "$INVITES" in
0|1) ;;
*) echo "entrypoint: INVITES must be 0 or 1, not '$INVITES'" >&2; exit 1 ;;
esac
# The name ends in a command shown to players and given to a shell: letters, digits, dots, dashes.
case "$INVITE_HOST" in
*[!A-Za-z0-9.:-]*)
    echo "entrypoint: INVITE_HOST is a name or an address (letters, digits, . : -), not '$INVITE_HOST'" >&2
    exit 1
    ;;
esac
if [ "$INVITES" = 1 ] && [ "$AUTH_MODE" = open ]; then
    echo "entrypoint: INVITES=1 is for AUTH_MODE=keys (open mode lets everybody in already)" >&2
    exit 1
fi
if [ "$INVITES" = 1 ] && [ -z "$INVITE_HOST" ]; then
    echo "entrypoint: INVITES=1 without INVITE_HOST: the command shown ends with <server>" >&2
fi

# The games of the container see each other through this folder (one locked file each).
mkdir -p /run/lobby
chmod 700 /run/lobby

# Who may log in, and how the invited ones do (an invitation is an account named invite- and
# ten characters, which docker/play adds to the list of accounts, and nobody else can).
if [ "$INVITES" = 1 ]; then
    echo "AllowUsers play invite-*" > /run/sshd_users.conf
    cat > /run/sshd_invites.conf <<EOC
Match User invite-*
    AuthenticationMethods any
    PasswordAuthentication yes
    PermitEmptyPasswords yes
    PubkeyAuthentication no
    KbdInteractiveAuthentication no
EOC
    echo "entrypoint: invitations on" >&2
else
    echo "AllowUsers play" > /run/sshd_users.conf
    : > /run/sshd_invites.conf
fi

case "$AUTH_MODE" in
open)
    echo "entrypoint: OPEN mode, anyone who reaches the port may play" >&2
    # The account has an empty password; sshd accepts it without asking anything.
    cat > /run/sshd_auth.conf <<EOC
PasswordAuthentication yes
PermitEmptyPasswords yes
PubkeyAuthentication no
KbdInteractiveAuthentication no
EOC
    ;;
keys)
    rm -f /run/authorized_keys.src
    if [ -n "${AUTHORIZED_KEYS:-}" ]; then
        printf '%s\n' "$AUTHORIZED_KEYS" > /run/authorized_keys.src
        chmod 600 /run/authorized_keys.src
        echo "entrypoint: keys mode, the keys of AUTHORIZED_KEYS" >&2
    else
        # The players' directory: any file in it holds keys (one per line).
        if ! cat /players/* 2> /dev/null | grep -q .; then
            echo "entrypoint: no key in /players yet: nobody can connect until a file there holds a" >&2
            echo "entrypoint: public key (or set AUTHORIZED_KEYS, or choose AUTH_MODE=open)" >&2
        fi
        echo "entrypoint: keys mode, the keys of the files of /players" >&2
    fi
    # The keys are read at each login by docker/authorized-keys.
    cat > /run/sshd_auth.conf <<EOC
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AuthorizedKeysFile none
AuthorizedKeysCommand /usr/local/bin/authorized-keys
AuthorizedKeysCommandUser play
EOC
    ;;
*)
    echo "entrypoint: AUTH_MODE must be keys or open, not '$AUTH_MODE'" >&2
    exit 1
    ;;
esac

printf 'IDLE_TIMEOUT=%s\nMAX_TIME=%s\nMAX_PLAYERS=%s\nCOMPACT=%s\nINVITES=%s\nINVITE_HOST=%s\nINVITE_PORT=%s\n' \
    "$IDLE_TIMEOUT" "$MAX_TIME" "$MAX_PLAYERS" "$COMPACT" "$INVITES" "$INVITE_HOST" "$INVITE_PORT" > /run/play.env

exec /usr/sbin/sshd -D -e
