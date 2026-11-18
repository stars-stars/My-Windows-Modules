#Requires -Version 7.0
<#
.SYNOPSIS
    TextMask の WinForms GUI。

.DESCRIPTION
    MaskEngine.psm1 / Dictionary.psm1 / Clipboard.psm1 を先に読み込んでから使います。
    状態はこのモジュールの $script:S（セッション・辞書・バッファ）と $script:C（コントロール）に持ち、
    ウィンドウを閉じると破棄します。イベントハンドラーは必ず $script: 経由で状態を参照します。

    New-TextMaskForm はフォームを組み立てるだけで表示しません（テストから呼べるようにするため）。
#>

Set-StrictMode -Version 3.0
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('TextMaskNative.User32' -as [type])) {
    Add-Type -Namespace TextMaskNative -Name User32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct POINT { public int X; public int Y; }
[DllImport("user32.dll")]
public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll", EntryPoint = "SendMessage")]
public static extern IntPtr SendMessagePoint(IntPtr hWnd, int msg, IntPtr wParam, ref POINT lParam);
'@
}

$script:S = $null           # 状態
$script:C = $null           # メインウィンドウのコントロール
$script:D = $null           # ダイアログのコントロール
$script:ThrowUiErrors = $false   # テスト用: UI のエラーをダイアログにせず例外として投げる

$script:Colors = @{
    Name     = [System.Drawing.Color]::FromArgb(255, 238, 150)   # 実名（黄）
    Token    = [System.Drawing.Color]::FromArgb(196, 236, 196)   # 識別子（緑）
    Unknown  = [System.Drawing.Color]::FromArgb(255, 186, 186)   # 未知・エラー（赤）
    Broken   = [System.Drawing.Color]::FromArgb(255, 211, 160)   # 書式崩れ（橙）
    OutputBg = [System.Drawing.Color]::FromArgb(250, 250, 250)
    Ok       = [System.Drawing.Color]::FromArgb(0, 110, 40)
    Warn     = [System.Drawing.Color]::FromArgb(170, 90, 0)
    Error    = [System.Drawing.Color]::FromArgb(190, 20, 20)
}

# ---------------------------------------------------------------------------
# 共通ヘルパー
# ---------------------------------------------------------------------------

function Invoke-UiAction {
    # イベントハンドラーの本体を包み、例外をダイアログで知らせる（アプリを落とさない）
    param([scriptblock]$Action, [object[]]$ArgumentList = @())
    try {
        & $Action @ArgumentList
    }
    catch {
        if ($script:ThrowUiErrors) { throw }
        $msg = "処理中にエラーが発生しました。`n`n{0}`n`n{1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage
        $owner = if ($script:C) { $script:C.Form } else { $null }
        [void][System.Windows.Forms.MessageBox]::Show($owner, $msg, 'TextMask', 'OK', 'Error')
    }
}

function Show-Message {
    param([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK')
    # テスト中はダイアログを出さない（操作待ちでブロックするため）
    if ($script:ThrowUiErrors) { throw "[ダイアログ表示を抑止] $Text" }
    return [System.Windows.Forms.MessageBox]::Show($script:C.Form, $Text, 'TextMask', $Buttons, $Icon)
}

function New-Button {
    param([string]$Text, [scriptblock]$OnClick)
    $b = [System.Windows.Forms.Button]::new()
    $b.Text = $Text
    $b.AutoSize = $true
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.Padding = [System.Windows.Forms.Padding]::new(6, 2, 6, 2)
    $b.UseVisualStyleBackColor = $true
    if ($OnClick) { $b.Add_Click($OnClick) }
    return $b
}

function New-Label {
    param([string]$Text, [switch]$Bold)
    $l = [System.Windows.Forms.Label]::new()
    $l.Text = $Text
    $l.AutoSize = $true
    $l.Margin = [System.Windows.Forms.Padding]::new(3, 8, 3, 3)
    if ($Bold) { $l.Font = [System.Drawing.Font]::new($script:S.UiFont, [System.Drawing.FontStyle]::Bold) }
    return $l
}

function New-TextBoxPane {
    param([bool]$ReadOnly)
    $r = [System.Windows.Forms.RichTextBox]::new()
    $r.Dock = 'Fill'
    $r.Multiline = $true
    $r.WordWrap = $true
    $r.ScrollBars = 'Vertical'
    $r.DetectUrls = $false
    $r.HideSelection = $false
    $r.AutoWordSelection = $false
    $r.EnableAutoDragDrop = $false
    $r.AllowDrop = $false
    $r.Font = $script:S.TextFont
    $r.LanguageOption = [System.Windows.Forms.RichTextBoxLanguageOptions]::UIFonts
    $r.ReadOnly = $ReadOnly
    $r.BackColor = if ($ReadOnly) { $script:Colors.OutputBg } else { [System.Drawing.SystemColors]::Window }
    return $r
}

function Get-Buffer {
    param([string]$Mode = $script:S.Mode)
    return $script:S.Buffers[$Mode]
}

function New-Buffer {
    @{
        InputText    = ''
        OutputText   = ''
        OutputOffset = 0
        Crlf         = $true     # コピー時に改行を CRLF にするか（貼り付けた文章に合わせる）
        Dirty        = $false    # 変換後に入力が変更されたか
        Result       = $null
        Messages     = @()
    }
}

function ConvertTo-ClipboardText {
    param([string]$Text, [bool]$Crlf)
    if ($Crlf) { return $Text.Replace("`n", "`r`n") }
    return $Text
}

function Set-Status {
    param([string]$Text, [ValidateSet('info', 'ok', 'warn', 'error')][string]$Level = 'info')
    $C = $script:C
    $C.Status.Text = $Text
    $C.Status.ForeColor = switch ($Level) {
        'ok' { $script:Colors.Ok }
        'warn' { $script:Colors.Warn }
        'error' { $script:Colors.Error }
        default { [System.Drawing.SystemColors]::ControlText }
    }
}

# ---------------------------------------------------------------------------
# ハイライト
# ---------------------------------------------------------------------------

function Set-Highlight {
    param(
        [System.Windows.Forms.RichTextBox]$Box,
        [object[]]$Spans,
        [int]$Offset = 0,
        [hashtable]$KindColors = @{}
    )
    $S = $script:S
    $S.Suppress = $true
    $redraw = $Box.IsHandleCreated
    $pt = [TextMaskNative.User32+POINT]::new()
    try {
        if ($redraw) {
            # 描画を止め、スクロール位置を保存（EM_GETSCROLLPOS）
            [void][TextMaskNative.User32]::SendMessagePoint($Box.Handle, 0x04DD, [IntPtr]::Zero, [ref]$pt)
            [void][TextMaskNative.User32]::SendMessage($Box.Handle, 0x000B, [IntPtr]::Zero, [IntPtr]::Zero)
        }
        $selStart = $Box.SelectionStart
        $selLen = $Box.SelectionLength
        $len = $Box.Text.Length
        $Box.SelectAll()
        $Box.SelectionBackColor = $Box.BackColor
        foreach ($sp in @($Spans)) {
            if ($null -eq $sp) { continue }
            $color = $KindColors[$sp.Kind]
            if ($null -eq $color) { continue }
            $start = $sp.Start + $Offset
            if ($start -lt 0 -or $sp.Length -le 0 -or $start + $sp.Length -gt $len) { continue }
            $Box.Select($start, $sp.Length)
            $Box.SelectionBackColor = $color
        }
        $Box.Select($selStart, $selLen)
        if ($selLen -eq 0) { $Box.SelectionBackColor = $Box.BackColor }
    }
    finally {
        if ($redraw) {
            [void][TextMaskNative.User32]::SendMessagePoint($Box.Handle, 0x04DE, [IntPtr]::Zero, [ref]$pt)
            [void][TextMaskNative.User32]::SendMessage($Box.Handle, 0x000B, [IntPtr]1, [IntPtr]::Zero)
            $Box.Invalidate()
        }
        $S.Suppress = $false
    }
}

function Get-KindColors {
    param([string]$Mode, [ValidateSet('Input', 'Output')][string]$Pane)
    $pal = $script:Colors
    if ($Mode -eq 'Mask') {
        if ($Pane -eq 'Input') { return @{ masked = $pal.Name; error = $pal.Unknown } }
        return @{ masked = $pal.Token }
    }
    if ($Pane -eq 'Input') { return @{ restored = $pal.Token; unknown = $pal.Unknown; broken = $pal.Broken } }
    return @{ restored = $pal.Name; unknown = $pal.Unknown; broken = $pal.Broken }
}

# ---------------------------------------------------------------------------
# 表示の更新
# ---------------------------------------------------------------------------

function Update-ModeLabels {
    $C = $script:C
    if ($script:S.Mode -eq 'Mask') {
        $C.InputLabel.Text = '入力文章（原文）'
        $C.OutputLabel.Text = '変換結果（AI に送る文章）'
        $C.Convert.Text = 'マスキング'
        $C.ConvertCopy.Text = 'マスキングしてコピー (Ctrl+Enter)'
        $C.Register.Enabled = $true
    }
    else {
        $C.InputLabel.Text = 'AI の回答（識別子入り）'
        $C.OutputLabel.Text = '復元結果'
        $C.Convert.Text = '復元'
        $C.ConvertCopy.Text = '復元してコピー (Ctrl+Enter)'
        $C.Register.Enabled = $false
    }
}

function Update-Messages {
    $C = $script:C
    $buf = Get-Buffer
    $C.Messages.BeginUpdate()
    try {
        $C.Messages.Items.Clear()
        foreach ($m in @($buf.Messages)) {
            $prefix = if ($m.Level -eq 'Error') { '[エラー] ' } else { '[警告] ' }
            [void]$C.Messages.Items.Add($prefix + $m.Message)
        }
    }
    finally { $C.Messages.EndUpdate() }
    $n = @($buf.Messages).Count
    $C.MessagesGroup.Text = if ($n -gt 0) { "警告・エラー（$n 件 / ダブルクリックで該当箇所を選択）" } else { '警告・エラー（なし）' }
}

function Show-Buffer {
    # 現在のモードのバッファを画面に反映する
    $S = $script:S; $C = $script:C
    $buf = Get-Buffer
    $S.Suppress = $true
    try {
        if ($C.Input.Text -cne $buf.InputText) { $C.Input.Text = $buf.InputText }
        $C.Output.Text = $buf.OutputText
    }
    finally { $S.Suppress = $false }
    $r = $buf.Result
    if ($null -ne $r -and -not $buf.Dirty) {
        $inSpans = @($r.InputSpans)
        if ($r.HasError) {
            $inSpans = foreach ($e in $r.Errors) { if ($e.Index -ge 0) { [pscustomobject]@{ Start = $e.Index; Length = $e.Length; Kind = 'error' } } }
        }
        Set-Highlight -Box $C.Input -Spans @($inSpans) -KindColors (Get-KindColors $S.Mode 'Input')
        Set-Highlight -Box $C.Output -Spans @($r.OutputSpans) -Offset $buf.OutputOffset -KindColors (Get-KindColors $S.Mode 'Output')
    }
    else {
        Set-Highlight -Box $C.Input -Spans @()
        Set-Highlight -Box $C.Output -Spans @()
    }
    Update-Messages
}

function Update-SessionLabel {
    $s = $script:S.Session
    $state = if ($s.HasUnrestored) { '・未復元' } else { '' }
    $script:C.SessionLabel.Text = 'セッション: 対応表 {0} 件{1}' -f $s.Mappings.Count, $state
}

function Update-Grid {
    $S = $script:S; $C = $script:C
    $g = $C.Grid
    $counts = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $mr = $S.Buffers['Mask'].Result
    if ($null -ne $mr -and -not $mr.HasError) {
        foreach ($u in @($mr.Used)) { $counts[$u.Original] = $u.Count }
    }
    $labels = @{}
    foreach ($cat in Get-TextMaskCategory) { $labels[$cat.Name] = $cat.Label }

    $currentKey = $null
    if ($g.CurrentRow -and $g.CurrentRow.Tag) { $currentKey = '{0}|{1}' -f $g.CurrentRow.Tag.Type, $g.CurrentRow.Tag.Original }

    $S.GridUpdating = $true
    try {
        $g.Rows.Clear()
        $listed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($e in $S.Profile.Entries) {
            $rows.Add(@{ Type = 'persist'; Entry = $e; Original = $e.Original; Category = $e.Category; Enabled = [bool]$e.Enabled; Kind = '永続' })
            [void]$listed.Add($e.Original)
        }
        foreach ($e in $S.TempEntries) {
            $rows.Add(@{ Type = 'temp'; Entry = $e; Original = $e.Original; Category = $e.Category; Enabled = [bool]$e.Enabled; Kind = '一時' })
            [void]$listed.Add($e.Original)
        }
        foreach ($m in $S.Session.Mappings.Values) {
            if ($listed.Contains($m.Original)) { continue }
            if ($m.Source -in @('email', 'phone')) {
                $rows.Add(@{ Type = 'detected'; Entry = $null; Original = $m.Original; Category = $m.Category; Enabled = -not $S.Session.ExcludedValues.Contains($m.Original); Kind = '自動検出' })
            }
            else {
                $rows.Add(@{ Type = 'session'; Entry = $null; Original = $m.Original; Category = $m.Category; Enabled = $false; Kind = '対応表のみ' })
            }
            [void]$listed.Add($m.Original)
        }
        foreach ($row in $rows) {
            $id = $null
            [void]$S.Session.OriginalToId.TryGetValue($row.Original, [ref]$id)
            $n = 0
            $countText = if ($counts.TryGetValue($row.Original, [ref]$n)) { [string]$n } else { '' }
            $label = if ($labels.ContainsKey($row.Category)) { $labels[$row.Category] } else { $row.Category }
            $i = $g.Rows.Add([object[]]@($row.Enabled, $row.Original, $label, $row.Kind, [string]$id, $countText))
            $g.Rows[$i].Tag = $row
            if ($row.Type -eq 'session') {
                $g.Rows[$i].Cells[0].ReadOnly = $true
                $g.Rows[$i].DefaultCellStyle.ForeColor = [System.Drawing.SystemColors]::GrayText
            }
            if ($currentKey -eq ('{0}|{1}' -f $row.Type, $row.Original)) {
                try { $g.CurrentCell = $g.Rows[$i].Cells[1] } catch { }
            }
        }
    }
    finally { $S.GridUpdating = $false }

    $ro = if ($S.ProfileError) { '（読み込みエラー: 保存されません）' } else { '' }
    $C.DictLabel.Text = '辞書: 永続 {0} 件 / 一時 {1} 件{2}' -f $S.Profile.Entries.Count, $S.TempEntries.Count, $ro
    $C.DictLabel.ForeColor = if ($S.ProfileError) { $script:Colors.Error } else { [System.Drawing.SystemColors]::ControlText }
    Update-SessionLabel
}

# ---------------------------------------------------------------------------
# 変換・コピー
# ---------------------------------------------------------------------------

function Get-ActiveEntries {
    $S = $script:S
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $S.Profile.Entries) { $list.Add($e) }
    foreach ($e in $S.TempEntries) { $list.Add($e) }
    return , $list.ToArray()
}

function Invoke-MaskConvert {
    $S = $script:S; $C = $script:C
    $buf = Get-Buffer 'Mask'
    $text = $C.Input.Text
    $buf.InputText = $text
    if ($text.Length -eq 0) {
        Set-Status '入力文章が空です。' 'warn'
        return $false
    }

    $pre = [System.Collections.Generic.List[object]]::new()
    if ($S.Session.HasUnrestored -and $null -ne $S.LastMaskedSource -and $S.LastMaskedSource -cne $text) {
        $pre.Add((New-MaskMessage Warning '前回マスキングした文章をまだ復元していません。対応表は引き継がれます（同じ名称には同じ識別子）が、復元時の消失・回数チェックは今回の文章が対象になります。'))
    }
    if ($S.ProfileError) {
        $pre.Add((New-MaskMessage Warning '辞書ファイルを読み込めなかったため、永続辞書を使わずに変換しました。'))
    }

    $detect = $C.Detect.Checked
    $r = Invoke-TextMask -Text $text -Entries (Get-ActiveEntries) -Session $S.Session -DetectEmail:$detect -DetectPhone:$detect
    $buf.Result = $r
    $buf.Dirty = $false
    $buf.Messages = @($pre) + @($r.Errors) + @($r.Warnings)

    if ($r.HasError) {
        $buf.OutputText = ''
        $buf.OutputOffset = 0
        Show-Buffer
        Update-Grid
        Set-Status ('エラーのため変換を中止しました（{0} 件）。警告・エラー欄を確認してください。' -f @($r.Errors).Count) 'error'
        return $false
    }

    $S.LastMaskedSource = $text
    $out = $r.Text
    $offset = 0
    if ($C.Prompt.Checked) {
        $out = Get-CorrectionPrompt -MaskedText $r.Text
        $offset = $out.Length - $r.Text.Length
    }
    $buf.OutputText = $out
    $buf.OutputOffset = $offset
    Show-Buffer
    Update-Grid

    $w = @($buf.Messages).Count
    $msg = 'マスキング: {0} 箇所 / 識別子 {1} 種類 / 警告 {2} 件' -f $r.Count, @($r.Used).Count, $w
    Set-Status $msg $(if ($w -gt 0) { 'warn' } else { 'ok' })
    return $true
}

function Invoke-RestoreConvert {
    $S = $script:S; $C = $script:C
    $buf = Get-Buffer 'Restore'
    $text = $C.Input.Text
    $buf.InputText = $text
    if ($text.Length -eq 0) {
        Set-Status 'AI の回答を貼り付けてください。' 'warn'
        return $false
    }
    $r = Invoke-TextUnmask -Text $text -Session $S.Session
    $buf.Result = $r
    $buf.Dirty = $false
    $buf.Messages = @($r.Warnings)
    $buf.OutputText = $r.Text
    $buf.OutputOffset = 0
    Show-Buffer
    Update-Grid
    $w = @($buf.Messages).Count
    $msg = '復元: {0} 箇所 / 警告 {1} 件' -f $r.Count, $w
    Set-Status $msg $(if ($w -gt 0) { 'warn' } else { 'ok' })
    return $true
}

function Invoke-Convert {
    if ($script:S.Mode -eq 'Mask') { return (Invoke-MaskConvert) }
    return (Invoke-RestoreConvert)
}

function Invoke-AutoReconvert {
    # 辞書や設定を変えたとき、マスキング済みの結果があれば作り直す
    $S = $script:S
    if ($S.Mode -ne 'Mask') { return }
    $buf = Get-Buffer 'Mask'
    if ($null -eq $buf.Result -or $buf.Dirty) { return }
    [void](Invoke-MaskConvert)
}

function Copy-Output {
    $buf = Get-Buffer
    if ($null -eq $buf.Result) {
        Set-Status '先に変換してください。' 'warn'; return
    }
    if ($buf.Dirty) {
        Set-Status '変換後に入力が変更されています。もう一度変換してからコピーしてください。' 'warn'; return
    }
    if ($buf.Result.HasError) {
        Set-Status 'エラーがあるためコピーしません。警告・エラー欄を確認してください。' 'error'; return
    }
    if ([string]::IsNullOrEmpty($buf.OutputText)) {
        Set-Status 'コピーする内容がありません。' 'warn'; return
    }
    try {
        Set-TextMaskClipboardText -Text (ConvertTo-ClipboardText $buf.OutputText $buf.Crlf)
    }
    catch {
        Set-Status $_.Exception.Message 'error'; return
    }
    $w = @($buf.Messages).Count
    $what = if ($script:S.Mode -eq 'Mask') { 'マスキング結果' } else { '復元結果' }
    if ($w -gt 0) {
        Set-Status ('{0}をコピーしました。警告が {1} 件あります。内容を確認してください。' -f $what, $w) 'warn'
    }
    else {
        Set-Status ('{0}をコピーしました（クリップボード履歴・クラウド同期の対象外として書き込み）。' -f $what) 'ok'
    }
}

function Invoke-ConvertAndCopy {
    if ((Invoke-Convert) -eq $true) { Copy-Output }
}

# ---------------------------------------------------------------------------
# 入力欄の操作
# ---------------------------------------------------------------------------

function Invoke-PasteToInput {
    param([switch]$ReplaceAll)
    $C = $script:C
    try { $t = Get-TextMaskClipboardText }
    catch { Set-Status $_.Exception.Message 'error'; return }
    if ([string]::IsNullOrEmpty($t)) {
        Set-Status 'クリップボードにテキストがありません。' 'warn'; return
    }
    $buf = Get-Buffer
    $hasCrlf = $t.Contains("`r`n")
    $hasLf = $t.Contains("`n")
    if ($ReplaceAll -or $C.Input.TextLength -eq 0) { $buf.Crlf = ($hasCrlf -or -not $hasLf) }
    elseif ($hasLf) { $buf.Crlf = $hasCrlf }
    $t = $t.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($ReplaceAll) {
        $C.Input.Text = $t
        $C.Input.Select(0, 0)
    }
    else {
        $C.Input.SelectedText = $t
    }
    [void]$C.Input.Focus()
    Set-Status '貼り付けました。' 'info'
}

function Copy-Selection {
    param([System.Windows.Forms.RichTextBox]$Box, [switch]$Cut)
    if ($Box.SelectionLength -eq 0) { return }
    $buf = Get-Buffer
    try {
        Set-TextMaskClipboardText -Text (ConvertTo-ClipboardText $Box.SelectedText $buf.Crlf)
    }
    catch { Set-Status $_.Exception.Message 'error'; return }
    if ($Cut -and -not $Box.ReadOnly) { $Box.SelectedText = '' }
}

function Invoke-TextBoxKeyDown {
    # 貼り付けはプレーンテキストに、コピーは履歴・同期対象外の形式にする
    param([System.Windows.Forms.RichTextBox]$Box, [System.Windows.Forms.KeyEventArgs]$e)
    $k = $e.KeyCode
    $isPaste = ($e.Control -and -not $e.Alt -and $k -eq 'V') -or ($e.Shift -and -not $e.Control -and $k -eq 'Insert')
    $isCopy = ($e.Control -and -not $e.Alt -and ($k -eq 'C' -or $k -eq 'Insert'))
    $isCut = ($e.Control -and -not $e.Alt -and $k -eq 'X') -or ($e.Shift -and -not $e.Control -and $k -eq 'Delete')
    if ($isPaste) {
        $e.SuppressKeyPress = $true
        if (-not $Box.ReadOnly) { Invoke-PasteToInput }
    }
    elseif ($isCopy) {
        $e.SuppressKeyPress = $true
        Copy-Selection -Box $Box
    }
    elseif ($isCut -and $Box.SelectionLength -gt 0) {
        $e.SuppressKeyPress = $true
        Copy-Selection -Box $Box -Cut
    }
}

function Invoke-InputTextChanged {
    $S = $script:S
    if ($S.Suppress) { return }
    $buf = Get-Buffer
    if ($null -ne $buf.Result -and -not $buf.Dirty) {
        $buf.Dirty = $true
        Set-Highlight -Box $script:C.Input -Spans @()
        Set-Status '入力が変更されました。もう一度変換してください。' 'info'
    }
}

function Switch-Mode {
    param([ValidateSet('Mask', 'Restore')][string]$Mode)
    $S = $script:S
    if ($S.Mode -eq $Mode) { return }
    $prev = Get-Buffer
    $prev.InputText = $script:C.Input.Text
    $S.Mode = $Mode
    Update-ModeLabels
    Show-Buffer
    if ($Mode -eq 'Restore' -and $S.Session.Mappings.Count -eq 0) {
        Set-Status '対応表が空です。先にマスキングを行ってください。' 'warn'
    }
    elseif ($Mode -eq 'Restore') {
        Set-Status 'AI の回答を貼り付けて［復元］を押してください。' 'info'
    }
    else {
        Set-Status 'マスキングモード' 'info'
    }
}

function Select-MessageLocation {
    $C = $script:C
    $i = $C.Messages.SelectedIndex
    $msgs = @((Get-Buffer).Messages)
    if ($i -lt 0 -or $i -ge $msgs.Count) { return }
    $m = $msgs[$i]
    if ($m.Index -lt 0 -or $m.Index -gt $C.Input.TextLength) { return }
    $C.Input.Select($m.Index, [Math]::Max(0, $m.Length))
    $C.Input.ScrollToCaret()
    [void]$C.Input.Focus()
}

# ---------------------------------------------------------------------------
# 辞書の操作
# ---------------------------------------------------------------------------

function Get-GuessedCategory {
    param([string]$Text)
    $p = Find-MaskPattern $Text
    if ($p) { return $p }
    if ($Text -match '株式会社|有限会社|合同会社|合資会社|（株）|\(株\)|㈱|（有）|㈲|法人|協会|組合|機構|大学|銀行|グループ|ホールディングス|(?i:\b(inc|corp|co|ltd|llc|gmbh)\.?$)') { return 'COMPANY' }
    if ($Text -match '(支店|支社|本社|本店|営業所|事業所|工場|研究所|センター|都|道|府|県|市|区|町|村|駅)$') { return 'PLACE' }
    if ($Text -match 'プロジェクト|(?i:project)|PJ$') { return 'PROJECT' }
    return $script:S.Settings.lastCategory
}

function Find-Entry {
    param([string]$Original, $Exclude = $null)
    foreach ($e in $script:S.Profile.Entries) {
        if ($e.Original -ceq $Original -and -not [object]::ReferenceEquals($e, $Exclude)) { return @{ Type = 'persist'; Entry = $e } }
    }
    foreach ($e in $script:S.TempEntries) {
        if ($e.Original -ceq $Original -and -not [object]::ReferenceEquals($e, $Exclude)) { return @{ Type = 'temp'; Entry = $e } }
    }
    return $null
}

function Save-Profile {
    $S = $script:S
    if ($S.ProfileError) {
        [void](Show-Message "辞書ファイルに読み込みエラーがあるため保存できません。`nファイルを修正して［再読込］を押してください。`n`n$($S.Profile.Path)" 'Warning')
        return $false
    }
    try {
        [void](Export-TextMaskProfile -DataDirectory $S.DataDirectory -Name $S.ProfileName -Entries $S.Profile.Entries.ToArray())
        $S.Profile.Exists = $true
        return $true
    }
    catch {
        [void](Show-Message "辞書ファイルを保存できませんでした。`n`n$($S.Profile.Path)`n$($_.Exception.Message)" 'Error')
        return $false
    }
}

function Add-Entry {
    # $Request: Original / Category / Persistent
    param($Request)
    $S = $script:S
    $existing = Find-Entry -Original $Request.Original
    if ($existing) {
        $kind = if ($existing.Type -eq 'persist') { '永続' } else { '一時' }
        if (-not $existing.Entry.Enabled) {
            $existing.Entry.Enabled = $true
            if ($existing.Type -eq 'persist') { [void](Save-Profile) }
            Set-Status ('すでに{0}辞書に登録されていたため、有効にしました。' -f $kind) 'info'
        }
        else {
            Set-Status ('すでに{0}辞書に登録されています。' -f $kind) 'info'
        }
        Update-Grid
        return
    }
    $entry = New-TextMaskEntry -Original $Request.Original -Category $Request.Category
    if ($Request.Persistent -and $S.ProfileError) {
        $S.TempEntries.Add($entry)
        [void](Show-Message '辞書ファイルに読み込みエラーがあるため、一時辞書に登録しました。' 'Warning')
    }
    elseif ($Request.Persistent) {
        $S.Profile.Entries.Add($entry)
        if (-not (Save-Profile)) { [void]$S.Profile.Entries.Remove($entry); Update-Grid; return }
        Set-Status '永続辞書に登録しました。' 'ok'
    }
    else {
        $S.TempEntries.Add($entry)
        Set-Status '一時辞書に登録しました（このセッションのみ。保存しません）。' 'ok'
    }
    Update-Grid
}

function Show-EntryDialog {
    param([string]$Title, [string]$Original = '', [string]$Category = 'PERSON', [bool]$Persistent = $false)
    $cats = @(Get-TextMaskCategory)
    $f = [System.Windows.Forms.Form]::new()
    $f.Text = $Title
    $f.Font = $script:S.UiFont
    $f.FormBorderStyle = 'FixedDialog'
    $f.StartPosition = 'CenterParent'
    $f.MinimizeBox = $false
    $f.MaximizeBox = $false
    $f.ShowInTaskbar = $false
    $f.AutoSize = $true
    $f.AutoSizeMode = 'GrowAndShrink'
    $f.Padding = [System.Windows.Forms.Padding]::new(10)

    $t = [System.Windows.Forms.TableLayoutPanel]::new()
    $t.AutoSize = $true
    $t.ColumnCount = 2
    $t.Dock = 'Fill'

    $tb = [System.Windows.Forms.TextBox]::new()
    $tb.Width = [int](380 * $script:S.Scale)
    $tb.Text = $Original
    $cb = [System.Windows.Forms.ComboBox]::new()
    $cb.DropDownStyle = 'DropDownList'
    $cb.Width = [int](220 * $script:S.Scale)
    foreach ($cat in $cats) { [void]$cb.Items.Add(('{0}（{1}）' -f $cat.Label, $cat.Name)) }
    $idx = [Array]::IndexOf(@($cats.Name), $Category)
    $cb.SelectedIndex = [Math]::Max(0, $idx)

    $kind = [System.Windows.Forms.FlowLayoutPanel]::new()
    $kind.AutoSize = $true
    $kind.FlowDirection = 'TopDown'
    $rbTemp = [System.Windows.Forms.RadioButton]::new()
    $rbTemp.Text = '一時（このセッションのみ・ファイルに保存しない）'
    $rbTemp.AutoSize = $true
    $rbPersist = [System.Windows.Forms.RadioButton]::new()
    $rbPersist.Text = '永続（辞書ファイルに保存）'
    $rbPersist.AutoSize = $true
    $rbPersist.Checked = $Persistent
    $rbTemp.Checked = -not $Persistent
    $kind.Controls.AddRange(@($rbTemp, $rbPersist))

    $err = New-Label ''
    $err.ForeColor = $script:Colors.Error

    $buttons = [System.Windows.Forms.FlowLayoutPanel]::new()
    $buttons.AutoSize = $true
    $buttons.FlowDirection = 'RightToLeft'
    $buttons.Dock = 'Fill'
    $cancel = New-Button 'キャンセル'
    $cancel.DialogResult = 'Cancel'
    $ok = New-Button 'OK' { Invoke-UiAction { Confirm-EntryDialog } }
    $buttons.Controls.AddRange(@($cancel, $ok))

    $t.Controls.Add((New-Label '元の文字列'), 0, 0); $t.Controls.Add($tb, 1, 0)
    $t.Controls.Add((New-Label 'カテゴリ'), 0, 1); $t.Controls.Add($cb, 1, 1)
    $t.Controls.Add((New-Label '種別'), 0, 2); $t.Controls.Add($kind, 1, 2)
    $t.Controls.Add($err, 0, 3); $t.SetColumnSpan($err, 2)
    $t.Controls.Add($buttons, 0, 4); $t.SetColumnSpan($buttons, 2)
    $f.Controls.Add($t)
    $f.AcceptButton = $ok
    $f.CancelButton = $cancel

    $script:D = @{ Form = $f; Original = $tb; Category = $cb; Persist = $rbPersist; Error = $err }
    try {
        if ($script:ThrowUiErrors) { throw '[ダイアログ表示を抑止] 辞書登録ダイアログ' }
        if ($f.ShowDialog($script:C.Form) -ne 'OK') { return $null }
        return [pscustomobject]@{
            Original   = $tb.Text.Trim()
            Category   = $cats[$cb.SelectedIndex].Name
            Persistent = $rbPersist.Checked
        }
    }
    finally {
        $script:D = $null
        $f.Dispose()
    }
}

function Confirm-EntryDialog {
    $D = $script:D
    $v = $D.Original.Text.Trim()
    $problem = $null
    if ($v.Length -eq 0) { $problem = '元の文字列を入力してください。' }
    elseif ($v.Contains([char]10) -or $v.Contains([char]13)) { $problem = '改行を含む文字列は登録できません。' }
    elseif (Test-MaskToken $v) { $problem = '識別子と同じ形式（[[NAME_01]]）を含む文字列は登録できません。' }
    if ($problem) {
        $D.Error.Text = $problem
        [void]$D.Original.Focus()
        return
    }
    $D.Form.DialogResult = 'OK'
}

function Invoke-AddEntry {
    param([string]$Original = '')
    $S = $script:S
    $cat = if ($Original) { Get-GuessedCategory $Original } else { $S.Settings.lastCategory }
    $r = Show-EntryDialog -Title '辞書に登録' -Original $Original -Category $cat -Persistent ([bool]$S.Settings.lastPersistent)
    if (-not $r) { return }
    $S.Settings.lastCategory = $r.Category
    $S.Settings.lastPersistent = $r.Persistent
    Add-Entry $r
    Invoke-AutoReconvert
}

function Invoke-RegisterSelection {
    $S = $script:S
    if ($S.Mode -ne 'Mask') {
        Set-Status '辞書への登録はマスキングモードで行います。' 'warn'; return
    }
    $sel = $script:C.Input.SelectedText.Trim()
    if ($sel.Length -eq 0) {
        Set-Status '登録したい文字列を入力欄で選択してから押してください。' 'warn'; return
    }
    if ($sel.Contains([char]10)) {
        Set-Status '改行を含む範囲は登録できません。1 行の中で選択してください。' 'warn'; return
    }
    Invoke-AddEntry -Original $sel
}

function Get-SelectedRowTag {
    $row = $script:C.Grid.CurrentRow
    if ($null -eq $row -or $null -eq $row.Tag) {
        Set-Status '辞書の行を選択してください。' 'warn'
        return $null
    }
    return $row.Tag
}

function Invoke-EditEntry {
    $S = $script:S
    $tag = Get-SelectedRowTag
    if (-not $tag) { return }
    if ($tag.Type -notin @('persist', 'temp')) {
        Set-Status '自動検出・対応表の行は編集できません（チェックで有効 / 除外を切り替えられます）。' 'warn'; return
    }
    $e = $tag.Entry
    $r = Show-EntryDialog -Title '辞書項目の編集' -Original $e.Original -Category $e.Category -Persistent ($tag.Type -eq 'persist')
    if (-not $r) { return }
    if (Find-Entry -Original $r.Original -Exclude $e) {
        [void](Show-Message '同じ文字列がすでに登録されています。' 'Warning'); return
    }
    if ($r.Persistent -and $S.ProfileError) {
        [void](Show-Message '辞書ファイルに読み込みエラーがあるため、永続辞書は変更できません。' 'Warning'); return
    }
    $old = @{ Original = $e.Original; Category = $e.Category }
    $e.Original = $r.Original
    $e.Category = $r.Category
    $wasPersist = ($tag.Type -eq 'persist')
    if ($wasPersist -and -not $r.Persistent) {
        [void]$S.Profile.Entries.Remove($e); $S.TempEntries.Add($e)
    }
    elseif (-not $wasPersist -and $r.Persistent) {
        [void]$S.TempEntries.Remove($e); $S.Profile.Entries.Add($e)
    }
    if ($wasPersist -or $r.Persistent) {
        if (-not (Save-Profile)) {
            # 保存に失敗したら元に戻す
            $e.Original = $old.Original; $e.Category = $old.Category
            if ($wasPersist -and -not $r.Persistent) { [void]$S.TempEntries.Remove($e); $S.Profile.Entries.Add($e) }
            elseif (-not $wasPersist -and $r.Persistent) { [void]$S.Profile.Entries.Remove($e); $S.TempEntries.Add($e) }
        }
    }
    Update-Grid
    Invoke-AutoReconvert
}

function Invoke-RemoveEntry {
    $S = $script:S
    $tag = Get-SelectedRowTag
    if (-not $tag) { return }
    switch ($tag.Type) {
        'persist' {
            $ans = Show-Message ("「{0}」を永続辞書（ファイル）から削除しますか？" -f $tag.Original) 'Question' 'YesNo'
            if ($ans -ne 'Yes') { return }
            $i = $S.Profile.Entries.IndexOf($tag.Entry)
            [void]$S.Profile.Entries.Remove($tag.Entry)
            if (-not (Save-Profile)) { $S.Profile.Entries.Insert($i, $tag.Entry) }
            else { Set-Status '永続辞書から削除しました（発行済みの対応表は残るので、送信済みの文章は復元できます）。' 'ok' }
        }
        'temp' {
            [void]$S.TempEntries.Remove($tag.Entry)
            Set-Status '一時辞書から削除しました（発行済みの対応表は残ります）。' 'ok'
        }
        'detected' {
            [void]$S.Session.ExcludedValues.Add($tag.Original)
            Set-Status '自動検出から除外しました（チェックを入れると戻せます）。' 'ok'
        }
        default {
            Set-Status '対応表の行は削除できません（［新しいセッション］で破棄されます）。' 'warn'
            return
        }
    }
    Update-Grid
    Invoke-AutoReconvert
}

function Invoke-GridValueChanged {
    param($e)
    $S = $script:S
    if ($S.GridUpdating -or $e.RowIndex -lt 0 -or $e.ColumnIndex -ne 0) { return }
    $row = $script:C.Grid.Rows[$e.RowIndex]
    $tag = $row.Tag
    if ($null -eq $tag) { return }
    $value = [bool]$row.Cells[0].Value
    switch ($tag.Type) {
        'persist' {
            $tag.Entry.Enabled = $value
            if (-not (Save-Profile)) { $tag.Entry.Enabled = -not $value }
        }
        'temp' { $tag.Entry.Enabled = $value }
        'detected' {
            if ($value) { [void]$S.Session.ExcludedValues.Remove($tag.Original) }
            else { [void]$S.Session.ExcludedValues.Add($tag.Original) }
        }
        default { return }
    }
    $tag.Enabled = $value
    # CellValueChanged の中で行を作り直すと編集中のセルと衝突するので、後で反映する
    $script:C.Form.BeginInvoke([Action] { Invoke-UiAction { Update-Grid; Invoke-AutoReconvert } }) | Out-Null
}

# ---------------------------------------------------------------------------
# プロファイル・セッション
# ---------------------------------------------------------------------------

function Import-ProfileIntoState {
    param([string]$Name)
    $S = $script:S
    $p = Import-TextMaskProfile -DataDirectory $S.DataDirectory -Name $Name
    $S.Profile = $p
    $S.ProfileName = $Name
    $S.ProfileError = $p.Error
    $S.Settings.lastProfile = $Name
    if ($p.Error) {
        $S.PendingNotice = "辞書ファイルを読み込めませんでした。`n`n$($p.Path)`n`n$($p.Error)`n`nファイルを修正して［再読込］を押すまで、このプロファイルの永続辞書は使用・保存されません。"
    }
    elseif ($p.Warnings.Count -gt 0) {
        $S.PendingNotice = "辞書ファイルに注意点があります。`n`n" + (@($p.Warnings | Select-Object -First 5) -join "`n")
    }
}

function Show-PendingNotice {
    $S = $script:S
    if ($S.PendingNotice -and $script:C.Form.Visible) {
        $n = $S.PendingNotice
        $S.PendingNotice = $null
        $icon = if ($S.ProfileError) { 'Warning' } else { 'Information' }
        [void](Show-Message $n $icon)
    }
}

function Invoke-ProfileChanged {
    $S = $script:S
    if ($S.Loading) { return }
    $name = [string]$script:C.Profile.SelectedItem
    if (-not $name -or $name -eq $S.ProfileName) { return }
    Import-ProfileIntoState -Name $name
    Update-Grid
    Show-PendingNotice
    Set-Status ('プロファイル「{0}」を読み込みました。' -f $name) 'info'
    Invoke-AutoReconvert
}

function Update-ProfileList {
    param([string]$Select)
    $S = $script:S; $C = $script:C
    $S.Loading = $true
    try {
        $C.Profile.Items.Clear()
        $names = @(Get-TextMaskProfileList -DataDirectory $S.DataDirectory)
        if ($Select -and $names -notcontains $Select) { $names += $Select }
        foreach ($n in $names) { [void]$C.Profile.Items.Add($n) }
        $C.Profile.SelectedItem = $Select
    }
    finally { $S.Loading = $false }
}

function Invoke-NewProfile {
    $S = $script:S
    $name = Show-InputDialog -Title '新しいプロファイル' -Prompt 'プロファイル名（英数字・_・- のみ。例: work, research）'
    if ($null -eq $name) { return }
    $name = $name.Trim()
    if (-not (Test-TextMaskProfileName $name)) {
        [void](Show-Message 'プロファイル名には英数字・_・- だけを使ってください（40 文字以内）。' 'Warning'); return
    }
    $path = Get-TextMaskProfilePath -DataDirectory $S.DataDirectory -Name $name
    if (-not (Test-Path -LiteralPath $path)) {
        try { [void](Export-TextMaskProfile -DataDirectory $S.DataDirectory -Name $name -Entries @()) }
        catch { [void](Show-Message "プロファイルを作成できませんでした。`n$($_.Exception.Message)" 'Error'); return }
    }
    Update-ProfileList -Select $name
    Import-ProfileIntoState -Name $name
    Update-Grid
    Show-PendingNotice
    Set-Status ('プロファイル「{0}」に切り替えました。' -f $name) 'ok'
    Invoke-AutoReconvert
}

function Show-InputDialog {
    param([string]$Title, [string]$Prompt)
    $f = [System.Windows.Forms.Form]::new()
    $f.Text = $Title
    $f.Font = $script:S.UiFont
    $f.FormBorderStyle = 'FixedDialog'
    $f.StartPosition = 'CenterParent'
    $f.MinimizeBox = $false; $f.MaximizeBox = $false; $f.ShowInTaskbar = $false
    $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'
    $f.Padding = [System.Windows.Forms.Padding]::new(10)
    $t = [System.Windows.Forms.TableLayoutPanel]::new()
    $t.AutoSize = $true; $t.ColumnCount = 1; $t.Dock = 'Fill'
    $tb = [System.Windows.Forms.TextBox]::new()
    $tb.Width = [int](320 * $script:S.Scale)
    $buttons = [System.Windows.Forms.FlowLayoutPanel]::new()
    $buttons.AutoSize = $true; $buttons.FlowDirection = 'RightToLeft'; $buttons.Dock = 'Fill'
    $cancel = New-Button 'キャンセル'; $cancel.DialogResult = 'Cancel'
    $ok = New-Button 'OK'; $ok.DialogResult = 'OK'
    $buttons.Controls.AddRange(@($cancel, $ok))
    $t.Controls.Add((New-Label $Prompt), 0, 0)
    $t.Controls.Add($tb, 0, 1)
    $t.Controls.Add($buttons, 0, 2)
    $f.Controls.Add($t)
    $f.AcceptButton = $ok; $f.CancelButton = $cancel
    try {
        if ($script:ThrowUiErrors) { throw '[ダイアログ表示を抑止] 入力ダイアログ' }
        if ($f.ShowDialog($script:C.Form) -ne 'OK') { return $null }
        return $tb.Text
    }
    finally { $f.Dispose() }
}

function Invoke-ReloadProfile {
    $S = $script:S
    Import-ProfileIntoState -Name $S.ProfileName
    Update-Grid
    Show-PendingNotice
    if (-not $S.ProfileError) { Set-Status '辞書ファイルを再読み込みしました。' 'ok' }
    Invoke-AutoReconvert
}

function Open-DataFolder {
    $dir = Join-Path $script:S.DataDirectory 'profiles'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $dir)
}

function Reset-Session {
    $S = $script:S; $C = $script:C
    $n = $S.Session.Mappings.Count
    if ($n -gt 0 -or $S.TempEntries.Count -gt 0) {
        $head = if ($S.Session.HasUnrestored) { "マスキングした文章をまだ復元していません。`n`n" } else { '' }
        $msg = $head + ("現在の対応表（{0} 件）と一時辞書（{1} 件）を破棄して、新しいセッションを開始しますか？`n破棄すると、これまでに AI へ送った文章は復元できなくなります。" -f $n, $S.TempEntries.Count)
        if ((Show-Message $msg 'Warning' 'YesNo') -ne 'Yes') { return }
    }
    Reset-MaskSession -Session $S.Session
    $S.TempEntries.Clear()
    $S.LastMaskedSource = $null
    $S.Buffers = @{ Mask = (New-Buffer); Restore = (New-Buffer) }
    Show-Buffer
    Update-Grid
    Set-Status '新しいセッションを開始しました（対応表と一時辞書を破棄）。クリップボードの内容は消えていません。' 'ok'
}

function Invoke-ClearClipboard {
    try { Clear-TextMaskClipboard }
    catch { Set-Status $_.Exception.Message 'error'; return }
    Set-Status 'クリップボードを消去しました（Windows のクリップボード履歴に残った項目は Win+V から削除してください）。' 'ok'
}

function Invoke-ClearInput {
    $script:C.Input.Clear()
    [void]$script:C.Input.Focus()
}

# ---------------------------------------------------------------------------
# フォーム全体のイベント
# ---------------------------------------------------------------------------

function Invoke-FormKeyDown {
    param([System.Windows.Forms.KeyEventArgs]$e)
    $C = $script:C
    if ($e.Control -and -not $e.Alt -and -not $e.Shift -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $e.SuppressKeyPress = $true
        Invoke-ConvertAndCopy
    }
    elseif ($e.Control -and -not $e.Alt -and -not $e.Shift -and $e.KeyCode -eq [System.Windows.Forms.Keys]::D) {
        $e.SuppressKeyPress = $true
        Invoke-RegisterSelection
    }
    elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and $e.Modifiers -eq 'None') {
        if ($C.Profile.DroppedDown -or $C.Grid.IsCurrentCellInEditMode) { return }
        $e.SuppressKeyPress = $true
        $C.Form.Close()
    }
}

function Invoke-FormClosing {
    param([System.Windows.Forms.FormClosingEventArgs]$e)
    $S = $script:S; $C = $script:C
    if ($S.Session.HasUnrestored) {
        $msg = "マスキングした文章をまだ復元していません。`n終了すると対応表が失われ、AI の回答を元に戻せなくなります。`n`n終了しますか？"
        if ((Show-Message $msg 'Warning' 'YesNo') -ne 'Yes') { $e.Cancel = $true; return }
    }
    $st = $S.Settings
    if ($C.Form.WindowState -eq 'Normal') {
        $st.windowWidth = [int]($C.Form.Width / $S.Scale)
        $st.windowHeight = [int]($C.Form.Height / $S.Scale)
    }
    $st.detectPatterns = $C.Detect.Checked
    $st.attachPrompt = $C.Prompt.Checked
    try { Export-TextMaskSettings -DataDirectory $S.DataDirectory -Settings $st } catch { }
}

function Invoke-FormShown {
    $C = $script:C
    $C.Form.Activate()
    try {
        $C.MainSplit.SplitterDistance = [int]($C.MainSplit.Height * 0.66)
        $C.TextSplit.SplitterDistance = [int]($C.TextSplit.Width / 2)
    }
    catch { }
    [void]$C.Input.Focus()
    Show-PendingNotice
}

# ---------------------------------------------------------------------------
# フォームの組み立て
# ---------------------------------------------------------------------------

function New-TextMaskForm {
    <#
    .SYNOPSIS
        メインウィンドウを組み立てて返す（表示はしない）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataDirectory,
        [string]$ProfileName,
        [AllowNull()][string]$InitialText
    )

    $settings = Import-TextMaskSettings -DataDirectory $DataDirectory
    if (-not $ProfileName) { $ProfileName = $settings.lastProfile }
    if (-not (Test-TextMaskProfileName $ProfileName)) {
        throw ('プロファイル名が不正です（英数字・_・- のみ）: {0}' -f $ProfileName)
    }

    $scale = 1.0
    try {
        $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        $scale = [Math]::Max(1.0, $g.DpiX / 96.0)
        $g.Dispose()
    }
    catch { }

    $script:S = @{
        DataDirectory    = $DataDirectory
        Settings         = $settings
        ProfileName      = $ProfileName
        Profile          = $null
        ProfileError     = $null
        PendingNotice    = $null
        TempEntries      = [System.Collections.Generic.List[object]]::new()
        Session          = New-MaskSession -ProfileName $ProfileName
        Mode             = 'Mask'
        Buffers          = @{ Mask = (New-Buffer); Restore = (New-Buffer) }
        LastMaskedSource = $null
        Suppress         = $false
        Loading          = $false
        GridUpdating     = $false
        Scale            = $scale
        UiFont           = [System.Drawing.Font]::new('Meiryo UI', 10)
        TextFont         = [System.Drawing.Font]::new('Meiryo UI', 11)
    }
    $script:C = @{}
    $S = $script:S; $C = $script:C

    # --- フォーム ---
    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'TextMask - ローカル文章マスキング'
    $form.Font = $S.UiFont
    $form.StartPosition = 'CenterScreen'
    $form.KeyPreview = $true
    # 保存したサイズ（既定 1000x720、96 DPI 換算）を DPI に合わせ、作業領域の 90% を超えないようにする
    $area = [System.Drawing.Rectangle]::new(0, 0, 1280, 800)
    try { $area = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea } catch { }
    $maxW = [int]($area.Width * 0.9)
    $maxH = [int]($area.Height * 0.9)
    $minW = [Math]::Min([int](720 * $scale), $maxW)
    $minH = [Math]::Min([int](520 * $scale), $maxH)
    $w = [Math]::Max($minW, [Math]::Min([int]($settings.windowWidth * $scale), $maxW))
    $h = [Math]::Max($minH, [Math]::Min([int]($settings.windowHeight * $scale), $maxH))
    $form.MinimumSize = [System.Drawing.Size]::new($minW, $minH)
    $form.Size = [System.Drawing.Size]::new($w, $h)
    $C.Form = $form

    $root = [System.Windows.Forms.TableLayoutPanel]::new()
    $root.Dock = 'Fill'
    $root.ColumnCount = 1
    $root.RowCount = 2
    [void]$root.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize'))
    [void]$root.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Percent', 100))

    # --- 上段: モード・プロファイル・オプション ---
    $top = [System.Windows.Forms.FlowLayoutPanel]::new()
    $top.Dock = 'Fill'
    $top.AutoSize = $true
    $top.WrapContents = $true
    $top.Padding = [System.Windows.Forms.Padding]::new(4, 4, 4, 0)

    $rbMask = [System.Windows.Forms.RadioButton]::new()
    $rbMask.Text = 'マスキング'
    $rbMask.Appearance = 'Button'
    $rbMask.AutoSize = $true
    $rbMask.Padding = [System.Windows.Forms.Padding]::new(10, 2, 10, 2)
    $rbMask.Checked = $true
    $rbRestore = [System.Windows.Forms.RadioButton]::new()
    $rbRestore.Text = '復元'
    $rbRestore.Appearance = 'Button'
    $rbRestore.AutoSize = $true
    $rbRestore.Padding = [System.Windows.Forms.Padding]::new(10, 2, 10, 2)
    $rbMask.Add_CheckedChanged({ if ($script:C.MaskMode.Checked) { Invoke-UiAction { Switch-Mode 'Mask' } } })
    $rbRestore.Add_CheckedChanged({ if ($script:C.RestoreMode.Checked) { Invoke-UiAction { Switch-Mode 'Restore' } } })
    $C.MaskMode = $rbMask
    $C.RestoreMode = $rbRestore

    $cbProfile = [System.Windows.Forms.ComboBox]::new()
    $cbProfile.DropDownStyle = 'DropDownList'
    $cbProfile.Width = [int](140 * $scale)
    $cbProfile.Margin = [System.Windows.Forms.Padding]::new(3, 5, 3, 3)
    $cbProfile.Add_SelectedIndexChanged({ Invoke-UiAction { Invoke-ProfileChanged } })
    $C.Profile = $cbProfile

    $chkDetect = [System.Windows.Forms.CheckBox]::new()
    $chkDetect.Text = 'メール・電話番号を自動検出'
    $chkDetect.AutoSize = $true
    $chkDetect.Margin = [System.Windows.Forms.Padding]::new(12, 7, 3, 3)
    $chkDetect.Checked = [bool]$settings.detectPatterns
    $chkDetect.Add_CheckedChanged({ Invoke-UiAction { Invoke-AutoReconvert } })
    $C.Detect = $chkDetect

    $chkPrompt = [System.Windows.Forms.CheckBox]::new()
    $chkPrompt.Text = '添削指示を付加'
    $chkPrompt.AutoSize = $true
    $chkPrompt.Margin = [System.Windows.Forms.Padding]::new(6, 7, 3, 3)
    $chkPrompt.Checked = [bool]$settings.attachPrompt
    $chkPrompt.Add_CheckedChanged({ Invoke-UiAction { Invoke-AutoReconvert } })
    $C.Prompt = $chkPrompt

    $lblSession = New-Label 'セッション: 対応表 0 件'
    $lblSession.Margin = [System.Windows.Forms.Padding]::new(12, 8, 3, 3)
    $C.SessionLabel = $lblSession

    $top.Controls.AddRange(@(
            $rbMask, $rbRestore,
            (New-Label '  プロファイル:'), $cbProfile,
            (New-Button '新規...' { Invoke-UiAction { Invoke-NewProfile } }),
            $chkDetect, $chkPrompt,
            (New-Button '新しいセッション' { Invoke-UiAction { Reset-Session } }),
            (New-Button 'クリップボード消去' { Invoke-UiAction { Invoke-ClearClipboard } }),
            $lblSession
        ))

    # --- 中段: 入力・出力・警告・ボタン ---
    $mainSplit = [System.Windows.Forms.SplitContainer]::new()
    $mainSplit.Dock = 'Fill'
    $mainSplit.Orientation = 'Horizontal'
    $mainSplit.SplitterWidth = 6
    $C.MainSplit = $mainSplit

    $upper = [System.Windows.Forms.TableLayoutPanel]::new()
    $upper.Dock = 'Fill'
    $upper.ColumnCount = 1
    $upper.RowCount = 3
    # 行: 入力・出力 / ボタン / 警告・エラー
    [void]$upper.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Percent', 100))
    [void]$upper.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize'))
    [void]$upper.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', [int](100 * $scale)))

    $textSplit = [System.Windows.Forms.SplitContainer]::new()
    $textSplit.Dock = 'Fill'
    $textSplit.Orientation = 'Vertical'
    $textSplit.SplitterWidth = 6
    $C.TextSplit = $textSplit

    $rtbIn = New-TextBoxPane -ReadOnly $false
    $rtbOut = New-TextBoxPane -ReadOnly $true
    $C.Input = $rtbIn
    $C.Output = $rtbOut
    $rtbIn.Add_KeyDown({ param($s, $e) Invoke-UiAction { param($ev) Invoke-TextBoxKeyDown -Box $script:C.Input -e $ev } $e })
    $rtbOut.Add_KeyDown({ param($s, $e) Invoke-UiAction { param($ev) Invoke-TextBoxKeyDown -Box $script:C.Output -e $ev } $e })
    $rtbIn.Add_TextChanged({ Invoke-UiAction { Invoke-InputTextChanged } })

    foreach ($pane in @(
            @{ Panel = $textSplit.Panel1; Box = $rtbIn; Key = 'InputLabel' },
            @{ Panel = $textSplit.Panel2; Box = $rtbOut; Key = 'OutputLabel' })) {
        $t = [System.Windows.Forms.TableLayoutPanel]::new()
        $t.Dock = 'Fill'
        $t.ColumnCount = 1
        $t.RowCount = 2
        [void]$t.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize'))
        [void]$t.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Percent', 100))
        $lbl = New-Label '' -Bold
        $lbl.Margin = [System.Windows.Forms.Padding]::new(3, 4, 3, 2)
        $C[$pane.Key] = $lbl
        $t.Controls.Add($lbl, 0, 0)
        $t.Controls.Add($pane.Box, 0, 1)
        $pane.Panel.Controls.Add($t)
    }

    # 右クリックメニュー
    $menuIn = [System.Windows.Forms.ContextMenuStrip]::new()
    [void]$menuIn.Items.Add('切り取り', $null, { Invoke-UiAction { Copy-Selection -Box $script:C.Input -Cut } })
    [void]$menuIn.Items.Add('コピー', $null, { Invoke-UiAction { Copy-Selection -Box $script:C.Input } })
    [void]$menuIn.Items.Add('貼り付け', $null, { Invoke-UiAction { Invoke-PasteToInput } })
    [void]$menuIn.Items.Add('すべて選択', $null, { $script:C.Input.SelectAll() })
    [void]$menuIn.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    [void]$menuIn.Items.Add('選択範囲を辞書に登録 (Ctrl+D)', $null, { Invoke-UiAction { Invoke-RegisterSelection } })
    $rtbIn.ContextMenuStrip = $menuIn
    $menuOut = [System.Windows.Forms.ContextMenuStrip]::new()
    [void]$menuOut.Items.Add('コピー', $null, { Invoke-UiAction { Copy-Selection -Box $script:C.Output } })
    [void]$menuOut.Items.Add('すべて選択', $null, { $script:C.Output.SelectAll() })
    $rtbOut.ContextMenuStrip = $menuOut

    $grpMsg = [System.Windows.Forms.GroupBox]::new()
    $grpMsg.Dock = 'Fill'
    $grpMsg.Text = '警告・エラー（なし）'
    $lbMsg = [System.Windows.Forms.ListBox]::new()
    $lbMsg.Dock = 'Fill'
    $lbMsg.HorizontalScrollbar = $true
    $lbMsg.IntegralHeight = $false
    $lbMsg.ForeColor = $script:Colors.Warn
    $lbMsg.Add_DoubleClick({ Invoke-UiAction { Select-MessageLocation } })
    $grpMsg.Controls.Add($lbMsg)
    $C.Messages = $lbMsg
    $C.MessagesGroup = $grpMsg

    $btnRow = [System.Windows.Forms.FlowLayoutPanel]::new()
    $btnRow.Dock = 'Fill'
    $btnRow.AutoSize = $true
    $btnRow.WrapContents = $true
    $C.Register = New-Button '選択範囲を登録 (Ctrl+D)' { Invoke-UiAction { Invoke-RegisterSelection } }
    $C.Convert = New-Button 'マスキング' { Invoke-UiAction { [void](Invoke-Convert) } }
    $C.ConvertCopy = New-Button 'マスキングしてコピー (Ctrl+Enter)' { Invoke-UiAction { Invoke-ConvertAndCopy } }
    $C.ConvertCopy.Font = [System.Drawing.Font]::new($S.UiFont, [System.Drawing.FontStyle]::Bold)
    $spacer = [System.Windows.Forms.Label]::new()
    $spacer.Width = [int](24 * $scale)
    $btnRow.Controls.AddRange(@(
            (New-Button '貼り付け' { Invoke-UiAction { Invoke-PasteToInput -ReplaceAll } }),
            $C.Register,
            (New-Button 'クリア' { Invoke-UiAction { Invoke-ClearInput } }),
            $spacer,
            $C.Convert,
            $C.ConvertCopy,
            (New-Button '結果をコピー' { Invoke-UiAction { Copy-Output } })
        ))

    $upper.Controls.Add($textSplit, 0, 0)
    $upper.Controls.Add($btnRow, 0, 1)
    $upper.Controls.Add($grpMsg, 0, 2)
    $mainSplit.Panel1.Controls.Add($upper)

    # --- 下段: 辞書 ---
    $lower = [System.Windows.Forms.TableLayoutPanel]::new()
    $lower.Dock = 'Fill'
    $lower.ColumnCount = 1
    $lower.RowCount = 2
    [void]$lower.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize'))
    [void]$lower.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Percent', 100))
    $dictBar = [System.Windows.Forms.FlowLayoutPanel]::new()
    $dictBar.Dock = 'Fill'
    $dictBar.AutoSize = $true
    $C.DictLabel = New-Label '辞書' -Bold
    $dictBar.Controls.AddRange(@(
            $C.DictLabel,
            (New-Button '追加...' { Invoke-UiAction { Invoke-AddEntry } }),
            (New-Button '編集...' { Invoke-UiAction { Invoke-EditEntry } }),
            (New-Button '削除 / 除外' { Invoke-UiAction { Invoke-RemoveEntry } }),
            (New-Button '再読込' { Invoke-UiAction { Invoke-ReloadProfile } }),
            (New-Button 'フォルダを開く' { Invoke-UiAction { Open-DataFolder } })
        ))

    $grid = [System.Windows.Forms.DataGridView]::new()
    $grid.Dock = 'Fill'
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.ColumnHeadersHeightSizeMode = 'AutoSize'
    $colEnabled = [System.Windows.Forms.DataGridViewCheckBoxColumn]::new()
    $colEnabled.HeaderText = '有効'
    $colEnabled.FillWeight = 7
    [void]$grid.Columns.Add($colEnabled)
    foreach ($col in @(
            @{ H = '元の文字列'; W = 40 },
            @{ H = 'カテゴリ'; W = 14 },
            @{ H = '種別'; W = 11 },
            @{ H = '置換文字列'; W = 18 },
            @{ H = '出現件数'; W = 9 })) {
        $column = [System.Windows.Forms.DataGridViewTextBoxColumn]::new()
        $column.HeaderText = $col.H
        $column.FillWeight = $col.W
        $column.ReadOnly = $true
        $column.SortMode = 'NotSortable'
        [void]$grid.Columns.Add($column)
    }
    $colEnabled.SortMode = 'NotSortable'
    $grid.Add_CurrentCellDirtyStateChanged({
            if ($script:C.Grid.IsCurrentCellDirty) { [void]$script:C.Grid.CommitEdit('CurrentCellChange') }
        })
    $grid.Add_CellValueChanged({ param($s, $e) Invoke-UiAction { param($ev) Invoke-GridValueChanged $ev } $e })
    $grid.Add_CellDoubleClick({ param($s, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -ne 0) { Invoke-UiAction { Invoke-EditEntry } } })
    $grid.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) { $e.Handled = $true; Invoke-UiAction { Invoke-RemoveEntry } }
        })
    $C.Grid = $grid

    $lower.Controls.Add($dictBar, 0, 0)
    $lower.Controls.Add($grid, 0, 1)
    $mainSplit.Panel2.Controls.Add($lower)

    $root.Controls.Add($top, 0, 0)
    $root.Controls.Add($mainSplit, 0, 1)

    # --- ステータスバー ---
    $status = [System.Windows.Forms.StatusStrip]::new()
    $status.SizingGrip = $true
    $lblLocal = [System.Windows.Forms.ToolStripStatusLabel]::new('ローカル処理のみ（通信なし）')
    $lblLocal.ForeColor = [System.Drawing.SystemColors]::GrayText
    $lblStatus = [System.Windows.Forms.ToolStripStatusLabel]::new('')
    $lblStatus.Spring = $true
    $lblStatus.TextAlign = 'MiddleLeft'
    [void]$status.Items.Add($lblLocal)
    [void]$status.Items.Add($lblStatus)
    $C.Status = $lblStatus

    # Fill を先に追加し、StatusStrip を後から追加する（後から追加した方が先にドッキングされる）
    $form.Controls.Add($root)
    $form.Controls.Add($status)

    $form.Add_KeyDown({ param($s, $e) Invoke-UiAction { param($ev) Invoke-FormKeyDown $ev } $e })
    $form.Add_FormClosing({ param($s, $e) Invoke-UiAction { param($ev) Invoke-FormClosing $ev } $e })
    $form.Add_Shown({ Invoke-UiAction { Invoke-FormShown } })

    # --- 初期状態 ---
    Update-ProfileList -Select $ProfileName
    Import-ProfileIntoState -Name $ProfileName
    Update-ModeLabels
    if ($InitialText) {
        $buf = Get-Buffer 'Mask'
        $buf.Crlf = $InitialText.Contains("`r`n") -or -not $InitialText.Contains("`n")
        $buf.InputText = $InitialText.Replace("`r`n", "`n").Replace("`r", "`n")
    }
    Show-Buffer
    Update-Grid
    Set-Status 'マスキングする文章を貼り付けて、辞書に置換対象を登録してください。' 'info'
    return $form
}

function Show-TextMaskWindow {
    <#
    .SYNOPSIS
        メインウィンドウを表示し、閉じるまで待つ。閉じたら状態を破棄する。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataDirectory,
        [string]$ProfileName,
        [AllowNull()][string]$InitialText
    )
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
    try { [void][System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2) } catch { }

    $form = New-TextMaskForm @PSBoundParameters
    try {
        [void]$form.ShowDialog()
    }
    finally {
        $form.Dispose()
        $script:S = $null
        $script:C = $null
        $script:D = $null
        [GC]::Collect()
    }
}

Export-ModuleMember -Function New-TextMaskForm, Show-TextMaskWindow
