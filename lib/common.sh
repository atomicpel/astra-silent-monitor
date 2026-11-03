# shellcheck shell=bash
# Общие функции для скриптов astra-silent-monitor

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\e[1;32m[+]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Запустите от root (sudo)."; }

# Пакеты сервера (ставятся на ВМ)
SERVER_PKGS=(
  postgresql
  zabbix-server-pgsql
  zabbix-frontend-php
  php-pgsql php-gd php-bcmath php-mbstring php-xml php-ldap
  apache2 libapache2-mod-php
  fping nftables auditd chrony openssl ca-certificates
  python3 curl
)
# Пакеты, которые только кладутся в репозиторий (для Linux-ПК на Astra 1.8)
EXTRA_PKGS=( zabbix-agent )

load_config() {
  local cfg="${ROOT_DIR}/config.env"
  [[ -f $cfg ]] || die "Нет ${cfg}. Скопируйте config.env.example в config.env и заполните."
  # shellcheck disable=SC1090
  source "$cfg"
  : "${ADMIN_IF:?ADMIN_IF не задан}" "${ADMIN_ADDR:?ADMIN_ADDR не задан}" "${ADMIN_ALLOWED:?ADMIN_ALLOWED не задан}"
  ADMIN_IP="${ADMIN_ADDR%/*}"
  ARP_STEALTH="${ARP_STEALTH:-yes}"
  STRICT_TARGETS="${STRICT_TARGETS:-yes}"
  TZ_NAME="${TZ_NAME:-Europe/Moscow}"

  NET_NAMES=(); declare -gA NET_IF NET_ADDR NET_CIDR
  local line n i a
  for line in "${NETS[@]}"; do
    read -r n i a <<<"$line"
    [[ -n $n && -n $i && -n $a ]] || die "Ошибка в NETS: '$line'"
    [[ $i == "$ADMIN_IF" ]] && die "Сеть $n использует админский интерфейс $i"
    [[ -n ${NET_IF[$n]:-} ]] && die "Имя сети $n повторяется"
    NET_NAMES+=("$n"); NET_IF[$n]=$i; NET_ADDR[$n]=$a
    NET_CIDR[$n]=$(python3 -c 'import ipaddress,sys;print(ipaddress.ip_interface(sys.argv[1]).network)' "$a")
  done
  (( ${#NET_NAMES[@]} > 0 )) || die "NETS пуст"
  (( ${#NET_NAMES[@]} <= 9 )) || die "Больше 9 наблюдаемых сетей: у ВМ ESXi максимум 10 vNIC"
  check_overlap
}

check_overlap() {
  local list=("${ADMIN_ADDR}") n
  for n in "${NET_NAMES[@]}"; do list+=("${NET_ADDR[$n]}"); done
  python3 - "${list[@]}" <<'PY' || die "Подсети пересекаются — так изолировать нельзя."
import ipaddress, sys
nets = [ipaddress.ip_interface(a).network for a in sys.argv[1:]]
for i, a in enumerate(nets):
    for b in nets[i+1:]:
        if a.overlaps(b):
            print(f"  пересекаются: {a} и {b}", file=sys.stderr); sys.exit(1)
PY
}

# Читает hosts.txt в массивы H_NET H_IP H_NAME H_OS H_MAC
load_hosts() {
  H_NET=(); H_IP=(); H_NAME=(); H_OS=(); H_MAC=()
  local f="${ROOT_DIR}/hosts.txt" net ip name os mac
  [[ -f $f ]] || { warn "hosts.txt нет — правила будут по целым подсетям."; return 0; }
  while read -r net ip name os mac _; do
    [[ -z $net || $net == \#* ]] && continue
    [[ -n ${NET_IF[$net]:-} ]] || die "hosts.txt: неизвестная сеть '$net' (узел $ip)"
    [[ $os =~ ^(win|linux|ping)$ ]] || die "hosts.txt: ОС должна быть win|linux|ping (узел $ip)"
    python3 -c 'import ipaddress,sys
ip=ipaddress.ip_address(sys.argv[1]); net=ipaddress.ip_network(sys.argv[2])
sys.exit(0 if ip in net else 1)' "$ip" "${NET_CIDR[$net]}" \
      || die "hosts.txt: $ip не входит в подсеть ${NET_CIDR[$net]} сети $net"
    if [[ -n ${mac:-} && ! $mac =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
      die "hosts.txt: неверный MAC '$mac' у $ip"
    fi
    H_NET+=("$net"); H_IP+=("$ip"); H_NAME+=("$name"); H_OS+=("$os"); H_MAC+=("${mac:-}")
  done < "$f"
}

# Генерирует nftables.conf в stdout
gen_nftables() {
  local n i ip
  local -A net_has_hosts=()
  for i in "${!H_NET[@]}"; do net_has_hosts[${H_NET[$i]}]=1; done

  # элементы набора «куда можно ходить»: интерфейс . адрес
  local targets=() arpok=()
  for n in "${NET_NAMES[@]}"; do
    if [[ $STRICT_TARGETS == yes && -n ${net_has_hosts[$n]:-} ]]; then
      for i in "${!H_NET[@]}"; do
        [[ ${H_NET[$i]} == "$n" ]] && targets+=("\"${NET_IF[$n]}\" . ${H_IP[$i]}")
      done
    else
      targets+=("\"${NET_IF[$n]}\" . ${NET_CIDR[$n]}")
    fi
    if [[ -n ${net_has_hosts[$n]:-} ]]; then
      for i in "${!H_NET[@]}"; do
        [[ ${H_NET[$i]} == "$n" ]] && arpok+=("\"${NET_IF[$n]}\" . ${H_IP[$i]}")
      done
    else
      arpok+=("\"${NET_IF[$n]}\" . ${NET_CIDR[$n]}")
    fi
  done

  local admin_out=""
  if [[ -n ${ADMIN_NTP:-} ]]; then
    admin_out+=$'\n'"    oifname \"${ADMIN_IF}\" ip daddr ${ADMIN_NTP} udp dport 123 accept"
  fi
  if [[ -n ${ADMIN_SMTP:-} ]]; then
    admin_out+=$'\n'"    oifname \"${ADMIN_IF}\" ip daddr ${ADMIN_SMTP%:*} tcp dport ${ADMIN_SMTP##*:} accept"
  fi
  local admin_allowed; admin_allowed=$(echo "$ADMIN_ALLOWED" | tr -s ' ' ',' | sed 's/,$//')
  local mon_ifs=""; for n in "${NET_NAMES[@]}"; do mon_ifs+="\"${NET_IF[$n]}\", "; done
  mon_ifs="${mon_ifs%, }"

  cat <<EOF
#!/usr/sbin/nft -f
# Сгенерировано astra-silent-monitor $(date '+%F %T'). Не править вручную —
# меняйте config.env / hosts.txt и запускайте: install-offline.sh firewall
flush ruleset

table inet silent {
  # Куда серверу разрешено обращаться (интерфейс . адрес/подсеть)
  set targets {
    type ifname . ipv4_addr; flags interval
    elements = { $(IFS=,; echo "${targets[*]}" | sed 's/,/, /g') }
  }
  set admins {
    type ipv4_addr; flags interval
    elements = { ${admin_allowed} }
  }

  chain input {
    type filter hook input priority filter; policy drop;
    iif "lo" accept
    ct state invalid drop
    ct state established,related accept
    # Вход только из админской сети и только с разрешённых адресов
    iifname "${ADMIN_IF}" ip saddr @admins tcp dport { 22, 443 } ct state new accept
    # Всё остальное — молча в никуда (без RST и ICMP unreachable)
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
    # Пересылка между сетями запрещена полностью
  }

  chain output {
    type filter hook output priority filter; policy drop;
    oif "lo" accept
    ct state invalid drop
    ct state established,related accept
    # Опрос: агент Zabbix и ping — только к разрешённым узлам
    meta l4proto tcp oifname . ip daddr @targets tcp dport 10050 ct state new accept
    meta l4proto icmp oifname . ip daddr @targets icmp type echo-request accept${admin_out}
    # Счётчик заблокированных попыток выхода — смотреть: nft list chain inet silent output
    oifname { ${mon_ifs} } counter drop
  }
}
EOF

  if [[ $ARP_STEALTH == yes ]]; then
    cat <<EOF

# ARP: сервер не отвечает «кто это?» никому, кроме узлов мониторинга
table arp silent_arp {
  set arp_ok {
    type ifname . ipv4_addr; flags interval
    elements = { $(IFS=,; echo "${arpok[*]}" | sed 's/,/, /g') }
  }
  chain input {
    type filter hook input priority filter; policy accept;
    iifname "${ADMIN_IF}" accept
    arp operation reply accept
    arp operation request iifname . arp saddr ip @arp_ok accept
    arp operation request counter drop
  }
}
EOF
  fi
}
