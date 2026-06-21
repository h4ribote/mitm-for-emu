#!/usr/bin/env bash
#
# start-mitmproxy.sh
# ------------------
# Start mitmproxy in Docker (Linux / macOS / WSL).
#
# On first run a full set of CA files is generated under ./certs :
#   - certs/mitmproxy-ca-cert.pem  : CA certificate for Android (PEM)
#   - certs/mitmproxy-ca-cert.cer  : same, for user-certificate install (DER-compatible)
#   - certs/mitmproxy-ca.pem       : certificate INCLUDING the private key (keep secret)
#
# For the Android emulator proxy setup and how to install the CA as a
# system-level certificate, see android-system-cert-setup.md.
#
# Usage:
#   ./start-mitmproxy.sh           # mitmweb (with Web UI) [default]
#   ./start-mitmproxy.sh web       # mitmweb
#   ./start-mitmproxy.sh proxy     # mitmproxy (TUI)
#   ./start-mitmproxy.sh dump      # mitmdump (headless)
#
# Configuration is read from ./.env (copy .env.example to .env). Supported keys:
#   MITM_PROXY_USER  proxy auth username        (default mitmproxy)
#   MITM_PROXY_PASS  proxy auth password        (empty = no authentication)
#   MITMWEB_PASSWORD mitmweb Web UI password    (empty = random token; web mode)
#   PROXY_PORT       proxy listen port          (default 8080)
#   WEB_PORT         Web UI port                (default 8081)
#   CERT_DIR         certificate output dir     (default ./certs)
#   IMAGE            Docker image               (default mitmproxy/mitmproxy)
# Any value already set in the environment overrides the .env file.

set -euo pipefail

# --- settings ----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env if present (existing environment variables take precedence).
if [ -f "${SCRIPT_DIR}/.env" ]; then
  while IFS= read -r _line || [ -n "${_line}" ]; do
    case "${_line}" in
      ''|\#*) continue ;;            # skip blank lines and comments
    esac
    _key="${_line%%=*}"
    _val="${_line#*=}"
    _key="$(printf '%s' "${_key}" | tr -d '[:space:]')"
    [ -z "${_key}" ] && continue
    # strip surrounding single/double quotes from the value, if any
    case "${_val}" in
      \"*\") _val="${_val#\"}"; _val="${_val%\"}" ;;
      \'*\') _val="${_val#\'}"; _val="${_val%\'}" ;;
    esac
    # only set if not already defined in the environment
    if [ -z "$(eval "printf '%s' \"\${${_key}:-}\"")" ]; then
      eval "${_key}=\${_val}"
    fi
  done < "${SCRIPT_DIR}/.env"
fi

MODE="${1:-web}"
PROXY_PORT="${PROXY_PORT:-8080}"
WEB_PORT="${WEB_PORT:-8081}"
CERT_DIR="${CERT_DIR:-${SCRIPT_DIR}/certs}"
IMAGE="${IMAGE:-mitmproxy/mitmproxy}"
MITM_PROXY_USER="${MITM_PROXY_USER:-mitmproxy}"
MITM_PROXY_PASS="${MITM_PROXY_PASS:-}"
MITMWEB_PASSWORD="${MITMWEB_PASSWORD:-}"
CONTAINER_NAME="mitmproxy-emu"

# --- prerequisite checks -----------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] docker not found. Please install Docker." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "[ERROR] Cannot reach the Docker daemon. Please start Docker Desktop / dockerd." >&2
  exit 1
fi

# Prepare the certificate output directory.
# (The mitmproxy container runs as UID 1000, so make it writable.)
mkdir -p "${CERT_DIR}"
chmod 777 "${CERT_DIR}" 2>/dev/null || true

# Remove any leftover container with the same name.
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
fi

# --- decide launch command ---------------------------------------------
WEB_AUTH_STATUS="n/a"
case "${MODE}" in
  web)
    APP_CMD=(mitmweb --web-host 0.0.0.0 --web-port "${WEB_PORT}" --listen-port "${PROXY_PORT}")
    if [ -n "${MITMWEB_PASSWORD}" ]; then
      APP_CMD+=(--set "web_password=${MITMWEB_PASSWORD}")
      WEB_AUTH_STATUS="enabled (password from .env)"
    else
      WEB_AUTH_STATUS="disabled (random token printed in logs)"
    fi
    INTERACTIVE="-d"   # Web UI: run detached in the background
    ;;
  proxy)
    APP_CMD=(mitmproxy --listen-port "${PROXY_PORT}")
    INTERACTIVE="-it"  # TUI: run in the foreground
    ;;
  dump)
    APP_CMD=(mitmdump --listen-port "${PROXY_PORT}")
    INTERACTIVE="-it"
    ;;
  *)
    echo "[ERROR] unknown mode: ${MODE} (use: web | proxy | dump)" >&2
    exit 1
    ;;
esac

# connection_strategy=lazy: wait for the client TLS ClientHello (SNI) before
# connecting upstream. Required for transparent/redsocks setups where the
# CONNECT target is a raw IP (the real hostname is only in the SNI).
APP_CMD+=(--set "connection_strategy=lazy")

# Enable proxy authentication when a password is configured.
AUTH_STATUS="disabled"
if [ -n "${MITM_PROXY_PASS}" ]; then
  APP_CMD+=(--set "proxyauth=${MITM_PROXY_USER}:${MITM_PROXY_PASS}")
  AUTH_STATUS="enabled (user: ${MITM_PROXY_USER})"
fi

# --- run ---------------------------------------------------------------
echo "==================================================================="
echo " Starting mitmproxy"
echo "   mode        : ${MODE}"
echo "   proxy port  : ${PROXY_PORT}"
[ "${MODE}" = "web" ] && echo "   Web UI      : http://127.0.0.1:${WEB_PORT}"
[ "${MODE}" = "web" ] && echo "   Web UI auth : ${WEB_AUTH_STATUS}"
echo "   proxy auth  : ${AUTH_STATUS}"
echo "   cert dir    : ${CERT_DIR}"
echo "   docker image: ${IMAGE}"
echo "==================================================================="

PORT_ARGS=(-p "${PROXY_PORT}:${PROXY_PORT}")
[ "${MODE}" = "web" ] && PORT_ARGS+=(-p "${WEB_PORT}:${WEB_PORT}")

# shellcheck disable=SC2086
docker run --rm ${INTERACTIVE} \
  --name "${CONTAINER_NAME}" \
  "${PORT_ARGS[@]}" \
  -v "${CERT_DIR}:/home/mitmproxy/.mitmproxy" \
  "${IMAGE}" \
  "${APP_CMD[@]}"

if [ "${MODE}" = "web" ]; then
  echo
  echo "Started in the background."
  echo "  logs   : docker logs -f ${CONTAINER_NAME}"
  echo "  stop   : docker stop ${CONTAINER_NAME}"
  echo "  Web UI : http://127.0.0.1:${WEB_PORT}"
  if [ -n "${MITMWEB_PASSWORD}" ]; then
    echo "  (Web UI is password-protected; enter the password or use ?token=<password>)"
  fi
fi
