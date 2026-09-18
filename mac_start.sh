#!/bin/bash
#
# Set up and start Micronomy locally on macOS.
#
# Installs Rakudo via Homebrew, bootstraps zef, installs the Raku
# modules required by META6.json, then starts the service over plain
# HTTP on an unprivileged port. Safe to re-run - every step is skipped
# once it's already satisfied.
#
set -euo pipefail

scriptdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$scriptdir"

port=${MICRONOMY_PORT:-8080}
host=${MICRONOMY_HOST:-127.0.0.1}

usage() {
    echo "usage: $0 [--port <int>] [--host <address>]" >&2
    exit 1
}

while test $# -gt 0
do
    case $1 in
        -p|--port) port=$2; shift;;
        -h|--host) host=$2; shift;;
        *) usage;;
    esac
    shift
done

info() { echo "==> $*"; }

command -v brew >/dev/null 2>&1 || {
    echo "ERROR: Homebrew is required - install it from https://brew.sh first" >&2
    exit 1
}

# Rakudo (Raku + MoarVM), as a precompiled Homebrew bottle - much faster
# than building from source via rakubrew, and avoids the qemu/emulation
# issues seen when compiling for Cro under Docker on Apple Silicon.
if ! brew list --formula rakudo >/dev/null 2>&1
then
    info "Installing Rakudo via Homebrew"
    brew install rakudo
fi

rakudo_prefix=$(brew --prefix rakudo)
export PATH="$rakudo_prefix/bin:$rakudo_prefix/share/perl6/site/bin:$PATH"

# zef (Raku's package manager) has no Homebrew formula, so bootstrap it
# straight from source.
if ! command -v zef >/dev/null 2>&1
then
    info "Bootstrapping zef"
    zefsrc=$(mktemp -d)
    git clone --quiet https://github.com/ugexe/zef.git "$zefsrc"
    (cd "$zefsrc" && raku -I. bin/zef install .)
    rm -rf "$zefsrc"
fi

# Modules required by META6.json. Cro::HTTP and Cro::WebApp are
# namespaces with no module of that exact name, so `raku -M` can't see
# them even when installed - check zef's install list first and only
# fall back to `raku -M` for plain modules like Digest::MD5, which
# ships as part of Rakudo itself and never shows up in that list.
installed_dists=$(zef list --installed 2>/dev/null || true)
modules=(Cro::HTTP Cro::WebApp URI::Encode Digest::MD5)
missing=()
for module in "${modules[@]}"
do
    echo "$installed_dists" | grep -q "^${module}:" && continue
    raku -M"$module" -e '' >/dev/null 2>&1 || missing+=("$module")
done

if test ${#missing[@]} -gt 0
then
    info "Installing missing Raku modules: ${missing[*]}"
    zef install --serial "${missing[@]}"
fi

info "Starting Micronomy at http://$host:$port"
export MICRONOMY_PORT=$port
export MICRONOMY_HOST=$host
exec raku -I lib service.raku
