#!/usr/bin/env bash
#
# apply_our_network.sh — Вариант A для Telegram-iOS (tag release-12.9.2).
# Пришиваем iOS-клиент к НАШЕМУ единственному MTProto-серверу (CoreGram),
# по аналогии с APK (ConnectionsManager.cpp addAddressAndPort) и TDesktop
# (mtproto_dc_options.cpp: свой endpoint + kPublicRSAKeys + f_tcpo_only).
#
# НАШ СЕРВЕР:  2.26.123.219 : 2398, dc_id 2, TL layer 228, только TCP-obfuscated.
# НАШ RSA:     rebrand/server_rsa_public.pem (PKCS#1). Fingerprint клиент
#              вычисляет сам из PEM (MTRsaFingerprint), хардкодить не нужно.
#
# ВАЖНО: скрипт ДЕТЕРМИНИРОВАННЫЙ и ПАДАЕТ ГРОМКО (exit 1), если хоть один
# ожидаемый якорь не найден. Лучше уронить сборку, чем молча выпустить
# клиент, который снова коннектится к настоящему Telegram.
#
set -euo pipefail

OUR_HOST="2.26.123.219"
OUR_PORT="2398"

log()  { echo ">> apply_our_network: $*"; }
die()  { echo "::error::apply_our_network: $*" >&2; exit 1; }

# --- 0. Определяем корень репозитория (там, где лежит submodules/) ---------
ROOT=""
for cand in "${GITHUB_WORKSPACE:-}" "$(pwd)" "$(cd "$(dirname "$0")/.." && pwd)"; do
  [ -n "$cand" ] || continue
  if [ -d "$cand/submodules" ]; then ROOT="$cand"; break; fi
done
[ -n "$ROOT" ] || die "не нашёл корень репозитория (нет каталога submodules/). GITHUB_WORKSPACE=${GITHUB_WORKSPACE:-<не задан>}"
cd "$ROOT"
log "корень репозитория: $ROOT"

NETWORK_SWIFT="submodules/TelegramCore/Sources/Network/Network.swift"
AUTH_M="submodules/MtProtoKit/Sources/MTDatacenterAuthMessageService.m"
[ -f "$NETWORK_SWIFT" ] || die "нет файла $NETWORK_SWIFT — структура репозитория изменилась"
[ -f "$AUTH_M" ]        || die "нет файла $AUTH_M — структура репозитория изменилась"

# --- 1. Читаем наш PEM -----------------------------------------------------
RSA_SRC=""
for cand in "${GITHUB_WORKSPACE:-}/rebrand/server_rsa_public.pem" \
            "$ROOT/rebrand/server_rsa_public.pem" \
            "rebrand/server_rsa_public.pem" \
            "../rebrand/server_rsa_public.pem"; do
  [ -n "$cand" ] || continue
  if [ -f "$cand" ]; then RSA_SRC="$cand"; break; fi
done
[ -n "$RSA_SRC" ] || die "не нашёл rebrand/server_rsa_public.pem — положи публичный RSA gramsrv"
grep -q "BEGIN RSA PUBLIC KEY" "$RSA_SRC" || die "$RSA_SRC не похож на PKCS#1 PEM (нет 'BEGIN RSA PUBLIC KEY')"
log "RSA-ключ: $RSA_SRC"

# Obj-C строковый литерал: одна строка @"...\n...\n...", переводы строк -> \n
OBJC_KEY="$(awk 'BEGIN{ORS=""} {gsub(/\r/,""); print $0 "\\n"}' "$RSA_SRC" | sed 's/\\n$//')"
[ -n "$OBJC_KEY" ] || die "не смог собрать Obj-C литерал ключа из $RSA_SRC"

# ==========================================================================
# (A)+(C)+(D) Network.swift: сид-адреса всех DC -> наш сервер, порт 2398,
#             restrictToTcp: true (TCP-obfuscated-only, аналог f_tcpo_only).
# ==========================================================================

# (A) production seedAddressList: заменяем весь блок 1..5 на наш единственный DC.
# ВНИМАНИЕ (fork loyldg/mytelegram-iOS@master, app 12.6.2): fork УЖЕ переписал
# сид-адреса на свой сервер (192.168.1.100:20443), поэтому якориться на стоковые
# 149.154.* НЕЛЬЗЯ. Проверяем СТРУКТУРУ production-блока (5 DC), а не конкретные IP;
# сама замена ниже (perl) IP-агностична ([^\]]*) и падает громко, если $n != 1.
PROD_SEED_CNT="$(perl -0777 -ne '$c=()=/seedAddressList\s*=\s*\[\s*\n\s*1:\s*\[[^\]]*\],\s*\n\s*2:\s*\[[^\]]*\],\s*\n\s*3:\s*\[[^\]]*\],\s*\n\s*4:\s*\[[^\]]*\],\s*\n\s*5:\s*\[[^\]]*\]\s*\n\s*\]/g; print $c' "$NETWORK_SWIFT")"
[ "$PROD_SEED_CNT" = "1" ] || die "не нашёл production seedAddressList (5 DC) в $NETWORK_SWIFT — структура изменилась (нашёл $PROD_SEED_CNT)"

perl -0pi -e '
  my $our = "'"$OUR_HOST"'";
  my $n = s/
    (\bseedAddressList\s*=\s*\[\s*\n)      # открытие production-массива
    \s*1:\s*\[[^\]]*\],\s*\n
    \s*2:\s*\[[^\]]*\],\s*\n
    \s*3:\s*\[[^\]]*\],\s*\n
    \s*4:\s*\[[^\]]*\],\s*\n
    \s*5:\s*\[[^\]]*\]\s*\n
    (\s*\])                                # закрытие
  /$1
                    1: ["$our"],
                    2: ["$our"],
                    3: ["$our"],
                    4: ["$our"],
                    5: ["$our"]
                $2/gx;
  END { die "PRODUCTION_SEED_NOT_REPLACED\n" unless $n == 1 }
' "$NETWORK_SWIFT" || die "не удалось заменить production seedAddressList (perl-якорь не сработал)"
log "(A) production seedAddressList -> $OUR_HOST (DC 1..5)"

# (A-debug) testing seedAddressList (используется в DEBUG-сборках, DC1..3): туда же.
perl -0pi -e '
  my $our = "'"$OUR_HOST"'";
  my $n = s/
    (if\s+testingEnvironment\s*\{\s*\n\s*seedAddressList\s*=\s*\[\s*\n)
    \s*1:\s*\[[^\]]*\],\s*\n
    \s*2:\s*\[[^\]]*\],\s*\n
    \s*3:\s*\[[^\]]*\]\s*\n
    (\s*\])
  /$1
                    1: ["$our"],
                    2: ["$our"],
                    3: ["$our"]
                $2/gx;
  END { die "TESTING_SEED_NOT_REPLACED\n" unless $n == 1 }
' "$NETWORK_SWIFT" || die "не удалось заменить testing seedAddressList (perl-якорь не сработал)"
log "(A-debug) testing seedAddressList -> $OUR_HOST (DC 1..3)"

# (C)+(D) строка сборки MTDatacenterAddress для сид-адресов: порт и restrictToTcp.
# ВНИМАНИЕ: fork использует port: 20443 (не 443), release-12.9.2 — port: 443.
# Якорь порт-агностичен (\d+), поэтому скрипт работает и на fork, и на upstream.
SEED_CTOR_CNT="$(perl -0777 -ne '$c=()=/MTDatacenterAddress\(ip: \$0, port: \d+, preferForMedia: false, restrictToTcp: false/g; print $c' "$NETWORK_SWIFT")"
[ "$SEED_CTOR_CNT" = "1" ] || die "не нашёл сид-строку MTDatacenterAddress(ip:\$0, port:<N>, restrictToTcp:false) в $NETWORK_SWIFT (нашёл $SEED_CTOR_CNT)"
perl -0pi -e '
  my $n = s/MTDatacenterAddress\(ip: \$0, port: \d+, preferForMedia: false, restrictToTcp: false/MTDatacenterAddress(ip: \$0, port: '"$OUR_PORT"', preferForMedia: false, restrictToTcp: true/g;
  END { die "SEED_ADDR_CTOR_NOT_PATCHED\n" unless $n == 1 }
' "$NETWORK_SWIFT" || die "не удалось пропатчить сид-строку MTDatacenterAddress (порт/restrictToTcp)"
log "(C)+(D) сид MTDatacenterAddress: port -> $OUR_PORT, restrictToTcp false -> true (TCP-obfuscated-only)"

# ==========================================================================
# (B) MTDatacenterAuthMessageService.m: production+testing RSA -> наш ключ.
#     Fingerprint клиент вычислит сам из PEM (MTRsaFingerprint), поэтому
#     достаточно подставить PEM. Наш DC отдаёт fingerprint 0x9b3557ecb31999e6,
#     он совпадёт с вычисленным из этого же ключа.
# ==========================================================================
grep -q 'productionPublicKeys = @\[' "$AUTH_M" || die "не нашёл productionPublicKeys в $AUTH_M"
grep -q 'testingPublicKeys = @\['    "$AUTH_M" || die "не нашёл testingPublicKeys в $AUTH_M"

perl -0pi -e '
  my $key = q{'"$OBJC_KEY"'};
  my $repl_prod = "productionPublicKeys = \@[\n            [[MTDatacenterAuthPublicKey alloc] initWithPublicKey:\@\"$key\"]\n        ];";
  my $repl_test = "testingPublicKeys = \@[\n            [[MTDatacenterAuthPublicKey alloc] initWithPublicKey:\@\"$key\"]\n        ];";
  my $np = s/productionPublicKeys\s*=\s*\@\[.*?\];/$repl_prod/s;
  my $nt = s/testingPublicKeys\s*=\s*\@\[.*?\];/$repl_test/s;
  END {
    die "PRODUCTION_KEYS_NOT_REPLACED\n" unless $np == 1;
    die "TESTING_KEYS_NOT_REPLACED\n"    unless $nt == 1;
  }
' "$AUTH_M" || die "не удалось заменить RSA-ключи в $AUTH_M"
log "(B) production+testing RSA public keys -> наш ключ из $RSA_SRC"

# --- Верификация постфактум ------------------------------------------------
FAIL=0
grep -q "\"$OUR_HOST\"" "$NETWORK_SWIFT"                 || { echo "::error:: нет $OUR_HOST в $NETWORK_SWIFT" >&2; FAIL=1; }
grep -q "port: $OUR_PORT, preferForMedia: false, restrictToTcp: true" "$NETWORK_SWIFT" || { echo "::error:: не применились port/restrictToTcp в $NETWORK_SWIFT" >&2; FAIL=1; }
grep -q "149.154" "$NETWORK_SWIFT"                       && { echo "::error:: остались стоковые 149.154 адреса в $NETWORK_SWIFT" >&2; FAIL=1; }
OUR_KEY_HEAD="$(sed -n '2p' "$RSA_SRC" | cut -c1-24)"
grep -q "$OUR_KEY_HEAD" "$AUTH_M"                        || { echo "::error:: наш ключ не найден в $AUTH_M" >&2; FAIL=1; }
grep -q "MIIBCgKCAQEA6LszBcC1LGzyr" "$AUTH_M"            && { echo "::error:: остался стоковый production TG-ключ в $AUTH_M" >&2; FAIL=1; }
[ "$FAIL" -eq 0 ] || die "постпроверка не прошла — сеть НЕ перенастроена корректно"

log "ГОТОВО. Все правки применены и проверены:"
log "  - сид-адреса всех DC   -> $OUR_HOST:$OUR_PORT (restrictToTcp)"
log "  - fresh-account dc_id   = 2 (release) уже указывает на наш DC"
log "  - RSA production+testing -> наш ключ ($RSA_SRC)"
exit 0
