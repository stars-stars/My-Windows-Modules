#Requires -Version 7.0
<#
.SYNOPSIS
    TextMask の永続辞書（プロファイル）と UI 設定の読み書き。

.DESCRIPTION
    データディレクトリ（既定はリポジトリ外の data\textmask）に次のファイルを置きます。

      settings.json           UI 設定（機密情報は含めない）
      profiles\<名前>.json    永続辞書（平文 JSON。エディタで直接編集してもよい）

    辞書ファイルの形式
      {
        "schemaVersion": 1,
        "profile": "default",
        "entries": [
          { "original": "株式会社サンプル", "category": "COMPANY", "enabled": true }
        ]
      }

    読み込みに失敗した辞書ファイルは、手で修正されるまで上書き保存しません。
    エラーメッセージには辞書の中身（原文字列）を含めません。
#>

Set-StrictMode -Version 3.0

# MaskEngine.psm1 と同じカテゴリ（このモジュール単体でも検証できるよう重複して持つ）
$script:Categories = @('COMPANY', 'PERSON', 'PLACE', 'PRODUCT', 'PROJECT', 'EMAIL', 'PHONE', 'CUSTOM')
$script:SchemaVersion = 1
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-JsonValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Write-TextFileAtomic {
    # 一時ファイルに書いてから置き換える（書き込み途中で落ちても元のファイルが壊れない）
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
    $tmp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        [System.IO.File]::WriteAllText($tmp, $Content, $script:Utf8NoBom)
        # 同じディレクトリ内の上書き移動（NTFS では置き換えは原子的）。
        # File.Replace に PowerShell から $null を渡すと空文字列になり失敗するので使わない。
        [System.IO.File]::Move($tmp, $Path, $true)
    }
    finally {
        if ([System.IO.File]::Exists($tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Test-TextMaskProfileName {
    <# .SYNOPSIS プロファイル名として使えるか（英数字・_・- のみ、40 文字以内）。 #>
    param([AllowEmptyString()][AllowNull()][string]$Name)
    return ($Name -cmatch '^[A-Za-z0-9_\-]{1,40}$')
}

function Get-TextMaskProfilePath {
    param([Parameter(Mandatory)][string]$DataDirectory, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-TextMaskProfileName $Name)) {
        throw ('プロファイル名が不正です（英数字・_・- のみ）: {0}' -f $Name)
    }
    return Join-Path (Join-Path $DataDirectory 'profiles') ($Name + '.json')
}

function Get-TextMaskProfileList {
    <# .SYNOPSIS 既存のプロファイル名の一覧（default は常に含む）。 #>
    param([Parameter(Mandatory)][string]$DataDirectory)
    $names = [System.Collections.Generic.List[string]]::new()
    $names.Add('default')
    $dir = Join-Path $DataDirectory 'profiles'
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object Name) {
            $n = $f.BaseName
            if ((Test-TextMaskProfileName $n) -and -not $names.Contains($n)) { $names.Add($n) }
        }
    }
    return , $names.ToArray()
}

function New-TextMaskEntry {
    <# .SYNOPSIS 辞書項目オブジェクトを作る。 #>
    param(
        [Parameter(Mandatory)][string]$Original,
        [string]$Category = 'CUSTOM',
        [bool]$Enabled = $true
    )
    $c = $Category.Trim().ToUpperInvariant()
    if ($script:Categories -cnotcontains $c) { $c = 'CUSTOM' }
    [pscustomobject]@{ Original = $Original; Category = $c; Enabled = $Enabled }
}

function Import-TextMaskProfile {
    <#
    .SYNOPSIS
        辞書ファイルを読み込む。

    .OUTPUTS
        Name, Path, Exists, Entries（List）, Warnings（List）, Error（読めなかった場合のメッセージ。なければ $null）
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$Name
    )
    $path = Get-TextMaskProfilePath -DataDirectory $DataDirectory -Name $Name
    $result = [pscustomobject]@{
        Name     = $Name
        Path     = $path
        Exists   = $false
        Entries  = [System.Collections.Generic.List[object]]::new()
        Warnings = [System.Collections.Generic.List[string]]::new()
        Error    = $null
    }
    if (-not (Test-Path -LiteralPath $path)) { return $result }
    $result.Exists = $true

    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    }
    catch {
        $result.Error = '辞書ファイルを開けませんでした（他のアプリで使用中か、アクセス権がありません）。'
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $result.Error = '辞書ファイルが空です。'
        return $result
    }
    try {
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        # 例外メッセージには辞書の中身が含まれ得るので出さない
        $result.Error = 'JSON の構文エラーがあります。括弧・カンマ・引用符を確認してください。'
        return $result
    }

    $ver = Get-JsonValue $json 'schemaVersion'
    if ($null -ne $ver -and ($ver -isnot [long] -and $ver -isnot [int])) {
        $result.Error = 'schemaVersion は数値で指定してください。'
        return $result
    }
    if ($null -ne $ver -and $ver -gt $script:SchemaVersion) {
        $result.Error = ('schemaVersion {0} には対応していません（対応: {1}）。' -f $ver, $script:SchemaVersion)
        return $result
    }

    $entries = Get-JsonValue $json 'entries'
    if ($null -eq $entries) { $entries = @() }
    if ($entries -isnot [array]) { $entries = @($entries) }

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $problems = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        if ($e -isnot [System.Management.Automation.PSCustomObject]) {
            $problems.Add(('entries[{0}]: オブジェクトではありません。' -f $i)); continue
        }
        $orig = Get-JsonValue $e 'original'
        if ($orig -isnot [string] -or [string]::IsNullOrWhiteSpace($orig)) {
            $problems.Add(('entries[{0}]: original が空か、文字列ではありません。' -f $i)); continue
        }
        if ($orig.Contains([char]10) -or $orig.Contains([char]13)) {
            $problems.Add(('entries[{0}]: original に改行は使えません。' -f $i)); continue
        }
        $cat = Get-JsonValue $e 'category'
        if ($null -eq $cat) { $cat = 'CUSTOM' }
        if ($cat -isnot [string] -or $script:Categories -notcontains $cat.Trim()) {
            $problems.Add(('entries[{0}]: category は {1} のいずれかにしてください。' -f $i, ($script:Categories -join ' / '))); continue
        }
        $en = Get-JsonValue $e 'enabled'
        if ($null -eq $en) { $en = $true }
        if ($en -isnot [bool]) {
            $problems.Add(('entries[{0}]: enabled は true / false で指定してください。' -f $i)); continue
        }
        if (-not $seen.Add($orig)) {
            $result.Warnings.Add(('entries[{0}]: 同じ original が重複しているため無視しました。' -f $i))
            continue
        }
        $result.Entries.Add((New-TextMaskEntry -Original $orig -Category $cat -Enabled $en))
    }
    if ($problems.Count -gt 0) {
        $shown = @($problems | Select-Object -First 5)
        $more = if ($problems.Count -gt 5) { "`n（ほか {0} 件）" -f ($problems.Count - 5) } else { '' }
        $result.Error = ($shown -join "`n") + $more
        $result.Entries.Clear()
    }
    return $result
}

function Export-TextMaskProfile {
    <# .SYNOPSIS 辞書ファイルを保存する（UTF-8・BOM なし・原子的に置き換え）。 #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][AllowEmptyCollection()][object[]]$Entries
    )
    $path = Get-TextMaskProfilePath -DataDirectory $DataDirectory -Name $Name
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($e in @($Entries)) {
        if ($null -eq $e) { continue }
        $list.Add([ordered]@{
                original = [string]$e.Original
                category = [string]$e.Category
                enabled  = [bool]$e.Enabled
            })
    }
    $doc = [ordered]@{
        schemaVersion = $script:SchemaVersion
        profile       = $Name
        entries       = $list.ToArray()
    }
    $json = ConvertTo-Json -InputObject $doc -Depth 5
    Write-TextFileAtomic -Path $path -Content ($json + "`n")
    return $path
}

function Get-DefaultTextMaskSettings {
    [ordered]@{
        lastProfile    = 'default'
        detectPatterns = $true
        attachPrompt   = $false
        windowWidth    = 1000
        windowHeight   = 720
        lastCategory   = 'PERSON'
        lastPersistent = $false
    }
}

function Import-TextMaskSettings {
    <# .SYNOPSIS settings.json を読む。壊れていたら既定値を返す。 #>
    param([Parameter(Mandatory)][string]$DataDirectory)
    $s = Get-DefaultTextMaskSettings
    $path = Join-Path $DataDirectory 'settings.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $json = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            foreach ($k in @($s.Keys)) {
                $v = Get-JsonValue $json $k
                if ($null -eq $v) { continue }
                $def = $s[$k]
                if ($def -is [bool] -and $v -is [bool]) { $s[$k] = $v }
                elseif ($def -is [int] -and ($v -is [int] -or $v -is [long])) { $s[$k] = [int]$v }
                elseif ($def -is [string] -and $v -is [string]) { $s[$k] = $v }
            }
        }
        catch { }
    }
    if (-not (Test-TextMaskProfileName $s.lastProfile)) { $s.lastProfile = 'default' }
    if ($script:Categories -cnotcontains $s.lastCategory) { $s.lastCategory = 'PERSON' }
    return [pscustomobject]$s
}

function Export-TextMaskSettings {
    <# .SYNOPSIS settings.json を保存する。 #>
    param([Parameter(Mandatory)][string]$DataDirectory, [Parameter(Mandatory)]$Settings)
    $o = [ordered]@{}
    foreach ($k in (Get-DefaultTextMaskSettings).Keys) {
        $o[$k] = $Settings.$k
    }
    $json = ConvertTo-Json -InputObject $o -Depth 3
    Write-TextFileAtomic -Path (Join-Path $DataDirectory 'settings.json') -Content ($json + "`n")
}

Export-ModuleMember -Function @(
    'Test-TextMaskProfileName'
    'Get-TextMaskProfilePath'
    'Get-TextMaskProfileList'
    'New-TextMaskEntry'
    'Import-TextMaskProfile'
    'Export-TextMaskProfile'
    'Import-TextMaskSettings'
    'Export-TextMaskSettings'
)
