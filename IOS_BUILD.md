# CoreGram iOS — сборка .ipa

Собрать/подписать iOS можно **только на macOS** (Telegram-iOS = Bazel + Xcode).
С Linux-сервера — нельзя. Поэтому сборка идёт на **GitHub Actions macOS-раннере**.

## Что уже готово
- **Репо:** `github.com/eternald3v/coregram-ios` (ветка `main`, уже запушено).
- **Workflow:** `.github/workflows/ios-build.yml` — клонирует Telegram-iOS
  `release-12.9.2`, применяет ребренд (`rebrand/`), собирает через
  `build-system/Make/Make.py` с `fake-codesigning`, пакует **неподписанный .ipa**
  и выгружает его артефактом. Логи выгружаются всегда (для доводки на Mac).
- **Ребренд:** `rebrand/apply_branding.sh` (имя «CoreGram», bundle id,
  url-scheme), `rebrand/apply_our_network.sh` (сид-DC на наш `gramsrv` для
  варианта «our»), + `appstore-configuration.our.json` / `.tg.json`.

## Как запустить сборку
1. GitHub → репо `coregram-ios` → вкладка **Actions** → workflow **CoreGram iOS**.
2. **Run workflow** (workflow_dispatch), параметры:
   - `variant`:
     - **our** — наша сеть (подключается к `gramsrv`, переписка с APK-юзерами). Секреты не нужны.
     - **tg** — реальный Telegram. Требует секретов `COREGRAM_API_ID` / `COREGRAM_API_HASH`
       (с my.telegram.org) в Settings → Secrets → Actions.
   - `tg_ref`: ref Telegram-iOS (по умолчанию `release-12.9.2`).
3. Дождаться сборки (Telegram-iOS собирается долго, до ~3 ч на первой итерации;
   Bazel-кэш ускоряет повторные).
4. Готовый файл — в **Artifacts** прогона: `coregram-ios-<variant>` → `*.ipa`
   (`Telegram.ipa` или фоллбэк `CoreGram-unsigned.ipa`). Рядом `build-logs-*`.

## Установка на iPhone (iOS 26.6)
IPA из CI **неподписанный** — нужно подписать своим Apple ID:
- **Sideloadly / AltStore + бесплатный Apple ID** — подпись живёт **7 дней**
  (потом переподписать), лимит 3 приложения, без пушей.
- **$99 Apple Developer** — подпись на год, «поставил и забыл».
- **TrollStore — НЕ работает** на 26.6 (CoreTrust закрыт с iOS 16.7/17.0).
- App Store клон не пропустит — только сайдлоад.

## Триггеры
Сейчас — только ручной (**workflow_dispatch**). Чтобы собирать по тегу, добавить
в `ios-build.yml`:
```yaml
on:
  workflow_dispatch: { ... }   # как сейчас
  push:
    tags: ["ios-v*"]           # сборка на пуш тега ios-v*
```

## Остаточные риски (правятся только на Mac)
- GitHub-раннер может не иметь Xcode 26.2 — workflow берёт самый свежий и
  переопределяет версию (`--overrideXcodeVersion`); при несовместимости —
  self-hosted Mac.
- `rules_apple` при неподписанной сборке может отдать бандл, который придётся
  до-подписать (для сайдлоада это и так делается).
- Ребренд best-effort: часть строк/иконок доводится вручную по логам.
