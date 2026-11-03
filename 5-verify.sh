#!/usr/bin/env bash
# =====================================================================
#  ШАГ 5. Проверка: сервер изолирован и «невидим».
#  Запускать на сервере. Ничего не меняет.
# =====================================================================
set -Euo pipefail
source "$(dirname "$0")/lib/common.sh"
need_root
load_config
load_hosts

ok=0; bad=0
pass() { printf '  \e[32mOK\e[0m   %s\n' "$*"; ok=$((ok+1)); }
fail() { printf '  \e[31mFAIL\e[0m %s\n' "$*"; bad=$((bad+1)); }

echo "== Маршрутизация и IPv6"
[[ $(sysctl -n net.ipv4.ip_forward) == 0 ]] && pass "ip_forward = 0" || fail "ip_forward включён!"
for f in /proc/sys/net/ipv4/conf/*/forwarding; do
  [[ $(cat "$f") == 0 ]] || fail "forwarding=1 в $f"
done
if ip -6 addr show 2>/dev/null | grep -q inet6; then fail "Есть IPv6-адреса"; else pass "IPv6 нет"; fi
[[ $(sysctl -n net.ipv4.conf.all.arp_ignore) -ge 1 ]] && pass "arp_ignore = $(sysctl -n net.ipv4.conf.all.arp_ignore)" || fail "arp_ignore = 0"

echo "== Маршруты"
dr=$(ip -4 route show default)
if [[ -z $dr ]]; then pass "Шлюза по умолчанию нет"
elif [[ $dr == *"dev ${ADMIN_IF}"* ]]; then pass "Шлюз только в админской сети: $dr"
else fail "Шлюз по умолчанию НЕ через админскую сеть: $dr"; fi

echo "== Адреса на интерфейсах"
for n in "${NET_NAMES[@]}"; do
  i=${NET_IF[$n]}
  got=$(ip -4 -o addr show dev "$i" | awk '{print $4}' | xargs)
  [[ $got == "${NET_ADDR[$n]}" ]] && pass "$n ($i): $got" || fail "$n ($i): ожидалось ${NET_ADDR[$n]}, есть '${got}'"
done

echo "== Firewall"
if nft list table inet silent >/dev/null 2>&1; then
  pass "Таблица inet silent загружена"
  for ch in input forward output; do
    nft list chain inet silent "$ch" | grep -q 'policy drop' && pass "$ch: policy drop" || fail "$ch: политика не drop"
  done
else
  fail "Таблица nftables не загружена"
fi
if [[ $ARP_STEALTH == yes ]]; then
  nft list table arp silent_arp >/dev/null 2>&1 && pass "ARP-фильтр активен" || fail "ARP-фильтр не загружен"
fi
systemctl is-enabled nftables >/dev/null 2>&1 && pass "nftables включён при загрузке" || fail "nftables не включён при загрузке"

echo "== Открытые порты (допустимы только 127.0.0.1 и ${ADMIN_IP})"
while read -r proto _ _ _ local _ proc; do
  addr=${local%:*}; addr=${addr#[}; addr=${addr%]}
  case $addr in
    127.0.0.1|127.0.0.53|::1|"${ADMIN_IP}") pass "$proto $local ${proc}" ;;
    *) fail "$proto $local слушает НЕ только локально/админ: ${proc}" ;;
  esac
done < <(ss -Hlntup 2>/dev/null)

echo "== Лишние службы"
for u in avahi-daemon cups cups-browsed rpcbind smbd nmbd NetworkManager systemd-timesyncd snmpd; do
  systemctl is-active --quiet "$u" 2>/dev/null && fail "$u запущен" || true
done
pass "проверено: avahi, cups, rpcbind, samba, NetworkManager, timesyncd, snmpd"

echo "== Службы мониторинга"
for u in postgresql zabbix-server apache2 ssh; do
  systemctl is-active --quiet "$u" && pass "$u работает" || fail "$u не работает"
done

echo "== Статические ARP-записи"
for i in "${!H_IP[@]}"; do
  [[ -z ${H_MAC[$i]} ]] && continue
  ip neigh show "${H_IP[$i]}" | grep -q PERMANENT && pass "${H_IP[$i]} PERMANENT" || fail "${H_IP[$i]}: нет постоянной записи"
done

echo "== Счётчики блокировок"
nft list chain inet silent output 2>/dev/null | grep -E 'counter' | sed 's/^/  исходящие: /' || true
nft list chain arp silent_arp input 2>/dev/null | grep -E 'counter' | sed 's/^/  ARP: /' || true

echo
printf 'Итог: \e[32m%d OK\e[0m, \e[31m%d FAIL\e[0m\n' "$ok" "$bad"
cat <<EOF

Проверка СНАРУЖИ (с ПК в каждой наблюдаемой сети, НЕ из списка hosts.txt):
  nmap -sn ${NET_ADDR[${NET_NAMES[0]}]%/*}            # не должен найти хост
  nmap -Pn -p- -T4 ${NET_ADDR[${NET_NAMES[0]}]%/*}    # все порты filtered
  arp-scan -l                                 # сервера в списке быть не должно
С ПК из hosts.txt сервер отвечает на ARP, но порты всё равно закрыты.
EOF
(( bad == 0 ))
