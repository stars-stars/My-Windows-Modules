<#
.SYNOPSIS
    ディレクトリ直下の各項目の容量を色分けして表示する。

.DESCRIPTION
    ディレクトリはシアン、.exe は緑、その他は白で表示し、最後に合計を出します。
    隠しファイルも集計に含めます。シンボリックリンクは二重計上を避けるためスキップします。
    アクセスできないディレクトリは黙って飛ばします。

.PARAMETER Dir
    対象ディレクトリ。既定はカレントディレクトリ。

.EXAMPLE
    Show-DirectorySize.ps1 -Dir C:\tmp
#>
param(
    [string]$Dir = "./"
)

# 合計サイズ表示用変数
$totalSize = 0

# 直下の項目ごとにサイズを集計（隠しファイルも含める）
$rows = Get-ChildItem -LiteralPath $Dir -Force | ForEach-Object {
    $item = $_
    # シンボリックリンクならスキップ
    if ($item.LinkType) {
        return
    }

    if ($item.PSIsContainer) {
        # ディレクトリの場合（アクセス拒否のサブディレクトリは無視する）
        $size = (Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        $color = "Cyan"
    }
    elseif ($item.Extension -eq ".exe") {
        # .exeファイルの場合
        $size = $item.Length
        $color = "Green"
    }
    else {
        # その他のファイル
        $size = $item.Length
        $color = "White"
    }
    [pscustomobject]@{ Name = $item.Name; Size = [long]$size; Color = $color }
}

# 大きい順に表示
foreach ($r in ($rows | Sort-Object Size -Descending)) {
    $totalSize += $r.Size
    $sizeMB = [math]::Round($r.Size / 1MB, 2)
    Write-Host "$($r.Name) : $sizeMB MB" -ForegroundColor $r.Color
}

# 合計サイズをMBで表示
$totalMB = [math]::Round($totalSize / 1MB, 2)
Write-Host "-----------------------------"
Write-Host "合計容量 : $totalMB MB" -ForegroundColor "Magenta"
