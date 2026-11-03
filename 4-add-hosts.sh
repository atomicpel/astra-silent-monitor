#!/usr/bin/env bash
# =====================================================================
#  ШАГ 4. Добавить/обновить узлы из hosts.txt в Zabbix через API.
#  Запускать на сервере после 3-gen-psk.sh. Можно повторять после
#  изменения hosts.txt или перевыпуска ключей.
#
#  Для каждой сети создаётся группа узлов «Сеть <имя>».
#  Шаблоны: win → Windows by Zabbix agent, linux → Linux by Zabbix agent,
#  всем → ICMP Ping. Связь с агентами только по PSK.
# =====================================================================
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
need_root
load_config
load_hosts
source /etc/silent-monitor/secrets.env

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
for i in "${!H_IP[@]}"; do
  printf '%s\t%s\t%s\t%s\n' "${H_NET[$i]}" "${H_IP[$i]}" "${H_NAME[$i]}" "${H_OS[$i]}"
done > "$TMP"

if [[ -z ${ZBX_API_PASS:-} ]]; then
  read -rsp "Пароль пользователя Admin в Zabbix (Enter — из secrets.env): " ZBX_API_PASS; echo
  ZBX_API_PASS=${ZBX_API_PASS:-$ZBX_ADMIN_PASS}
fi

URL="https://${ADMIN_IP}/api_jsonrpc.php" CA=/etc/silent-monitor/tls/cert.pem \
PSKDB=/etc/silent-monitor/psk.csv HOSTS="$TMP" ZPASS="$ZBX_API_PASS" \
python3 -I - <<'PY'
import csv, json, os, ssl, sys, urllib.request

url, hosts_f, pskdb = os.environ["URL"], os.environ["HOSTS"], os.environ["PSKDB"]
ctx = ssl.create_default_context(cafile=os.environ["CA"])
token = None

def call(method, params):
    body = {"jsonrpc": "2.0", "method": method, "params": params, "id": 1}
    req = urllib.request.Request(url, json.dumps(body).encode(),
                                 {"Content-Type": "application/json-rpc"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
        resp = json.load(r)
    if "error" in resp:
        sys.exit(f"[x] {method}: {resp['error'].get('data') or resp['error']}")
    return resp["result"]

token = call("user.login", {"username": "Admin", "password": os.environ["ZPASS"]})

psk = {}
if os.path.exists(pskdb):
    with open(pskdb) as f:
        for row in csv.DictReader(f):
            psk[row["name"]] = (row["identity"], row["psk"])

def template(name):
    r = call("template.get", {"output": ["templateid"], "filter": {"host": [name]}})
    if not r:
        sys.exit(f"[x] Нет шаблона '{name}' в Zabbix")
    return r[0]["templateid"]

TPL = {"win": "Windows by Zabbix agent", "linux": "Linux by Zabbix agent"}
tpl_ping = template("ICMP Ping")
groups = {}

def group(net):
    if net not in groups:
        name = f"Сеть {net}"
        r = call("hostgroup.get", {"output": ["groupid"], "filter": {"name": [name]}})
        groups[net] = r[0]["groupid"] if r else call("hostgroup.create", {"name": name})["groupids"][0]
    return groups[net]

created = updated = 0
for line in open(hosts_f):
    net, ip, name, os_ = line.rstrip("\n").split("\t")
    tpls = [{"templateid": tpl_ping}]
    data = {"host": name, "groups": [{"groupid": group(net)}]}
    if os_ in TPL:
        if name not in psk:
            sys.exit(f"[x] Нет ключа для {name}: запустите 3-gen-psk.sh")
        tpls.append({"templateid": template(TPL[os_])})
        ident, key = psk[name]
        data.update(tls_connect=2, tls_accept=2, tls_psk_identity=ident, tls_psk=key)
    else:
        data.update(tls_connect=1, tls_accept=1)
    data["templates"] = tpls
    iface = {"type": 1, "main": 1, "useip": 1, "ip": ip, "dns": "", "port": "10050"}

    ex = call("host.get", {"output": ["hostid"], "filter": {"host": [name]},
                           "selectInterfaces": ["interfaceid"]})
    if ex:
        hid = ex[0]["hostid"]
        data["hostid"] = hid
        if ex[0]["interfaces"]:
            iface["interfaceid"] = ex[0]["interfaces"][0]["interfaceid"]
        data["interfaces"] = [iface]
        call("host.update", data); updated += 1
        print(f"[~] обновлён  {name:20} {ip:15} {net}")
    else:
        data["interfaces"] = [iface]
        call("host.create", data); created += 1
        print(f"[+] добавлен  {name:20} {ip:15} {net}")

call("user.logout", [])
print(f"[+] Готово: добавлено {created}, обновлено {updated}")
PY
