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
set -eu

AUTH_MODE=${AUTH_MODE:-keys}
IDLE_TIMEOUT=${IDLE_TIMEOUT:-300}
MAX_TIME=${MAX_TIME:-1800}
MAX_PLAYERS=${MAX_PLAYERS:-10}
COMPACT=${COMPACT:-0}

# A wrong value would otherwise make every connection fail while the container looks healthy.
for setting in IDLE_TIMEOUT MAX_TIME MAX_PLAYERS; do
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

printf 'IDLE_TIMEOUT=%s\nMAX_TIME=%s\nMAX_PLAYERS=%s\nCOMPACT=%s\n' "$IDLE_TIMEOUT" "$MAX_TIME" "$MAX_PLAYERS" "$COMPACT" > /run/play.env

exec /usr/sbin/sshd -D -e
