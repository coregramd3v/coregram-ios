#!/usr/bin/env bash
#
# apply_wallet_gift_links.sh
#
# Подарок, уехавший на блокчейн, в оригинале ведёт на Fragment: экран подарка
# блокирует передачу/крафт, если у подарка есть host (владелец-кошелёк), и
# показывает алерт «Action Locked → Open Fragment» со ссылкой
# https://fragment.com/gift/<slug>.
#
# У CoreGram блокчейн свой и Fragment тут ни при чём: подарок лежит на нашем
# TON-кошельке, страница предмета — https://coregram.live/nft/<slug>, кошелёк —
# https://coregram.live/wallet/<адрес или .ton домен>. Патч переписывает обе
# ссылки на наши. Тексты алерта живут в langpack на сервере и правятся там.
#
# FAILS LOUD: якорь обязан найтись ровно один раз, иначе сборка падает, а не
# уезжает молча со ссылкой на чужой сайт.
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
        if [ -f "$c/submodules/TelegramUI/Components/Gifts/GiftViewScreen/Sources/GiftViewScreen.swift" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
    if ! REPO_ROOT="$(find_root)"; then
        echo "ERROR: не нашёл корень Telegram-iOS (нужен submodules/TelegramUI/Components/Gifts/GiftViewScreen/Sources/GiftViewScreen.swift)." >&2
        exit 1
    fi
fi

SCREEN="$REPO_ROOT/submodules/TelegramUI/Components/Gifts/GiftViewScreen/Sources/GiftViewScreen.swift"
if [ ! -f "$SCREEN" ]; then
    echo "ERROR: не найден файл: $SCREEN" >&2
    exit 1
fi

if grep -q "CoreGram: подарок на нашем кошельке" "$SCREEN"; then
    echo "apply_wallet_gift_links.sh: патч уже применён, пропускаю."
    exit 0
fi

python3 - "$SCREEN" <<'PY'
import sys

path = sys.argv[1]
src = open(path, encoding='utf-8').read()

anchor = 'url: "https://fragment.com/gift/\\(gift.slug)"'
if src.count(anchor) != 1:
    raise SystemExit("ERROR: якорь ссылки на fragment.com/gift найден %d раз" % src.count(anchor))
src = src.replace(
    anchor,
    '/* CoreGram: подарок на нашем кошельке */ url: "https://coregram.live/nft/\\(gift.slug)"',
    1,
)

# Эксплорер адреса владельца берётся из app config (ton_blockchain_explorer_url),
# но дефолт в коде — tonviewer.com. Меняем и его, чтобы кошелёк открывался
# нашим даже до того, как клиент подтянет свежий конфиг.
default_explorer = 'GiftViewConfiguration(explorerUrl: "https://tonviewer.com")'
if src.count(default_explorer) != 1:
    raise SystemExit("ERROR: якорь дефолтного эксплорера найден %d раз" % src.count(default_explorer))
src = src.replace(
    default_explorer,
    'GiftViewConfiguration(explorerUrl: "https://coregram.live/wallet/")',
    1,
)

open(path, 'w', encoding='utf-8').write(src)
PY

echo "apply_wallet_gift_links.sh: ok"
