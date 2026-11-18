# Windows/bin

Windows 環境で日常的に使っている PowerShell / AutoHotkey スクリプト群です。
単体で動くものが中心なので、使いたいものだけ個別に実行できます。

## ディレクトリ構成

```
bin/
├── powershell/   PowerShell スクリプト（.ps1）
│   ├── TextMask/ Start-TextMask.ps1 が読み込むモジュールとテスト
│   └── InstallmentSimulator/ Start-InstallmentSimulator.ps1 が読み込むモジュールとテスト
└── autohotkey/   AutoHotkey v2 スクリプト（.ahk）
```

`.ps1` をどこからでも名前で呼び出せるように、`powershell/` をユーザー PATH に追加しておくと便利です。

## 動作環境

- Windows 10 / 11
- PowerShell 7 以降を推奨（`Rename-ByRegex.ps1` と `Undo-RenameLog.ps1` は 5.1 でも動作、`Find-LanHost.ps1` は `ForEach-Object -Parallel` を使うため 7 以降が必須）
- 一部スクリプトは外部ツールに依存します（下表の「依存」欄を参照）

スクリプトは署名していないため、実行ポリシーの変更が必要な場合があります。

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## ファイル一覧

| ファイル | 概要 | 依存 |
| --- | --- | --- |
| [`powershell/Rename-ByRegex.ps1`](#rename-byregexps1) | 正規表現によるファイル名の対話的一括リネーム | — |
| [`powershell/Undo-RenameLog.ps1`](#undo-renamelogps1) | `Rename-ByRegex.ps1` のリネームをログから巻き戻す | — |
| [`powershell/Connect-SshHost.ps1`](#connect-sshhostps1) | SSH 接続先を GUI 一覧から選んで接続 | `ssh`, CSV |
| [`powershell/Connect-AndroidWirelessDebugging.ps1`](#connect-androidwirelessdebuggingps1) | Android ワイヤレスデバッグの対話的ペアリング・接続（LAN / Tailscale） | `adb`（Tailscale 利用時は `tailscale`） |
| [`powershell/Find-LanHost.ps1`](#find-lanhostps1) | 同一サブネットを ping スキャンして稼働ホストを列挙 | PowerShell 7+ |
| [`powershell/Show-WifiPassword.ps1`](#show-wifipasswordps1) | 接続中の Wi-Fi の SSID とパスワードを表示 | 管理者権限 |
| [`powershell/Show-DirectorySize.ps1`](#show-directorysizeps1) | ディレクトリ直下の各項目の容量を色分け表示 | — |
| [`powershell/Switch-TouchScreen.ps1`](#switch-touchscreenps1) | タッチスクリーンの有効 / 無効を切り替え | 管理者権限 |
| [`powershell/Show-ScriptList.ps1`](#show-scriptlistps1) | このディレクトリのスクリプト一覧を説明付きで表示（Ctrl+Shift+? に割り当て可） | — |
| [`powershell/Copy-FileToClipboard.ps1`](#copy-filetoclipboardps1) | ファイルをエクスプローラーの Ctrl+C と同じ形でクリップボードにコピー | — |
| [`powershell/Start-TextMask.ps1`](#start-textmaskps1) | 会社名・人名を識別子に置き換えて外部 AI に渡し、回答を元に戻す GUI（TextMask） | PowerShell 7+, 辞書 JSON |
| [`powershell/Start-InstallmentSimulator.ps1`](#start-installmentsimulatorps1) | クレカ請求明細 CSV を読み、分割払いにしたときの毎月の請求額と手数料を試算する GUI | PowerShell 7+, 明細 CSV |
| [`autohotkey/StorageBar.ahk`](#storagebarahk) | タスクバー左端にドライブの使用量・空き容量を常時表示 | AutoHotkey v2 |
| [`autohotkey/IMEKeySwitch.ahk`](#imekeyswitchahk) | 変換 / 無変換キーを IME の ON / OFF 専用キーにする | AutoHotkey v2 |
| [`autohotkey/DisplayOff.ahk`](#displayoffahk) | Win + Backspace で画面を暗転する（ロックしない疑似消灯） | AutoHotkey v2 |
| [`autohotkey/PowerPointFastScroll.ahk`](#powerpointfastscrollahk) | PowerPoint の編集画面に高速スクロールとミドルボタンのオートスクロールを追加 | AutoHotkey v2 |
| [`powershell/Convert-PngToJpg.ps1`](#convert-pngtojpgps1--convert-pngtoepsps1) | カレントディレクトリの PNG を一括で JPG に変換 | ImageMagick |
| [`powershell/Convert-PngToEps.ps1`](#convert-pngtojpgps1--convert-pngtoepsps1) | カレントディレクトリの PNG を一括で EPS に変換 | ImageMagick |

---

## 各ファイルの説明

### `Rename-ByRegex.ps1`

正規表現でファイル名を一括リネームします。このリポジトリで最も作り込んであるスクリプトです。

処理は 3 ステップで進みます。

1. 正規表現を入力（決定時に構文チェック）
2. マッチしたファイルが一覧表示され、該当部分がハイライトされる
3. 置換文字列を入力（`$1` などのキャプチャ参照が使える）
   → 「変更前 → 変更後」のレビューが出て、Enter で実行

各ステップで `r` = 再入力 / `q` = 中止 が選べます。実行内容は
`data/rename-by-regex/logs` 配下に JSON ログとして保存され
（`data` は `Connect-SshHost.ps1` の接続先リストと同じ、このリポジトリの 1 階層上のディレクトリ）、
`Undo-RenameLog.ps1` で元に戻せます。

使い方と正規表現チートシートを並べたヘルプ画面を内蔵しています
（`-Help` で単独表示、正規表現の入力時は `?`、確認プロンプトでは `h`）。
ヘルプは `←` `→` でタブ切り替え、本文は less と同じキー操作で読めます。

```powershell
# 対話的に実行
.\Rename-ByRegex.ps1

# 非対話的にパターンを与える（一覧とレビューの確認は入る）
.\Rename-ByRegex.ps1 -Pattern '^document_(\w)$' -Replacement 'doc-$1' -Recurse

# 実行せず結果だけ確認
.\Rename-ByRegex.ps1 -WhatIf

# ヘルプ画面を開く
.\Rename-ByRegex.ps1 -Help
```

主なパラメータ: `-Path` `-Filter` `-Recurse` `-IncludeDirectory`
`-CaseSensitive` `-Pattern` `-Replacement` `-NoLog` `-LogDirectory` `-Help`
（`-WhatIf` / `-Confirm` に対応）

### `Undo-RenameLog.ps1`

`Rename-ByRegex.ps1` が書き出した JSON ログを読み、リネームを巻き戻します。
「現在の名前 → 戻した後の名前」のレビューを表示し、Enter で実行します。
ログを省略した場合は最新のものが使われます。

```powershell
# 最新のログを巻き戻す
.\Undo-RenameLog.ps1

# ログの一覧だけ表示
.\Undo-RenameLog.ps1 -List

# ログを指定
.\Undo-RenameLog.ps1 -LogPath ..\..\data\rename-by-regex\logs\rename-20261003-120000.json
```

主なパラメータ: `-LogPath` `-LogDirectory` `-List`（`-WhatIf` / `-Confirm` に対応）

### `Connect-SshHost.ps1`

SSH 接続先を Windows フォームの一覧（Out-GridView 風）から選んで接続します。
`↑` `↓` で選択、Enter またはダブルクリックで接続、`q` / `Esc` でキャンセルです。
`User` / `Port` が空欄の行は指定を省き、`ssh` の既定値（`~/.ssh/config` を含む）で接続します。

接続先は **リポジトリの外の `../data/machine_list.csv`**（スクリプトから見て `../../data/`）を読み込みます。
このリポジトリには含まれていないので、以下の形式で用意してください。

```csv
Name,Host,User,Port
MyServer,192.168.0.10,myuser,22
```

### `Connect-AndroidWirelessDebugging.ps1`

Android 11 以降のワイヤレスデバッグ機能を使って `adb` で端末にペアリング・接続します。
同一 LAN 経由と Tailscale 経由の両方に対応しています。
事前に端末側の開発者向けオプションで「ワイヤレスデバッグ」を有効にしてください。

- **LAN** … 「ワイヤレスデバッグ」画面に表示される IP を入力して接続します。
- **Tailscale** … `tailscale status` から Android 端末を一覧表示して番号で選びます（手入力も可）。
- `adb` は Android SDK の `platform-tools\adb.exe`（`ANDROID_HOME` / `ANDROID_SDK_ROOT` / `%LOCALAPPDATA%\Android\Sdk`）を優先し、なければ PATH 上のものを使います。
- 接続用ポート → ペアリング用ポート → ペアリングコードの順に入力します。ペアリング用ポートを空欄にするとペアリングを省略し、接続だけ行います（ペアリング済みの端末向け）。
- ペアリング・接続の前に TCP で到達性を確認し、届かない場合は確認ポイントを表示します。
- 同じ IP の古いポートでの接続は自動で切断し、`adb get-state` で `device` になったことを確認します。
- 接続に成功した IP は方式ごとに `%LOCALAPPDATA%\adb-pair\last-target.json` に保存され、次回の既定値になります。
- どの入力プロンプトでも `q` で中断できます。失敗時は終了コード 1 を返します。

```powershell
Connect-AndroidWirelessDebugging.ps1                              # 方式を対話で選択
Connect-AndroidWirelessDebugging.ps1 -Mode Tailscale              # Tailscale 経由
Connect-AndroidWirelessDebugging.ps1 -Mode Lan -Ip 192.168.1.23   # IP を指定
```

### `Find-LanHost.ps1`

デフォルトルート（複数ある場合はメトリック最小のもの）から自分の IPv4 アドレスを自動検出し、
同じ /24 サブネットの `.1` から `.254` に並列で ping（タイムアウト 1 秒）を打って、
応答のあったホストを IP 順に列挙します。LAN 上の機器の IP を探すときに使います。
サブネットが /24 でない場合は警告を出したうえで /24 の範囲だけを走査します。

```powershell
.\Find-LanHost.ps1
# Detected local IP address: 192.168.0.5/24
# Scanning subnet: 192.168.0.1 to 192.168.0.254
# 192.168.0.1 is UP
# 1 host(s) found.
```

### `Show-WifiPassword.ps1`

現在接続中の Wi-Fi の SSID とパスワードを `netsh` 経由で取得して表示します。
他の端末を同じ Wi-Fi に繋ぐときに使います。英語環境（`Key Content`）と
日本語環境（`主要なコンテンツ`）の両方に対応しています。

> パスワードの取得には管理者権限が必要な場合があります。

### `Show-DirectorySize.ps1`

指定ディレクトリ直下の各項目の容量を大きい順に一覧表示し、最後に合計を出します。
ディレクトリはシアン、`.exe` は緑、その他は白で色分けされます。
隠しファイルも集計に含めます。シンボリックリンクは二重計上を避けるためスキップし、
アクセスできないサブディレクトリはエラーを出さずに飛ばします。

```powershell
.\Show-DirectorySize.ps1              # カレントディレクトリ
.\Show-DirectorySize.ps1 -Dir C:\tmp  # 指定したディレクトリ
```

### `Switch-TouchScreen.ps1`

`Intel(R) Precise Touch Device` の有効 / 無効を切り替えます。
2-in-1 PC でタッチパネルの誤反応を一時的に止めたいときに使います。

> **管理者権限が必須** です。通常の PowerShell から実行すると UAC で管理者として起動し直し、
> 切り替え後の状態（ON / OFF）を元のコンソールに表示します。デバイス名が決め打ちなので、
> 別のタッチデバイスを使っている場合はスクリプト冒頭の `FriendlyName` を
> 書き換えてください（`Get-PnpDevice -Class HIDClass` で確認できます）。

### `Show-ScriptList.ps1`

`powershell/` にある `.ps1` の一覧を説明付きで表示します。ファイル名を忘れたとき用です。
説明はこの README のファイル一覧表の「概要」欄から取り、表にないスクリプトは `.SYNOPSIS` を使います。
新しいスクリプトを追加したら、表にも行を足しておくと説明が表示されます。

```powershell
Show-ScriptList.ps1
```

プロファイル（`$PROFILE`）に次を書いておくと、どのディレクトリにいても
`Ctrl+Shift+?` で一覧を表示できます。入力途中のコマンドは消えずに残ります。

```powershell
Set-PSReadLineKeyHandler -Chord 'Ctrl+?' -BriefDescription ShowScriptList `
    -Description 'bin\powershell のスクリプト一覧を表示' -ScriptBlock {
    $line = $null; $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($line.Length)
    Write-Host ''
    & 'Show-ScriptList.ps1'   # powershell\ は PATH に登録済みなので名前だけで呼べる
    [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt($null, $Host.UI.RawUI.CursorPosition.Y)
    [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor)
}
```

> キーを押しても反応しない場合は、`Alt+?` に続けて `Ctrl+Shift+?` を押すと、
> PSReadLine がそのキーをどう受け取っているかを確認できます。

### `Copy-FileToClipboard.ps1`

ファイル / フォルダを、エクスプローラーで `Ctrl+C` したのと同じ形（ファイルドロップリスト）で
クリップボードにコピーします。エクスプローラー、Slack、Teams、メールなどへ `Ctrl+V` で
ファイルとして貼り付け（添付）できます。テキストとして中身を貼り付けたい場合は
`Get-Content file | Set-Clipboard` を使ってください。

```powershell
# 1 ファイルをコピー
Copy-FileToClipboard.ps1 .\report.pdf

# ワイルドカード・複数指定（まとめて 1 回でコピー）
Copy-FileToClipboard.ps1 *.png, .\docs

# パイプラインから
Get-ChildItem -Filter *.log | Copy-FileToClipboard.ps1
```

クリップボードの操作には STA モードが必要です（通常の `pwsh` / `powershell` は STA で起動します）。

### `Start-TextMask.ps1`

ChatGPT や Claude などの外部 AI に文章の添削を頼む前に、会社名・人名・拠点名などを
`[[COMPANY_01]]` のような識別子にローカルで置き換え（マスキング）、AI の回答を元の名称に戻す（復元）GUI です。
ネットワーク通信は一切行いません。AI への送信はクリップボード経由で自分で行います。
設計は [`TextMask_specification.md`](TextMask_specification.md) を参照してください。

```text
原文      株式会社サンプルの田中様へ、新宿支店の件について確認をお願いします。
マスキング [[COMPANY_01]]の[[PERSON_01]]様へ、[[PLACE_01]]の件について確認をお願いします。
AI の回答 [[COMPANY_01]]の[[PERSON_01]]様へ、[[PLACE_01]]の件につきまして、ご確認をお願いいたします。
復元      株式会社サンプルの田中様へ、新宿支店の件につきまして、ご確認をお願いいたします。
```

```powershell
Start-TextMask.ps1                     # 起動（前回のプロファイル）
Start-TextMask.ps1 -Clipboard          # クリップボードの文章を読み込んで起動
Start-TextMask.ps1 -Profile work       # プロファイル（辞書）を指定
Start-TextMask.ps1 -Detach             # 別プロセスで開き、すぐプロンプトに戻る
```

`$PROFILE` に次を書いておくと `mask` で起動できます（専用の子プロセスで動くので、閉じると一時データがプロセスごと消えます）。

```powershell
function mask { pwsh -NoProfile -STA -File "$HOME\programing\Windows\bin\powershell\Start-TextMask.ps1" @args }
```

**使い方**

1. 「マスキング」モードで原文を貼り付ける（`貼り付け` ボタン / `Ctrl+V`。書式は捨ててプレーンテキストになる）
2. 置換したい語を選択して `Ctrl+D`（右クリックメニューや `選択範囲を登録` でも可）。カテゴリと
   **一時**（このセッションだけ・保存しない）/ **永続**（辞書ファイルに保存）を選ぶ
3. `Ctrl+Enter`（マスキングしてコピー）→ AI に貼り付けて添削を依頼
4. AI の回答をコピーし、「復元」モードに切り替えて貼り付け → `Ctrl+Enter`（復元してコピー）
5. 作業が終わったら `新しいセッション` か、ウィンドウを閉じる（`Esc`）

- 入力欄では置換箇所が黄、出力欄では識別子が緑でハイライトされます。復元時は未知の識別子が赤、書式の崩れた識別子が橙です。
- 警告・エラー欄の行をダブルクリックすると、入力欄の該当箇所が選択されます。
- `自動検出 ▼` のメニューで、辞書に登録しなくても置き換える種類を選べます（既定はすべて有効）。値ごとに別の識別子になり、誤検出は辞書の一覧でチェックを外すと除外できます。

  | 種類 | 識別子 | 検出するもの |
  | --- | --- | --- |
  | メールアドレス | `[[EMAIL_01]]` | `taro@example.com` |
  | 電話番号 | `[[PHONE_01]]` | `03-1234-5678`、`090 1234 5678`、`03(1234)5678`、`09012345678`、`+81-3-1234-5678`。全角数字・全角ハイフン（`０３－１２３４－５６７８`）も可 |
  | URL | `[[URL_01]]` | `https://` `http://` `ftp://` `www.` で始まるもの。末尾の句読点や対応しない閉じ括弧、直後の日本語は含めない |
  | 郵便番号 | `[[POSTAL_01]]` | `123-4567`、`〒1234567`（`〒` は残す）。`〒` がない場合はハイフン付きのみ |
  | IP アドレス | `[[IP_01]]` | IPv4（`192.168.0.1`、`10.0.0.0/8`）。範囲外の数値やバージョン番号風（`1.2.3.4.5`）は除く。IPv6 は対象外 |
- `添削指示を付加` を有効にすると、「識別子を変更・省略しないで」という指示文を付けた形でコピーします（出力欄に表示されているものがそのままコピーされます）。
- 辞書の一覧の「対応表のみ」は、辞書から削除したが、このセッションで識別子を発行済みの項目です（送信済みの文章を復元するために残ります）。

**置換の規則**

- 辞書は文字どおりに一致させます（大文字・小文字を区別、`.` や `(` などもそのまま）。大文字・小文字や全角・半角だけが違う表記が残っていると警告します。
- 重なる候補は「左にある方」→「長い方」→「辞書（自動検出より優先）」の順で採用します。`株式会社サンプル` と `サンプル` を両方登録すると前者が優先されます。
- 同じセッションでは、同じ語に必ず同じ識別子を割り当てます。辞書を後から編集・削除しても、発行済みの識別子は元の語に戻せます。
- 原文に `[[XXX_01]]` 形式の文字列が元からある場合は置換せず、同じ番号は発行しません。発行済みの識別子を含む文章（マスキング済みの文章など）をもう一度マスキングしようとするとエラーにします。
- 復元時、対応表にない識別子や書式の崩れた識別子（`［［COMPANY_01］］`、`[COMPANY_01]`、`COMPANY_01` など）は推測で戻さずにそのまま残して警告します。マスキング時にあった識別子が回答から消えた / 回数が変わった場合も警告します。

**データの置き場所**

永続辞書と設定は **リポジトリの外の `../data/textmask/`**（スクリプトから見て `../../data/textmask/`）に保存されます。

```
data/textmask/
├── settings.json          ウィンドウサイズ・チェック状態など（機密情報なし）
└── profiles/
    ├── default.json       永続辞書（平文 JSON）
    └── work.json
```

辞書はエディタで直接編集できます（`フォルダを開く` → 編集後に `再読込`）。

```json
{
  "schemaVersion": 1,
  "profile": "default",
  "entries": [
    { "original": "株式会社サンプル", "category": "COMPANY", "enabled": true },
    { "original": "新宿支店", "category": "PLACE", "enabled": true }
  ]
}
```

`category` は `COMPANY` `PERSON` `PLACE` `PRODUCT` `PROJECT` `EMAIL` `PHONE` `URL` `POSTAL` `IP` `CUSTOM` のいずれかです（省略時は `CUSTOM`、`enabled` の省略時は `true`）。
JSON が壊れている場合は読み込まずに警告し、修正されるまで上書き保存しません。

**セキュリティ上の注意**

- 永続辞書は**平文**で保存されます（設計書では DPAPI 暗号化を推奨していましたが、エディタで編集でき別 PC にも持ち出せるよう平文にしています）。`data/` を同期・共有する場合は中身に注意してください。
- 一時辞書と対応表はメモリ上にだけあり、ファイルには書きません。ウィンドウを閉じると失われ、**別のウィンドウ・プロセスからは復元できません**（未復元のまま閉じようとすると確認が出ます）。
- 入力文章・変換結果・履歴はファイルに保存しません。
- コピー時は Windows のクリップボード履歴（Win+V）・クラウド同期・監視ツールの対象外にするよう要求します（`CanIncludeInClipboardHistory` などの形式）。他のアプリで先にコピーした原文や、対応していないクリップボード管理ツールは制御できません。`クリップボード消去` で現在の内容は消せますが、履歴に残ったものは Win+V から削除してください。
- これは可逆的な仮名化の補助ツールで、完全な匿名化を保証するものではありません。名称を消しても文脈（事業内容・数値・役職など）から特定される可能性があります。組織の規程で外部 AI への入力が禁止されている情報は、マスキングしても送らないでください。

**テスト**（GUI を表示せずに実行されます。`-Gui` はフォームを非表示のまま組み立てて内部処理を確認します）

```powershell
pwsh -NoProfile -STA -File .\powershell\TextMask\tests\Test-TextMask.ps1 -Gui
```

モジュール構成: `TextMask/MaskEngine.psm1`（置換・復元・検証）、`Dictionary.psm1`（辞書 JSON・設定）、
`Clipboard.psm1`（クリップボード）、`GUI.psm1`（WinForms）。

### `Start-InstallmentSimulator.ps1`

クレジットカードの請求明細 CSV を読み込み、1 回払いの明細を分割払いに変えたら
今月・来月以降の請求額と手数料がどう変わるかを試算する GUI です。ネットワーク通信は行いません。

```powershell
Start-InstallmentSimulator.ps1                    # 前回の明細（なければ明細フォルダの最新の月）を開く
Start-InstallmentSimulator.ps1 -CsvPath .\x.csv   # 最初に開く明細を指定（明細フォルダの外でも可）
Start-InstallmentSimulator.ps1 -Detach            # 別プロセスで開き、すぐプロンプトに戻る
```

**使い方**

0. 毎月の明細 CSV を `data/installment-simulator/statements/` に `yyyyMM.csv` の名前で置き、上部の `明細` リストで試算する月を選ぶ
   - 月を切り替えても、それぞれの月で選んだ回数と選択中（✓）はウィンドウを閉じるまで覚えている（ファイルには保存しない）
   - `再読込` で明細フォルダを読み直す（CSV を追加・更新したとき）。`フォルダを開く` で明細フォルダをエクスプローラーで開く
   - 閉じるときに開いていた月を保存し、次回はその月から開く
1. 明細の「支払回数」を選ぶ（1・2・3・5・6・10・12・15・18・20・24 回）と、すぐに再計算される
2. 複数の明細をまとめて変えるときは、行を **選択中（✓）** にしてから `まとめて` の回数 → `選択中に適用`
   - 行をダブルクリックすると選択中（✓、青い行）になり、もう一度ダブルクリックで解除（支払回数の列はドロップダウン用なので除く）
   - ほかのセルをクリックしても、並べ替えても選択中は消えないので、離れた行を 1 行ずつ選べる
   - マウスでドラッグして範囲選択している途中（または Ctrl / Shift で選んだあと）に `Space` を押すと、その範囲の行をまとめて選択中にする
   - `選択を解除` で選択中をすべて外す。返品・既存の分割払いの行は選択中にできない
   - 選択中の行がないときは、いまハイライトしている行に適用する。`すべてに適用`（変更できる明細すべて）/ `リセット`（すべて 1 回）もある
3. 下段で変更前（明細どおり）と変更後を比べる
   - サマリー: 今月の請求額と差額、手数料の合計、支払総額、月の最大請求額、支払いが終わる月
   - 月別の請求額: 表（差額・うち手数料）とグラフ
4. `実質年率` を変えると再計算する（既定 15.00%。閉じるときに保存）
5. 明細は列見出しのクリック（もう一度クリックで昇順 / 降順を切り替え）か、上部の `並べ替え` リストで並べ替えられる
   - リスト: 明細の順（CSV のまま）・日付の新しい順 / 古い順・金額の大きい順 / 小さい順・手数料の大きい順・今月の請求分の大きい順・利用先の名前順・区分順・選択中（✓）の行が先
   - 数値・日付の列は最初のクリックで大きい順 / 新しい順。手数料など値のない行（変更できない明細）は常に末尾
   - 回数を変えても自動では並べ直しません（編集中の行が動かないように）。並べ替えは閉じるときに保存

- 返品（マイナス）と、すでに分割払いになっている明細は変更できません（灰色）。既存の分割払いは残りの回も今回と同じ額で計上します。
- 利用先にマウスを乗せると備考（外貨の金額・レートなど）が出ます。
- 明細の合計が CSV の合計行と一致しないときは、画面下に警告を出します。

**計算方法**（元利均等方式。三井住友カード系の「100 円あたりの分割払い手数料」表と同じ値になります）

- 月利 r = 年率 / 12、100 円あたり手数料 = (n·r / (1 − (1+r)^−n) − 1) × 100（小数第 2 位）。15% なら 3 回 2.51 円、6 回 4.42 円、12 回 8.31 円、24 回 16.37 円
- 手数料 = 利用金額 × 係数 / 100（円未満切り捨て）。各回 = (利用金額 + 手数料) / n の切り捨てで、端数は初回に加算
- 1・2 回払いは手数料なし。分割にした明細は今月の請求から 1 回目が始まる（あとから分割を想定）
- 概算です。実際の手数料・各回の金額はカード会社の確定額に従います。

**明細 CSV の形式**（Amazon Mastercard などの明細ダウンロード。Shift_JIS、数字は全角でも可）

```
氏名,カード番号（マスク済み）,カード名
利用日,利用先,利用金額,支払回数,今回回数,今回請求額,備考
…
,,,,,合計,
```

ファイル名の先頭 `yyyyMM` を請求月として使います（例: `202611.csv` → 2026 年 11 月請求）。1 行目の氏名は読み込みません。

**データの置き場所**

```
data/installment-simulator/
├── settings.json                 実質年率・支払回数の選択肢・ウィンドウサイズ（96 DPI 換算）・並べ替え・前回の明細
└── statements/                   明細 CSV（請求月ごとに 1 ファイル。リストには新しい月から並ぶ）
    ├── 202611.csv
    └── 202612.csv
```

ファイル名に `yyyyMM` がない CSV もリストに出ます（年月のあるものの後ろ。請求月は実行した日の月として扱います）。

`settings.json` の `counts` を編集すると支払回数の選択肢を変えられます（1 は常に含まれます）。

**テスト**（架空の明細を一時ディレクトリに書いて検証します。`-Gui` はフォームを表示せずに組み立てて再計算・グラフ描画を確認します）

```powershell
pwsh -NoProfile -STA -File .\powershell\InstallmentSimulator\tests\Test-InstallmentSimulator.ps1 -Gui
```

モジュール構成: `InstallmentSimulator/Statement.psm1`（CSV 読み込み）、`Calculator.psm1`（手数料・月別スケジュール）、
`GUI.psm1`（WinForms）。

### `StorageBar.ahk`

AutoHotkey v2 のスクリプトです。固定ドライブの容量をタスクバーの左端に
常時表示します。

1 ドライブにつき 1 ブロックで、上段に数値、下段に使用率バーが出ます。

```
C: 123 / 456 GB   空き 333 GB
████████████░░░░░░░░░░░░░░░░
```

- 上段左が「使用量 / 全容量」、右が残り容量（エクスプローラーと同じ 1024 進）
- 30 秒ごとに容量を再取得、1 秒ごとに位置合わせと最前面維持
- 空き率が 10% 未満でオレンジ、6.5% 未満で赤に変色（残り容量とバー）
- タスクバーの背景色を拾って馴染ませる
- トレイアイコンにカーソルを当てると全ドライブの内訳と空き率を表示
- ダブルクリックで「PC」を開く
- トレイメニューからスタートアップ登録（`StorageBar.lnk`）が可能

閾値や 1 ドライブ分の幅（`BLOCK_W`）はスクリプト冒頭の「設定」セクションで
変更できます。文字が切れる・余りすぎる場合はここを調整してください。

### `IMEKeySwitch.ahk`

AutoHotkey v2 のスクリプトです。日本語キーボードの変換 / 無変換キーを、
IME のトグルではなく ON / OFF 専用キーとして割り当て直します。

- 変換キー → IME ON（ひらがな入力）
- 無変換キー → IME OFF（半角英数字）
- トレイメニューからスタートアップ登録（`IMEKeySwitch.lnk`）が可能

現在の IME 状態を気にせず押せるので、変換ミスを戻す操作が減ります。

### `DisplayOff.ahk`

AutoHotkey v2 のスクリプトです。`Win + Backspace` で画面を暗転します。

モダンスタンバイ機（Surface Laptop 3 など）では、本当にディスプレイを消すとスリープと同じ扱いになり、
サインイン設定が「毎回」だとロックされます。そこでこのスクリプトは本当には消灯せず、
全画面の黒いウィンドウを出して明るさを 0 にします（ロックはかかりません）。

- マウスかキーボードを操作すると、元の明るさとウィンドウに戻る
- 復帰のために押したキーは黒いウィンドウが受け取るので、裏のアプリには入力されない
- キーを離してから暗転するので、キーを離したときの入力ですぐには戻らない
- トレイアイコンは月マーク付きのモニター（`imageres.dll` の 97 番）
- トレイメニューからスタートアップ登録（`DisplayOff.lnk`）が可能

> 注意点
> - バックライトは完全には消えません（明るさ 0 で黒を表示しているだけ）。省電力の効果は本当の消灯より小さくなります。
> - 電源設定の「画面をオフにする」時間が来ると、Windows が本当に消灯してロックします。長く離れるときはこれで問題ありません。
> - 明るさを変えられるのは内蔵ディスプレイだけです。外部モニターは黒い画面になるだけです。

### `PowerPointFastScroll.ahk`

AutoHotkey v2 のスクリプトです。PowerPoint の編集画面（`PPTFrameClass`）でだけ、次の操作を追加します。

- `Shift + ホイール` → 1 刻みで `fastScrollAmount`（既定 8）刻み分スクロールする
- `ミドルボタン` → オートスクロール。原点から離した距離に応じて縦横に加速する
  - 短くクリック → 固定モード（もう一度ミドルボタン / 左右クリック / `Esc` / ホイールで解除）
  - 押したままドラッグ → 離した時点で停止
- 原点には半透明の丸いマーカーが出る（クリックやホイールは素通しする）
- `Ctrl + Alt + R` でスクリプトを再読み込み
- トレイアイコンはマウス（`main.cpl` の 1 番）
- 既定ではスタートアップに登録しない。必要ならトレイメニューから登録（`PowerPointFastScroll.lnk`）が可能
- トレイメニューから再読み込みもできる

スクロールはホイール入力を合成して送るので、ペインの構成やビューの種類に関係なく動きます（COM は使いません）。
カーソルが PowerPoint の外にある間はスクロールを送りません。スライドショー中は何もしません。

倍率・加速・デッドゾーン・固定モードの判定時間などはスクリプト冒頭の `cfg` で変更できます。
変更したら `Ctrl + Alt + R` で反映してください。

### `Convert-PngToJpg.ps1` / `Convert-PngToEps.ps1`

カレントディレクトリにある `.png` をすべて JPG / EPS に変換します。
EPS 版は LaTeX に図を貼るとき用です。元の PNG は残ります。
JPG 版は透過部分を白で塗りつぶします（そのままだと黒くなるため）。
変換に失敗したファイルは赤で表示し、1 件でも失敗すると終了コード 1 を返します。

> ImageMagick（`magick` コマンド）が PATH にある必要があります。

## 補足

このリポジトリに個人の接続先情報や認証情報は含めていません。
環境依存の値は `../data/`（Git 管理外）か環境変数に外出ししています。
