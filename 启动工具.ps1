# 市场动态与制造核算台 —— 一键启动脚本
# 用法：双击“启动工具.bat”，或手动执行  powershell -NoProfile -ExecutionPolicy Bypass -File "启动工具.ps1"
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
$pidFile = Join-Path $root "用户数据\server.pid"
$portFile = Join-Path $root "用户数据\server.port"

# 已有服务在运行：直接打开页面并退出
$running = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'server\.js' }
if ($running) {
  $port = 8657
  if (Test-Path -LiteralPath $portFile) { $port = [int](Get-Content -LiteralPath $portFile -Raw -ErrorAction SilentlyContinue) }
  Write-Host ("服务已在运行 (PID " + (($running.ProcessId | Sort-Object -Unique) -join ",") + ")")
  Start-Process ("http://localhost:" + $port + "/")
  exit 0
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Host "未找到 node，请先安装 Node.js 或将其加入 PATH 后重试。" -ForegroundColor Red
  exit 1
}

# 清理旧的状态文件，启动服务（隐藏窗口）
Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $portFile -Force -ErrorAction SilentlyContinue
$env:NO_AUTO_OPEN = "1"
$p = Start-Process -FilePath "node" -ArgumentList "server.js" -WorkingDirectory $root -WindowStyle Hidden -PassThru
$p.Id | Out-File -FilePath $pidFile -Encoding ascii

# 等待服务就绪（最长 20 秒），读取实际端口
$port = 8657
$ok = $false
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 500
  if (Test-Path -LiteralPath $portFile) { $port = [int](Get-Content -LiteralPath $portFile -Raw -ErrorAction SilentlyContinue) }
  try {
    $r = Invoke-WebRequest -Uri ("http://localhost:" + $port + "/") -UseBasicParsing -TimeoutSec 2
    if ($r.StatusCode -eq 200) { $ok = $true; break }
  } catch { }
}
if ($ok) {
  Write-Host ("服务已启动: http://localhost:" + $port + "/") -ForegroundColor Green
  Start-Process ("http://localhost:" + $port + "/")
} else {
  Write-Host "服务启动超时或失败，请检查 node 环境与 server.js 日志。" -ForegroundColor Red
}