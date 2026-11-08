<#
.SYNOPSIS
    このディレクトリにある PowerShell スクリプトの一覧を説明付きで表示する。

.DESCRIPTION
    スクリプトと同じディレクトリにある .ps1 を一覧表示します。
    説明は README.md のファイル一覧表の「概要」欄から取り、
    表にないものはスクリプトの .SYNOPSIS を使います。

    プロファイルで PSReadLine のキーハンドラーに登録しておくと、
    どのディレクトリにいても Ctrl+Shift+? で呼び出せます（README.md 参照）。

.EXAMPLE
    Show-ScriptList.ps1
#>
[CmdletBinding()]
param()

$scriptDir = $PSScriptRoot
$readme    = Join-Path $scriptDir '..\README.md'

# README のファイル一覧表から「ファイル名 -> 概要」を作る
#   | [`powershell/Foo.ps1`](#foops1) | 概要 | 依存 |
$descriptions = @{}
if (Test-Path -LiteralPath $readme) {
    foreach ($line in Get-Content -LiteralPath $readme -Encoding utf8) {
        if ($line -match '^\|\s*\[`powershell/([^`]+)`\]\([^)]*\)\s*\|\s*([^|]+?)\s*\|') {
            $descriptions[$Matches[1]] = $Matches[2] -replace '`', ''
        }
    }
}

$scripts = Get-ChildItem -LiteralPath $scriptDir -Filter *.ps1 -File |
    Sort-Object Name

$rows = foreach ($s in $scripts) {
    $desc = $descriptions[$s.Name]
    if (-not $desc) {
        # README にない場合は .SYNOPSIS の次の行を使う
        $lines = Get-Content -LiteralPath $s.FullName -TotalCount 30 -Encoding utf8
        for ($i = 0; $i -lt $lines.Count - 1; $i++) {
            if ($lines[$i] -match '^\s*\.SYNOPSIS\s*$') { $desc = $lines[$i + 1].Trim(); break }
        }
    }
    [pscustomobject]@{ Name = $s.Name; Description = $desc }
}

$width = ($rows.Name | Measure-Object -Maximum -Property Length).Maximum

Write-Host ''
Write-Host "  スクリプト一覧 ($scriptDir)" -ForegroundColor DarkGray
foreach ($r in $rows) {
    Write-Host ('  ' + $r.Name.PadRight($width + 2)) -ForegroundColor Cyan -NoNewline
    Write-Host $r.Description
}
Write-Host ''
