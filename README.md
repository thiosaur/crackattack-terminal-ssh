# Crack Attack! over ssh

A Docker image that serves the terminal version of
[Crack Attack!](https://github.com/thiosaur/crackattack) over ssh: connecting starts the game,
and nothing else is reachable.

```
ssh -p 2222 play@your-server
```

The image is only packaging. The game itself is downloaded from a release of the main
repository (one small executable) and checked against a pinned SHA-256 before it goes in.

## A personal server, not a public service

This image is meant for your own machine: a homelab, a home server, a few people you know.
**It is not designed to be offered to the public.** Nothing in it deals with load or abuse:
there is no limit per address, no queue, no banning. The only limit is a plain total, `MAX_PLAYERS`
games at once (10 by default), and the container's `pids_limit`, `mem_limit` and `cpus`, which
only keep a mistake from taking the host down. Keep the port on your own network, or behind a VPN.

That is why, with nothing configured, only the ssh keys already allowed on the host can play.

## Run it

```sh
docker compose up -d --build
```

With nothing else set, the image allows **the public keys of `~/.ssh/authorized_keys` on the
machine that runs docker**: whoever may already log in to that host may play, with the same key,
and nobody else. The file is mounted read-only and read at each login, so a key added to it or
removed from it counts at once. If the file does not exist, the container does not start.

```sh
# another file of public keys (a path on the machine that runs docker)
AUTHORIZED_KEYS_FILE=/srv/keys/players docker compose up -d --build

# the keys you give, instead of a file (one per line)
AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" docker compose up -d --build

# anyone who reaches the port, no password asked: only on a network you trust
AUTH_MODE=open AUTHORIZED_KEYS_FILE=/dev/null docker compose up -d --build
```

Open access is never chosen for you: it takes `AUTH_MODE=open`, and the container says so in
its log when it starts.

| Variable | Default | Meaning |
|---|---|---|
| `AUTH_MODE` | `keys` | `keys`, or `open` to let anyone in |
| `AUTHORIZED_KEYS_FILE` | `~/.ssh/authorized_keys` | file of allowed public keys, on the docker host |
| `AUTHORIZED_KEYS` | | allowed public keys given directly; replaces the file |
| `IDLE_TIMEOUT` | `300` | seconds without a key press before the game stops |
| `MAX_TIME` | `1800` | seconds of play per connection |
| `MAX_PLAYERS` | `10` | games at once; a further connection is told the server is full |
| `HOST_PORT` | `2222` | port published on the host |
| `BIND_ADDRESS` | `0.0.0.0` | address the port is published on; give your LAN address to keep it off other networks |

`IDLE_TIMEOUT`, `MAX_TIME` and `MAX_PLAYERS` must be positive whole numbers: anything else stops
the container at start, with a message, rather than failing every connection later.

With a remote docker engine (`docker context`), `~` is resolved on the machine where you type
the command: give `AUTHORIZED_KEYS_FILE` the path as it is on the engine's machine. An editor that
replaces the file instead of rewriting it leaves the container on the old one: restart it then.

The ssh host key is kept in the `host-keys` volume, so the fingerprint survives a rebuild.
It is printed in the container's log when it is created.

## What the account can do

- One account, `play`. Its login shell and the forced command are both a script that ignores what
  the client asked for (`ssh play@host ls`, `sftp`...) and starts the game.
- No forwarding of any kind (tcp, unix sockets, agent, X11, tunnels), no root login.
- After a lost game a new one starts (`--replay`); Q leaves. A player who stops pressing keys, or
  who plays too long, is disconnected. A dropped connection ends the game.
- A connection without a terminal (`ssh -T`, or a command given without `-t`) is refused with a
  message, and a connection beyond `MAX_PLAYERS` is told the server is full. The count is a plain
  one: two connections arriving in the same instant may both get in.
- The container has a read-only root file system, no capability beyond what sshd needs to switch
  to the `play` account, `no-new-privileges`, and limits on processes, memory and CPU
  (`compose.yml`).
- **Load.** Each connection runs a game at 50 images per second. Measured here with the clients
  inside the same container (so a slight overestimate): about 1.5 % of one CPU core, 5 MiB and
  5 processes per player, from 1 to 10 players (14 % of a core and 49 MiB for ten). Size
  `pids_limit`, `mem_limit`, `cpus` and `MAX_PLAYERS` for the number of players you expect.
- **Logs.** sshd logs each connection with the player's address. The container log is capped
  (3 files of 10 MB) so that it cannot fill the disk, and it is lost with the container.
- **Base and game.** The image is `debian:13-slim` (Debian 12 left regular security support in
  July 2026). The game is the static build, which needs no system library: the image does not
  depend on its base's libc.
- The terminal version draws in 80x24 when the player's terminal is short (it chooses by itself).

## Which release

`.env` pins the release (`CRACKATTACK_VERSION`, `CRACKATTACK_ARCHIVE`, `CRACKATTACK_SHA256`).
To move to a new one:

```sh
tools/bump.sh 2.0.0-beta.6                       # the static build; reads the checksum from SHA256SUMS
tools/bump.sh 2.0.0-beta.6 linux-x86_64          # the ordinary build instead (needs glibc 2.34 or later)
docker compose up -d --build
```

The options this image relies on (`--replay`, `--idle-timeout`, `--max-time`, the end of the game
when the connection drops) and `SHA256SUMS` come with the release after 2.0.0-beta.5: pin that one
or a later one.

## Test

```sh
test/smoke.sh                                  # the release pinned in .env
test/smoke.sh /path/to/crackattack/checkout    # the game built from a checkout, to try a change
```

It builds the image, starts it with the hardening of `compose.yml` and checks over ssh (from inside
the container, so it works with a remote docker engine): the game starts and Q ends it, a command
asked by the client does not run, a connection without a terminal is refused, another account is
refused, the effective sshd settings, the read-only file system, a static game, a bounded log, a
wrong setting that stops the start, the idle limit, a dropped connection, the cap on players, and
who gets in: with nothing set (the
host's file of keys, a key added and a key removed without a restart, no file at all), with
`AUTHORIZED_KEYS`, and with `AUTH_MODE=open`. It removes everything it created.

## Licence

The game is free software, GPL-3.0-or-later; the image carries `LICENSE`, `AUTHORS` and the
third-party notices under `/usr/share/doc/crackattack-terminal/`, and the ssh banner points to the
source. This repository uses the same licence (see `LICENSE`).
