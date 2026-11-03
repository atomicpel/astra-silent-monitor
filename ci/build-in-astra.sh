#!/usr/bin/env bash
# Сборка офлайн-комплекта внутри контейнера Astra Linux 1.8 (GitHub Actions).
# Переменные: ASTRA_VERSION (например 1.8.5; пусто = версия образа),
#             AGENT_VERSION (пусто = как версия Zabbix в репозитории Astra)
set -Eeuo pipefail
cd "$(dirname "$0")/.."

echo "== Образ: $(cat /etc/astra_version 2>/dev/null || echo '?')"

export DEBIAN_FRONTEND=noninteractive
IMG_VER=$(cat /etc/astra_version 2>/dev/null || true)
ASTRA_VERSION=${ASTRA_VERSION:-$IMG_VER}
[[ -n $ASTRA_VERSION ]] || { echo "Не удалось определить версию Astra"; exit 1; }
echo "== Версия репозиториев Astra: $ASTRA_VERSION"

# Источники образа уже указывают на frozen-репозитории его версии.
# Если нужна другая версия — подменяем номер версии в адресах.
grep -rhE '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null > /tmp/src || true
if [[ ! -s /tmp/src ]]; then
  for sub in main-repository extended-repository; do
    echo "deb https://download.astralinux.ru/astra/frozen/1.8_x86-64/${ASTRA_VERSION}/${sub}/ 1.8_x86-64 main contrib non-free"
  done > /tmp/src
fi
if [[ -n $IMG_VER && $ASTRA_VERSION != "$IMG_VER" ]]; then
  sed -i "s#/${IMG_VER}/#/${ASTRA_VERSION}/#g" /tmp/src
fi
rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources
cp /tmp/src /etc/apt/sources.list
cat /etc/apt/sources.list
apt-get update

ZBX=$(apt-cache policy zabbix-server-pgsql | awk '/Candidate|Кандидат/{print $2}')
echo "== Zabbix в репозитории: ${ZBX:-НЕТ}"
[[ -n $ZBX && $ZBX != "(none)" ]] || { echo "zabbix-server-pgsql не найден в репозиториях $ASTRA_VERSION"; exit 1; }
if [[ -z ${AGENT_VERSION:-} ]]; then
  AGENT_VERSION=$(sed -E 's/^[0-9]+://; s/[+~-].*//' <<<"$ZBX")
fi
export AGENT_VERSION
echo "== Агент Windows: $AGENT_VERSION"

rm -f config.env hosts.txt
./1-prepare-online.sh

{
  echo "Astra Linux SE: $ASTRA_VERSION (frozen)"
  echo "Репозитории:"; sed 's/^/  /' /etc/apt/sources.list
  echo "Zabbix server: $ZBX"
  echo "Агент Windows: $AGENT_VERSION"
  echo "Собрано: $(date -u '+%F %T UTC')"
  echo "SHA256 архива: $(cut -d' ' -f1 bundle/astra-silent-monitor-bundle.tar.gz.sha256)"
} | tee bundle/BUILD-INFO.txt
echo "ASTRA_VERSION=$ASTRA_VERSION" > bundle/build.env
