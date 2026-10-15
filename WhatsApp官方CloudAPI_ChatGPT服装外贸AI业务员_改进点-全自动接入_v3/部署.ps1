$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Put-Secret([string]$Name, [string]$Label) {
    $secure = Read-Host $Label -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        $plain | & npx.cmd wrangler secret put $Name
        if ($LASTEXITCODE -ne 0) { throw "保存 $Name 失败" }
    }
    finally {
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        $plain = $null
    }
}

try {
    if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) {
        Start-Process "https://nodejs.org/en/download"
        throw "电脑尚未安装 Node.js。已打开官方下载页面；安装 LTS 版本后重新双击本文件。"
    }
    Write-Host "[1/4] 安装经过锁定的依赖……"
    & npm.cmd ci
    if ($LASTEXITCODE -ne 0) { throw "依赖安装失败" }

    Write-Host "[2/4] 浏览器即将打开 Cloudflare 官方授权页……"
    & npx.cmd wrangler login
    if ($LASTEXITCODE -ne 0) { throw "Cloudflare 授权未完成" }

    Write-Host "[3/4] 创建 Worker……"
    & npx.cmd wrangler deploy
    if ($LASTEXITCODE -ne 0) { throw "Worker 创建失败" }

    Write-Host "[4/4] 密钥仅加密保存到 Cloudflare，不会写入文件或 GitHub。"
    $verifyToken = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
    $verifyToken | & npx.cmd wrangler secret put META_VERIFY_TOKEN
    if ($LASTEXITCODE -ne 0) { throw "保存 META_VERIFY_TOKEN 失败" }
    Set-Content -LiteralPath (Join-Path $Root "Webhook验证字符串.txt") -Value $verifyToken -Encoding UTF8
    Put-Secret "META_ACCESS_TOKEN" "粘贴 Meta 长期访问令牌"
    Put-Secret "META_APP_SECRET" "粘贴 Meta App Secret"
    Put-Secret "META_PHONE_NUMBER_ID" "粘贴 Meta Phone Number ID"
    Put-Secret "OPENAI_API_KEY" "粘贴 OpenAI API Key"

    Write-Host "`n部署完成。请复制上方 workers.dev 地址并在末尾添加 /webhook，填入 Meta Webhook。验证字符串已自动生成在 Webhook验证字符串.txt。" -ForegroundColor Green
}
catch {
    Write-Host "`n部署未完成：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
