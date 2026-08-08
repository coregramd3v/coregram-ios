#!/usr/bin/env bash
#
# apply_stealth.sh
#
# Adds a client-side "Stealth Mode" (ghost mode) to Telegram-iOS
# (tag release-12.9.2): when ON, the client stops revealing the user's
# activity by suppressing these outgoing RPCs at a single choke point:
#   - read receipts:  messages.readHistory / channels.readHistory
#                     messages.readMessageContents / channels.readMessageContents
#                     messages.readEncryptedHistory
#   - online status:  account.updateStatus
#   - typing/activity: messages.setTyping / messages.setEncryptedTyping
#   - story views:    stories.readStories / stories.incrementStoryViews
#
# Mechanism: every one of these originates as `network.request(Api.functions.X)`.
# ALL of them funnel through Network.request<T>(_:) in
#   submodules/TelegramCore/Sources/Network/Network.swift
# The tuple's first element is a FunctionDescription whose `.name` is the TL
# method name (e.g. "messages.readHistory"). We gate on that name: when stealth
# is enabled and the method is in the blocklist, the request becomes a no-op
# (returns .complete() -> completes cleanly, so managed operation queues clear
# the op and never resend, and no packet ever hits the wire).
#
# The toggle is a single global boolean CoreGramStealthMode.isEnabled, backed by
# UserDefaults (survives relaunch, read once into memory; the network hot-path
# only reads the in-memory value). It defaults to false, so an unconfigured
# build behaves exactly like stock. Set `CoreGramStealthMode.isEnabled = true`
# from a Settings/Debug row (see wiring note at bottom of this script) to enable.
#
# FAILS LOUD: if the anchor is not found exactly once, exits 1.
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
        if [ -f "$c/submodules/TelegramCore/Sources/Network/Network.swift" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
    if ! REPO_ROOT="$(find_root)"; then
        echo "ERROR: could not locate Telegram-iOS repo root (need submodules/TelegramCore/Sources/Network/Network.swift)." >&2
        exit 1
    fi
fi

NETWORK="$REPO_ROOT/submodules/TelegramCore/Sources/Network/Network.swift"
NEWFILE="$REPO_ROOT/submodules/TelegramCore/Sources/CoreGramStealthMode.swift"
if [ ! -f "$NETWORK" ]; then
    echo "ERROR: target file not found: $NETWORK" >&2
    exit 1
fi

MARKER="coregram stealth mode gate"

if grep -q "$MARKER" "$NETWORK" && [ -f "$NEWFILE" ]; then
    echo "Already patched ($MARKER present and $NEWFILE exists). Nothing to do."
    exit 0
fi

# --- 1. Drop in the toggle + blocklist (auto-globbed by TelegramCore/BUILD) --
cat > "$NEWFILE" <<'SWIFT'
import Foundation

// CoreGram Stealth ("ghost") Mode.
//
// When enabled, activity-revealing RPCs are suppressed at the single
// Network.request<T> choke point (see Network.swift). Defaults to false so an
// unconfigured build behaves exactly like stock Telegram.
public final class CoreGramStealthMode {
    private static let storageKey = "coregram_stealth_mode"

    // Backed by UserDefaults so the toggle survives relaunch. The value is
    // cached in memory (static stored properties are lazily initialised once);
    // the network hot-path reads only this in-memory value, never UserDefaults.
    public static var isEnabled: Bool = UserDefaults.standard.bool(forKey: CoreGramStealthMode.storageKey) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: CoreGramStealthMode.storageKey)
        }
    }
}

// TL method names that are turned into no-ops while stealth mode is ON.
// Matched against FunctionDescription.name of the outgoing request.
let coreGramStealthBlockedMethods: Set<String> = [
    "messages.readHistory",
    "messages.readMessageContents",
    "messages.readEncryptedHistory",
    "channels.readHistory",
    "channels.readMessageContents",
    "account.updateStatus",
    "messages.setTyping",
    "messages.setEncryptedTyping",
    "stories.readStories",
    "stories.incrementStoryViews",
]
SWIFT
echo "Wrote $NEWFILE"

# --- 2. Insert the gate at the top of Network.request<T>(_:) ----------------
if ! grep -q "$MARKER" "$NETWORK"; then
    ANCHOR='public func request<T>(_ data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>), tag: NetworkRequestDependencyTag? = nil, automaticFloodWait: Bool = true, onFloodWaitError: ((String) -> Void)? = nil) -> Signal<T, MTRpcError> {'
    COUNT="$(grep -cF "$ANCHOR" "$NETWORK" || true)"
    if [ "$COUNT" != "1" ]; then
        echo "ERROR: expected exactly 1 occurrence of Network.request<T> anchor, found $COUNT." >&2
        echo "       Upstream signature changed -- refusing to patch." >&2
        exit 1
    fi

    echo "=== BEFORE ==="
    grep -n -A1 "func request<T>(_ data:" "$NETWORK"

    perl -0777 -pi -e '
    my $count = 0;
    $count += s{
        (public\ func\ request<T>\(_\ data:\ \(FunctionDescription,\ Buffer,\ DeserializeFunctionResponse<T>\),\ tag:\ NetworkRequestDependencyTag\?\ =\ nil,\ automaticFloodWait:\ Bool\ =\ true,\ onFloodWaitError:\ \(\(String\)\ ->\ Void\)\?\ =\ nil\)\ ->\ Signal<T,\ MTRpcError>\ \{\n)
    }{$1        // --- coregram stealth mode gate ---
        // Ghost mode: turn activity-revealing RPCs into a clean no-op so nothing hits the wire.
        if CoreGramStealthMode.isEnabled && coreGramStealthBlockedMethods.contains(data.0.name) {
            return .complete()
        }
}gx;
    die "ERROR: gate substitution replaced $count sites (expected 1)\n" unless $count == 1;
    ' "$NETWORK"

    if ! grep -q "$MARKER" "$NETWORK"; then
        echo "ERROR: gate did not land in $NETWORK." >&2
        exit 1
    fi
    echo "=== AFTER ==="
    grep -n -A5 "$MARKER" "$NETWORK"
fi

echo "OK: patched $NETWORK (+ $NEWFILE)"
echo
echo "NOTE: build-safe and inert until the toggle is flipped. To expose a UI"
echo "      switch, add a row in DebugSettingsUI/Sources/DebugController.swift"
echo "      that sets CoreGramStealthMode.isEnabled (import TelegramCore)."
