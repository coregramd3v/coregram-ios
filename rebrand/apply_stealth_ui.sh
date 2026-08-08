#!/usr/bin/env bash
#
# apply_stealth_ui.sh
#
# Adds a "Stealth Mode" switch to the Debug settings so the ghost-mode toggle
# created by apply_stealth.sh (CoreGramStealthMode.isEnabled, in TelegramCore)
# is user-controllable.
#
# Target: submodules/DebugSettingsUI/Sources/DebugController.swift
# This file drives its list via the `DebugControllerEntry` enum. A new switch
# requires the same 5 coordinated touch-points every existing switch uses; we
# mirror `.alwaysDisplayTyping` (a single-Bool row) EXACTLY:
#   1. enum case            : `case coregramStealthMode(Bool)`
#   2. section mapping      : add to the `.experiments` section list
#   3. stableId             : `19` (verified unused: ids jump 18 -> 20)
#   4. item() switch        : an ItemListSwitchItem mirroring "Show Typing",
#                             whose `updated:` sets CoreGramStealthMode.isEnabled
#   5. entries.append(...)  : `.coregramStealthMode(CoreGramStealthMode.isEnabled)`
#
# `import TelegramCore` is already present in the file (line ~5), so
# CoreGramStealthMode resolves. The three switches over the enum (section,
# stableId, item) are exhaustive (no `default:`), so all three get the new case.
# There is no hand-written `==` operator, so synthesized Equatable absorbs the
# new case automatically.
#
# The neighbor row we copy (verified in-tree):
#   case let .alwaysDisplayTyping(value):
#       return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Show Typing", value: value, sectionId: self.section, style: .blocks, updated: { value in ... })
#
# FAILS LOUD: each of the 5 anchors must match exactly once. Idempotent marker:
# `coregramStealthMode`.
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
        if [ -f "$c/submodules/DebugSettingsUI/Sources/DebugController.swift" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
    if ! REPO_ROOT="$(find_root)"; then
        echo "ERROR: could not locate Telegram-iOS repo root (need submodules/DebugSettingsUI/Sources/DebugController.swift)." >&2
        exit 1
    fi
fi

TARGET="$REPO_ROOT/submodules/DebugSettingsUI/Sources/DebugController.swift"
if [ ! -f "$TARGET" ]; then
    echo "ERROR: target file not found: $TARGET" >&2
    exit 1
fi

MARKER="coregramStealthMode"

if grep -q "$MARKER" "$TARGET"; then
    echo "Already patched ($MARKER present). Nothing to do."
    exit 0
fi

# --- Sanity: import TelegramCore must exist --------------------------------
if ! grep -q "^import TelegramCore" "$TARGET"; then
    echo "ERROR: 'import TelegramCore' not found in $TARGET (needed for CoreGramStealthMode)." >&2
    exit 1
fi

# --- Verify all 5 anchors exactly once -------------------------------------
declare -a ANCHORS=(
'    case alwaysDisplayTyping(Bool)'
'        case .keepChatNavigationStack, .skipReadHistory, .alwaysDisplayTyping, .debugRatingLayout, .crashOnSlowQueries, .crashOnMemoryPressure:'
'        case let .alwaysDisplayTyping(value):'
'        entries.append(.alwaysDisplayTyping(experimentalSettings.alwaysDisplayTyping))'
)
for a in "${ANCHORS[@]}"; do
    c="$(grep -cF "$a" "$TARGET" || true)"
    if [ "$c" != "1" ]; then
        echo "ERROR: expected exactly 1 occurrence of anchor, found $c:" >&2
        echo "       $a" >&2
        exit 1
    fi
done
# stableId block anchor (2 lines)
if [ "$(grep -cF '        case .alwaysDisplayTyping:' "$TARGET")" != "1" ]; then
    echo "ERROR: stableId anchor '.alwaysDisplayTyping:' not unique." >&2
    exit 1
fi

echo "=== BEFORE (enum / section / stableId / item / append) ==="
grep -n "case alwaysDisplayTyping(Bool)" "$TARGET"
grep -n "case let .alwaysDisplayTyping(value):" "$TARGET"
grep -n "entries.append(.alwaysDisplayTyping" "$TARGET"

# --- Apply all 5 insertions ------------------------------------------------
perl -0777 -pi -e '
my $n;

# 1) enum case
$n = 0;
$n += s{(\ {4}case\ alwaysDisplayTyping\(Bool\)\n)}{$1    case coregramStealthMode(Bool)\n}g;
die "ERROR: enum-case insert matched $n (expected 1)\n" unless $n == 1;

# 2) section mapping: append .coregramStealthMode to the experiments list
$n = 0;
$n += s{(\ {8}case\ \.keepChatNavigationStack,\ \.skipReadHistory,\ \.alwaysDisplayTyping,\ \.debugRatingLayout,\ \.crashOnSlowQueries,\ \.crashOnMemoryPressure)(:)}{$1, .coregramStealthMode$2}g;
die "ERROR: section-list insert matched $n (expected 1)\n" unless $n == 1;

# 3) stableId
$n = 0;
$n += s{(\ {8}case\ \.alwaysDisplayTyping:\n\ {12}return\ 17\n)}{$1        case .coregramStealthMode:\n            return 19\n}g;
die "ERROR: stableId insert matched $n (expected 1)\n" unless $n == 1;

# 4) item() switch: insert the stealth row just before the alwaysDisplayTyping row
$n = 0;
my $row = <<"ROW";
        case let .coregramStealthMode(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Stealth Mode", value: value, sectionId: self.section, style: .blocks, updated: { value in
                // CoreGram: ghost mode -- suppress read receipts / online / typing / story views
                CoreGramStealthMode.isEnabled = value
            })
ROW
$n += s{(\ {8}case\ let\ \.alwaysDisplayTyping\(value\):)}{$row$1}g;
die "ERROR: item-row insert matched $n (expected 1)\n" unless $n == 1;

# 5) entries.append
$n = 0;
$n += s{(\ {8}entries\.append\(\.alwaysDisplayTyping\(experimentalSettings\.alwaysDisplayTyping\)\)\n)}{$1        entries.append(.coregramStealthMode(CoreGramStealthMode.isEnabled))\n}g;
die "ERROR: entries.append insert matched $n (expected 1)\n" unless $n == 1;
' "$TARGET"

# --- Post-conditions: expect 5 occurrences of the marker -------------------
GOT="$(grep -cF "$MARKER" "$TARGET" || true)"
if [ "$GOT" != "5" ]; then
    echo "ERROR: expected 5 '$MARKER' occurrences after patch, found $GOT." >&2
    exit 1
fi

echo "=== AFTER ==="
echo "-- enum case --";     grep -n "case coregramStealthMode(Bool)" "$TARGET"
echo "-- section list --";  grep -n ".coregramStealthMode:" "$TARGET" | head -1
echo "-- stableId --";      grep -n -A1 "case .coregramStealthMode:" "$TARGET" | grep "return 19"
echo "-- item row --";      grep -n "case let .coregramStealthMode(value):" "$TARGET"
echo "-- item body --";     grep -n "CoreGramStealthMode.isEnabled = value" "$TARGET"
echo "-- entries.append --";grep -n "entries.append(.coregramStealthMode" "$TARGET"

echo "OK: patched $TARGET"
