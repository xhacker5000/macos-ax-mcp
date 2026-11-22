#!/usr/bin/env bash
# Deploy the universal (arm64 + x86_64) macos-ax-mcp binary to a remote Mac over SSH (e.g. an always-on agent node).
#
# Idempotent: re-running it is safe. If the remote binary's SHA-256 already matches, nothing is uploaded.
# Aborts before writing anything when the host is unreachable, below macOS 14, or not x86_64/arm64.
#
# Usage:
#   HOST=my_node scripts/deploy_remote.sh                # check -> push -> remote check-health
#   HOST=my_node scripts/deploy_remote.sh --check-only   # read-only: connectivity + version + current remote binary
#   HOST=my_node BIN=/path/to/macos-ax-mcp scripts/deploy_remote.sh
set -euo pipefail

HOST="${HOST:?set HOST to the SSH alias of the target Mac, e.g. HOST=my_node}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="${BIN:-$PROJECT_DIR/.build/apple/Products/Release/macos-ax-mcp}"
REMOTE_DIR='$HOME/.local/bin'            # expanded on the remote side
REMOTE_BIN="$REMOTE_DIR/macos-ax-mcp"
MIN_MAJOR=14
CHECK_ONLY=0
[[ "${1:-}" == "--check-only" ]] && CHECK_ONLY=1

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR "$HOST")

log()  { printf '[deploy] %s\n' "$*"; }
die()  { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

# 1. Local artifact sanity -------------------------------------------------------------------------
[[ -x "$BIN" ]] || die "binary not found: $BIN (build it: swift build -c release --arch arm64 --arch x86_64)"
ARCHS="$(lipo -archs "$BIN")"
[[ " $ARCHS " == *" x86_64 "* && " $ARCHS " == *" arm64 "* ]] || die "expected universal x86_64+arm64 binary, got: $ARCHS"
LOCAL_SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
log "local binary: $BIN [$ARCHS] sha256=$LOCAL_SHA"

# 2. Connectivity + OS version gate (read-only) ----------------------------------------------------
REMOTE_INFO="$("${SSH[@]}" 'uname -m; sw_vers -productVersion' 2>/dev/null)" \
    || die "$HOST unreachable (offline, rebooting, or SSH key not accepted)"
REMOTE_ARCH="$(sed -n 1p <<<"$REMOTE_INFO")"
REMOTE_VER="$(sed -n 2p <<<"$REMOTE_INFO")"
REMOTE_MAJOR="${REMOTE_VER%%.*}"
log "$HOST: arch=$REMOTE_ARCH macOS=$REMOTE_VER"

[[ "$REMOTE_MAJOR" =~ ^[0-9]+$ ]] || die "could not parse remote macOS version: '$REMOTE_VER'"
if (( REMOTE_MAJOR < MIN_MAJOR )); then
    die "$HOST runs macOS $REMOTE_VER; macos-ax-mcp requires macOS $MIN_MAJOR+ (Sonoma). Finish the upgrade first. Nothing was written."
fi
[[ "$REMOTE_ARCH" == "x86_64" || "$REMOTE_ARCH" == "arm64" ]] || die "unsupported remote arch: $REMOTE_ARCH"

REMOTE_SHA="$("${SSH[@]}" "if [ -f $REMOTE_BIN ]; then shasum -a 256 $REMOTE_BIN | awk '{print \$1}'; fi" || true)"
log "remote binary sha256=${REMOTE_SHA:-<none>}"

if (( CHECK_ONLY )); then
    log "--check-only: stopping before any write."
    exit 0
fi

# 3. Push (atomic: upload to temp file, then mv) ----------------------------------------------------
if [[ "$REMOTE_SHA" == "$LOCAL_SHA" ]]; then
    log "remote binary already up to date, skipping upload"
else
    "${SSH[@]}" "mkdir -p $REMOTE_DIR"
    "${SSH[@]}" "cat > $REMOTE_BIN.tmp.\$\$ && chmod 0755 $REMOTE_BIN.tmp.\$\$ && mv -f $REMOTE_BIN.tmp.\$\$ $REMOTE_BIN" < "$BIN"
    NEW_SHA="$("${SSH[@]}" "shasum -a 256 $REMOTE_BIN | awk '{print \$1}'")"
    [[ "$NEW_SHA" == "$LOCAL_SHA" ]] || die "checksum mismatch after upload (remote=$NEW_SHA)"
    log "uploaded and verified -> $HOST:~/.local/bin/macos-ax-mcp"
fi

# 4. Remote health check ---------------------------------------------------------------------------
log "remote check-health:"
set +e
"${SSH[@]}" "$REMOTE_BIN --cli check-health"
RC=$?
set -e
(( RC == 0 )) || die "remote check-health failed (exit $RC)"
log "done. If accessibility_trusted is false: on $HOST grant Accessibility to the host process shown in"
log "host_app_hint (for SSH sessions that is sshd / sshd-keygen-wrapper), or run it from a local Terminal there."
