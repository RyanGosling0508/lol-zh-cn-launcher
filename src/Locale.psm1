Set-StrictMode -Version Latest

function ConvertTo-MainlandLocale {
    param([Parameter(Mandatory)][string]$Text)
    # 只定位根级 settings 下的 locale，保留换行、注释和其他设置。
    $lines = [regex]::Matches($Text, '(?m)^[^\r\n]*(?:\r?\n|$)')
    $sections = @($lines | Where-Object { $_.Value -match '^settings:[ \t]*(?:#[^\r\n]*)?\r?\n?$' })
    if ($sections.Count -ne 1) { throw '配置格式不符合预期：必须只有一个根级 settings 节点。' }
    $start = $sections[0].Index + $sections[0].Length
    $end = $Text.Length
    foreach ($line in $lines) {
        if ($line.Index -ge $start -and $line.Value -match '^[^\s#]') { $end = $line.Index; break }
    }
    $body = $Text.Substring($start, $end - $start)
    $children = @([regex]::Matches($body, '(?m)^(?<indent> +)\S[^\r\n]*'))
    if (-not $children.Count) { throw 'settings 节点为空。' }
    $indent = ($children | ForEach-Object { $_.Groups['indent'].Length } | Measure-Object -Minimum).Minimum
    $pattern = '(?m)^(?<prefix> {' + $indent + '}locale:[ \t]*)(?<value>"[^"\r\n]*"|''[^''\r\n]*''|[^\s#]+)(?<tail>[ \t]*(?:#[^\r\n]*)?)(?=\r?$)'
    $matches = [regex]::Matches($body, $pattern)
    if ($matches.Count -ne 1) { throw '配置格式不符合预期：settings 下必须只有一个直接的 locale 字段。' }
    $m = $matches[0].Groups['value']
    if ($m.Value.Trim('"', "'") -eq 'zh_CN') { return $Text }
    $offset = $start + $m.Index
    return $Text.Substring(0, $offset) + '"zh_CN"' + $Text.Substring($offset + $m.Length)
}

function Set-MainlandLocale {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$BackupDirectory)
    # 使用同一个文件句柄完成读取和写入；占用时让调用方稍后重试。
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        $bytes = New-Object byte[] ([int]$stream.Length)
        $read = 0
        while ($read -lt $bytes.Length) {
            $n = $stream.Read($bytes, $read, $bytes.Length - $read)
            if ($n -eq 0) { throw '读取配置时文件意外结束。' }
            $read += $n
        }
        $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
        $skip = 0
        if ($bom) { $skip = 3 }
        $encoding = New-Object Text.UTF8Encoding($false, $true)
        $text = $encoding.GetString($bytes, $skip, $bytes.Length - $skip)
        $updated = ConvertTo-MainlandLocale -Text $text
        if ($updated -ceq $text) { return $false }
        [IO.Directory]::CreateDirectory($BackupDirectory) | Out-Null
        # 每个配置路径只保留首次原始备份；恢复时不会混用其他安装的备份。
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Path).ToLowerInvariant())))).Replace('-', '').Substring(0, 16) }
        finally { $sha.Dispose() }
        $backup = Join-Path $BackupDirectory ($key + '.original.yaml')
        if (-not [IO.File]::Exists($backup)) { [IO.File]::WriteAllBytes($backup, $bytes) }
        $payload = $encoding.GetBytes($updated)
        $stream.Position = 0
        if ($bom) { $stream.Write([byte[]](239,187,191), 0, 3) }
        $stream.Write($payload, 0, $payload.Length)
        $stream.SetLength($stream.Position)
        $stream.Flush()
        return $true
    } finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Resolve-LeaguePaths {
    param([string]$ConfigPath, [string]$RiotClientPath)
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $env:ProgramData 'Riot Games\Metadata\league_of_legends.live\league_of_legends.live.product_settings.yaml'
    }
    if ([string]::IsNullOrWhiteSpace($RiotClientPath)) {
        $registry = Join-Path $env:ProgramData 'Riot Games\RiotClientInstalls.json'
        if (Test-Path -LiteralPath $registry) {
            $data = Get-Content -LiteralPath $registry -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($key in @('rc_live','rc_default')) {
                $property = $data.PSObject.Properties[$key]
                if ($null -ne $property -and $property.Value -and (Test-Path -LiteralPath $property.Value -PathType Leaf)) {
                    $RiotClientPath = [string]$property.Value
                    break
                }
            }
        }
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw '没有找到游戏配置。请先安装并运行一次正式服 LOL，或在 config.json 中填写 configPath。' }
    if ([string]::IsNullOrWhiteSpace($RiotClientPath) -or -not (Test-Path -LiteralPath $RiotClientPath -PathType Leaf)) { throw '没有找到 Riot 启动器。请在 config.json 中填写 riotClientPath。' }
    if ([IO.Path]::GetFileName($RiotClientPath) -ine 'RiotClientServices.exe') { throw 'riotClientPath 必须指向 RiotClientServices.exe。' }
    if ([IO.Path]::GetFileName($ConfigPath) -ine 'league_of_legends.live.product_settings.yaml') { throw '此版本只支持正式服的 league_of_legends.live.product_settings.yaml。' }
    [pscustomobject]@{ ConfigPath = [IO.Path]::GetFullPath($ConfigPath); RiotClientPath = [IO.Path]::GetFullPath($RiotClientPath) }
}

Export-ModuleMember -Function ConvertTo-MainlandLocale, Set-MainlandLocale, Resolve-LeaguePaths
