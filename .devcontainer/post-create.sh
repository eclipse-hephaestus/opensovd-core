#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Contributors to the Eclipse Foundation
# SPDX-License-Identifier: Apache-2.0
#
# Dev container provisioning: installs Nix (single-user), direnv/nix-direnv and
# warms the project environment via `uv sync`.
#
# Corporate networks: optional proxy and CA settings can be supplied, either as
# flags in devcontainer.json's postCreateCommand, or via environment variables.
# When none are given, the script runs a clean, generic setup (no proxy/CA step).
#
# Usage:
#   bash .devcontainer/post-create.sh [options]
#
# Options (all optional):
#   --proxy <url>           HTTP/HTTPS proxy URL (sets http(s)_proxy).
#   --no-proxy <list>       Comma-separated no_proxy list.
#   --ca-bundle-url <url>   URL of a corporate CA bundle to download and trust.
#   -h, --help              Show this help and exit.
#
# Environment fallbacks (used only when the matching flag is absent):
#   HTTP_PROXY / HTTPS_PROXY, NO_PROXY, CA_BUNDLE_URL
set -euo pipefail

cd "$(dirname "$0")/.."

PROXY_URL=""
NO_PROXY_LIST=""
CA_BUNDLE_URL_ARG=""

usage() {
  sed -n '2,/^# *HTTP_PROXY/p' "$0" | sed 's/^# \{0,1\}//; s/^#//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --proxy)          PROXY_URL="${2:-}"; shift 2 ;;
    --no-proxy)       NO_PROXY_LIST="${2:-}"; shift 2 ;;
    --ca-bundle-url)  CA_BUNDLE_URL_ARG="${2:-}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# Flags take precedence; otherwise fall back to the environment.
PROXY_URL="${PROXY_URL:-${HTTP_PROXY:-${https_proxy:-}}}"
NO_PROXY_LIST="${NO_PROXY_LIST:-${NO_PROXY:-${no_proxy:-}}}"
CA_BUNDLE_URL_ARG="${CA_BUNDLE_URL_ARG:-${CA_BUNDLE_URL:-}}"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

# ---------------------------------------------------------------------------
# Optional corporate network setup. Must run before any tool download so the
# proxy and corporate CA are in place first. Skipped entirely when unset.
# ---------------------------------------------------------------------------
CA_CERT_DIR="/etc/ssl/certs"
CA_BUNDLE="${CA_CERT_DIR}/ca-certificates.crt"

if [ -n "$PROXY_URL" ] || [ -n "$NO_PROXY_LIST" ]; then
  export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
  export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
  export NO_PROXY="${NO_PROXY_LIST:-localhost,127.0.0.1,::1}"
  export no_proxy="$NO_PROXY"
fi

if [ -n "$CA_BUNDLE_URL_ARG" ]; then
  export SSL_CERT_DIR="$CA_CERT_DIR"
  export NODE_EXTRA_CA_CERTS="$CA_BUNDLE"
  export REQUESTS_CA_BUNDLE="$CA_BUNDLE"
  export CURL_CA_BUNDLE="$CA_BUNDLE"
  export GIT_SSL_CAINFO="$CA_BUNDLE"

  tmp_bundle="$(mktemp)"
  # The proxy's CA is not trusted yet, so bootstrap the download with -k.
  if curl -fsSLk "$CA_BUNDLE_URL_ARG" -o "$tmp_bundle" && grep -q "BEGIN CERTIFICATE" "$tmp_bundle"; then
    split_dir="$(mktemp -d)"
    awk -v dir="$split_dir" '
      { print > (dir "/corp-ca-" n ".crt") }
      /-----END CERTIFICATE-----/ { close(dir "/corp-ca-" n ".crt"); n++ }
    ' < "$tmp_bundle"
    $SUDO cp "$split_dir"/corp-ca-*.crt /usr/local/share/ca-certificates/
    $SUDO update-ca-certificates || true
    rm -rf "$split_dir"
    rm -f "$tmp_bundle"
  else
    # A CA bundle was explicitly requested but could not be fetched. Fail fast:
    # continuing would only hit confusing TLS errors on the next download.
    rm -f "$tmp_bundle"
    echo "ERROR: could not download the CA bundle from ${CA_BUNDLE_URL_ARG}." >&2
    echo "       If you are behind a proxy, ensure the CA host is reachable and" >&2
    echo "       that --no-proxy covers it (e.g. the host's domain)." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Tool installation (Nix, direnv, project environment).
# ---------------------------------------------------------------------------

# The /nix named volume is created root-owned; single-user Nix needs it writable.
if [ ! -w /nix ]; then
  $SUDO chown -R "$(id -u):$(id -g)" /nix
fi

# Install single-user Nix only once; the /nix volume persists across rebuilds.
if ! command -v nix >/dev/null 2>&1 && [ ! -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
  curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon
fi

# Make nix available in this script and in future interactive shells.
if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi

# Install direnv + nix-direnv into the Nix profile.
if ! command -v direnv >/dev/null 2>&1; then
  nix --extra-experimental-features "nix-command flakes" \
    profile install nixpkgs#direnv nixpkgs#nix-direnv
fi

# Nix + direnv setup: wire nix-direnv and allow the project's .envrc.
nix_direnv="$HOME/.nix-profile/share/nix-direnv/direnvrc"
mkdir -p "$HOME/.config/direnv"
if [ -f "$nix_direnv" ]; then
  echo "source $nix_direnv" > "$HOME/.config/direnv/direnvrc"
fi

direnv allow .

# Warm the store and create the venv through the project's direnv environment.
direnv exec . uv sync --locked

# Replace the base image's legacy pre-commit shim with the project's Nix-provided prek hook.
direnv exec . prek install -f --hook-type pre-commit

# ---------------------------------------------------------------------------
# Persist shell setup for interactive terminals.
# ---------------------------------------------------------------------------
{
  if [ -n "$PROXY_URL" ] || [ -n "$NO_PROXY_LIST" ]; then
    echo "export HTTP_PROXY='$PROXY_URL' HTTPS_PROXY='$PROXY_URL'"
    echo "export http_proxy='$PROXY_URL' https_proxy='$PROXY_URL'"
    echo "export NO_PROXY='${NO_PROXY_LIST:-localhost,127.0.0.1,::1}' no_proxy='${NO_PROXY_LIST:-localhost,127.0.0.1,::1}'"
  fi
  if [ -n "$CA_BUNDLE_URL_ARG" ]; then
    echo "export SSL_CERT_DIR='$CA_CERT_DIR'"
    echo "export NODE_EXTRA_CA_CERTS='$CA_BUNDLE' REQUESTS_CA_BUNDLE='$CA_BUNDLE'"
    echo "export CURL_CA_BUNDLE='$CA_BUNDLE' GIT_SSL_CAINFO='$CA_BUNDLE'"
  fi
} >> "$HOME/.bashrc"

cat >> "$HOME/.bashrc" <<'EOF'
# Load Nix (single-user) and the direnv shell hook for interactive shells.
if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
  . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook bash)"
EOF
