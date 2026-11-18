#Requires -Version 7.0
<#
.SYNOPSIS
    会社名・人名などを識別子に置き換えて外部 AI に渡し、回答を元に戻す GUI（TextMask）。

.DESCRIPTION
    文章中の会社名・人名・拠点名などを [[COMPANY_01]] のような識別子にローカルで置き換え（マスキング）、
    外部 AI に添削してもらった回答を、同じウィンドウ（セッション）の対応表で元の名称に戻します（復元）。
    ネットワーク通信は行いません。AI への送信はクリップボード経由でユーザー自身が行います。

    永続辞書は ..\..\data\textmask\profiles\<プロファイル名>.json（平文 JSON）に保存します。
    一時辞書と対応表はメモリ上だけにあり、ウィンドウを閉じると失われます。
    別のプロセスで起動した TextMask からは復元できません。

.PARAMETER Clipboard
    起動時にクリップボードのテキストを入力欄に読み込む。

.PARAMETER ProfileName
    使用するプロファイル（辞書）の名前。英数字・_・- のみ。省略時は前回のもの。-Profile でも指定できる。

.PARAMETER DataDirectory
    辞書と設定の置き場所。既定はリポジトリの 1 階層上の data\textmask。

.PARAMETER Detach
    別プロセスでウィンドウを開き、すぐにプロンプトへ戻る。

.EXAMPLE
    Start-TextMask.ps1

.EXAMPLE
    Start-TextMask.ps1 -Clipboard -Profile work

.EXAMPLE
    Start-TextMask.ps1 -Detach
#>
[CmdletBinding()]
param(
    [switch]$Clipboard,
    [Alias('Profile')][string]$ProfileName,
    [string]$DataDirectory,
    [switch]$Detach
)

$ErrorActionPreference = 'Stop'

if ($ProfileName -and $ProfileName -cnotmatch '^[A-Za-z0-9_\-]{1,40}$') {
    Write-Error ('プロファイル名には英数字・_・- だけを使ってください: {0}' -f $ProfileName)
    exit 1
}
if (-not $DataDirectory) {
    $DataDirectory = Join-Path $PSScriptRoot '..\..\data\textmask'
}
$DataDirectory = [System.IO.Path]::GetFullPath($DataDirectory)

# 別プロセスで起動し直すときの引数（機密データは渡さない）
function Get-ForwardArgument {
    $a = [System.Collections.Generic.List[string]]::new()
    $a.AddRange([string[]]@('-NoProfile', '-STA', '-File', $PSCommandPath, '-DataDirectory', $DataDirectory))
    if ($Clipboard) { $a.Add('-Clipboard') }
    if ($ProfileName) { $a.AddRange([string[]]@('-ProfileName', $ProfileName)) }
    return , $a.ToArray()
}

$pwshPath = [Environment]::ProcessPath

if ($Detach) {
    # Start-Process は引数を空白で連結するだけなので、空白を含むものは引用符で囲む
    $quoted = foreach ($x in Get-ForwardArgument) { if ($x -match '\s') { '"{0}"' -f $x } else { $x } }
    Start-Process -FilePath $pwshPath -ArgumentList $quoted -WindowStyle Hidden
    exit 0
}

# WinForms とクリップボードは STA が必要
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    & $pwshPath @(Get-ForwardArgument)
    exit $LASTEXITCODE
}

$moduleDir = Join-Path $PSScriptRoot 'TextMask'
$modules = 'MaskEngine', 'Dictionary', 'Clipboard', 'GUI'
try {
    foreach ($m in $modules) {
        Import-Module (Join-Path $moduleDir "$m.psm1") -Force -DisableNameChecking
    }

    $initial = $null
    if ($Clipboard) {
        try { $initial = Get-TextMaskClipboardText }
        catch { Write-Warning 'クリップボードを読み取れませんでした。空の状態で起動します。' }
    }

    Show-TextMaskWindow -DataDirectory $DataDirectory -ProfileName $ProfileName -InitialText $initial
}
catch {
    # TextMask 自身の例外メッセージには原文・対応表を含めていない
    Write-Host ('TextMask でエラーが発生しました: {0}' -f $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    exit 1
}
finally {
    $initial = $null
    foreach ($m in $modules) { Remove-Module $m -Force -ErrorAction SilentlyContinue }
}
