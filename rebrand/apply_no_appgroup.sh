#!/usr/bin/env bash
#
# apply_no_appgroup.sh
#
# Patches Telegram-iOS (tag release-12.9.2) so a SIDELOADED build (signed
# WITHOUT the App Group entitlement) does not black-screen on launch.
#
# Problem: submodules/TelegramUI/Sources/AppDelegate.swift resolves the account
# database container via containerURL(forSecurityApplicationGroupIdentifier:).
# On a free/sideload signer that call returns nil, the original code shows an
# "Error 2" alert and `return true`s out of didFinishLaunching WITHOUT building
# a root view controller -> black screen.
#
# Fix: when the App Group container is nil, fall back to a directory in the
# app's own sandbox (Library/AppGroupFallback). Types are preserved:
# `appGroupUrl` stays a non-optional `URL`, so all downstream code is unchanged.
# When the App Group IS available (paid signer / App Store), it is used as
# before -- the fallback only triggers on nil.
#
# FAILS LOUD: if the anchor cannot be found, the script exits 1 so a future
# upstream change breaks the build instead of silently shipping a
# black-screening app.
#
set -euo pipefail

# --- Locate repo root (contains Telegram/Telegram-iOS) ---------------------
find_root() {
    local candidates=()
    [ -n "${GITHUB_WORKSPACE:-}" ] && candidates+=("$GITHUB_WORKSPACE")
    candidates+=("$(pwd)")
    candidates+=("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    # walk up from script dir too
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while [ "$d" != "/" ]; do
        candidates+=("$d")
        d="$(dirname "$d")"
    done
    for c in "${candidates[@]}"; do
        if [ -d "$c/Telegram/Telegram-iOS" ] && [ -f "$c/submodules/TelegramUI/Sources/AppDelegate.swift" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
    if ! REPO_ROOT="$(find_root)"; then
        echo "ERROR: could not locate Telegram-iOS repo root (need Telegram/Telegram-iOS and submodules/TelegramUI/Sources/AppDelegate.swift)." >&2
        echo "       Set GITHUB_WORKSPACE, run from the repo, or pass the root as \$1." >&2
        exit 1
    fi
fi

TARGET="$REPO_ROOT/submodules/TelegramUI/Sources/AppDelegate.swift"
if [ ! -f "$TARGET" ]; then
    echo "ERROR: target file not found: $TARGET" >&2
    exit 1
fi

MARKER="no-appgroup sideload fallback"

# --- Idempotency: already patched? -----------------------------------------
if grep -q "$MARKER" "$TARGET"; then
    echo "Already patched ($MARKER present in $TARGET). Nothing to do."
    exit 0
fi

# --- Verify the exact anchor is present exactly once ------------------------
ANCHOR='guard let appGroupUrl = maybeAppGroupUrl else {'
COUNT="$(grep -cF "$ANCHOR" "$TARGET" || true)"
if [ "$COUNT" != "1" ]; then
    echo "ERROR: expected exactly 1 occurrence of anchor, found $COUNT." >&2
    echo "       Anchor: $ANCHOR" >&2
    echo "       Upstream code changed -- refusing to patch (would ship a black-screening app)." >&2
    exit 1
fi

echo "=== BEFORE ==="
grep -n -A3 "$ANCHOR" "$TARGET"

# --- Apply the patch (whole-file slurp, exact anchored block) --------------
# Original block (4 lines, 8-space indent):
#     guard let appGroupUrl = maybeAppGroupUrl else {
#         self.mainWindow?.presentNative(UIAlertController(title: nil, message: "Error 2", preferredStyle: .alert))
#         return true
#     }
perl -0777 -pi -e '
my $count = 0;
$count += s{
        [ ]{8}guard\ let\ appGroupUrl\ =\ maybeAppGroupUrl\ else\ \{\n
        \ +self\.mainWindow\?\.presentNative\(UIAlertController\(title:\ nil,\ message:\ "Error\ 2",\ preferredStyle:\ \.alert\)\)\n
        \ +return\ true\n
        \ +\}
}{        // --- no-appgroup sideload fallback ---------------------------------
        // If no App Group entitlement (sideload / free Apple ID signer),
        // containerURL(forSecurityApplicationGroupIdentifier:) returns nil.
        // Fall back to the app'"'"'s own sandbox instead of black-screening.
        let appGroupUrl: URL
        if let maybeAppGroupUrl = maybeAppGroupUrl {
            appGroupUrl = maybeAppGroupUrl
        } else {
            let fallbackUrl = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("AppGroupFallback", isDirectory: true)
            try? FileManager.default.createDirectory(at: fallbackUrl, withIntermediateDirectories: true, attributes: nil)
            print("[no-appgroup] App Group container unavailable; falling back to sandbox path: \\(fallbackUrl.path)")
            appGroupUrl = fallbackUrl
        }}gx;
die "ERROR: anchor matched by grep but perl substitution replaced $count blocks (expected 1)\n" unless $count == 1;
' "$TARGET"

# --- Post-conditions --------------------------------------------------------
if ! grep -q "$MARKER" "$TARGET"; then
    echo "ERROR: patch did not land (marker missing after substitution)." >&2
    exit 1
fi
if grep -qF "$ANCHOR" "$TARGET"; then
    echo "ERROR: original anchor still present after patch." >&2
    exit 1
fi

echo "=== AFTER ==="
grep -n -A15 "$MARKER" "$TARGET" | head -20

echo "OK: patched $TARGET"
