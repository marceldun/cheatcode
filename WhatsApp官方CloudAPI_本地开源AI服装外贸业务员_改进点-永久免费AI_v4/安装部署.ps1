$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Read-Secret([string]$Label) {
    $secure = Read-Host $Label -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) } }
}

try {
    Write-Host "[1/7] 检查并安装 Node.js……"
    if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { throw "此电脑缺少 winget，无法一键安装 Node.js。请先运行 Windows 更新。" }
        winget install --id OpenJS.NodeJS.LTS -e --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "Node.js 安装失败" }
        Refresh-Path
    }

    Write-Host "[2/7] 检查并安装 Ollama……"
    if (-not (Get-Command ollama.exe -ErrorAction SilentlyContinue)) {
        winget install --id Ollama.Ollama -e --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "Ollama 安装失败" }
        Refresh-Path
    }
    $ollama = Get-Command ollama.exe -ErrorAction SilentlyContinue
    if ($ollama) { $ollamaPath = $ollama.Source } else {
        $candidate = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
        if (Test-Path $candidate) { $ollamaPath = $candidate } else { throw "找不到 ollama.exe" }
    }
    if (-not (Get-Process ollama -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $ollamaPath -ArgumentList "serve" -WindowStyle Hidden
        Start-Sleep -Seconds 3
    }

    Write-Host "[3/7] 下载适合16GB内存的本地视觉模型 qwen3-vl:8b（首次约数GB）……"
    & $ollamaPath pull qwen3-vl:8b
    if ($LASTEXITCODE -ne 0) { throw "模型下载失败" }

    Write-Host "[4/7] 安装并验证程序……"
    npm.cmd ci
    if ($LASTEXITCODE -ne 0) { throw "程序依赖安装失败" }
    npm.cmd test
    if ($LASTEXITCODE -ne 0) { throw "程序自检失败，已停止部署" }

    Write-Host "[5/7] Cloudflare免费账号授权将在浏览器打开……"
    npx.cmd wrangler login
    if ($LASTEXITCODE -ne 0) { throw "Cloudflare授权未完成" }
    $deployOutput = npx.cmd wrangler deploy 2>&1 | Tee-Object -Variable deployLines
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
    $agentToken = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    $verifyToken = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
    $secretFile = Join-Path $env:TEMP ("wa-v4-secrets-{0}.json" -f $PID)
    try {
        @{ META_ACCESS_TOKEN=$metaToken; META_APP_SECRET=$metaSecret; META_PHONE_NUMBER_ID=$phoneId; AGENT_TOKEN=$agentToken; META_VERIFY_TOKEN=$verifyToken } |
            ConvertTo-Json | Set-Content -LiteralPath $secretFile -Encoding UTF8
        npx.cmd wrangler secret bulk $secretFile
        if ($LASTEXITCODE -ne 0) { throw "加密上传密钥失败" }
    } finally { Remove-Item -LiteralPath $secretFile -Force -ErrorAction SilentlyContinue }

    Write-Host "[7/7] 创建本地配置和开机自动运行……"
    $profile = Read-Host "输入公司英文名和主要产品（可直接回车使用通用服装供应商）"
    if (-not $profile) { $profile = "Professional apparel supplier serving international B2B buyers." }
    @{ workerUrl=$workerUrl; agentToken=$agentToken; model="qwen3-vl:8b"; businessProfile=$profile } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root "local\config.json") -Encoding UTF8

    $vbsPath = Join-Path $Root "启动本地AI.vbs"
    $escapedRoot = $Root.Replace('"', '""')
    $vbs = "Set s=CreateObject(""WScript.Shell"")`r`ns.Run ""cmd /c cd /d """"$escapedRoot"""" && node local\agent.mjs >> local\agent.log 2>&1"",0,False"
    Set-Content -LiteralPath $vbsPath -Value $vbs -Encoding ASCII
    $startup = [Environment]::GetFolderPath("Startup")
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $startup "WhatsApp本地AI业务员v4.lnk"))
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

