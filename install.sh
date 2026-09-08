#!/bin/sh
# Rhythma installer.
#
# One question — the URL people will reach this at — and everything else is generated. Run it
# on a fresh Debian or Ubuntu machine:
#
#   curl -fsSL https://rhythma-app.github.io/install/install.sh | sh -s -- --key <your licence>
#
# Re-running it is safe: it never touches ./data, and an Instance that is already installed is
# updated rather than replaced.
#
# `RHYTHMA_RELEASES` points at the published release index — GitHub Pages for the `install`
# repository, which needs no DNS of its own. Putting a custom domain in front of it is a CNAME
# and a change to this default; nothing else here knows the difference.
set -eu

INSTALL_DIR="${RHYTHMA_DIR:-/opt/rhythma}"
RELEASES="${RHYTHMA_RELEASES:-https://rhythma-app.github.io/install}"
# `REGISTRY` is not declared here on purpose. It is published beside VERSION rather than
# written into this script — so moving the service is a release and not an edit every customer
# has to make, and so this file names no host of ours — and it is fetched below, before the
# first thing that uses it. A placeholder here is what let it be used while still empty.
KEY=""

die() { printf '\nerror: %s\n' "$1" >&2; exit 1; }
say() { printf '%s\n' "$1"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --key) KEY="${2:-}"; shift 2 ;;
        --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done

# ---------------------------------------------------------------- preflight --
[ "$(id -u)" = "0" ] || die "run this as root (or with sudo): it installs into $INSTALL_DIR"
[ -n "$KEY" ] || die "a licence is required: curl -fsSL $RELEASES/install.sh | sh -s -- --key <your licence>"

. /etc/os-release 2>/dev/null || die "cannot identify this operating system"
case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) ;;
    *) die "only Debian and Ubuntu are supported; this is ${PRETTY_NAME:-unknown}" ;;
esac

MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[ "$MEM_MB" -ge 1900 ] || die "needs at least 2 GB of RAM; this machine has ${MEM_MB} MB"

DISK_MB=$(df -Pm / | awk 'NR==2 {print $4}')
[ "$DISK_MB" -ge 10000 ] || die "needs at least 10 GB free; / has ${DISK_MB} MB"

# ------------------------------------------------------------------ docker --
if ! command -v docker >/dev/null 2>&1; then
    say ""
    say "Docker is not installed on this machine."
    printf "Install it now? [Y/n] "
    read -r answer < /dev/tty || answer=""
    case "$answer" in
        [Nn]*) die "Docker is required. Install it and run this again." ;;
    esac
    curl -fsSL https://get.docker.com | sh || die "Docker installation failed"
fi

docker compose version >/dev/null 2>&1 || die "this Docker has no 'compose' plugin"

# ----------------------------------------------------------------- release --
# Before anything is written, because everything written below names one of these. `REGISTRY`
# in particular reaches `.env` on both paths, and fetching it afterwards wrote an empty one:
# compose then resolved `image: /api:1.2.3`, docker rejected the reference, and the installer
# blamed the licence — the one thing that was fine.
VERSION=$(curl -fsSL "$RELEASES/VERSION") || die "cannot reach $RELEASES"
[ -n "$VERSION" ] || die "$RELEASES/VERSION is empty"

REGISTRY=$(curl -fsSL "$RELEASES/REGISTRY") || die "cannot reach $RELEASES"
[ -n "$REGISTRY" ] || die "$RELEASES/REGISTRY is empty"

# ----------------------------------------------------------------- the URL --
mkdir -p "$INSTALL_DIR/data/postgres" "$INSTALL_DIR/data/minio"

# Stated, not inherited from whatever umask the operator's root shell has. Postgres 18's
# entrypoint re-execs as the `postgres` user and has to traverse this directory to reach the
# data it initialises inside it. Created under `umask 077` it is 0700 and root-owned, that
# user cannot enter it, and the install dies at `docker compose up` with "container
# rhythma-postgres-1 is unhealthy" — the reason visible only in the database's own log, as
# "mkdir: can't create directory '/var/lib/postgresql/18/': Permission denied". Observed on a
# real host. Nothing secret lives at this level: `.env` is written under `umask 077` below and
# the data directory Postgres creates inside this one is 0700 and its own.
chmod 755 "$INSTALL_DIR" "$INSTALL_DIR/data" "$INSTALL_DIR/data/postgres" "$INSTALL_DIR/data/minio"

cd "$INSTALL_DIR"

if [ -f .env ]; then
    # shellcheck disable=SC1091
    . ./.env
    say "Updating the Instance already installed here ($RHYTHMA_URL)."
    # Values this Instance predates. Appended rather than rewritten: everything else in here is
    # the operator's, including any edit they made deliberately.
    grep -q '^RHYTHMA_REGISTRY=' .env || printf 'RHYTHMA_REGISTRY=%s\n' "$REGISTRY" >> .env
    grep -q '^RHYTHMA_LICENCE=' .env || printf 'RHYTHMA_LICENCE=%s\n' "$KEY" >> .env
    grep -q '^RELEASE_SERVICE_URL=' .env || printf 'RELEASE_SERVICE_URL=https://%s\n' "$REGISTRY" >> .env
else
    say ""
    say "What URL will people reach this at?"
    say "Press Enter to run it on this machine only."
    printf "URL [http://localhost:8080]: "
    read -r RHYTHMA_URL < /dev/tty || RHYTHMA_URL=""
    [ -n "$RHYTHMA_URL" ] || RHYTHMA_URL="http://localhost:8080"

    case "$RHYTHMA_URL" in
        http://*|https://*) ;;
        *) die "the URL must start with http:// or https://" ;;
    esac

    RHYTHMA_PORT="${RHYTHMA_PORT:-8080}"
    secret() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

    umask 077
    cat > .env <<ENV
# Written by the installer. Edit a value and run 'rhythma restart'.
RHYTHMA_URL=$RHYTHMA_URL
RHYTHMA_PORT=$RHYTHMA_PORT
# Which address the port is published on. Loopback is right when TLS is terminated by
# something running on this machine. Change it to the docker bridge address (usually
# 172.17.0.1) if your reverse proxy is itself a container, and to 0.0.0.0 only if you
# genuinely mean to publish an Instance with nothing in front of it.
RHYTHMA_BIND=127.0.0.1
RHYTHMA_VERSION=
# Which watch builds that release ships. Not the same string: a watch build moves only when its
# own source changed (ADR-0016), so a release ordinarily ships an app older than itself. Written
# below, from the release's own published answer.
WEAR_APP_VERSION=
FLEET_AGENT_VERSION=
RHYTHMA_REGISTRY=$REGISTRY
# One artifact, three uses: it pulls the images, it identifies this Instance to the release
# service, and the dashboard reads its term without a network call (ADR-0013).
RHYTHMA_LICENCE=$KEY
RELEASE_SERVICE_URL=https://$REGISTRY
POSTGRES_PASSWORD=$(secret)
BETTER_AUTH_SECRET=$(secret)
S3_ACCESS_KEY_ID=rhythma
S3_SECRET_ACCESS_KEY=$(secret)
ENV
fi

# --------------------------------------------------------------------- key --
# The key is the licence. It used to be a registry token, which could not be scoped to one
# customer — GitHub refuses fine-grained tokens for its registry and a classic one reads every
# private package its account can see. So the licence became the credential, and revoking one
# revokes exactly one Instance. See the amendment in docs/adr/0011.
say ""
say "Signing in to $REGISTRY…"
printf '%s' "$KEY" | docker login "$REGISTRY" --username rhythma --password-stdin >/dev/null 2>&1 \
    || die "that licence was refused by $REGISTRY"

# Write a variable into `.env`, whether or not it is already there.
#
# `sed` alone silently does nothing when the line is absent, which is exactly the case that
# matters: an Instance installed before a variable existed has an `.env` without it, and an
# update that "wrote" it would leave compose interpolating an empty string. `api` then refuses
# to start, on a machine that was working a minute earlier.
set_env() {
    if grep -q "^$1=" .env; then
        sed -i "s|^$1=.*|$1=$2|" .env
    else
        printf '%s=%s\n' "$1" "$2" >> .env
    fi
}

curl -fsSL "$RELEASES/$VERSION/docker-compose.yml" -o docker-compose.yml \
    || die "cannot fetch the compose file for $VERSION"

# Which builds this release puts on a watch, published beside its compose file (ADR-0016).
#
# Fetched rather than derived, and fatal when missing: an Instance that cannot name the app it
# ships tells its watches nothing, which is a fleet that never converges and a screen that says
# so nowhere. `api` refuses to start without them for the same reason.
curl -fsSL "$RELEASES/$VERSION/builds.env" -o builds.env \
    || die "cannot fetch the builds for $VERSION"
APP_VERSION=$(sed -n 's/^WEAR_APP_VERSION=//p' builds.env)
AGENT_VERSION=$(sed -n 's/^FLEET_AGENT_VERSION=//p' builds.env)
[ -n "$APP_VERSION" ] && [ -n "$AGENT_VERSION" ] \
    || die "$RELEASES/$VERSION/builds.env does not name both watch builds"
set_env WEAR_APP_VERSION "$APP_VERSION"
set_env FLEET_AGENT_VERSION "$AGENT_VERSION"

# The version is written last, so an interrupted install does not claim to be on a release it
# never finished pulling.
set_env RHYTHMA_VERSION "$VERSION"

# The registry reaches compose through `.env`, not through this shell, so this asserts what
# was *written* rather than what was fetched — the distinction the ordering bug turned on.
grep -q '^RHYTHMA_REGISTRY=.\+$' .env || die "no registry in $INSTALL_DIR/.env — nothing can be pulled"

say ""
say "Pulling Rhythma $VERSION…"
# Not `--quiet`. This is the step that takes minutes on a domestic connection, and a silent
# one is indistinguishable from a hung one — which is when an operator kills it half-pulled.
docker compose pull || die "could not pull the images — is the licence still valid?"
docker compose up -d || die "the stack did not start"

# ------------------------------------------------------------------ verify --
say "Waiting for it to come up…"
# shellcheck disable=SC1091
. ./.env
i=0
until curl -fsS "http://127.0.0.1:$RHYTHMA_PORT/healthz" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || die "it did not answer within a minute — try 'rhythma logs'"
    sleep 1
done

# ------------------------------------------------------------------- admin --
if docker compose run --rm -T api rhythma-admin has-admin >/dev/null 2>&1; then
    say ""
    say "This Instance already has an administrator; leaving it alone."
else
    say ""
    say "Create the administrator account."
    printf "Email: "
    read -r ADMIN_EMAIL < /dev/tty

    # `stty` acts on its own stdin, and this script's stdin is the curl pipe it was fed
    # through — not a terminal. Without `< /dev/tty` it fails with "Inappropriate ioctl for
    # device", which `2>/dev/null || true` then swallowed, so the password was typed in the
    # clear on the one path that matters: the published one-liner.
    #
    # Turning echo off means it has to come back on however the script leaves, or the
    # operator is returned to a shell that types blind.
    restore_echo() { stty echo < /dev/tty 2>/dev/null || true; }
    trap 'restore_echo' EXIT INT TERM HUP
    stty -echo < /dev/tty || die "cannot turn off echo — refusing to read a password in the clear"
    printf "Password: "
    read -r ADMIN_PASSWORD < /dev/tty
    restore_echo
    trap - EXIT INT TERM HUP
    say ""

    docker compose run --rm -T \
        -e ADMIN_EMAIL="$ADMIN_EMAIL" -e ADMIN_PASSWORD="$ADMIN_PASSWORD" \
        api rhythma-admin create-admin || die "could not create the administrator"
fi

# --------------------------------------------------------------------- cli --
curl -fsSL "$RELEASES/rhythma" -o /usr/local/bin/rhythma && chmod +x /usr/local/bin/rhythma

say ""
say "Rhythma $VERSION is running."
say ""
say "  Open       $RHYTHMA_URL"
say "  Listening  127.0.0.1:$RHYTHMA_PORT — point your reverse proxy here"
say "  Manage     rhythma help"
say ""
