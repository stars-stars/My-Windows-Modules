#Requires -Version 7.0
<#
.SYNOPSIS
    TextMask の単体テスト（外部モジュール不要の簡易ランナー）。

.DESCRIPTION
    置換エンジン・辞書ファイルの読み書きを検証します。テストデータはすべて架空のものです。
    辞書ファイルは一時ディレクトリに書き、終了時に削除します。

    -Gui を付けると、GUI モジュールのフォームを「表示せずに」組み立て、
    内部の変換処理を呼び出すスモークテストも行います（ウィンドウやダイアログは出ません）。

.EXAMPLE
    pwsh -NoProfile -File .\powershell\TextMask\tests\Test-TextMask.ps1 -Gui
#>
[CmdletBinding()]
param([switch]$Gui)

$ErrorActionPreference = 'Stop'
$moduleDir = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleDir 'MaskEngine.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $moduleDir 'Dictionary.psm1') -Force -DisableNameChecking

$script:passed = 0
$script:failed = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:passed++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    }
    catch {
        $script:failed++
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host ("         {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host ("         {0}" -f ($_.InvocationInfo.PositionMessage -split "`n")[0]) -ForegroundColor DarkGray
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ($Expected -is [string] -or $Actual -is [string]) {
        if ([string]$Expected -cne [string]$Actual) {
            throw ("期待値 <{0}> / 実際 <{1}> {2}" -f $Expected, $Actual, $Because)
        }
    }
    elseif ($Expected -ne $Actual) {
        throw ("期待値 <{0}> / 実際 <{1}> {2}" -f $Expected, $Actual, $Because)
    }
}

function Assert-True {
    param($Condition, [string]$Because = '')
    if (-not $Condition) { throw ("条件が成り立ちません: {0}" -f $Because) }
}

function Get-WarningText($Result) { (@($Result.Warnings) | ForEach-Object Message) -join "`n" }

function E([string]$Original, [string]$Category = 'CUSTOM', [bool]$Enabled = $true) {
    [pscustomobject]@{ Original = $Original; Category = $Category; Enabled = $Enabled }
}

$dict = @(
    E '株式会社サンプル' 'COMPANY'
    E '田中' 'PERSON'
    E '新宿支店' 'PLACE'
)

Write-Host ''
Write-Host 'MaskEngine' -ForegroundColor Cyan

Test-Case '会社名・人名の基本置換（設計書の変換例）' {
    $s = New-MaskSession
    $r = Invoke-TextMask -Text '株式会社サンプルの田中様へ、新宿支店の件について確認をお願いします。' -Entries $dict -Session $s
    Assert-Equal '[[COMPANY_01]]の[[PERSON_01]]様へ、[[PLACE_01]]の件について確認をお願いします。' $r.Text
    Assert-Equal 3 $r.Count
    Assert-True (-not $r.HasError)
    Assert-Equal 0 @($r.Warnings).Count (Get-WarningText $r)
}

Test-Case '同一文字列の複数出現は同じ識別子・件数が正しい' {
    $s = New-MaskSession
    $r = Invoke-TextMask -Text '田中さんと田中部長、田中' -Entries $dict -Session $s
    Assert-Equal '[[PERSON_01]]さんと[[PERSON_01]]部長、[[PERSON_01]]' $r.Text
    Assert-Equal 3 $r.Count
    Assert-Equal 1 @($r.Used).Count
    Assert-Equal 3 $r.Used[0].Count
}

Test-Case '別の名称には別の識別子' {
    $s = New-MaskSession
    $r = Invoke-TextMask -Text '田中と佐藤と鈴木' -Entries @((E '田中' 'PERSON'), (E '佐藤' 'PERSON'), (E '鈴木' 'PERSON')) -Session $s
    Assert-Equal '[[PERSON_01]]と[[PERSON_02]]と[[PERSON_03]]' $r.Text
}

Test-Case '長短が重なる辞書項目は長い方が優先（登録順に依存しない）' {
    foreach ($entries in @(
            @((E 'サンプル' 'COMPANY'), (E '株式会社サンプル' 'COMPANY')),
            @((E '株式会社サンプル' 'COMPANY'), (E 'サンプル' 'COMPANY')))) {
        $s = New-MaskSession
        $r = Invoke-TextMask -Text '株式会社サンプルとサンプル' -Entries $entries -Session $s
        Assert-Equal '[[COMPANY_01]]と[[COMPANY_02]]' $r.Text
        Assert-Equal '株式会社サンプル' $s.Mappings['[[COMPANY_01]]'].Original
    }
}

Test-Case '部分的に重なる項目は左にある方が優先' {
    $s = New-MaskSession
    $r = Invoke-TextMask -Text 'ABCD' -Entries @((E 'BCD'), (E 'AB')) -Session $s
    Assert-Equal '[[CUSTOM_01]]CD' $r.Text
    Assert-Equal 'AB' $s.Mappings['[[CUSTOM_01]]'].Original
}

Test-Case '連鎖置換が起きない（置換後の文字列が他の項目に一致しても再置換しない）' {
    $s = New-MaskSession
    $r = Invoke-TextMask -Text 'COMPANY と 01' -Entries @((E 'COMPANY'), (E '01')) -Session $s
    Assert-Equal '[[CUSTOM_01]] と [[CUSTOM_02]]' $r.Text
    $u = Invoke-TextUnmask -Text $r.Text -Session $s
    Assert-Equal 'COMPANY と 01' $u.Text
}

Test-Case '正規表現のメタ文字を含む原文字列はリテラル一致' {
    $s = New-MaskSession
    $r = Invoke-TextMask -Text 'A.B(株) と AxB(株) と (C++) と $1' -Entries @((E 'A.B(株)' 'COMPANY'), (E '(C++)' 'PRODUCT'), (E '$1')) -Session $s
    Assert-Equal '[[COMPANY_01]] と AxB(株) と [[PRODUCT_01]] と [[CUSTOM_01]]' $r.Text
}

Test-Case '大文字・小文字を区別し、違いは警告する' {
    $s = New-MaskSession
    $r = Invoke-TextMask -Text 'Sample Inc. と SAMPLE INC.' -Entries @((E 'Sample Inc.' 'COMPANY')) -Session $s
    Assert-Equal '[[COMPANY_01]] と SAMPLE INC.' $r.Text
    Assert-True ((Get-WarningText $r) -match '大文字・小文字') (Get-WarningText $r)
}

Test-Case '全角・半角の表記違いを警告する（置換はしない）' {
    $s = New-MaskSession
    $r = Invoke-TextMask -Text 'ＡＢＣ商事 と ABC商事' -Entries @((E 'ABC商事' 'COMPANY')) -Session $s
    Assert-Equal 'ＡＢＣ商事 と [[COMPANY_01]]' $r.Text
    Assert-True ((Get-WarningText $r) -match '全角・半角') (Get-WarningText $r)
}

Test-Case '原文に識別子と同じ形式の文字列がある → 置換せず、同じ番号を発行しない' {
    $s = New-MaskSession
    $r = Invoke-TextMask -Text '[[PERSON_01]] と 田中' -Entries $dict -Session $s
    Assert-Equal '[[PERSON_01]] と [[PERSON_02]]' $r.Text
    Assert-True ((Get-WarningText $r) -match '識別子と同じ形式') (Get-WarningText $r)
    $u = Invoke-TextUnmask -Text $r.Text -Session $s
    Assert-Equal '[[PERSON_01]] と 田中' $u.Text '原文由来の識別子を誤って復元しない'
    Assert-True ((Get-WarningText $u) -match '原文に元から含まれていた') (Get-WarningText $u)
}

Test-Case '辞書項目が識別子の内部に一致しても識別子を壊さない' {
    $s = New-MaskSession
    $r = Invoke-TextMask -Text '[[PERSON_07]] PERSON' -Entries @((E 'PERSON'), (E '07')) -Session $s
    Assert-Equal '[[PERSON_07]] [[CUSTOM_01]]' $r.Text
}

Test-Case '発行済みの識別子を含む文章の再マスキングはエラー' {
    $s = New-MaskSession
    $r1 = Invoke-TextMask -Text '田中' -Entries $dict -Session $s
    $r2 = Invoke-TextMask -Text $r1.Text -Entries $dict -Session $s
    Assert-True $r2.HasError
    Assert-Equal $null $r2.Text
    Assert-Equal 0 $r2.Errors[0].Index
    $r3 = Invoke-TextMask -Text '[[PERSON_1]]' -Entries $dict -Session $s
    Assert-True $r3.HasError '番号の桁が違っても同じ識別子とみなす'
}

Test-Case '変換 → 復元の往復で元の文章と一致（日本語・複数行・全角半角・空白を保持）' {
    $text = "株式会社サンプル　御中`r`n`r`n  田中様（ﾀﾅｶ）`tへ`n新宿支店の件、ＡＢＣ　123 です。`r`n末尾の空白  "
    $s = New-MaskSession
    $r = Invoke-TextMask -Text $text -Entries $dict -Session $s
    Assert-True ($r.Text.Contains("`r`n`r`n  [[PERSON_01]]様（ﾀﾅｶ）`tへ`n")) '対象外の文字と改行は変更しない'
    $u = Invoke-TextUnmask -Text $r.Text -Session $s
    Assert-Equal $text $u.Text
    Assert-Equal 0 @($u.Warnings).Count (Get-WarningText $u)
}

Test-Case 'AI が文章の順序を変えても識別子単位で復元できる' {
    $s = New-MaskSession
    $r = Invoke-TextMask -Text '株式会社サンプルの田中様へ' -Entries $dict -Session $s
    $u = Invoke-TextUnmask -Text '[[PERSON_01]]様（[[COMPANY_01]]）へ' -Session $s
    Assert-Equal '田中様（株式会社サンプル）へ' $u.Text
    Assert-Equal 2 $u.Count
}

Test-Case '設計書の添削例を復元できる' {
    $s = New-MaskSession
    [void](Invoke-TextMask -Text '株式会社サンプルの田中様へ、新宿支店の件について確認をお願いします。' -Entries $dict -Session $s)
    $u = Invoke-TextUnmask -Text '[[COMPANY_01]]の[[PERSON_01]]様へ、[[PLACE_01]]の件につきまして、ご確認をお願いいたします。' -Session $s
    Assert-Equal '株式会社サンプルの田中様へ、新宿支店の件につきまして、ご確認をお願いいたします。' $u.Text
    Assert-True (-not $s.HasUnrestored)
}

Test-Case '識別子の欠落・回数変化・未知・書式崩れを警告し、未知は復元しない' {
    $s = New-MaskSession
    [void](Invoke-TextMask -Text '株式会社サンプルの田中様、田中様、新宿支店' -Entries $dict -Session $s)
    $answer = "[[PERSON_01]]様`n[[PERSON_09]] と [[COMPANY_1]]`n［［PLACE_01］］ と [company_01] と PERSON_01 と [[ PLACE_01 ]]"
    $u = Invoke-TextUnmask -Text $answer -Session $s
    $w = Get-WarningText $u
    Assert-True ($w -match '\[\[PERSON_09\]\]') '未知の識別子'
    Assert-True ($w -match '\[\[COMPANY_1\]\].*\[\[COMPANY_01\]\]') '番号の書式違い'
    Assert-True ($w -match '\[\[COMPANY_01\]\] が回答から消えています') '消失'
    Assert-True ($w -match '\[\[PERSON_01\]\] の出現回数が変化') '回数変化'
    Assert-True ($w -match '［［PLACE_01］］') '全角括弧'
    Assert-True ($w -match '\[company_01\]') '小文字・単括弧'
    Assert-True ($w -match '「PERSON_01」') '括弧なし'
    Assert-True ($w -match '\[\[ PLACE_01 \]\]') '空白混入'
    Assert-True ($u.Text.StartsWith("田中様`n[[PERSON_09]] と [[COMPANY_1]]`n")) '未知の識別子はそのまま残す'
    Assert-True ($w -notmatch '田中|サンプル|新宿') '警告に原文字列を含めない'
    $broken = @($u.OutputSpans | Where-Object Kind -eq 'broken')
    Assert-Equal 4 $broken.Count
    foreach ($b in $broken) { Assert-True ($u.Text.Substring($b.Start, $b.Length) -match 'PLACE|company|PERSON') '出力側の位置' }
}

Test-Case 'マスキング後に辞書を編集・削除しても発行済みの対応表で復元できる' {
    $s = New-MaskSession
    $entries = [System.Collections.Generic.List[object]]::new()
    $entries.Add((E '田中' 'PERSON'))
    $r = Invoke-TextMask -Text '田中様' -Entries $entries -Session $s
    $entries[0].Original = '佐藤'
    $entries.Clear()
    $u = Invoke-TextUnmask -Text $r.Text -Session $s
    Assert-Equal '田中様' $u.Text
}

Test-Case '同じセッションでは別の文章でも同じ名称に同じ識別子' {
    $s = New-MaskSession
    $r1 = Invoke-TextMask -Text '田中' -Entries $dict -Session $s
    $r2 = Invoke-TextMask -Text '新宿支店の田中' -Entries $dict -Session $s
    Assert-Equal '[[PERSON_01]]' $r1.Text
    Assert-Equal '[[PLACE_01]]の[[PERSON_01]]' $r2.Text
}

Test-Case '空入力・辞書 0 件・無効な項目でもクラッシュしない' {
    $s = New-MaskSession
    $r = Invoke-TextMask -Text '' -Entries @() -Session $s
    Assert-Equal '' $r.Text
    $r = Invoke-TextMask -Text 'こんにちは' -Entries $null -Session $s
    Assert-Equal 'こんにちは' $r.Text
    Assert-True ((Get-WarningText $r) -match '辞書が 0 件') (Get-WarningText $r)
    $r = Invoke-TextMask -Text '田中 と 佐藤' -Entries @((E '  '), (E '田中' 'PERSON' $false), (E '佐藤' 'PERSON'), (E '佐藤' 'COMPANY'), @{ Original = 'と'; Category = 'nope' }) -Session $s
    Assert-Equal '田中 [[CUSTOM_01]] [[PERSON_01]]' $r.Text '無効化した項目は使わない・不明カテゴリは CUSTOM'
    Assert-True ((Get-WarningText $r) -match '空の辞書項目 1 件') (Get-WarningText $r)
    Assert-True ((Get-WarningText $r) -match '重複') (Get-WarningText $r)
    $u = Invoke-TextUnmask -Text '' -Session (New-MaskSession)
    Assert-Equal '' $u.Text
}

Test-Case 'メールアドレス・電話番号を検出し、値ごとに別の識別子を割り当てる' {
    $s = New-MaskSession
    $text = 'taro@example.com と hanako.s+tag@mail.example.co.jp、03-1234-5678 / 090-1234-5678 / +81-3-1234-5678、日付 2026-11-18、taro@example.com'
    $r = Invoke-TextMask -Text $text -Entries @() -Session $s -DetectEmail -DetectPhone
    Assert-Equal '[[EMAIL_01]] と [[EMAIL_02]]、[[PHONE_01]] / [[PHONE_02]] / [[PHONE_03]]、日付 2026-11-18、[[EMAIL_01]]' $r.Text
    Assert-Equal 'email' $s.Mappings['[[EMAIL_02]]'].Source
    $u = Invoke-TextUnmask -Text $r.Text -Session $s
    Assert-Equal $text $u.Text
}

Test-Case '自動検出の取り消し（除外）と辞書優先' {
    $s = New-MaskSession
    [void]$s.ExcludedValues.Add('03-1234-5678')
    $r = Invoke-TextMask -Text '03-1234-5678、info@example.com' -Entries @((E 'info@example.com' 'COMPANY')) -Session $s -DetectEmail -DetectPhone
    Assert-Equal '03-1234-5678、[[COMPANY_01]]' $r.Text
}

Test-Case 'ハイライト用の位置情報が正しい' {
    $s = New-MaskSession
    $text = 'ああ田中いい新宿支店'
    $r = Invoke-TextMask -Text $text -Entries $dict -Session $s
    foreach ($sp in $r.InputSpans) { Assert-Equal $s.Mappings[$sp.Id].Original $text.Substring($sp.Start, $sp.Length) }
    foreach ($sp in $r.OutputSpans) { Assert-Equal $sp.Id $r.Text.Substring($sp.Start, $sp.Length) }
    $u = Invoke-TextUnmask -Text $r.Text -Session $s
    foreach ($sp in $u.OutputSpans) { Assert-Equal $s.Mappings[$sp.Id].Original $u.Text.Substring($sp.Start, $sp.Length) }
}

Test-Case '識別子の番号は 100 以上にも対応' {
    $s = New-MaskSession
    $entries = 1..105 | ForEach-Object { E ('名前{0:D3}' -f $_) 'PERSON' }
    $text = ($entries | ForEach-Object Original) -join ' '
    $r = Invoke-TextMask -Text $text -Entries $entries -Session $s
    Assert-True ($r.Text.EndsWith('[[PERSON_105]]'))
    Assert-Equal $text (Invoke-TextUnmask -Text $r.Text -Session $s).Text
}

Test-Case 'セッションのリセットで対応表が解放される' {
    $s = New-MaskSession
    $r = Invoke-TextMask -Text '田中' -Entries $dict -Session $s
    Assert-True $s.HasUnrestored
    Reset-MaskSession -Session $s
    Assert-Equal 0 $s.Mappings.Count
    Assert-Equal 0 $s.OriginalToId.Count
    Assert-True (-not $s.HasUnrestored)
    $u = Invoke-TextUnmask -Text $r.Text -Session $s
    Assert-Equal '[[PERSON_01]]' $u.Text 'リセット後は復元しない'
}

Test-Case '添削指示の付加' {
    $p = Get-CorrectionPrompt -MaskedText '[[COMPANY_01]]です。'
    Assert-True ($p.StartsWith('以下の文章を添削してください。'))
    Assert-True ($p.EndsWith("【添削対象】`n[[COMPANY_01]]です。"))
}

Test-Case 'カテゴリ推定用のパターン判定' {
    Assert-Equal 'EMAIL' (Find-MaskPattern 'a.b@example.com')
    Assert-Equal 'PHONE' (Find-MaskPattern '090-1234-5678')
    Assert-Equal $null (Find-MaskPattern '田中')
}

Write-Host ''
Write-Host 'Dictionary' -ForegroundColor Cyan

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('TextMaskTest-' + [guid]::NewGuid().ToString('N'))
try {
    Test-Case '存在しないプロファイルは空で読み込める' {
        $p = Import-TextMaskProfile -DataDirectory $tmp -Name 'default'
        Assert-True (-not $p.Exists)
        Assert-Equal 0 $p.Entries.Count
        Assert-Equal $null $p.Error
    }

    Test-Case '保存 → 再読み込みで内容が一致（UTF-8・BOM なし）' {
        $entries = @(
            (New-TextMaskEntry -Original '株式会社サンプル' -Category 'COMPANY'),
            (New-TextMaskEntry -Original 'A.B "quoted" \ 円' -Category 'product' -Enabled $false)
        )
        $path = Export-TextMaskProfile -DataDirectory $tmp -Name 'default' -Entries $entries
        $bytes = [System.IO.File]::ReadAllBytes($path)
        Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'BOM なし'
        $raw = [System.IO.File]::ReadAllText($path)
        Assert-True ($raw.Contains('株式会社サンプル')) '日本語をエスケープせず保存'
        $p = Import-TextMaskProfile -DataDirectory $tmp -Name 'default'
        Assert-Equal $null $p.Error
        Assert-Equal 2 $p.Entries.Count
        Assert-Equal 'A.B "quoted" \ 円' $p.Entries[1].Original
        Assert-Equal 'PRODUCT' $p.Entries[1].Category
        Assert-Equal $false $p.Entries[1].Enabled
        Assert-Equal 0 @(Get-ChildItem -LiteralPath (Split-Path $path) -Filter '*.tmp').Count '一時ファイルが残らない'
    }

    Test-Case '既存の辞書ファイルを上書き保存できる' {
        [void](Export-TextMaskProfile -DataDirectory $tmp -Name 'overwrite' -Entries @((New-TextMaskEntry -Original 'A')))
        [void](Export-TextMaskProfile -DataDirectory $tmp -Name 'overwrite' -Entries @((New-TextMaskEntry -Original 'A'), (New-TextMaskEntry -Original 'B')))
        $p = Import-TextMaskProfile -DataDirectory $tmp -Name 'overwrite'
        Assert-Equal 2 $p.Entries.Count
        $s = Import-TextMaskSettings -DataDirectory $tmp
        Export-TextMaskSettings -DataDirectory $tmp -Settings $s
        Export-TextMaskSettings -DataDirectory $tmp -Settings $s
    }

    Test-Case '辞書 0 件・1 件でも配列として保存される' {
        [void](Export-TextMaskProfile -DataDirectory $tmp -Name 'one' -Entries @((New-TextMaskEntry -Original 'X')))
        $j = Get-Content -Raw (Get-TextMaskProfilePath -DataDirectory $tmp -Name 'one') | ConvertFrom-Json
        Assert-True ($j.entries -is [array])
        [void](Export-TextMaskProfile -DataDirectory $tmp -Name 'zero' -Entries @())
        $p = Import-TextMaskProfile -DataDirectory $tmp -Name 'zero'
        Assert-Equal $null $p.Error
        Assert-Equal 0 $p.Entries.Count
    }

    Test-Case '手書きの JSON（省略可能な項目なし）を読める' {
        $path = Get-TextMaskProfilePath -DataDirectory $tmp -Name 'hand'
        Set-Content -LiteralPath $path -Encoding utf8 -Value '{ "entries": [ { "original": "田中" }, { "original": "鈴木", "category": "PERSON" }, { "original": "鈴木" } ] }'
        $p = Import-TextMaskProfile -DataDirectory $tmp -Name 'hand'
        Assert-Equal $null $p.Error
        Assert-Equal 2 $p.Entries.Count
        Assert-Equal 'CUSTOM' $p.Entries[0].Category
        Assert-Equal $true $p.Entries[0].Enabled
        Assert-Equal 1 $p.Warnings.Count
    }

    Test-Case '壊れた JSON はエラーになり、エラーに中身を含めない' {
        $path = Get-TextMaskProfilePath -DataDirectory $tmp -Name 'broken'
        Set-Content -LiteralPath $path -Encoding utf8 -Value '{ "entries": [ { "original": "秘密の会社", } '
        $p = Import-TextMaskProfile -DataDirectory $tmp -Name 'broken'
        Assert-True ($null -ne $p.Error)
        Assert-True ($p.Error -notmatch '秘密') $p.Error
        Assert-Equal 0 $p.Entries.Count
        Set-Content -LiteralPath $path -Encoding utf8 -Value '{ "entries": [ { "original": "x", "category": "BAD" }, { "original": "" } ] }'
        $p = Import-TextMaskProfile -DataDirectory $tmp -Name 'broken'
        Assert-True ($p.Error -match 'entries\[0\].*category') $p.Error
        Assert-True ($p.Error -match 'entries\[1\].*original') $p.Error
        Assert-Equal 0 $p.Entries.Count
    }

    Test-Case 'プロファイル名の検証と一覧' {
        Assert-True (Test-TextMaskProfileName 'work-2')
        Assert-True (-not (Test-TextMaskProfileName '..\evil'))
        Assert-True (-not (Test-TextMaskProfileName ''))
        $threw = $false
        try { [void](Get-TextMaskProfilePath -DataDirectory $tmp -Name '../x') } catch { $threw = $true }
        Assert-True $threw
        $list = Get-TextMaskProfileList -DataDirectory $tmp
        Assert-Equal 'default' $list[0]
        Assert-True ($list -contains 'hand')
    }

    Test-Case '設定ファイルの保存・読み込み（壊れていれば既定値）' {
        $s = Import-TextMaskSettings -DataDirectory $tmp
        Assert-Equal 'default' $s.lastProfile
        $s.lastProfile = 'hand'; $s.windowWidth = 999; $s.attachPrompt = $true
        Export-TextMaskSettings -DataDirectory $tmp -Settings $s
        $s2 = Import-TextMaskSettings -DataDirectory $tmp
        Assert-Equal 'hand' $s2.lastProfile
        Assert-Equal 999 $s2.windowWidth
        Assert-Equal $true $s2.attachPrompt
        Set-Content -LiteralPath (Join-Path $tmp 'settings.json') -Value '{ broken'
        Assert-Equal 'default' (Import-TextMaskSettings -DataDirectory $tmp).lastProfile
    }

    if ($Gui) {
        Write-Host ''
        Write-Host 'GUI（表示しないスモークテスト）' -ForegroundColor Cyan
        Import-Module (Join-Path $moduleDir 'Clipboard.psm1') -Force -DisableNameChecking
        $guiModule = Import-Module (Join-Path $moduleDir 'GUI.psm1') -Force -DisableNameChecking -PassThru
        # エラーダイアログを出さず、例外としてテストに返す
        & $guiModule { $script:ThrowUiErrors = $true }

        Test-Case 'フォームを組み立て、変換・復元・登録・モード切替を内部から実行できる' {
            $guiDir = Join-Path $tmp 'gui'
            [void](Export-TextMaskProfile -DataDirectory $guiDir -Name 'default' -Entries @((New-TextMaskEntry -Original '株式会社サンプル' -Category 'COMPANY')))
            $form = New-TextMaskForm -DataDirectory $guiDir -InitialText "株式会社サンプルの田中様`r`nmail: taro@example.com"
            try {
                Assert-True (-not $form.Visible) 'ウィンドウは表示しない'
                $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
                Assert-True ($form.Width -le $wa.Width -and $form.Height -le $wa.Height) ('初期サイズが作業領域に収まる: {0}x{1} / {2}x{3}' -f $form.Width, $form.Height, $wa.Width, $wa.Height)
                & $guiModule {
                    $C = $script:C
                    $upper = $C.MessagesGroup.Parent
                    if ($upper.GetRow($C.ConvertCopy.Parent) -ge $upper.GetRow($C.MessagesGroup)) { throw 'ボタン行が警告・エラー欄より上にない' }
                }
                & $guiModule {
                    $C = $script:C; $S = $script:S
                    if (-not (Invoke-MaskConvert)) { throw 'マスキングに失敗' }
                    if ($C.Output.Text -cne "[[COMPANY_01]]の田中様`nmail: [[EMAIL_01]]") { throw ('出力が違う: ' + $C.Output.Text) }
                    Add-Entry ([pscustomobject]@{ Original = '田中'; Category = 'PERSON'; Persistent = $false })
                    Invoke-AutoReconvert
                    if ($C.Output.Text -cne "[[COMPANY_01]]の[[PERSON_01]]様`nmail: [[EMAIL_01]]") { throw ('再変換の出力が違う: ' + $C.Output.Text) }
                    if ($C.Grid.Rows.Count -ne 3) { throw ('辞書グリッドの行数: ' + $C.Grid.Rows.Count) }
                    $C.Prompt.Checked = $true
                    if (-not $C.Output.Text.StartsWith('以下の文章を添削')) { throw '添削指示が付加されない' }
                    $C.RestoreMode.Checked = $true
                    if ($S.Mode -ne 'Restore') { throw 'モードが切り替わらない' }
                    $C.Input.Text = '[[PERSON_01]]様（[[COMPANY_01]]）'
                    if (-not (Invoke-Convert)) { throw '復元に失敗' }
                    if ($C.Output.Text -cne '田中様（株式会社サンプル）') { throw ('復元結果が違う: ' + $C.Output.Text) }
                    $C.MaskMode.Checked = $true
                    if (-not $C.Input.Text.StartsWith('株式会社サンプル')) { throw 'モード切替で入力が失われた' }
                    $p = Import-TextMaskProfile -DataDirectory $S.DataDirectory -Name 'default'
                    if ($p.Entries.Count -ne 1) { throw '一時辞書が永続辞書に保存された' }
                    Add-Entry ([pscustomobject]@{ Original = '新宿支店'; Category = 'PLACE'; Persistent = $true })
                    $p = Import-TextMaskProfile -DataDirectory $S.DataDirectory -Name 'default'
                    if ($p.Entries.Count -ne 2) { throw '永続辞書に保存されない' }
                }
            }
            finally {
                $form.Dispose()
            }
        }
    }
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
$color = if ($script:failed -eq 0) { 'Green' } else { 'Red' }
Write-Host ("{0} passed, {1} failed" -f $script:passed, $script:failed) -ForegroundColor $color
exit ([int]($script:failed -gt 0))
