# 変換対象のディレクトリ（カレントディレクトリ）
$sourceDir = Get-Location

# すべての .png ファイルを取得
Get-ChildItem -Path $sourceDir -Filter *.png | ForEach-Object {
    $pngFile = $_.FullName
    $jpgFile = [System.IO.Path]::ChangeExtension($pngFile, ".jpg")

    # ImageMagick の magick コマンドで変換
    magick "$pngFile" "$jpgFile"

    Write-Host "変換完了: $($_.Name) → $(Split-Path $jpgFile -Leaf)" -ForegroundColor Green
}