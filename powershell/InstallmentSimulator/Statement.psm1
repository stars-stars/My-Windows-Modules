#Requires -Version 7.0
<#
.SYNOPSIS
    クレジットカード請求明細 CSV（Shift_JIS）の読み込み。

.DESCRIPTION
    想定する形式（Amazon Mastercard / 三井住友カード系の明細ダウンロード）:
        1 行目   : 氏名, カード番号（マスク済み）, カード名
        明細行   : 利用日, 利用先, 利用金額, 支払回数, 今回回数, 今回請求額, 備考
        最終行   : (空), (空), (空), (空), (空), 合計, (空)
    数字は全角のことがあるので NFKC 正規化してから数値にします。

    明細の種別（Kind）:
        Changeable : 1 回払い・金額 > 0。分割に変更できる候補
        Refund     : 金額 < 0（返品など）。今月に一括で差し引く
        Existing   : すでに分割払い（支払回数 > 1）。残り回数を翌月以降も同額で計上する
#>

Set-StrictMode -Version 3.0

function ConvertTo-NormalizedText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    # 全角英数・全角スペースを半角に揃える
    return $Text.Normalize([System.Text.NormalizationForm]::FormKC).Trim()
}

function ConvertTo-IntOrNull {
    param([AllowNull()][string]$Text)
    $t = (ConvertTo-NormalizedText $Text) -replace '[,\s円]', ''
    if ($t -eq '') { return $null }
    $n = 0L
    if ([long]::TryParse($t, [ref]$n)) { return $n }
    return $null
}

function Get-BillingMonthFromPath {
    <#
    .SYNOPSIS
        ファイル名の先頭 yyyyMM から請求月（その月の 1 日）を返す。取れなければ $null。
    #>
    param([Parameter(Mandatory)][string]$Path)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ($name -match '^(\d{4})(\d{2})') {
        $y = [int]$Matches[1]; $m = [int]$Matches[2]
        if ($m -ge 1 -and $m -le 12) { return [datetime]::new($y, $m, 1) }
    }
    return $null
}

function Import-CardStatement {
    <#
    .SYNOPSIS
        請求明細 CSV を読み、明細の一覧と合計照合の結果を返す。

    .PARAMETER Path
        CSV のパス。

    .PARAMETER BillingMonth
        請求月。省略時はファイル名の yyyyMM、それも無ければ今月。

    .PARAMETER EncodingName
        文字コード。既定は shift_jis。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Nullable[datetime]]$BillingMonth,
        [string]$EncodingName = 'shift_jis'
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "明細ファイルが見つかりません: $full"
    }
    $encoding = [System.Text.Encoding]::GetEncoding($EncodingName)
    $lines = [System.IO.File]::ReadAllLines($full, $encoding)

    if (-not $BillingMonth) { $BillingMonth = Get-BillingMonthFromPath -Path $full }
    if (-not $BillingMonth) { $BillingMonth = [datetime]::new((Get-Date).Year, (Get-Date).Month, 1) }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $items = [System.Collections.Generic.List[object]]::new()
    $cardName = ''
    $cardNumber = ''
    $statedTotal = $null

    $header = 'Date', 'Merchant', 'Amount', 'Count', 'Current', 'Billed', 'Note'
    $lineNo = 0
    foreach ($line in $lines) {
        $lineNo++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $f = @(ConvertFrom-Csv -InputObject $line -Header $header)[0]

        $dateText = ConvertTo-NormalizedText $f.Date
        $date = [datetime]::MinValue
        $isDate = [datetime]::TryParseExact($dateText, 'yyyy/MM/dd', [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$date)

        if (-not $isDate) {
            if ($dateText -eq '' -and $null -ne (ConvertTo-IntOrNull $f.Billed)) {
                # 合計行
                $statedTotal = ConvertTo-IntOrNull $f.Billed
            }
            elseif ($items.Count -eq 0 -and $cardName -eq '') {
                # 1 行目（氏名, カード番号, カード名）。氏名は保持しない
                $cardNumber = ConvertTo-NormalizedText $f.Merchant
                $cardName = ConvertTo-NormalizedText $f.Amount
            }
            else {
                $warnings.Add("$lineNo 行目を読み飛ばしました（形式が想定外）")
            }
            continue
        }

        $amount = ConvertTo-IntOrNull $f.Amount
        $count = ConvertTo-IntOrNull $f.Count
        $current = ConvertTo-IntOrNull $f.Current
        $billed = ConvertTo-IntOrNull $f.Billed
        if ($null -eq $amount) { $warnings.Add("$lineNo 行目: 利用金額を読めません"); continue }
        if ($null -eq $count -or $count -lt 1) { $count = 1 }
        if ($null -eq $current -or $current -lt 1) { $current = 1 }
        if ($null -eq $billed) { $billed = $amount }

        $kind = if ($count -gt 1) { 'Existing' } elseif ($amount -lt 0) { 'Refund' } else { 'Changeable' }
        $remaining = if ($kind -eq 'Existing') { [math]::Max(0, $count - $current) } else { 0 }

        $items.Add([pscustomobject]@{
            Id        = $items.Count
            Date      = $date
            Merchant  = ConvertTo-NormalizedText $f.Merchant
            Amount    = [long]$amount
            Count     = [int]$count
            Current   = [int]$current
            Billed    = [long]$billed
            Note      = ConvertTo-NormalizedText $f.Note
            Kind      = $kind
            Remaining = [int]$remaining     # 翌月以降に残っている回数（既存分割のみ）
        })
    }

    $computed = [long]0
    foreach ($i in $items) { $computed += $i.Billed }
    if ($null -eq $statedTotal) {
        $warnings.Add('合計行が見つかりません')
    }
    elseif ($statedTotal -ne $computed) {
        $warnings.Add(('明細の合計 {0:N0} 円が、ファイルの合計 {1:N0} 円と一致しません' -f $computed, $statedTotal))
    }

    return [pscustomobject]@{
        Path          = $full
        CardName      = $cardName
        CardNumber    = $cardNumber
        BillingMonth  = [datetime]$BillingMonth
        Items         = $items.ToArray()
        StatedTotal   = $statedTotal
        ComputedTotal = $computed
        Warnings      = $warnings.ToArray()
    }
}

function Get-StatementFile {
    <#
    .SYNOPSIS
        明細 CSV の一覧を返す（請求月の新しい順。ファイル名に yyyyMM がないものは後ろに名前順）。

    .PARAMETER Directory
        明細フォルダ。直下の *.csv を対象にする。フォルダがなければ空。

    .PARAMETER Path
        1 ファイルだけの情報を返す（明細フォルダの外のファイル用）。

    .OUTPUTS
        Path（フルパス）, Name, BillingMonth（$null あり）, Label（リストの表示名）
    #>
    [CmdletBinding(DefaultParameterSetName = 'Directory')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Directory')][string]$Directory,
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path
    )
    $toEntry = {
        param([string]$FullPath)
        $month = Get-BillingMonthFromPath -Path $FullPath
        $name = [System.IO.Path]::GetFileName($FullPath)
        $label = if ($month) { '{0} 請求（{1}）' -f $month.ToString('yyyy年M月'), $name } else { $name }
        [pscustomobject]@{ Path = $FullPath; Name = $name; BillingMonth = $month; Label = $label }
    }
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        return (& $toEntry ([System.IO.Path]::GetFullPath($Path)))
    }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $entries = Get-ChildItem -LiteralPath $Directory -Filter '*.csv' -File |
        ForEach-Object { & $toEntry $_.FullName }
    $withMonth = @($entries | Where-Object BillingMonth | Sort-Object BillingMonth, Name -Descending)
    $others = @($entries | Where-Object { -not $_.BillingMonth } | Sort-Object Name)
    return @($withMonth + $others)
}

Export-ModuleMember -Function Import-CardStatement, Get-BillingMonthFromPath, ConvertTo-NormalizedText, Get-StatementFile
