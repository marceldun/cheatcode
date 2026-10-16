param([switch]$CalledFromSetup)

$ErrorActionPreference = "Stop"
$PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataRoot = "D:\WhatsAppLocalAI"
$AppRoot = Join-Path $DataRoot "app"
$NodePath = Join-Path $DataRoot "runtime\node\node.exe"
$OllamaPath = Join-Path $DataRoot "runtime\ollama\ollama.exe"
$ModelsRoot = Join-Path $DataRoot "models"
$StatusPath = Join-Path $AppRoot "local\AI服务运行状态.txt"
$OutLog = Join-Path $AppRoot "local\agent.out.log"
$ErrorLog = Join-Path $AppRoot "local\agent.error.log"

try {
    foreach ($required in @($NodePath, $OllamaPath, (Join-Path $AppRoot "local\config.json"))) {
        if (-not (Test-Path -LiteralPath $required)) { throw "缺少已安装文件：$required" }
    }
    $sourceAgent = Join-Path $PackageRoot "local\agent.mjs"
    $targetAgent = Join-Path $AppRoot "local\agent.mjs"
    if ([IO.Path]::GetFullPath($sourceAgent) -ne [IO.Path]::GetFullPath($targetAgent)) {
        Copy-Item -LiteralPath $sourceAgent -Destination $targetAgent -Force
    }

    $env:OLLAMA_MODELS = $ModelsRoot
    try { Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 3 | Out-Null }
    catch { Start-Process -FilePath $OllamaPath -ArgumentList "serve" -WindowStyle Hidden; Start-Sleep -Seconds 4 }

    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*WhatsAppLocalAI*local*agent.mjs*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $StatusPath, $OutLog, $ErrorLog -Force -ErrorAction SilentlyContinue

    $agent = Start-Process -FilePath $NodePath -ArgumentList "local\agent.mjs" -WorkingDirectory $AppRoot -RedirectStandardOutput $OutLog -RedirectStandardError $ErrorLog -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        $agent.Refresh()
        if ($agent.HasExited) {
            $detail = Get-Content -LiteralPath $ErrorLog -Raw -ErrorAction SilentlyContinue
            throw "AI进程启动后退出：$detail"
        }
        if (Test-Path -LiteralPath $StatusPath) { break }
    }
    if (-not (Test-Path -LiteralPath $StatusPath)) { throw "AI进程没有生成运行状态文件" }
    $firstHeartbeat = (Get-Item -LiteralPath $StatusPath).LastWriteTimeUtc
    Start-Sleep -Seconds 17
    $agent.Refresh()
    $secondHeartbeat = (Get-Item -LiteralPath $StatusPath).LastWriteTimeUtc
    if ($agent.HasExited -or $secondHeartbeat -le $firstHeartbeat) { throw "AI进程未能持续运行或心跳没有更新" }

    $cmdPath = Join-Path $AppRoot "start-local-ai.cmd"
    $cmd = "@echo off`r`nset `"OLLAMA_MODELS=$ModelsRoot`"`r`nstart `"`" /min `"$OllamaPath`" serve`r`ncd /d `"$AppRoot`"`r`n`"$NodePath`" local\agent.mjs 1>>`"$OutLog`" 2>>`"$ErrorLog`"`r`n"
    Set-Content -LiteralPath $cmdPath -Value $cmd -Encoding ASCII
    $vbsPath = Join-Path $AppRoot "start-local-ai.vbs"
    $launch = "cmd.exe /d /c `"`"$cmdPath`"`""
    $vbsLaunch = $launch.Replace('"', '""')
    Set-Content -LiteralPath $vbsPath -Value "CreateObject(""WScript.Shell"").Run ""$vbsLaunch"",0,False" -Encoding ASCII
    $startup = [Environment]::GetFolderPath("Startup")
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $startup "WhatsApp本地AI业务员v11.lnk"))
    $shortcut.TargetPath = "wscript.exe"
    $shortcut.Arguments = "`"$vbsPath`""
    $shortcut.WorkingDirectory = $AppRoot
    $shortcut.Save()

    Write-Host "AI后台服务已启动，并通过连续心跳验证。" -ForegroundColor Green
    if (-not $CalledFromSetup) { Start-Process notepad.exe -ArgumentList "`"$StatusPath`"" }
}
catch {
    Write-Host "修复启动失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
