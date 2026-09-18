#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Locale.psm1') -Force -DisableNameChecking
$count = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ($Actual -cne $Expected) { throw ('测试失败：' + $Name) }
    $script:count++
    Write-Host ('通过：' + $Name)
}
function Assert-Rejected($Text, $Name) {
    $failed = $false
    try { $null = ConvertTo-MainlandLocale -Text $Text } catch { $failed = $true }
    Assert-Equal $failed $true $Name
}
$sample = "locale_data:`r`n    default_locale: `"en_US`"`r`nsettings:`r`n    nested:`r`n        locale: `"ja_JP`"`r`n    locale: `"zh_TW`" # 保留注释`r`n    other: true`r`nnext: value`r`n"
$expected = $sample.Replace('locale: "zh_TW"', 'locale: "zh_CN"')
Assert-Equal (ConvertTo-MainlandLocale $sample) $expected '仅修改直接语言字段，保留嵌套字段、默认语言、注释和 CRLF'
Assert-Equal (ConvertTo-MainlandLocale $expected) $expected '重复执行不会继续改写'
Assert-Equal (ConvertTo-MainlandLocale "settings:`n  locale: en_US") "settings:`n  locale: `"zh_CN`"" '支持 LF、无末尾换行和未加引号的语言值'
Assert-Equal (ConvertTo-MainlandLocale "settings:`n  locale: 'en_US'`n") "settings:`n  locale: `"zh_CN`"`n" '支持单引号'
Assert-Rejected "settings:`n  language: zh_TW`n" '缺少 locale 时拒绝修改'
Assert-Rejected "settings:`n  locale: en_US`n  locale: zh_TW`n" '重复 locale 时拒绝修改'
Assert-Rejected "settings:`n  locale: en_US`nsettings:`n  locale: zh_TW`n" '重复 settings 时拒绝修改'
Assert-Rejected "settings:`n  nested:`n    locale: zh_TW`n" '仅有嵌套 locale 时拒绝修改'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('lol-zh-cn-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
try {
    $file = Join-Path $temp 'fixture.yaml'
    $backup = Join-Path $temp 'backups'
    $utf8 = New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($file, $sample, $utf8)
    $original = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file))
    Assert-Equal (Set-MainlandLocale $file $backup) $true '文件修改成功'
    Assert-Equal ([IO.File]::ReadAllText($file)) $expected '写入结果正确'
    $saved = @(Get-ChildItem -LiteralPath $backup -File)
    Assert-Equal $saved.Count 1 '仅创建一份备份'
    Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($saved[0].FullName))) $original '原始备份逐字节相同'
    $payload = [IO.File]::ReadAllBytes($file)
    Assert-Equal ($payload[0] -eq 239 -and $payload[1] -eq 187 -and $payload[2] -eq 191) $true '保留 UTF-8 BOM'
    Assert-Equal (Set-MainlandLocale $file $backup) $false '已是中文时不写入'
    [IO.File]::WriteAllText($file, $sample, (New-Object Text.UTF8Encoding($false)))
    $null = Set-MainlandLocale $file $backup
    Assert-Equal ([IO.File]::ReadAllBytes($file)[0] -eq 239) $false '无 BOM 文件保持无 BOM'
    Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($saved[0].FullName))) $original '后续重置不覆盖首次备份'
    $fakeExe = Join-Path $temp 'RiotClientServices.exe'
    [IO.File]::WriteAllText($fakeExe, '')
    $properFile = Join-Path $temp 'league_of_legends.live.product_settings.yaml'
    Copy-Item -LiteralPath $file -Destination $properFile
    $paths = Resolve-LeaguePaths -ConfigPath $properFile -RiotClientPath $fakeExe
    Assert-Equal $paths.ConfigPath $properFile '接受用户指定的有效路径'
} finally {
    # 只清理本次测试生成的、已经验证位于临时目录下的唯一文件夹。
    $resolved = [IO.Path]::GetFullPath($temp)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and ([IO.Path]::GetFileName($resolved) -match '^lol-zh-cn-test-[a-f0-9]{32}$')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host ("全部 {0} 项测试通过。" -f $count) -ForegroundColor Green
