#Requires -Version 7.0
<#
.SYNOPSIS
    TextMask の置換エンジン（マスキング・復元・検証）。GUI には依存しない。

.DESCRIPTION
    辞書の文字列（会社名・人名など）を [[COMPANY_01]] 形式の識別子に置き換え、
    同じセッションの対応表を使って識別子を元の文字列に戻します。

    置換の規則
      - 辞書はリテラル一致（大文字・小文字を区別、正規表現のメタ文字もそのまま）。
      - 原文を左から 1 回だけ走査して組み立てる（逐次置換による連鎖置換は起きない）。
      - 候補が重なるときは「開始位置が左」→「長い」→「辞書（自動検出より優先）」の順で採用する。
        例: 「株式会社サンプル」と「サンプル」が両方登録されていれば前者が勝つ。
      - 同じセッションでは、同じ原文字列に必ず同じ識別子を割り当てる。
      - 原文に識別子と同じ形式の文字列があれば置換せず、同じ番号は発行しない。

    このモジュールの警告・エラーメッセージは GUI に表示するためのもので、
    ログやファイルには出力しません。復元時の警告には原文字列を含めません（識別子のみ）。
#>

Set-StrictMode -Version 3.0

$script:Categories = @('COMPANY', 'PERSON', 'PLACE', 'PRODUCT', 'PROJECT', 'EMAIL', 'PHONE', 'CUSTOM')
$script:CategoryLabels = [ordered]@{
    COMPANY = '会社名・組織名'
    PERSON  = '人名'
    PLACE   = '地名・拠点名'
    PRODUCT = '製品名'
    PROJECT = 'プロジェクト名'
    EMAIL   = 'メールアドレス'
    PHONE   = '電話番号'
    CUSTOM  = 'その他'
}

$script:RegexTimeout = [TimeSpan]::FromSeconds(1)
$script:RegexOpts = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
$script:RegexOptsIgnoreCase = $script:RegexOpts -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

# 正しい形式の識別子（\d は全角数字にも一致するので [0-9] を使う）
$script:TokenRegex = [regex]::new('\[\[([A-Z]+)_([0-9]+)\]\]', $script:RegexOpts, $script:RegexTimeout)

# 書式が崩れた識別子の候補（全角括弧・【】・単括弧・小文字・空白混入・全角数字・括弧なし）
$catAlt = $script:Categories -join '|'
$script:LooseTokenRegex = [regex]::new(
    "[\[［【〔]{1,2}\s*(?:$catAlt)\s*[_＿\-－]?\s*[0-9０-９]{1,4}\s*[\]］】〕]{0,2}" +
    "|(?<![A-Za-z\[［【〔])(?:$catAlt)[_＿][0-9０-９]{1,4}",
    $script:RegexOptsIgnoreCase, $script:RegexTimeout)
Remove-Variable catAlt

# 自動検出（メールアドレス・日本の電話番号）
$script:EmailRegex = [regex]::new(
    '(?<![A-Za-z0-9._%+\-])[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}(?![A-Za-z0-9\-])',
    $script:RegexOpts, $script:RegexTimeout)
$script:PhoneRegex = [regex]::new(
    '(?<![0-9+\-])(?:' +
    '\+81[\- ]?[0-9]{1,4}[\- ][0-9]{1,4}[\- ][0-9]{3,4}' +   # +81-3-1234-5678
    '|0[0-9]{1,4}-[0-9]{1,4}-[0-9]{3,4}' +                    # 03-1234-5678 / 090-1234-5678
    '|0[0-9]{1,4}[(（][0-9]{1,4}[)）][0-9]{3,4}' +              # 03(1234)5678
    '|0[0-9]{9,10}' +                                         # 0312345678 / 09012345678
    ')(?![0-9\-])',
    $script:RegexOpts, $script:RegexTimeout)

$script:PromptHeader = (@(
        '以下の文章を添削してください。'
        'ただし、[[COMPANY_01]] などの二重角括弧で囲まれた識別子は、変更・省略せず、そのまま維持してください。'
        '添削後の文章のみを出力してください。'
        ''
        '【添削対象】'
    ) -join "`n") + "`n"

# ---------------------------------------------------------------------------
# 内部ヘルパー
# ---------------------------------------------------------------------------

function Get-EntryValue {
    param($Entry, [string]$Name)
    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains($Name)) { return $Entry[$Name] }
        return $null
    }
    $p = $Entry.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-TokenKey {
    # [[COMPANY_01]] と [[COMPANY_1]] を同じ番号として扱うための正規化キー
    param([string]$Category, [string]$Digits)
    $d = $Digits.TrimStart('0')
    if ($d -eq '') { $d = '0' }
    return '{0}_{1}' -f $Category.ToUpperInvariant(), $d
}

function New-Span {
    param([int]$Start, [int]$Length, [string]$Id, [string]$Kind)
    [pscustomobject]@{ Start = $Start; Length = $Length; Id = $Id; Kind = $Kind }
}

function Get-LineNumber {
    param([string]$Text, [int]$Index)
    # string 版の IndexOf はカルチャ依存（ICU では "`r`n" 内の "`n" を見つけない）なので char 版を使う
    $lf = [char]10
    $n = 1
    for ($i = $Text.IndexOf($lf); $i -ge 0 -and $i -lt $Index; $i = $Text.IndexOf($lf, $i + 1)) { $n++ }
    return $n
}

function New-MaskResult {
    param(
        [AllowNull()][string]$Text,
        [int]$Count = 0,
        $Used = @(),
        $InputSpans = @(),
        $OutputSpans = @(),
        $Warnings = @(),
        $Errors = @()
    )
    [pscustomobject]@{
        Text        = $Text
        Count       = $Count
        Used        = @($Used)
        InputSpans  = @($InputSpans)
        OutputSpans = @($OutputSpans)
        Warnings    = @($Warnings)
        Errors      = @($Errors)
        HasError    = (@($Errors).Count -gt 0)
    }
}

function Get-OrAddMaskId {
    param($Session, [string]$Original, [string]$Category, [string]$Source)
    $id = $null
    if ($Session.OriginalToId.TryGetValue($Original, [ref]$id)) { return $id }

    $n = 0
    [void]$Session.Counters.TryGetValue($Category, [ref]$n)
    do {
        $n++
        $key = '{0}_{1}' -f $Category, $n
    } while ($Session.Reserved.Contains($key) -or $Session.KeyToId.ContainsKey($key))
    $Session.Counters[$Category] = $n

    $id = '[[{0}_{1:D2}]]' -f $Category, $n
    $Session.Mappings[$id] = [pscustomobject]@{
        Id       = $id
        Original = $Original
        Category = $Category
        Source   = $Source
    }
    $Session.OriginalToId[$Original] = $id
    $Session.KeyToId[$key] = $id
    return $id
}

# ---------------------------------------------------------------------------
# 公開関数
# ---------------------------------------------------------------------------

function Get-TextMaskCategory {
    <# .SYNOPSIS カテゴリ一覧（Name / Label）を返す。 #>
    foreach ($k in $script:CategoryLabels.Keys) {
        [pscustomobject]@{ Name = $k; Label = $script:CategoryLabels[$k] }
    }
}

function ConvertTo-MaskCategory {
    <# .SYNOPSIS カテゴリ名を正規化する（不明なものは CUSTOM）。 #>
    param([AllowNull()][object]$Category)
    $c = ([string]$Category).Trim().ToUpperInvariant()
    if ($script:Categories -ccontains $c) { return $c }
    return 'CUSTOM'
}

function Test-MaskToken {
    <# .SYNOPSIS 文字列が識別子と同じ形式を含むか。 #>
    param([AllowEmptyString()][string]$Text)
    return $script:TokenRegex.IsMatch($Text)
}

function New-MaskMessage {
    <# .SYNOPSIS 警告・エラー 1 件を表すオブジェクト。Index は入力文章上の位置（なければ -1）。 #>
    param(
        [ValidateSet('Warning', 'Error')][string]$Level,
        [string]$Message,
        [int]$Index = -1,
        [int]$Length = 0
    )
    [pscustomobject]@{ Level = $Level; Message = $Message; Index = $Index; Length = $Length }
}

function New-MaskSession {
    <# .SYNOPSIS 空のセッション（対応表）を作る。メモリ上にだけ存在する。 #>
    param([string]$ProfileName = 'default')
    $ord = [StringComparer]::Ordinal
    [pscustomobject]@{
        Id             = [guid]::NewGuid().ToString('N').Substring(0, 8)
        ProfileName    = $ProfileName
        # 識別子 -> { Id, Original, Category, Source }
        Mappings       = [System.Collections.Generic.Dictionary[string, object]]::new($ord)
        # 原文字列 -> 識別子
        OriginalToId   = [System.Collections.Generic.Dictionary[string, string]]::new($ord)
        # 正規化キー（COMPANY_1）-> 識別子
        KeyToId        = [System.Collections.Generic.Dictionary[string, string]]::new($ord)
        Counters       = [System.Collections.Generic.Dictionary[string, int]]::new($ord)
        # 原文に元からあった識別子形式の文字列（この番号は発行しない）
        Reserved       = [System.Collections.Generic.HashSet[string]]::new($ord)
        # 自動検出のうち、ユーザーが取り消した値
        ExcludedValues = [System.Collections.Generic.HashSet[string]]::new($ord)
        # 直近のマスキングで使った識別子 -> 出現回数（復元時の検証用）
        LastMaskCounts = $null
        # マスキング後にまだ復元していないか
        HasUnrestored  = $false
    }
}

function Reset-MaskSession {
    <# .SYNOPSIS セッションの対応表・一時情報をすべて破棄する。 #>
    param([Parameter(Mandatory)][psobject]$Session)
    $Session.Mappings.Clear()
    $Session.OriginalToId.Clear()
    $Session.KeyToId.Clear()
    $Session.Counters.Clear()
    $Session.Reserved.Clear()
    $Session.ExcludedValues.Clear()
    $Session.LastMaskCounts = $null
    $Session.HasUnrestored = $false
    $Session.Id = [guid]::NewGuid().ToString('N').Substring(0, 8)
}

function Invoke-TextMask {
    <#
    .SYNOPSIS
        文章をマスキングする。

    .PARAMETER Entries
        辞書項目。Original / Category / Enabled を持つオブジェクトまたはハッシュテーブル。

    .OUTPUTS
        Text（変換結果。エラー時は $null）, Count, Used, InputSpans, OutputSpans, Warnings, Errors, HasError
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [AllowNull()][AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory)][psobject]$Session,
        [switch]$DetectEmail,
        [switch]$DetectPhone
    )

    $ord = [StringComparison]::Ordinal
    $warnings = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[object]]::new()

    # 1. 辞書の検証（空文字・重複）
    $literals = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $blank = 0
    $dup = 0
    foreach ($e in @($Entries)) {
        if ($null -eq $e) { continue }
        $enabled = Get-EntryValue $e 'Enabled'
        if ($null -ne $enabled -and -not [bool]$enabled) { continue }
        $orig = [string](Get-EntryValue $e 'Original')
        if ([string]::IsNullOrWhiteSpace($orig)) { $blank++; continue }
        if (-not $seen.Add($orig)) { $dup++; continue }
        $literals.Add([pscustomobject]@{
                Original = $orig
                Category = ConvertTo-MaskCategory (Get-EntryValue $e 'Category')
            })
    }
    if ($blank -gt 0) {
        $warnings.Add((New-MaskMessage Warning ('空の辞書項目 {0} 件を無視しました。' -f $blank)))
    }
    if ($dup -gt 0) {
        $warnings.Add((New-MaskMessage Warning ('同じ文字列の辞書項目が重複していたため {0} 件を統合しました（先に登録された項目を使用）。' -f $dup)))
    }
    if ($literals.Count -eq 0 -and -not $DetectEmail -and -not $DetectPhone) {
        $warnings.Add((New-MaskMessage Warning '辞書が 0 件です。置換したい文字列を辞書に登録してください。'))
    }

    if ($Text.Length -eq 0) {
        return New-MaskResult -Text '' -Warnings $warnings
    }

    # 2. 原文に元から含まれる識別子形式の文字列
    $blocked = [System.Collections.Generic.List[int[]]]::new()
    $reservedCount = 0
    $firstReserved = -1
    foreach ($m in $script:TokenRegex.Matches($Text)) {
        $key = Get-TokenKey $m.Groups[1].Value $m.Groups[2].Value
        if ($Session.KeyToId.ContainsKey($key)) {
            $errors.Add((New-MaskMessage Error ('原文に、このセッションで発行済みの識別子と同じ文字列 {0} が含まれています。復元時に区別できないため変換を中止しました（マスキング済みの文章をもう一度マスキングしていないか確認するか、新しいセッションを開始してください）。' -f $m.Value) $m.Index $m.Length))
        }
        else {
            [void]$Session.Reserved.Add($key)
            $reservedCount++
            if ($firstReserved -lt 0) { $firstReserved = $m.Index }
        }
        $blocked.Add([int[]]@($m.Index, ($m.Index + $m.Length)))
    }
    if ($errors.Count -gt 0) {
        return New-MaskResult -Text $null -Warnings $warnings -Errors $errors
    }
    if ($reservedCount -gt 0) {
        $warnings.Add((New-MaskMessage Warning ('原文に識別子と同じ形式の文字列が {0} 件あります。この部分は置換せず、同じ番号の識別子も発行しません（復元時は対応表にない識別子としてそのまま残ります）。' -f $reservedCount) $firstReserved))
    }

    # 3. 置換候補を集める
    $cands = [System.Collections.Generic.List[object]]::new()
    foreach ($lit in $literals) {
        $o = $lit.Original
        $i = $Text.IndexOf($o, $ord)
        while ($i -ge 0) {
            $cands.Add([pscustomobject]@{
                    Start = $i; Length = $o.Length; Original = $o
                    Category = $lit.Category; Source = 'dictionary'; Priority = 0
                })
            if ($i + 1 -ge $Text.Length) { break }
            $i = $Text.IndexOf($o, $i + 1, $ord)
        }
    }

    $detectors = [System.Collections.Generic.List[object]]::new()
    if ($DetectEmail) { $detectors.Add([pscustomobject]@{ Regex = $script:EmailRegex; Category = 'EMAIL'; Source = 'email'; Label = 'メールアドレス' }) }
    if ($DetectPhone) { $detectors.Add([pscustomobject]@{ Regex = $script:PhoneRegex; Category = 'PHONE'; Source = 'phone'; Label = '電話番号' }) }
    foreach ($d in $detectors) {
        try {
            foreach ($m in $d.Regex.Matches($Text)) {
                if ($Session.ExcludedValues.Contains($m.Value)) { continue }
                $cands.Add([pscustomobject]@{
                        Start = $m.Index; Length = $m.Length; Original = $m.Value
                        Category = $d.Category; Source = $d.Source; Priority = 1
                    })
            }
        }
        catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
            $warnings.Add((New-MaskMessage Warning ('{0}の自動検出が時間切れになったため、途中で打ち切りました。' -f $d.Label)))
        }
    }

    # 4. 重なりの解決: 左 → 長い → 辞書優先 で、左から貪欲に採用
    $sorted = $cands | Sort-Object -Stable -Property `
        @{ Expression = 'Start'; Ascending = $true },
        @{ Expression = 'Length'; Descending = $true },
        @{ Expression = 'Priority'; Ascending = $true }
    $selected = [System.Collections.Generic.List[object]]::new()
    $pos = 0
    foreach ($c in $sorted) {
        if ($c.Start -lt $pos) { continue }
        $end = $c.Start + $c.Length
        $hit = $false
        foreach ($b in $blocked) {
            if ($c.Start -lt $b[1] -and $end -gt $b[0]) { $hit = $true; break }
        }
        if ($hit) { continue }
        $selected.Add($c)
        $pos = $end
    }

    # 5. 採番と組み立て（1 回の走査）
    $sb = [System.Text.StringBuilder]::new($Text.Length + 16)
    $last = 0
    $counts = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $inSpans = [System.Collections.Generic.List[object]]::new()
    $outSpans = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $selected) {
        $id = Get-OrAddMaskId -Session $Session -Original $c.Original -Category $c.Category -Source $c.Source
        [void]$sb.Append($Text, $last, $c.Start - $last)
        $inSpans.Add((New-Span $c.Start $c.Length $id 'masked'))
        $outSpans.Add((New-Span $sb.Length $id.Length $id 'masked'))
        [void]$sb.Append($id)
        $last = $c.Start + $c.Length
        $n = 0
        [void]$counts.TryGetValue($id, [ref]$n)
        $counts[$id] = $n + 1
    }
    [void]$sb.Append($Text, $last, $Text.Length - $last)
    $out = $sb.ToString()

    # 6. マスキング漏れのチェック（識別子の中は見ない）
    $stripped = $script:TokenRegex.Replace($out, [string][char]0)
    $strippedKc = $null
    try { $strippedKc = $stripped.Normalize([System.Text.NormalizationForm]::FormKC) } catch { }
    foreach ($lit in $literals) {
        $o = $lit.Original
        if ($stripped.IndexOf($o, $ord) -ge 0) {
            $warnings.Add((New-MaskMessage Warning ('マスキング漏れ: 「{0}」が変換結果に残っています。' -f $o)))
        }
        elseif ($stripped.IndexOf($o, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $warnings.Add((New-MaskMessage Warning ('大文字・小文字だけが異なる「{0}」が変換結果に残っています。必要なら辞書に別の項目として登録してください。' -f $o)))
        }
        elseif ($null -ne $strippedKc) {
            $okc = $null
            try { $okc = $o.Normalize([System.Text.NormalizationForm]::FormKC) } catch { }
            if ($okc -and $strippedKc.IndexOf($okc, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $warnings.Add((New-MaskMessage Warning ('全角・半角などの表記が異なる「{0}」が変換結果に残っている可能性があります。必要なら辞書に別の項目として登録してください。' -f $o)))
            }
        }
    }
    if ($selected.Count -eq 0 -and ($literals.Count -gt 0 -or $DetectEmail -or $DetectPhone)) {
        $warnings.Add((New-MaskMessage Warning '置換対象が見つかりませんでした。'))
    }

    # 7. セッションの更新と結果
    $Session.LastMaskCounts = $counts
    $Session.HasUnrestored = ($selected.Count -gt 0)

    $used = foreach ($kv in $counts.GetEnumerator()) {
        $map = $Session.Mappings[$kv.Key]
        [pscustomobject]@{
            Id       = $kv.Key
            Original = $map.Original
            Category = $map.Category
            Source   = $map.Source
            Count    = $kv.Value
        }
    }

    return New-MaskResult -Text $out -Count $selected.Count -Used @($used) `
        -InputSpans $inSpans -OutputSpans $outSpans -Warnings $warnings
}

function Invoke-TextUnmask {
    <#
    .SYNOPSIS
        識別子を対応表で元の文字列に戻し、欠落・改変・破損を検証する。

    .DESCRIPTION
        対応表にない識別子や書式が崩れた識別子は推測で復元せず、そのまま残して警告します。
        警告には原文字列を含めません。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][psobject]$Session
    )

    $warnings = [System.Collections.Generic.List[object]]::new()
    if ($Session.Mappings.Count -eq 0) {
        $warnings.Add((New-MaskMessage Warning 'このセッションの対応表は空です。先にマスキングを行ってください（別のウィンドウやプロセスで発行した識別子は復元できません）。'))
    }
    if ($Text.Length -eq 0) {
        return New-MaskResult -Text '' -Warnings $warnings
    }

    $sb = [System.Text.StringBuilder]::new($Text.Length + 16)
    $last = 0
    $counts = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $inSpans = [System.Collections.Generic.List[object]]::new()
    $outSpans = [System.Collections.Generic.List[object]]::new()
    $strict = [System.Collections.Generic.List[int[]]]::new()
    # 入力位置 -> 出力位置の変換用（入力開始, 入力長, 出力長）
    $repl = [System.Collections.Generic.List[int[]]]::new()
    $warned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $restored = 0

    foreach ($m in $script:TokenRegex.Matches($Text)) {
        [void]$sb.Append($Text, $last, $m.Index - $last)
        $tok = $m.Value
        $strict.Add([int[]]@($m.Index, ($m.Index + $m.Length)))
        $map = $null
        if ($Session.Mappings.TryGetValue($tok, [ref]$map)) {
            $inSpans.Add((New-Span $m.Index $m.Length $tok 'restored'))
            $outSpans.Add((New-Span $sb.Length $map.Original.Length $tok 'restored'))
            [void]$sb.Append($map.Original)
            $repl.Add([int[]]@($m.Index, $m.Length, $map.Original.Length))
            $n = 0
            [void]$counts.TryGetValue($tok, [ref]$n)
            $counts[$tok] = $n + 1
            $restored++
        }
        else {
            $inSpans.Add((New-Span $m.Index $m.Length $tok 'unknown'))
            $outSpans.Add((New-Span $sb.Length $m.Length $tok 'unknown'))
            [void]$sb.Append($tok)
            if ($warned.Add($tok)) {
                $key = Get-TokenKey $m.Groups[1].Value $m.Groups[2].Value
                $similar = $null
                $line = Get-LineNumber $Text $m.Index
                if ($Session.KeyToId.TryGetValue($key, [ref]$similar)) {
                    $msg = '{0} 行目の識別子 {1} は対応表にありません（{2} の番号の書式が変わった可能性があります）。推測では復元せず、そのまま残しました。' -f $line, $tok, $similar
                }
                elseif ($Session.Reserved.Contains($key)) {
                    $msg = '{0} 行目の {1} は原文に元から含まれていた識別子形式の文字列で、対応表にはありません。そのまま残しました。' -f $line, $tok
                }
                else {
                    $msg = '{0} 行目に対応表にない識別子 {1} があります。推測では復元せず、そのまま残しました。' -f $line, $tok
                }
                $warnings.Add((New-MaskMessage Warning $msg $m.Index $m.Length))
            }
        }
        $last = $m.Index + $m.Length
    }
    [void]$sb.Append($Text, $last, $Text.Length - $last)
    $out = $sb.ToString()

    # 書式が崩れた識別子の候補
    try {
        foreach ($m in $script:LooseTokenRegex.Matches($Text)) {
            $mEnd = $m.Index + $m.Length
            $overlap = $false
            foreach ($r in $strict) {
                if ($m.Index -lt $r[1] -and $mEnd -gt $r[0]) { $overlap = $true; break }
            }
            if ($overlap) { continue }
            $delta = 0
            foreach ($r in $repl) {
                if ($r[0] + $r[1] -le $m.Index) { $delta += $r[2] - $r[1] }
            }
            $inSpans.Add((New-Span $m.Index $m.Length '' 'broken'))
            $outSpans.Add((New-Span ($m.Index + $delta) $m.Length '' 'broken'))
            $warnings.Add((New-MaskMessage Warning ('{0} 行目の「{1}」は識別子の書式が崩れている可能性があります。自動では復元しないので、必要なら手で直してください。' -f (Get-LineNumber $Text $m.Index), $m.Value) $m.Index $m.Length))
        }
    }
    catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
        $warnings.Add((New-MaskMessage Warning '書式が崩れた識別子の検査が時間切れになったため、途中で打ち切りました。'))
    }

    # 直近のマスキングとの比較（消失・回数変化）
    if ($null -ne $Session.LastMaskCounts) {
        foreach ($kv in $Session.LastMaskCounts.GetEnumerator()) {
            $n = 0
            [void]$counts.TryGetValue($kv.Key, [ref]$n)
            if ($n -eq 0) {
                $warnings.Add((New-MaskMessage Warning ('識別子 {0} が回答から消えています（マスキング時 {1} 回）。AI が省略・改変していないか確認してください。' -f $kv.Key, $kv.Value)))
            }
            elseif ($n -ne $kv.Value) {
                $warnings.Add((New-MaskMessage Warning ('識別子 {0} の出現回数が変化しました（マスキング時 {1} 回 → 回答 {2} 回）。文章の再構成による正常な変化か確認してください。' -f $kv.Key, $kv.Value, $n)))
            }
        }
    }

    $Session.HasUnrestored = $false

    $used = foreach ($kv in $counts.GetEnumerator()) {
        [pscustomobject]@{ Id = $kv.Key; Count = $kv.Value }
    }
    $sortedIn = $inSpans | Sort-Object -Stable -Property Start
    $sortedOut = $outSpans | Sort-Object -Stable -Property Start
    return New-MaskResult -Text $out -Count $restored -Used @($used) `
        -InputSpans @($sortedIn) -OutputSpans @($sortedOut) -Warnings $warnings
}

function Get-CorrectionPrompt {
    <# .SYNOPSIS マスキング済み文章に、識別子を維持するよう求める添削指示を付ける。 #>
    param([AllowEmptyString()][string]$MaskedText = '')
    return $script:PromptHeader + $MaskedText
}

function Find-MaskPattern {
    <#
    .SYNOPSIS
        文字列がメールアドレス・電話番号の形式に完全一致するかを返す（登録時のカテゴリ推定用）。
    #>
    param([AllowEmptyString()][string]$Text)
    try {
        $m = $script:EmailRegex.Match($Text)
        if ($m.Success -and $m.Index -eq 0 -and $m.Length -eq $Text.Length) { return 'EMAIL' }
        $m = $script:PhoneRegex.Match($Text)
        if ($m.Success -and $m.Index -eq 0 -and $m.Length -eq $Text.Length) { return 'PHONE' }
    }
    catch [System.Text.RegularExpressions.RegexMatchTimeoutException] { }
    return $null
}

Export-ModuleMember -Function @(
    'Get-TextMaskCategory'
    'ConvertTo-MaskCategory'
    'Test-MaskToken'
    'New-MaskMessage'
    'New-MaskSession'
    'Reset-MaskSession'
    'Invoke-TextMask'
    'Invoke-TextUnmask'
    'Get-CorrectionPrompt'
    'Find-MaskPattern'
)
