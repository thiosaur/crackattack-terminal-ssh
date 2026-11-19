#!/bin/sh
# End-to-end check of the image: builds it, starts it with the hardening of compose.yml and
# connects over ssh (from inside the container, so it also works with a remote docker).
#
#   test/smoke.sh                      the release pinned in .env
#   test/smoke.sh /path/to/checkout    the game built from that checkout of Crack Attack!
#                                      (the way to try a change before it is released)
#
# Everything it creates (containers, volumes, images, temporary files) is removed on exit.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

export COMPOSE_PROJECT_NAME="ca-ssh-smoke-$$"
export IMAGE="ca-ssh-smoke-$$"
export HOST_PORT=$((20000 + $$ % 20000))
export IDLE_TIMEOUT=5 MAX_TIME=60
unset AUTH_MODE AUTHORIZED_KEYS
# A directory on the machine that runs docker (not necessarily this one), for the file of
# keys that stands for the host's ~/.ssh/authorized_keys. Written and removed by containers.
HOST_DIR="/tmp/ca-ssh-smoke-$$"
export AUTHORIZED_KEYS_FILE="$HOST_DIR/authorized_keys"
if [ $# -ge 1 ]; then
    export BINARY_FROM=source CRACKATTACK_SRC="$1"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ca-ssh-smoke.XXXXXX")
IMG=
cleanup() {
    [ -n "$IMG" ] && docker run --rm -v /tmp:/host-tmp --entrypoint rm "$IMG" -rf "/host-tmp/ca-ssh-smoke-$$" > /dev/null 2>&1
    docker compose down --volumes --rmi all --remove-orphans > /dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

SSH="ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p 2222"
SSH_NO_TTY="ssh -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p 2222"
FAILED=0
check() { # check "name" command...
    name=$1; shift
    if "$@"; then echo "  ok    $name"; else echo "  FAIL  $name"; FAILED=$((FAILED + 1)); fi
}
inbox() { docker compose exec -T crackattack "$@"; }
# Runs ssh in the container; keys sent to the game after $1 seconds.
play_after() { delay=$1; shift; inbox sh -c "(sleep $delay; printf q) | $SSH $* 2>&1"; }
has() { printf '%s' "$OUT" | grep -q -- "$1"; }
hasnt() { ! has "$1"; }
running() { inbox pgrep -f "^/usr/local/bin/$1" > /dev/null; }
absent_within() { # process $1 gone within $2 seconds
    i=0; while [ $i -lt "$2" ]; do inbox pgrep -f "^/usr/local/bin/$1" > /dev/null || return 0; sleep 1; i=$((i + 1)); done; return 1
}

# Writes stdin to the file of keys on the docker host, owned as a user's own file would be.
host_keys() { docker run --rm -i -v "$HOST_DIR:/d" --entrypoint sh "$IMG" -c 'cat > /d/authorized_keys && chown 1000:1000 /d/authorized_keys && chmod 600 /d/authorized_keys'; }
wait_sshd() {
    i=0; until inbox ssh-keyscan -T 2 -p 2222 127.0.0.1 2> /dev/null | grep -q ssh-ed25519; do
        i=$((i + 1)); [ $i -gt 20 ] && { docker compose logs --tail 30; echo "sshd did not start"; exit 1; }; sleep 1
    done
}
# The test keys go into the container's /tmp, a tmpfs emptied each time it is recreated.
put_keys() {
    inbox sh -c 'cat > /tmp/good && chmod 600 /tmp/good' < "$WORK/good"
    inbox sh -c 'cat > /tmp/bad && chmod 600 /tmp/bad' < "$WORK/bad"
}

echo "== files"
check "compose.coolify.yml is what tools/coolify-compose.sh makes from compose.yml" \
    sh -c "tools/coolify-compose.sh | diff -q - compose.coolify.yml > /dev/null"
check "compose.coolify.yml has no variable in a volume source (Coolify refuses it)" \
    sh -c "! grep 'source:' compose.coolify.yml | grep -qF '\${'"

echo "== build"
docker compose build > "$WORK/build.log" 2>&1 || { tail -30 "$WORK/build.log"; echo "build failed"; exit 1; }
IMG=$(docker compose config --images | head -1)
ssh-keygen -q -t ed25519 -N '' -f "$WORK/good" && ssh-keygen -q -t ed25519 -N '' -f "$WORK/bad"

echo "== nothing set: only the keys of the host's file"
OUT=$(AUTHORIZED_KEYS_FILE="$HOST_DIR/absent" docker compose up -d 2>&1)
check "no file of keys: the container does not start" test -z "$(docker compose ps -q --status running)"
host_keys < "$WORK/good.pub"
docker compose up -d --force-recreate > /dev/null 2>&1
wait_sshd
inbox crackattack-terminal --version
put_keys
for bad in IDLE_TIMEOUT=abc IDLE_TIMEOUT=0 MAX_TIME=-5 MAX_TIME=1.5 MAX_PLAYERS=2x MAX_PLAYERS=0; do
    OUT=$(docker compose run --rm --no-deps -e "$bad" crackattack 2>&1)
    check "a wrong setting stops the start: $bad" has "must be a positive whole number"
done
CONF=$(inbox sshd -T)
check "the image carries the repository of the image as its source" \
    sh -c "docker image inspect --format '{{index .Config.Labels \"org.opencontainers.image.source\"}}' \"$IMG\" | grep -q crackattack-terminal-ssh"
OUT=$(inbox sh -c 'ldd /usr/local/bin/crackattack-terminal 2>&1')
check "the game in the image is a static executable" has "not a dynamic executable\|statically linked"
CID=$(docker compose ps -q crackattack)
OUT=$(docker inspect --format '{{.HostConfig.LogConfig.Config}}' "$CID")
check "the container log is bounded" has "max-size"
for setting in "passwordauthentication no" "permitemptypasswords no" "kbdinteractiveauthentication no" \
               "pubkeyauthentication yes" "authorizedkeyscommand /usr/local/bin/authorized-keys"; do
    OUT=$CONF; check "sshd: $setting" has "^$setting\$"
done
OUT=$(inbox sh -c "$SSH play@127.0.0.1 2>&1" < /dev/null)
check "no key: refused"                               has "Permission denied"
OUT=$(play_after 2 -i /tmp/bad play@127.0.0.1)
check "a key that is not in the file: refused"        has "Permission denied"
OUT=$(play_after 2 -i /tmp/good play@127.0.0.1)
check "a key of the file: the game runs"              has "Game stopped"
host_keys < "$WORK/bad.pub"
OUT=$(play_after 2 -i /tmp/good play@127.0.0.1)
check "key removed from the file: refused, no restart" has "Permission denied"
OUT=$(play_after 2 -i /tmp/bad play@127.0.0.1)
check "key added to the file: the game runs, no restart" has "Game stopped"

echo "== open access (AUTH_MODE=open)"
export AUTH_MODE=open AUTHORIZED_KEYS_FILE=/dev/null
docker compose up -d --force-recreate > /dev/null 2>&1
wait_sshd
OUT=$(play_after 2 play@127.0.0.1)
check "login starts the game and Q ends the session" has "Game stopped"
check "the banner names the licence"                 has "GPL-3.0-or-later"
OUT=$(play_after 2 play@127.0.0.1 id)
check "a command asked by the client does not run"   hasnt "uid="
check "the game runs instead"                         has "Game stopped"
OUT=$(inbox sh -c "$SSH_NO_TTY play@127.0.0.1 2>&1" < /dev/null)
check "without a terminal: refused with a message"    has "needs a terminal"
OUT=$(inbox sh -c "$SSH_NO_TTY play@127.0.0.1 ls 2>&1" < /dev/null)
check "a command without a terminal: refused too"     has "needs a terminal"
check "...and no game was started"                    absent_within crackattack-terminal 2
OUT=$(inbox sh -c "$SSH root@127.0.0.1 2>&1" < /dev/null)
check "another account is refused"                    has "Permission denied"
CONF=$(inbox sshd -T)
for setting in "allowusers play" "permitrootlogin no" "allowtcpforwarding no" "x11forwarding no" \
               "allowagentforwarding no" "permittunnel no" "forcecommand /usr/local/bin/play" \
               "permitemptypasswords yes" "pubkeyauthentication no"; do
    OUT=$CONF; check "sshd: $setting" has "^$setting\$"
done
check "the root file system is read-only"            sh -c "! docker compose exec -T crackattack touch /etc/x 2> /dev/null"
check "no game process is left"                      absent_within crackattack-terminal 5

echo "== limits"
t0=$(date +%s)
OUT=$(inbox sh -c "$SSH play@127.0.0.1 2>&1" < /dev/null)
t1=$(date +%s)
check "an idle player is stopped (IDLE_TIMEOUT=5, took $((t1 - t0)) s)" has "no key was pressed"
check "...within a few seconds of the timeout"       test $((t1 - t0)) -le 12
docker compose exec -d -T crackattack sh -c "(sleep 600) | $SSH play@127.0.0.1 > /dev/null 2>&1"
sleep 3
check "a game is running for the connected player"   running crackattack-terminal
inbox pkill -9 -x ssh
check "a dropped connection ends the game"           absent_within crackattack-terminal 10

echo "== the number of players (MAX_PLAYERS=2)"
MAX_PLAYERS=2 IDLE_TIMEOUT=30 docker compose up -d --force-recreate > /dev/null 2>&1
wait_sshd
for n in 1 2; do
    docker compose exec -d -T crackattack sh -c "(sleep 600) | $SSH play@127.0.0.1 > /dev/null 2>&1"
    sleep 2
done
check "two games are running"                         test "$(inbox pgrep -c -f '^/usr/local/bin/crackattack-terminal')" = 2
OUT=$(play_after 2 play@127.0.0.1)
check "a third player is told the server is full"     has "server is full"
check "...and no third game was started"              test "$(inbox pgrep -c -f '^/usr/local/bin/crackattack-terminal')" = 2
inbox pkill -9 -x ssh
check "the games end with the connections"            absent_within crackattack-terminal 10
OUT=$(play_after 2 play@127.0.0.1)
check "a place is free again"                         has "Game stopped"

echo "== the keys given in AUTHORIZED_KEYS"
unset AUTH_MODE
AUTHORIZED_KEYS="$(cat "$WORK/good.pub")" docker compose up -d --force-recreate > /dev/null 2>&1
wait_sshd
put_keys
OUT=$(inbox sh -c "$SSH play@127.0.0.1 2>&1" < /dev/null)
check "no key: refused"                               has "Permission denied"
OUT=$(play_after 2 -i /tmp/bad play@127.0.0.1)
check "another key: refused"                          has "Permission denied"
OUT=$(play_after 2 -i /tmp/good play@127.0.0.1)
check "the listed key: the game runs"                 has "Game stopped"

echo
if [ "$FAILED" -eq 0 ]; then echo "all checks passed"; else echo "$FAILED check(s) failed"; fi
exit "$FAILED"
