#!/usr/bin/env bash
#
# apply_profile_gifts_button.sh
#
# Adds a GUARANTEED-rendering "🎁 Подарки" row to the OWN profile's info section
# that opens the user's gifts list. The profile INFO rows render reliably on this
# build (the username / location / anonymous-number rows do), so a row is a
# dependable entry to the gifts even where the gifts PANE TAB did not surface.
#
# WHERE: submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoProfileItems.swift
#   `infoItems(...)` builds the profile rows; its `.user` branch begins at
#     if case let .user(user) = data.peer {
#         let ItemCallList = 1000
#   We insert the row at the TOP of the .peerInfo section, gated on `isMyProfile`
#   (self only) -- other-user profiles are untouched.
#
# HOW IT OPENS GIFTS (all verified in-tree, no new interaction wiring):
#   - `interaction.getController()` -> the profile ViewController
#     (PeerInfoInteraction.swift:88; used by existing rows, e.g. line 149-153
#      `guard let controller = interaction.getController() ... controller.push(...)`).
#   - `context.sharedContext.makePeerInfoController(context:updatedPresentationData:
#      peer:mode:avatarInitiallyExpanded:fromChat:requestsContext:)`
#     (AccountContext.swift:1414) with `mode: .myProfileGifts`
#     (PeerInfoControllerMode.myProfileGifts, AccountContext.swift:785) -> that mode
#     maps to isMyProfile=true + switchToGiftsTarget=.generic -> initialPaneKey=.gifts
#     (SharedAccountContext.swift:4599 / PeerInfoScreen.swift:6877): the dedicated
#     "show my gifts" screen.
#   - `controller.push(giftsController)` (Display.ViewController.push, used at
#     PeerInfoProfileItems.swift:153).
#   Row item: PeerInfoScreenDisclosureItem(id:label:text:icon:action:) mirrors the
#   existing Stars-balance row (PeerInfoProfileItems.swift:460); icon reuses
#   PresentationResourcesSettings.stars. `data` is non-optional here (guarded at the
#   top of infoItems), and `PresentationResourcesSettings`/`AccountContext`/`Display`
#   are already imported by the file.
#
# NOTE: this row shows the gifts by opening `.myProfileGifts`, which lands on the
# gifts pane. That pane node (PeerInfoGiftsPaneNode) DOES render -- other users'
# gifts panes render fine; the only earlier problem was `.gifts` not being in the
# OWN profile's availablePanes, which apply_profile_gifts.sh already fixes. Keep
# BOTH scripts enabled: this button is the always-visible entry; the pane fix
# makes the opened screen land on the gifts. Neither is a no-op.
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
        if [ -f "$c/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoProfileItems.swift" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
    if ! REPO_ROOT="$(find_root)"; then
        echo "ERROR: could not locate Telegram-iOS repo root (need submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoProfileItems.swift)." >&2
        exit 1
    fi
fi

TARGET="$REPO_ROOT/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoProfileItems.swift"
if [ ! -f "$TARGET" ]; then
    echo "ERROR: target file not found: $TARGET" >&2
    exit 1
fi

MARKER="CoreGram: guaranteed-rendering Podarki row"

if grep -qF "$MARKER" "$TARGET"; then
    echo "Already patched (Podarki row present). Nothing to do."
    exit 0
fi

# --- Sanity: interaction.getController + makePeerInfoController exist ---------
if ! grep -q "interaction.getController()" "$TARGET"; then
    echo "ERROR: interaction.getController() not found in $TARGET (push pattern missing)." >&2
    exit 1
fi

# --- Verify the disambiguated anchor (infoItems .user entry) exactly once -----
ANCHOR_COUNT="$(perl -0777 -ne 'no warnings; $c=()=/if case let \.user\(user\) = data\.peer \{\n        let ItemCallList = 1000\n/g; print $c' "$TARGET")"
if [ "$ANCHOR_COUNT" != "1" ]; then
    echo "ERROR: expected exactly 1 infoItems .user anchor, found $ANCHOR_COUNT." >&2
    echo "       Upstream code changed -- refusing to patch." >&2
    exit 1
fi

echo "=== BEFORE ==="
grep -n -A1 "if case let .user(user) = data.peer {" "$TARGET" | head -4

# --- Insert the gifts row at the top of the own-profile info section ---------
perl -0777 -pi -e '
my $block = <<"BLOCK";
        // CoreGram: guaranteed-rendering Podarki row -- own profile only. Info rows render
        // reliably where the gifts pane tab did not; this opens the dedicated self-gifts
        // screen via makePeerInfoController(mode: .myProfileGifts).
        if isMyProfile {
            items[currentPeerInfoSection]!.append(PeerInfoScreenDisclosureItem(id: 92026, label: .none, text: "\xF0\x9F\x8E\x81 \xD0\x9F\xD0\xBE\xD0\xB4\xD0\xB0\xD1\x80\xD0\xBA\xD0\xB8", icon: PresentationResourcesSettings.stars, action: {
                guard let peer = data.peer else {
                    return
                }
                guard let controller = interaction.getController() else {
                    return
                }
                guard let giftsController = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .myProfileGifts, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) else {
                    return
                }
                controller.push(giftsController)
            }))
        }
BLOCK
my $n = 0;
$n += s{(if case let \.user\(user\) = data\.peer \{\n        let ItemCallList = 1000\n)}{$1$block}g;
die "ERROR: Podarki-row insertion matched $n (expected 1)\n" unless $n == 1;
' "$TARGET"

# --- Post-conditions --------------------------------------------------------
if ! grep -qF "$MARKER" "$TARGET"; then
    echo "ERROR: Podarki row did not land (marker missing)." >&2
    exit 1
fi
for needle in \
    'if isMyProfile {' \
    'mode: .myProfileGifts,' \
    'controller.push(giftsController)'; do
    if ! grep -qF "$needle" "$TARGET"; then
        echo "ERROR: expected inserted line missing: $needle" >&2
        exit 1
    fi
done

echo "=== AFTER ==="
grep -n -A15 "$MARKER" "$TARGET" | head -17

echo "OK: patched $TARGET"
