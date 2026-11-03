#!/usr/bin/env bash
# =====================================================================
#  ШАГ 2. Запускать на сервере (ВМ Astra Linux SE) БЕЗ интернета,
#  из консоли ESXi (не по SSH — сеть будет перенастраиваться).
#
#  Использование:
#     sudo ./2-install-offline.sh            # всё по порядку
#     sudo ./2-install-offline.sh firewall   # только один шаг
#  Шаги: checks repo packages firewall sysctl network services
#        postgres zabbix web ssh time audit start astra summary
#
#  Повторный запуск безопасен: пароли и база не пересоздаются.
# =====================================================================
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
need_root
load_config
load_hosts

ETC=/etc/silent-monitor
SECRETS=${ETC}/secrets.env
REPO_DST=/opt/silent-monitor/repo
APT_LIST=/etc/apt/sources.list.d/silent-monitor-offline.list
APT_KEY=/etc/apt/keyrings/silent-monitor-offline.gpg
APT_OPTS=(-o "Dir::Etc::sourcelist=${APT_LIST}" -o "Dir::Etc::sourceparts=-" -o "APT::Get::List-Cleanup=0")

mkdir -p "$ETC"; chmod 700 "$ETC"

# ---------------------------------------------------------------------
step_checks() {
  log "Проверки"
  [[ -f /etc/astra_version ]] && log "Astra: $(cat /etc/astra_version)" || warn "Похоже, это не Astra Linux"
  local n missing=0
  for i in "$ADMIN_IF" $(for n in "${NET_NAMES[@]}"; do echo "${NET_IF[$n]}"; done); do
    if ! ip link show "$i" >/dev/null 2>&1; then warn "Интерфейса $i нет"; missing=1; fi
  done
  if (( missing )); then
    echo; ip -br link; echo
    die "Исправьте имена интерфейсов в config.env (по MAC сверьте с ESXi)."
  fi
  log "Интерфейсы на месте:"
  printf '   %-10s %-8s %s\n' admin "$ADMIN_IF" "$ADMIN_ADDR"
  for n in "${NET_NAMES[@]}"; do printf '   %-10s %-8s %s\n' "$n" "${NET_IF[$n]}" "${NET_ADDR[$n]}"; done
  log "Узлов в hosts.txt: ${#H_IP[@]}"
  if [[ -f ${ROOT_DIR}/SHA256SUMS ]]; then
    log "Проверяю целостность комплекта"
    ( cd "$ROOT_DIR" && sha256sum --quiet -c SHA256SUMS ) || die "Контрольные суммы не сошлись! Комплект повреждён или подменён."
  fi
}

# ---------------------------------------------------------------------
step_repo() {
  log "Подключаю локальный репозиторий"
  [[ -f ${ROOT_DIR}/repo/InRelease ]] || die "Нет ${ROOT_DIR}/repo — запускайте из распакованного комплекта."
  mkdir -p "$REPO_DST" /etc/apt/keyrings
  cp -a "${ROOT_DIR}/repo/." "$REPO_DST/"
  chmod -R a+rX /opt/silent-monitor
  install -m 644 "${ROOT_DIR}/offline-repo.gpg" "$APT_KEY"
  echo "deb [signed-by=${APT_KEY}] file:${REPO_DST} ./" > "$APT_LIST"
  apt-get "${APT_OPTS[@]}" update
}

# ---------------------------------------------------------------------
step_packages() {
  log "Устанавливаю пакеты (службы при установке НЕ запускаются)"
  # Запрещаем автозапуск служб, пока не настроен firewall
  printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 755 /usr/sbin/policy-rc.d
  trap 'rm -f /usr/sbin/policy-rc.d' EXIT
  DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install -y --no-install-recommends \
    "${SERVER_PKGS[@]}" ifupdown apache2-utils
  rm -f /usr/sbin/policy-rc.d
}

# ---------------------------------------------------------------------
step_firewall() {
  log "Генерирую и применяю nftables"
  local tmp; tmp=$(mktemp)
  gen_nftables > "$tmp"
  nft -c -f "$tmp" || die "Ошибка в сгенерированных правилах ($tmp)"
  install -m 600 "$tmp" /etc/nftables.conf; rm -f "$tmp"
  systemctl enable nftables >/dev/null 2>&1 || true
  nft -f /etc/nftables.conf
  log "Firewall активен: вход только из ${ADMIN_ALLOWED} на ${ADMIN_IF}, пересылка запрещена"
}

# ---------------------------------------------------------------------
step_sysctl() {
  log "Параметры ядра: без маршрутизации, без IPv6, тихий ARP"
  cat > /etc/sysctl.d/90-silent-monitor.conf <<'EOF'
# --- маршрутизации между сетями нет ---
net.ipv4.ip_forward = 0
net.ipv4.conf.all.forwarding = 0
net.ipv4.conf.default.forwarding = 0
# --- IPv6 выключен полностью (никаких объявлений и link-local) ---
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
# --- ARP: отвечать только на своём интерфейсе и только своей подсети ---
net.ipv4.conf.all.arp_ignore = 2
net.ipv4.conf.default.arp_ignore = 2
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.arp_accept = 0
net.ipv4.conf.all.proxy_arp = 0
net.ipv4.conf.default.proxy_arp = 0
# --- строгая проверка источника, без редиректов и source route ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 0
# --- ядро ---
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.sysrq = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
EOF
  sysctl --system >/dev/null
}

# ---------------------------------------------------------------------
step_network() {
  log "Сеть: статические адреса через ifupdown, NetworkManager выключается"
  local f=/etc/network/interfaces.d/silent-monitor n i
  {
    echo "# Сгенерировано astra-silent-monitor. Шлюз только в админской сети (если задан)."
    echo; echo "auto ${ADMIN_IF}"; echo "iface ${ADMIN_IF} inet static"
    echo "    address ${ADMIN_ADDR}"
    [[ -n ${ADMIN_GW:-} ]] && echo "    gateway ${ADMIN_GW}"
    for n in "${NET_NAMES[@]}"; do
      echo; echo "# сеть ${n}"; echo "auto ${NET_IF[$n]}"; echo "iface ${NET_IF[$n]} inet static"
      echo "    address ${NET_ADDR[$n]}"
      for i in "${!H_NET[@]}"; do
        if [[ ${H_NET[$i]} == "$n" && -n ${H_MAC[$i]} ]]; then
          echo "    post-up ip neigh replace ${H_IP[$i]} lladdr ${H_MAC[$i]} dev ${NET_IF[$n]} nud permanent"
        fi
      done
    done
  } > "$f"
  # Убираем любые старые настройки этих интерфейсов из основного файла
  cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

source /etc/network/interfaces.d/*
EOF
  : > /etc/resolv.conf   # DNS не нужен: всё по IP
  if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
    systemctl disable --now NetworkManager.service NetworkManager-wait-online.service 2>/dev/null || true
    systemctl mask NetworkManager.service 2>/dev/null || true
  fi
  systemctl enable networking.service >/dev/null 2>&1 || true
  for i in "$ADMIN_IF" $(for n in "${NET_NAMES[@]}"; do echo "${NET_IF[$n]}"; done); do
    ip addr flush dev "$i" 2>/dev/null || true
    ifdown "$i" 2>/dev/null || true
    ifup "$i"
  done
  ip -br addr
}

# ---------------------------------------------------------------------
step_services() {
  log "Отключаю всё, что «говорит» в сеть"
  local u
  for u in avahi-daemon.service avahi-daemon.socket cups.service cups.socket cups-browsed.service \
           bluetooth.service ModemManager.service rpcbind.service rpcbind.socket \
           smbd.service nmbd.service samba.service winbind.service wsdd.service \
           exim4.service postfix.service snmpd.service systemd-timesyncd.service \
           NetworkManager.service ssh.socket; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1 && systemctl cat "$u" >/dev/null 2>&1; then
      systemctl disable --now "$u" >/dev/null 2>&1 || true
      systemctl mask "$u" >/dev/null 2>&1 || true
      echo "   отключено: $u"
    fi
  done
  if [[ -d /etc/systemd/resolved.conf.d || -f /etc/systemd/resolved.conf ]]; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nLLMNR=no\nMulticastDNS=no\n' > /etc/systemd/resolved.conf.d/silent.conf
  fi
}

# ---------------------------------------------------------------------
gen_secret() { openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 32; }

load_secrets() {
  if [[ ! -f $SECRETS ]]; then
    umask 077
    printf 'DB_PASS=%s\nZBX_ADMIN_PASS=%s\n' "$(gen_secret)" "$(gen_secret)" > "$SECRETS"
  fi
  # shellcheck disable=SC1090
  source "$SECRETS"
}

pg_conf_dir() { ls -d /etc/postgresql/*/main 2>/dev/null | sort -V | tail -1; }

step_postgres() {
  log "PostgreSQL: только 127.0.0.1, база zabbix"
  load_secrets
  local d; d=$(pg_conf_dir); [[ -n $d ]] || die "Кластер PostgreSQL не найден"
  mkdir -p "$d/conf.d"
  cat > "$d/conf.d/silent-monitor.conf" <<'EOF'
listen_addresses = '127.0.0.1'
password_encryption = 'scram-sha-256'
ssl = off
log_connections = on
log_disconnections = on
EOF
  grep -q '^include_dir' "$d/postgresql.conf" || echo "include_dir = 'conf.d'" >> "$d/postgresql.conf"
  # pg_hba: только локальные подключения
  cat > "$d/pg_hba.conf" <<'EOF'
local   all       postgres                 peer
local   zabbix    zabbix                   scram-sha-256
host    zabbix    zabbix    127.0.0.1/32   scram-sha-256
EOF
  systemctl enable postgresql >/dev/null 2>&1 || true
  systemctl restart postgresql
  local psql=(runuser -u postgres -- psql -qtAX)
  if [[ -z $("${psql[@]}" -c "select 1 from pg_roles where rolname='zabbix'") ]]; then
    "${psql[@]}" -c "create role zabbix login password '${DB_PASS}'"
  else
    "${psql[@]}" -c "alter role zabbix password '${DB_PASS}'"
  fi
  if [[ -z $("${psql[@]}" -c "select 1 from pg_database where datname='zabbix'") ]]; then
    "${psql[@]}" -c "create database zabbix owner zabbix encoding 'UTF8' template template0"
  fi

  export PGPASSWORD=$DB_PASS
  local zpsql=(psql -qX -v ON_ERROR_STOP=1 -h 127.0.0.1 -U zabbix -d zabbix)
  if [[ -n $("${zpsql[@]}" -tA -c "select to_regclass('public.users')") ]]; then
    log "Схема Zabbix уже загружена — пропускаю"
  else
    local files=()
    if [[ -f /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz ]]; then
      files=(/usr/share/zabbix-sql-scripts/postgresql/server.sql.gz)
    else
      local base=/usr/share/zabbix-server-pgsql f
      for f in schema images data; do
        [[ -f $base/$f.sql.gz ]] && files+=("$base/$f.sql.gz")
        [[ -f $base/$f.sql ]] && files+=("$base/$f.sql")
      done
    fi
    (( ${#files[@]} )) || die "Не найдены SQL-файлы схемы Zabbix (dpkg -L zabbix-server-pgsql)"
    for f in "${files[@]}"; do
      log "Загружаю $(basename "$f")"
      if [[ $f == *.gz ]]; then zcat "$f" | "${zpsql[@]}"; else "${zpsql[@]}" -f "$f"; fi
    done
  fi
  # Пароль Admin в веб-интерфейсе — случайный вместо стандартного «zabbix»
  local hash; hash=$(htpasswd -nbBC 12 x "$ZBX_ADMIN_PASS" | cut -d: -f2)
  "${zpsql[@]}" -c "update users set passwd='${hash}' where username='Admin'"
  # Гостевой доступ выключен
  "${zpsql[@]}" -c "update usrgrp set users_status=1 where name='Guests'" 2>/dev/null || true
  unset PGPASSWORD
}

# ---------------------------------------------------------------------
set_conf() { # файл ключ значение
  local f=$1 k=$2 v=$3
  if grep -qE "^${k}=" "$f"; then sed -i -E "s|^${k}=.*|${k}=${v}|" "$f"
  else echo "${k}=${v}" >> "$f"; fi
}

step_zabbix() {
  log "Zabbix server: слушает только localhost"
  load_secrets
  local c=/etc/zabbix/zabbix_server.conf
  [[ -f $c ]] || die "Нет $c"
  chown root:zabbix "$c"; chmod 640 "$c"
  set_conf "$c" DBHost 127.0.0.1
  set_conf "$c" DBName zabbix
  set_conf "$c" DBUser zabbix
  set_conf "$c" DBPassword "$DB_PASS"
  set_conf "$c" ListenIP 127.0.0.1
  set_conf "$c" FpingLocation /usr/bin/fping
  set_conf "$c" Timeout 5
  set_conf "$c" StartPingers 5
  set_conf "$c" AllowRoot 0
  set_conf "$c" EnableGlobalScripts 0
  set_conf "$c" UnreachablePeriod 120

  log "Веб-интерфейс Zabbix: конфиг подключения"
  local ui
  for ui in /usr/share/zabbix/ui /usr/share/zabbix; do [[ -f $ui/index.php ]] && break; done
  [[ -f $ui/index.php ]] || die "Не найден веб-интерфейс Zabbix (dpkg -L zabbix-frontend-php)"
  echo "$ui" > "${ETC}/ui-dir"
  mkdir -p /etc/zabbix/web
  cat > /etc/zabbix/web/zabbix.conf.php <<EOF
<?php
\$DB['TYPE']     = 'POSTGRESQL';
\$DB['SERVER']   = '127.0.0.1';
\$DB['PORT']     = '5432';
\$DB['DATABASE'] = 'zabbix';
\$DB['USER']     = 'zabbix';
\$DB['PASSWORD'] = '${DB_PASS}';
\$DB['SCHEMA']   = '';
\$DB['ENCRYPTION'] = false;
\$DB['KEY_FILE'] = ''; \$DB['CERT_FILE'] = ''; \$DB['CA_FILE'] = '';
\$DB['VERIFY_HOST'] = false; \$DB['CIPHER_LIST'] = '';
\$DB['VAULT'] = ''; \$DB['VAULT_URL'] = ''; \$DB['VAULT_PREFIX'] = '';
\$DB['VAULT_DB_PATH'] = ''; \$DB['VAULT_TOKEN'] = '';
\$DB['VAULT_CERT_FILE'] = ''; \$DB['VAULT_KEY_FILE'] = '';
\$DB['DOUBLE_IEEE754'] = true;
\$ZBX_SERVER      = '127.0.0.1';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = 'silent-monitor';
\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
EOF
  chown root:www-data /etc/zabbix/web/zabbix.conf.php; chmod 640 /etc/zabbix/web/zabbix.conf.php
  if [[ -d $ui/conf ]] && [[ ! -L $ui/conf/zabbix.conf.php ]] && \
     [[ "$(readlink -f "$ui/conf/zabbix.conf.php" 2>/dev/null)" != /etc/zabbix/web/zabbix.conf.php ]]; then
    ln -sfn /etc/zabbix/web/zabbix.conf.php "$ui/conf/zabbix.conf.php"
  fi
}

# ---------------------------------------------------------------------
step_web() {
  log "Apache: только ${ADMIN_IP}:443, TLS, доступ только с ${ADMIN_ALLOWED}"
  local ui; ui=$(cat "${ETC}/ui-dir" 2>/dev/null || echo /usr/share/zabbix)
  local tls=${ETC}/tls
  mkdir -p "$tls"
  if [[ ! -f $tls/cert.pem ]]; then
    openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
      -keyout "$tls/key.pem" -out "$tls/cert.pem" \
      -subj "/CN=${ADMIN_IP}" -addext "subjectAltName=IP:${ADMIN_IP}" 2>/dev/null
    chmod 600 "$tls/key.pem"
  fi
  log "Отпечаток сертификата (сверьте в браузере при первом входе):"
  openssl x509 -in "$tls/cert.pem" -noout -fingerprint -sha256

  # В Astra SE Apache по умолчанию требует мандатной аутентификации
  if grep -qE '^\s*AstraMode' /etc/apache2/apache2.conf; then
    sed -i -E 's/^\s*AstraMode\s+.*/AstraMode off/' /etc/apache2/apache2.conf
  fi
  echo "Listen ${ADMIN_IP}:443" > /etc/apache2/ports.conf

  cat > /etc/apache2/conf-available/silent-hardening.conf <<'EOF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
FileETag None
Header always unset X-Powered-By
EOF
  local req=""; for a in $ADMIN_ALLOWED; do req+=" ${a}"; done
  cat > /etc/apache2/sites-available/silent-monitor.conf <<EOF
<VirtualHost ${ADMIN_IP}:443>
    ServerName ${ADMIN_IP}
    DocumentRoot ${ui}

    SSLEngine on
    SSLCertificateFile    ${tls}/cert.pem
    SSLCertificateKeyFile ${tls}/key.pem
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    SSLHonorCipherOrder on

    Header always set Strict-Transport-Security "max-age=31536000"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "no-referrer"

    <Directory ${ui}>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require ip${req}
        <IfModule mod_php.c>
            php_admin_flag  expose_php Off
            php_value max_execution_time 300
            php_value memory_limit 256M
            php_value post_max_size 16M
            php_value upload_max_filesize 2M
            php_value max_input_time 300
            php_value max_input_vars 10000
            php_value date.timezone ${TZ_NAME}
        </IfModule>
    </Directory>
    <DirectoryMatch "^${ui}/(conf|app|include|local)/">
        Require all denied
    </DirectoryMatch>
</VirtualHost>
EOF
  a2dissite -q 000-default default-ssl >/dev/null 2>&1 || true
  a2disconf -q zabbix-frontend-php zabbix >/dev/null 2>&1 || true
  a2disconf -q serve-cgi-bin >/dev/null 2>&1 || true
  a2enmod -q ssl headers >/dev/null
  local m; for m in /etc/apache2/mods-available/php*.load; do a2enmod -q "$(basename "$m" .load)" >/dev/null; done
  a2dismod -q -f status autoindex >/dev/null 2>&1 || true
  a2enconf -q silent-hardening >/dev/null
  a2ensite -q silent-monitor >/dev/null
  apache2ctl configtest
}

# ---------------------------------------------------------------------
step_ssh() {
  log "SSH: только ${ADMIN_IP}, без туннелей и пересылок"
  local f=/etc/ssh/sshd_config.d/10-silent-monitor.conf keys_ok=no home
  mkdir -p /etc/ssh/sshd_config.d
  grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config || \
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  home=$(getent passwd "${SSH_ADMIN_USER:-admin}" | cut -d: -f6 || true)
  [[ -n $home && -s $home/.ssh/authorized_keys ]] && keys_ok=yes
  {
    echo "ListenAddress ${ADMIN_IP}"
    echo "AddressFamily inet"
    echo "PermitRootLogin no"
    echo "AllowUsers ${SSH_ADMIN_USER:-admin}"
    echo "PubkeyAuthentication yes"
    if [[ ${SSH_KEYS_ONLY:-yes} == yes && $keys_ok == yes ]]; then
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
    fi
    echo "# Сервер не должен стать мостом между сетями:"
    echo "AllowTcpForwarding no"
    echo "AllowStreamLocalForwarding no"
    echo "GatewayPorts no"
    echo "PermitTunnel no"
    echo "AllowAgentForwarding no"
    echo "X11Forwarding no"
    echo "MaxAuthTries 3"
    echo "LoginGraceTime 30"
    echo "ClientAliveInterval 300"
    echo "ClientAliveCountMax 2"
  } > "$f"
  if [[ ${SSH_KEYS_ONLY:-yes} == yes && $keys_ok != yes ]]; then
    warn "У ${SSH_ADMIN_USER:-admin} нет ~/.ssh/authorized_keys — вход по паролю оставлен."
    warn "Положите ключ и перезапустите шаг: ./2-install-offline.sh ssh"
  fi
  sshd -t
  # ssh.socket замаскирован: используем обычную службу, чтобы работал ListenAddress
  systemctl enable ssh.service >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------
step_time() {
  if [[ -n ${ADMIN_NTP:-} ]]; then
    log "Время: chrony только к ${ADMIN_NTP}, сам не раздаёт"
    cat > /etc/chrony/chrony.conf <<EOF
server ${ADMIN_NTP} iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1 3
rtcsync
port 0
cmdport 0
EOF
    systemctl enable chrony >/dev/null 2>&1 || true
  else
    log "NTP не задан: chrony выключен. Включите в ВМ «Synchronize guest time with host» (VMware Tools)."
    systemctl disable --now chrony >/dev/null 2>&1 || true
  fi
  timedatectl set-timezone "$TZ_NAME" 2>/dev/null || true
}

# ---------------------------------------------------------------------
step_audit() {
  log "Аудит изменений настроек (auditd)"
  cat > /etc/audit/rules.d/silent-monitor.rules <<'EOF'
-w /etc/nftables.conf -p wa -k sm_firewall
-w /etc/sysctl.d/ -p wa -k sm_sysctl
-w /etc/sysctl.conf -p wa -k sm_sysctl
-w /etc/network/ -p wa -k sm_network
-w /etc/ssh/sshd_config -p wa -k sm_ssh
-w /etc/ssh/sshd_config.d/ -p wa -k sm_ssh
-w /etc/zabbix/ -p wa -k sm_zabbix
-w /etc/silent-monitor/ -p rwa -k sm_secrets
-w /etc/apache2/ -p wa -k sm_web
-w /etc/apt/ -p wa -k sm_apt
-a always,exit -F arch=b64 -S sethostname,setdomainname -k sm_hostname
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k sm_modules
EOF
  systemctl enable auditd >/dev/null 2>&1 || true
  augenrules --load >/dev/null 2>&1 || systemctl restart auditd || true
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nStorage=persistent\n' > /etc/systemd/journald.conf.d/silent.conf
}

# ---------------------------------------------------------------------
step_start() {
  log "Запускаю службы"
  rm -f /usr/sbin/policy-rc.d
  systemctl enable --now postgresql zabbix-server apache2 ssh.service
  [[ -n ${ADMIN_NTP:-} ]] && systemctl restart chrony
  systemctl restart postgresql zabbix-server apache2 ssh.service
  sleep 3
  systemctl --no-pager --lines=0 status zabbix-server apache2 postgresql ssh.service | grep -E '●|Active:'
}

# ---------------------------------------------------------------------
step_astra() {
  log "Механизмы защиты Astra SE"
  local changed=0
  if [[ ${ASTRA_ZPS:-yes} == yes ]] && command -v astra-digsig-control >/dev/null; then
    astra-digsig-control enable && changed=1 && echo "   ЗПС: включена"
  fi
  if [[ ${ASTRA_MIC:-yes} == yes ]] && command -v astra-mic-control >/dev/null; then
    astra-mic-control enable && changed=1 && echo "   МКЦ: включён"
  fi
  if [[ ${ASTRA_PTRACE:-yes} == yes ]] && command -v astra-ptrace-lock >/dev/null; then
    astra-ptrace-lock enable && echo "   ptrace: заблокирован"
  fi
  (( changed )) && warn "Для применения ЗПС/МКЦ нужна перезагрузка: reboot"
  return 0
}

# ---------------------------------------------------------------------
step_summary() {
  load_secrets
  echo
  log "===================== ГОТОВО ====================="
  echo "  Веб-интерфейс:  https://${ADMIN_IP}/   (только с ${ADMIN_ALLOWED})"
  echo "  Логин:          Admin"
  echo "  Пароль:         ${ZBX_ADMIN_PASS}"
  echo "  Пароли хранятся в ${SECRETS} (только root)."
  echo
  echo "  Дальше:"
  echo "   1) ./3-gen-psk.sh      — ключи для агентов и пакеты установки на ПК"
  echo "   2) ./4-add-hosts.sh    — добавить узлы из hosts.txt в Zabbix"
  echo "   3) ./5-verify.sh       — проверить, что сервер «невидим»"
  echo "   4) reboot              — если включали ЗПС/МКЦ"
  echo
  warn "Смените пароль Admin в веб-интерфейсе и запишите его в надёжное место."
}

# ---------------------------------------------------------------------
ALL=(checks repo packages firewall sysctl network services postgres zabbix web ssh time audit start astra summary)
if (( $# )); then
  for s in "$@"; do
    declare -F "step_$s" >/dev/null || die "Нет шага '$s'. Доступны: ${ALL[*]}"
    "step_$s"
  done
else
  for s in "${ALL[@]}"; do "step_$s"; done
fi
