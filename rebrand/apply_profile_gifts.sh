#!/usr/bin/env bash
#
# apply_profile_gifts.sh  (v4 -- self/own-profile fix; NO cachedData/starGiftsCount deps)
#
# SCREEN CONFIRMED: Settings -> "Профиль" pushes PeerInfoScreenImpl(peerId:
# account.peerId, isMyProfile: true) with isSettings defaulting to false
# (PeerInfoScreen.swift:6490) -> peerInfoScreenData takes the `.user` kind
# (peerInfoScreenInputData only returns `.settings` when isSettings==true), so
# the availablePanes code below IS the branch that runs for this screen. The
# render is faithful: PeerInfoScreen.swift:5620 shows the tab strip whenever
# `!availablePanes.isEmpty && !isEditing` -- no isMyProfile/isSettings gate. So
# the fix is purely to get `.gifts` into data.availablePanes for self.
#
# WHY v1-v3 "failed on device": timeline, not logic. The last build (v6) used
# the earlier cachedData-gated self-guarantee; the no-cachedData version was
# committed AFTER that build and was never compiled. This v4 is that fix.
#
# v3/v4 change vs v2: the self inserts (Edit A own-profile branch, and Edit C
# guarantee) no longer require `peerView.cachedData is CachedUserData`. On this
# fork, getFullUser(self) may not populate a CachedUserData for the account's own
# peer (other users DO get one -- that is why other users' gifts show), so that
# type check was silently blocking BOTH self inserts. `userPeerId ==
# context.account.peerId` already proves it is the self user, so the check is
# redundant; dropping it makes the Gifts tab appear for self whenever the gifts
# context exists, independent of cachedData load state.
#
# For isMyProfile specifically: availablePanes starts [] (peerInfoAvailableMediaPanes
# uses empty tags for isMyProfile), line 1548 inserts .stories -> [.stories],
# Edit A inserts .gifts (profileGiftsContext is non-nil because isMyProfile takes
# the `if` branch at 1186 that always creates it) -> [.stories, .gifts]. Edit C
# then no-ops (already contains .gifts). data.availablePanes = [.stories, .gifts]
# -> strip renders. The gifts pane force-unwraps data.profileGiftsContext! AND
# data.profileGiftsCollectionsContext! (PeerInfoPaneContainerNode.swift:470), both
# guaranteed non-nil here, so no crash.
#
# Symptom: on this fork, OTHER users' profiles show the Gifts pane correctly,
# but the user's OWN profile never shows a Gifts tab.
#
# Root cause (client-side), in
#   submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoData.swift
# For the `.user` kind:
#   * Gifts context creation (~line 1186):
#       if isMyProfile || userPeerId != context.account.peerId {
#           profileGiftsContext = ... ProfileGiftsContext(...)
#       } else {
#           profileGiftsContext = nil          // <-- SELF opened with isMyProfile == false
#       }
#     When the own profile is reached with isMyProfile == false (userPeerId ==
#     account.peerId), profileGiftsContext becomes nil.
#   * The own-profile (isMyProfile) insert (~1549) is gated on
#     `profileGiftsContext != nil` (and, stock, `starGiftsCount > 0`), so with a
#     nil context / nil count it is skipped.
#   * The other-user insert (~1562) is guarded by `peerView.peerId !=
#     context.account.peerId`, so SELF is deliberately excluded there.
#   Net: for the own profile, no branch ever inserts `.gifts`, and since the
#   whole pane bar is hidden when availablePanes is empty (PeerInfoScreen.swift
#   ~5620), the user sees no Gifts tab.
#   (starGiftsCount comes from userFull.stargifts_count behind flags2 bit 8,
#    which is unreliable on this fork -> stays nil.)
#
# Fix (three surgical, SELF-scoped edits; the working other-user path is NOT
# touched):
#   A. Own-profile (isMyProfile) insert: drop the unreliable `starGiftsCount > 0`
#      gate so it fires whenever profileGiftsContext != nil.
#   B. Gifts-context creation: create the context for SELF too (the `else`
#      branch), so profileGiftsContext is non-nil on the own profile regardless
#      of isMyProfile.
#   C. Guarantee block: for SELF only (userPeerId == account.peerId), ensure
#      availablePanes is non-nil and contains `.gifts`. This is independent of
#      isMyProfile / hasStories / the self-exclusion guard, so it reliably lands
#      whichever way the own profile was opened. Scoped to self => other users
#      are unaffected.
#
# `.gifts` pane is present & renderable in this build: PeerInfoPaneKey.gifts
# (PeerInfoPaneNode.swift:12), GiftsPaneNode created at
# PeerInfoPaneContainerNode.swift:457, tab title/icons at ~1307. The only thing
# missing was `.gifts` inside availablePanes for the self profile.
#
# FAILS LOUD: each anchor must match exactly once. Idempotent marker (Edit C).
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
        if [ -f "$c/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoData.swift" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
    if ! REPO_ROOT="$(find_root)"; then
        echo "ERROR: could not locate Telegram-iOS repo root (need submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoData.swift)." >&2
        exit 1
    fi
fi

TARGET="$REPO_ROOT/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoData.swift"
if [ ! -f "$TARGET" ]; then
    echo "ERROR: target file not found: $TARGET" >&2
    exit 1
fi

MARKER="CoreGram: guarantee the Gifts pane on the user's OWN profile"

if grep -qF "$MARKER" "$TARGET"; then
    echo "Already patched (v2 self guarantee present). Nothing to do."
    exit 0
fi

# --- Verify anchors (each exactly once) ------------------------------------
A_CNT="$(perl -0777 -ne '$c=()=/if availablePanes != nil, profileGiftsContext != nil, let cachedData = peerView\.cachedData as\? CachedUserData \{\n\s+if let starGiftsCount = cachedData\.starGiftsCount, starGiftsCount > 0 \{\n\s+availablePanes\?\.insert\(\.gifts, at: 1\)\n/g; print $c' "$TARGET")"
B_CNT="$(perl -0777 -ne '$c=()=/\n\s+} else \{\n\s+profileGiftsContext = nil\n\s+profileGiftsCollectionsContext = nil\n\s+\}/g; print $c' "$TARGET")"
C_CNT="$(grep -cF 'if var currentAvailablePanes = availablePanes, let cachedData = peerView.cachedData as? CachedUserData, let mainProfileTab = cachedData.mainProfileTab {' "$TARGET" || true)"
if [ "$A_CNT" != "1" ]; then echo "ERROR: Edit A anchor (own-profile insert) matched $A_CNT (expected 1)." >&2; exit 1; fi
if [ "$B_CNT" != "1" ]; then echo "ERROR: Edit B anchor (gifts-context else) matched $B_CNT (expected 1)." >&2; exit 1; fi
if [ "$C_CNT" != "1" ]; then echo "ERROR: Edit C anchor (mainProfileTab reorder) matched $C_CNT (expected 1)." >&2; exit 1; fi

echo "=== BEFORE (context creation ~1186) ==="
grep -n -A11 "if isMyProfile || userPeerId != context.account.peerId {" "$TARGET" | head -13

# --- Edit A: own-profile insert -- drop starGiftsCount gate -----------------
perl -0777 -pi -e '
my $n = 0;
$n += s{
    [ ]+if\ availablePanes\ !=\ nil,\ profileGiftsContext\ !=\ nil,\ let\ cachedData\ =\ peerView\.cachedData\ as\?\ CachedUserData\ \{\n
    [ ]+if\ let\ starGiftsCount\ =\ cachedData\.starGiftsCount,\ starGiftsCount\ >\ 0\ \{\n
    [ ]+availablePanes\?\.insert\(\.gifts,\ at:\ 1\)\n
    [ ]+\}\n
    [ ]+\}
}{                    // CoreGram: own-profile Gifts pane no longer gated on the (unreliable) starGiftsCount
                    // nor on cachedData being loaded (self may have no CachedUserData on this fork).
                    if availablePanes != nil, profileGiftsContext != nil {
                        availablePanes?.insert(.gifts, at: 1)
                    }}gx;
die "ERROR: Edit A replaced $n (expected 1)\n" unless $n == 1;
' "$TARGET"

# --- Edit B: create gifts context for SELF (the else branch) ----------------
# Match ONLY the two `= nil` body lines (keeping `} else {` and its closing `}`
# untouched) so the perl replacement contains no unbalanced braces.
perl -0777 -pi -e '
my $body = <<"BODY";
                    // CoreGram: self opened with isMyProfile=false still needs a gifts context,
                    // otherwise the own-profile Gifts pane can never appear.
                    profileGiftsContext = existingProfileGiftsContext ?? ProfileGiftsContext(account: context.account, peerId: userPeerId)
                    profileGiftsCollectionsContext = existingProfileGiftsCollectionsContext ?? ProfileGiftsCollectionsContext(account: context.account, peerId: userPeerId, allGiftsContext: profileGiftsContext)
BODY
# $2 captures the closing `}` -- present only for the self else (block 1); the
# non-user-kind else (block 2) is followed by `premiumGiftOptions`, so it is
# excluded. $2 is re-emitted so the replacement has no literal braces.
my $n = 0;
$n += s{(\}[ ]else[ ]\{\n)[ ]+profileGiftsContext\ =\ nil\n[ ]+profileGiftsCollectionsContext\ =\ nil\n([ ]+\})}{$1$body$2}gx;
die "ERROR: Edit B replaced $n (expected 1)\n" unless $n == 1;
' "$TARGET"

# --- Edit C: SELF-scoped guarantee block, inserted before mainProfileTab -----
perl -0777 -pi -e '
my $n = 0;
my $block = <<"BLOCK";
                // CoreGram: guarantee the Gifts pane on the user\x27s OWN profile.
                // Other users\x27 profiles already work (their branch inserts .gifts). For self, the
                // screen may be opened with isMyProfile=false -> profileGiftsContext was nil (fixed
                // above) and the self path never inserts .gifts (the other-user branch is guarded by
                // peerId != accountId). Surface it here for self, fed by profileGiftsContext
                // (payments.getSavedStarGifts). Scoped to self so the working other-user path is untouched.
                // NOTE: intentionally NOT gated on cachedData being a CachedUserData -- self may lack
                // one on this fork, which was blocking the pane. userPeerId == account.peerId is enough.
                // BOTH gift contexts must be non-nil: PeerInfoPaneContainerNode force-unwraps
                // data.profileGiftsContext! AND data.profileGiftsCollectionsContext! when building the
                // gifts pane, so inserting .gifts with either nil would crash. Edit B guarantees both.
                if userPeerId == context.account.peerId, profileGiftsContext != nil, profileGiftsCollectionsContext != nil {
                    if availablePanes == nil {
                        availablePanes = []
                    }
                    if availablePanes?.contains(.gifts) == false {
                        let coreGramGiftsIndex = (availablePanes?.contains(.stories) == true) ? 1 : 0
                        availablePanes?.insert(.gifts, at: coreGramGiftsIndex)
                    }
                }
BLOCK
$n += s{(\ +if\ var\ currentAvailablePanes\ =\ availablePanes,\ let\ cachedData\ =\ peerView\.cachedData\ as\?\ CachedUserData,\ let\ mainProfileTab\ =\ cachedData\.mainProfileTab\ \{)}{$block\n$1}g;
die "ERROR: Edit C inserted $n (expected 1)\n" unless $n == 1;
' "$TARGET"

# --- Post-conditions --------------------------------------------------------
if ! grep -qF "$MARKER" "$TARGET"; then
    echo "ERROR: Edit C marker missing after patch." >&2
    exit 1
fi
if ! grep -q "self opened with isMyProfile=false still needs a gifts context" "$TARGET"; then
    echo "ERROR: Edit B did not land." >&2
    exit 1
fi
if ! grep -q "own-profile Gifts pane no longer gated on the (unreliable) starGiftsCount" "$TARGET"; then
    echo "ERROR: Edit A did not land." >&2
    exit 1
fi
# The self else-branch (block 1: the two nil lines immediately followed by `}`)
# must no longer nil the gifts context. The non-user-kind else (block 2, followed
# by `premiumGiftOptions`) is intentionally left as nil and is excluded by the
# trailing `\s+\}`.
STILL_NIL="$(perl -0777 -ne '$c=()=/\}[ ]else[ ]\{\n\s+profileGiftsContext = nil\n\s+profileGiftsCollectionsContext = nil\n\s+\}/g; print $c' "$TARGET")"
if [ "$STILL_NIL" != "0" ]; then
    echo "ERROR: self else-branch still nils profileGiftsContext after patch (found $STILL_NIL)." >&2
    exit 1
fi

echo "=== AFTER (context creation) ==="
grep -n -A13 "if isMyProfile || userPeerId != context.account.peerId {" "$TARGET" | head -15
echo "=== AFTER (own-profile insert) ==="
grep -n -A2 "own-profile Gifts pane no longer gated" "$TARGET"
echo "=== AFTER (self guarantee block) ==="
grep -n -A11 "$MARKER" "$TARGET"

echo "OK: patched $TARGET"
