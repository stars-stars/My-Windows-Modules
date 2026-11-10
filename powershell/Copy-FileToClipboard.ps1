<#
.SYNOPSIS
    ファイルをエクスプローラーの Ctrl+C と同じ形でクリップボードにコピーする。

.DESCRIPTION
    指定したファイル / フォルダをファイルドロップリストとしてクリップボードに設定します。
    エクスプローラー、Slack、Teams、メールなど、ファイルの貼り付けに対応したアプリへ
    Ctrl+V でそのまま貼り付け（添付）できます。

    -Path はワイルドカードが使えます。パイプラインから Get-ChildItem の結果も受け取れます。
    複数指定した場合はまとめて 1 回でコピーします。

.PARAMETER Path
    コピーするファイル / フォルダのパス（ワイルドカード可）。

.PARAMETER LiteralPath
    コピーするファイル / フォルダのパス（ワイルドカードとして解釈しない）。

.EXAMPLE
    Copy-FileToClipboard.ps1 .\report.pdf

.EXAMPLE
    Copy-FileToClipboard.ps1 *.png, .\docs

.EXAMPLE
    Get-ChildItem -Filter *.log | Copy-FileToClipboard.ps1
#>
[CmdletBinding(DefaultParameterSetName = 'Path')]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path', ValueFromPipeline)]
    [SupportsWildcards()]
    [string[]]$Path,

    [Parameter(Mandatory, ParameterSetName = 'LiteralPath', ValueFromPipelineByPropertyName)]
    [Alias('PSPath', 'FullName')]
    [string[]]$LiteralPath
)

begin {
    # Clipboard API は STA スレッドでしか動かない
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'クリップボードを操作するには STA モードの PowerShell が必要です（pwsh -STA で起動してください）。'
    }

    Add-Type -AssemblyName System.Windows.Forms

    $files = [System.Collections.Specialized.StringCollection]::new()
}

process {
    $items = if ($PSCmdlet.ParameterSetName -eq 'Path') {
        Get-Item -Path $Path
    } else {
        Get-Item -LiteralPath $LiteralPath
    }

    foreach ($item in $items) {
        if ($item.PSProvider.Name -ne 'FileSystem') {
            Write-Error "ファイルシステム上のパスではありません: $($item.PSPath)"
            continue
        }
        if (-not $files.Contains($item.FullName)) {
            [void]$files.Add($item.FullName)
        }
    }
}

end {
    if ($files.Count -eq 0) {
        Write-Warning 'コピーするファイルがありません。'
        return
    }

    $data = [System.Windows.Forms.DataObject]::new()
    $data.SetFileDropList($files)

    # 貼り付け時の動作を「コピー」にする（DROPEFFECT_COPY = 1）。
    # byte[] を渡すと BinaryFormatter でシリアライズされてしまうため MemoryStream で渡す。
    $data.SetData('Preferred DropEffect', [System.IO.MemoryStream]::new([byte[]](1, 0, 0, 0)))

    # 他プロセスがクリップボードを使用中の場合に備えてリトライする（10 回 x 100ms）
    [System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 10, 100)

    Write-Host "$($files.Count) 件をクリップボードにコピーしました。" -ForegroundColor Green
    foreach ($f in $files) { Write-Host "  $f" -ForegroundColor DarkGray }
}
