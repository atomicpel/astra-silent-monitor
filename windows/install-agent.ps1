<#
  Установка Zabbix Agent 2 на Windows-ПК в режиме «только опрос сервером».
  Обычно запускается через install-<имя>.cmd из комплекта psk-export\<сеть>\.

  Что делает:
   - ставит агент из MSI без интернета;
   - пассивный режим: агент сам никуда не подключается (ServerActive выключен);
   - шифрование PSK, удалённые команды запрещены;
   - брандмауэр: порт 10050 открыт ТОЛЬКО для IP сервера мониторинга;
   - ключ доступен только SYSTEM и администраторам;
   - удаляет файл ключа с флешки после копирования.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Msi,
  [Parameter(Mandatory)] [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')] [string] $Server,
  [Parameter(Mandatory)] [string] $HostName,
  [Parameter(Mandatory)] [string] $PskIdentity,
  [Parameter(Mandatory)] [string] $PskFile,
  [switch] $KeepPskSource
)
$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Запустите от имени администратора.'
}
foreach ($f in @($Msi, $PskFile)) { if (-not (Test-Path $f)) { throw "Нет файла: $f" } }

$psk = (Get-Content -Raw $PskFile).Trim()
if ($psk -notmatch '^[0-9a-fA-F]{64}$') { throw 'Неверный формат PSK (ожидается 64 hex-символа).' }

$dir     = Join-Path $env:ProgramFiles 'Zabbix Agent 2'
$conf    = Join-Path $dir 'zabbix_agent2.conf'
$pskDst  = Join-Path $dir 'psk.key'
$svcName = 'Zabbix Agent 2'

Write-Host '[+] Устанавливаю агент...'
$log = Join-Path $env:TEMP 'zabbix_agent2_install.log'
$msiArgs = @('/i', "`"$Msi`"", '/qn', '/norestart', '/l*v', "`"$log`"",
          "SERVER=$Server", "HOSTNAME=$HostName", 'LISTENPORT=10050')
$p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "msiexec завершился с кодом $($p.ExitCode), см. $log" }
if (-not (Test-Path $conf)) { throw "Не найден $conf" }

Stop-Service $svcName -ErrorAction SilentlyContinue

Write-Host '[+] Ключ PSK...'
Set-Content -Path $pskDst -Value $psk -NoNewline -Encoding ascii
icacls $pskDst /inheritance:r /grant:r 'SYSTEM:(R)' 'BUILTIN\Administrators:(F)' | Out-Null

Write-Host '[+] Настройка агента...'
# Убираем все активные строки с нашими параметрами и дописываем свой блок
$keys = 'Server','ServerActive','Hostname','HostnameItem','ListenPort','ListenIP',
        'TLSConnect','TLSAccept','TLSPSKIdentity','TLSPSKFile','DenyKey','AllowKey',
        'RefreshActiveChecks','Timeout'
$pattern = '^\s*(' + ($keys -join '|') + ')\s*='
$lines = Get-Content $conf | Where-Object { $_ -notmatch $pattern }
$lines += @(
  '',
  '### astra-silent-monitor ###',
  "Server=$Server",
  '# ServerActive не задан: агент сам никуда не подключается',
  "Hostname=$HostName",
  'ListenPort=10050',
  'Timeout=5',
  'TLSConnect=psk',
  'TLSAccept=psk',
  "TLSPSKIdentity=$PskIdentity",
  "TLSPSKFile=$pskDst",
  'DenyKey=system.run[*]'
)
Set-Content -Path $conf -Value $lines -Encoding utf8
icacls $conf /inheritance:r /grant:r 'SYSTEM:(R)' 'BUILTIN\Administrators:(F)' | Out-Null

Write-Host '[+] Брандмауэр: 10050 только для сервера...'
Get-NetFirewallRule -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -like '*Zabbix*' } | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'Zabbix Agent 2 (только сервер мониторинга)' `
  -Direction Inbound -Action Allow -Protocol TCP -LocalPort 10050 `
  -RemoteAddress $Server -Program (Join-Path $dir 'zabbix_agent2.exe') -Profile Any | Out-Null
# Агенту исходящие соединения не нужны вообще
New-NetFirewallRule -DisplayName 'Zabbix Agent 2 (запрет исходящих)' `
  -Direction Outbound -Action Block -Program (Join-Path $dir 'zabbix_agent2.exe') -Profile Any | Out-Null
# Ответы на входящие разрешённые соединения брандмауэр Windows пропускает сам (stateful)

Set-Service $svcName -StartupType Automatic
Start-Service $svcName
Start-Sleep 2
$s = Get-Service $svcName
Write-Host "[+] Служба: $($s.Status)"

if (-not $KeepPskSource) {
  Remove-Item -Force $PskFile
  Write-Host "[+] Файл ключа удалён с носителя: $PskFile"
}
Write-Host '[+] Готово.'
