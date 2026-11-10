#Requires -Version 5.1
<#
.SYNOPSIS
    Rename-ByRegex.ps1 が書き出したログを使ってリネームを元に戻す。

.DESCRIPTION
    ログを読み込んで「現在の名前 -> 戻した後の名前」のレビューを表示し、
    Enter で巻き戻しを実行します。ログを省略した場合は最新のものを使います。

.PARAMETER LogPath
    使用するログファイル。省略時は LogDirectory 内の最新ログ。

.PARAMETER LogDirectory
    ログの置き場所。既定は data/rename-by-regex/logs
    （スクリプトの 2 階層上にある data ディレクトリ。Rename-ByRegex.ps1 と共通）。

.PARAMETER List
    ログの一覧だけを表示して終了する。

.EXAMPLE
    .\Undo-RenameLog.ps1

.EXAMPLE
    .\Undo-RenameLog.ps1 -List

.EXAMPLE
    .\Undo-RenameLog.ps1 -LogPath ..\..\data\rename-by-regex\logs\rename-20261003-120000.json
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$LogPath,
    [string]$LogDirectory,
    [switch]$List
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Palette = @{
    Plain = @{ ForegroundColor = 'Gray'     }
    Dim   = @{ ForegroundColor = 'DarkGray' }
    Head  = @{ ForegroundColor = 'Cyan'     }
    Warn  = @{ ForegroundColor = 'Yellow'   }
    Err   = @{ ForegroundColor = 'Red'      }
    Ok    = @{ ForegroundColor = 'Green'    }
}

function Write-Tagged {
    param([string]$Text, [string]$Style = 'Plain', [switch]$NoNewline)
    $p = $script:Palette[$Style]
    Write-Host $Text @p -NoNewline:$NoNewline
}

function Write-Rule {
    param([string]$Title)
    Write-Host ''
    Write-Tagged ('-- {0} {1}' -f $Title, ('-' * [Math]::Max(1, 56 - $Title.Length))) 'Head'
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Keys)
    while ($true) {
        Write-Tagged $Prompt 'Head' -NoNewline
        $answer = ([string](Read-Host)).Trim().ToLowerInvariant()
        if ($answer -eq '') { return 'enter' }
        if ($Keys -contains $answer) { return $answer }
        Write-Tagged ('  不明な入力です。{0} のいずれかを入力してください（Enter も可）。' -f ($Keys -join ' / ')) 'Warn'
    }
}

# 既定は Rename-ByRegex.ps1 の書き出し先（Connect-SshHost.ps1 と同じ data ディレクトリ）
$logDir = if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\data\rename-by-regex\logs'))
}
else { $LogDirectory }

$logs = @()
if (Test-Path -LiteralPath $logDir) {
    $logs = @(Get-ChildItem -LiteralPath $logDir -Filter 'rename-*.json' -File |
        Sort-Object LastWriteTime -Descending)
}

if ($List) {
    Write-Rule 'リネームログ'
    if ($logs.Count -eq 0) {
        Write-Tagged ('  ログがありません: {0}' -f $logDir) 'Warn'
        exit 0
    }
    foreach ($l in $logs) {
        $data = Get-Content -LiteralPath $l.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $count = @($data.Renames).Count
        Write-Tagged ('  {0}' -f $l.Name) 'Ok'
        Write-Tagged ('      /{0}/  ->  "{1}"   {2} 件   {3}' -f `
                $data.Pattern, $data.Replacement, $count, $data.Root) 'Dim'
    }
    Write-Host ''
    exit 0
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    if ($logs.Count -eq 0) {
        Write-Tagged ('  ログがありません: {0}' -f $logDir) 'Err'
        exit 1
    }
    $LogPath = $logs[0].FullName
    Write-Tagged ('  最新のログを使います: {0}' -f $LogPath) 'Dim'
}

if (-not (Test-Path -LiteralPath $LogPath)) {
    Write-Tagged ('  ログが見つかりません: {0}' -f $LogPath) 'Err'
    exit 1
}

$log = Get-Content -LiteralPath $LogPath -Raw -Encoding UTF8 | ConvertFrom-Json
$renames = @($log.Renames)

# 元に戻すので、記録の逆順（浅い階層のディレクトリから先）に処理する
[array]::Reverse($renames)

$ready = New-Object System.Collections.ArrayList
$issues = New-Object System.Collections.ArrayList

foreach ($r in $renames) {
    if (-not (Test-Path -LiteralPath $r.NewPath)) {
        [void]$issues.Add([pscustomobject]@{ Entry = $r; Reason = '対象が見つかりません（移動・再リネーム済み？）' })
        continue
    }
    if (Test-Path -LiteralPath $r.OldPath) {
        # 大文字小文字だけの違いなら同一の実体なので問題なし
        if ($r.OldName -ine $r.NewName) {
            [void]$issues.Add([pscustomobject]@{ Entry = $r; Reason = ('戻し先 "{0}" が既に存在します' -f $r.OldName) })
            continue
        }
    }
    [void]$ready.Add($r)
}

Write-Rule ('巻き戻しレビュー  /{0}/  ->  "{1}"' -f $log.Pattern, $log.Replacement)
Write-Tagged ('  ログ: {0}   実行日時: {1}' -f (Split-Path $LogPath -Leaf), $log.Timestamp) 'Dim'
Write-Host ''

if ($ready.Count -gt 0) {
    Write-Tagged ('  戻す対象: {0} 件' -f $ready.Count) 'Ok'
    $i = 0
    foreach ($r in $ready) {
        $i++
        Write-Tagged ('    {0,3}. {1}  ->  {2}' -f $i, $r.NewName, $r.OldName) 'Plain'
    }
}

if ($issues.Count -gt 0) {
    Write-Host ''
    Write-Tagged ('  戻せない: {0} 件' -f $issues.Count) 'Err'
    foreach ($x in $issues) {
        Write-Tagged ('       {0}   ({1})' -f $x.Entry.NewName, $x.Reason) 'Warn'
    }
}

if ($ready.Count -eq 0) {
    Write-Host ''
    Write-Tagged '  戻せるものがありません。' 'Warn'
    exit 0
}

Write-Host ''
$choice = Read-Choice '  [Enter] 巻き戻しを実行  /  q: 中止 > ' @('q')
if ($choice -eq 'q') {
    Write-Tagged '  中止しました。' 'Warn'
    exit 0
}
if (-not $PSCmdlet.ShouldProcess(('{0} 件のファイル名' -f $ready.Count), '巻き戻し')) {
    exit 0
}

Write-Rule '実行'
$done = 0
$failed = 0
foreach ($r in $ready) {
    try {
        Rename-Item -LiteralPath $r.NewPath -NewName $r.OldName -ErrorAction Stop
        Write-Tagged '  ok   ' 'Ok' -NoNewline
        Write-Tagged ('{0}  ->  {1}' -f $r.NewName, $r.OldName) 'Plain'
        $done++
    }
    catch {
        Write-Tagged ('  ng   {0}  ({1})' -f $r.NewName, $_.Exception.Message) 'Err'
        $failed++
    }
}

Write-Host ''
Write-Tagged ('  完了: {0} 件を戻しました。{1}' -f $done, $(if ($failed) { " 失敗 $failed 件。" } else { '' })) 'Ok'
Write-Host ''
