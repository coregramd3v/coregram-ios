# CoreGram iOS — план форка (Telegram-iOS)

> Честный статус: **собрать/проверить .ipa с Linux-сервера нельзя.** Telegram-iOS
> строится Bazel+Xcode ТОЛЬКО на macOS. Здесь — готовый к исполнению набор
> (ребренд + два варианта + CI), запуск сборки — на Mac или GitHub Actions macOS.

## Требования сборки (из versions.json репо)
- **Xcode 26.2**, **macOS 26**, Bazel 8.4.2, app-версия 12.9.2.
- ⚠️ Бесплатные GitHub-раннеры могут ещё не иметь Xcode 26.2 — проверить
  `xcode-select -p` в CI; если нет, нужен self-hosted Mac или macOS-раннер с 26.2.

## Установка на iPhone (у юзера iOS 26.6)
- **TrollStore НЕ работает** (CoreTrust закрыт с iOS 16.7/17.0) — навсегда-без-$99 нельзя.
- **Sideloadly / AltStore + бесплатный Apple ID** — ставится, подпись живёт **7 дней**,
  потом переподписывать. Лимит 3 приложения, без пушей.
- **$99 Apple Developer** — подпись на год, поставил и забыл. Для юзабилити на 26.6 —
  фактически единственный «нормальный» путь. App Store клон не пропустит.

## Две версии (как договорились)
Отличаются ТОЛЬКО сетью, к которой подключается MTProto (как APK vs PC):

### Вариант A — «CoreGram» (наша сеть)
- Подключается к нашему серверу `gramsrv` (DC2, `cdn.un1quedev.lol:2398` / `2.26.123.219:2398`) + наши RSA-ключи.
- Аналог APK: `ConnectionsManager.cpp:1824` → `addAddressAndPort("2.26.123.219", 2398, 0, "")`.
- В Telegram-iOS правится сид-адрес DC + RSA в сабмодуле MTProto (`submodules/MtProtoKit` /
  `TelegramApi` — там хардкод production-DC и RSA, как `mtproto_dc_options.cpp` у tdesktop).
- Косметика/маркет/безлимит — **нативно** (сервер отдаёт сам, как APK). /pc-оверлей НЕ нужен.
- Переписка: с APK-юзерами (одна сеть). НЕ видит реальный Telegram.

### Вариант B — «CoreGram TG» (реальный Telegram)
- Стоковые DC Telegram + стоковые RSA (как в оригинале Telegram-iOS).
- Нужны валидные **api_id/api_hash** (my.telegram.org) — в `build-system/appstore-configuration.json`.
- Косметика через **/pc-оверлей** (HTTP-слой `https://un1quedev.lol/pc/*`), как в PC-десктопе.
- Переписка: с реальным Telegram и PC-юзерами. НЕ видит APK-юзеров.
- Один бинарь можно параметризовать флагом сборки (два app-target'а / две схемы).

## Ребренд (точки из репо)
`build-system/appstore-configuration.json`:
- `bundle_id`: `ph.telegra.Telegraph` → `org.coregram.messenger` (как Android; для B-варианта
  можно `org.coregram.messenger.tg`, чтобы обе версии стояли рядом).
- `api_id`/`api_hash`: A-вариант — сервер не проверяет (любые валидные по формату);
  B-вариант — реальные с my.telegram.org.
- `app_specific_url_scheme`: `tg` → `coregram`.
- `team_id`: свой (из Apple Developer, если $99) или пусто для adhoc/free-sign.

Имя приложения — `APP_NAME` (build var) → «CoreGram». `Info.plist` использует `${APP_NAME}`,
`$(PRODUCT_BUNDLE_IDENTIFIER)`, `$(PRODUCT_NAME)` — задаётся конфигом сборки.
Иконка/ассеты: `Telegram/Telegram-iOS/Assets.xcassets` + `AlternateIcons.plist`.

## Сборка
Локально на Mac: `python3 build-system/Make/Make.py build --configurationPath <config>.json`
CI: см. `.github/workflows/ios-build.yml` (в этом каталоге) — клон, ребренд-патч, build, artifact.

## Что дальше (только на Mac-стороне)
1. Форкнуть Telegram-iOS в GitHub minato4kaYT, применить `rebrand/` патч.
2. Прогнать CI (или локально на Mac с Xcode 26.2). Почти наверняка потребуется итеративная
   доводка (Bazel/провижининг) — это нормально для Telegram-iOS.
3. Подписать .ipa (free Apple ID / $99) → Sideloadly на iPhone.

Связано: экосистема CoreGram (APK `/root/coreclient`, desktop `/root/coredesktop`, сервер `/root/coregram`).
