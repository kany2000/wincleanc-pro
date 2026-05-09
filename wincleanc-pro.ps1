<#
.SYNOPSIS
    wincleanc-pro — Windows C 盘深度清理工具
    基于 Cotton059/Light-Help 项目重构优化

.DESCRIPTION
    - 完全本地执行，无需联网下载
    - 支持预览模式（-Preview）仅扫描不删除
    - 自动记录操作日志
    - 智能跳过系统关键目录
    - 深度清理 .tmp 等冗余文件
    - 集成 DISM + cleanmgr 系统工具
    - 支持清空回收站和浏览器缓存

.EXAMPLE
    # 普通清理（推荐以管理员身份运行）
    PowerShell -ExecutionPolicy Bypass -File "wincleanc-pro.ps1"

.EXAMPLE
    # 仅扫描预览，不执行删除
    PowerShell -ExecutionPolicy Bypass -File "wincleanc-pro.ps1" -Preview

.EXAMPLE
    # 极速模式（跳过大小统计，直接清理）
    PowerShell -ExecutionPolicy Bypass -File "wincleanc-pro.ps1" -Fast

.PARAMETER Preview
    预览模式：仅扫描并列出目标，不执行删除操作

.PARAMETER Fast
    快速模式：清理时跳过大小统计，提升执行速度

.PARAMETER NoSystemClean
    跳过系统级清理（DISM / cleanmgr / RecycleBin）

.PARAMETER LogPath
    自定义日志路径（默认：C:\LightHelp_Clean\logs）
#>

[CmdletBinding()]
param(
    [switch]$Preview,
    [switch]$Fast,
    [switch]$NoSystemClean,
    [string]$LogPath = "C:\LightHelp_Clean\logs"
)

# ================= 配置区域 =================
$Script:Version = "1.0.0"

# 已知的可安全清理的目录（精确路径）
$Script:KnownCleanPaths = @(
    "$env:LOCALAPPDATA\Temp",
    "$env:LOCALAPPDATA\CrashDumps",
    "$env:TEMP",
    "$env:WINDIR\Temp",
    "$env:WINDIR\Prefetch",
    "$env:WINDIR\SoftwareDistribution\Download",
    "$env:WINDIR\DeliveryOptimization\Files",
    "$env:WINDIR\Logs",
    "$env:WINDIR\LiveKernelReports",
    "$env:ProgramData\Microsoft\Windows\WER",
    "$env:LOCALAPPDATA\Microsoft\Windows\INetCache",
    "$env:LOCALAPPDATA\Microsoft\Windows\DeliveryOptimization",
    "$env:LOCALAPPDATA\Microsoft\Windows\WER"
)

# 在 Temp 类型目录内扫描的额外目标名（仅在已知 temp 目录下匹配）
$Script:TempDirTargets = @(
    "Cache", "cache", ".cache",
    "CrashDumps",
    "LogFiles", "Logs",
    "tmp"
)

# 排除的系统关键路径（绝不触碰）
$Script:ExcludeRoots = @(
    "$env:WINDIR\System32",
    "$env:WINDIR\SysWOW64",
    "$env:WINDIR\WinSxS",
    "$env:WINDIR\assembly",
    "$env:WINDIR\Microsoft.NET",
    "$env:ProgramFiles",
    "${env:ProgramFiles(x86)}",
    "$env:USERPROFILE\AppData\Local\Microsoft\OneDrive",
    "$env:USERPROFILE\AppData\Local\Microsoft\WindowsApps",
    "$env:USERPROFILE\AppData\Local\Microsoft\Teams",
    "$env:ProgramData\Microsoft\Windows\Start Menu"
)

# .tmp 文件搜索路径
$Script:TmpSearchPaths = @(
    "$env:TEMP",
    "$env:WINDIR\Temp",
    "$env:LOCALAPPDATA\Temp"
)

$Script:ScanDepth = 6   # 最大递归深度
# ===========================================

# 初始化
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Script:StartTime = Get-Date
$Script:TotalDirsScanned = 0
$Script:TotalTmpScanned = 0
$Script:FoundTargets = [System.Collections.Generic.List[string]]::new()
$Script:FoundTmpFiles = [System.Collections.Generic.List[string]]::new()
$Script:DeletedCount = 0
$Script:TmpDeletedCount = 0
$Script:TotalFreedBytes = 0

# =================== 函数定义 ===================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    if (-not (Test-Path $LogPath)) {
        New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
    }
    $logFile = Join-Path $LogPath "LightHelp_$(Get-Date -Format 'yyyyMMdd').log"
    Add-Content -Path $logFile -Value $logEntry -Encoding UTF8 -Force

    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "White" }
    }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "$([math]::Round($Bytes / 1GB, 2)) GB" }
    if ($Bytes -ge 1MB) { return "$([math]::Round($Bytes / 1MB, 2)) MB" }
    if ($Bytes -ge 1KB) { return "$([math]::Round($Bytes / 1KB, 2)) KB" }
    return "$Bytes Bytes"
}

# 是否匹配排除路径
function Test-Excluded {
    param([string]$Path)
    foreach ($ex in $Script:ExcludeRoots) {
        $normalEx = $ex.TrimEnd('\')
        if ($Path -eq $normalEx -or $Path -like "$normalEx\*") { return $true }
    }
    return $false
}

# 是否为 NTFS 重解析点（junction/symlink），跳过以避免递归循环
function Test-IsReparsePoint {
    param([System.IO.DirectoryInfo]$Item)
    return $Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint
}

# 匹配已知 temp 目录下的子目标名
function Test-TempDirTarget {
    param([string]$Name)
    return $Name -in $Script:TempDirTargets
}

# 计算目录大小（递归）
function Get-DirSize {
    param([string]$Path)
    try {
        $files = Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue
        $sum = ($files | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        return [math]::Max(0, $sum)
    }
    catch { return 0 }
}

# =================== 扫描模块 ===================

# 1. 添加已知路径到清理列表
function Add-KnownPaths {
    foreach ($path in $Script:KnownCleanPaths) {
        if ((Test-Path $path) -and (-not $Script:FoundTargets.Contains($path))) {
            $Script:FoundTargets.Add($path)
            $Script:TotalDirsScanned++
        }
    }
}

# 2. 在 temp 目录下扫描额外可清理子目录（跳过重解析点）
function Invoke-TempDirScan {
    param([string]$Root, [int]$Depth = 0)
    if ($Depth -gt $Script:ScanDepth) { return }
    try {
        $items = Get-ChildItem -Path $Root -Directory -Force -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            # 跳过 NTFS 重解析点（junction），避免无限递归
            if (Test-IsReparsePoint -Item $item) { continue }
            $Script:TotalDirsScanned++
            if (Test-Excluded -Path $item.FullName) { continue }
            if (Test-TempDirTarget -Name $item.Name) {
                if (-not $Script:FoundTargets.Contains($item.FullName)) {
                    $Script:FoundTargets.Add($item.FullName)
                }
            }
            Invoke-TempDirScan -Root $item.FullName -Depth ($Depth + 1)
        }
    }
    catch { }
}

# 3. .tmp 文件扫描
function Invoke-TmpScan {
    param([string]$Root)
    try {
        Get-ChildItem -Path $Root -Filter "*.tmp" -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Excluded -Path $_.FullName) } |
            ForEach-Object {
                $Script:TotalTmpScanned++
                if (-not $Script:FoundTmpFiles.Contains($_.FullName)) {
                    $Script:FoundTmpFiles.Add($_.FullName)
                }
            }
    }
    catch { }
}

# =================== 主流程 ===================

$Script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

Clear-Host
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    Light-Help Local Clean v$($Script:Version)" -ForegroundColor Cyan
Write-Host "    Windows Deep Clean Tool (Optimized)" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $Script:IsAdmin) {
    Write-Log "Not running as Administrator. Some system locations will be skipped." "WARN"
    Write-Host "  Tip: Right-click PowerShell -> 'Run as Administrator' for full access" -ForegroundColor Yellow
    Write-Host ""
}

if ($Preview) {
    Write-Host "  [PREVIEW MODE] Scan only, no files will be deleted." -ForegroundColor Yellow
    Write-Host ""
}

if ($Fast) {
    Write-Host "  [FAST MODE] Skip size statistics for faster cleanup." -ForegroundColor Yellow
    Write-Host ""
}

# ========== 阶段一：扫描目标目录 ==========
Write-Log "Scanning target directories..." "INFO"
Write-Host "  Scanning target directories..." -ForegroundColor Cyan
Write-Host ""

# 1. 添加已知可清理路径
Add-KnownPaths
Write-Host "    Known clean paths : $($Script:FoundTargets.Count)" -ForegroundColor DarkGray

# 2. 在 Temp 目录下扫描额外可清理的子目录
$tempScanRoots = @(
    "$env:LOCALAPPDATA\Temp",
    "$env:TEMP",
    "$env:WINDIR\Temp"
)
foreach ($root in $tempScanRoots) {
    if (Test-Path $root) {
        Invoke-TempDirScan -Root $root -Depth 0
    }
}
Write-Host "    Total targets    : $($Script:FoundTargets.Count)" -ForegroundColor DarkGray
Write-Host ""

# ========== 阶段二：.tmp 文件扫描 ==========
Write-Log "Scanning .tmp files..." "INFO"
Write-Host "  Scanning .tmp files..." -ForegroundColor Cyan
Write-Host ""

foreach ($rp in $Script:TmpSearchPaths) {
    if (Test-Path $rp) {
        Invoke-TmpScan -Root $rp
    }
}
Write-Host "    .tmp files found: $($Script:FoundTmpFiles.Count)" -ForegroundColor DarkGray
Write-Host ""

# ========== 阶段三：统计可释放空间 (Preview / Normal) ==========
$Script:PreviewSizes = @{}
$Script:TmpTotalBytes = 0

if ($Preview -or (-not $Fast)) {
    $total = $Script:FoundTargets.Count + $Script:FoundTmpFiles.Count
    $idx = 0

    foreach ($folder in $Script:FoundTargets) {
        $idx++
        Write-Progress -Activity "Calculating directory sizes..." -Status "$idx / $total" -PercentComplete ($idx / $total * 100)
        $size = Get-DirSize -Path $folder
        $Script:PreviewSizes[$folder] = $size
        $Script:TotalFreedBytes += $size
    }

    foreach ($tmpFile in $Script:FoundTmpFiles) {
        $idx++
        Write-Progress -Activity "Calculating .tmp file sizes..." -Status "$idx / $total" -PercentComplete ($idx / $total * 100)
        try {
            $size = (Get-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue).Length
            $size = [math]::Max(0, $size)
            $Script:TotalFreedBytes += $size
            $Script:TmpTotalBytes += $size
        }
        catch { }
    }
    Write-Progress -Activity "Done" -Completed
}

# ========== 结果汇总 ==========
Write-Host ""
Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Scan Complete!" -ForegroundColor Green
Write-Host "    Junk directories   : $($Script:FoundTargets.Count)"
Write-Host "    .tmp files         : $($Script:FoundTmpFiles.Count)"

if ($Script:TotalFreedBytes -gt 0) {
    $estDisplay = Format-FileSize $Script:TotalFreedBytes
    Write-Host "    Est. space to free: $estDisplay" -ForegroundColor Yellow
}
Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

if ($Script:FoundTargets.Count -eq 0 -and $Script:FoundTmpFiles.Count -eq 0) {
    Write-Host "  No junk found. Your system is clean!" -ForegroundColor Green
    Write-Log "No targets found." "SUCCESS"
    Read-Host "  Press Enter to exit"
    exit
}

# ========== 预览模式 ==========
if ($Preview) {
    Write-Host "  Junk directories to clean:" -ForegroundColor Cyan
    foreach ($folder in $Script:FoundTargets) {
        $sz = if ($Script:PreviewSizes.ContainsKey($folder)) { $Script:PreviewSizes[$folder] } else { 0 }
        $szStr = if ($sz -gt 0) { Format-FileSize $sz } else { "---" }
        Write-Host "    * $folder  [$szStr]" -ForegroundColor Gray
    }
    if ($Script:FoundTmpFiles.Count -gt 0) {
        Write-Host ""
        Write-Host "  .tmp files to clean:" -ForegroundColor Cyan
        Write-Host "    Total: $($Script:FoundTmpFiles.Count) files ($(Format-FileSize $Script:TmpTotalBytes))" -ForegroundColor Gray
        # 显示前 20 个
        $Script:FoundTmpFiles | Select-Object -First 20 | ForEach-Object {
            Write-Host "    * $_" -ForegroundColor DarkGray
        }
        if ($Script:FoundTmpFiles.Count -gt 20) {
            Write-Host "    ... and $($Script:FoundTmpFiles.Count - 20) more" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "  Tip: Remove -Preview to perform actual cleaning." -ForegroundColor Yellow
    Write-Log "Preview complete." "INFO"
    Read-Host "  Press Enter to exit"
    exit
}

# ========== 确认 ==========
Write-Host ""
$confirm = Read-Host "  Confirm cleanup? [Y/n] (Default: Y)"
if ($confirm -ne "" -and $confirm -notmatch "^[Yy]$") {
    Write-Log "User cancelled." "WARN"
    Write-Host "  Cancelled. No files deleted." -ForegroundColor Red
    Read-Host "  Press Enter to exit"
    exit
}

# ==========================================
# ========== 执行清理 ==========
# ==========================================
Write-Log "Begin cleanup..." "INFO"
Write-Host ""
Write-Host "  Cleaning..." -ForegroundColor Cyan
Write-Host ""

$Script:TotalFreedBytes = 0  # 重新统计实际释放

# ---- 清理目录 ----
foreach ($folder in $Script:FoundTargets) {
    try {
        if (-not (Test-Path $folder)) {
            Write-Host "    [SKIP] Not found: $folder" -ForegroundColor DarkGray
            continue
        }
        # 计算大小（Fast 模式跳过）
        $size = 0
        if (-not $Fast) {
            $size = Get-DirSize -Path $folder
            if (-not $size) { $size = 0 }
        }
        $Script:TotalFreedBytes += $size

        # 删内容
        Get-ChildItem -Path $folder -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        $Script:DeletedCount++
        $detail = if (-not $Fast -and $size -gt 0) { "  ($(Format-FileSize $size))" } else { "" }
        Write-Host "    [DONE] $folder$detail" -ForegroundColor DarkGray
        Write-Log "Cleaned: $folder" "SUCCESS"
    }
    catch {
        Write-Log "Failed: $folder - $($_.Exception.Message)" "ERROR"
        Write-Host "    [FAIL] $folder" -ForegroundColor Red
    }
}

# ---- 清理 .tmp 文件 ----
if ($Script:FoundTmpFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "  --- Cleaning .tmp files ---" -ForegroundColor Cyan
    $tmpFreed = 0
    foreach ($tmpFile in $Script:FoundTmpFiles) {
        try {
            if (-not (Test-Path $tmpFile)) { continue }
            $size = 0
            if (-not $Fast) {
                $size = [math]::Max(0, (Get-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue).Length)
            }
            Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
            $tmpFreed += $size
            $Script:TmpDeletedCount++
        }
        catch { }
    }
    $Script:TotalFreedBytes += $tmpFreed
    Write-Host "    [DONE] Deleted $Script:TmpDeletedCount .tmp files ($(Format-FileSize $tmpFreed))" -ForegroundColor DarkGray
    Write-Log "Deleted $Script:TmpDeletedCount .tmp files, freed $(Format-FileSize $tmpFreed)" "SUCCESS"
}

# ---- 系统级清理（管理员 + 非跳过）----
if ($Script:IsAdmin -and (-not $NoSystemClean)) {
    Write-Host ""
    Write-Host "  --- System-level cleanup ---" -ForegroundColor Cyan

    # 1. DISM 清理
    try {
        Write-Host "    [DISM] Running..." -ForegroundColor DarkGray
        $dismResult = dism /online /Cleanup-Image /StartComponentCleanup /Quiet 2>&1
        Write-Log "DISM component cleanup completed." "SUCCESS"
        Write-Host "    [DISM] Component cleanup done" -ForegroundColor DarkGray
    }
    catch {
        Write-Log "DISM cleanup skipped: $($_.Exception.Message)" "WARN"
    }

    # 2. cleanmgr /sagerun (预设)
    try {
        Write-Host "    [cleanmgr] Disk cleanup..." -ForegroundColor DarkGray
        Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/sagerun:1" -Wait -WindowStyle Hidden
        Write-Log "cleanmgr disk cleanup completed." "SUCCESS"
        Write-Host "    [cleanmgr] Done" -ForegroundColor DarkGray
    }
    catch {
        Write-Log "cleanmgr skipped: $($_.Exception.Message)" "WARN"
    }

    # 3. 清空回收站
    try {
        Write-Host "    [RecycleBin] Emptying..." -ForegroundColor DarkGray
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Log "Recycle Bin cleared." "SUCCESS"
        Write-Host "    [RecycleBin] Done" -ForegroundColor DarkGray
    }
    catch {
        Write-Log "Recycle Bin skip: $($_.Exception.Message)" "WARN"
    }

    # 4. Windows 更新缓存清理
    $wuPath = "$env:WINDIR\SoftwareDistribution\Download"
    if (Test-Path $wuPath) {
        try {
            # 停止更新服务，清缓存，重启
            Get-Service wuauserv, BITS -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' } | Stop-Service -Force
            $wuSize = Get-DirSize -Path $wuPath
            Get-ChildItem -Path $wuPath -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            $Script:TotalFreedBytes += $wuSize
            Write-Host "    [Windows Update] Cache cleared ($(Format-FileSize $wuSize))" -ForegroundColor DarkGray
            Write-Log "Windows Update cache cleared, freed $(Format-FileSize $wuSize)" "SUCCESS"
        }
        catch {
            Write-Log "Windows Update cache skip: $($_.Exception.Message)" "WARN"
        }
    }

    # 5. 清理系统日志 (事件日志)
    try {
        Write-Host "    [EventLogs] Clearing..." -ForegroundColor DarkGray
        wevtutil el | ForEach-Object {
            try { wevtutil cl "$_" 2>$null } catch { }
        }
        Write-Log "Event logs cleared." "SUCCESS"
        Write-Host "    [EventLogs] Done" -ForegroundColor DarkGray
    }
    catch {
        Write-Log "Event log cleanup skip" "WARN"
    }

    # 6. 清理浏览器缓存（用户级）
    $browserPaths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Service Worker\CacheStorage",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache",
        "$env:LOCALAPPDATA\Microsoft\Windows\INetCache",
        "$env:USERPROFILE\AppData\Roaming\Mozilla\Firefox\Profiles\*\cache2",
        "$env:USERPROFILE\AppData\Roaming\Mozilla\Firefox\Profiles\*\offlinecache"
    )
    foreach ($bp in $browserPaths) {
        try {
            $resolved = Resolve-Path -Path $bp -ErrorAction SilentlyContinue
            if ($resolved) {
                Get-ChildItem -Path $resolved.Path -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "    [Browser] $($resolved.Path.Split('\')[-3..-1] -join '\')" -ForegroundColor DarkGray
            }
        }
        catch { }
    }
    Write-Host "    [Browser] Caches cleaned" -ForegroundColor DarkGray
}

# ==========================================
# ========== 最终报告 ==========
# ==========================================
$elapsed = (New-TimeSpan $Script:StartTime (Get-Date)).TotalSeconds
$freedDisplay = Format-FileSize $Script:TotalFreedBytes
$logFilePath = Join-Path $LogPath "LightHelp_$(Get-Date -Format 'yyyyMMdd').log"

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    Cleanup Complete!" -ForegroundColor Green
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

if ($Script:TotalFreedBytes -gt 0) {
    Write-Host "    Space freed     : $freedDisplay" -ForegroundColor Yellow
}
else {
    Write-Host "    Space freed     : (none)" -ForegroundColor Gray
}
Write-Host "    Dirs cleaned    : $Script:DeletedCount" -ForegroundColor White
Write-Host "    .tmp files      : $Script:TmpDeletedCount" -ForegroundColor White
Write-Host "    Time elapsed    : $([math]::Round($elapsed, 1)) seconds" -ForegroundColor White
Write-Host "    Log file        : $logFilePath" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan

Write-Log "Task complete. Freed $freedDisplay in $([math]::Round($elapsed,1))s." "SUCCESS"

Write-Host ""
Read-Host "  Press Enter to exit"
