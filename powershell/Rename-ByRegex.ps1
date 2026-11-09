#Requires -Version 5.1
<#
.SYNOPSIS
    正規表現でファイル名を対話的に一括リネームする。

.DESCRIPTION
    処理は次の 3 ステップで進みます。

      1. 正規表現を入力する（決定時に構文チェック）
      2. マッチしたファイルが一覧表示され、該当部分がハイライトされる
      3. 置換文字列を入力する（$1 などのキャプチャ参照が使える）
         → 「変更前 -> 変更後」のレビューが表示され、Enter で実行

    各ステップで r = 再入力 / q = 中止 が選べます。
    実行内容は JSON ログに保存され、Undo-RenameLog.ps1 で元に戻せます。

    使い方と正規表現チートシートを並べたヘルプ画面を内蔵しています。
    -Help で単独表示、正規表現の入力時は ? 、各確認プロンプトでは h で開けます。
    ヘルプ画面は ← → でタブを切り替え、本文は less と同じ感覚で読めます。
      ↑ ↓ / j k      1 行スクロール
      f b / Space    1 画面スクロール（Ctrl+F / Ctrl+B も可）
      d u            半画面スクロール
      g G / Home End 先頭 / 末尾
      q / Esc        閉じる

.PARAMETER Path
    対象ディレクトリ。既定はカレントディレクトリ。

.PARAMETER Filter
    Get-ChildItem に渡すワイルドカードの事前絞り込み。既定は *。

.PARAMETER Recurse
    サブディレクトリも対象にする。

.PARAMETER IncludeDirectory
    ディレクトリ名もリネーム対象に含める。

.PARAMETER CaseSensitive
    正規表現を大文字小文字を区別して適用する（既定は区別しない）。

.PARAMETER Pattern
    正規表現を対話入力せずに指定する。指定しても一覧確認は行われる。

.PARAMETER Replacement
    置換文字列を対話入力せずに指定する。指定してもレビュー確認は行われる。

.PARAMETER NoLog
    Undo 用ログを書き出さない。

.PARAMETER LogDirectory
    Undo 用ログの出力先。既定は data/rename-by-regex/logs
    （スクリプトの 2 階層上にある data ディレクトリ。ssh-list.ps1 と共通）。

.PARAMETER Help
    リネームを始めず、ヘルプ画面（使い方 / 正規表現チートシート）だけを表示する。

.EXAMPLE
    .\Rename-ByRegex.ps1

.EXAMPLE
    .\Rename-ByRegex.ps1 -Pattern '^document_(\w)$' -Replacement 'doc-$1' -Recurse

.EXAMPLE
    .\Rename-ByRegex.ps1 -WhatIf

.EXAMPLE
    .\Rename-ByRegex.ps1 -Help
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$Path = '.',
    [string]$Filter = '*',
    [switch]$Recurse,
    [switch]$IncludeDirectory,
    [switch]$CaseSensitive,
    [string]$Pattern,
    [string]$Replacement,
    [switch]$NoLog,
    [string]$LogDirectory,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region 表示ヘルパー

$script:Palette = @{
    Hit   = @{ ForegroundColor = 'Black';    BackgroundColor = 'Yellow' }
    New   = @{ ForegroundColor = 'Black';    BackgroundColor = 'Green'  }
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

function Write-Banner {
    Write-Host ''
    Write-Tagged '  Rename-ByRegex  -  正規表現によるファイル名の一括リネーム' 'Head'
}

# 半角のみで構成されているか（キャレット行の桁がずれないかの判定用）
function Test-SingleWidth {
    param([string]$Text)
    return ($Text -cmatch '^[\x20-\x7E]*$')
}

# 文字列を、指定区間だけ強調色にして 1 行で出力する
#   Spans: @(@(開始位置, 長さ), ...)
function Write-Spanned {
    param(
        [string]$Text,
        [System.Collections.Generic.List[int[]]]$Spans,
        [string]$HitStyle = 'Hit',
        [switch]$NoNewline
    )
    $cursor = 0
    foreach ($span in $Spans) {
        $start = $span[0]
        $len = $span[1]
        if ($start -gt $cursor) {
            Write-Tagged $Text.Substring($cursor, $start - $cursor) 'Plain' -NoNewline
        }
        if ($len -gt 0) {
            Write-Tagged $Text.Substring($start, $len) $HitStyle -NoNewline
        }
        $cursor = $start + $len
    }
    if ($cursor -lt $Text.Length) {
        Write-Tagged $Text.Substring($cursor) 'Plain' -NoNewline
    }
    if (-not $NoNewline) { Write-Host '' }
}

# ハイライト区間の真下に ^^^ を並べた行を返す（半角名のみ。全角混在時は $null）
function Get-RulerLine {
    param([string]$Text, [System.Collections.Generic.List[int[]]]$Spans)
    if (-not (Test-SingleWidth $Text)) { return $null }
    $chars = New-Object 'char[]' $Text.Length
    for ($i = 0; $i -lt $Text.Length; $i++) { $chars[$i] = ' ' }
    $any = $false
    foreach ($span in $Spans) {
        for ($i = $span[0]; $i -lt ($span[0] + $span[1]) -and $i -lt $Text.Length; $i++) {
            $chars[$i] = '^'
            $any = $true
        }
    }
    if (-not $any) { return $null }
    return (-join $chars).TrimEnd()
}

#endregion

#region 入力ヘルパー

function Read-Line {
    param([string]$Prompt)
    Write-Tagged ('{0}: ' -f $Prompt) 'Head' -NoNewline
    return [string](Read-Host)
}

# Enter / r / q などの選択を受け取る（空入力 = Enter）
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

#endregion

#region ヘルプ（タブ切り替え表示）

# ヘルプ 1 行分。Key を与えると、左に記号列・右に説明の 2 段組みになる。
function New-HelpLine {
    param([string]$Text = '', [string]$Key = '', [string]$Style = 'Plain')
    return [pscustomobject]@{ Text = $Text; Key = $Key; Style = $Style }
}

function New-HelpHeading {
    param([string]$Text)
    return (New-HelpLine ('  ■ {0}' -f $Text) '' 'Ok')
}

function Get-HelpPages {

    $usage = @(
        (New-HelpHeading '処理の流れ')
        (New-HelpLine -Key '1/3' -Text '正規表現を入力する（決定した時点で構文を確認）')
        (New-HelpLine -Key '2/3' -Text 'マッチしたファイル名の一覧を確認する（該当部分を反転表示）')
        (New-HelpLine -Key '3/3' -Text '置換後の文字列を入力し、変更前 -> 変更後 を確認して実行')
        (New-HelpLine)
        (New-HelpHeading '各ステップで使えるキー')
        (New-HelpLine -Key 'Enter' -Text '次へ進む / 実行する')
        (New-HelpLine -Key 'r' -Text 'そのステップを入れ直す')
        (New-HelpLine -Key 'q' -Text '中止する（ファイル名は変更されない）')
        (New-HelpLine -Key '?' -Text '正規表現の入力時にこのヘルプを開く')
        (New-HelpLine -Key 'h' -Text '確認のプロンプトでこのヘルプを開く')
        (New-HelpLine)
        (New-HelpHeading 'オプション')
        (New-HelpLine -Key '-Path' -Text '対象ディレクトリ（既定はカレントディレクトリ）')
        (New-HelpLine -Key '-Filter' -Text 'ワイルドカードでの事前絞り込み（例: *.jpg）')
        (New-HelpLine -Key '-Recurse' -Text 'サブディレクトリも対象にする')
        (New-HelpLine -Key '-IncludeDirectory' -Text 'ディレクトリ名もリネーム対象に含める')
        (New-HelpLine -Key '-CaseSensitive' -Text '大文字小文字を区別する（既定は区別しない）')
        (New-HelpLine -Key '-Pattern' -Text '正規表現を対話入力せずに渡す')
        (New-HelpLine -Key '-Replacement' -Text '置換後の文字列を対話入力せずに渡す')
        (New-HelpLine -Key '-WhatIf' -Text 'レビューまで行い、実行はしない')
        (New-HelpLine -Key '-NoLog' -Text 'Undo 用ログを書き出さない')
        (New-HelpLine -Key '-LogDirectory' -Text 'ログの出力先（既定は data\rename-by-regex\logs）')
        (New-HelpLine -Key '-Help' -Text 'このヘルプだけを開く')
        (New-HelpLine)
        (New-HelpHeading '実行例')
        (New-HelpLine '     .\Rename-ByRegex.ps1 -Filter *.jpg')
        (New-HelpLine '     .\Rename-ByRegex.ps1 -Pattern "^IMG_(\d+)" -Replacement "photo-$1"')
        (New-HelpLine '     .\Rename-ByRegex.ps1 -Recurse -IncludeDirectory -WhatIf')
        (New-HelpLine)
        (New-HelpHeading '元に戻す')
        (New-HelpLine '     実行後に表示される JSON ログのパスを渡す:')
        (New-HelpLine '     .\Undo-RenameLog.ps1 -LogPath <ログのパス>')
    )

    $cheatsheet = @(
        (New-HelpHeading '1 文字にマッチ')
        (New-HelpLine -Key '.' -Text '任意の 1 文字')
        (New-HelpLine -Key '\d  \D' -Text '数字 / 数字以外')
        (New-HelpLine -Key '\w  \W' -Text '英数字と _ / それ以外')
        (New-HelpLine -Key '\s  \S' -Text '空白 / 空白以外')
        (New-HelpLine -Key '[abc]' -Text 'a か b か c のどれか')
        (New-HelpLine -Key '[^abc]' -Text 'a b c 以外')
        (New-HelpLine -Key '[a-z0-9]' -Text '範囲での指定')
        (New-HelpLine)
        (New-HelpHeading '繰り返し（直前の 1 つに付ける）')
        (New-HelpLine -Key '*' -Text '0 回以上')
        (New-HelpLine -Key '+' -Text '1 回以上')
        (New-HelpLine -Key '?' -Text '0 回か 1 回（あってもなくてもよい）')
        (New-HelpLine -Key '{3}' -Text 'ちょうど 3 回')
        (New-HelpLine -Key '{2,}' -Text '2 回以上')
        (New-HelpLine -Key '{2,4}' -Text '2 回から 4 回')
        (New-HelpLine -Key '*?  +?' -Text '最短一致（できるだけ短くマッチ）')
        (New-HelpLine)
        (New-HelpHeading '位置')
        (New-HelpLine -Key '^' -Text 'ファイル名の先頭')
        (New-HelpLine -Key '$' -Text 'ファイル名の末尾（拡張子より後ろ）')
        (New-HelpLine -Key '\b' -Text '単語の境界')
        (New-HelpLine)
        (New-HelpHeading 'グループと選択')
        (New-HelpLine -Key '(...)' -Text 'キャプチャする。置換側で $1 として使える')
        (New-HelpLine -Key '(?:...)' -Text 'キャプチャしないグループ')
        (New-HelpLine -Key '(?<y>...)' -Text '名前付きキャプチャ。置換側では ${y}')
        (New-HelpLine -Key 'a|b' -Text 'a または b')
        (New-HelpLine)
        (New-HelpHeading '置換側で使える記号')
        (New-HelpLine -Key '$1  $2' -Text '1 番目 / 2 番目のキャプチャ')
        (New-HelpLine -Key '${name}' -Text '名前付きキャプチャ')
        (New-HelpLine -Key '$&' -Text 'マッチした部分の全体')
        (New-HelpLine -Key '$$' -Text '文字としての $')
        (New-HelpLine)
        (New-HelpHeading '記号そのものを探すときのエスケープ')
        (New-HelpLine -Key '\.  \+  \*' -Text '記号の前に \ を付けると、その文字そのものを指す')
        (New-HelpLine -Key '\\' -Text '\ 自身を探すときは 2 つ重ねる')
        (New-HelpLine '     他に \(  \)  \[  \]  \{  \}  \?  \|  \^  \$  なども同じ')
        (New-HelpLine)
        (New-HelpHeading '組み合わせの例（正規表現  ->  置換後）')
        (New-HelpLine '     ^IMG_(\d+)\.JPG$      ->  photo-$1.jpg')
        (New-HelpLine '     \s+                   ->  _            空白を _ にする')
        (New-HelpLine '     ^(.*)_(\d{4})$        ->  $2_$1        前後を入れ替える')
        (New-HelpLine '     (?<y>\d{4})(\d{2})    ->  ${y}-$2      数字を 年-月 に整形')
        (New-HelpLine '     ^\d+[-_ ]*            ->               先頭の連番を削除')
    )

    return @(
        [pscustomobject]@{ Title = '使い方';               KeyWidth = 18; Lines = $usage }
        [pscustomobject]@{ Title = '正規表現チートシート'; KeyWidth = 12; Lines = $cheatsheet }
    )
}

# ヘルプ 1 行を、色の変わる区間（Text / Style）の並びに展開する
function Get-HelpLineSegments {
    param([object]$Line, [int]$KeyWidth = 12)
    if ($Line.Key -ne '') {
        return @(
            @{ Text = '     ' + $Line.Key.PadRight($KeyWidth); Style = 'Warn' }
            @{ Text = $Line.Text; Style = $Line.Style }
        )
    }
    return @(@{ Text = $Line.Text; Style = $Line.Style })
}

function Write-HelpLine {
    param([object]$Line, [int]$KeyWidth = 12)
    foreach ($seg in (Get-HelpLineSegments -Line $Line -KeyWidth $KeyWidth)) {
        Write-Tagged $seg.Text $seg.Style -NoNewline
    }
    Write-Host ''
}

# 全タブを続けて出力する（キー入力が取れない環境用）
function Write-HelpFrame {
    param([object[]]$Pages, [int]$Index)

    Write-Host ''
    Write-Tagged '  Rename-ByRegex  ヘルプ' 'Head'
    Write-Host ''

    Write-Tagged '  ' 'Plain' -NoNewline
    for ($i = 0; $i -lt $Pages.Count; $i++) {
        $label = ' {0}. {1} ' -f ($i + 1), $Pages[$i].Title
        $style = if ($i -eq $Index) { 'Hit' } else { 'Dim' }
        Write-Tagged $label $style -NoNewline
        Write-Tagged '  ' 'Plain' -NoNewline
    }
    Write-Host ''
    Write-Host ''

    foreach ($line in $Pages[$Index].Lines) {
        Write-HelpLine -Line $line -KeyWidth $Pages[$Index].KeyWidth
    }
    Write-Host ''
}

#endregion

#region ヘルプ（画面制御）

# 1 画面に表示できる本文の行数。
# 見出し 5 行 + 操作説明 2 行を引き、折り返し用に 1 行残して画面送りを防ぐ。
function Get-HelpViewportHeight {
    $rows = 24
    try {
        if ([Console]::WindowHeight -gt 0) { $rows = [Console]::WindowHeight }
    }
    catch { }
    return [Math]::Max(5, $rows - 8)
}

# 書き込んでよい桁数。右端 1 桁は空けて自動折り返しを避ける。
function Get-HelpViewportWidth {
    $cols = 80
    try {
        if ([Console]::WindowWidth -gt 0) { $cols = [Console]::WindowWidth }
    }
    catch { }
    return [Math]::Max(20, $cols - 1)
}

# 表示桁数の見積もり。曖昧幅（■ ← → など）は 2 桁側に寄せる。
# 多めに数えると埋め残りが出るだけだが、少なく数えると折り返して画面が崩れる。
function Get-DisplayWidth {
    param([string]$Text)
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int][char]$ch
        if (($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2190 -and $code -le 0x2199) -or
            ($code -ge 0x25A0 -and $code -le 0x25FF) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
            $width += 2
        }
        else {
            $width += 1
        }
    }
    return $width
}

function Get-TruncatedText {
    param([string]$Text, [int]$MaxWidth)
    if ($MaxWidth -le 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $w = Get-DisplayWidth ([string]$ch)
        if (($width + $w) -gt $MaxWidth) { break }
        [void]$sb.Append($ch)
        $width += $w
    }
    return $sb.ToString()
}

# 指定行へカーソルを移して 1 行を上書きする。
# 行末は空白で埋めるので、画面を消さずに前の内容を消せる（= ちらつかない）。
function Write-HelpRowAt {
    param([int]$Row, [object[]]$Segments, [int]$Width)

    try { [Console]::SetCursorPosition(0, $Row) }
    catch { return }

    $used = 0
    foreach ($seg in $Segments) {
        if ($used -ge $Width) { break }
        $text = [string]$seg.Text
        if ($text -eq '') { continue }
        $w = Get-DisplayWidth $text
        if (($used + $w) -gt $Width) {
            $text = Get-TruncatedText -Text $text -MaxWidth ($Width - $used)
            $w = Get-DisplayWidth $text
        }
        if ($text -ne '') { Write-Tagged $text $seg.Style -NoNewline }
        $used += $w
    }
    if ($used -lt $Width) {
        Write-Tagged (' ' * ($Width - $used)) 'Plain' -NoNewline
    }
}

# 1 画面分の行（= 色区間の配列の配列）を組み立てる。
# 本文は常に Height 行ぶん作るので、操作説明の行は画面下で動かない。
function Get-HelpFrameRows {
    param([object[]]$Pages, [int]$Index, [int]$Offset, [int]$Height, [int]$MaxOffset, [int]$Width = 80)

    $page = $Pages[$Index]
    $lines = @($page.Lines)
    $rows = New-Object System.Collections.ArrayList

    [void]$rows.Add(@())
    [void]$rows.Add(@(@{ Text = '  Rename-ByRegex  ヘルプ'; Style = 'Head' }))
    [void]$rows.Add(@())

    $tabs = New-Object System.Collections.ArrayList
    [void]$tabs.Add(@{ Text = '  '; Style = 'Plain' })
    for ($i = 0; $i -lt $Pages.Count; $i++) {
        $style = if ($i -eq $Index) { 'Hit' } else { 'Dim' }
        [void]$tabs.Add(@{ Text = (' {0}. {1} ' -f ($i + 1), $Pages[$i].Title); Style = $style })
        [void]$tabs.Add(@{ Text = '  '; Style = 'Plain' })
    }
    [void]$rows.Add($tabs.ToArray())
    [void]$rows.Add(@())

    for ($i = 0; $i -lt $Height; $i++) {
        $n = $Offset + $i
        if ($n -lt $lines.Count) {
            [void]$rows.Add((Get-HelpLineSegments -Line $lines[$n] -KeyWidth $page.KeyWidth))
        }
        else {
            [void]$rows.Add(@())
        }
    }

    [void]$rows.Add(@())

    $status = New-Object System.Collections.ArrayList
    if ($MaxOffset -gt 0) {
        $tail = [Math]::Min($lines.Count, $Offset + $Height)
        $mark = if ($Offset -ge $MaxOffset) { '  (END)' } elseif ($Offset -eq 0) { '  (TOP)' } else { '' }
        [void]$status.Add(@{
            Text  = ('  [ {0}-{1} / {2} 行 ]{3}' -f ($Offset + 1), $tail, $lines.Count, $mark)
            Style = 'Warn'
        })
    }
    else {
        [void]$status.Add(@{ Text = ('  [ 全 {0} 行 ]' -f $lines.Count); Style = 'Warn' })
    }
    # 狭い画面では切り詰められてしまうので、操作の説明も幅に合わせて選ぶ
    $hint = if ($Width -ge 100) {
        '   ↑ ↓ j k 行送り   f b 画面送り   d u 半画面   ← → タブ   g G 先頭末尾   q 終了'
    }
    else {
        '   ↑↓ 行   f b 画面   ← → タブ   q 終了'
    }
    [void]$status.Add(@{ Text = $hint; Style = 'Dim' })
    [void]$rows.Add($status.ToArray())

    return , $rows.ToArray()
}

function Write-HelpScreen {
    param([object[]]$Rows, [int]$Width, [int]$Origin, [int]$Previous)

    for ($i = 0; $i -lt $Rows.Count; $i++) {
        Write-HelpRowAt -Row ($Origin + $i) -Segments $Rows[$i] -Width $Width
    }
    # 前回より短くなったぶんの残像を消す
    for ($i = $Rows.Count; $i -lt $Previous; $i++) {
        Write-HelpRowAt -Row ($Origin + $i) -Segments @() -Width $Width
    }
    try { [Console]::SetCursorPosition(0, $Origin + $Rows.Count) } catch { }

    return $Rows.Count
}

# キー入力を操作名に翻訳する（less に近い割り当て）
function Get-HelpAction {
    param([System.ConsoleKeyInfo]$KeyInfo)

    switch ($KeyInfo.Key) {
        'LeftArrow'  { return 'prev-tab' }
        'RightArrow' { return 'next-tab' }
        'Tab'        { return 'next-tab' }
        'UpArrow'    { return 'up' }
        'DownArrow'  { return 'down' }
        'Enter'      { return 'down' }
        'Spacebar'   { return 'page-down' }
        'PageDown'   { return 'page-down' }
        'PageUp'     { return 'page-up' }
        'Home'       { return 'top' }
        'End'        { return 'bottom' }
        'Escape'     { return 'quit' }
    }

    # Ctrl+F / Ctrl+B / Ctrl+D / Ctrl+U は制御文字として届く
    switch ([int][char]$KeyInfo.KeyChar) {
        6  { return 'page-down' }
        2  { return 'page-up' }
        4  { return 'half-down' }
        21 { return 'half-up' }
    }

    switch -CaseSensitive ([string]$KeyInfo.KeyChar) {
        'j' { return 'down' }
        'k' { return 'up' }
        'f' { return 'page-down' }
        'b' { return 'page-up' }
        'd' { return 'half-down' }
        'u' { return 'half-up' }
        'g' { return 'top' }
        'G' { return 'bottom' }
        'h' { return 'prev-tab' }
        'l' { return 'next-tab' }
        'q' { return 'quit' }
        'Q' { return 'quit' }
    }

    if ([char]::IsDigit($KeyInfo.KeyChar)) {
        return 'tab:{0}' -f $KeyInfo.KeyChar
    }
    return ''
}

# キー入力とカーソル移動ができる環境か。
# どちらかが使えないホスト（リダイレクト実行、ISE など）では画面を組み立てられない。
function Test-KeyInputAvailable {
    if ([Console]::IsInputRedirected) { return $false }
    try { $null = [Console]::KeyAvailable }
    catch { return $false }
    try { [Console]::SetCursorPosition([Console]::CursorLeft, [Console]::CursorTop) }
    catch { return $false }
    return $true
}

# 左右キーでタブを切り替え、上下キーで本文をスクロールするヘルプ。
# タブを切り替えたときは必ず先頭行に戻す。
# 画面は消さずに同じ位置へ上書きし、表示内容が変わらないキーでは描画しない。
# キー入力が取れない環境では、切り替えずに全タブを続けて出力する。
function Show-Help {
    $pages = Get-HelpPages

    if (-not (Test-KeyInputAvailable)) {
        for ($i = 0; $i -lt $pages.Count; $i++) {
            Write-HelpFrame -Pages $pages -Index $i
        }
        return
    }

    $cursorVisible = $true
    try { $cursorVisible = [Console]::CursorVisible } catch { }
    try { [Console]::CursorVisible = $false } catch { }

    try {
        $index = 0
        $offset = 0
        $origin = 0
        $drawn = 0
        $lastSize = ''
        $redraw = $true
        $closed = $false

        while (-not $closed) {
            # ウィンドウサイズは毎回測る（表示中にリサイズされても崩れないように）
            $height = Get-HelpViewportHeight
            $width = Get-HelpViewportWidth
            $maxOffset = [Math]::Max(0, @($pages[$index].Lines).Count - $height)
            if ($offset -gt $maxOffset) { $offset = $maxOffset; $redraw = $true }

            # 画面を消すのは最初とリサイズ時だけ。描画の起点もそこで取り直す。
            $size = '{0}x{1}' -f $width, $height
            if ($size -ne $lastSize) {
                Clear-Host
                try { $origin = [Console]::CursorTop } catch { $origin = 0 }
                $lastSize = $size
                $drawn = 0
                $redraw = $true
            }

            if ($redraw) {
                $rows = Get-HelpFrameRows -Pages $pages -Index $index `
                    -Offset $offset -Height $height -MaxOffset $maxOffset -Width $width
                $drawn = Write-HelpScreen -Rows $rows -Width $width -Origin $origin -Previous $drawn
                $redraw = $false
            }

            $before = '{0}:{1}' -f $index, $offset
            $half = [Math]::Max(1, [int]($height / 2))

            switch (Get-HelpAction -KeyInfo ([Console]::ReadKey($true))) {
                'prev-tab'  { $index = ($index - 1 + $pages.Count) % $pages.Count; $offset = 0 }
                'next-tab'  { $index = ($index + 1) % $pages.Count;                $offset = 0 }
                'down'      { $offset = [Math]::Min($maxOffset, $offset + 1) }
                'up'        { $offset = [Math]::Max(0, $offset - 1) }
                'page-down' { $offset = [Math]::Min($maxOffset, $offset + $height) }
                'page-up'   { $offset = [Math]::Max(0, $offset - $height) }
                'half-down' { $offset = [Math]::Min($maxOffset, $offset + $half) }
                'half-up'   { $offset = [Math]::Max(0, $offset - $half) }
                'top'       { $offset = 0 }
                'bottom'    { $offset = $maxOffset }
                'quit'      { $closed = $true }
                default {
                    # 数字キーでタブを直接選ぶ
                    if ($_ -like 'tab:*') {
                        $n = [int]($_ -replace '^tab:', '') - 1
                        if ($n -ge 0 -and $n -lt $pages.Count) { $index = $n; $offset = 0 }
                    }
                }
            }

            # 端で ↑ ↓ を押したときなど、位置が変わらなければ描き直さない
            if (-not $closed -and ('{0}:{1}' -f $index, $offset) -ne $before) {
                $redraw = $true
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $cursorVisible } catch { }
    }

    # ヘルプを閉じたら画面を元の流れに戻す
    Clear-Host
    Write-Banner
}

#endregion

#region 走査・置換ロジック

function Get-TargetItems {
    param([string]$Root)

    $common = @{ LiteralPath = $Root; Filter = $Filter; Force = $true; ErrorAction = 'SilentlyContinue' }
    if ($Recurse) { $common['Recurse'] = $true }

    $items = @(Get-ChildItem @common -File)
    if ($IncludeDirectory) {
        $items += @(Get-ChildItem @common -Directory)
    }

    # このスクリプト自身は対象外にする
    $selfNames = @('Rename-ByRegex.ps1', 'Undo-RenameLog.ps1')
    $items = @($items | Where-Object { $selfNames -notcontains $_.Name })

    # 単一要素や 0 件でもコレクションのまま返すため , で包む
    return , @($items | Sort-Object @{ Expression = { Split-Path $_.FullName -Parent } }, Name)
}

function New-Regex {
    param([string]$PatternText)
    $options = [System.Text.RegularExpressions.RegexOptions]::None
    if (-not $CaseSensitive) {
        $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    }
    return New-Object System.Text.RegularExpressions.Regex($PatternText, $options)
}

function Get-MatchSpans {
    param([System.Text.RegularExpressions.Regex]$Regex, [string]$Source)
    $spans = New-Object 'System.Collections.Generic.List[int[]]'
    foreach ($m in $Regex.Matches($Source)) {
        $spans.Add(@($m.Index, $m.Length))
    }
    return , $spans
}

# 置換後の文字列と、置換結果側のハイライト区間を同時に組み立てる
function Get-ReplacedName {
    param(
        [System.Text.RegularExpressions.Regex]$Regex,
        [string]$Source,
        [string]$ReplacementText
    )
    $sb = New-Object System.Text.StringBuilder
    $spans = New-Object 'System.Collections.Generic.List[int[]]'
    $last = 0
    foreach ($m in $Regex.Matches($Source)) {
        [void]$sb.Append($Source.Substring($last, $m.Index - $last))
        $expanded = $m.Result($ReplacementText)
        $spans.Add(@($sb.Length, $expanded.Length))
        [void]$sb.Append($expanded)
        $last = $m.Index + $m.Length
    }
    [void]$sb.Append($Source.Substring($last))
    return [pscustomobject]@{
        Text  = $sb.ToString()
        Spans = $spans
    }
}

function Test-NewName {
    param([string]$Name)
    $problems = @()
    if ($Name -eq '') { $problems += '空の名前になります' }
    if ($Name -eq '.' -or $Name -eq '..') { $problems += "'.' / '..' は使えません" }

    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $bad = @($Name.ToCharArray() | Where-Object { $invalid -contains $_ } | Select-Object -Unique)
    if ($bad.Count -gt 0) {
        $problems += ('使用できない文字が含まれます: {0}' -f (($bad | ForEach-Object { "'$_'" }) -join ', '))
    }
    if ($Name -ne '' -and ($Name.EndsWith(' ') -or $Name.EndsWith('.'))) {
        $problems += '末尾の空白やピリオドは Windows では扱えません'
    }
    if ($Name.Length -gt 255) { $problems += '名前が長すぎます（255 文字超）' }
    return , $problems
}

#endregion

#region ステップ 1-2: 正規表現の入力とマッチ一覧

function Select-Pattern {
    param([object[]]$Items, [string]$InitialPattern)

    $pending = $InitialPattern

    while ($true) {
        if ([string]::IsNullOrEmpty($pending)) {
            Write-Rule 'ステップ 1/3: 正規表現を入力'
            $scope = if ($Recurse) { ' / 再帰あり' } else { '' }
            Write-Tagged ('  走査対象: {0} 件  ({1}{2})' -f $Items.Count, $script:ResolvedPath, $scope) 'Dim'
            Write-Tagged '  空入力で中止します。? でヘルプ（使い方 / 正規表現チートシート）。' 'Dim'
            $pending = (Read-Line '  正規表現').Trim()
            if ($pending -eq '') { return $null }

            # 単独の ? は正規表現として不正なので、ヘルプの合図として使う
            if ($pending -eq '?') {
                Show-Help
                $pending = ''
                continue
            }
        }

        try {
            $regex = New-Regex $pending
        }
        catch {
            # New-Object の例外は .NET のコンストラクタ例外に包まれるので中身を出す
            $detail = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            Write-Tagged ('  正規表現が不正です: {0}' -f $detail) 'Err'
            $pending = ''
            continue
        }

        $hits = @()
        foreach ($item in $Items) {
            $spans = Get-MatchSpans -Regex $regex -Source $item.Name
            if ($spans.Count -gt 0) {
                $hits += [pscustomobject]@{
                    Item    = $item
                    Spans   = $spans
                    Matched = @($regex.Matches($item.Name) | ForEach-Object { $_.Value })
                }
            }
        }

        $flag = if ($CaseSensitive) { '' } else { 'i' }
        Write-Rule ('ステップ 2/3: マッチ結果  /{0}/{1}' -f $pending, $flag)

        if ($hits.Count -eq 0) {
            Write-Tagged '  マッチするファイルはありませんでした。' 'Warn'
            $choice = Read-Choice '  [Enter] 正規表現を入れ直す  /  h: ヘルプ  /  q: 中止 > ' @('h', 'q')
            if ($choice -eq 'q') { return $null }
            if ($choice -eq 'h') { Show-Help }
            $pending = ''
            continue
        }

        Show-MatchList -Hits $hits

        $choice = Read-Choice '  [Enter] この条件で進む  /  r: 入れ直す  /  h: ヘルプ  /  q: 中止 > ' @('r', 'h', 'q')
        switch ($choice) {
            'q' { return $null }
            'r' { $pending = '' }
            'h' { Show-Help }   # $pending を保ったまま再描画してマッチ一覧に戻る
            default {
                return [pscustomobject]@{ Pattern = $pending; Regex = $regex; Hits = $hits }
            }
        }
    }
}

function Show-MatchList {
    param([object[]]$Hits)

    Write-Tagged ('  {0} 件のファイル名がマッチしました。' -f $Hits.Count) 'Ok'
    Write-Host ''

    $lastDir = $null
    $index = 0
    foreach ($hit in $Hits) {
        $dir = Split-Path $hit.Item.FullName -Parent
        if ($dir -ne $lastDir) {
            Write-Tagged ('  [{0}]' -f $dir) 'Dim'
            $lastDir = $dir
        }
        $index++
        $prefix = '    {0,3}. ' -f $index
        Write-Tagged $prefix 'Dim' -NoNewline
        Write-Spanned -Text $hit.Item.Name -Spans $hit.Spans

        $ruler = Get-RulerLine -Text $hit.Item.Name -Spans $hit.Spans
        if ($ruler) {
            Write-Tagged ((' ' * $prefix.Length) + $ruler) 'Warn' -NoNewline
            Write-Tagged ('   match: {0}' -f (($hit.Matched | ForEach-Object { "'$_'" }) -join ', ')) 'Dim'
        }
    }
}

#endregion

#region ステップ 3: 置換文字列の入力とレビュー

function Select-Replacement {
    param([object]$Selection, [string]$InitialReplacement, [bool]$HasInitial)

    $pending = $InitialReplacement
    $hasPending = $HasInitial

    while ($true) {
        if (-not $hasPending) {
            Write-Rule 'ステップ 3/3: 置換後の文字列を入力'
            Write-Tagged '  $1 や ${name} でキャプチャ参照、$$ でリテラルの $ が使えます。' 'Dim'
            Write-Tagged '  空入力はマッチ部分の削除とみなします（確認します）。 q で中止。' 'Dim'
            Write-Tagged '  次の確認で h を押すとヘルプを開けます。' 'Dim'
            $pending = Read-Line '  置換後'
            $hasPending = $true

            if ($pending -eq 'q') { return $null }

            # 標準入力がリダイレクトされている（スクリプト経由の実行など）場合、
            # 入力が尽きると Read-Host は空を返し続ける。空は中止として扱い無限ループを防ぐ。
            if ($pending -eq '' -and [Console]::IsInputRedirected) {
                Write-Tagged '  入力がありません。中止します。' 'Warn'
                return $null
            }

            if ($pending -eq '') {
                $ok = Read-Choice '  空です。マッチ部分を削除しますか？ [Enter] はい  /  r: 入れ直す  /  q: 中止 > ' @('r', 'q')
                if ($ok -eq 'q') { return $null }
                if ($ok -eq 'r') { $hasPending = $false; continue }
            }
        }

        $plan = New-RenamePlan -Selection $Selection -ReplacementText $pending
        if ($null -eq $plan) { $hasPending = $false; continue }

        Show-Review -Plan $plan -ReplacementText $pending

        if ($plan.Changes.Count -eq 0) {
            $choice = Read-Choice '  実行できる変更がありません。[Enter] 入れ直す  /  h: ヘルプ  /  q: 中止 > ' @('h', 'q')
            if ($choice -eq 'q') { return $null }
            if ($choice -eq 'h') { Show-Help }
            $hasPending = $false
            continue
        }

        $choice = Read-Choice '  [Enter] 実行  /  r: 置換後を入れ直す  /  h: ヘルプ  /  q: 中止 > ' @('r', 'h', 'q')
        switch ($choice) {
            'q' { return $null }
            'r' { $hasPending = $false }
            'h' { Show-Help }   # $pending を保ったままレビューを再表示する
            default {
                $plan | Add-Member -NotePropertyName Replacement -NotePropertyValue $pending -Force
                return $plan
            }
        }
    }
}

# マッチ結果から実行計画を作り、変化なし・不正名・衝突を切り分ける
function New-RenamePlan {
    param([object]$Selection, [string]$ReplacementText)

    $changes = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    $blocked = New-Object System.Collections.ArrayList

    foreach ($hit in $Selection.Hits) {
        $item = $hit.Item
        try {
            $result = Get-ReplacedName -Regex $Selection.Regex -Source $item.Name -ReplacementText $ReplacementText
        }
        catch {
            Write-Tagged ('  置換文字列を展開できません: {0}' -f $_.Exception.Message) 'Err'
            return $null
        }

        $parent = Split-Path $item.FullName -Parent
        $entry = [pscustomobject]@{
            Directory = $parent
            OldName   = $item.Name
            NewName   = $result.Text
            OldPath   = $item.FullName
            NewPath   = (Join-Path $parent $result.Text)
            OldSpans  = $hit.Spans
            NewSpans  = $result.Spans
            IsDir     = [bool]$item.PSIsContainer
            Reason    = $null
        }

        $problems = Test-NewName $result.Text
        if ($problems.Count -gt 0) {
            $entry.Reason = ($problems -join ' / ')
            [void]$blocked.Add($entry)
        }
        elseif ($result.Text -ceq $item.Name) {
            $entry.Reason = '名前が変わりません'
            [void]$skipped.Add($entry)
        }
        else {
            [void]$changes.Add($entry)
        }
    }

    # 同一ディレクトリ内の衝突検証（Windows の実挙動に合わせ大文字小文字は無視）
    $survivors = New-Object System.Collections.ArrayList
    foreach ($group in @($changes | Group-Object Directory)) {
        $dir = $group.Name

        # リネーム対象の「変更前の名前」は処理後には空くので、占有扱いにしない
        $vacating = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($c in $group.Group) { [void]$vacating.Add($c.OldName) }

        $occupied = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($existing in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            if (-not $vacating.Contains($existing.Name)) { [void]$occupied.Add($existing.Name) }
        }

        # 同じ変換結果が複数ある場合は、どれを残すかを勝手に決めずに全部止める
        $duplicated = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($c in $group.Group) {
            if (-not $seen.Add($c.NewName)) { [void]$duplicated.Add($c.NewName) }
        }

        foreach ($c in $group.Group) {
            if ($occupied.Contains($c.NewName)) {
                $c.Reason = ('既存の "{0}" と衝突します' -f $c.NewName)
                [void]$blocked.Add($c)
            }
            elseif ($duplicated.Contains($c.NewName)) {
                $c.Reason = ('変換結果 "{0}" が他と重複します' -f $c.NewName)
                [void]$blocked.Add($c)
            }
            else {
                [void]$survivors.Add($c)
            }
        }
    }

    # 深い階層から処理する（ディレクトリ名を変えても子のパスが無効化しないように）
    $ordered = @($survivors | Sort-Object `
        @{ Expression = { ($_.Directory -split '[\\/]').Count }; Descending = $true }, `
        @{ Expression = 'Directory'; Descending = $false }, `
        @{ Expression = 'OldName'; Descending = $false })

    return [pscustomobject]@{
        Changes = @($ordered)
        Skipped = @($skipped)
        Blocked = @($blocked)
    }
}

function Show-Review {
    param([object]$Plan, [string]$ReplacementText)

    Write-Rule ('レビュー  /{0}/  ->  "{1}"' -f $script:ActivePattern, $ReplacementText)

    if ($Plan.Changes.Count -gt 0) {
        Write-Tagged ('  実行する変更: {0} 件' -f $Plan.Changes.Count) 'Ok'
        Write-Host ''
        $lastDir = $null
        $i = 0
        foreach ($c in $Plan.Changes) {
            if ($c.Directory -ne $lastDir) {
                Write-Tagged ('  [{0}]' -f $c.Directory) 'Dim'
                $lastDir = $c.Directory
            }
            $i++
            Write-Tagged ('    {0,3}. ' -f $i) 'Dim' -NoNewline
            Write-Spanned -Text $c.OldName -Spans $c.OldSpans -HitStyle 'Hit' -NoNewline
            Write-Tagged '  ->  ' 'Dim' -NoNewline
            Write-Spanned -Text $c.NewName -Spans $c.NewSpans -HitStyle 'New' -NoNewline
            if ($c.IsDir) { Write-Tagged '  [dir]' 'Dim' -NoNewline }
            Write-Host ''
        }
    }

    if ($Plan.Skipped.Count -gt 0) {
        Write-Host ''
        Write-Tagged ('  スキップ: {0} 件' -f $Plan.Skipped.Count) 'Dim'
        foreach ($s in $Plan.Skipped) {
            Write-Tagged ('       {0}   ({1})' -f $s.OldName, $s.Reason) 'Dim'
        }
    }

    if ($Plan.Blocked.Count -gt 0) {
        Write-Host ''
        Write-Tagged ('  実行できない: {0} 件' -f $Plan.Blocked.Count) 'Err'
        foreach ($b in $Plan.Blocked) {
            Write-Tagged ('       {0}  ->  {1}' -f $b.OldName, $b.NewName) 'Err' -NoNewline
            Write-Tagged ('   {0}' -f $b.Reason) 'Warn'
        }
    }
    Write-Host ''
}

#endregion

#region 実行

# 同一ディレクトリ内で一時名を経由する 2 段リネーム。
# 名前の入れ替え（a <-> b）や大文字小文字だけの変更も安全に通る。
function Invoke-RenamePlan {
    param([object]$Plan)

    $journal = New-Object System.Collections.ArrayList   # 実際に行った (現在のパス, 戻し先パス)
    $applied = New-Object System.Collections.ArrayList   # ログ用の最終結果

    try {
        foreach ($group in @($Plan.Changes | Group-Object Directory)) {
            $dir = $group.Name
            $staging = New-Object System.Collections.ArrayList
            $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)

            # 第 1 段: いったん全件を一時名へ
            $n = 0
            foreach ($c in $group.Group) {
                $n++
                $tempName = '.rbr-{0}-{1}.tmp' -f $stamp, $n
                $tempPath = Join-Path $dir $tempName
                Rename-Item -LiteralPath $c.OldPath -NewName $tempName -ErrorAction Stop
                [void]$journal.Add(@($tempPath, $c.OldPath))
                [void]$staging.Add([pscustomobject]@{ Change = $c; TempPath = $tempPath })
            }

            # 第 2 段: 一時名から最終名へ
            foreach ($s in $staging) {
                Rename-Item -LiteralPath $s.TempPath -NewName $s.Change.NewName -ErrorAction Stop
                [void]$journal.Add(@($s.Change.NewPath, $s.TempPath))
                [void]$applied.Add([pscustomobject]@{
                    Directory = $s.Change.Directory
                    OldName   = $s.Change.OldName
                    NewName   = $s.Change.NewName
                    OldPath   = $s.Change.OldPath
                    NewPath   = $s.Change.NewPath
                    IsDir     = $s.Change.IsDir
                })
                Write-Tagged '  ok   ' 'Ok' -NoNewline
                Write-Tagged ('{0}  ->  {1}' -f $s.Change.OldName, $s.Change.NewName) 'Plain'
            }
        }
    }
    catch {
        Write-Host ''
        Write-Tagged ('  失敗しました: {0}' -f $_.Exception.Message) 'Err'
        Write-Tagged '  ここまでの変更を巻き戻します。' 'Warn'
        for ($i = $journal.Count - 1; $i -ge 0; $i--) {
            $from = $journal[$i][0]
            $to = $journal[$i][1]
            try {
                Rename-Item -LiteralPath $from -NewName (Split-Path $to -Leaf) -ErrorAction Stop
            }
            catch {
                Write-Tagged ('  巻き戻せません: {0}  （手動で {1} に戻してください）' -f $from, $to) 'Err'
            }
        }
        Write-Tagged '  巻き戻しを終えました。' 'Warn'
        return $null
    }

    return , @($applied)
}

function Write-UndoLog {
    param([object[]]$Applied, [string]$PatternText, [string]$ReplacementText)

    if ($NoLog -or $Applied.Count -eq 0) { return $null }

    # 既定は ssh-list.ps1 の接続先リストと同じ data ディレクトリ
    $dir = if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\data\rename-by-regex\logs'))
    }
    else { $LogDirectory }

    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $file = Join-Path $dir ('rename-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        [pscustomobject]@{
            Timestamp   = (Get-Date).ToString('o')
            Root        = $script:ResolvedPath
            Pattern     = $PatternText
            Replacement = $ReplacementText
            Renames     = $Applied
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
        return $file
    }
    catch {
        Write-Tagged ('  ログを書けませんでした: {0}' -f $_.Exception.Message) 'Warn'
        return $null
    }
}

#endregion

#region メイン

if ($Help) {
    Show-Help
    exit 0
}

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Tagged ('対象パスが見つかりません: {0}' -f $Path) 'Err'
    exit 1
}
$script:ResolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
$script:ActivePattern = ''

Write-Banner

$items = Get-TargetItems -Root $script:ResolvedPath
if ($items.Count -eq 0) {
    Write-Tagged ('  対象となるファイルがありません: {0}' -f $script:ResolvedPath) 'Warn'
    exit 0
}

$selection = Select-Pattern -Items $items -InitialPattern $Pattern
if ($null -eq $selection) {
    Write-Host ''
    Write-Tagged '  中止しました。変更はありません。' 'Warn'
    exit 0
}
$script:ActivePattern = $selection.Pattern

$plan = Select-Replacement -Selection $selection `
    -InitialReplacement $Replacement `
    -HasInitial ($PSBoundParameters.ContainsKey('Replacement'))
if ($null -eq $plan) {
    Write-Host ''
    Write-Tagged '  中止しました。変更はありません。' 'Warn'
    exit 0
}

if (-not $PSCmdlet.ShouldProcess(('{0} 件のファイル名' -f $plan.Changes.Count), 'リネーム')) {
    Write-Tagged '  -WhatIf 指定のため実行しませんでした。' 'Warn'
    exit 0
}

Write-Rule '実行'
$applied = Invoke-RenamePlan -Plan $plan
if ($null -eq $applied) { exit 1 }

Write-Host ''
Write-Tagged ('  完了: {0} 件をリネームしました。' -f $applied.Count) 'Ok'

$log = Write-UndoLog -Applied $applied -PatternText $selection.Pattern -ReplacementText $plan.Replacement
if ($log) {
    Write-Tagged ('  ログ: {0}' -f $log) 'Dim'
    Write-Tagged ('  元に戻す: .\Undo-RenameLog.ps1 -LogPath "{0}"' -f $log) 'Dim'
}
Write-Host ''

#endregion
