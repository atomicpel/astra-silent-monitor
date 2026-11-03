#!/usr/bin/env bash
# Установка zabbix-agent на Linux-ПК (Astra 1.8) из локального репозитория
# на флешке. Режим «только опрос сервером», PSK, удалённые команды запрещены.
# Использование: sudo ./install-linux-agent.sh IP_СЕРВЕРА ИМЯ PSK_IDENTITY ФАЙЛ_PSK
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Запустите от root"; exit 1; }
SERVER=$1 NAME=$2 IDENT=$3 PSKSRC=$4
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ $(tr -d '\n' < "$PSKSRC") =~ ^[0-9a-f]{64}$ ]] || { echo "Неверный PSK"; exit 1; }

LIST=$(mktemp)
echo "deb [signed-by=${HERE}/repo/offline-repo.gpg] file:${HERE}/repo ./" > "$LIST"
OPTS=(-o "Dir::Etc::sourcelist=$LIST" -o "Dir::Etc::sourceparts=-" -o "APT::Get::List-Cleanup=0")
apt-get "${OPTS[@]}" update
DEBIAN_FRONTEND=noninteractive apt-get "${OPTS[@]}" install -y --no-install-recommends zabbix-agent
rm -f "$LIST"

install -o zabbix -g zabbix -m 400 "$PSKSRC" /etc/zabbix/agent.psk
C=/etc/zabbix/zabbix_agentd.conf
sed -i -E '/^\s*(Server|ServerActive|Hostname|ListenPort|TLSConnect|TLSAccept|TLSPSKIdentity|TLSPSKFile|DenyKey|AllowKey|EnableRemoteCommands)\s*=/d' "$C"
cat >> "$C" <<EOF

### astra-silent-monitor ###
Server=${SERVER}
# ServerActive не задан: агент сам никуда не подключается
Hostname=${NAME}
ListenPort=10050
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=${IDENT}
TLSPSKFile=/etc/zabbix/agent.psk
DenyKey=system.run[*]
EOF
chmod 640 "$C"; chown root:zabbix "$C"
systemctl enable --now zabbix-agent
systemctl restart zabbix-agent
rm -f "$PSKSRC"
echo "[+] Агент запущен. Файл ключа удалён с носителя."
echo "[!] Ограничьте порт 10050 на этом ПК только адресом ${SERVER} (ufw/nftables/iptables)."
