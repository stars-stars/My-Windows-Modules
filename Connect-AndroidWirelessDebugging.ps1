<#
.SYNOPSIS
    Android端末とワイヤレスデバッグで接続するためのスクリプトです。

.DESCRIPTION
    このスクリプトは、Android 11以降で利用可能なワイヤレスデバッグ機能を使用して、
    adbコマンドでデバイスをペアリングし、接続するための手順を対話的に実行します。

    あらかじめ、Android端末の開発者向けオプションから「ワイヤレスデバッグ」をオンにしてください。
#>

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Android ワイヤレスデバッグ 接続ツール" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# adbコマンドの存在確認
if (-not (Get-Command "adb" -ErrorAction SilentlyContinue)) {
    Write-Host "エラー: 'adb' コマンドが見つかりません。Android SDK Platform-Toolsがインストールされ、環境変数PATHに設定されていることを確認してください。" -ForegroundColor Red
    Exit
}

Write-Host "【手順1】端末側でワイヤレスデバッグを有効にし、「ペア設定コードでデバイスをペア設定」をタップしてください。"
Write-Host ""

# IPアドレスの入力
# デフォルト値は環境変数 ANDROID_DEBUG_IP から読み込む（未設定の場合は毎回入力）
$defaultIp = $env:ANDROID_DEBUG_IP
if ([string]::IsNullOrWhiteSpace($defaultIp)) {
    $ipAddress = Read-Host "IPアドレスを入力してください"
} else {
    $ipAddress = Read-Host "IPアドレスを入力してください (デフォルト: $defaultIp)"
}
if ([string]::IsNullOrWhiteSpace($ipAddress)) {
    if ([string]::IsNullOrWhiteSpace($defaultIp)) {
        Write-Host "IPアドレスが入力されていません。処理を中止します。" -ForegroundColor Yellow
        Write-Host "(環境変数 ANDROID_DEBUG_IP を設定すると、デフォルト値として使用されます)" -ForegroundColor DarkGray
        Exit
    }
    $ipAddress = $defaultIp
    Write-Host "デフォルトのIPアドレス $defaultIp を使用します。" -ForegroundColor Cyan
}

# ペアリングポートの入力
$pairingPort = Read-Host "ペア設定のポート番号を入力してください (IPアドレスに続く5桁などの数字)"
if ([string]::IsNullOrWhiteSpace($pairingPort)) {
    Write-Host "処理を中止します。" -ForegroundColor Yellow
    Exit
}

# ペア設定コードの入力
$pairingCode = Read-Host "6桁のWi-Fiペア設定コードを入力してください"
if ([string]::IsNullOrWhiteSpace($pairingCode)) {
    Write-Host "処理を中止します。" -ForegroundColor Yellow
    Exit
}

Write-Host "`nペアリングを実行しています (${ipAddress}:${pairingPort}) ..." -ForegroundColor Cyan
$pairOutput = adb pair "${ipAddress}:${pairingPort}" $pairingCode 2>&1
Write-Host $pairOutput

if ($pairOutput -match "Successfully paired to") {
    Write-Host "ペアリングに成功しました！" -ForegroundColor Green
} else {
    Write-Host "ペアリングに失敗した可能性があります。出力内容を確認してください。" -ForegroundColor Red
    $continue = Read-Host "続行しますか？ (y/n)"
    if ($continue -notmatch "^y$") { Exit }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "【手順2】端末側の「ワイヤレスデバッグ」画面に戻り、「IPアドレスとポート」の下に表示されている接続用ポートを確認してください。"
Write-Host "※ペア設定のポートとは異なるポート番号が割り当てられます。"
Write-Host ""

# 接続用ポートの入力
$connectPort = Read-Host "接続用のポート番号を入力してください"
if ([string]::IsNullOrWhiteSpace($connectPort)) {
    Write-Host "処理を中止します。" -ForegroundColor Yellow
    Exit
}

Write-Host "`n接続を実行しています (${ipAddress}:${connectPort}) ..." -ForegroundColor Cyan
$connectOutput = adb connect "${ipAddress}:${connectPort}" 2>&1
Write-Host $connectOutput

if ($connectOutput -match "connected to") {
    Write-Host "接続に成功しました！" -ForegroundColor Green
    Write-Host "`n現在接続されているデバイス:" -ForegroundColor Cyan
    adb devices
} else {
    Write-Host "接続に失敗しました。出力内容を確認してください。" -ForegroundColor Red
}

Write-Host "`n完了しました。" -ForegroundColor Cyan
