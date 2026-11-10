param(
    [string]$Dir = "./"
)
# 合計サイズ表示用変数
$totalSize = 0

# 現在のディレクトリにあるすべてのディレクトリを取得
Get-ChildItem -Path $Dir | ForEach-Object {
    $item = $_
    # シンボリックリンクならスキップ
    if ($item.LinkType) {
        return
    }

    $itemPath = $item.FullName
    $size = 0
    if ($item.PSIsContainer) {
        # ディレクトリの場合
        $size = (Get-ChildItem -Recurse -File -Path $itemPath | Measure-Object -Property Length -Sum).Sum
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
    $sizeMB = [math]::Round($size / 1MB, 2)
    $totalSize += $size
    Write-Host "$($_.Name) : $sizeMB MB" -ForegroundColor $color
}

# 合計サイズをMBで表示
$totalMB = [math]::Round($totalSize / 1MB, 2)
Write-Host "-----------------------------"
Write-Host "合計容量 : $totalMB MB" -ForegroundColor "Magenta"
return $items