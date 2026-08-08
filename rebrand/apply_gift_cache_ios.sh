#!/usr/bin/env bash
#
# apply_gift_cache_ios.sh
#
# CoreGram iOS fix for NFT / star-gift animation loading -- the iOS equivalent
# of the Android star-gift pinning fix. Root-cause investigation identified the
# hero (opened) gift animation re-decoding its frames on every open, which shows
# as a re-load / stutter each time a gift detail is opened.
#
# FIX 3a (APPLIED) -- reuse the shared animation-frame cache for the opened gift
# --------------------------------------------------------------------------
#   File: submodules/TelegramUI/Components/Gifts/GiftAnimationComponent/Sources/
#         GiftAnimationComponent.swift
#   The hero animation layer is built as an InlineStickerItemLayer with
#     unique: !component.still
#   `unique: true` forces a PRIVATE render cache for that layer, so the frames
#   the grid already rendered into the shared `/animation-cache` are ignored and
#   the sticker is re-decoded from scratch every time the gift is opened. The
#   GIFT GRID cell (GiftItemComponent.swift) already builds its layer with
#   `unique: false` and therefore hits the shared cache. We make the hero match:
#     unique: false
#   so the opened gift reuses the shared rendered frames instead of re-decoding.
#   loopCount / isVisibleForAnimations behaviour is untouched (they stay keyed
#   off component.still), so the still-vs-animated distinction is preserved --
#   only the cache bucket changes.
#
# FIX 3b (SKIPPED -- see note) -- eviction-resistance for model/pattern files
# --------------------------------------------------------------------------
#   The model/pattern resources are fetched as FREE resources
#     freeMediaFileResourceInteractiveFetched(account:, userLocation: .other,
#                                              fileReference: .standalone(media: file), ...)
#   in GiftItemComponent.swift (two identical call sites) and via
#   FetchMediaUtils.swift, so they live under the mediaBox total-size LRU and can
#   be swept -> re-download. There is NO clean, low-risk, uniquely-anchorable
#   edit for this on release-12.9.2:
#     * the fetch call string is IDENTICAL at two sites in GiftItemComponent.swift
#       (not a unique anchor), and the pattern spans three files;
#     * `.standalone(media:)` / `userLocation: .other` is the only reference these
#       call sites can form -- keeping the bytes out of the total-size sweep is a
#       property of the mediaBox reference/keep machinery, not an argument on the
#       fetch, so it would require broad structural changes to give these a
#       durable/gift-scoped reference.
#   Per the investigation brief we do NOT force it. 3a alone is a real
#   improvement (no re-decode on open); 3b is left as a documented follow-up.
#
# Layer stays at 228 -- this script does not touch the layer.
# Safe to run alongside the other apply_*.sh: it edits only
# GiftAnimationComponent.swift.
#
# FAILS LOUD: anchor must match exactly once, else exit 1. Idempotent marker.
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
        if [ -f "$c/submodules/TelegramUI/Components/Gifts/GiftAnimationComponent/Sources/GiftAnimationComponent.swift" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
    if ! REPO_ROOT="$(find_root)"; then
        echo "ERROR: could not locate Telegram-iOS repo root (need submodules/TelegramUI/Components/Gifts/GiftAnimationComponent/Sources/GiftAnimationComponent.swift)." >&2
        exit 1
    fi
fi

TARGET="$REPO_ROOT/submodules/TelegramUI/Components/Gifts/GiftAnimationComponent/Sources/GiftAnimationComponent.swift"
if [ ! -f "$TARGET" ]; then
    echo "ERROR: target file not found: $TARGET" >&2
    exit 1
fi

MARKER="CoreGram: shared gift animation cache"

if grep -qF "$MARKER" "$TARGET"; then
    echo "Already patched ($MARKER present). Nothing to do."
    exit 0
fi

# --- Verify the exact anchor (unique) --------------------------------------
ANCHOR='                    unique: !component.still,'
COUNT="$(grep -cF "$ANCHOR" "$TARGET" || true)"
if [ "$COUNT" != "1" ]; then
    echo "ERROR: expected exactly 1 occurrence of the 'unique: !component.still' anchor, found $COUNT." >&2
    echo "       Upstream code changed -- refusing to patch." >&2
    exit 1
fi

echo "=== BEFORE ==="
grep -n "unique:" "$TARGET"

# --- Flip the hero layer to the shared cache bucket ------------------------
perl -0777 -pi -e '
my $n = 0;
$n += s{^(                    )unique: !component\.still,$}
       {$1// CoreGram: shared gift animation cache -- reuse the grid-rendered\n$1// frames from /animation-cache instead of a private per-open re-decode.\n$1unique: false,}m;
die "ERROR: unique-flip matched $n (expected 1)\n" unless $n == 1;
' "$TARGET"

# --- Post-conditions -------------------------------------------------------
if ! grep -qF "$MARKER" "$TARGET"; then
    echo "ERROR: marker did not land in $TARGET." >&2
    exit 1
fi
if ! grep -qF "unique: false," "$TARGET"; then
    echo "ERROR: expected 'unique: false,' not present after patch." >&2
    exit 1
fi
if grep -qF "unique: !component.still," "$TARGET"; then
    echo "ERROR: old 'unique: !component.still,' still present after patch." >&2
    exit 1
fi
# loopCount / isVisibleForAnimations behaviour must be preserved.
for needle in \
    'loopCount: component.still ? 0 : 1' \
    'animationLayer.isVisibleForAnimations = !component.still'; do
    if ! grep -qF "$needle" "$TARGET"; then
        echo "ERROR: expected surrounding behaviour changed/missing: $needle" >&2
        exit 1
    fi
done

echo "=== AFTER ==="
grep -n -B1 -A2 "$MARKER" "$TARGET"

echo "OK: patched $TARGET (FIX 3a). FIX 3b intentionally skipped (see header)."
