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

function Test-OllamaModel([string]$Model) {
    try {
        $tags = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 5
        $names = @($tags.models | ForEach-Object { $_.name })
        return (($names -contains $Model) -or ($names -contains "${Model}:latest"))
    } catch { return $false }
}

function Install-OllamaModelResumable([string]$OllamaExe, [string]$Model, [string]$LogRoot, [string]$ModelRoot) {
    if (Test-OllamaModel $Model) { Write-Host "完整模型 $Model 已存在，跳过下载。"; return }
    $attempt = 0
    while ($true) {
        $attempt++
        $stdout = Join-Path $LogRoot "model-pull-out.log"
        $stderr = Join-Path $LogRoot "model-pull-error.log"
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
        Write-Host "模型下载/续传第 $attempt 次启动；已有分片不会删除。"
        $pull = Start-Process -FilePath $OllamaExe -ArgumentList "pull", $Model -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
        $lastSavedBytes = (Get-ChildItem -LiteralPath $ModelRoot -File -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $lastSavedBytes) { $lastSavedBytes = 0L }
        $lastCpuSeconds = 0.0
        $lastActivity = Get-Date
        $lastReport = [DateTime]::MinValue
        $restart = $false
        while (-not $pull.HasExited) {
            Start-Sleep -Seconds 2
            $pull.Refresh()
            $savedBytes = (Get-ChildItem -LiteralPath $ModelRoot -File -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if ($null -eq $savedBytes) { $savedBytes = 0L }
            $cpuSeconds = (Get-Process -Name ollama -ErrorAction SilentlyContinue | ForEach-Object { $_.TotalProcessorTime.TotalSeconds } | Measure-Object -Sum).Sum
            if ($null -eq $cpuSeconds) { $cpuSeconds = 0.0 }
            if ($savedBytes -ne $lastSavedBytes) {
                $lastSavedBytes = $savedBytes
                $lastCpuSeconds = $cpuSeconds
                $lastActivity = Get-Date
            } elseif (($cpuSeconds - $lastCpuSeconds) -ge 1.0) {
                $lastCpuSeconds = $cpuSeconds
                $lastActivity = Get-Date
            }
            if (((Get-Date) - $lastReport).TotalSeconds -ge 15) {
                $idleSeconds = [Math]::Floor(((Get-Date) - $lastActivity).TotalSeconds)
                Write-Host ("完整8B模型：D盘已有 {0:N2} GB；有效活动距今 {1} 秒。" -f ($savedBytes / 1GB), $idleSeconds)
                $lastReport = Get-Date
            }
            if (((Get-Date) - $lastActivity).TotalSeconds -ge 120) {
                Write-Host "连续120秒没有下载活动，自动重启下载进程并接着已有分片继续。" -ForegroundColor Yellow
                Stop-Process -Id $pull.Id -Force -ErrorAction SilentlyContinue
                $pull.WaitForExit()
                $restart = $true
                break
            }
        }
        if (-not $restart) {
            $pull.WaitForExit()
            if ($pull.ExitCode -eq 0 -and (Test-OllamaModel $Model)) {
                Write-Host "完整模型 $Model 下载并验证完成。" -ForegroundColor Green
                return
            }
            Write-Host "本次连接已中断，5秒后自动续传；D盘分片保持不动。" -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 5
    }
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
    }
    $npmPath = Join-Path $nodeDir "npm.cmd"
    $npxPath = Join-Path $nodeDir "npx.cmd"
    $env:Path = "$nodeDir;$env:Path"

    Write-Host "[2/7] 在D盘准备Ollama官方完整便携包（不安装到C盘，可断点续传）……"
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
    }

    Write-Host "[3/7] 启动D盘Ollama；不会读取、迁移或删除C盘任何已有文件……"
    Start-Process -FilePath $ollamaPath -ArgumentList "serve" -WindowStyle Hidden | Out-Null
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        try { Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 | Out-Null; $ready = $true; break } catch { Start-Sleep -Seconds 1 }
    }
    if (-not $ready) { throw "D盘Ollama未能启动" }

    Write-Host "[4/7] 下载完整视觉模型 qwen3-vl:8b（约6.1GB，防卡死并自动断点续传）……"
    Install-OllamaModelResumable $ollamaPath "qwen3-vl:8b" $TempRoot $ModelsRoot

    Write-Host "[5/7] 在D盘安装并验证程序……"
    & $npmPath ci
    if ($LASTEXITCODE -ne 0) { throw "程序依赖安装失败" }
    & $npmPath run check
    if ($LASTEXITCODE -ne 0) { throw "类型检查失败" }
    & $npmPath test
    if ($LASTEXITCODE -ne 0) { throw "程序自检失败，已停止部署" }

    Write-Host "[6/7] 自动检查Cloudflare授权、注册workers.dev地址并部署……"
    $wranglerJs = Join-Path $AppRoot "node_modules\wrangler\bin\wrangler.js"
    $whoOut = Join-Path $TempRoot "wrangler-whoami-out.log"
    $whoErr = Join-Path $TempRoot "wrangler-whoami-error.log"
    Remove-Item -LiteralPath $whoOut, $whoErr -Force -ErrorAction SilentlyContinue
    $who = Start-Process -FilePath $nodePath -ArgumentList $wranglerJs, "whoami" -RedirectStandardOutput $whoOut -RedirectStandardError $whoErr -WindowStyle Hidden -Wait -PassThru
    if ($who.ExitCode -ne 0) {
        & $npxPath wrangler login
        if ($LASTEXITCODE -ne 0) { throw "Cloudflare授权未完成" }
    }

    $subdomainFile = Join-Path $DataRoot "cloudflare-subdomain-name.txt"
    if (Test-Path -LiteralPath $subdomainFile) {
        $automaticName = (Get-Content -LiteralPath $subdomainFile -Raw).Trim()
    } else {
        $automaticName = "wa-ai-$(New-HexToken 6)"
        Set-Content -LiteralPath $subdomainFile -Value $automaticName -Encoding ASCII
    }
    $env:CODEX_THREAD_ID = "whatsapp-local-ai-setup"
    $env:WRANGLER_CI_OVERRIDE_NAME = $automaticName
    $deployOut = Join-Path $TempRoot "wrangler-deploy-out.log"
    $deployErr = Join-Path $TempRoot "wrangler-deploy-error.log"
    Remove-Item -LiteralPath $deployOut, $deployErr -Force -ErrorAction SilentlyContinue
    $deploy = Start-Process -FilePath $nodePath -ArgumentList $wranglerJs, "deploy" -RedirectStandardOutput $deployOut -RedirectStandardError $deployErr -WindowStyle Hidden -Wait -PassThru
    $deployText = ((Get-Content -LiteralPath $deployOut -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content -LiteralPath $deployErr -Raw -ErrorAction SilentlyContinue))
    Write-Host $deployText
    if ($deploy.ExitCode -ne 0) { throw "Cloudflare自动注册或部署失败，请重新双击让程序自动重试" }
    $workerUrl = ([regex]::Match($deployText, "https://[a-zA-Z0-9.-]+\.workers\.dev")).Value.TrimEnd('/')
    if (-not $workerUrl) { $workerUrl = Read-Host "粘贴上方显示的 https://...workers.dev 地址" }

    Write-Host "[7/7] 输入Meta官方Cloud API的三项账号值。输入内容不会显示。"
    Start-Process "https://developers.facebook.com/apps/"
    $metaToken = Read-Secret "Meta长期访问令牌"
    $metaSecret = Read-Secret "Meta App Secret"
    $phoneId = Read-Secret "Meta Phone Number ID"
    $agentToken = New-HexToken 32
    $verifyToken = New-HexToken 24
    $secretFile = Join-Path $TempRoot ("wa-v11-secrets-{0}.json" -f $PID)
    try {
        @{ META_ACCESS_TOKEN=$metaToken; META_APP_SECRET=$metaSecret; META_PHONE_NUMBER_ID=$phoneId; AGENT_TOKEN=$agentToken; META_VERIFY_TOKEN=$verifyToken } |
            ConvertTo-Json | Set-Content -LiteralPath $secretFile -Encoding UTF8
        & $npxPath wrangler secret bulk $secretFile
        if ($LASTEXITCODE -ne 0) { throw "加密上传密钥失败" }
    } finally { Remove-Item -LiteralPath $secretFile -Force -ErrorAction SilentlyContinue }

    $profile = Read-Host "输入公司英文名和主要产品（直接回车使用通用服装供应商）"
    if (-not $profile) { $profile = "Professional apparel supplier serving international B2B buyers." }
    @{ workerUrl=$workerUrl; agentToken=$agentToken; model="qwen3-vl:8b"; businessProfile=$profile } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $AppRoot "local\config.json") -Encoding UTF8

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $AppRoot "repair-start.ps1") -CalledFromSetup
    if ($LASTEXITCODE -ne 0) { throw "AI后台服务启动验证失败" }

    $result = "Webhook回调地址：$workerUrl/webhook`r`nWebhook验证字符串：$verifyToken`r`n订阅字段：messages"
    Set-Content -LiteralPath (Join-Path $AppRoot "最后一步_Meta_Webhook.txt") -Value $result -Encoding UTF8
    Set-Clipboard $result
    Write-Host "`n完成。全部程序、缓存和模型均在 D:\WhatsAppLocalAI。Webhook信息已复制到剪贴板。" -ForegroundColor Green
}
catch {
    Write-Host "`n安装未完成：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "已经下载的文件保留在D盘；修复网络后重新双击会继续，不会从头下载。" -ForegroundColor Yellow
    exit 1
}
