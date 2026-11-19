#!/bin/sh
# Prepares what depends on the environment, then runs sshd in the foreground.
#   AUTH_MODE     keys (default): only the public keys in AUTHORIZED_KEYS (the keys themselves,
#                 one per line) or, failing that, in the file mounted on /authorized_keys
#                 (compose.yml mounts the host's ~/.ssh/authorized_keys there)
#                 open: anyone may connect, no password asked; never the default
#   IDLE_TIMEOUT  seconds without a key press before the game stops (default 300)
#   MAX_TIME      seconds of play per connection (default 1800)
#   MAX_PLAYERS   games at once; a further connection is told the server is full (default 10)
set -eu

AUTH_MODE=${AUTH_MODE:-keys}
IDLE_TIMEOUT=${IDLE_TIMEOUT:-300}
MAX_TIME=${MAX_TIME:-1800}
MAX_PLAYERS=${MAX_PLAYERS:-10}

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

# /run is a tmpfs (the image runs with a read-only root): sshd's privilege-separation
# directory and everything written below are created at each start.
install -d -m 755 /run/sshd
# sshd records logins in these files; they are empty and live in a tmpfs too.
touch /var/log/lastlog /var/log/wtmp /var/log/btmp

# Host keys live in a volume, so that the fingerprint survives a rebuild of the image.
if [ ! -s /keys/ssh_host_ed25519_key ]; then
    ssh-keygen -q -t ed25519 -N '' -f /keys/ssh_host_ed25519_key
    echo "entrypoint: new host key, fingerprint:" >&2
    ssh-keygen -l -f /keys/ssh_host_ed25519_key.pub >&2
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
    elif [ -f /authorized_keys ]; then
        [ -s /authorized_keys ] \
            || echo "entrypoint: /authorized_keys is empty: nobody can connect until it holds a key" >&2
        echo "entrypoint: keys mode, the keys of the file mounted on /authorized_keys" >&2
    else
        echo "entrypoint: no key to allow: set AUTHORIZED_KEYS, mount a file of public keys on" >&2
        echo "entrypoint: /authorized_keys, or choose AUTH_MODE=open to let anyone in" >&2
        exit 1
    fi
    # The keys are read at each login by docker/authorized-keys, as root: the host's file
    # usually belongs to another account and is not readable by `play`.
    cat > /run/sshd_auth.conf <<EOC
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile none
AuthorizedKeysCommand /usr/local/bin/authorized-keys
AuthorizedKeysCommandUser root
EOC
    ;;
*)
    echo "entrypoint: AUTH_MODE must be keys or open, not '$AUTH_MODE'" >&2
    exit 1
    ;;
esac

printf 'IDLE_TIMEOUT=%s\nMAX_TIME=%s\nMAX_PLAYERS=%s\n' "$IDLE_TIMEOUT" "$MAX_TIME" "$MAX_PLAYERS" > /run/play.env

exec /usr/sbin/sshd -D -e
