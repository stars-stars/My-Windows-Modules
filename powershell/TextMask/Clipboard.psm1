#Requires -Version 7.0
<#
.SYNOPSIS
    TextMask のクリップボード操作（STA スレッドが必要）。

.DESCRIPTION
    書き込み時は Windows 定義のクリップボード形式を併せて置き、
    クリップボード履歴（Win+V）・クラウド同期・クリップボード監視ツールの対象外にするよう要求します。
      - CanIncludeInClipboardHistory = 0
      - CanUploadToCloudClipboard    = 0
      - ExcludeClipboardContentFromMonitorProcessing
    これは「要求」であり、対応していないクリップボード管理ツールには効きません。
    また、他のアプリが先にコピーした内容や過去の履歴は制御できません。
#>

Set-StrictMode -Version 3.0
Add-Type -AssemblyName System.Windows.Forms

function Assert-Sta {
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'クリップボードを操作するには STA モードの PowerShell が必要です（pwsh -STA で起動してください）。'
    }
}

function New-DwordStream {
    param([int]$Value)
    return [System.IO.MemoryStream]::new([BitConverter]::GetBytes([int]$Value))
}

function Get-TextMaskClipboardText {
    <# .SYNOPSIS クリップボードのテキストを返す（なければ空文字）。使用中なら数回再試行する。 #>
    Assert-Sta
    for ($i = 0; $i -lt 5; $i++) {
        try {
            if ([System.Windows.Forms.Clipboard]::ContainsText()) {
                return [System.Windows.Forms.Clipboard]::GetText([System.Windows.Forms.TextDataFormat]::UnicodeText)
            }
            return ''
        }
        catch [System.Runtime.InteropServices.ExternalException] {
            Start-Sleep -Milliseconds 100
        }
    }
    throw 'クリップボードを読み取れませんでした（他のアプリが使用中の可能性があります）。'
}

function Set-TextMaskClipboardText {
    <# .SYNOPSIS テキストを、履歴・クラウド同期の対象外としてクリップボードに書き込む。 #>
    param([Parameter(Mandatory)][string]$Text)
    Assert-Sta
    $data = [System.Windows.Forms.DataObject]::new()
    $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $Text)
    $data.SetData('CanIncludeInClipboardHistory', (New-DwordStream 0))
    $data.SetData('CanUploadToCloudClipboard', (New-DwordStream 0))
    $data.SetData('ExcludeClipboardContentFromMonitorProcessing', (New-DwordStream 0))
    # copy = $true: プロセス終了後も内容を残す / 使用中なら 100ms 間隔で 10 回まで再試行
    try {
        [System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 10, 100)
    }
    catch [System.Runtime.InteropServices.ExternalException] {
        throw 'クリップボードに書き込めませんでした（他のアプリが使用中の可能性があります）。'
    }
}

function Clear-TextMaskClipboard {
    <# .SYNOPSIS クリップボードを空にする（Windows のクリップボード履歴に残った項目は消えない）。 #>
    Assert-Sta
    try {
        [System.Windows.Forms.Clipboard]::Clear()
    }
    catch [System.Runtime.InteropServices.ExternalException] {
        throw 'クリップボードを消去できませんでした（他のアプリが使用中の可能性があります）。'
    }
}

Export-ModuleMember -Function Get-TextMaskClipboardText, Set-TextMaskClipboardText, Clear-TextMaskClipboard
