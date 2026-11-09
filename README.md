# powershell/bin

Windows 環境で日常的に使っている PowerShell / AutoHotkey スクリプト群です。
単体で動くものが中心なので、使いたいものだけ個別に実行できます。

## ディレクトリ構成

```
bin/
├── powershell/   PowerShell スクリプト（.ps1）
└── autohotkey/   AutoHotkey v2 スクリプト（.ahk）
```

`.ps1` をどこからでも名前で呼び出せるように、`powershell/` をユーザー PATH に追加しておくと便利です。

## 動作環境

- Windows 10 / 11
- PowerShell 7 以降を推奨（`Rename-ByRegex.ps1` と `Undo-RenameLog.ps1` は 5.1 でも動作、`send_ip_all.ps1` は `ForEach-Object -Parallel` を使うため 7 以降が必須）
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
| [`powershell/ssh-list.ps1`](#ssh-listps1) | SSH 接続先を GUI 一覧から選んで接続 | `ssh`, CSV |
| [`powershell/Connect-AndroidWirelessDebugging.ps1`](#connect-androidwirelessdebuggingps1) | Android ワイヤレスデバッグの対話的ペアリング・接続（LAN / Tailscale） | `adb`（Tailscale 利用時は `tailscale`） |
| [`powershell/send_ip_all.ps1`](#send_ip_allps1) | 同一サブネットを ping スキャンして稼働ホストを列挙 | PowerShell 7+ |
| [`powershell/password.ps1`](#passwordps1) | 接続中の Wi-Fi の SSID とパスワードを表示 | 管理者権限 |
| [`powershell/capacity.ps1`](#capacityps1) | ディレクトリ直下の各項目の容量を色分け表示 | — |
| [`powershell/ToggleTouch.ps1`](#toggletouchps1) | タッチスクリーンの有効 / 無効を切り替え | 管理者権限 |
| [`powershell/Show-ScriptList.ps1`](#show-scriptlistps1) | このディレクトリのスクリプト一覧を説明付きで表示（Ctrl+Shift+? に割り当て可） | — |
| [`autohotkey/StorageBar.ahk`](#storagebarahk) | タスクバー左端にドライブの使用量・空き容量を常時表示 | AutoHotkey v2 |
| [`autohotkey/IMEKeySwitch.ahk`](#imekeyswitchahk) | 変換 / 無変換キーを IME の ON / OFF 専用キーにする | AutoHotkey v2 |
| [`autohotkey/DisplayOff.ahk`](#displayoffahk) | Win + Backspace で画面を暗転する（ロックしない疑似消灯） | AutoHotkey v2 |
| [`powershell/PngToJpg.ps1`](#pngtojpgps1--pngtoepsps1) | カレントディレクトリの PNG を一括で JPG に変換 | ImageMagick |
| [`powershell/PngToEps.ps1`](#pngtojpgps1--pngtoepsps1) | カレントディレクトリの PNG を一括で EPS に変換 | ImageMagick |

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
（`data` は `ssh-list.ps1` の接続先リストと同じ、このリポジトリの 1 階層上のディレクトリ）、
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

### `ssh-list.ps1`

SSH 接続先を Windows フォームの一覧（Out-GridView 風）から選んで接続します。
`↑` `↓` で選択、Enter またはダブルクリックで接続、`q` でキャンセルです。

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

### `send_ip_all.ps1`

デフォルトルートから自分の IPv4 アドレスを自動検出し、同じ /24 サブネットの
`.1` から `.254` に並列で ping を打って応答のあったホストを列挙します。
LAN 上の機器の IP を探すときに使います。

```powershell
.\send_ip_all.ps1
# Detected local IP address: 192.168.0.5
# Scanning subnet: 192.168.0.1 to 192.168.0.254
# 192.168.0.1 is UP
```

### `password.ps1`

現在接続中の Wi-Fi の SSID とパスワードを `netsh` 経由で取得して表示します。
他の端末を同じ Wi-Fi に繋ぐときに使います。英語環境（`Key Content`）と
日本語環境（`主要なコンテンツ`）の両方に対応しています。

> パスワードの取得には管理者権限が必要な場合があります。

### `capacity.ps1`

指定ディレクトリ直下の各項目の容量を一覧表示し、最後に合計を出します。
ディレクトリはシアン、`.exe` は緑、その他は白で色分けされます。
シンボリックリンクは二重計上を避けるためスキップします。

```powershell
.\capacity.ps1              # カレントディレクトリ
.\capacity.ps1 -Dir C:\tmp  # 指定したディレクトリ
```

### `ToggleTouch.ps1`

`Intel(R) Precise Touch Device` の有効 / 無効を切り替えます。
2-in-1 PC でタッチパネルの誤反応を一時的に止めたいときに使います。

> **管理者権限が必須** です。デバイス名が決め打ちなので、
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

### `PngToJpg.ps1` / `PngToEps.ps1`

カレントディレクトリにある `.png` をすべて JPG / EPS に変換します。
EPS 版は LaTeX に図を貼るとき用です。元の PNG は残ります。

> ImageMagick（`magick` コマンド）が PATH にある必要があります。

## 補足

このリポジトリに個人の接続先情報や認証情報は含めていません。
環境依存の値は `../data/`（Git 管理外）か環境変数に外出ししています。
