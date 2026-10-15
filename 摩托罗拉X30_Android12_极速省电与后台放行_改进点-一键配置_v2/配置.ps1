$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$AdbPath = Join-Path $Root "工具\adb.exe"
$BackupDir = Join-Path $Root "备份"
$LogPath = Join-Path $Root ("配置日志_{0}.txt" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Log([string]$Text) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Text
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Adb([string[]]$AdbArgs, [switch]$CanFail) {
    $out = & $AdbPath @AdbArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    if (($code -ne 0) -and (-not $CanFail)) {
        throw "ADB 命令失败（退出码 $code）：adb $($AdbArgs -join ' ')`n$out"
    }
    return $out.Trim()
}

function Shell([string]$Command, [switch]$CanFail) {
    return Adb @("shell", $Command) -CanFail:$CanFail
}

function Get-Setting([string]$Namespace, [string]$Name) {
    return (Shell "settings get $Namespace $Name" -CanFail).Trim()
}

function Get-AppOp([string]$Package, [string]$Operation) {
    $value = Shell "cmd appops get $Package $Operation" -CanFail
    if ($value -match "(?m)^${Operation}:\s+(allow|deny|ignore|default|foreground)\b") { return $Matches[1] }
    return "default"
}

try {
    if (-not (Test-Path -LiteralPath $AdbPath)) { throw "工具目录缺少 adb.exe。" }
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    Log "正在连接手机……"
    Adb @("start-server") | Out-Null

    $authorized = @()
    for ($i = 0; $i -lt 90; $i++) {
        $rows = Adb @("devices") -CanFail
        $authorized = @($rows -split "`r?`n" | Where-Object { $_ -match "\sdevice$" })
        if ($authorized.Count -eq 1) { break }
        if ($rows -match "unauthorized") {
            if ($i -eq 0) { Log "请在手机弹窗中点一次“允许 USB 调试”，程序会自动继续。" }
        }
        Start-Sleep -Seconds 1
    }
    if ($authorized.Count -ne 1) { throw "未检测到唯一且已授权的手机。请连接一台手机并允许 USB 调试。" }

    $manufacturer = Shell "getprop ro.product.manufacturer"
    $model = Shell "getprop ro.product.model"
    $release = Shell "getprop ro.build.version.release"
    $apiText = Shell "getprop ro.build.version.sdk"
    $api = 0
    [void][int]::TryParse($apiText, [ref]$api)
    Log "已连接：$manufacturer $model，Android $release（API $api）"

    $settingTargets = @(
        @{ Namespace = "global"; Name = "window_animation_scale"; Value = "0.5" },
        @{ Namespace = "global"; Name = "transition_animation_scale"; Value = "0.5" },
        @{ Namespace = "global"; Name = "animator_duration_scale"; Value = "0.5" },
        @{ Namespace = "global"; Name = "wifi_scan_always_enabled"; Value = "0" },
        @{ Namespace = "global"; Name = "ble_scan_always_enabled"; Value = "0" },
        @{ Namespace = "global"; Name = "app_standby_enabled"; Value = "1" },
        @{ Namespace = "global"; Name = "cached_apps_freezer"; Value = "enabled" }
    )

    $installedText = Shell "pm list packages"
    $installed = @($installedText -split "`r?`n" | ForEach-Object { $_ -replace "^package:", "" })
    $wanted = @("com.tencent.mm", "com.hpbr.bosszhipin")
    $wanted += @($installed | Where-Object { $_ -match "(?i)syncthing" })
    $packages = @($wanted | Select-Object -Unique | Where-Object { $installed -contains $_ })

    $oldIdle = Shell "dumpsys deviceidle whitelist" -CanFail
    $oldNet = Shell "cmd netpolicy list restrict-background-whitelist" -CanFail
    $backupApps = @()
    foreach ($pkg in $packages) {
        $uidText = Shell "dumpsys package $pkg" -CanFail
        $uid = ""
        if ($uidText -match "userId=(\d+)") { $uid = $Matches[1] }
        $backupApps += [PSCustomObject]@{
            Package = $pkg
            WasIdleWhitelisted = ($oldIdle -match [regex]::Escape($pkg))
            WasNetWhitelisted = (($uid -ne "") -and ($oldNet -match "\b$uid\b"))
            Uid = $uid
            RunInBackground = Get-AppOp $pkg "RUN_IN_BACKGROUND"
            RunAnyInBackground = Get-AppOp $pkg "RUN_ANY_IN_BACKGROUND"
        }
    }

    $backup = [PSCustomObject]@{
        Version = 2
        CreatedAt = (Get-Date).ToString("o")
        Device = [PSCustomObject]@{ Manufacturer = $manufacturer; Model = $model; Android = $release; Api = $api }
        Settings = @($settingTargets | ForEach-Object {
            [PSCustomObject]@{ Namespace = $_.Namespace; Name = $_.Name; OldValue = Get-Setting $_.Namespace $_.Name }
        })
        Apps = $backupApps
    }
    $backupPath = Join-Path $BackupDir ("配置前_{0}.json" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $backup | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $backupPath -Encoding UTF8
    Log "原设置已备份：$backupPath"

    foreach ($item in $settingTargets) {
        Shell "settings put $($item.Namespace) $($item.Name) $($item.Value)" | Out-Null
    }

    foreach ($app in $backupApps) {
        $pkg = $app.Package
        Shell "cmd deviceidle whitelist +$pkg" | Out-Null
        Shell "cmd appops set $pkg RUN_IN_BACKGROUND allow" | Out-Null
        Shell "cmd appops set $pkg RUN_ANY_IN_BACKGROUND allow" -CanFail | Out-Null
        Shell "am set-inactive $pkg false" -CanFail | Out-Null
        Shell "am set-standby-bucket $pkg active" -CanFail | Out-Null
        if ($app.Uid -ne "") { Shell "cmd netpolicy add restrict-background-whitelist $($app.Uid)" -CanFail | Out-Null }
        if ($api -ge 33) { Shell "pm grant $pkg android.permission.POST_NOTIFICATIONS" -CanFail | Out-Null }
        Log "已放行：$pkg"
    }

    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($item in $settingTargets) {
        $actual = Get-Setting $item.Namespace $item.Name
        if ($actual -ne $item.Value) { $failures.Add("设置未生效：$($item.Name)，实际值 $actual") }
    }
    $newIdle = Shell "dumpsys deviceidle whitelist" -CanFail
    foreach ($app in $backupApps) {
        if ($newIdle -notmatch [regex]::Escape($app.Package)) { $failures.Add("Doze 放行失败：$($app.Package)") }
        $op = Get-AppOp $app.Package "RUN_IN_BACKGROUND"
        if ($op -ne "allow") { $failures.Add("后台权限失败：$($app.Package)，实际值 $op") }
    }

    if ($failures.Count -gt 0) { throw ($failures -join "`n") }
    if ($packages.Count -eq 0) { Log "警告：指定的三个应用均未安装；系统优化已完成，安装应用后可再次双击本文件。" }
    Log "验证通过：7 项系统设置和 $($packages.Count) 个已安装目标应用均已回读成功。"
    Write-Host "`n配置成功。以后安装微信、BOSS直聘或 Syncthing 后，再双击一次即可自动放行。" -ForegroundColor Green
}
catch {
    Log "失败：$($_.Exception.Message)"
    Write-Host "`n配置没有完整通过验证，请查看日志。" -ForegroundColor Red
    exit 1
}

