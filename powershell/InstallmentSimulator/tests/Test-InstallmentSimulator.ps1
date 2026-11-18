#Requires -Version 7.0
<#
.SYNOPSIS
    分割払いシミュレーターの単体テスト（外部モジュール不要の簡易ランナー）。

.DESCRIPTION
    明細 CSV の読み込み・手数料計算・月別スケジュール・設定ファイルを検証します。
    テスト用の明細（架空のデータ, Shift_JIS）を一時ディレクトリに書き、終了時に削除します。

    -Gui を付けると、GUI モジュールのフォームを「表示せずに」組み立て、
    回数変更・再計算・グラフ描画を呼び出すスモークテストも行います（ウィンドウやダイアログは出ません）。

.EXAMPLE
    pwsh -NoProfile -STA -File .\powershell\InstallmentSimulator\tests\Test-InstallmentSimulator.ps1 -Gui
#>
[CmdletBinding()]
param([switch]$Gui)

$ErrorActionPreference = 'Stop'
$moduleDir = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleDir 'Statement.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $moduleDir 'Calculator.psm1') -Force -DisableNameChecking

$script:passed = 0
$script:failed = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:passed++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    }
    catch {
        $script:failed++
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host ("         {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host ("         {0}" -f ($_.InvocationInfo.PositionMessage -split "`n")[0]) -ForegroundColor DarkGray
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ($Expected -is [string] -or $Actual -is [string]) {
        if ([string]$Expected -cne [string]$Actual) {
            throw ("期待値 <{0}> / 実際 <{1}> {2}" -f $Expected, $Actual, $Because)
        }
    }
    elseif ($Expected -ne $Actual) {
        throw ("期待値 <{0}> / 実際 <{1}> {2}" -f $Expected, $Actual, $Because)
    }
}

function Assert-True {
    param($Condition, [string]$Because = '')
    if (-not $Condition) { throw ("条件が成り立ちません: {0}" -f $Because) }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('installment-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmp)
$sjis = [System.Text.Encoding]::GetEncoding('shift_jis')

# 架空の明細（実際の明細と同じ形式: 全角数字・返品・既存の 3 回払い・合計行）
$fixture = @(
    'テスト　太郎　様,1234-56**-****-****,テストカード'
    '2026/10/02,スーパーＡ,10000,１,１,10000,'
    '2026/10/05,書店Ｂ,34630,１,１,34630,'
    '2026/10/06,書店Ｂ,-2000,１,１,-2000,返品'
    '2026/09/17,家電Ｃ,30000,３,２,10251,'
    ',,,,,52881,'
    ''
)
# 明細フォルダ（statements）に 2 か月ぶん置く
$statementDir = Join-Path $tmp 'statements'
[void](New-Item -ItemType Directory -Path $statementDir)
$csv = Join-Path $statementDir '202611.csv'
[System.IO.File]::WriteAllLines($csv, [string[]]$fixture, $sjis)

# 翌月: 2 件（家電Ｃの 3 回払いは 3 回目で終わり）
$fixtureDec = @(
    'テスト　太郎　様,1234-56**-****-****,テストカード'
    '2026/11/03,スーパーＡ,8000,１,１,8000,'
    '2026/09/17,家電Ｃ,30000,３,３,10251,'
    ',,,,,18251,'
)
$csvDec = Join-Path $statementDir '202612.csv'
[System.IO.File]::WriteAllLines($csvDec, [string[]]$fixtureDec, $sjis)
Set-Content -LiteralPath (Join-Path $statementDir 'readme.txt') -Value 'CSV 以外は無視する'

$bad = Join-Path $tmp 'bad.csv'   # 明細フォルダの外
[System.IO.File]::WriteAllLines($bad, [string[]]($fixture[0..4] + ',,,,,99999,'), $sjis)

try {
    Write-Host '明細の読み込み'
    $st = Import-CardStatement -Path $csv

    Test-Case '明細 4 件と合計が一致し、警告がない' {
        Assert-Equal 4 $st.Items.Count
        Assert-Equal 52881 $st.ComputedTotal
        Assert-Equal 52881 $st.StatedTotal
        Assert-Equal 0 @($st.Warnings).Count
    }
    Test-Case '請求月をファイル名から取る' {
        Assert-Equal ([datetime]'2026-11-01') $st.BillingMonth
    }
    Test-Case 'カード名・番号を読み、氏名は保持しない' {
        Assert-Equal 'テストカード' $st.CardName
        Assert-Equal '1234-56**-****-****' $st.CardNumber
        $all = ($st | ConvertTo-Json -Depth 4)
        Assert-True (-not $all.Contains('太郎')) '氏名が結果に含まれている'
    }
    Test-Case '全角を半角に揃える' {
        Assert-Equal 'スーパーA' $st.Items[0].Merchant
        Assert-Equal 3 $st.Items[3].Count
        Assert-Equal 2 $st.Items[3].Current
    }
    Test-Case '種別の判定（変更可 / 返品 / 既存分割）' {
        Assert-Equal 'Changeable' $st.Items[0].Kind
        Assert-Equal 'Changeable' $st.Items[1].Kind
        Assert-Equal 'Refund' $st.Items[2].Kind
        Assert-Equal 'Existing' $st.Items[3].Kind
        Assert-Equal 1 $st.Items[3].Remaining
    }
    Test-Case '合計が合わないと警告する' {
        $b = Import-CardStatement -Path $bad
        Assert-Equal 1 @($b.Warnings).Count
        Assert-True ($b.Warnings[0] -match '一致しません') $b.Warnings[0]
    }
    Test-Case 'ファイル名に年月がなければ -BillingMonth を使う' {
        $b = Import-CardStatement -Path $bad -BillingMonth ([datetime]'2027-01-01')
        Assert-Equal ([datetime]'2027-01-01') $b.BillingMonth
    }

    Write-Host '手数料'
    Test-Case '100 円あたり手数料（年率 15%）がカード会社の表と一致する' {
        # 文字列で書く（double を経由すると 10.2899999… になる）
        $expected = @{ 3 = '2.51'; 5 = '3.78'; 6 = '4.42'; 10 = '7.00'; 12 = '8.31'; 15 = '10.29'; 18 = '12.29'; 20 = '13.64'; 24 = '16.37' }
        foreach ($n in $expected.Keys) {
            $want = [decimal]::Parse($expected[$n], [cultureinfo]::InvariantCulture)
            Assert-Equal $want (Get-InstallmentFeeRate -Count $n -AnnualRate 15) "($n 回)"
        }
    }
    Test-Case '1・2 回払いと年率 0% は手数料なし' {
        Assert-Equal ([decimal]0) (Get-InstallmentFeeRate -Count 1 -AnnualRate 15)
        Assert-Equal ([decimal]0) (Get-InstallmentFeeRate -Count 2 -AnnualRate 15)
        Assert-Equal ([decimal]0) (Get-InstallmentFeeRate -Count 12 -AnnualRate 0)
    }
    Test-Case '6 回払い: 手数料は切り捨て、端数は初回' {
        $p = Get-InstallmentPayment -Amount 34630 -Count 6 -AnnualRate 15
        Assert-Equal 1530 $p.Fee
        Assert-Equal 36160 $p.Total
        Assert-Equal 6030 $p.Payments[0]
        Assert-Equal 6026 $p.Payments[5]
        Assert-Equal 36160 ($p.Payments | Measure-Object -Sum).Sum
        Assert-Equal 1530 ($p.FeeParts | Measure-Object -Sum).Sum
    }
    Test-Case '2 回払い: 奇数円の端数は初回' {
        $p = Get-InstallmentPayment -Amount 10001 -Count 2 -AnnualRate 15
        Assert-Equal 0 $p.Fee
        Assert-Equal 5001 $p.Payments[0]
        Assert-Equal 5000 $p.Payments[1]
    }
    Test-Case '回数 0 はエラー' {
        $threw = $false
        try { [void](Get-InstallmentPayment -Amount 100 -Count 0 -AnnualRate 15) } catch { $threw = $true }
        Assert-True $threw
    }

    Write-Host '月別スケジュール'
    Test-Case 'すべて 1 回なら明細どおり（今月 + 既存分割の残り）' {
        $r = Get-PaymentSchedule -Statement $st -AnnualRate 15
        Assert-Equal 2 $r.Months.Count
        Assert-Equal 52881 $r.ThisMonthBefore
        Assert-Equal 52881 $r.ThisMonthAfter
        Assert-Equal 10251 $r.Months[1].Before
        Assert-Equal 10251 $r.Months[1].After
        Assert-Equal 0 $r.TotalFee
        Assert-Equal $r.TotalBefore $r.TotalAfter
    }
    Test-Case '1 件を 6 回払いにすると今月が減り、手数料ぶん総額が増える' {
        $r = Get-PaymentSchedule -Statement $st -Counts @{ 1 = 6 } -AnnualRate 15
        Assert-Equal 6 $r.Months.Count
        Assert-Equal (10000 + 6030 - 2000 + 10251) $r.ThisMonthAfter
        Assert-Equal (10251 + 6026) $r.Months[1].After
        Assert-Equal 6026 $r.Months[5].After
        Assert-Equal 1530 $r.TotalFee
        Assert-Equal 1530 ($r.TotalAfter - $r.TotalBefore)
        Assert-Equal ([datetime]'2027-04-01') $r.LastMonthAfter
        Assert-Equal ([datetime]'2026-12-01') $r.LastMonthBefore
    }
    Test-Case '返品・既存分割の回数指定は無視する' {
        $r = Get-PaymentSchedule -Statement $st -Counts @{ 2 = 6; 3 = 12 } -AnnualRate 15
        Assert-Equal 52881 $r.ThisMonthAfter
        Assert-Equal 2 $r.Months.Count
    }
    Test-Case '明細ごとの結果（手数料・今月分）' {
        $r = Get-PaymentSchedule -Statement $st -Counts @{ 1 = 3 } -AnnualRate 15
        $i1 = $r.Items | Where-Object Id -EQ 1
        Assert-Equal ([long][math]::Floor(34630 * 2.51 / 100)) $i1.Fee
        Assert-Equal 3 $i1.Count
        $i3 = $r.Items | Where-Object Id -EQ 3
        Assert-Equal (10251 * 2) $i3.Total
    }

    Write-Host '明細フォルダ'
    Test-Case '明細 CSV を請求月の新しい順に列挙する（CSV 以外は無視）' {
        $files = @(Get-StatementFile -Directory $statementDir)
        Assert-Equal 2 $files.Count
        Assert-Equal '202612.csv' $files[0].Name
        Assert-Equal '202611.csv' $files[1].Name
        Assert-Equal '2026年11月 請求（202611.csv）' $files[1].Label
        Assert-Equal ([datetime]'2026-12-01') $files[0].BillingMonth
    }
    Test-Case '年月のないファイル名は後ろ・フォルダがなければ空' {
        $files = @(Get-StatementFile -Path $bad)
        Assert-Equal 'bad.csv' $files[0].Label
        Assert-True ($null -eq $files[0].BillingMonth)
        Assert-Equal 0 @(Get-StatementFile -Directory (Join-Path $tmp 'none')).Count
    }

    # 実際の明細（あれば）: 明細フォルダの CSV がすべて読めて合計が一致すること
    $realDir = [System.IO.Path]::GetFullPath((Join-Path $moduleDir '..\..\..\data\installment-simulator\statements'))
    foreach ($real in @(Get-StatementFile -Directory $realDir)) {
        Test-Case ('実際の明細 {0} を読める（合計一致）' -f $real.Name) {
            $s = Import-CardStatement -Path $real.Path
            Assert-Equal 0 @($s.Warnings).Count ($s.Warnings -join ' / ')
            $r = Get-PaymentSchedule -Statement $s -AnnualRate 15
            Assert-Equal $s.ComputedTotal $r.ThisMonthBefore
        }
    }

    if ($Gui) {
        Import-Module (Join-Path $moduleDir 'GUI.psm1') -Force -DisableNameChecking
        Set-InstallmentSimulatorTestMode $true
        $dataDir = Join-Path $tmp 'settings'

        Write-Host '設定ファイル'
        Test-Case '設定が無ければ既定値（年率 15%）' {
            $s = Read-SimulatorSettings -DataDirectory $dataDir
            Assert-Equal 15.0 $s.annualRate
            Assert-True ($s.counts -contains 1)
        }
        Test-Case '保存して読み直せる・不正な値は無視する' {
            $s = Read-SimulatorSettings -DataDirectory $dataDir
            $s.annualRate = 12.5
            Save-SimulatorSettings -DataDirectory $dataDir -Settings $s
            Assert-Equal 12.5 (Read-SimulatorSettings -DataDirectory $dataDir).annualRate
            '{"annualRate": 99, "counts": [0, 4, 4, 7], "windowWidth": 10}' |
                Set-Content -LiteralPath (Join-Path $dataDir 'settings.json') -Encoding utf8
            $s2 = Read-SimulatorSettings -DataDirectory $dataDir
            Assert-Equal 15.0 $s2.annualRate
            Assert-Equal '1,4,7' ($s2.counts -join ',')
            Assert-True ($s2.windowWidth -ge 600)
            Remove-Item -LiteralPath (Join-Path $dataDir 'settings.json')
        }
        Test-Case '並べ替えの設定を保存できる・不明なキーは無視する' {
            Assert-Equal 'Id' (Read-SimulatorSettings -DataDirectory $dataDir).sortKey
            '{"sortKey": "Amount", "sortDescending": true}' |
                Set-Content -LiteralPath (Join-Path $dataDir 'settings.json') -Encoding utf8
            $s = Read-SimulatorSettings -DataDirectory $dataDir
            Assert-Equal 'Amount' $s.sortKey
            Assert-Equal $true $s.sortDescending
            '{"sortKey": "Bogus", "sortDescending": true}' |
                Set-Content -LiteralPath (Join-Path $dataDir 'settings.json') -Encoding utf8
            $s = Read-SimulatorSettings -DataDirectory $dataDir
            Assert-Equal 'Id' $s.sortKey
            Assert-Equal $false $s.sortDescending
            Remove-Item -LiteralPath (Join-Path $dataDir 'settings.json')
        }
        Test-Case '前回の明細はファイル名だけ受け付ける' {
            '{"lastStatement": "202611.csv"}' | Set-Content -LiteralPath (Join-Path $dataDir 'settings.json') -Encoding utf8
            Assert-Equal '202611.csv' (Read-SimulatorSettings -DataDirectory $dataDir).lastStatement
            '{"lastStatement": "..\\..\\secret.csv"}' | Set-Content -LiteralPath (Join-Path $dataDir 'settings.json') -Encoding utf8
            Assert-Equal '' (Read-SimulatorSettings -DataDirectory $dataDir).lastStatement
            Remove-Item -LiteralPath (Join-Path $dataDir 'settings.json')
        }

        Write-Host 'GUI（表示しない）'
        $form = $null
        try {
            $form = New-InstallmentSimulatorForm -DataDirectory $dataDir -StatementDirectory $statementDir -Path $csv
            $ui = Get-InstallmentSimulatorState
            $C = $ui.Controls

            Test-Case 'フォームを組み立てられる・明細 4 行' {
                Assert-True (-not $form.Visible) 'ウィンドウは表示しない'
                Assert-Equal 4 $C.Grid.Rows.Count
                Assert-True ($C.Summary.ThisMonth.Text -match '52,881 → 52,881 円') $C.Summary.ThisMonth.Text
                Assert-Equal 3 $C.Schedule.Rows.Count '2 か月 + 合計行'
            }
            Test-Case '初期サイズが作業領域に収まる' {
                $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
                Assert-True ($form.Width -le $wa.Width -and $form.Height -le $wa.Height) ('{0}x{1} / {2}x{3}' -f $form.Width, $form.Height, $wa.Width, $wa.Height)
                Assert-True ($form.Width -ge $form.MinimumSize.Width -and $form.Height -ge $form.MinimumSize.Height) '最小サイズ以上'
            }
            Test-Case '返品・既存分割の行は回数を変えられない' {
                Assert-True $C.Grid.Rows[2].Cells['Count'].ReadOnly
                Assert-True $C.Grid.Rows[3].Cells['Count'].ReadOnly
                Assert-True (-not $C.Grid.Rows[1].Cells['Count'].ReadOnly)
            }
            Test-Case 'セルの回数を変えるとすぐ再計算する' {
                $C.Grid.Rows[1].Cells['Count'].Value = 6
                Assert-True ($C.Summary.ThisMonth.Text -match '→ 24,281 円') $C.Summary.ThisMonth.Text
                Assert-Equal '1,530 円' $C.Summary.Fee.Text
                Assert-Equal 1530 $C.Grid.Rows[1].Cells['Fee'].Value
                Assert-Equal 6030 $C.Grid.Rows[1].Cells['ThisMonth'].Value
                Assert-Equal 7 $C.Schedule.Rows.Count '6 か月 + 合計行'
            }
            Test-Case '年率を変えると再計算する' {
                $C.Rate.Value = 0
                Assert-Equal '0 円' $C.Summary.Fee.Text
                $C.Rate.Value = 15
                Assert-Equal '1,530 円' $C.Summary.Fee.Text
            }
            Test-Case 'まとめて変更・リセット' {
                Set-RowCount -Count 3
                Assert-Equal 3 $C.Grid.Rows[0].Cells['Count'].Value
                Assert-Equal 3 $C.Grid.Rows[1].Cells['Count'].Value
                Assert-Equal '2 件 / 44,630 円' $C.Summary.Changed.Text
                Set-RowCount -Count 1
                Assert-True ($C.Summary.ThisMonth.Text -match '52,881 → 52,881 円') $C.Summary.ThisMonth.Text
                Assert-Equal '0 件 / 0 円' $C.Summary.Changed.Text
            }

            # 明細の並び（Id）: 0=10/02 10,000 / 1=10/05 34,630 / 2=10/06 -2,000（返品）/ 3=09/17 30,000（既存分割）
            function Get-RowOrder { (@($C.Grid.Rows) | ForEach-Object { $_.Tag.Id }) -join ',' }
            function Get-RowById([int]$Id) { @($C.Grid.Rows) | Where-Object { $_.Tag.Id -eq $Id } }

            Test-Case '並べ替え: 金額の大きい順 / 小さい順' {
                Set-ItemSort -Key Amount -Descending $true
                Assert-Equal '1,3,0,2' (Get-RowOrder)
                Assert-Equal 'Descending' ([string]$C.Grid.Columns['Amount'].HeaderCell.SortGlyphDirection)
                Assert-Equal '金額の大きい順' $C.Sort.SelectedItem
                Set-ItemSort -Key Amount -Descending $false
                Assert-Equal '2,0,3,1' (Get-RowOrder)
                Assert-Equal '金額の小さい順' $C.Sort.SelectedItem
            }
            Test-Case '並べ替え: 列見出しのクリックで日付の新しい順 → 古い順' {
                Invoke-HeaderSort -ColumnName Date
                Assert-Equal '2,1,0,3' (Get-RowOrder)
                Assert-Equal '日付の新しい順' $C.Sort.SelectedItem
                Assert-Equal 'None' ([string]$C.Grid.Columns['Amount'].HeaderCell.SortGlyphDirection)
                Invoke-HeaderSort -ColumnName Date
                Assert-Equal '3,0,1,2' (Get-RowOrder)
                Assert-Equal 'Ascending' ([string]$C.Grid.Columns['Date'].HeaderCell.SortGlyphDirection)
            }
            Test-Case '並べ替え: 値のない行（固定行の手数料）は常に末尾' {
                (Get-RowById 1).Cells['Count'].Value = 6
                (Get-RowById 0).Cells['Count'].Value = 3
                Invoke-HeaderSort -ColumnName Fee
                Assert-Equal '1,0,2,3' (Get-RowOrder)
                Invoke-HeaderSort -ColumnName Fee
                Assert-Equal '0,1,2,3' (Get-RowOrder)
                Assert-Equal -1 $C.Sort.SelectedIndex '選択肢にない並べ替えは空欄'
            }
            Test-Case '並べ替えても行の状態と再計算は保たれる' {
                Set-ItemSort -Key Amount -Descending $true
                Assert-True (Get-RowById 3).Cells['Count'].ReadOnly '既存分割の行は変更不可のまま'
                Assert-True (Get-RowById 2).Cells['Count'].ReadOnly '返品の行は変更不可のまま'
                Assert-Equal 6 (Get-RowById 1).Cells['Count'].Value
                Assert-Equal ('{0:N0} 円' -f (1530 + 251)) $C.Summary.Fee.Text
                (Get-RowById 0).Cells['Count'].Value = 1
                Assert-Equal '1,530 円' $C.Summary.Fee.Text
                Assert-Equal '1,3,0,2' (Get-RowOrder) '回数を変えても自動では並べ直さない'
            }
            Test-Case '並べ替え: リストで選ぶと並べ替わる（明細の順に戻す）' {
                $C.Sort.SelectedIndex = 0
                Assert-Equal '0,1,2,3' (Get-RowOrder)
                Assert-Equal 'None' ([string]$C.Grid.Columns['Amount'].HeaderCell.SortGlyphDirection)
                Set-RowCount -Count 1
            }

            function Get-MarkedIds { (@($C.Grid.Rows) | Where-Object { $_.Cells['Mark'].Value -eq '✓' } | ForEach-Object { $_.Tag.Id } | Sort-Object) -join ',' }
            function Select-GridRows([int[]]$Ids) {
                $C.Grid.ClearSelection()
                foreach ($id in $Ids) { (Get-RowById $id).Cells['Merchant'].Selected = $true }
            }

            Test-Case '選択中: ダブルクリックで付け外しできる' {
                Assert-Equal '選択中 0 件' $C.MarkStatus.Text
                Assert-True (-not $C.ClearMarks.Enabled) '0 件のときは解除ボタンを無効'
                Invoke-ItemDoubleClick -RowIndex (Get-RowById 1).Index -ColumnName 'Merchant'
                Assert-Equal '1' (Get-MarkedIds)
                Assert-Equal '選択中 1 件' $C.MarkStatus.Text
                Assert-True $C.ClearMarks.Enabled
                Invoke-ItemDoubleClick -RowIndex (Get-RowById 1).Index -ColumnName 'Date'
                Assert-Equal '' (Get-MarkedIds) 'もう一度で解除'
            }
            Test-Case '選択中: 支払回数の列・変更できない行・見出しのダブルクリックでは付かない' {
                Invoke-ItemDoubleClick -RowIndex (Get-RowById 0).Index -ColumnName 'Count'
                Invoke-ItemDoubleClick -RowIndex (Get-RowById 2).Index -ColumnName 'Merchant'
                Invoke-ItemDoubleClick -RowIndex (Get-RowById 3).Index -ColumnName 'Merchant'
                Invoke-ItemDoubleClick -RowIndex -1 -ColumnName 'Merchant'
                Assert-Equal '' (Get-MarkedIds)
            }
            Test-Case '選択中: ほかの行をクリック（ハイライト変更）しても消えない・並べ替えても残る' {
                Invoke-ItemDoubleClick -RowIndex (Get-RowById 0).Index -ColumnName 'Merchant'
                Select-GridRows 3
                $C.Grid.CurrentCell = (Get-RowById 3).Cells['Amount']
                Assert-Equal '0' (Get-MarkedIds)
                Set-ItemSort -Key Amount -Descending $true
                Assert-Equal '0' (Get-MarkedIds)
            }
            Test-Case '選択中: Space で範囲（ハイライト中の行）を選択中にする・変更できない行は飛ばす' {
                Clear-RowMark
                Select-GridRows 0, 1, 2, 3
                Invoke-MarkSelection
                Assert-Equal '0,1' (Get-MarkedIds)
                Assert-Equal '選択中 2 件' $C.MarkStatus.Text
                Select-GridRows 1
                Invoke-MarkSelection
                Assert-Equal '0,1' (Get-MarkedIds) 'すでに選択中の行は外さない'
            }
            Test-Case '選択中に適用: 離れた選択中の行だけに適用し、ハイライト中の行は無視する' {
                Clear-RowMark
                # 金額の大きい順では Id 1 と Id 0 は離れている（1,3,0,2）
                Assert-Equal '1,3,0,2' (Get-RowOrder)
                Invoke-ItemDoubleClick -RowIndex (Get-RowById 1).Index -ColumnName 'Merchant'
                Invoke-ItemDoubleClick -RowIndex (Get-RowById 0).Index -ColumnName 'Merchant'
                Select-GridRows 3
                $targets = @(Get-TargetGridRow | ForEach-Object { $_.Tag.Id } | Sort-Object) -join ','
                Assert-Equal '0,1' $targets '対象は選択中の行だけ（ハイライト中の行は含めない）'
                Set-TargetRowCount -Count 6
                Assert-Equal 6 (Get-RowById 0).Cells['Count'].Value
                Assert-Equal 6 (Get-RowById 1).Cells['Count'].Value
                Assert-Equal '2 件 / 44,630 円' $C.Summary.Changed.Text
            }
            Test-Case '選択中に適用: 選択中がなければハイライト中の行に適用する' {
                Clear-RowMark
                Set-RowCount -Count 1
                Select-GridRows 1
                Set-TargetRowCount -Count 3
                Assert-Equal 3 (Get-RowById 1).Cells['Count'].Value
                Assert-Equal 1 (Get-RowById 0).Cells['Count'].Value
            }
            Test-Case '選択中: グリッドのイベント（ダブルクリック / Space キー）から呼ばれる' {
                Clear-RowMark
                $flags = [System.Reflection.BindingFlags]'Instance, NonPublic'
                $type = [System.Windows.Forms.DataGridView]
                $row0 = Get-RowById 0
                $dbl = [System.Windows.Forms.DataGridViewCellEventArgs]::new($C.Grid.Columns['Merchant'].Index, $row0.Index)
                [void]$type.GetMethod('OnCellDoubleClick', $flags).Invoke($C.Grid, @($dbl))
                Assert-Equal '0' (Get-MarkedIds) 'ダブルクリックで選択中に'
                Select-GridRows 1, 3
                $key = [System.Windows.Forms.KeyEventArgs]::new([System.Windows.Forms.Keys]::Space)
                [void]$type.GetMethod('OnKeyDown', $flags, $null, [type[]]@([System.Windows.Forms.KeyEventArgs]), $null).Invoke($C.Grid, @($key))
                Assert-Equal '0,1' (Get-MarkedIds) 'Space で範囲を選択中に'
                Assert-True $key.SuppressKeyPress 'Space の既定動作（編集開始など）を止める'
            }
            Test-Case '選択中: 解除ボタンですべて外れ、行の色が戻る' {
                Add-RowMark -Rows @((Get-RowById 0), (Get-RowById 1))
                $marked = (Get-RowById 0).DefaultCellStyle.BackColor
                Clear-RowMark
                Assert-Equal '' (Get-MarkedIds)
                Assert-Equal '選択中 0 件' $C.MarkStatus.Text
                Assert-True ((Get-RowById 0).DefaultCellStyle.BackColor -ne $marked) '選択中の色が残っている'
                Assert-True ((Get-RowById 1).DefaultCellStyle.BackColor.ToArgb() -ne $marked.ToArgb()) '分割にした行は黄色に戻る'
                Set-RowCount -Count 1
                Set-ItemSort -Key Id
            }
            Test-Case 'グラフを描画できる（24 回払い）' {
                Set-RowCount -Count 24
                $C.Form.Size = [System.Drawing.Size]::new(1200, 800)
                $C.Form.PerformLayout()
                $w = [math]::Max(200, $C.Chart.Width); $h = [math]::Max(150, $C.Chart.Height)
                $bmp = [System.Drawing.Bitmap]::new($w, $h)
                try { $C.Chart.DrawToBitmap($bmp, [System.Drawing.Rectangle]::new(0, 0, $w, $h)) }
                finally { $bmp.Dispose() }
                Assert-Equal 25 $C.Schedule.Rows.Count
            }

            Write-Host '明細（月）の切り替え'
            Test-Case '明細リストに 2 か月が並び、開いている月が選ばれている' {
                Assert-Equal 2 $C.Month.Items.Count
                Assert-Equal '2026年11月 請求（202611.csv）' $C.Month.SelectedItem
                Assert-True ($C.Form.Text -match '202611\.csv') $C.Form.Text
                Assert-True ($C.Info.Text -match 'テストカード .*明細 4 件') $C.Info.Text
            }
            Test-Case '月を切り替えると、その月の明細で試算する' {
                Set-RowCount -Count 1
                (Get-RowById 1).Cells['Count'].Value = 6
                Clear-RowMark
                [void](Switch-RowMark -Row (Get-RowById 0))
                $C.Month.SelectedIndex = 0     # 2026年12月
                Assert-True ($C.Form.Text -match '202612\.csv') $C.Form.Text
                Assert-Equal 2 $C.Grid.Rows.Count
                Assert-True ($C.Summary.ThisMonth.Text -match '18,251 → 18,251 円') $C.Summary.ThisMonth.Text
                Assert-Equal '選択中 0 件' $C.MarkStatus.Text
                Assert-Equal 2 $C.Schedule.Rows.Count '既存分割は今回で終わり（1 か月 + 合計行）'
                (Get-RowById 0).Cells['Count'].Value = 3
                Assert-Equal ('{0:N0} 円' -f [math]::Floor(8000 * 2.51 / 100)) $C.Summary.Fee.Text
            }
            Test-Case '元の月に戻すと、回数と選択中（✓）が復元される' {
                $C.Month.SelectedIndex = 1     # 2026年11月
                Assert-Equal 4 $C.Grid.Rows.Count
                Assert-Equal 6 (Get-RowById 1).Cells['Count'].Value
                Assert-Equal 1 (Get-RowById 0).Cells['Count'].Value
                Assert-Equal '0' (Get-MarkedIds)
                Assert-Equal '1,530 円' $C.Summary.Fee.Text
                $C.Month.SelectedIndex = 0
                Assert-Equal 3 (Get-RowById 0).Cells['Count'].Value '12 月の回数も残る'
                $C.Month.SelectedIndex = 1
            }
            Test-Case '再読込: 追加した明細がリストに出る・いまの月と回数はそのまま' {
                $jan = Join-Path $statementDir '202701.csv'
                [System.IO.File]::WriteAllLines($jan, [string[]]$fixtureDec, $sjis)
                try {
                    Update-StatementList
                    Open-Statement -Path $script:csv
                    Assert-Equal 3 $C.Month.Items.Count
                    Assert-Equal '2027年1月 請求（202701.csv）' $C.Month.Items[0]
                    Assert-Equal '2026年11月 請求（202611.csv）' $C.Month.SelectedItem
                    Assert-Equal 6 (Get-RowById 1).Cells['Count'].Value
                }
                finally {
                    Remove-Item -LiteralPath $jan
                    Update-StatementList
                }
            }
            Test-Case '明細フォルダの外の明細も開け、警告を表示する' {
                Open-Statement -Path $bad
                Update-StatementList
                Assert-Equal 3 $C.Month.Items.Count
                Assert-Equal 'bad.csv' $C.Month.SelectedItem
                Assert-True ($C.Warning.Text -match '一致しません') $C.Warning.Text
                $C.Month.SelectedIndex = 1     # 2026年11月
                Assert-Equal '' $C.Warning.Text
            }
            Test-Case '開けない明細を選んでも、いまの月のまま' {
                $threw = $false
                try { Open-Statement -Path (Join-Path $statementDir 'missing.csv') } catch { $threw = $true }
                Assert-True $threw
                Assert-True ($C.Form.Text -match '202611\.csv') $C.Form.Text
                Assert-Equal 4 $C.Grid.Rows.Count
            }
        }
        finally {
            if ($form) { $form.Dispose() }
        }

        Test-Case '起動時の明細: 前回の明細 → なければ最新の月' {
            $f2 = $null
            try {
                '{"lastStatement": "202611.csv"}' | Set-Content -LiteralPath (Join-Path $dataDir 'settings.json') -Encoding utf8
                $f2 = New-InstallmentSimulatorForm -DataDirectory $dataDir -StatementDirectory $statementDir
                Assert-True ($f2.Text -match '202611\.csv') $f2.Text
                $f2.Dispose()
                Remove-Item -LiteralPath (Join-Path $dataDir 'settings.json')
                $f2 = New-InstallmentSimulatorForm -DataDirectory $dataDir -StatementDirectory $statementDir
                Assert-True ($f2.Text -match '202612\.csv') $f2.Text
            }
            finally { if ($f2) { $f2.Dispose() } }
        }
        Test-Case '明細フォルダが空ならエラー' {
            $threw = $false
            $empty = Join-Path $tmp 'empty'
            try { [void](New-InstallmentSimulatorForm -DataDirectory $dataDir -StatementDirectory $empty) }
            catch { $threw = $_.Exception.Message -match '見つかりません' }
            Assert-True $threw
        }
    }
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
$color = if ($script:failed -eq 0) { 'Green' } else { 'Red' }
Write-Host ("結果: {0} 件成功 / {1} 件失敗" -f $script:passed, $script:failed) -ForegroundColor $color
exit ([int]($script:failed -gt 0))
