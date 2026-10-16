function Download-FileResumable([string]$Url, [string]$Destination, [string]$Label) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    if (Test-Path -LiteralPath $Destination) { Write-Host "$Label 已完整下载，直接复用。"; return }
    $partial = "$Destination.part"
    $attempt = 0
    while ($true) {
        $attempt++
        $response = $null; $inputStream = $null; $outputStream = $null
        try {
            $offset = if (Test-Path -LiteralPath $partial) { (Get-Item -LiteralPath $partial).Length } else { 0L }
            $request = [Net.HttpWebRequest]::Create($Url)
            $request.UserAgent = "WhatsApp-Local-AI-v8"
            $request.AllowAutoRedirect = $true
            $request.Timeout = 60000
            $request.ReadWriteTimeout = 60000
            $request.KeepAlive = $false
            if ($offset -gt 0) { $request.AddRange($offset) }
            $response = [Net.HttpWebResponse]$request.GetResponse()
            $isPartial = ([int]$response.StatusCode -eq 206)
            if ($offset -gt 0 -and -not $isPartial) { throw "服务器本次未接受断点，保留已有文件并自动重试" }
            $remaining = [int64]$response.ContentLength
            $total = if ($remaining -gt 0) { $offset + $remaining } else { -1L }
            $inputStream = $response.GetResponseStream()
            $mode = if ($offset -gt 0) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
            $outputStream = New-Object IO.FileStream($partial, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $buffer = New-Object byte[] (1024 * 1024)
            $received = $offset
            $lastUpdate = [DateTime]::MinValue
            while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $outputStream.Write($buffer, 0, $read)
                $received += $read
                if (((Get-Date) - $lastUpdate).TotalSeconds -ge 1) {
                    if ($total -gt 0) {
                        $percent = [Math]::Min(100, [Math]::Floor($received * 100.0 / $total))
                        Write-Host -NoNewline ("`r{0}: {1}%  {2:N0}/{3:N0} MB    " -f $Label, $percent, ($received/1MB), ($total/1MB))
                    } else { Write-Host -NoNewline ("`r{0}: 已保存 {1:N0} MB    " -f $Label, ($received/1MB)) }
                    $lastUpdate = Get-Date
                }
            }
            $outputStream.Flush()
            $outputStream.Dispose(); $outputStream = $null
            $inputStream.Dispose(); $inputStream = $null
            $response.Dispose(); $response = $null
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            Write-Host "`r$Label：下载完成                              "
            return
        } catch {
            Write-Host "`n$Label 暂时中断（第 $attempt 次），已有进度仍在D盘，5秒后续传。" -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        } finally {
            if ($outputStream) { $outputStream.Dispose() }
            if ($inputStream) { $inputStream.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }
}
