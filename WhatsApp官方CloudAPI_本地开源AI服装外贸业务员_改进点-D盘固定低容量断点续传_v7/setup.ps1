param([switch]$FromBootstrap)

$ErrorActionPreference = "Stop"
$PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataRoot = "D:\WhatsAppLocalAI"
$AppRoot = Join-Path $DataRoot "app"
$RuntimeRoot = Join-Path $DataRoot "runtime"
$CacheRoot = Join-Path $DataRoot "cache"
$TempRoot = Join-Path $DataRoot "temp"
$ModelsRoot = Join-Path $DataRoot "models"
$ollamaArchive = $null
$ollamaPath = $null

function Read-Secret([string]$Label) {
    $secure = Read-Host $Label -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) } }
}

function New-HexToken([int]$ByteCount) {
    $bytes = New-Object byte[] $ByteCount
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

try {
    if (-not (Test-Path -LiteralPath "D:\")) { throw "没有检测到D盘。请插入或创建D盘后重新双击；本安装器绝不会改用C盘。" }
    New-Item -ItemType Directory -Path $DataRoot, $AppRoot, $RuntimeRoot, $CacheRoot, $TempRoot, $ModelsRoot -Force | Out-Null

    if (-not $FromBootstrap -and ([IO.Path]::GetFullPath($PackageRoot).TrimEnd('\') -ne [IO.Path]::GetFullPath($AppRoot).TrimEnd('\'))) {
        Write-Host "[0/7] 把程序复制到 D:\WhatsAppLocalAI（后续全部从D盘运行）……"
        & robocopy.exe $PackageRoot $AppRoot /E /R:2 /W:1 /XD node_modules .wrangler /XF "local\config.json" "*.log" | Out-Null
        if ($LASTEXITCODE -gt 7) { throw "复制程序到D盘失败，Robocopy退出码：$LASTEXITCODE" }
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $AppRoot "setup.ps1") -FromBootstrap
        exit $LASTEXITCODE
    }

    Set-Location $AppRoot
    $env:TEMP = $TempRoot
    $env:TMP = $TempRoot
    $env:npm_config_cache = Join-Path $CacheRoot "npm"
    $env:XDG_CONFIG_HOME = Join-Path $DataRoot "config"
    $env:OLLAMA_MODELS = $ModelsRoot
    [Environment]::SetEnvironmentVariable("OLLAMA_MODELS", $ModelsRoot, "User")
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    . (Join-Path $AppRoot "download.ps1")

    Write-Host "[1/7] 在D盘准备Node.js便携版（可断点续传）……"
    $nodeVersion = "v24.22.0"
    $nodeArchiveName = "node-$nodeVersion-win-x64.zip"
    $nodeArchive = Join-Path $CacheRoot $nodeArchiveName
    $nodeDir = Join-Path $RuntimeRoot "node"
    $nodePath = Join-Path $nodeDir "node.exe"
    if (-not (Test-Path -LiteralPath $nodePath)) {
        Download-FileResumable "https://nodejs.org/dist/$nodeVersion/$nodeArchiveName" $nodeArchive "Node.js"
        $expectedNodeHash = "f9683a19877e12a9b167305c8db71040d812876359de21f0d2e97c3f321f80c3"
        $actualNodeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $nodeArchive).Hash.ToLowerInvariant()
        if ($actualNodeHash -ne $expectedNodeHash) {
            Remove-Item -LiteralPath $nodeArchive -Force
            throw "Node.js校验失败，损坏文件已删除；重新双击即可重新下载。"
        }
        $nodeExtract = Join-Path $TempRoot "node-extract"
        Remove-Item -LiteralPath $nodeExtract -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -LiteralPath $nodeArchive -DestinationPath $nodeExtract -Force
        Remove-Item -LiteralPath $nodeDir -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath (Join-Path $nodeExtract "node-$nodeVersion-win-x64") -Destination $nodeDir
        Remove-Item -LiteralPath $nodeExtract -Recurse -Force
        Remove-Item -LiteralPath $nodeArchive -Force
    }
    $npmPath = Join-Path $nodeDir "npm.cmd"
    $npxPath = Join-Path $nodeDir "npx.cmd"
    $env:Path = "$nodeDir;$env:Path"

    Write-Host "[2/7] 在D盘准备Ollama便携版（不安装到C盘，可断点续传）……"
    Stop-Process -Name ollama -Force -ErrorAction SilentlyContinue
    $ollamaDir = Join-Path $RuntimeRoot "ollama"
    $ollamaPath = Join-Path $ollamaDir "ollama.exe"
    if (-not (Test-Path -LiteralPath $ollamaPath)) {
        $ollamaArchive = Join-Path $CacheRoot "ollama-windows-amd64.zip"
        Download-FileResumable "https://github.com/ollama/ollama/releases/latest/download/ollama-windows-amd64.zip" $ollamaArchive "Ollama"
        $ollamaExtract = Join-Path $TempRoot "ollama-extract"
        Remove-Item -LiteralPath $ollamaExtract -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -LiteralPath $ollamaArchive -DestinationPath $ollamaExtract -Force
        $foundOllama = Get-ChildItem -LiteralPath $ollamaExtract -Filter ollama.exe -Recurse | Select-Object -First 1
        if (-not $foundOllama) { throw "Ollama压缩包中没有ollama.exe" }
        $signature = Get-AuthenticodeSignature -FilePath $foundOllama.FullName
        if ($signature.Status -ne "Valid") { throw "Ollama官方程序数字签名验证失败" }
        Remove-Item -LiteralPath $ollamaDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($foundOllama.Directory.FullName -eq $ollamaExtract) {
            Move-Item -LiteralPath $ollamaExtract -Destination $ollamaDir
        } else {
            Move-Item -LiteralPath $foundOllama.Directory.FullName -Destination $ollamaDir
            Remove-Item -LiteralPath $ollamaExtract -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $ollamaArchive -Force
    }

    Write-Host "[3/7] 清理C盘旧的8B未完成分片，并把已有完整模型迁移到D盘……"
    $oldModels = Join-Path $env:USERPROFILE ".ollama\models"
    if (Test-Path -LiteralPath $oldModels) {
        Get-ChildItem -LiteralPath $oldModels -Filter "*partial*" -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        & robocopy.exe $oldModels $ModelsRoot /E /MOVE /R:2 /W:1 | Out-Null
        if ($LASTEXITCODE -gt 7) { throw "旧模型从C盘迁移到D盘失败，Robocopy退出码：$LASTEXITCODE" }
    }
    $oldOllamaDir = Join-Path $env:LOCALAPPDATA "Programs\Ollama"
    $oldUninstaller = Get-ChildItem -LiteralPath $oldOllamaDir -Filter "unins*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($oldUninstaller) { Start-Process -FilePath $oldUninstaller.FullName -ArgumentList "/VERYSILENT", "/NORESTART" -Wait }

    Start-Process -FilePath $ollamaPath -ArgumentList "serve" -WindowStyle Hidden | Out-Null
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        try { Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 | Out-Null; $ready = $true; break } catch { Start-Sleep -Seconds 1 }
    }
    if (-not $ready) { throw "D盘Ollama未能启动" }

    & $ollamaPath rm qwen3-vl:8b 2>$null
    Write-Host "[4/7] 下载低容量视觉模型 qwen3-vl:2b。每个分片会单独从0%计数，不是整包重下；中断后重新双击会续传。"
    & $ollamaPath pull qwen3-vl:2b
    if ($LASTEXITCODE -ne 0) { throw "模型下载中断。已下载分片保留在D盘，重新双击会续传。" }

    Write-Host "[5/7] 在D盘安装并验证程序……"
    & $npmPath ci
    if ($LASTEXITCODE -ne 0) { throw "程序依赖安装失败" }
    & $npmPath run check
    if ($LASTEXITCODE -ne 0) { throw "类型检查失败" }
    & $npmPath test
    if ($LASTEXITCODE -ne 0) { throw "程序自检失败，已停止部署" }
    & $npmPath cache clean --force | Out-Null

    Write-Host "[6/7] Cloudflare免费账号授权将在浏览器打开……"
    & $npxPath wrangler login
    if ($LASTEXITCODE -ne 0) { throw "Cloudflare授权未完成" }
    $deployOutput = & $npxPath wrangler deploy 2>&1 | Tee-Object -Variable deployLines
    if ($LASTEXITCODE -ne 0) { throw "Cloudflare Worker部署失败" }
    $workerUrl = ([regex]::Match(($deployLines -join "`n"), "https://[a-zA-Z0-9.-]+\.workers\.dev")).Value.TrimEnd('/')
    if (-not $workerUrl) { $workerUrl = Read-Host "粘贴上方显示的 https://...workers.dev 地址" }

    Write-Host "[7/7] 输入Meta官方Cloud API的三项账号值。输入内容不会显示。"
    Start-Process "https://developers.facebook.com/apps/"
    $metaToken = Read-Secret "Meta长期访问令牌"
    $metaSecret = Read-Secret "Meta App Secret"
    $phoneId = Read-Secret "Meta Phone Number ID"
    $agentToken = New-HexToken 32
    $verifyToken = New-HexToken 24
    $secretFile = Join-Path $TempRoot ("wa-v7-secrets-{0}.json" -f $PID)
    try {
        @{ META_ACCESS_TOKEN=$metaToken; META_APP_SECRET=$metaSecret; META_PHONE_NUMBER_ID=$phoneId; AGENT_TOKEN=$agentToken; META_VERIFY_TOKEN=$verifyToken } |
            ConvertTo-Json | Set-Content -LiteralPath $secretFile -Encoding UTF8
        & $npxPath wrangler secret bulk $secretFile
        if ($LASTEXITCODE -ne 0) { throw "加密上传密钥失败" }
    } finally { Remove-Item -LiteralPath $secretFile -Force -ErrorAction SilentlyContinue }

    $profile = Read-Host "输入公司英文名和主要产品（直接回车使用通用服装供应商）"
    if (-not $profile) { $profile = "Professional apparel supplier serving international B2B buyers." }
    @{ workerUrl=$workerUrl; agentToken=$agentToken; model="qwen3-vl:2b"; businessProfile=$profile } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $AppRoot "local\config.json") -Encoding UTF8

    $vbsPath = Join-Path $AppRoot "启动本地AI.vbs"
    $agentLog = Join-Path $AppRoot "local\agent.log"
    $command = "cmd /c set OLLAMA_MODELS=$ModelsRoot&& start `"`" /min `"$ollamaPath`" serve && cd /d `"$AppRoot`" && `"$nodePath`" local\agent.mjs >> `"$agentLog`" 2>&1"
    $vbsCommand = $command.Replace('"', '""')
    $vbs = "Set s=CreateObject(""WScript.Shell"")`r`ns.Run ""$vbsCommand"",0,False"
    Set-Content -LiteralPath $vbsPath -Value $vbs -Encoding ASCII
    $startup = [Environment]::GetFolderPath("Startup")
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $startup "WhatsApp本地AI业务员v7.lnk"))
    $shortcut.TargetPath = "wscript.exe"
    $shortcut.Arguments = "`"$vbsPath`""
    $shortcut.WorkingDirectory = $AppRoot
    $shortcut.Save()
    Start-Process "wscript.exe" -ArgumentList "`"$vbsPath`""

    $result = "Webhook回调地址：$workerUrl/webhook`r`nWebhook验证字符串：$verifyToken`r`n订阅字段：messages"
    Set-Content -LiteralPath (Join-Path $AppRoot "最后一步_Meta_Webhook.txt") -Value $result -Encoding UTF8
    Set-Clipboard $result
    Write-Host "`n完成。全部程序、缓存和模型均在 D:\WhatsAppLocalAI。Webhook信息已复制到剪贴板。" -ForegroundColor Green
}
catch {
    if ($ollamaArchive -and (-not $ollamaPath -or -not (Test-Path -LiteralPath $ollamaPath))) {
        Remove-Item -LiteralPath $ollamaArchive -Force -ErrorAction SilentlyContinue
    }
    Write-Host "`n安装未完成：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "已经下载的文件保留在D盘；修复网络后重新双击会继续，不会从头下载。" -ForegroundColor Yellow
    exit 1
}
