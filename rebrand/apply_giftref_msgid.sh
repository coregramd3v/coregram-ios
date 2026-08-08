#!/usr/bin/env bash
#
# apply_giftref_msgid.sh
#
# Recover cached pre-fix star gifts: build a StarGiftReference from the MESSAGE
# id (not the peer) for USER-owned gifts, so gifts cached before the server-side
# fix can still be upgraded/transferred WITHOUT a cache reset.
#
# Background: messageActionStarGift used to (wrongly) carry `peer` for USER
# gifts. The client then builds StarGiftReference.peer(peerId, id: savedId),
# which serializes to Api.InputSavedStarGift.inputSavedStarGiftChat(peer,
# savedId) -> server returns STARGIFT_INVALID for a user gift. The msg-id form
# StarGiftReference.message(messageId) serializes to inputSavedStarGiftUser(msgId)
# which resolves correctly. Server is fixed for NEW gifts, but gifts received
# before the fix are cached client-side with the bad `.peer` reference; the user
# does NOT want a cache/reinstall reset.
#
# Fix: everywhere a saved/parsed gift reference is built as `.peer(peerId, id:)`,
# gate the `.peer` form on the owner peer being a CHANNEL. For a USER owner it
# falls through to the `.message(messageId:)` branch -> inputSavedStarGiftUser,
# which resolves regardless of the stale cached peer. Channel gifts keep `.peer`.
#
# Target: submodules/TelegramCore/Sources/TelegramEngine/Payments/StarGifts.swift
# Sites patched (verified; `Namespaces.Peer.CloudChannel` is a valid symbol,
# used elsewhere in TelegramCore):
#   * Site A ~3523 -- ProfileGiftsContext.State.StarGift.init?(apiSavedStarGift:)
#       the cached-list parser (payments.getSavedStarGifts). Structure:
#         if let savedId { self.reference = .peer(peerId: peerId, id: savedId) }
#         else if let msgId { ... self.reference = .message(...) ... }
#       -> gate the first branch on channel; user gifts use the msgId branch.
#   * Sites B (~3453, craft flow) & C (~1683, upgrade flow) -- identical shape:
#         if let peerId, let savedId { reference = .peer(peerId: peerId, id: savedId) }
#         else { reference = .message(messageId: messageId) }
#       -> add `, peerId.namespace == Namespaces.Peer.CloudChannel` so user gifts
#          take the `.message(messageId:)` else-branch (messageId is in scope).
# NOT touched: the Codable decode `self = .peer(peerId: try container.decode...)`
# (~3698) -- that deserializes an already-stored reference, not a construction.
#
# FAILS LOUD: Site A block must match exactly once; sites B+C must match exactly
# twice. Idempotent marker.
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
        if [ -f "$c/submodules/TelegramCore/Sources/TelegramEngine/Payments/StarGifts.swift" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
    if ! REPO_ROOT="$(find_root)"; then
        echo "ERROR: could not locate Telegram-iOS repo root (need submodules/TelegramCore/Sources/TelegramEngine/Payments/StarGifts.swift)." >&2
        exit 1
    fi
fi

TARGET="$REPO_ROOT/submodules/TelegramCore/Sources/TelegramEngine/Payments/StarGifts.swift"
if [ ! -f "$TARGET" ]; then
    echo "ERROR: target file not found: $TARGET" >&2
    exit 1
fi

MARKER="CoreGram: only CHANNEL gifts"

if grep -qF "$MARKER" "$TARGET"; then
    echo "Already patched (giftref msgid present). Nothing to do."
    exit 0
fi

# --- Verify anchor counts ---------------------------------------------------
A_CNT="$(perl -0777 -ne '$c=()=/[ ]+if let savedId \{\n[ ]+self\.reference = \.peer\(peerId: peerId, id: savedId\)\n/g; print $c' "$TARGET")"
BC_CNT="$(grep -cF "if let peerId, let savedId {" "$TARGET" || true)"
if [ "$A_CNT" != "1" ]; then echo "ERROR: Site A anchor matched $A_CNT (expected 1)." >&2; exit 1; fi
if [ "$BC_CNT" != "2" ]; then echo "ERROR: Sites B+C anchor matched $BC_CNT (expected 2)." >&2; exit 1; fi

echo "=== BEFORE ==="
grep -n "if let savedId {" "$TARGET"
grep -n "if let peerId, let savedId {" "$TARGET"

# --- Site A: gate the peer-reference branch on channel ----------------------
perl -0777 -pi -e '
my $repl = "            if let savedId, peerId.namespace == Namespaces.Peer.CloudChannel {\n                // CoreGram: only CHANNEL gifts keep the (peer, savedId) reference; USER gifts fall\n                // through to the msgId branch below -> inputSavedStarGiftUser (resolves stale-cached gifts).\n                self.reference = .peer(peerId: peerId, id: savedId)\n";
my $n = 0;
$n += s{[ ]+if let savedId \{\n[ ]+self\.reference = \.peer\(peerId: peerId, id: savedId\)\n}{$repl}g;
die "ERROR: Site A replaced $n (expected 1)\n" unless $n == 1;
' "$TARGET"

# --- Sites B & C: gate the peer-reference branch on channel -----------------
perl -0777 -pi -e '
my $tail = "if let peerId, let savedId, peerId.namespace == Namespaces.Peer.CloudChannel {";
my $n = 0;
$n += s{([ ]+)if let peerId, let savedId \{}{${1}$tail}g;
die "ERROR: Sites B+C replaced $n (expected 2)\n" unless $n == 2;
' "$TARGET"

# --- Post-conditions --------------------------------------------------------
if ! grep -qF "$MARKER" "$TARGET"; then
    echo "ERROR: Site A marker missing after patch." >&2
    exit 1
fi
GATED="$(grep -cF "peerId.namespace == Namespaces.Peer.CloudChannel" "$TARGET" || true)"
if [ "$GATED" != "3" ]; then
    echo "ERROR: expected 3 channel-gated references after patch, found $GATED." >&2
    exit 1
fi
# The ungated user-gift peer references must be gone (site A + B + C = 3 gated).
if [ "$(grep -cF "if let peerId, let savedId {" "$TARGET" || true)" != "0" ]; then
    echo "ERROR: an ungated 'if let peerId, let savedId {' remains." >&2
    exit 1
fi

echo "=== AFTER ==="
grep -n "peerId.namespace == Namespaces.Peer.CloudChannel" "$TARGET"

echo "OK: patched $TARGET"
