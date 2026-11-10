<#
.SYNOPSIS
    カレントディレクトリの PNG を一括で JPG に変換する（ImageMagick 使用）。

.DESCRIPTION
    透過部分は白で塗りつぶします（JPG は透過を扱えず、そのままだと黒くなるため）。
    元の PNG は残します。失敗したファイルがあれば終了コード 1 を返します。
#>

if (-not (Get-Command magick -ErrorAction SilentlyContinue)) {
    Write-Host "ImageMagick の magick コマンドが見つかりません。インストールして PATH に追加してください。" -ForegroundColor Red
    exit 1
}

# 変換対象のディレクトリ（カレントディレクトリ）
$sourceDir = Get-Location
$failed = 0

# すべての .png ファイルを取得
Get-ChildItem -Path $sourceDir -Filter *.png | ForEach-Object {
    $pngFile = $_.FullName
    $jpgFile = [System.IO.Path]::ChangeExtension($pngFile, ".jpg")

    # ImageMagick の magick コマンドで変換（透過部分は白背景に合成）
    magick "$pngFile" -background white -alpha remove -alpha off "$jpgFile"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "変換完了: $($_.Name) → $(Split-Path $jpgFile -Leaf)" -ForegroundColor Green
    } else {
        Write-Host "変換失敗: $($_.Name)" -ForegroundColor Red
        $failed++
    }
}

if ($failed -gt 0) { exit 1 }
