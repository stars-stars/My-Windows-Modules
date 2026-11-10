<#
.SYNOPSIS
    カレントディレクトリの PNG を一括で EPS に変換する（ImageMagick 使用）。

.DESCRIPTION
    LaTeX に図を貼るとき用です。元の PNG は残します。
    失敗したファイルがあれば終了コード 1 を返します。
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
    $epsFile = [System.IO.Path]::ChangeExtension($pngFile, ".eps")

    # ImageMagick の magick コマンドで変換
    magick "$pngFile" "$epsFile"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "変換完了: $($_.Name) → $(Split-Path $epsFile -Leaf)" -ForegroundColor Green
    } else {
        Write-Host "変換失敗: $($_.Name)" -ForegroundColor Red
        $failed++
    }
}

if ($failed -gt 0) { exit 1 }
