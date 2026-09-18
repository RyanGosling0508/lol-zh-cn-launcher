#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Check, [switch]$Stop, [string]$ConfigPath, [string]$RiotClientPath)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\Locale.psm1') -Force -DisableNameChecking
$stateDirectory = Join-Path $PSScriptRoot '.runtime'
$stopFile = Join-Path $stateDirectory 'stop'
$mutex = $null
$ownsMutex = $false
try {
    $userConfig = Join-Path $PSScriptRoot 'config.json'
    if (Test-Path -LiteralPath $userConfig) {
        $settings = Get-Content -LiteralPath $userConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $ConfigPath) { $ConfigPath = $settings.configPath }
        if (-not $RiotClientPath) { $RiotClientPath = $settings.riotClientPath }
    }
    if ($Stop) {
        [IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
        [IO.File]::WriteAllText($stopFile, 'stop')
        Write-Host '已请求停止此文件夹启动的语言维护。不会关闭游戏或修改现有语言。'
        exit 0
    }
    $paths = Resolve-LeaguePaths -ConfigPath $ConfigPath -RiotClientPath $RiotClientPath
    $null = ConvertTo-MainlandLocale -Text ([IO.File]::ReadAllText($paths.ConfigPath))
    if ($Check) {
        Write-Host '检查通过：已找到启动器，游戏配置格式符合预期。'
        Write-Host ('配置：' + $paths.ConfigPath)
        Write-Host ('启动器：' + $paths.RiotClientPath)
        Write-Host '本次检查没有修改任何游戏文件。'
        exit 0
    }
    $mutex = New-Object Threading.Mutex($false, 'Local\LOLZhCnCommunityLauncher')
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { Write-Host '语言维护已经在运行，请使用已打开的 Riot 客户端。'; exit 0 }
    [IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
    if (Test-Path -LiteralPath $stopFile) { Remove-Item -LiteralPath $stopFile }
    $backupDirectory = Join-Path $stateDirectory 'backups'
    $null = Set-MainlandLocale -Path $paths.ConfigPath -BackupDirectory $backupDirectory
    Start-Process -FilePath $paths.RiotClientPath -ArgumentList '--launch-product=league_of_legends','--launch-patchline=live' -WindowStyle Hidden
    Write-Host '已启动 Riot。请在客户端中点击游玩，等待中文资源下载完成。' -ForegroundColor Green
    Write-Host '请保留本窗口，可以最小化。按 Ctrl+C 或运行 Stop.cmd 可停止语言维护。'
    Write-Host 'Riot 完全退出后，本窗口中的维护程序会自动结束。'
    $started = Get-Date
    $lastSeen = $started
    $nextProcessCheck = $started
    $nextErrorMessage = $started
    $consecutiveFailures = 0
    while (-not (Test-Path -LiteralPath $stopFile)) {
        try {
            if (Set-MainlandLocale -Path $paths.ConfigPath -BackupDirectory $backupDirectory) {
                Write-Host ('[{0}] 已将启动器重置的语言恢复为大陆简体中文。' -f (Get-Date -Format 'HH:mm:ss'))
            }
            $consecutiveFailures = 0
        } catch {
            $consecutiveFailures++
            if ((Get-Date) -ge $nextErrorMessage) {
                Write-Warning ('暂时无法维护语言：' + $_.Exception.Message)
                $nextErrorMessage = (Get-Date).AddSeconds(10)
            }
            if ($consecutiveFailures -ge 120) { throw '连续约 30 秒无法维护配置，已停止。请确认没有只读或拒绝写入限制，并查看上方错误。' }
        }
        if ((Get-Date) -ge $nextProcessCheck) {
            if (Get-Process -Name RiotClientServices -ErrorAction SilentlyContinue) { $lastSeen = Get-Date }
            elseif (((Get-Date) - $started).TotalSeconds -gt 30 -and ((Get-Date) - $lastSeen).TotalSeconds -gt 15) { break }
            $nextProcessCheck = (Get-Date).AddSeconds(3)
        }
        Start-Sleep -Milliseconds 250
    }
    Write-Host '语言维护已结束。'
} catch {
    Write-Host ('运行失败：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '请参阅 README.md 的常见问题；脚本不会自动更改系统权限。'
    exit 1
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
