$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$AdbPath = Join-Path $Root "工具\adb.exe"
$BackupDir = Join-Path $Root "备份"

function Adb([string[]]$AdbArgs, [switch]$CanFail) {
    $out = & $AdbPath @AdbArgs 2>&1 | Out-String
    if (($LASTEXITCODE -ne 0) -and (-not $CanFail)) { throw "ADB 命令失败：adb $($AdbArgs -join ' ')`n$out" }
    return $out.Trim()
}
function Shell([string]$Command, [switch]$CanFail) { return Adb @("shell", $Command) -CanFail:$CanFail }

try {
    $file = Get-ChildItem -LiteralPath $BackupDir -Filter "配置前_*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $file) { throw "没有找到可恢复的配置备份。" }
    $backup = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Adb @("start-server") | Out-Null
    $rows = Adb @("devices")
    if (@($rows -split "`r?`n" | Where-Object { $_ -match "\sdevice$" }).Count -ne 1) { throw "请连接一台已允许 USB 调试的手机。" }

    foreach ($item in $backup.Settings) {
        if (($item.OldValue -eq "null") -or ($null -eq $item.OldValue) -or ($item.OldValue -eq "")) {
            Shell "settings delete $($item.Namespace) $($item.Name)" | Out-Null
        } else {
            Shell "settings put $($item.Namespace) $($item.Name) $($item.OldValue)" | Out-Null
        }
    }
    foreach ($app in $backup.Apps) {
        if (-not $app.WasIdleWhitelisted) { Shell "cmd deviceidle whitelist -$($app.Package)" -CanFail | Out-Null }
        if ((-not $app.WasNetWhitelisted) -and ($app.Uid -ne "")) { Shell "cmd netpolicy remove restrict-background-whitelist $($app.Uid)" -CanFail | Out-Null }
        Shell "cmd appops set $($app.Package) RUN_IN_BACKGROUND $($app.RunInBackground)" -CanFail | Out-Null
        Shell "cmd appops set $($app.Package) RUN_ANY_IN_BACKGROUND $($app.RunAnyInBackground)" -CanFail | Out-Null
    }
    Write-Host "`n已恢复到执行 v2 之前保存的设置。" -ForegroundColor Green
}
catch {
    Write-Host "`n恢复失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

