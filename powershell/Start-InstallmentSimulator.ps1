#Requires -Version 7.0
<#
.SYNOPSIS
    クレジットカードの請求明細 CSV を読み、分割払いにしたときの毎月の請求額と手数料を試算する GUI。

.DESCRIPTION
    明細ごとに支払回数（1・2・3・5・6・10・12・15・18・20・24 回）を選ぶと、
    今月の請求額・手数料の合計・月別の請求額（表とグラフ）を変更前と並べて表示します。
    手数料は元利均等方式・実質年率（既定 15.00%）で計算する概算です。

    明細 CSV（Shift_JIS、Amazon Mastercard などの明細ダウンロード形式）は
    ..\..\data\installment-simulator\statements\ に yyyyMM.csv（例: 202611.csv）の名前で置きます。
    画面上部の「明細」リストで、どの月を試算するかを切り替えられます。
    設定（年率・ウィンドウサイズ・並べ替え・前回の明細）は ..\..\data\installment-simulator\settings.json に保存します。
    ネットワーク通信は行いません。

.PARAMETER CsvPath
    最初に開く明細 CSV。省略時は前回開いていた明細、それも無ければ明細フォルダの最新の月。
    明細フォルダの外のファイルも指定できます（リストに加わります）。

.PARAMETER DataDirectory
    設定と明細フォルダ（statements）の置き場所。既定はリポジトリの 1 階層上の data\installment-simulator。

.PARAMETER Detach
    別プロセスでウィンドウを開き、すぐにプロンプトへ戻る。

.EXAMPLE
    Start-InstallmentSimulator.ps1

.EXAMPLE
    Start-InstallmentSimulator.ps1 -CsvPath ..\..\data\installment-simulator\statements\202611.csv -Detach
#>
[CmdletBinding()]
param(
    [string]$CsvPath,
    [string]$DataDirectory,
    [switch]$Detach
)

$ErrorActionPreference = 'Stop'

if (-not $DataDirectory) { $DataDirectory = Join-Path $PSScriptRoot '..\..\data\installment-simulator' }
$DataDirectory = [System.IO.Path]::GetFullPath($DataDirectory)
$statementDirectory = Join-Path $DataDirectory 'statements'

if ($CsvPath) {
    $CsvPath = [System.IO.Path]::GetFullPath($CsvPath)
    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        Write-Error ('明細 CSV が見つかりません: {0}' -f $CsvPath)
        exit 1
    }
}
elseif (-not (Get-ChildItem -LiteralPath $statementDirectory -Filter '*.csv' -File -ErrorAction SilentlyContinue)) {
    Write-Error ('明細 CSV が {0} にありません。yyyyMM.csv（例: 202611.csv）の名前で置くか、-CsvPath で指定してください。' -f $statementDirectory)
    exit 1
}

function Get-ForwardArgument {
    $a = [System.Collections.Generic.List[string]]::new()
    $a.AddRange([string[]]@('-NoProfile', '-STA', '-File', $PSCommandPath, '-DataDirectory', $DataDirectory))
    if ($CsvPath) { $a.AddRange([string[]]@('-CsvPath', $CsvPath)) }
    return , $a.ToArray()
}

$pwshPath = [Environment]::ProcessPath

if ($Detach) {
    # Start-Process は引数を空白で連結するだけなので、空白を含むものは引用符で囲む
    $quoted = foreach ($x in Get-ForwardArgument) { if ($x -match '\s') { '"{0}"' -f $x } else { $x } }
    Start-Process -FilePath $pwshPath -ArgumentList $quoted -WindowStyle Hidden
    exit 0
}

# WinForms は STA が必要
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    & $pwshPath @(Get-ForwardArgument)
    exit $LASTEXITCODE
}

$moduleDir = Join-Path $PSScriptRoot 'InstallmentSimulator'
$modules = 'Statement', 'Calculator', 'GUI'
try {
    foreach ($m in $modules) {
        Import-Module (Join-Path $moduleDir "$m.psm1") -Force -DisableNameChecking
    }
    $window = @{ DataDirectory = $DataDirectory; StatementDirectory = $statementDirectory }
    if ($CsvPath) { $window.Path = $CsvPath }
    Show-InstallmentSimulatorWindow @window
}
catch {
    Write-Host ('分割払いシミュレーターでエラーが発生しました: {0}' -f $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    exit 1
}
finally {
    foreach ($m in $modules) { Remove-Module $m -Force -ErrorAction SilentlyContinue }
}
