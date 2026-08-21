#!/usr/bin/env bash
#
# apply_stars_withdraw_no2fa.sh
#
# Вывод звёздного дохода канала без двухфакторки.
#
# Как это устроено в оригинале (release-12.9.2):
#   1. Экран дохода дёргает _internal_checkStarsRevenueWithdrawalAvailability —
#      «пробу»: payments.getStarsRevenueWithdrawalUrl с пустым peer и пустой
#      проверкой пароля. Она ВСЕГДА падает, и по тексту ошибки клиент решает,
#      что показать: PASSWORD_HASH_INVALID -> спросить пароль,
#      PASSWORD_MISSING -> предложить включить 2FA, что угодно ещё -> «An error
#      occurred, please try again later».
#   2. Настоящий вывод (_internal_requestStarsRevenueWithdrawalUrl) отказывается
#      работать с пустым паролем и считает отсутствие 2FA ошибкой
#      .twoStepAuthMissing.
#
# У CoreGram двухфакторка для вывода не нужна: сервер принимает
# inputCheckPasswordEmpty у аккаунта без пароля и сразу переводит звёзды на
# баланс владельца. Поэтому патч:
#   * в TelegramCore: пустой пароль больше не отказ, а отсутствие пароля у
#     аккаунта даёт inputCheckPasswordEmpty вместо ошибки twoStepAuthMissing;
#   * в UI: ответ «2FA не настроена» больше не ведёт к предложению включить
#     двухфакторку, а открывает тот же диалог подтверждения, что и с паролем —
#     введённое значение сервером не проверяется, если пароля на аккаунте нет.
#
# FAILS LOUD: если якоря не найдены ровно один раз — выходим с ошибкой, чтобы
# сборка не уехала молча без фичи.
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
        if [ -f "$c/submodules/TelegramCore/Sources/Statistics/StarsRevenueStatistics.swift" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
    if ! REPO_ROOT="$(find_root)"; then
        echo "ERROR: не нашёл корень Telegram-iOS (нужен submodules/TelegramCore/Sources/Statistics/StarsRevenueStatistics.swift)." >&2
        exit 1
    fi
fi

CORE="$REPO_ROOT/submodules/TelegramCore/Sources/Statistics/StarsRevenueStatistics.swift"
UI="$REPO_ROOT/submodules/TelegramUI/Components/Stars/StarsWithdrawalScreen/Sources/StarsRevenueWithdrawalController.swift"

for f in "$CORE" "$UI"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: не найден файл: $f" >&2
        exit 1
    fi
done

MARKER="CoreGram: вывод без 2FA"
if grep -q "$MARKER" "$CORE"; then
    echo "apply_stars_withdraw_no2fa.sh: патч уже применён, пропускаю."
    exit 0
fi

python3 - "$CORE" "$UI" <<'PY'
import sys

core_path, ui_path = sys.argv[1], sys.argv[2]

core = open(core_path, encoding='utf-8').read()

guard = """    guard !password.isEmpty else {
        return .fail(.invalidPassword)
    }
"""
if core.count(guard) != 1:
    raise SystemExit("ERROR: якорь guard !password.isEmpty найден %d раз" % core.count(guard))
core = core.replace(guard, """    // CoreGram: вывод без 2FA — пустой пароль допустим, ниже он превращается
    // в inputCheckPasswordEmpty, которую сервер принимает у аккаунтов без
    // двухфакторки.
""", 1)

missing = """            } else {
                return .fail(.twoStepAuthMissing)
            }
"""
if core.count(missing) != 1:
    raise SystemExit("ERROR: якорь twoStepAuthMissing найден %d раз" % core.count(missing))
core = core.replace(missing, """            } else {
                // CoreGram: вывод без 2FA — пароля на аккаунте нет, поэтому
                // отправляем пустую проверку вместо отказа.
                return .single(.inputCheckPasswordEmpty)
            }
""", 1)

srp_branch = """            if let currentPasswordDerivation = authData.currentPasswordDerivation, let srpSessionData = authData.srpSessionData {"""
if core.count(srp_branch) != 1:
    raise SystemExit("ERROR: якорь SRP-ветки найден %d раз" % core.count(srp_branch))
core = core.replace(srp_branch, """            if password.isEmpty {
                return .single(.inputCheckPasswordEmpty)
            }
""" + srp_branch, 1)

open(core_path, 'w', encoding='utf-8').write(core)

ui = open(ui_path, encoding='utf-8').read()
start_anchor = "    case .twoStepAuthMissing:"
end_anchor = "    default:"
start = ui.find(start_anchor)
if start < 0 or ui.count(start_anchor) != 1:
    raise SystemExit("ERROR: якорь twoStepAuthMissing в UI найден %d раз" % ui.count(start_anchor))
end = ui.find(end_anchor, start)
if end < 0:
    raise SystemExit("ERROR: не нашёл конец ветки twoStepAuthMissing в UI")
replacement = """    case .twoStepAuthMissing:
        // CoreGram: вывод без 2FA — вместо предложения включить двухфакторку
        // открываем обычное подтверждение вывода; пароль у аккаунта без 2FA
        // сервер не проверяет.
        return confirmStarsRevenueWithdrawalController(context: context, updatedPresentationData: updatedPresentationData, peerId: peerId, amount: amount, present: present, completion: completion)
"""
ui = ui[:start] + replacement + ui[end:]
open(ui_path, 'w', encoding='utf-8').write(ui)
PY

echo "apply_stars_withdraw_no2fa.sh: ok"
