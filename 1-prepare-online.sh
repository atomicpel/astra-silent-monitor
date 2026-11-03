#!/usr/bin/env bash
# =====================================================================
#  ШАГ 1. Запускать на машине С ИНТЕРНЕТОМ, где стоит Astra Linux SE
#  той же версии, что будет на сервере (например 1.8.x), с подключёнными
#  официальными репозиториями Astra (main + extended).
#
#  Результат: bundle/astra-silent-monitor-bundle.tar.gz + .sha256
#  — локальный подписанный репозиторий со всеми зависимостями,
#    агент Zabbix для Windows и все скрипты.
#
#  Использование:  sudo ./1-prepare-online.sh
# =====================================================================
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
need_root

AGENT_VERSION="7.0.10"
# shellcheck disable=SC1091
[[ -f ${ROOT_DIR}/config.env ]] && source "${ROOT_DIR}/config.env"

OUT="${ROOT_DIR}/bundle"
STAGE="${OUT}/astra-silent-monitor"
REPO="${STAGE}/repo"

if [[ -f /etc/astra_version ]]; then
  log "Версия Astra на этой машине: $(cat /etc/astra_version)"
  log "На сервере должна быть ТА ЖЕ версия, иначе зависимости могут не сойтись."
else
  warn "Это не Astra Linux. Пакеты нужно скачивать на Astra той же версии, что и сервер."
  read -rp "Продолжить всё равно? [y/N] " a; [[ $a == y ]] || exit 1
fi

log "Ставлю инструменты сборки (apt-utils, gnupg, curl)"
apt-get update
apt-get install -y apt-utils gnupg curl ca-certificates

rm -rf "$STAGE"; mkdir -p "$REPO" "${STAGE}/windows"

# --- 1. Проверка, что все пакеты есть в репозиториях -----------------
ALL_PKGS=("${SERVER_PKGS[@]}" "${EXTRA_PKGS[@]}")
missing=()
for p in "${ALL_PKGS[@]}"; do
  apt-cache show --no-all-versions "$p" >/dev/null 2>&1 || missing+=("$p")
done
if (( ${#missing[@]} )); then
  warn "В подключённых репозиториях не найдены: ${missing[*]}"
  warn "Проверьте, что подключён extended-репозиторий Astra 1.8:"
  warn "  apt-cache search zabbix"
  die  "Без этих пакетов сборка невозможна."
fi
log "Версия Zabbix в репозитории: $(apt-cache policy zabbix-server-pgsql | awk '/Кандидат|Candidate/{print $2}')"

# --- 2. Полное дерево зависимостей ------------------------------------
# Скачиваем всё дерево целиком, включая то, что уже стоит в системе:
# так набор не зависит от того, что именно установлено на сервере.
log "Вычисляю полное дерево зависимостей"
mapfile -t closure < <(
  apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
    --no-breaks --no-replaces --no-enhances "${ALL_PKGS[@]}" \
  | grep -E '^[a-zA-Z0-9]' | grep -v ':' | sort -u
)
real=()
for p in "${closure[@]}"; do
  # виртуальные пакеты пропускаем — у них нет кандидата для скачивания
  apt-cache show --no-all-versions "$p" >/dev/null 2>&1 && real+=("$p")
done
log "Пакетов к скачиванию: ${#real[@]}"

log "Скачиваю пакеты"
( cd "$REPO" && apt-get download "${real[@]}" )
log "Скачано: $(ls "$REPO"/*.deb | wc -l) файлов, $(du -sh "$REPO" | cut -f1)"

# --- 3. Индекс репозитория и подпись ----------------------------------
log "Строю индекс локального репозитория"
( cd "$REPO"
  apt-ftparchive packages . > Packages
  gzip -9kf Packages
  apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=astra-silent-monitor \
    -o APT::FTPArchive::Release::Label=astra-silent-monitor \
    -o APT::FTPArchive::Release::Suite=offline \
    -o APT::FTPArchive::Release::Codename=offline \
    release . > Release
)

log "Подписываю репозиторий одноразовым ключом"
GNUPGHOME=$(mktemp -d); export GNUPGHOME; chmod 700 "$GNUPGHOME"
trap 'rm -rf "$GNUPGHOME"' EXIT
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "astra-silent-monitor offline repo $(date +%F)" ed25519 sign 2y
gpg --batch --yes --clearsign -o "$REPO/InRelease" "$REPO/Release"
gpg --batch --yes -abs -o "$REPO/Release.gpg" "$REPO/Release"
gpg --batch --export > "${STAGE}/offline-repo.gpg"
gpg --batch --list-keys --with-colons | awk -F: '/^fpr/{print $10; exit}' > "${STAGE}/offline-repo.fingerprint"
log "Отпечаток ключа: $(cat "${STAGE}/offline-repo.fingerprint")"
# закрытый ключ уничтожается при выходе (trap) — подделать подпись потом нельзя

# --- 4. Агент для Windows ---------------------------------------------
MAJ="${AGENT_VERSION%.*}"
MSI="zabbix_agent2-${AGENT_VERSION}-windows-amd64-openssl.msi"
URL="https://cdn.zabbix.com/zabbix/binaries/stable/${MAJ}/${AGENT_VERSION}/${MSI}"
log "Скачиваю агент Windows: ${URL}"
if curl -fL --retry 3 -o "${STAGE}/windows/${MSI}" "$URL"; then
  log "SHA256 агента: $(sha256sum "${STAGE}/windows/${MSI}" | cut -d' ' -f1)"
  log "Сверьте его с контрольной суммой на странице загрузки zabbix.com!"
else
  warn "Агент не скачался. Скачайте вручную ${MSI} с zabbix.com/download_agents"
  warn "и положите в ${STAGE}/windows/"
fi

# --- 5. Скрипты --------------------------------------------------------
log "Копирую скрипты"
cp -a "${ROOT_DIR}/lib" "${ROOT_DIR}"/[2-9]-*.sh "${ROOT_DIR}/README.md" \
      "${ROOT_DIR}/config.env.example" "${ROOT_DIR}/hosts.txt.example" "$STAGE/"
cp -a "${ROOT_DIR}/windows/"*.ps1 "${STAGE}/windows/"
# Заполненные config.env / hosts.txt кладём, только если они есть
for f in config.env hosts.txt; do
  [[ -f ${ROOT_DIR}/$f ]] && cp "${ROOT_DIR}/$f" "$STAGE/"
done

# --- 6. Архив и контрольные суммы -------------------------------------
( cd "$STAGE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
TAR="${OUT}/astra-silent-monitor-bundle.tar.gz"
tar -C "$OUT" -czf "$TAR" astra-silent-monitor
sha256sum "$TAR" > "${TAR}.sha256"

log "Готово: ${TAR} ($(du -h "$TAR" | cut -f1))"
log "SHA256: $(cut -d' ' -f1 "${TAR}.sha256")"
log "Запишите эту сумму на бумагу и сверьте на сервере перед установкой."
