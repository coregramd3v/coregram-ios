#!/usr/bin/env bash
# Брендинг CoreGram: имя приложения. Запускается из корня клона Telegram-iOS (tg/).
#
# ПОЧЕМУ РАНЬШЕ ИМЯ ОСТАВАЛОСЬ "Telegram":
#   Итоговый Info.plist приложения Telegram-iOS собирается Bazel'ом из инлайн
#   plist-фрагментов в Telegram/BUILD, а НЕ из InfoPlist.strings/Localizable.strings
#   и НЕ из Telegram/Telegram-iOS/Info.plist. Главный app-таргет
#   `ios_application(name="Telegram")` имеет `infoplists = [":TelegramInfoPlist", ...]`,
#   а фрагмент `TelegramInfoPlist` жёстко задаёт:
#       <key>CFBundleDisplayName</key><string>Telegram</string>
#       <key>CFBundleName</key><string>Telegram</string>
#   Правки .strings на CFBundleDisplayName не влияют — поэтому имя терялось.
#
# ПРАВИЛЬНОЕ ИСПРАВЛЕНИЕ: патчим реальный источник — Telegram/BUILD — подменяя
# значение ТОЛЬКО у ключей CFBundleDisplayName/CFBundleName (по ключу, а не по всем
# вхождениям слова Telegram), поэтому сабмодули (MtProtoKit/Postbox/TelegramApi/
# TelegramCore и т.п. — у них своё CFBundleName) не затрагиваются. Скрипт ФАТАЛЕН:
# если паттерн не найден (upstream переехал) — падаем, чтобы сборка не выпустила
# приложение с именем Telegram.
set -euo pipefail
APP_NAME="${APP_NAME:-CoreGram}"
echo ">> apply_branding: APP_NAME=$APP_NAME"

BUILD_FILE="Telegram/BUILD"
[ -f "$BUILD_FILE" ] || { echo "::error::apply_branding: не найден $BUILD_FILE (запускай из корня клона Telegram-iOS)"; exit 1; }

# ВАЖНО: <key> и <string> лежат на РАЗНЫХ строках, поэтому все проверки — многострочные
# (perl -0777), а не построчный grep (он бы всегда давал 0 и ломал ассерты).
cnt() {  # cnt <file> <regex> → число совпадений во всём файле (многострочно)
  RE="$2" perl -0777 -ne 'my $re=$ENV{RE}; my $c=()=/$re/g; END{print scalar $c}' "$1" 2>/dev/null || echo 0
}
DN_KEY='<key>CFBundleDisplayName<\/key>\s*<string>'
BN_KEY='<key>CFBundleName<\/key>\s*<string>'

# Замена по ключу (учитывает перевод строки/отступы между <key> и <string>).
# ВАЖНО про «Beta»: апстрим/форк держит значение "Telegram", но бета-ветки апстрима
# иногда ставят "Telegram Beta". Ставим ВСЁ значение = APP_NAME (а не подстроку), т.е.
# матчим "Telegram" И "Telegram Beta" -> "CoreGram" (иначе получили бы "CoreGram Beta").
# Матч по-прежнему привязан к КЛЮЧУ CFBundleDisplayName/CFBundleName, поэтому CFBundleName
# сабмодулей (MtProtoKit/Postbox/…) не задевается. Второй проход снимает хвост " Beta",
# если значение уже оказалось "<APP_NAME> Beta" (идемпотентность/повторный прогон).
APP_NAME="$APP_NAME" perl -0777 -i -pe '
  my $n = $ENV{APP_NAME};
  s{(<key>CFBundleDisplayName</key>\s*<string>)Telegram(?: Beta)?(</string>)}{$1$n$2}g;
  s{(<key>CFBundleName</key>\s*<string>)Telegram(?: Beta)?(</string>)}{$1$n$2}g;
  s{(<key>CFBundleDisplayName</key>\s*<string>\Q$n\E) Beta(</string>)}{$1$2}g;
  s{(<key>CFBundleName</key>\s*<string>\Q$n\E) Beta(</string>)}{$1$2}g;
' "$BUILD_FILE"

left="$(cnt "$BUILD_FILE" '<key>(CFBundleDisplayName|CFBundleName)<\/key>\s*<string>Telegram(?: Beta)?<\/string>')"
gotdn="$(cnt "$BUILD_FILE" "${DN_KEY}${APP_NAME}<\/string>")"
gotbn="$(cnt "$BUILD_FILE" "${BN_KEY}${APP_NAME}<\/string>")"
echo ">> apply_branding: Telegram/BUILD → CFBundleDisplayName=${APP_NAME}:$gotdn, CFBundleName=${APP_NAME}:$gotbn, осталось «Telegram»:$left"

# Жёсткая проверка: обе строки главного app должны стать APP_NAME и НИ ОДНОГО app-facing Telegram.
if [ "$gotdn" -lt 1 ] || [ "$gotbn" -lt 1 ]; then
  echo "::error::apply_branding: CFBundleDisplayName/CFBundleName=${APP_NAME} не выставлены в $BUILD_FILE — upstream изменился, останавливаю."
  exit 1
fi
if [ "$left" -ne 0 ]; then
  echo "::error::apply_branding: в $BUILD_FILE остались app-facing имена «Telegram» ($left) — останавливаю."
  exit 1
fi

# Для согласованности (эти plist в IPA не мёржатся, но пусть не расходятся при генерации
# Xcode-проекта / будущих правках upstream) — best-effort, без фатала.
for pf in Telegram/Telegram-iOS/InfoBazel.plist Telegram/Telegram-iOS/Info.plist; do
  [ -f "$pf" ] || continue
  APP_NAME="$APP_NAME" perl -0777 -i -pe '
    my $n=$ENV{APP_NAME};
    s{(<key>CFBundleDisplayName</key>\s*<string>)Telegram(?: Beta)?(</string>)}{$1$n$2}g;
    s{(<key>CFBundleName</key>\s*<string>)Telegram(?: Beta)?(</string>)}{$1$n$2}g;
    s{(<key>CFBundleDisplayName</key>\s*<string>\Q$n\E) Beta(</string>)}{$1$2}g;
    s{(<key>CFBundleName</key>\s*<string>\Q$n\E) Beta(</string>)}{$1$2}g;
  ' "$pf" || true
done

# Иконки: если в ребренд-репо есть готовый appiconset — копируем (best-effort).
ICON_SRC="${GITHUB_WORKSPACE:-..}/rebrand/AppIcon"
ICON_DST="$(find Telegram -type d -name '*.appiconset' 2>/dev/null | head -1)"
if [ -d "$ICON_SRC" ] && [ -n "$ICON_DST" ]; then
  cp -f "$ICON_SRC"/*.png "$ICON_DST"/ 2>/dev/null && echo ">> apply_branding: иконки скопированы в $ICON_DST" \
    || echo "::warning::apply_branding: иконки не скопированы."
else
  echo ">> apply_branding: rebrand/AppIcon отсутствует — иконка дефолтная (не критично)."
fi

echo ">> apply_branding: готово."
