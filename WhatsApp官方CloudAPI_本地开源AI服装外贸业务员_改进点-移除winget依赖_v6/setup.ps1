$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Download-File([string]$Url, [string]$Destination) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $client = New-Object Net.WebClient
            $client.Headers["User-Agent"] = "WhatsApp-Local-AI-v6"
            $client.DownloadFile($Url, $Destination)
            return
        } catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds (2 * $attempt)
        } finally { if ($client) { $client.Dispose() } }
    }
}

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
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host "[1/7] 下载官方Node.js便携版（不再调用winget）……"
    $toolsDir = Join-Path $Root "tools"
    $nodeDir = Join-Path $toolsDir "node"
    $nodePath = Join-Path $nodeDir "node.exe"
    if (-not (Test-Path $nodePath)) {
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
        $index = Invoke-RestMethod -Uri "https://nodejs.org/dist/index.json" -Headers @{ "User-Agent"="WhatsApp-Local-AI-v6" }
        $release = $index | Where-Object { $_.lts -and ($_.files -contains "win-x64-zip") } | Select-Object -First 1
        if (-not $release) { throw "未找到Node.js官方Windows LTS便携版" }
        $archiveName = "node-$($release.version)-win-x64.zip"
        $archive = Join-Path $env:TEMP $archiveName
        $checksums = Join-Path $env:TEMP "node-shasums-$PID.txt"
        Download-File "https://nodejs.org/dist/$($release.version)/$archiveName" $archive
        Download-File "https://nodejs.org/dist/$($release.version)/SHASUMS256.txt" $checksums
        $checksumText = Get-Content -LiteralPath $checksums -Raw
        $match = [regex]::Match($checksumText, "(?m)^([0-9a-f]{64})\s+$([regex]::Escape($archiveName))$")
        if (-not $match.Success) { throw "无法取得Node.js官方校验值" }
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
        if ($actualHash -ne $match.Groups[1].Value) { throw "Node.js下载文件校验失败" }
        $extractDir = Join-Path $env:TEMP "node-extract-$PID"
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -LiteralPath $archive -DestinationPath $extractDir -Force
        Remove-Item -LiteralPath $nodeDir -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath (Join-Path $extractDir "node-$($release.version)-win-x64") -Destination $nodeDir
        Remove-Item -LiteralPath $archive, $checksums, $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $npmPath = Join-Path $nodeDir "npm.cmd"
    $npxPath = Join-Path $nodeDir "npx.cmd"
    $env:Path = "$nodeDir;$env:Path"
    if (-not (Test-Path $nodePath)) { throw "Node.js便携版准备失败" }

    Write-Host "[2/7] 检查并安装Ollama官方程序（不再调用winget）……"
    $ollama = Get-Command ollama.exe -ErrorAction SilentlyContinue
    if ($ollama) { $ollamaPath = $ollama.Source } else {
        $candidate = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
        if (-not (Test-Path $candidate)) {
            $installer = Join-Path $env:TEMP "OllamaSetup-$PID.exe"
            Download-File "https://github.com/ollama/ollama/releases/latest/download/OllamaSetup.exe" $installer
            $signature = Get-AuthenticodeSignature -FilePath $installer
            if ($signature.Status -ne "Valid") { throw "Ollama官方安装包数字签名验证失败" }
            $process = Start-Process -FilePath $installer -ArgumentList "/VERYSILENT", "/NORESTART" -Wait -PassThru
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
            if ($process.ExitCode -ne 0) { throw "Ollama安装失败，退出码：$($process.ExitCode)" }
        }
        if (Test-Path $candidate) { $ollamaPath = $candidate } else { throw "Ollama安装完成后仍找不到ollama.exe" }
    }
    if (-not (Get-Process ollama -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $ollamaPath -ArgumentList "serve" -WindowStyle Hidden
        Start-Sleep -Seconds 3
    }

    Write-Host "[3/7] 下载适合16GB内存的本地视觉模型 qwen3-vl:8b（首次约数GB）……"
    & $ollamaPath pull qwen3-vl:8b
    if ($LASTEXITCODE -ne 0) { throw "模型下载失败" }

    Write-Host "[4/7] 安装并验证程序……"
    & $npmPath ci
    if ($LASTEXITCODE -ne 0) { throw "程序依赖安装失败" }
    & $npmPath test
    if ($LASTEXITCODE -ne 0) { throw "程序自检失败，已停止部署" }

    Write-Host "[5/7] Cloudflare免费账号授权将在浏览器打开……"
    & $npxPath wrangler login
    if ($LASTEXITCODE -ne 0) { throw "Cloudflare授权未完成" }
    $deployOutput = & $npxPath wrangler deploy 2>&1 | Tee-Object -Variable deployLines
    if ($LASTEXITCODE -ne 0) { throw "Cloudflare Worker部署失败" }
    $workerUrl = ([regex]::Match(($deployLines -join "`n"), "https://[a-zA-Z0-9.-]+\.workers\.dev")).Value.TrimEnd('/')
    if (-not $workerUrl) { $workerUrl = Read-Host "粘贴上方显示的 https://...workers.dev 地址" }

    Write-Host "[6/7] 输入Meta官方Cloud API的三项账号值。输入内容不会显示。"
    Write-Host "浏览器即将打开Meta应用后台。三个值的位置："
    Write-Host "  App Secret：App settings → Basic"
    Write-Host "  Phone Number ID：WhatsApp → API Setup"
    Write-Host "  长期令牌：Business settings → System users → Generate token"
    Start-Process "https://developers.facebook.com/apps/"
    $metaToken = Read-Secret "Meta长期访问令牌"
    $metaSecret = Read-Secret "Meta App Secret"
    $phoneId = Read-Secret "Meta Phone Number ID"
    $agentToken = New-HexToken 32
    $verifyToken = New-HexToken 24
    $secretFile = Join-Path $env:TEMP ("wa-v6-secrets-{0}.json" -f $PID)
    try {
        @{ META_ACCESS_TOKEN=$metaToken; META_APP_SECRET=$metaSecret; META_PHONE_NUMBER_ID=$phoneId; AGENT_TOKEN=$agentToken; META_VERIFY_TOKEN=$verifyToken } |
            ConvertTo-Json | Set-Content -LiteralPath $secretFile -Encoding UTF8
        & $npxPath wrangler secret bulk $secretFile
        if ($LASTEXITCODE -ne 0) { throw "加密上传密钥失败" }
    } finally { Remove-Item -LiteralPath $secretFile -Force -ErrorAction SilentlyContinue }

    Write-Host "[7/7] 创建本地配置和开机自动运行……"
    $profile = Read-Host "输入公司英文名和主要产品（可直接回车使用通用服装供应商）"
    if (-not $profile) { $profile = "Professional apparel supplier serving international B2B buyers." }
    @{ workerUrl=$workerUrl; agentToken=$agentToken; model="qwen3-vl:8b"; businessProfile=$profile } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root "local\config.json") -Encoding UTF8

    $vbsPath = Join-Path $Root "启动本地AI.vbs"
    $command = "cmd /c cd /d `"$Root`" && `"$nodePath`" local\agent.mjs >> local\agent.log 2>&1"
    $vbsCommand = $command.Replace('"', '""')
    $vbs = "Set s=CreateObject(""WScript.Shell"")`r`ns.Run ""$vbsCommand"",0,False"
    Set-Content -LiteralPath $vbsPath -Value $vbs -Encoding ASCII
    $startup = [Environment]::GetFolderPath("Startup")
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $startup "WhatsApp本地AI业务员v6.lnk"))
    $shortcut.TargetPath = "wscript.exe"
    $shortcut.Arguments = "`"$vbsPath`""
    $shortcut.WorkingDirectory = $Root
    $shortcut.Save()
    Start-Process "wscript.exe" -ArgumentList "`"$vbsPath`""

    $result = "Webhook回调地址：$workerUrl/webhook`r`nWebhook验证字符串：$verifyToken`r`n订阅字段：messages"
    Set-Content -LiteralPath (Join-Path $Root "最后一步_Meta_Webhook.txt") -Value $result -Encoding UTF8
    Set-Clipboard $result
    Write-Host "`n本地AI已启动。Meta最后需要粘贴的Webhook信息已复制到剪贴板，并保存到 最后一步_Meta_Webhook.txt。" -ForegroundColor Green
}
catch {
    Write-Host "`n安装未完成：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

