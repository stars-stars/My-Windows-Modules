#Requires -Version 7.0
<#
.SYNOPSIS
    分割払いの手数料と月別の支払額を計算する。

.DESCRIPTION
    元利均等方式・実質年率で計算します（三井住友カード系の「100円あたりの分割払い手数料」表と同じ式）。
        月利 r = 年率 / 12
        100 円あたり手数料 = (n × r / (1 − (1 + r)^−n) − 1) × 100   （小数第 2 位に丸める）
        手数料   = 利用金額 × 係数 / 100（円未満切り捨て）
        各回     = (利用金額 + 手数料) / n の切り捨て。端数は初回に加える
    1 回・2 回払いは手数料なし。
    実際の請求額はカード会社の端数処理で数円ずれることがあります（概算）。
#>

Set-StrictMode -Version 3.0

function Get-InstallmentFeeRate {
    <#
    .SYNOPSIS
        利用金額 100 円あたりの分割払い手数料（円, 小数第 2 位）を返す。
    #>
    param(
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][double]$AnnualRate   # 実質年率（%）
    )
    if ($Count -lt 1) { throw "支払回数は 1 以上にしてください: $Count" }
    if ($Count -le 2 -or $AnnualRate -le 0) { return [decimal]0 }
    $r = $AnnualRate / 100 / 12
    $factor = $Count * $r / (1 - [math]::Pow(1 + $r, -$Count))
    # double -> decimal に変換してから丸める（2.5099999… のような二進誤差を残さない）
    return [math]::Round([decimal](($factor - 1) * 100), 2, [System.MidpointRounding]::AwayFromZero)
}

function Get-InstallmentPayment {
    <#
    .SYNOPSIS
        1 件の利用を n 回払いにしたときの手数料と各回の支払額を返す。

    .OUTPUTS
        Fee（手数料合計）, Payments（各回の支払額 long[]）, FeeParts（各回に含まれる手数料 long[]）, Total
    #>
    param(
        [Parameter(Mandatory)][long]$Amount,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][double]$AnnualRate
    )
    if ($Count -lt 1) { throw "支払回数は 1 以上にしてください: $Count" }
    $rate = Get-InstallmentFeeRate -Count $Count -AnnualRate $AnnualRate
    $fee = if ($Amount -gt 0) { [long][math]::Floor([decimal]$Amount * $rate / 100) } else { [long]0 }

    $payments = [long[]]::new($Count)
    $feeParts = [long[]]::new($Count)
    $total = $Amount + $fee
    $each = [long][math]::Floor($total / $Count)
    $feeEach = [long][math]::Floor($fee / $Count)
    for ($k = 0; $k -lt $Count; $k++) {
        $payments[$k] = $each
        $feeParts[$k] = $feeEach
    }
    # 端数は初回に寄せる
    $payments[0] += $total - $each * $Count
    $feeParts[0] += $fee - $feeEach * $Count

    return [pscustomobject]@{
        Amount   = $Amount
        Count    = $Count
        Rate     = $rate
        Fee      = $fee
        Total    = $total
        Payments = $payments
        FeeParts = $feeParts
    }
}

function Get-PaymentSchedule {
    <#
    .SYNOPSIS
        明細全体について、変更前（明細どおり）と変更後（指定した回数）の月別請求額を比べる。

    .PARAMETER Statement
        Import-CardStatement の結果。

    .PARAMETER Counts
        明細 Id -> 支払回数 のハッシュテーブル。Kind が Changeable の明細だけを見る。
        指定のない明細は 1 回払いのまま。

    .PARAMETER AnnualRate
        実質年率（%）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Statement,
        [hashtable]$Counts = @{},
        [Parameter(Mandatory)][double]$AnnualRate
    )

    $before = [System.Collections.Generic.Dictionary[int, long]]::new()
    $after = [System.Collections.Generic.Dictionary[int, long]]::new()
    $fees = [System.Collections.Generic.Dictionary[int, long]]::new()
    $add = {
        param($dict, [int]$k, [long]$v)
        if ($dict.ContainsKey($k)) { $dict[$k] += $v } else { $dict[$k] = $v }
    }

    $itemResults = foreach ($item in $Statement.Items) {
        switch ($item.Kind) {
            'Changeable' {
                $n = 1
                if ($Counts.ContainsKey($item.Id) -and [int]$Counts[$item.Id] -ge 1) { $n = [int]$Counts[$item.Id] }
                $p = Get-InstallmentPayment -Amount $item.Amount -Count $n -AnnualRate $AnnualRate
                & $add $before 0 $item.Amount
                for ($k = 0; $k -lt $n; $k++) {
                    & $add $after $k $p.Payments[$k]
                    & $add $fees $k $p.FeeParts[$k]
                }
                [pscustomobject]@{
                    Id = $item.Id; Count = $n; Rate = $p.Rate; Fee = $p.Fee
                    ThisMonth = $p.Payments[0]; Total = $p.Total
                }
            }
            'Existing' {
                # 今回分と、残り回数ぶんを同額で計上する（どちらのプランでも同じ）
                for ($k = 0; $k -le $item.Remaining; $k++) {
                    & $add $before $k $item.Billed
                    & $add $after $k $item.Billed
                }
                [pscustomobject]@{
                    Id = $item.Id; Count = $item.Count; Rate = $null; Fee = $null
                    ThisMonth = $item.Billed; Total = $item.Billed * ($item.Remaining + 1)
                }
            }
            default {
                # Refund など: 今月に一括
                & $add $before 0 $item.Billed
                & $add $after 0 $item.Billed
                [pscustomobject]@{
                    Id = $item.Id; Count = 1; Rate = $null; Fee = $null
                    ThisMonth = $item.Billed; Total = $item.Billed
                }
            }
        }
    }

    $last = 0
    foreach ($k in @($before.Keys) + @($after.Keys)) { if ($k -gt $last) { $last = $k } }

    $months = for ($k = 0; $k -le $last; $k++) {
        $b = if ($before.ContainsKey($k)) { $before[$k] } else { [long]0 }
        $a = if ($after.ContainsKey($k)) { $after[$k] } else { [long]0 }
        $f = if ($fees.ContainsKey($k)) { $fees[$k] } else { [long]0 }
        [pscustomobject]@{
            Index  = $k
            Month  = $Statement.BillingMonth.AddMonths($k)
            Before = $b
            After  = $a
            Diff   = $a - $b
            Fee    = $f
        }
    }
    $months = @($months)

    $totalBefore = [long]0; $totalAfter = [long]0; $totalFee = [long]0
    $maxBefore = [long]0; $maxAfter = [long]0
    $lastBefore = 0; $lastAfter = 0
    foreach ($m in $months) {
        $totalBefore += $m.Before; $totalAfter += $m.After; $totalFee += $m.Fee
        if ($m.Before -gt $maxBefore) { $maxBefore = $m.Before }
        if ($m.After -gt $maxAfter) { $maxAfter = $m.After }
        if ($m.Before -ne 0) { $lastBefore = $m.Index }
        if ($m.After -ne 0) { $lastAfter = $m.Index }
    }

    return [pscustomobject]@{
        AnnualRate      = $AnnualRate
        Items           = @($itemResults)
        Months          = $months
        ThisMonthBefore = $months[0].Before
        ThisMonthAfter  = $months[0].After
        TotalBefore     = $totalBefore
        TotalAfter      = $totalAfter
        TotalFee        = $totalFee
        MaxBefore       = $maxBefore
        MaxAfter        = $maxAfter
        LastMonthBefore = $Statement.BillingMonth.AddMonths($lastBefore)
        LastMonthAfter  = $Statement.BillingMonth.AddMonths($lastAfter)
    }
}

Export-ModuleMember -Function Get-InstallmentFeeRate, Get-InstallmentPayment, Get-PaymentSchedule
