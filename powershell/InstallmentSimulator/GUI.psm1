#Requires -Version 7.0
<#
.SYNOPSIS
    分割払いシミュレーターの WinForms GUI。

.DESCRIPTION
    Statement.psm1 / Calculator.psm1 を先に読み込んでから使います。
    状態はこのモジュールの $script:S（明細・設定・計算結果）と $script:C（コントロール）に持ちます。
    イベントハンドラーは必ず $script: 経由で状態を参照します。

    New-InstallmentSimulatorForm はフォームを組み立てるだけで表示しません（テストから呼べるようにするため）。
    $script:ThrowUiErrors を $true にすると、ダイアログを出さずに例外を投げます（テスト用）。
#>

Set-StrictMode -Version 3.0
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:S = $null
$script:C = $null
$script:ThrowUiErrors = $false

$script:Colors = @{
    Before    = [System.Drawing.Color]::FromArgb(150, 162, 180)   # 変更前（グレー青）
    After     = [System.Drawing.Color]::FromArgb(230, 120, 40)    # 変更後（橙）
    Changed   = [System.Drawing.Color]::FromArgb(255, 244, 214)   # 分割にした行
    Marked    = [System.Drawing.Color]::FromArgb(206, 228, 255)   # 選択中（✓）の行
    MarkFg    = [System.Drawing.Color]::FromArgb(0, 90, 190)
    FixedBg   = [System.Drawing.Color]::FromArgb(238, 238, 238)   # 変更できない行
    FixedFg   = [System.Drawing.Color]::FromArgb(110, 110, 110)
    Up        = [System.Drawing.Color]::FromArgb(190, 40, 40)     # 増える
    Down      = [System.Drawing.Color]::FromArgb(0, 120, 60)      # 減る
    Grid      = [System.Drawing.Color]::FromArgb(225, 225, 225)
    Axis      = [System.Drawing.Color]::FromArgb(120, 120, 120)
    Warning   = [System.Drawing.Color]::FromArgb(190, 40, 40)
}

$script:DefaultSettings = [ordered]@{
    annualRate   = 15.0
    counts       = @(1, 2, 3, 5, 6, 10, 12, 15, 18, 20, 24)
    windowWidth  = 1000
    windowHeight = 720
    sortKey        = 'Id'      # 明細の並べ替え（Id = CSV の順）
    sortDescending = $false
    lastStatement  = ''        # 前回開いていた明細のファイル名（明細フォルダの中のもの）
}

# 並べ替えに使えるキー（明細グリッドの列名と同じ。Id は CSV の順）
$script:SortKeys = 'Id', 'Mark', 'Date', 'Merchant', 'Amount', 'Kind', 'Count', 'Rate', 'Fee', 'ThisMonth', 'Total'

# 列見出しを初めてクリックしたときに降順にする列（数値・日付は大きい方 / 新しい方から見たいことが多い）
$script:DescendingFirst = 'Date', 'Amount', 'Count', 'Rate', 'Fee', 'ThisMonth', 'Total'

# 「並べ替え」リストの選択肢
$script:SortPresets = @(
    @{ Label = '明細の順（CSV のまま）'; Key = 'Id'; Descending = $false }
    @{ Label = '日付の新しい順'; Key = 'Date'; Descending = $true }
    @{ Label = '日付の古い順'; Key = 'Date'; Descending = $false }
    @{ Label = '金額の大きい順'; Key = 'Amount'; Descending = $true }
    @{ Label = '金額の小さい順'; Key = 'Amount'; Descending = $false }
    @{ Label = '手数料の大きい順'; Key = 'Fee'; Descending = $true }
    @{ Label = '今月の請求分の大きい順'; Key = 'ThisMonth'; Descending = $true }
    @{ Label = '利用先の名前順'; Key = 'Merchant'; Descending = $false }
    @{ Label = '区分順（変更できる明細が先）'; Key = 'Kind'; Descending = $false }
    @{ Label = '選択中（✓）の行が先'; Key = 'Mark'; Descending = $false }
)

#region 設定

function Read-SimulatorSettings {
    <#
    .SYNOPSIS
        settings.json を読み、既定値で欠けている項目を補って返す（ファイルが無ければ既定値）。
    #>
    param([Parameter(Mandatory)][string]$DataDirectory)
    $s = [ordered]@{}
    foreach ($k in $script:DefaultSettings.Keys) { $s[$k] = $script:DefaultSettings[$k] }

    $path = Join-Path $DataDirectory 'settings.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $j = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
            if ($j.ContainsKey('annualRate')) {
                $r = [double]$j.annualRate
                if ($r -ge 0 -and $r -le 30) { $s.annualRate = $r }
            }
            if ($j.ContainsKey('counts')) {
                $c = @($j.counts | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 1 -and $_ -le 99 })
                $c = @(@(1) + $c | Sort-Object -Unique)
                if ($c.Count -ge 2) { $s.counts = $c }
            }
            foreach ($k in 'windowWidth', 'windowHeight') {
                if ($j.ContainsKey($k) -and [int]$j[$k] -ge 600) { $s[$k] = [int]$j[$k] }
            }
            if ($j.ContainsKey('sortKey') -and $script:SortKeys -ccontains [string]$j.sortKey) {
                $s.sortKey = [string]$j.sortKey
                $s.sortDescending = [bool]$j['sortDescending']
            }
            # ファイル名だけを受け付ける（パス区切りや .. を含むものは無視）
            if ($j.ContainsKey('lastStatement') -and [string]$j.lastStatement -match '^[^\\/:*?"<>|]+\.csv$') {
                $s.lastStatement = [string]$j.lastStatement
            }
        }
        catch {
            Write-Warning ('設定ファイルを読めなかったので既定値を使います: {0}' -f $_.Exception.Message)
        }
    }
    return $s
}

function Save-SimulatorSettings {
    param(
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings
    )
    if (-not (Test-Path -LiteralPath $DataDirectory)) {
        [void](New-Item -ItemType Directory -Path $DataDirectory -Force)
    }
    $path = Join-Path $DataDirectory 'settings.json'
    $Settings | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $path -Encoding utf8
}

#endregion

#region 共通

function Invoke-UiSafe {
    param([Parameter(Mandatory)][scriptblock]$Action)
    try { & $Action }
    catch {
        if ($script:ThrowUiErrors) { throw }
        $msg = "処理中にエラーが発生しました。`n`n{0}`n`n{1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage
        $owner = if ($script:C) { $script:C.Form } else { $null }
        [void][System.Windows.Forms.MessageBox]::Show($owner, $msg, '分割払いシミュレーター', 'OK', 'Error')
    }
}

function Get-Scaled {
    param([double]$Pixel)
    return [int][math]::Round($Pixel * $script:S.Scale)
}

function Format-Yen {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    return ('{0:N0} 円' -f $Value)
}

function Format-SignedYen {
    param([long]$Value)
    if ($Value -eq 0) { return '±0 円' }
    return ('{0:+#,0;-#,0} 円' -f $Value)
}

function New-Label {
    param([string]$Text, [switch]$Bold, [switch]$Right)
    $l = [System.Windows.Forms.Label]::new()
    $l.Text = $Text
    $l.AutoSize = $true
    $l.Margin = [System.Windows.Forms.Padding]::new((Get-Scaled 3), (Get-Scaled 7), (Get-Scaled 3), (Get-Scaled 3))
    if ($Bold) { $l.Font = [System.Drawing.Font]::new($script:S.UiFont, [System.Drawing.FontStyle]::Bold) }
    if ($Right) { $l.Anchor = [System.Windows.Forms.AnchorStyles]::Right }
    return $l
}

function New-Button {
    param([string]$Text, [scriptblock]$OnClick)
    $b = [System.Windows.Forms.Button]::new()
    $b.Text = $Text
    $b.AutoSize = $true
    $b.Padding = [System.Windows.Forms.Padding]::new((Get-Scaled 6), 0, (Get-Scaled 6), 0)
    $b.Margin = [System.Windows.Forms.Padding]::new((Get-Scaled 3))
    if ($OnClick) {
        # GetNewClosure() はモジュールのスコープを失うので使わず、Tag に処理を持たせる
        $b.Tag = $OnClick
        $b.add_Click({ param($sender, $e) Invoke-UiSafe $sender.Tag })
    }
    return $b
}

function Set-DoubleBuffered {
    param([System.Windows.Forms.Control]$Control)
    $flags = [System.Reflection.BindingFlags]'Instance, NonPublic'
    $Control.GetType().GetProperty('DoubleBuffered', $flags).SetValue($Control, $true)
}

function Get-CountLabel {
    param([int]$Count)
    if ($Count -eq 1) { return '1回 (一括)' }
    if ($Count -eq 2) { return '2回 (手数料なし)' }
    return ('{0}回' -f $Count)
}

#endregion

#region 計算と表示の更新

function Get-SelectedCounts {
    <#
    .SYNOPSIS
        明細グリッドで選ばれている支払回数を Id -> 回数 のハッシュテーブルで返す。
    #>
    $counts = @{}
    foreach ($row in $script:C.Grid.Rows) {
        $item = $row.Tag
        if ($item.Kind -ne 'Changeable') { continue }
        $v = $row.Cells['Count'].Value
        $counts[$item.Id] = if ($null -eq $v -or $v -is [System.DBNull]) { 1 } else { [int]$v }
    }
    return $counts
}

function Update-Simulation {
    $S = $script:S
    $C = $script:C
    $rate = [double]$C.Rate.Value
    $counts = Get-SelectedCounts
    $result = Get-PaymentSchedule -Statement $S.Statement -Counts $counts -AnnualRate $rate
    $S.Result = $result

    $byId = @{}
    foreach ($r in $result.Items) { $byId[$r.Id] = $r }

    $S.Updating = $true
    try {
        # 明細ごとの手数料・今月分
        $changedCount = 0; $changedAmount = [long]0
        foreach ($row in $C.Grid.Rows) {
            $item = $row.Tag
            $r = $byId[$item.Id]
            $row.Cells['Rate'].Value = if ($null -ne $r.Rate -and $r.Count -gt 2) { $r.Rate } else { $null }
            $row.Cells['Fee'].Value = $r.Fee
            $row.Cells['ThisMonth'].Value = $r.ThisMonth
            $row.Cells['Total'].Value = $r.Total
            if ($item.Kind -eq 'Changeable') {
                if ($r.Count -gt 1) { $changedCount++; $changedAmount += $item.Amount }
                Update-RowStyle -Row $row
            }
        }

        # 月別表
        $sg = $C.Schedule
        $sg.SuspendLayout()
        $sg.Rows.Clear()
        foreach ($m in $result.Months) {
            $i = $sg.Rows.Add($m.Month.ToString('yyyy/MM'), $m.Before, $m.After, $m.Diff, $m.Fee)
            $cell = $sg.Rows[$i].Cells['Diff']
            $cell.Style.ForeColor = if ($m.Diff -gt 0) { $script:Colors.Up } elseif ($m.Diff -lt 0) { $script:Colors.Down } else { [System.Drawing.Color]::Empty }
            if ($m.Index -eq 0) { $sg.Rows[$i].DefaultCellStyle.Font = $S.BoldFont }
        }
        $totalDiff = $result.TotalAfter - $result.TotalBefore
        $i = $sg.Rows.Add('合計', $result.TotalBefore, $result.TotalAfter, $totalDiff, $result.TotalFee)
        $sg.Rows[$i].DefaultCellStyle.Font = $S.BoldFont
        $sg.Rows[$i].DefaultCellStyle.BackColor = $script:Colors.FixedBg
        $sg.ClearSelection()
        $sg.ResumeLayout()
    }
    finally {
        $S.Updating = $false
    }

    # サマリー
    $L = $C.Summary
    $diff = $result.ThisMonthAfter - $result.ThisMonthBefore
    $L.ThisMonth.Text = '{0:N0} → {1:N0} 円' -f $result.ThisMonthBefore, $result.ThisMonthAfter
    $L.ThisMonthDiff.Text = Format-SignedYen $diff
    $L.ThisMonthDiff.ForeColor = if ($diff -gt 0) { $script:Colors.Up } elseif ($diff -lt 0) { $script:Colors.Down } else { [System.Drawing.SystemColors]::ControlText }
    $L.Fee.Text = Format-Yen $result.TotalFee
    $L.Fee.ForeColor = if ($result.TotalFee -gt 0) { $script:Colors.Up } else { [System.Drawing.SystemColors]::ControlText }
    $L.Total.Text = '{0:N0} → {1:N0} 円' -f $result.TotalBefore, $result.TotalAfter
    $L.Max.Text = '{0:N0} → {1:N0} 円' -f $result.MaxBefore, $result.MaxAfter
    $L.Last.Text = '{0} → {1}' -f $result.LastMonthBefore.ToString('yyyy/MM'), $result.LastMonthAfter.ToString('yyyy/MM')
    $L.Changed.Text = '{0} 件 / {1:N0} 円' -f $changedCount, $changedAmount

    $C.Chart.Invalidate()
}

function Set-RowCount {
    <#
    .SYNOPSIS
        指定した行（省略時は変更できる全行）の支払回数をまとめて変える。
    #>
    param(
        [Parameter(Mandatory)][int]$Count,
        [System.Windows.Forms.DataGridViewRow[]]$Rows
    )
    if (-not $Rows) { $Rows = @($script:C.Grid.Rows) }
    [void]$script:C.Grid.EndEdit()
    $script:S.Updating = $true
    try {
        foreach ($row in $Rows) {
            if ($row.Tag.Kind -eq 'Changeable') { $row.Cells['Count'].Value = $Count }
        }
    }
    finally { $script:S.Updating = $false }
    Update-Simulation
}

function Get-SelectedGridRow {
    # いまハイライトされている（マウス・Ctrl / Shift で選んだ）セルの行
    $set = [System.Collections.Generic.HashSet[int]]::new()
    $rows = [System.Collections.Generic.List[System.Windows.Forms.DataGridViewRow]]::new()
    foreach ($cell in $script:C.Grid.SelectedCells) {
        if ($set.Add($cell.RowIndex)) { $rows.Add($script:C.Grid.Rows[$cell.RowIndex]) }
    }
    return , $rows.ToArray()
}

#endregion

#region 選択中（✓）
# 離れた行をまとめて扱うための印。グリッドのハイライト（SelectedCells）とは別に、明細 Id で $S.Marked に持つ。
# ほかのセルをクリックしても、並べ替えても消えない。変更できない行（返品・既存分割）には付けない。

function Update-RowStyle {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    $item = $Row.Tag
    if ($item.Kind -ne 'Changeable') { return }   # 固定行は灰色のまま
    $marked = $script:S.Marked.Contains([int]$item.Id)
    $Row.Cells['Mark'].Value = if ($marked) { '✓' } else { '' }
    $v = $Row.Cells['Count'].Value
    $changed = $null -ne $v -and $v -isnot [System.DBNull] -and [int]$v -gt 1
    $Row.DefaultCellStyle.BackColor = if ($marked) { $script:Colors.Marked }
        elseif ($changed) { $script:Colors.Changed }
        else { [System.Drawing.Color]::Empty }
}

function Update-MarkStatus {
    $n = $script:S.Marked.Count
    $script:C.MarkStatus.Text = '選択中 {0} 件' -f $n
    $script:C.MarkStatus.ForeColor = if ($n -gt 0) { $script:Colors.MarkFg } else { $script:Colors.FixedFg }
    $script:C.ClearMarks.Enabled = $n -gt 0
}

function Switch-RowMark {
    <#
    .SYNOPSIS
        1 行の選択中（✓）を切り替える。変更できない行なら何もせず $false。
    #>
    param([Parameter(Mandatory)][System.Windows.Forms.DataGridViewRow]$Row)
    if ($Row.Tag.Kind -ne 'Changeable') { return $false }
    $id = [int]$Row.Tag.Id
    if (-not $script:S.Marked.Remove($id)) { [void]$script:S.Marked.Add($id) }
    $script:S.Updating = $true
    try { Update-RowStyle -Row $Row } finally { $script:S.Updating = $false }
    Update-MarkStatus
    return $true
}

function Add-RowMark {
    <#
    .SYNOPSIS
        行をまとめて選択中（✓）にする（すでに選択中の行はそのまま）。変更できない行は飛ばす。
    #>
    param([System.Windows.Forms.DataGridViewRow[]]$Rows)
    $script:S.Updating = $true
    try {
        foreach ($row in @($Rows)) {
            if ($row.Tag.Kind -ne 'Changeable') { continue }
            [void]$script:S.Marked.Add([int]$row.Tag.Id)
            Update-RowStyle -Row $row
        }
    }
    finally { $script:S.Updating = $false }
    Update-MarkStatus
}

function Clear-RowMark {
    $script:S.Marked.Clear()
    $script:S.Updating = $true
    try { foreach ($row in $script:C.Grid.Rows) { Update-RowStyle -Row $row } }
    finally { $script:S.Updating = $false }
    Update-MarkStatus
}

function Get-TargetGridRow {
    <#
    .SYNOPSIS
        「選択中に適用」の対象。選択中（✓）の行があればその行、なければハイライトしている行。
    #>
    $marked = @($script:C.Grid.Rows | Where-Object { $script:S.Marked.Contains([int]$_.Tag.Id) })
    if ($marked.Count -gt 0) { return , [System.Windows.Forms.DataGridViewRow[]]$marked }
    return , (Get-SelectedGridRow)
}

function Set-TargetRowCount {
    param([Parameter(Mandatory)][int]$Count)
    $rows = Get-TargetGridRow
    if ($rows.Count -gt 0) { Set-RowCount -Count $Count -Rows $rows }
}

function Invoke-ItemDoubleClick {
    <#
    .SYNOPSIS
        明細のダブルクリック: 支払回数の列以外なら、その行の選択中（✓）を切り替える。
    #>
    param([int]$RowIndex, [string]$ColumnName)
    if ($RowIndex -lt 0 -or $ColumnName -eq 'Count') { return }
    [void](Switch-RowMark -Row $script:C.Grid.Rows[$RowIndex])
}

function Invoke-MarkSelection {
    # Space: ハイライトしている行（マウスで範囲選択中の行を含む）を選択中（✓）にする
    Add-RowMark -Rows (Get-SelectedGridRow)
}

#endregion

#region 並べ替え

function Get-RowSortValue {
    <#
    .SYNOPSIS
        並べ替えに使う値を返す。値がない（固定行の手数料など）ときは $null。
    #>
    param([System.Windows.Forms.DataGridViewRow]$Row, [string]$Key)
    $item = $Row.Tag
    switch ($Key) {
        'Id' { return $item.Id }
        'Mark' { return $(if ($script:S.Marked.Contains([int]$item.Id)) { 0 } else { 1 }) }
        'Date' { return $item.Date }
        'Merchant' { return $item.Merchant }
        'Amount' { return $item.Amount }
        'Kind' { return @{ Changeable = 0; Existing = 1; Refund = 2 }[$item.Kind] }
        'Count' {
            if ($item.Kind -ne 'Changeable') { return $item.Count }
            $v = $Row.Cells['Count'].Value
            if ($null -eq $v -or $v -is [System.DBNull]) { return 1 }
            return [int]$v
        }
        default {
            $v = $Row.Cells[$Key].Value
            if ($null -eq $v -or $v -is [System.DBNull]) { return $null }
            return [double]$v
        }
    }
}

function Update-SortIndicator {
    # 列見出しの ▲▼ と「並べ替え」リストの表示を、現在の並べ替えに合わせる
    $S = $script:S
    $C = $script:C
    foreach ($col in $C.Grid.Columns) {
        $col.HeaderCell.SortGlyphDirection = if ($col.Name -eq $S.SortKey) {
            if ($S.SortDescending) { 'Descending' } else { 'Ascending' }
        } else { 'None' }
    }
    $index = -1
    for ($i = 0; $i -lt $script:SortPresets.Count; $i++) {
        $p = $script:SortPresets[$i]
        if ($p.Key -eq $S.SortKey -and ($p.Descending -eq $S.SortDescending -or $p.Key -eq 'Id')) { $index = $i; break }
    }
    $S.SyncingSort = $true
    try { $C.Sort.SelectedIndex = $index }   # 選択肢にない並べ替え（列見出しのクリック）は空欄
    finally { $S.SyncingSort = $false }
}

function Set-ItemSort {
    <#
    .SYNOPSIS
        明細の行を並べ替える。値のない行は昇順・降順どちらでも末尾。同じ値は CSV の順。
        回数を変えても自動では並べ直さない（編集中の行が動かないように）。
    #>
    param(
        [Parameter(Mandatory)][ValidateScript({ $script:SortKeys -ccontains $_ })][string]$Key,
        [bool]$Descending = $false
    )
    $S = $script:S
    $grid = $script:C.Grid
    [void]$grid.EndEdit()

    $entries = foreach ($row in @($grid.Rows)) {
        $v = Get-RowSortValue -Row $row -Key $Key
        [pscustomobject]@{ Row = $row; Missing = ($null -eq $v); Value = $v; Id = $row.Tag.Id }
    }
    $sorted = @($entries | Sort-Object -Culture 'ja-JP' -Property @(
            @{ Expression = 'Missing'; Ascending = $true }
            @{ Expression = 'Value'; Descending = $Descending }
            @{ Expression = 'Id'; Ascending = $true }) | ForEach-Object Row)

    $current = $grid.CurrentCell
    $currentItem = if ($current) { $grid.Rows[$current.RowIndex].Tag } else { $null }

    $S.Updating = $true
    $grid.SuspendLayout()
    try {
        $grid.Rows.Clear()
        $grid.Rows.AddRange([System.Windows.Forms.DataGridViewRow[]]$sorted)
        $grid.ClearSelection()
        # 選んでいた明細が見える位置に残す
        if ($currentItem) {
            foreach ($row in $grid.Rows) {
                if ($row.Tag -eq $currentItem) {
                    # 表示前・高さ 0 のときは設定できないので無視する
                    try { $grid.FirstDisplayedScrollingRowIndex = $row.Index } catch { }
                    break
                }
            }
        }
    }
    finally {
        $grid.ResumeLayout()
        $S.Updating = $false
    }
    $S.SortKey = $Key
    $S.SortDescending = $Descending
    Update-SortIndicator
}

function Invoke-HeaderSort {
    <#
    .SYNOPSIS
        列見出しのクリック: 同じ列なら昇順・降順を切り替え、別の列なら既定の向きで並べ替える。
    #>
    param([Parameter(Mandatory)][string]$ColumnName)
    if ($script:SortKeys -cnotcontains $ColumnName) { return }
    $desc = if ($script:S.SortKey -eq $ColumnName) { -not $script:S.SortDescending } else { $script:DescendingFirst -contains $ColumnName }
    Set-ItemSort -Key $ColumnName -Descending $desc
}

#endregion

#region グラフ

function Get-NiceStep {
    param([double]$Max, [int]$Ticks = 4)
    if ($Max -le 0) { return 1 }
    $raw = $Max / $Ticks
    $mag = [math]::Pow(10, [math]::Floor([math]::Log10($raw)))
    foreach ($m in 1, 2, 2.5, 5, 10) {
        if ($raw -le $m * $mag) { return $m * $mag }
    }
    return 10 * $mag
}

function Invoke-ChartPaint {
    param([System.Drawing.Graphics]$Graphics, [System.Drawing.Rectangle]$Bounds)
    $S = $script:S
    $g = $Graphics
    $g.Clear([System.Drawing.Color]::White)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    if (-not $S -or -not $S.Result) { return }
    $months = @($S.Result.Months)
    if ($months.Count -eq 0) { return }

    $font = $S.SmallFont
    $textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.SystemColors]::ControlText)
    $gridPen = [System.Drawing.Pen]::new($script:Colors.Grid)
    $axisPen = [System.Drawing.Pen]::new($script:Colors.Axis)
    $beforeBrush = [System.Drawing.SolidBrush]::new($script:Colors.Before)
    $afterBrush = [System.Drawing.SolidBrush]::new($script:Colors.After)
    try {
        $max = 0
        foreach ($m in $months) { $max = [math]::Max($max, [math]::Max($m.Before, $m.After)) }
        $step = Get-NiceStep $max
        $yMax = [math]::Max($step, [math]::Ceiling($max / $step) * $step)

        $yLabelW = $g.MeasureString(('{0:N0}' -f $yMax), $font).Width
        $lineH = $g.MeasureString('0', $font).Height
        $left = $Bounds.Left + $yLabelW + (Get-Scaled 8)
        $right = $Bounds.Right - (Get-Scaled 10)
        $top = $Bounds.Top + $lineH + (Get-Scaled 12)
        $bottom = $Bounds.Bottom - $lineH - (Get-Scaled 10)
        $plotW = $right - $left
        $plotH = $bottom - $top
        if ($plotW -le 20 -or $plotH -le 20) { return }

        # 凡例
        $sw = Get-Scaled 12
        $x = $left
        foreach ($lg in @(@($beforeBrush, '変更前（明細どおり）'), @($afterBrush, '変更後'))) {
            $g.FillRectangle($lg[0], [single]$x, [single]($Bounds.Top + (Get-Scaled 5)), $sw, $sw)
            $x += $sw + (Get-Scaled 4)
            $g.DrawString($lg[1], $font, $textBrush, [single]$x, [single]($Bounds.Top + (Get-Scaled 3)))
            $x += $g.MeasureString($lg[1], $font).Width + (Get-Scaled 16)
        }

        # 目盛り
        $rightFmt = [System.Drawing.StringFormat]::new()
        $rightFmt.Alignment = [System.Drawing.StringAlignment]::Far
        $rightFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        for ($v = 0; $v -le $yMax + 0.5; $v += $step) {
            $y = $bottom - $v / $yMax * $plotH
            $g.DrawLine($gridPen, [single]$left, [single]$y, [single]$right, [single]$y)
            $g.DrawString(('{0:N0}' -f $v), $font, $textBrush, [single]($left - (Get-Scaled 4)), [single]$y, $rightFmt)
        }
        $g.DrawLine($axisPen, [single]$left, [single]$bottom, [single]$right, [single]$bottom)

        # 棒
        $groupW = $plotW / $months.Count
        $barW = [math]::Max(1.0, [math]::Min($groupW * 0.38, (Get-Scaled 34)))
        $labelW = $g.MeasureString('2026/12', $font).Width + (Get-Scaled 6)
        $every = [math]::Max(1, [int][math]::Ceiling($labelW / $groupW))
        $centerFmt = [System.Drawing.StringFormat]::new()
        $centerFmt.Alignment = [System.Drawing.StringAlignment]::Center
        for ($i = 0; $i -lt $months.Count; $i++) {
            $m = $months[$i]
            $cx = $left + ($i + 0.5) * $groupW
            foreach ($bar in @(@($m.Before, $beforeBrush, ($cx - $barW - 1)), @($m.After, $afterBrush, ($cx + 1)))) {
                $h = [math]::Max(0, $bar[0]) / $yMax * $plotH
                if ($h -gt 0) {
                    $g.FillRectangle($bar[1], [single]$bar[2], [single]($bottom - $h), [single]$barW, [single]$h)
                }
            }
            if ($i % $every -eq 0) {
                $text = if ($i -eq 0 -or $m.Month.Month -eq 1) { $m.Month.ToString('yyyy/MM') } else { $m.Month.ToString('MM') + '月' }
                $g.DrawString($text, $font, $textBrush, [single]$cx, [single]($bottom + (Get-Scaled 3)), $centerFmt)
            }
        }
        $rightFmt.Dispose(); $centerFmt.Dispose()
    }
    finally {
        $textBrush.Dispose(); $gridPen.Dispose(); $axisPen.Dispose(); $beforeBrush.Dispose(); $afterBrush.Dispose()
    }
}

#endregion

#region フォーム

function New-ItemGrid {
    $S = $script:S
    $g = [System.Windows.Forms.DataGridView]::new()
    $g.Dock = 'Fill'
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.AllowUserToResizeRows = $false
    $g.RowHeadersVisible = $false
    $g.SelectionMode = 'CellSelect'
    $g.MultiSelect = $true
    $g.BackgroundColor = [System.Drawing.Color]::White
    $g.BorderStyle = 'None'
    $g.AutoSizeRowsMode = 'AllCells'
    $g.ColumnHeadersHeightSizeMode = 'AutoSize'
    $g.ShowCellToolTips = $true
    Set-DoubleBuffered $g

    $add = {
        param([string]$Name, [string]$Header, [string]$Format, [switch]$RightAlign, [int]$Width, [switch]$Fill)
        $c = [System.Windows.Forms.DataGridViewTextBoxColumn]::new()
        $c.Name = $Name; $c.HeaderText = $Header; $c.ReadOnly = $true
        if ($Format) { $c.DefaultCellStyle.Format = $Format }
        if ($RightAlign) { $c.DefaultCellStyle.Alignment = 'MiddleRight' }
        if ($Fill) { $c.AutoSizeMode = 'Fill'; $c.MinimumWidth = (Get-Scaled 130) }
        elseif ($Width) { $c.Width = (Get-Scaled $Width) }
        [void]$g.Columns.Add($c)
    }
    # 選択中（✓）の印。ダブルクリック / Space で切り替える
    & $add 'Mark' '✓' -Width 30
    $g.Columns['Mark'].DefaultCellStyle.Alignment = 'MiddleCenter'
    $g.Columns['Mark'].DefaultCellStyle.ForeColor = $script:Colors.MarkFg
    $g.Columns['Mark'].DefaultCellStyle.Font = $S.BoldFont
    $g.Columns['Mark'].ToolTipText = '選択中（ダブルクリックで切り替え / 範囲を選んで Space で選択中に）'
    & $add 'Date' '利用日' 'yyyy/MM/dd' -Width 88
    & $add 'Merchant' '利用先' -Fill
    & $add 'Amount' '利用金額' 'N0' -RightAlign -Width 80
    & $add 'Kind' '区分' -Width 110

    # 支払回数（DataTable を選択肢にして、値は int で持つ）
    $choices = [System.Data.DataTable]::new()
    [void]$choices.Columns.Add('Value', [int])
    [void]$choices.Columns.Add('Name', [string])
    foreach ($n in $S.Settings.counts) { [void]$choices.Rows.Add([int]$n, (Get-CountLabel $n)) }
    $cc = [System.Windows.Forms.DataGridViewComboBoxColumn]::new()
    $cc.Name = 'Count'; $cc.HeaderText = '支払回数'
    $cc.DataSource = $choices; $cc.ValueMember = 'Value'; $cc.DisplayMember = 'Name'
    $cc.ValueType = [int]
    $cc.DisplayStyle = 'DropDownButton'
    $cc.FlatStyle = 'Flat'
    $cc.Width = (Get-Scaled 132)
    [void]$g.Columns.Add($cc)

    & $add 'Rate' '100円あたり' '0.00' -RightAlign -Width 86
    & $add 'Fee' '手数料' 'N0' -RightAlign -Width 72
    & $add 'ThisMonth' '今月分' 'N0' -RightAlign -Width 80
    & $add 'Total' '支払総額' 'N0' -RightAlign -Width 84
    $g.Columns['Amount'].Width = Get-Scaled 94
    $g.Columns['Rate'].ToolTipText = '利用金額 100 円あたりの分割払い手数料（円）'
    $g.Columns['ThisMonth'].ToolTipText = '今月の請求に含まれる額（分割にした明細は 1 回目）'
    $g.Columns['Total'].ToolTipText = '手数料を含めた支払いの合計'

    # 並べ替えは Set-ItemSort で行う（列見出しのクリック / 「並べ替え」リスト）。
    # ▲▼ の分だけ見出しが広がるので、折り返さず 1 行に収める
    $g.ColumnHeadersDefaultCellStyle.WrapMode = 'False'
    foreach ($c in $g.Columns) {
        $c.SortMode = 'Programmatic'
        if (-not $c.ToolTipText) { $c.ToolTipText = '{0}（クリックで並べ替え）' -f $c.HeaderText }
        else { $c.ToolTipText += '（クリックで並べ替え）' }
    }
    $g.add_ColumnHeaderMouseClick({
        param($sender, $e)
        if ($e.Button -ne 'Left') { return }
        $name = $sender.Columns[$e.ColumnIndex].Name
        Invoke-UiSafe { Invoke-HeaderSort -ColumnName $name }
    })

    # ComboBox で選んだ時点で確定させる
    $g.add_CurrentCellDirtyStateChanged({
        param($sender, $e)
        if ($sender.IsCurrentCellDirty -and $sender.CurrentCell.OwningColumn.Name -eq 'Count') {
            [void]$sender.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })
    $g.add_CellValueChanged({
        param($sender, $e)
        if ($script:S.Updating -or $e.RowIndex -lt 0) { return }
        if ($sender.Columns[$e.ColumnIndex].Name -ne 'Count') { return }
        Invoke-UiSafe { Update-Simulation }
    })
    # 1 クリックでドロップダウンを開く（Ctrl / Shift を押しているときは範囲選択を優先）
    $g.add_CellClick({
        param($sender, $e)
        if ($e.RowIndex -lt 0 -or $sender.Columns[$e.ColumnIndex].Name -ne 'Count') { return }
        if ([System.Windows.Forms.Control]::ModifierKeys -ne 'None') { return }
        $cell = $sender.Rows[$e.RowIndex].Cells[$e.ColumnIndex]
        if ($cell.ReadOnly) { return }
        [void]$sender.BeginEdit($true)
        if ($sender.EditingControl -is [System.Windows.Forms.ComboBox]) { $sender.EditingControl.DroppedDown = $true }
    })
    # ダブルクリックで選択中（✓）を切り替える（支払回数の列はドロップダウン用なので除く）
    $g.add_CellDoubleClick({
        param($sender, $e)
        if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
        $name = $sender.Columns[$e.ColumnIndex].Name
        $index = $e.RowIndex
        Invoke-UiSafe { Invoke-ItemDoubleClick -RowIndex $index -ColumnName $name }
    })
    # Space: ハイライト中の行（マウスで範囲選択している最中も）を選択中にする。
    # SuppressKeyPress で、Space による編集開始・既定の動作を止める
    $g.add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -ne 'Space' -or $e.Control -or $e.Alt) { return }
        $e.Handled = $true
        $e.SuppressKeyPress = $true
        Invoke-UiSafe { Invoke-MarkSelection }
    })
    $g.add_DataError({ param($sender, $e) $e.ThrowException = $false })
    return $g
}

function Set-GridStatement {
    <#
    .SYNOPSIS
        明細グリッドの行を、指定した明細の内容で作り直す（回数はすべて 1 回）。
    #>
    param(
        [Parameter(Mandatory)][System.Windows.Forms.DataGridView]$Grid,
        [Parameter(Mandatory)]$Statement
    )
    [void]$Grid.EndEdit()
    $Grid.SuspendLayout()
    try {
        $Grid.Rows.Clear()
        foreach ($item in $Statement.Items) {
            $i = $Grid.Rows.Add()
            $row = $Grid.Rows[$i]
            $row.Tag = $item
            $row.Cells['Date'].Value = $item.Date
            $row.Cells['Merchant'].Value = $item.Merchant
            $row.Cells['Amount'].Value = $item.Amount
            if ($item.Note) { $row.Cells['Merchant'].ToolTipText = $item.Note }
            switch ($item.Kind) {
                'Changeable' {
                    $row.Cells['Kind'].Value = '変更できます'
                    $row.Cells['Count'].Value = 1
                }
                default {
                    $row.Cells['Kind'].Value = if ($item.Kind -eq 'Existing') {
                        '既存分割 {1}/{0}回' -f $item.Count, $item.Current
                    } else {
                        if ($item.Note) { $item.Note } else { 'マイナス（返品など）' }
                    }
                    $txt = [System.Windows.Forms.DataGridViewTextBoxCell]::new()
                    $row.Cells['Count'] = $txt
                    $txt.Value = if ($item.Kind -eq 'Existing') { '{0}回（変更不可）' -f $item.Count } else { '変更不可' }
                    $txt.ReadOnly = $true
                    $row.DefaultCellStyle.BackColor = $script:Colors.FixedBg
                    $row.DefaultCellStyle.ForeColor = $script:Colors.FixedFg
                }
            }
        }
        $Grid.ClearSelection()
    }
    finally { $Grid.ResumeLayout() }
}

function New-ScheduleGrid {
    $g = [System.Windows.Forms.DataGridView]::new()
    $g.Dock = 'Fill'
    $g.ReadOnly = $true
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.AllowUserToResizeRows = $false
    $g.RowHeadersVisible = $false
    $g.BackgroundColor = [System.Drawing.Color]::White
    $g.BorderStyle = 'None'
    $g.SelectionMode = 'FullRowSelect'
    $g.AutoSizeColumnsMode = 'Fill'
    $g.ColumnHeadersHeightSizeMode = 'AutoSize'
    $g.DefaultCellStyle.Font = $script:S.SmallFont
    $g.ColumnHeadersDefaultCellStyle.Font = $script:S.SmallFont
    Set-DoubleBuffered $g
    foreach ($def in @(
            @('Month', '請求月', '', 64), @('Before', '変更前', 'N0', 58), @('After', '変更後', 'N0', 58),
            @('Diff', '差額', '+#,0;-#,0;0', 58), @('Fee', 'うち手数料', 'N0', 50))) {
        $c = [System.Windows.Forms.DataGridViewTextBoxColumn]::new()
        $c.Name = $def[0]; $c.HeaderText = $def[1]; $c.SortMode = 'NotSortable'
        $c.MinimumWidth = Get-Scaled $def[3]
        if ($def[2]) { $c.DefaultCellStyle.Format = $def[2]; $c.DefaultCellStyle.Alignment = 'MiddleRight' }
        [void]$g.Columns.Add($c)
    }
    return $g
}

function New-SummaryPanel {
    $t = [System.Windows.Forms.TableLayoutPanel]::new()
    $t.Dock = 'Fill'
    $t.ColumnCount = 2
    $t.AutoScroll = $true
    [void]$t.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('AutoSize'))
    [void]$t.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
    $labels = [ordered]@{}
    foreach ($def in @(
            @('ThisMonth', '今月の請求額'), @('ThisMonthDiff', '今月の差額'), @('Fee', '手数料の合計'),
            @('Total', '支払総額'), @('Max', '最大の月額'), @('Last', '支払い終了月'), @('Changed', '分割した明細'))) {
        $name = New-Label $def[1]
        $value = New-Label '' -Bold
        [void]$t.Controls.Add($name)
        [void]$t.Controls.Add($value)
        $labels[$def[0]] = $value
    }
    $labels.ThisMonth.Font = $script:S.BigFont
    $labels.ThisMonthDiff.Font = $script:S.BigFont
    return @{ Panel = $t; Labels = $labels }
}

function New-GroupBox {
    param([string]$Text, [System.Windows.Forms.Control]$Child)
    $gb = [System.Windows.Forms.GroupBox]::new()
    $gb.Text = $Text
    $gb.Dock = 'Fill'
    $gb.Padding = [System.Windows.Forms.Padding]::new((Get-Scaled 6))
    $gb.Controls.Add($Child)
    return $gb
}

function New-InstallmentSimulatorForm {
    <#
    .SYNOPSIS
        メインウィンドウを組み立てて返す（表示はしない）。

    .PARAMETER DataDirectory
        設定（settings.json）の置き場所。

    .PARAMETER StatementDirectory
        明細 CSV の置き場所。ここにある CSV を「明細」リストに並べ、選んだ月を試算する。

    .PARAMETER Path
        最初に開く明細。省略時は前回開いていた明細、それも無ければ最新の月。
        StatementDirectory の外のファイルでもよい（リストに加える）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$StatementDirectory,
        [string]$Path
    )

    $form = [System.Windows.Forms.Form]::new()
    $settings = Read-SimulatorSettings -DataDirectory $DataDirectory
    $script:S = @{
        Statement     = $null
        Settings      = $settings
        DataDirectory = $DataDirectory
        StatementDirectory = [System.IO.Path]::GetFullPath($StatementDirectory)
        ExtraPath     = $null     # StatementDirectory の外から開いた明細
        Files         = @()       # 「明細」リストの中身（Get-StatementFile の結果）
        MonthStates   = @{}       # 明細のパス -> @{ Counts; Marked }（開いている間だけ覚えておく）
        SyncingFile   = $false
        Scale         = [math]::Max(1.0, $form.DeviceDpi / 96.0)
        Updating      = $false
        Result        = $null
        SortKey       = 'Id'
        SortDescending = $false
        SyncingSort   = $false
        Marked        = [System.Collections.Generic.HashSet[int]]::new()   # 選択中（✓）の明細 Id
        UiFont        = [System.Drawing.Font]::new('Meiryo UI', 10)
        BoldFont      = [System.Drawing.Font]::new('Meiryo UI', 9, [System.Drawing.FontStyle]::Bold)   # 月別表の強調用
        BigFont       = [System.Drawing.Font]::new('Meiryo UI', 12, [System.Drawing.FontStyle]::Bold)
        SmallFont     = [System.Drawing.Font]::new('Meiryo UI', 9)
    }
    $S = $script:S

    $form.Text = '分割払いシミュレーター'
    $form.Font = $S.UiFont
    $form.StartPosition = 'CenterScreen'
    # 保存したサイズ（既定 1000x720、96 DPI 換算）を DPI に合わせ、作業領域の 90% を超えないようにする
    $area = [System.Drawing.Rectangle]::new(0, 0, 1280, 800)
    try { $area = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea } catch { }
    $maxW = [int]($area.Width * 0.9)
    $maxH = [int]($area.Height * 0.9)
    $minW = [math]::Min((Get-Scaled 720), $maxW)
    $minH = [math]::Min((Get-Scaled 520), $maxH)
    $w = [math]::Max($minW, [math]::Min((Get-Scaled $settings.windowWidth), $maxW))
    $h = [math]::Max($minH, [math]::Min((Get-Scaled $settings.windowHeight), $maxH))
    $form.MinimumSize = [System.Drawing.Size]::new($minW, $minH)
    $form.Size = [System.Drawing.Size]::new($w, $h)
    $form.KeyPreview = $true

    $root = [System.Windows.Forms.TableLayoutPanel]::new()
    $root.Dock = 'Fill'
    $root.ColumnCount = 1
    $root.RowCount = 4
    $root.Padding = [System.Windows.Forms.Padding]::new((Get-Scaled 6))
    [void]$root.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize'))
    [void]$root.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Percent', 52))
    [void]$root.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Percent', 48))
    [void]$root.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize'))

    # 上部: カード情報と操作
    $bar = [System.Windows.Forms.FlowLayoutPanel]::new()
    $bar.Dock = 'Fill'
    $bar.AutoSize = $true
    $bar.WrapContents = $true
    $tip = [System.Windows.Forms.ToolTip]::new()

    # 1 行目: どの月の明細を試算するか
    $bar.Controls.Add((New-Label '明細' -Bold))
    $month = [System.Windows.Forms.ComboBox]::new()
    $month.DropDownStyle = 'DropDownList'
    $month.Width = Get-Scaled 230
    $month.Margin = [System.Windows.Forms.Padding]::new((Get-Scaled 3), (Get-Scaled 4), (Get-Scaled 3), (Get-Scaled 3))
    $month.add_SelectedIndexChanged({
        param($sender, $e)
        if ($script:S.SyncingFile -or $sender.SelectedIndex -lt 0) { return }
        $file = $script:S.Files[$sender.SelectedIndex]
        Invoke-UiSafe { Open-Statement -Path $file.Path }
        Update-StatementList   # 開けなかったときは元の月の表示に戻す
    })
    $tip.SetToolTip($month, '試算する明細（請求月）を選びます。月ごとの回数と選択中（✓）は、ウィンドウを閉じるまで覚えています。')
    $bar.Controls.Add($month)
    $reload = New-Button '再読込' {
        Update-StatementList
        Open-Statement -Path $script:S.Statement.Path
        Update-StatementList
    }
    $tip.SetToolTip($reload, '明細フォルダの CSV を読み直します（追加・更新した明細を反映）。')
    $bar.Controls.Add($reload)
    $openDir = New-Button 'フォルダを開く' {
        if (-not (Test-Path -LiteralPath $script:S.StatementDirectory)) {
            [void](New-Item -ItemType Directory -Path $script:S.StatementDirectory -Force)
        }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:S.StatementDirectory)
    }
    $tip.SetToolTip($openDir, ('明細 CSV の置き場所を開きます: {0}' -f $S.StatementDirectory))
    $bar.Controls.Add($openDir)

    # 1 行目の右側: 並べ替え
    $bar.Controls.Add((New-Label '　｜　並べ替え'))
    $sort = [System.Windows.Forms.ComboBox]::new()
    $sort.DropDownStyle = 'DropDownList'
    $sort.Width = Get-Scaled 230
    $sort.Margin = [System.Windows.Forms.Padding]::new((Get-Scaled 3), (Get-Scaled 4), (Get-Scaled 3), (Get-Scaled 3))
    foreach ($p in $script:SortPresets) { [void]$sort.Items.Add($p.Label) }
    $sort.add_SelectedIndexChanged({
        param($sender, $e)
        if ($script:S.SyncingSort -or $sender.SelectedIndex -lt 0) { return }
        $p = $script:SortPresets[$sender.SelectedIndex]
        Invoke-UiSafe { Set-ItemSort -Key $p.Key -Descending $p.Descending }
    })
    $bar.Controls.Add($sort)
    $bar.SetFlowBreak($sort, $true)

    # 2 行目: 年率・まとめて変更・選択中
    $bar.Controls.Add((New-Label '実質年率'))
    $rate = [System.Windows.Forms.NumericUpDown]::new()
    $rate.DecimalPlaces = 2
    $rate.Increment = [decimal]0.25
    $rate.Minimum = 0
    $rate.Maximum = 30
    $rate.Value = [decimal]$settings.annualRate
    $rate.Width = Get-Scaled 72
    $rate.TextAlign = 'Right'
    $rate.Margin = [System.Windows.Forms.Padding]::new((Get-Scaled 3), (Get-Scaled 4), 0, (Get-Scaled 3))
    $rate.add_ValueChanged({ Invoke-UiSafe { Update-Simulation } })
    $bar.Controls.Add($rate)
    $bar.Controls.Add((New-Label '%'))

    $bar.Controls.Add((New-Label '　｜　まとめて'))
    $bulk = [System.Windows.Forms.ComboBox]::new()
    $bulk.DropDownStyle = 'DropDownList'
    $bulk.Width = Get-Scaled 150
    $bulk.Margin = [System.Windows.Forms.Padding]::new((Get-Scaled 3), (Get-Scaled 4), (Get-Scaled 3), (Get-Scaled 3))
    foreach ($n in $settings.counts) { [void]$bulk.Items.Add((Get-CountLabel $n)) }
    $bulk.SelectedIndex = [math]::Max(0, [array]::IndexOf([int[]]$settings.counts, 3))
    $bar.Controls.Add($bulk)
    $applyMarked = New-Button '選択中に適用' {
        $n = [int]$script:S.Settings.counts[$script:C.Bulk.SelectedIndex]
        Set-TargetRowCount -Count $n
    }
    $tip.SetToolTip($applyMarked, '選択中（✓）の行に適用します。✓ がなければ、いまハイライトしている行に適用します。')
    $bar.Controls.Add($applyMarked)
    $applyAll = New-Button 'すべてに適用' {
        $n = [int]$script:S.Settings.counts[$script:C.Bulk.SelectedIndex]
        Set-RowCount -Count $n
    }
    $tip.SetToolTip($applyAll, '変更できる明細すべてに適用します。')
    $bar.Controls.Add($applyAll)
    $reset = New-Button 'リセット' { Set-RowCount -Count 1 }
    $tip.SetToolTip($reset, 'すべての明細を 1 回払いに戻します（選択中の ✓ はそのまま）。')
    $bar.Controls.Add($reset)

    $bar.Controls.Add((New-Label '　｜　'))
    $markStatus = New-Label '選択中 0 件' -Bold
    $bar.Controls.Add($markStatus)
    $clearMarks = New-Button '選択を解除' { Clear-RowMark }
    $tip.SetToolTip($clearMarks, '選択中（✓）をすべて外します。1 行ずつ外すときはその行をダブルクリックします。')
    $bar.Controls.Add($clearMarks)
    $root.Controls.Add($bar, 0, 0)

    # 中央: 明細
    $grid = New-ItemGrid
    $root.Controls.Add((New-GroupBox '明細（ダブルクリックで選択中 ✓ を切り替え。ドラッグ・Ctrl / Shift で選んだ範囲は Space でまとめて選択中に）' $grid), 0, 1)

    # 下部: サマリー / 月別表 / グラフ
    $bottom = [System.Windows.Forms.TableLayoutPanel]::new()
    $bottom.Dock = 'Fill'
    $bottom.ColumnCount = 3
    $bottom.RowCount = 1
    $bottom.Margin = [System.Windows.Forms.Padding]::new(0)
    [void]$bottom.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', (Get-Scaled 330)))
    [void]$bottom.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 56))
    [void]$bottom.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 44))
    $summary = New-SummaryPanel
    $schedule = New-ScheduleGrid
    $chart = [System.Windows.Forms.Panel]::new()
    $chart.Dock = 'Fill'
    $chart.BackColor = [System.Drawing.Color]::White
    Set-DoubleBuffered $chart
    $chart.add_Paint({
        param($sender, $e)
        try { Invoke-ChartPaint -Graphics $e.Graphics -Bounds $sender.ClientRectangle }
        catch { Write-Host ('グラフの描画に失敗しました: {0}' -f $_.Exception.Message) -ForegroundColor Red }
    })
    $chart.add_Resize({ param($sender, $e) $sender.Invalidate() })
    $bottom.Controls.Add((New-GroupBox 'サマリー（変更前 → 変更後）' $summary.Panel), 0, 0)
    $bottom.Controls.Add((New-GroupBox '月別の請求額' $schedule), 1, 0)
    $bottom.Controls.Add((New-GroupBox '月別の請求額（グラフ）' $chart), 2, 0)
    $root.Controls.Add($bottom, 0, 2)

    # 注記と警告
    $notes = [System.Windows.Forms.FlowLayoutPanel]::new()
    $notes.Dock = 'Fill'
    $notes.AutoSize = $true
    $notes.FlowDirection = 'TopDown'
    $notes.WrapContents = $false
    $note = New-Label ("※ 元利均等方式・実質年率で計算した概算です（1・2 回払いは手数料なし、端数は初回に加算）。実際の金額はカード会社の確定額に従います。`n" +
        '※ 既存の分割払いは残りの回も今回と同じ額で計上しています。利用先にマウスを乗せると備考（外貨の金額など）を表示します。')
    $note.ForeColor = $script:Colors.FixedFg
    # カード名・番号・明細の件数（Open-Statement で更新する）
    $info = New-Label '' -Bold
    $notes.Controls.Add($info)
    $notes.Controls.Add($note)
    $warn = New-Label '' -Bold     # 明細の警告（合計の不一致など）。Open-Statement で更新する
    $warn.ForeColor = $script:Colors.Warning
    $warn.Visible = $false
    $notes.Controls.Add($warn)
    $root.Controls.Add($notes, 0, 3)

    $form.Controls.Add($root)

    $script:C = @{
        Form     = $form
        Grid     = $grid
        Rate     = $rate
        Bulk     = $bulk
        Sort     = $sort
        Month    = $month
        Info     = $info
        Warning  = $warn
        MarkStatus = $markStatus
        ClearMarks = $clearMarks
        ToolTip  = $tip
        Schedule = $schedule
        Chart    = $chart
        Summary  = $summary.Labels
    }

    # 起動直後に先頭セルが選択色で表示されないようにする
    # 最初のフォーカスは明細に置く（並べ替えリストが選択色にならないように）
    $form.add_Shown({
        $script:C.Form.ActiveControl = $script:C.Grid
        $script:C.Grid.ClearSelection()
        $script:C.Schedule.ClearSelection()
    })

    $form.add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq 'Escape') { $sender.Close() }
    })
    $form.add_FormClosing({
        try {
            $st = $script:S.Settings
            $st.annualRate = [double]$script:C.Rate.Value
            $st.sortKey = $script:S.SortKey
            $st.sortDescending = [bool]$script:S.SortDescending
            # 明細フォルダの中の明細なら、次回もその月から開く
            if ($script:S.Statement -and
                [System.IO.Path]::GetDirectoryName($script:S.Statement.Path) -eq $script:S.StatementDirectory) {
                $st.lastStatement = [System.IO.Path]::GetFileName($script:S.Statement.Path)
            }
            if ($script:C.Form.WindowState -eq 'Normal') {
                $st.windowWidth = [int]($script:C.Form.Width / $script:S.Scale)
                $st.windowHeight = [int]($script:C.Form.Height / $script:S.Scale)
            }
            Save-SimulatorSettings -DataDirectory $script:S.DataDirectory -Settings $st
        }
        catch { Write-Warning ('設定を保存できませんでした: {0}' -f $_.Exception.Message) }
    })

    # 前回の並べ替え（明細を開くたびに適用する）
    $S.SortKey = $settings.sortKey
    $S.SortDescending = [bool]$settings.sortDescending

    # 最初に開く明細: -Path → 前回の明細 → 最新の月
    if ($Path) {
        $Path = [System.IO.Path]::GetFullPath($Path)
        if ([System.IO.Path]::GetDirectoryName($Path) -ne $S.StatementDirectory) { $S.ExtraPath = $Path }
    }
    $files = @(Get-StatementFile -Directory $S.StatementDirectory)
    if (-not $Path -and $settings.lastStatement) {
        $last = $files | Where-Object { [System.IO.Path]::GetFileName($_.Path) -eq $settings.lastStatement } | Select-Object -First 1
        if ($last) { $Path = $last.Path }
    }
    if (-not $Path -and $files.Count -gt 0) { $Path = $files[0].Path }
    if (-not $Path) { throw ('明細 CSV が見つかりません: {0}' -f $S.StatementDirectory) }

    Open-Statement -Path $Path
    Update-StatementList
    return $form
}

function Update-StatementList {
    <#
    .SYNOPSIS
        明細フォルダを読み直して「明細」リストを作り、いま開いている明細を選んだ状態にする。
    #>
    $S = $script:S
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($f in @(Get-StatementFile -Directory $S.StatementDirectory)) { $files.Add($f) }
    $paths = @($files | ForEach-Object Path)
    foreach ($p in @($S.ExtraPath, $(if ($S.Statement) { $S.Statement.Path }))) {
        if ($p -and $paths -notcontains $p -and (Test-Path -LiteralPath $p)) {
            $files.Add((Get-StatementFile -Path $p))
            $paths += $p
        }
    }
    $S.Files = $files.ToArray()

    $combo = $script:C.Month
    $S.SyncingFile = $true
    try {
        $combo.BeginUpdate()
        $combo.Items.Clear()
        foreach ($f in $S.Files) { [void]$combo.Items.Add($f.Label) }
        $combo.SelectedIndex = if ($S.Statement) { [array]::IndexOf([string[]]$paths, [string]$S.Statement.Path) } else { -1 }
    }
    finally {
        $combo.EndUpdate()
        $S.SyncingFile = $false
    }
}

function Save-MonthState {
    # いま開いている明細の回数と選択中（✓）を覚えておく
    $S = $script:S
    if (-not $S.Statement) { return }
    $S.MonthStates[$S.Statement.Path] = @{
        Counts = Get-SelectedCounts
        Marked = [int[]]@($S.Marked)
    }
}

function Open-Statement {
    <#
    .SYNOPSIS
        明細を読み込んで画面を切り替える。読み込みに失敗したら例外を投げ、画面は元のまま。
        前に開いていた明細の回数・選択中は覚えておき、同じ明細に戻ったとき（再読込を含む）に復元する。
    #>
    param([Parameter(Mandatory)][string]$Path)
    $S = $script:S
    $C = $script:C
    $Path = [System.IO.Path]::GetFullPath($Path)
    $statement = Import-CardStatement -Path $Path   # 失敗したらここで止まる

    Save-MonthState
    $S.Statement = $statement
    $S.Marked.Clear()

    $S.Updating = $true
    try {
        Set-GridStatement -Grid $C.Grid -Statement $statement
        $state = $S.MonthStates[$Path]
        if ($state) {
            # Id は明細の行番号。読み直して行が減っていたら、ないものは無視する
            foreach ($row in $C.Grid.Rows) {
                $item = $row.Tag
                if ($item.Kind -ne 'Changeable') { continue }
                if ($state.Counts.ContainsKey($item.Id) -and @($S.Settings.counts) -contains [int]$state.Counts[$item.Id]) {
                    $row.Cells['Count'].Value = [int]$state.Counts[$item.Id]
                }
                if ($state.Marked -contains [int]$item.Id) { [void]$S.Marked.Add([int]$item.Id) }
            }
        }
    }
    finally { $S.Updating = $false }

    $name = [System.IO.Path]::GetFileName($Path)
    $C.Form.Text = '分割払いシミュレーター - {0}' -f $name
    $C.Info.Text = '{0}  {1}  ／  明細 {2} 件' -f $statement.CardName, $statement.CardNumber, $statement.Items.Count
    $C.Warning.Text = (@($statement.Warnings) | ForEach-Object { '⚠ ' + $_ }) -join "`n"
    $C.Warning.Visible = @($statement.Warnings).Count -gt 0

    Update-Simulation
    Update-MarkStatus
    Set-ItemSort -Key $S.SortKey -Descending ([bool]$S.SortDescending)
}

function Show-InstallmentSimulatorWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$StatementDirectory,
        [string]$Path
    )
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
    try { [void][System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2) } catch { }

    $form = New-InstallmentSimulatorForm @PSBoundParameters
    try {
        [void]$form.ShowDialog()
    }
    finally {
        if ($script:C -and $script:C.ToolTip) { $script:C.ToolTip.Dispose() }
        $form.Dispose()
        foreach ($k in 'UiFont', 'BoldFont', 'BigFont', 'SmallFont') { if ($script:S) { $script:S[$k].Dispose() } }
        $script:S = $null
        $script:C = $null
    }
}

function Get-InstallmentSimulatorState {
    <#
    .SYNOPSIS
        テスト用: 状態 ($script:S) とコントロール ($script:C) を返す。
    #>
    return [pscustomobject]@{ State = $script:S; Controls = $script:C }
}

function Set-InstallmentSimulatorTestMode {
    <#
    .SYNOPSIS
        テスト用: $true にするとダイアログを出さずに例外を投げる。
    #>
    param([bool]$Enabled = $true)
    $script:ThrowUiErrors = $Enabled
}

#endregion

Export-ModuleMember -Function New-InstallmentSimulatorForm, Show-InstallmentSimulatorWindow,
    Get-InstallmentSimulatorState, Set-InstallmentSimulatorTestMode, Set-RowCount, Update-Simulation,
    Set-ItemSort, Invoke-HeaderSort,
    Switch-RowMark, Add-RowMark, Clear-RowMark, Get-TargetGridRow, Set-TargetRowCount,
    Invoke-ItemDoubleClick, Invoke-MarkSelection, Open-Statement, Update-StatementList,
    Read-SimulatorSettings, Save-SimulatorSettings
