#!/usr/bin/env bash
#
# apply_buymorestars.sh
#
# Feature 1: redirect the native Telegram Stars purchase flow to the CoreGram
# bot @coregrbot with a /start stars payload.
#
# IMPORTANT: @coregrbot is a bot on REAL Telegram, NOT on the CoreGram server
# the client is connected to. So it MUST NOT be resolved in-network (that would
# find nothing). Instead we open the EXTERNAL universal link
#     https://t.me/coregrbot?start=stars
# which launches the real Telegram app (or Safari -> real Telegram) landing on
# @coregrbot with the stars section.
#
# Injection point: every "Buy More Stars" / top-up entry funnels through ONE
# factory in submodules/TelegramUI/Sources/SharedAccountContext.swift:
#     public func makeStarsPurchaseScreen(...) -> ViewController {
#         return StarsPurchaseScreen(...)
#     }
# (~30 callers push/present the returned controller). We replace the body so it
# returns a tiny self-dismissing controller that, on appear, opens the external
# URL and removes itself.
#
# APIs used (all verified by grep against real, compiling call sites in this
# same tag, release-12.9.2):
#   - External URL open:
#       TelegramApplicationBindings.openUrl: (String) -> Void   (AccountContext.swift:46)
#       -> backed by UIApplication.shared.open(...) in AppDelegate.swift.
#       Real caller: context.sharedContext.applicationBindings.openUrl(url)   (OpenUrl.swift:373)
#       Inside SharedAccountContext (self == the shared context) it is
#       reachable as self.applicationBindings.openUrl(...)   (applicationBindings
#       is `public let applicationBindings: TelegramApplicationBindings`,
#       SharedAccountContext.swift:147).
#   - Display.ViewController (self-dismissing redirect controller):
#       * designated init : public init(navigationBarPresentationData:)      (ViewController.swift:370)
#       * required init   : required public init(coder:)                      (ViewController.swift:416)
#       * appear override : open override func viewDidAppear(_ animated: Bool) (ViewController.swift:660)
#       * self-remove     : override open func dismiss(animated:completion:)  (ViewController.swift:575-585)
#         -> filterController(self) when pushed, else presentingViewController?.dismiss(...)
#            so self.dismiss(animated:) removes it whether pushed OR presented.
#   - Imports already present in the file: Display, SwiftSignalKit, TelegramCore, AccountContext.
#
# FAILS LOUD: if the anchors are not found exactly once, exits 1.
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
        if [ -f "$c/submodules/TelegramUI/Sources/SharedAccountContext.swift" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
    if ! REPO_ROOT="$(find_root)"; then
        echo "ERROR: could not locate Telegram-iOS repo root (need submodules/TelegramUI/Sources/SharedAccountContext.swift)." >&2
        exit 1
    fi
fi

TARGET="$REPO_ROOT/submodules/TelegramUI/Sources/SharedAccountContext.swift"
if [ ! -f "$TARGET" ]; then
    echo "ERROR: target file not found: $TARGET" >&2
    exit 1
fi

MARKER="CoreGram: redirect native Stars purchase"

if grep -q "$MARKER" "$TARGET" && grep -q "class CoreGramRedirectController" "$TARGET"; then
    echo "Already patched ($MARKER + CoreGramRedirectController present). Nothing to do."
    exit 0
fi

# --- Verify anchor exactly once --------------------------------------------
ANCHOR='return StarsPurchaseScreen(context: context, starsContext: starsContext, options: options, purpose: purpose, targetPeerId: targetPeerId, customTheme: customTheme, completion: completion)'
COUNT="$(grep -cF "$ANCHOR" "$TARGET" || true)"
if [ "$COUNT" != "1" ]; then
    echo "ERROR: expected exactly 1 occurrence of makeStarsPurchaseScreen body anchor, found $COUNT." >&2
    echo "       Upstream code changed -- refusing to patch." >&2
    exit 1
fi

echo "=== BEFORE ==="
grep -n -B1 -A1 "$ANCHOR" "$TARGET"

# --- 1. Replace the factory body with the external-URL redirect ------------
perl -0777 -pi -e '
my $count = 0;
$count += s{
    [ ]+return\ StarsPurchaseScreen\(context:\ context,\ starsContext:\ starsContext,\ options:\ options,\ purpose:\ purpose,\ targetPeerId:\ targetPeerId,\ customTheme:\ customTheme,\ completion:\ completion\)\n
}{        // CoreGram: redirect native Stars purchase to the EXTERNAL bot \@coregrbot on real Telegram.
        // \@coregrbot lives on real Telegram (NOT our CoreGram server), so we must not resolve it
        // in-network. Opening the universal https://t.me link launches the real Telegram app
        // (or Safari -> real Telegram) at \@coregrbot with the /start stars payload.
        return CoreGramRedirectController(onAppear: { [weak self] in
            guard let self else {
                return
            }
            self.applicationBindings.openUrl("https://t.me/coregrbot?start=stars")
        })
}gx;
die "ERROR: factory-body substitution replaced $count sites (expected 1)\n" unless $count == 1;
' "$TARGET"

# --- 2. Append the self-dismissing redirect controller (file scope) --------
if ! grep -q "class CoreGramRedirectController" "$TARGET"; then
cat >> "$TARGET" <<'SWIFT'

// CoreGram: minimal self-dismissing controller. Presented/pushed by the star
// purchase call sites; on first appear it runs `onAppear` (open the external
// @coregrbot link) and removes itself. `dismiss(animated:)` (Display.ViewController)
// pops it when pushed onto a NavigationController and dismisses it when presented.
private final class CoreGramRedirectController: ViewController {
    private let onAppear: () -> Void
    private var didRun = false

    init(onAppear: @escaping () -> Void) {
        self.onAppear = onAppear
        super.init(navigationBarPresentationData: nil)
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !self.didRun {
            self.didRun = true
            self.onAppear()
            self.dismiss(animated: false)
        }
    }
}
SWIFT
echo "Appended CoreGramRedirectController to $TARGET"
fi

# --- Post-conditions --------------------------------------------------------
if ! grep -q "$MARKER" "$TARGET"; then
    echo "ERROR: redirect body did not land." >&2
    exit 1
fi
if ! grep -q 'applicationBindings.openUrl("https://t.me/coregrbot?start=stars")' "$TARGET"; then
    echo "ERROR: external-URL open call missing after patch." >&2
    exit 1
fi
if ! grep -q "class CoreGramRedirectController" "$TARGET"; then
    echo "ERROR: CoreGramRedirectController class missing after patch." >&2
    exit 1
fi
if grep -qF "$ANCHOR" "$TARGET"; then
    echo "ERROR: original StarsPurchaseScreen body still present." >&2
    exit 1
fi

echo "=== AFTER (factory) ==="
grep -n -A11 "$MARKER" "$TARGET" | head -13
echo "=== AFTER (controller) ==="
grep -n -A3 "class CoreGramRedirectController" "$TARGET"

echo "OK: patched $TARGET"
