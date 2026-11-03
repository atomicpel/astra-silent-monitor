#!/usr/bin/env bash
# Сборка офлайн-комплекта внутри контейнера Astra Linux 1.8 (GitHub Actions).
# Переменные: ASTRA_VERSION (например 1.8.5; пусто = последняя),
#             AGENT_VERSION (пусто = как версия Zabbix в репозитории Astra)
set -Eeuo pipefail
cd "$(dirname "$0")/.."

BASE=https://dl.astralinux.ru/astra/frozen/1.8_x86-64
echo "== Образ: $(cat /etc/astra_version 2>/dev/null || echo '?')"

export DEBIAN_FRONTEND=noninteractive
apt-get update || true
apt-get install -y curl ca-certificates || true
command -v curl >/dev/null || { echo "Нет curl в образе"; exit 1; }

if [[ -z ${ASTRA_VERSION:-} ]]; then
  ASTRA_VERSION=$(curl -fsSL "$BASE/" | grep -oE '1\.8\.[0-9]+(\.[0-9]+)?/' | tr -d / | sort -uV | tail -1)
fi
[[ -n $ASTRA_VERSION ]] || { echo "Не удалось определить версию Astra"; exit 1; }
echo "== Версия репозиториев Astra: $ASTRA_VERSION"

: > /etc/apt/sources.list
rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources
found=0
for sub in repository-main main-repository repository-base base-repository \
           repository-extended extended-repository; do
  for rel in InRelease Release; do
    if curl -fsSI "$BASE/$ASTRA_VERSION/$sub/dists/1.8_x86-64/$rel" >/dev/null; then
      echo "deb $BASE/$ASTRA_VERSION/$sub/ 1.8_x86-64 main contrib non-free" >> /etc/apt/sources.list
      echo "   + $sub"; found=1; break
    fi
  done
done
(( found )) || { echo "Репозитории $ASTRA_VERSION не найдены"; exit 1; }
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
