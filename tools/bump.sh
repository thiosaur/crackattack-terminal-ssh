#!/bin/sh
# Pins a Crack Attack! release in .env: version, archive and the checksum read from the
# release's SHA256SUMS.
#
#   tools/bump.sh 2.0.0-beta.7 [linux-x86_64-static | linux-x86_64]
set -eu

VERSION=${1:?usage: tools/bump.sh <version> [archive]}
ARCHIVE=${2:-linux-x86_64-static}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

SUMS=$(curl -fsSL "https://github.com/thiosaur/crackattack/releases/download/v$VERSION/SHA256SUMS") \
    || { echo "no SHA256SUMS in release v$VERSION (published? built by a version that writes it?)" >&2; exit 1; }
NAME="crackattack-terminal-$VERSION-$ARCHIVE.tar.gz"
SHA=$(printf '%s\n' "$SUMS" | awk -v n="$NAME" '$2 == n { print $1 }')
[ -n "$SHA" ] || { echo "$NAME is not in the SHA256SUMS of v$VERSION" >&2; exit 1; }

cat > "$ROOT/.env" <<EOC
# Which release of Crack Attack! goes into the image. Written by tools/bump.sh from the
# SHA256SUMS of the release: do not edit the checksum by hand.
CRACKATTACK_VERSION=$VERSION
CRACKATTACK_ARCHIVE=$ARCHIVE
CRACKATTACK_SHA256=$SHA
EOC
echo "pinned $NAME ($SHA)"
