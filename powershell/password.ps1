# 現在接続しているWi-Fiインターフェースの情報を取得
$interfaces = netsh wlan show interfaces

# SSIDを抽出
$ssid = $null
foreach ($line in $interfaces) {
    # 行の先頭付近に "SSID" があり、その後の文字列を取得
    if ($line -match "^\s*SSID\s*:\s*(.+)$") {
        $ssid = $matches[1].Trim()
        break
    }
}

# Wi-Fiに接続していない場合の処理
if ([string]::IsNullOrEmpty($ssid)) {
    Write-Host "現在Wi-Fiに接続していないか、SSIDを取得できませんでした。" -ForegroundColor Red
    exit
}

# 取得したSSIDのプロファイル情報を、パスワード（キー）を平文で表示するオプションを付けて取得
$profile = netsh wlan show profile name="$ssid" key=clear

# パスワードを抽出
$password = $null
foreach ($line in $profile) {
    # 英語環境の"Key Content"、日本語環境の"主要なコンテンツ"の両方に対応
    if ($line -match "(Key Content|主要なコンテンツ)\s*:\s*(.+)$") {
        $password = $matches[2].Trim()
        break
    }
}

# 結果をターミナルに出力
Write-Host "==============================" -ForegroundColor Cyan
Write-Host " 現在接続中のWi-Fi情報" -ForegroundColor Cyan
Write-Host "==============================" -ForegroundColor Cyan

if (-not [string]::IsNullOrEmpty($password)) {
    Write-Host " SSID       : $ssid"
    Write-Host " パスワード : $password" -ForegroundColor Yellow
} else {
    Write-Host " SSID       : $ssid"
    Write-Host " パスワード : 取得できませんでした" -ForegroundColor Red
    Write-Host " (※管理者権限で実行する必要がある場合があります)" -ForegroundColor DarkGray
}
Write-Host "==============================" -ForegroundColor Cyan