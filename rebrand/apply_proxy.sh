#!/usr/bin/env bash
#
# apply_proxy.sh
#
# Pre-ADD our MTProto faketls proxy (our front for gramsrv) to a FRESH install,
# but seed it DISABLED / INACTIVE. The user can enable it manually in
# Settings -> Data and Storage -> Proxy.
#
# WHY DISABLED (transport correctness — do NOT flip back to enabled without
# fixing the proxy relay first):
#   The seeded secret below is ee-prefixed => MTProxySecretType2 (faketls). When
#   a proxy with a Type1/Type2 secret is the ACTIVE server, MtProtoKit sets
#   _mtpSecret != nil and forces _useIntermediateFormat = true
#   (submodules/MtProtoKit/Sources/MTTcpConnection.m:926-929), i.e. the client
#   switches its DC transport from obfuscated ABRIDGED (0xefefefef) to
#   PADDED-INTERMEDIATE (0xdddddddd, MTTcpConnection.m:1231-1235) AND routes
#   every connection through the proxy instead of directly to our DC on :2398.
#   Our gramsrv edge (telesrv, Codec=nil auto-detect) accepts obfuscated
#   abridged directly (this is exactly what the release-12.9.2 build used and
#   logged in fine). With the proxy ACTIVE the edge instead sees padded-
#   intermediate frames it cannot cleanly decode ("read padded intermediate:
#   invalid transport message length ...") and drops the connection -> login
#   fails on device. Seeding the proxy DISABLED keeps the fresh install on the
#   proven direct obfuscated-abridged path to :2398.
#
# Proxy: host 2.26.123.219, port 443, MTProto secret (ee-prefixed faketls,
# secret+SNI cdn.un1quedev.lol):
#   eef046f7666491c563142f024bd2c82c3c63646e2e756e317175656465762e6c6f6c
#
# How the app applies a proxy (verified):
#   Account.swift:1487-1493 subscribes to SharedDataKeys.proxySettings and pushes
#   `effectiveActiveServer` (activeServer iff enabled) into the network. It only
#   acts when a STORED proxySettings entry exists -- a fresh install (no entry)
#   gets no proxy. So we must PERSIST a seed, not just change a default.
#
# Injection point (single, one-time): the startup accountManager transaction in
#   submodules/TelegramUI/Sources/AppDelegate.swift:1195
#     return accountManager.transaction { transaction -> (SharedApplicationContext, LoggingSettings) in
#       return (sharedApplicationContext, transaction.getSharedData(SharedDataKeys.loggingSettings)?...)
#     }
# We insert a seed at the top of that closure. Idempotency/no-clobber guard:
#   `if transaction.getSharedData(SharedDataKeys.proxySettings) == nil { ... }`
# i.e. seed ONLY when no proxy entry has ever been written. Once the entry
# exists -- even after the user disables it or removes all servers -- the guard
# is false and we never re-seed, so the user's own config is preserved.
#
# APIs used (all verified in-tree, all reachable from AppDelegate.swift which
# imports TelegramCore + Postbox):
#   * dataWithHexString(_:) -> Data        Account.swift:613 (the existing hex
#     decoder; the tg://proxy secret is stored as these raw bytes in
#     ProxyServerConnection.mtp(secret:) -> MTSocksProxySettings(secret:)).
#   * ProxyServerSettings(host:port:connection:) / .mtp(secret:)  SyncCore_ProxySettings.swift:39/5
#   * ProxySettings(enabled:servers:activeServer:useForCalls:)    SyncCore_ProxySettings.swift:83
#   * transaction.getSharedData: (ValueBoxKey) -> PreferencesEntry?              AccountManagerImpl.swift:20
#   * transaction.updateSharedData: (ValueBoxKey,(PreferencesEntry?)->PreferencesEntry?)->Void  :21
#   * PreferencesEntry(_:)                  used at Settings/ProxySettings.swift:29
#   * SharedDataKeys.proxySettings          used at AppDelegate.swift:1196 (loggingSettings sibling)
#
# FAILS LOUD: anchor must match exactly once. Idempotent marker.
#
set -euo pipefail

find_root() {
    local candidates=()
    [ -n "${GITHUB_WORKSPACE:-}" ] && candidates+=("$GITHUB_WORKSPACE")
    candidates+=("$(pwd)")
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while [ "$d" != "/" ]; do
        candidates+=("$d")
        d="$(dirname "$d")"
    done
    for c in "${candidates[@]}"; do
        if [ -f "$c/submodules/TelegramUI/Sources/AppDelegate.swift" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
    if ! REPO_ROOT="$(find_root)"; then
        echo "ERROR: could not locate Telegram-iOS repo root (need submodules/TelegramUI/Sources/AppDelegate.swift)." >&2
        exit 1
    fi
fi

TARGET="$REPO_ROOT/submodules/TelegramUI/Sources/AppDelegate.swift"
if [ ! -f "$TARGET" ]; then
    echo "ERROR: target file not found: $TARGET" >&2
    exit 1
fi

MARKER="CoreGram: seed our default MTProto proxy"

if grep -qF "$MARKER" "$TARGET"; then
    echo "Already patched (proxy seed present). Nothing to do."
    exit 0
fi

# --- Sanity: imports present ------------------------------------------------
for imp in TelegramCore Postbox; do
    if ! grep -q "^import $imp" "$TARGET"; then
        echo "ERROR: 'import $imp' not found in $TARGET (needed for proxy seed types)." >&2
        exit 1
    fi
done

# --- Verify anchor exactly once ---------------------------------------------
ANCHOR='return accountManager.transaction { transaction -> (SharedApplicationContext, LoggingSettings) in'
COUNT="$(grep -cF "$ANCHOR" "$TARGET" || true)"
if [ "$COUNT" != "1" ]; then
    echo "ERROR: expected exactly 1 occurrence of startup-transaction anchor, found $COUNT." >&2
    echo "       Upstream code changed -- refusing to patch." >&2
    exit 1
fi

echo "=== BEFORE ==="
grep -n -A1 "$ANCHOR" "$TARGET"

# --- Insert the seed at the top of the transaction closure ------------------
perl -0777 -pi -e '
my $block = <<"BLOCK";
                // CoreGram: seed our default MTProto proxy on a clean install (only when none is
                // stored yet). Idempotent + non-clobbering: once a proxy entry exists -- even after
                // the user enables/disables it or removes all servers -- this never re-seeds.
                // Seeded DISABLED + activeServer: nil on purpose: an ACTIVE Type1/Type2 (ee/dd)
                // secret forces MtProtoKit onto padded-intermediate + proxy routing and breaks the
                // direct obfuscated-abridged login to our DC :2398 (see header). Leave it inactive
                // so the fresh install uses the proven direct transport; the user can enable it.
                if transaction.getSharedData(SharedDataKeys.proxySettings) == nil {
                    let coreGramProxySecret = dataWithHexString("eef046f7666491c563142f024bd2c82c3c63646e2e756e317175656465762e6c6f6c")
                    let coreGramProxyServer = ProxyServerSettings(host: "2.26.123.219", port: 443, connection: .mtp(secret: coreGramProxySecret))
                    transaction.updateSharedData(SharedDataKeys.proxySettings, { _ in
                        return PreferencesEntry(ProxySettings(enabled: false, servers: [coreGramProxyServer], activeServer: nil, useForCalls: false))
                    })
                }
BLOCK
my $n = 0;
$n += s{(\ +return accountManager\.transaction \{ transaction -> \(SharedApplicationContext, LoggingSettings\) in\n)}{$1$block}g;
die "ERROR: proxy-seed insertion matched $n (expected 1)\n" unless $n == 1;
' "$TARGET"

# --- Post-conditions --------------------------------------------------------
if ! grep -qF "$MARKER" "$TARGET"; then
    echo "ERROR: proxy seed did not land." >&2
    exit 1
fi
for needle in \
    'dataWithHexString("eef046f7666491c563142f024bd2c82c3c63646e2e756e317175656465762e6c6f6c")' \
    'ProxyServerSettings(host: "2.26.123.219", port: 443, connection: .mtp(secret: coreGramProxySecret))' \
    'if transaction.getSharedData(SharedDataKeys.proxySettings) == nil {' \
    'ProxySettings(enabled: false, servers: [coreGramProxyServer], activeServer: nil, useForCalls: false)'; do
    if ! grep -qF "$needle" "$TARGET"; then
        echo "ERROR: expected seeded line missing: $needle" >&2
        exit 1
    fi
done

echo "=== AFTER ==="
grep -n -A11 "$MARKER" "$TARGET" | head -13

echo "OK: patched $TARGET"
