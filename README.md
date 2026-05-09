# wincleanc-pro

> Windows C 盘深度清理工具 | Windows Deep Clean Tool for C Drive

一键清理 Windows 系统临时文件、缓存、.tmp 文件、浏览器缓存、回收站等冗余数据，集成 DISM 和 cleanmgr 系统工具，安全高效地释放磁盘空间。

---

## 功能特点

- **本地执行** — 纯 PowerShell 脚本，无需联网下载任何组件
- **安全可靠** — 智能跳过系统关键目录，不触碰系统核心文件
- **深度清理** — 清理 Temp、Prefetch、CrashDumps、WER、Logs 等 10+ 个目录
- **.tmp 文件** — 自动扫描并删除 Temp 目录下的残留 .tmp 文件
- **浏览器缓存** — 支持 Chrome / Edge / IE 缓存清理
- **系统集成** — DISM 组件清理 + cleanmgr 磁盘清理 + 回收站清空 + 事件日志清理
- **预览模式** — `-Preview` 参数仅扫描不删除，先看再清
- **快速模式** — `-Fast` 参数跳过大小统计，速度更快
- **操作日志** — 自动记录每次清理详情到日志文件

## 使用方法

### 基本清理（推荐以管理员身份运行）

```powershell
powershell -ExecutionPolicy Bypass -File "wincleanc-pro.ps1"
```

### 预览模式（仅扫描，不删除）

```powershell
powershell -ExecutionPolicy Bypass -File "wincleanc-pro.ps1" -Preview
```

### 快速模式（跳过大小统计）

```powershell
powershell -ExecutionPolicy Bypass -File "wincleanc-pro.ps1" -Fast
```

### 跳过系统级清理

```powershell
powershell -ExecutionPolicy Bypass -File "wincleanc-pro.ps1" -NoSystemClean
```

### 自定义日志路径

```powershell
powershell -ExecutionPolicy Bypass -File "wincleanc-pro.ps1" -LogPath "D:\MyLogs"
```

## 参数说明

| 参数 | 说明 |
|------|------|
| `-Preview` | 预览模式：仅扫描列出目标，不执行删除 |
| `-Fast` | 快速模式：跳过目录大小统计，更快完成 |
| `-NoSystemClean` | 跳过系统级清理（DISM / cleanmgr / 回收站等）|
| `-LogPath` | 自定义日志保存路径（默认：`C:\LightHelp_Clean\logs`）|

## 清理目录清单

| 清理项 | 说明 |
|--------|------|
| `AppData\Local\Temp` | 用户临时文件 |
| `Windows\Temp` | 系统临时文件 |
| `Windows\Prefetch` | 预读取缓存 |
| `Windows\SoftwareDistribution\Download` | Windows 更新缓存 |
| `Windows\Logs` | 系统日志文件 |
| `Windows\LiveKernelReports` | 内核故障转储 |
| `AppData\Local\CrashDumps` | 程序崩溃转储 |
| `ProgramData\Microsoft\Windows\WER` | Windows 错误报告 |
| `AppData\Local\INetCache` | IE/Edge 缓存 |
| `.tmp` 文件 | Temp 目录下的残留临时文件 |
| 回收站 | Windows 回收站 |
| 浏览器缓存 | Chrome / Edge 缓存 |
| 事件日志 | Windows 事件日志 |
| DISM | 组件存储清理 |

## 安全机制

- 排除 `System32`、`SysWOW64`、`WinSxS`、`Program Files` 等系统关键目录
- 跳过 NTFS 重解析点（junction），防止无限递归
- 不扫描 VS Code、npm、OneDrive、Teams 等应用的缓存目录
- 预览模式可提前查看所有待清理目标

## 许可

MIT License
