# 市场动态与制造核算台 —— 一键关闭脚本
# 用法：双击“关闭服务.bat”，或手动执行  powershell -NoProfile -ExecutionPolicy Bypass -File "关闭服务.ps1"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $root "用户数据\server.pid"
$portFile = Join-Path $root "用户数据\server.port"
$killed = @()

# 1) 按命令行匹配 server.js 进程（最可靠）
$procs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'server\.js' }
foreach ($pr in $procs) {
  Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue
  $killed += $pr.ProcessId
}

# 2) 按 pid 文件兜底
if (Test-Path -LiteralPath $pidFile) {
  foreach ($id in (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue)) {
    $pr = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($pr -and $pr.ProcessName -eq "node") { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue; $killed += $id }
  }
  Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

# 3) 按端口兜底（默认 8657 及记录端口）
$ports = @(8657)
if (Test-Path -LiteralPath $portFile) { $ports = @(Get-Content -LiteralPath $portFile -Raw -ErrorAction SilentlyContinue) }
foreach ($pt in $ports) {
  Get-NetTCPConnection -LocalPort ([int]$pt) -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object {
      $o = $_.OwningProcess
      $pr = Get-Process -Id $o -ErrorAction SilentlyContinue
      if ($pr -and $pr.ProcessName -match "node") { Stop-Process -Id $o -Force -ErrorAction SilentlyContinue; $killed += $o }
    }
}
Remove-Item -LiteralPath $portFile -Force -ErrorAction SilentlyContinue

if ($killed.Count) {
  Write-Host ("已结束后台服务进程: " + (($killed | Sort-Object -Unique) -join ", ")) -ForegroundColor Green
} else {
  Write-Host "未发现运行中的服务进程，端口已空闲。" -ForegroundColor Yellow
}