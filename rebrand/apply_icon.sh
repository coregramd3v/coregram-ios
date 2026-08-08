#!/usr/bin/env bash
#
# apply_icon.sh — заменяет иконку приложения на CoreGram.
#
# ГЛАВНОЕ ОТКРЫТИЕ (почему это НЕ просто «положить PNG в appiconset»):
#   В апстриме Telegram-iOS (12.6.x/12.9.x — и в форке utonem/mytelegram-iOS)
#   ОСНОВНАЯ иконка приложения задаётся НЕ через .appiconset, а через НОВЫЙ формат
#   Xcode 26 «Icon Composer» — каталог Telegram/Telegram-iOS/Telegram.icon (векторный
#   icon.json + SVG). Главный таргет собирает её так (Telegram/BUILD):
#       app_icons = [ ":{}_icon".format(name) for name in composer_icon_folders ]
#       composer_icon_folders = ["Telegram"]      # -> :Telegram_icon -> Telegram.icon/**
#   А СТАРЫЙ appiconset Telegram/Telegram-iOS/DefaultAppIcon.xcassets/AppIconLLC.appiconset
#   в главном таргете НЕ используется (в resources закомментирован `#":DefaultAppIcon"`).
#   Значит: просто перерисовать PNG в appiconset — иконка в сборке НЕ поменяется.
#
# ЧТО ДЕЛАЕМ (две части, обе фатальные при несоответствии):
#   1) Пересобираем PNG-иконки из rebrand/assets/coregram_appicon.png (1024×1024, RGB)
#      во ВСЕ размеры appiconset AppIconLLC по его Contents.json (sips, macOS).
#   2) Переключаем главный таргет с векторного .icon на этот классический appiconset:
#      app_icons = [":DefaultAppIcon"]. Это штатный путь rules_apple
#      (@build_bazel_rules_apple//apple:ios.bzl) и гарантированно валидный PNG-набор
#      (без неопределённости liquid-glass/Icon Composer). Info.plist уже объявляет
#      CFBundlePrimaryIcon -> CFBundleIconName = "AppIconLLC", т.е. согласовано.
#
# АЛЬТЕРНАТИВНЫЕ ИКОНКИ (alternate_icons -> *.alticon/*.png) НЕ трогаем — это
# доп. темы иконок из настроек (Blue/Black/Premium…), их брендинг вне задачи.
#
# Идемпотентно: повторный прогон просто перегенерит PNG и увидит app_icons уже
# переключённым. Фатально: нет appiconset/Contents.json/исходника, не совпал размер
# на выходе, не найден якорь app_icons — выходим с ошибкой (не выпускаем чужую иконку).
#
set -euo pipefail

echo ">> apply_icon: старт"

# --- 0. Корень клона Telegram-iOS -------------------------------------------
find_root() {
    local candidates=()
    [ -n "${GITHUB_WORKSPACE:-}" ] && candidates+=("$GITHUB_WORKSPACE") && candidates+=("$GITHUB_WORKSPACE/tg")
    candidates+=("$(pwd)")
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while [ "$d" != "/" ]; do candidates+=("$d"); d="$(dirname "$d")"; done
    for c in "${candidates[@]}"; do
        if [ -f "$c/Telegram/BUILD" ] && \
           [ -d "$c/Telegram/Telegram-iOS/DefaultAppIcon.xcassets/AppIconLLC.appiconset" ]; then
            printf '%s\n' "$c"; return 0
        fi
    done
    return 1
}

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
    if ! REPO_ROOT="$(find_root)"; then
        echo "::error::apply_icon: не найден корень Telegram-iOS (нужны Telegram/BUILD и DefaultAppIcon.xcassets/AppIconLLC.appiconset)." >&2
        exit 1
    fi
fi
echo ">> apply_icon: REPO_ROOT=$REPO_ROOT"

BUILD_FILE="$REPO_ROOT/Telegram/BUILD"
APPICONSET="$REPO_ROOT/Telegram/Telegram-iOS/DefaultAppIcon.xcassets/AppIconLLC.appiconset"
CONTENTS="$APPICONSET/Contents.json"

# --- 1. Исходник иконки ------------------------------------------------------
SRC="${GITHUB_WORKSPACE:-}/rebrand/assets/coregram_appicon.png"
[ -f "$SRC" ] || SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/assets/coregram_appicon.png"
[ -f "$SRC" ] || { echo "::error::apply_icon: не найден исходник иконки: $SRC"; exit 1; }
[ -f "$CONTENTS" ] || { echo "::error::apply_icon: не найден $CONTENTS"; exit 1; }
[ -d "$APPICONSET" ] || { echo "::error::apply_icon: не найден каталог $APPICONSET"; exit 1; }

command -v sips >/dev/null 2>&1 || { echo "::error::apply_icon: sips не найден (скрипт рассчитан на macOS-раннер)."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "::error::apply_icon: python3 не найден."; exit 1; }

# iOS-иконки ДОЛЖНЫ быть непрозрачными. Наш исходник — RGB без альфы; проверяем и
# падаем, если вдруг альфа есть (полупрозрачную иконку App Store/actool отвергнут).
if sips -g hasAlpha "$SRC" 2>/dev/null | grep -qi 'hasAlpha: *yes'; then
    echo "::error::apply_icon: исходник $SRC имеет альфа-канал — иконка должна быть непрозрачной. Сведи фон (flatten) и повтори."
    exit 1
fi
echo ">> apply_icon: исходник OK (без альфы): $SRC"

# --- 2. Разбор Contents.json: filename<TAB>px (px = size * scale) ------------
# Пропускаем записи без "filename" (в AppIconLLC есть ipad 76x76@1x без файла).
MAP="$(python3 - "$CONTENTS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d.get("images", []):
    fn = e.get("filename")
    if not fn:
        continue
    base = float(e["size"].split("x")[0])
    scale = int(e["scale"].replace("x", ""))
    px = int(round(base * scale))
    print("%s\t%d" % (fn, px))
PY
)"
[ -n "$MAP" ] || { echo "::error::apply_icon: не удалось разобрать $CONTENTS (пусто)."; exit 1; }

count=0
while IFS=$'\t' read -r fn px; do
    [ -n "$fn" ] || continue
    dest="$APPICONSET/$fn"
    # sips -z <высота> <ширина>; иконки квадратные, поэтому px px.
    sips -z "$px" "$px" "$SRC" --out "$dest" >/dev/null
    count=$((count + 1))
done <<< "$MAP"
echo ">> apply_icon: перегенерировано PNG: $count"

# --- 3. Пост-условие: каждый файл существует и имеет ожидаемый размер ---------
fail=0
while IFS=$'\t' read -r fn px; do
    [ -n "$fn" ] || continue
    dest="$APPICONSET/$fn"
    if [ ! -f "$dest" ]; then echo "::error::apply_icon: не создан $dest"; fail=1; continue; fi
    gotw="$(sips -g pixelWidth "$dest" 2>/dev/null | awk '/pixelWidth/{print $2}')"
    goth="$(sips -g pixelHeight "$dest" 2>/dev/null | awk '/pixelHeight/{print $2}')"
    if [ "$gotw" != "$px" ] || [ "$goth" != "$px" ]; then
        echo "::error::apply_icon: $fn размер ${gotw}x${goth}, ожидалось ${px}x${px}"; fail=1
    fi
done <<< "$MAP"
[ "$fail" -eq 0 ] || { echo "::error::apply_icon: пост-проверка размеров провалена."; exit 1; }
echo ">> apply_icon: пост-проверка размеров OK"

# --- 4. Переключить главный таргет с .icon (Icon Composer) на appiconset ------
COMPOSER_ANCHOR='    app_icons = [ ":{}_icon".format(name) for name in composer_icon_folders ],'
APPICONSET_LINE='    app_icons = [":DefaultAppIcon"],'

if grep -qF "$APPICONSET_LINE" "$BUILD_FILE"; then
    echo ">> apply_icon: app_icons уже указывает на :DefaultAppIcon — пропускаю переключение."
elif grep -qF "$COMPOSER_ANCHOR" "$BUILD_FILE"; then
    n="$(grep -cF "$COMPOSER_ANCHOR" "$BUILD_FILE")"
    if [ "$n" != "1" ]; then
        echo "::error::apply_icon: якорь app_icons найден $n раз (ожидалось 1) — upstream изменился, останавливаюсь."; exit 1
    fi
    ANCHOR="$COMPOSER_ANCHOR" REPL="$APPICONSET_LINE" perl -0777 -i -pe '
        my $a=$ENV{ANCHOR}; my $r=$ENV{REPL};
        my $c = ($_ =~ s{\Q$a\E}{$r}g);
        die "apply_icon: substitution count $c (expected 1)\n" unless $c == 1;
    ' "$BUILD_FILE"
    grep -qF "$APPICONSET_LINE" "$BUILD_FILE" || { echo "::error::apply_icon: не удалось переключить app_icons."; exit 1; }
    echo ">> apply_icon: app_icons переключён на :DefaultAppIcon (был Icon Composer .icon)"
else
    echo "::error::apply_icon: в $BUILD_FILE не найден ни якорь Icon Composer, ни :DefaultAppIcon — upstream изменился, останавливаюсь."; exit 1
fi

echo ">> apply_icon: готово."
echo "   ПРИМЕЧАНИЕ: альтернативные иконки (*.alticon: Blue/Black/Premium…) и векторный"
echo "   Telegram.icon оставлены как есть; основная иконка теперь CoreGram (AppIconLLC)."
