# 変換対象のディレクトリ（カレントディレクトリ）
$sourceDir = Get-Location

# すべての .png ファイルを取得
Get-ChildItem -Path $sourceDir -Filter *.png | ForEach-Object {
    $pngFile = $_.FullName
    $epsFile = [System.IO.Path]::ChangeExtension($pngFile, ".eps")

    # ImageMagick の magick コマンドで変換
    magick "$pngFile" "$epsFile"

    Write-Host "変換完了: $($_.Name) → $(Split-Path $epsFile -Leaf)" -ForegroundColor Green
}