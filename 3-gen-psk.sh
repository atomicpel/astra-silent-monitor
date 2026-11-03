#!/usr/bin/env bash
# =====================================================================
#  ШАГ 3. Ключи PSK для агентов и комплекты установки на ПК.
#  Запускать на сервере после 2-install-offline.sh.
#
#  - Для КАЖДОГО узла свой ключ (утечка ключа с одного ПК не раскрывает
#    остальные). Ключи хранятся в /etc/silent-monitor/psk.csv (root, 600).
#  - Повторный запуск не меняет существующие ключи; новые узлы из
#    hosts.txt получают новые. Перевыпустить ключ узла:
#       ./3-gen-psk.sh --rotate имя_узла
#  - Для каждой сети собирается отдельная папка psk-export/<сеть>/.
#    Носите на каждую сеть ОТДЕЛЬНУЮ флешку — не переносите один
#    носитель между изолированными сетями.
# =====================================================================
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
need_root
load_config
load_hosts
(( ${#H_IP[@]} )) || die "hosts.txt пуст — сначала заполните его."

DB=/etc/silent-monitor/psk.csv
OUT="${ROOT_DIR}/psk-export"
ROTATE="${2:-}"; [[ ${1:-} == --rotate ]] || ROTATE=""

umask 077
mkdir -p /etc/silent-monitor; chmod 700 /etc/silent-monitor
touch "$DB"; chmod 600 "$DB"

declare -A ID KEY
while IFS=, read -r name identity key; do
  [[ -z $name || $name == name ]] && continue
  ID[$name]=$identity; KEY[$name]=$key
done < "$DB"

[[ -n $ROTATE && -z ${ID[$ROTATE]:-} ]] && die "Узла '$ROTATE' нет в базе ключей"

new=0
for i in "${!H_IP[@]}"; do
  name=${H_NAME[$i]}
  [[ ${H_OS[$i]} == ping ]] && continue
  if [[ -z ${ID[$name]:-} || $name == "$ROTATE" ]]; then
    # Идентификатор PSK передаётся открытым текстом при рукопожатии TLS,
    # поэтому он случайный и ничего не говорит о назначении сервера.
    ID[$name]="id-$(openssl rand -hex 8)"
    KEY[$name]="$(openssl rand -hex 32)"     # 256 бит
    new=$((new+1))
  fi
done

{ echo "name,identity,psk"; for n in "${!ID[@]}"; do echo "$n,${ID[$n]},${KEY[$n]}"; done; } | sort > "$DB"
log "Ключей в базе: $(( $(wc -l < "$DB") - 1 )), новых/перевыпущенных: $new"

# --- Комплекты по сетям ----------------------------------------------
rm -rf "$OUT"; mkdir -p "$OUT"
MSI=$(ls "${ROOT_DIR}"/windows/zabbix_agent2-*-windows-amd64-openssl.msi 2>/dev/null | head -1 || true)

for net in "${NET_NAMES[@]}"; do
  srv_ip=${NET_ADDR[$net]%/*}
  d="$OUT/$net"; has_win=0; has_lin=0
  for i in "${!H_IP[@]}"; do
    [[ ${H_NET[$i]} == "$net" ]] || continue
    os=${H_OS[$i]}; name=${H_NAME[$i]}
    [[ $os == ping ]] && continue
    mkdir -p "$d"
    printf '%s' "${KEY[$name]}" > "$d/$name.psk"
    if [[ $os == win ]]; then
      has_win=1
      cat > "$d/install-$name.cmd" <<EOF
@echo off
chcp 65001 >nul
rem Установка агента Zabbix на ${name} (${H_IP[$i]}). Запускать от имени администратора.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-agent.ps1" ^
  -Msi "%~dp0zabbix_agent2.msi" -Server ${srv_ip} -HostName ${name} ^
  -PskIdentity ${ID[$name]} -PskFile "%~dp0${name}.psk"
pause
EOF
      sed -i 's/$/\r/' "$d/install-$name.cmd"
    else
      has_lin=1
      cat > "$d/install-$name.sh" <<EOF
#!/bin/sh
# Установка агента Zabbix на ${name} (${H_IP[$i]}). Запускать от root.
cd "\$(dirname "\$0")" && exec ./install-linux-agent.sh ${srv_ip} ${name} ${ID[$name]} ./${name}.psk
EOF
      chmod 755 "$d/install-$name.sh"
    fi
  done
  if (( has_win )); then
    cp "${ROOT_DIR}/windows/install-agent.ps1" "$d/"
    if [[ -n $MSI ]]; then cp "$MSI" "$d/zabbix_agent2.msi"
    else warn "Нет MSI агента в windows/ — положите zabbix_agent2.msi в $d вручную"; fi
  fi
  if (( has_lin )); then
    cp "${ROOT_DIR}/lib/install-linux-agent.sh" "$d/"
    mkdir -p "$d/repo"; cp -a /opt/silent-monitor/repo/. "$d/repo/"
    cp /etc/apt/keyrings/silent-monitor-offline.gpg "$d/repo/offline-repo.gpg"
  fi
  [[ -d $d ]] && log "Комплект сети $net: $d"
done
chmod -R go-rwx "$OUT"

echo
warn "В psk-export лежат СЕКРЕТНЫЕ ключи. После установки агентов:"
warn "  - удалите папку сети с флешки (скрипт на ПК сам удаляет свой .psk);"
warn "  - на сервере: rm -rf ${OUT}"
