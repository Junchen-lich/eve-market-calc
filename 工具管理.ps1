# ============================================================
#  市场动态与制造核算台 —— 服务管理（启动 / 关闭 / 状态）
#  用法：
#    双击 工具管理.bat                → 检测状态并弹出操作菜单（窗口保持，选 0 退出）
#    工具管理.bat start|stop|status   → 直接执行对应操作（窗口保持，可关闭窗口结束）
#  手动：powershell -NoProfile -ExecutionPolicy Bypass -File "工具管理.ps1" [start|stop|status]
# ============================================================
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
$pidFile  = Join-Path $root "用户数据\server.pid"
$portFile = Join-Path $root "用户数据\server.port"

function Get-MkPort {
  $p = 8657
  if (Test-Path -LiteralPath $portFile) {
    try { $p = [int](Get-Content -LiteralPath $portFile -Raw -ErrorAction SilentlyContinue) } catch {}
  }
  return $p
}

# 服务是否在运行：按 server.js 命令行 / pid 文件 / 端口监听 三重判定
function Test-MkRunning {
  $procs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'server\.js' }
  if ($procs) { return $true }
  if (Test-Path -LiteralPath $pidFile) {
    foreach ($id in (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue)) {
      $pr = Get-Process -Id $id -ErrorAction SilentlyContinue
      if ($pr -and $pr.ProcessName -eq "node") { return $true }
    }
  }
  $c = Get-NetTCPConnection -LocalPort (Get-MkPort) -State Listen -ErrorAction SilentlyContinue
  if ($c) { $o = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue; if ($o -and $o.ProcessName -match "node") { return $true } }
  return $false
}

function Start-Mk {
  $port = Get-MkPort
  if (Test-MkRunning) {
    Write-Host ("服务已在运行（端口 " + $port + "）") -ForegroundColor Yellow
    Write-Host ("已直接打开工具链接: http://localhost:" + $port + "/") -ForegroundColor Green
    Start-Process ("http://localhost:" + $port + "/")
    return
  }
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "未找到 node，请先安装 Node.js 或将其加入 PATH 后重试。" -ForegroundColor Red
    return
  }
  Remove-Item -LiteralPath $pidFile  -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $portFile -Force -ErrorAction SilentlyContinue
  $env:NO_AUTO_OPEN = "1"
  $p = Start-Process -FilePath "node" -ArgumentList "server.js" -WorkingDirectory $root -WindowStyle Hidden -PassThru
  $p.Id | Out-File -FilePath $pidFile -Encoding ascii
  $port = 8657; $ok = $false
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $portFile) { $port = Get-MkPort }
    try { $r = Invoke-WebRequest -Uri ("http://localhost:" + $port + "/") -UseBasicParsing -TimeoutSec 2; if ($r.StatusCode -eq 200) { $ok = $true; break } } catch {}
  }
  if ($ok) {
    Write-Host ("服务已启动: http://localhost:" + $port + "/") -ForegroundColor Green
    Start-Process ("http://localhost:" + $port + "/")
  } else {
    Write-Host "服务启动超时或失败，请检查 node 环境与 server.js 日志。" -ForegroundColor Red
  }
}

function Stop-Mk {
  if (-not (Test-MkRunning)) {
    Write-Host "服务当前已关闭，无需操作。" -ForegroundColor Yellow
    return
  }
  $killed = @()
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'server\.js' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $killed += $_.ProcessId }
  if (Test-Path -LiteralPath $pidFile) {
    foreach ($id in (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue)) {
      $pr = Get-Process -Id $id -ErrorAction SilentlyContinue
      if ($pr -and $pr.ProcessName -eq "node") { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue; $killed += $id }
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
  }
  $ports = @(8657); if (Test-Path -LiteralPath $portFile) { $ports = @(Get-Content -LiteralPath $portFile -Raw -ErrorAction SilentlyContinue) }
  foreach ($pt in $ports) {
    Get-NetTCPConnection -LocalPort ([int]$pt) -State Listen -ErrorAction SilentlyContinue |
      ForEach-Object { $o = $_.OwningProcess; $pr = Get-Process -Id $o -ErrorAction SilentlyContinue; if ($pr -and $pr.ProcessName -match "node") { Stop-Process -Id $o -Force -ErrorAction SilentlyContinue; $killed += $o } }
  }
  Remove-Item -LiteralPath $portFile -Force -ErrorAction SilentlyContinue
  if ($killed.Count) { Write-Host ("已结束后台服务进程: " + (($killed | Sort-Object -Unique) -join ", ")) -ForegroundColor Green }
  else { Write-Host "已确认服务关闭，端口已空闲。" -ForegroundColor Yellow }
}

function Show-Status {
  if (Test-MkRunning) { Write-Host ("服务状态: 运行中（端口 " + (Get-MkPort) + "）") -ForegroundColor Green }
  else { Write-Host "服务状态: 已关闭" -ForegroundColor Yellow }
}

# 保持窗口：不“按任意键退出”。start 模式直到服务关闭或用户关闭窗口；
# stop/status 模式保持显示，直到用户直接关闭本窗口。
function Keep-MkWindow($mode) {
  Write-Host ""
  if ($mode -eq "start") {
    Write-Host "窗口保持中：服务运行期间本窗口不关闭；关闭服务（另行运行 stop）或直接关闭本窗口即可结束。" -ForegroundColor DarkGray
    while (Test-MkRunning) { Start-Sleep -Seconds 3 }
    Write-Host "检测到服务已关闭，窗口结束。" -ForegroundColor Yellow
  } else {
    Write-Host "本窗口保持显示中，可直接关闭本窗口结束。" -ForegroundColor DarkGray
    while ($true) { Start-Sleep -Seconds 5 }
  }
}

# ---------- 主流程 ----------
$cmd = $args[0]
switch ($cmd) {
  "start"  { Start-Mk;  Keep-MkWindow "start" }
  "stop"   { Stop-Mk;   Keep-MkWindow "stop" }
  "status" { Show-Status; Keep-MkWindow "status" }
  default {
    while ($true) {
      Write-Host ""
      if (Test-MkRunning) { Write-Host ("【服务状态】运行中 · 端口 " + (Get-MkPort)) -ForegroundColor Green }
      else { Write-Host "【服务状态】已关闭" -ForegroundColor Yellow }
      Write-Host "-----------------------------"
      Write-Host "  请选择操作："
      Write-Host "    [1] 启动服务并打开工具"
      Write-Host "    [2] 关闭服务"
      Write-Host "    [3] 仅查看状态"
      Write-Host "    [0] 退出（关闭窗口）"
      $sel = Read-Host "请输入编号"
      switch ($sel) {
        "1" { Start-Mk }
        "2" { Stop-Mk }
        "3" { Show-Status }
        "0" { Write-Host "已退出。"; break }
        default { Write-Host "无效输入，请重新选择。" }
      }
      if ($sel -eq "0") { break }
    }
  }
}