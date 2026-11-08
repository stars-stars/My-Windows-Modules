# CLAUDE.md

Windows 向けの個人用スクリプト集（PowerShell + AutoHotkey v2）。
各スクリプトは単体で動くため、ビルドやテストのパイプラインはありません。

- `powershell/` … `.ps1`（ユーザー PATH に登録されているディレクトリ）
- `autohotkey/` … `.ahk`（スタートアップの `.lnk` はこのディレクトリのパスを指す）

ファイルを移動・リネームすると PATH やスタートアップのショートカットが切れるので注意する。

## 開発 / デバッグ時の必須ルール: GUI ポップアップを出さない

GUI ダイアログが出るとユーザーの操作待ちになり、セッションがブロックされます。
特に次のポップアップは**出してはいけません**。

```
validate
  ✕  Script file not found.
      C:/Program Files/Git/validate
```

### 原因

Bash ツール（Git Bash / MSYS2）は、引数の先頭の `/` を Windows パスに自動変換します
（path conversion）。そのため

```bash
# NG: Bash ツールから実行した場合
"/c/Program Files/AutoHotkey/v2/AutoHotkey64.exe" /validate autohotkey/StorageBar.ahk
```

の `/validate` が `C:/Program Files/Git/validate` に書き換えられ、
AutoHotkey はこれを「スクリプトファイルのパス」と解釈して
`Script file not found.` のダイアログを表示します。

### 対策

**.ahk の構文チェックは PowerShell ツールから `/ErrorStdOut /validate` で行う。**
`/ErrorStdOut` を付けるとエラーがダイアログではなく標準出力に出ます。

```powershell
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut /validate "C:\Users\human\programing\powershell\bin\autohotkey\StorageBar.ahk"
# 構文 OK  -> 出力なし / exit 0
# 構文エラー -> stdout にエラー行が出て exit 2（ポップアップは出ない）
```

どうしても Bash ツールを使う場合は、パス変換を無効にしてスクリプトは Windows 形式の絶対パスで渡します。

```bash
MSYS_NO_PATHCONV=1 "/c/Program Files/AutoHotkey/v2/AutoHotkey64.exe" \
  /ErrorStdOut /validate "C:\Users\human\programing\powershell\bin\autohotkey\StorageBar.ahk"
```

### その他のポップアップ対策

- `.ahk` を**実行しない**（`AutoHotkey64.exe script.ahk`）。常駐 GUI・ホットキーを奪うスクリプトなので、
  検証は上記の `/validate` のみに留め、実際の動作確認はユーザーに依頼する。
- `.ps1` の構文チェックは実行せずパーサーで行う。

  ```powershell
  $e = $null
  [System.Management.Automation.Language.Parser]::ParseFile("$PWD\powershell\Rename-ByRegex.ps1", [ref]$null, [ref]$e)
  $e
  ```

- 対話的スクリプト（`Rename-ByRegex.ps1`、`ssh-list.ps1`、`Connect-AndroidWirelessDebugging.ps1` など）や
  管理者権限が必要なスクリプト（`password.ps1`、`ToggleTouch.ps1`）は、
  プロンプト待ち・UAC ダイアログ・Windows Forms ウィンドウが出るため自動実行しない。
- `MsgBox` / `[System.Windows.Forms.MessageBox]` / `Read-Host` を検証目的で追加しない。
  デバッグ出力は `OutputDebug`（AHK）や `Write-Host`（PowerShell）を使う。

## 変更時のメモ

- 機能を追加・変更したら `README.md` の該当セクションも更新する（ファイル一覧の表と各ファイルの説明）。
- コミットメッセージは英語の命令形 1 行（既存の履歴に合わせる）。
