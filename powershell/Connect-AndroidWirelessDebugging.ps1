<#
.SYNOPSIS
    Android のワイヤレスデバッグに Windows からペアリング・接続する (LAN / Tailscale 両対応)

.DESCRIPTION
    pair-android.sh (Docker 内 Linux 用, socat トンネル経由) の Windows 版。
    Windows ホストから端末へ直接届くため、トンネルは使わず adb で直接ペアリング・接続する。

    接続方式:
      Lan       … 同一 LAN 上の端末の IP (Android の「ワイヤレスデバッグ」画面に表示されるもの) に接続
      Tailscale … tailscale status から Android 端末を一覧表示して選択 (手入力も可)

    入力プロンプトで q を入力すると中断する。
    ペアリング用ポートを空欄にするとペアリングを省略し、接続のみ行う (ペアリング済み端末向け)。

.EXAMPLE
    .\Connect-AndroidWirelessDebugging.ps1
.EXAMPLE
    .\Connect-AndroidWirelessDebugging.ps1 -Mode Tailscale
.EXAMPLE
    .\Connect-AndroidWirelessDebugging.ps1 -Mode Lan -Ip 192.168.1.23
#>
[CmdletBinding()]
param(
    [ValidateSet('Lan', 'Tailscale')]
    [string]$Mode,
    [string]$Ip
)

# 'Stop' だと Windows PowerShell 5.1 で adb の stderr 出力が例外扱いになるため Continue のまま扱う
$ErrorActionPreference = 'Continue'

# 前回の接続先 (方式ごとの IP) を記憶しておく場所
$StateDir  = Join-Path $env:LOCALAPPDATA 'adb-pair'
$StateFile = Join-Path $StateDir 'last-target.json'

# ---------------------------------------------------------------------------
# 共通関数
# ---------------------------------------------------------------------------

# SDK 版 adb を優先する (Android Studio が起動する adb サーバーとのバージョン不一致を避けるため)
function Find-Adb {
    $roots = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $p = Join-Path $root 'platform-tools\adb.exe'
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-Tailscale {
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $p = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path $p) { return $p }
    return $null
}

# 入力を読む。q で中断、空欄なら既定値を返す
function Read-Input([string]$Prompt, [string]$Default) {
    $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $v = "$(Read-Host $label)".Trim()
    if ($v -eq 'q') { Write-Host '中断しました。'; exit 0 }
    if (-not $v -and $Default) { return $Default }
    return $v
}

function Read-Port([string]$Prompt, [switch]$AllowEmpty) {
    while ($true) {
        $v = Read-Input $Prompt
        if (-not $v -and $AllowEmpty) { return $null }
        $n = 0
        if ([int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 65535) { return $n }
        Write-Host '[!] 1〜65535 の数値を入力してください。'
    }
}

# TCP で到達できるかを短いタイムアウトで確認する (Test-NetConnection は遅いので使わない)
function Test-TcpPort([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 3000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($TargetHost, $Port)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Test-Reachable([string]$TargetHost, [int]$Port, [string]$Label) {
    Write-Host "[+] ターゲットへの到達性を確認中 (${TargetHost}:${Port}, $Label)..."
    if (Test-TcpPort $TargetHost $Port) { return $true }

    Write-Host "[!] ${TargetHost}:${Port} に接続できません。以下を確認してください:"
    Write-Host '    - Android のワイヤレスデバッグが ON で、入力したポート番号が最新か'
    Write-Host '      (ワイヤレスデバッグの ON/OFF やペアリング画面の開き直しでポートは変わります)'
    if ($Mode -eq 'Lan') {
        Write-Host '    - PC と Android が同じ LAN (同じルーター配下) にいるか'
        Write-Host '    - ルーターの AP アイソレーション (プライバシーセパレーター) が無効か'
    } else {
        Write-Host '    - PC と Android の両方で Tailscale が接続中か'
        Write-Host '    - Tailscale の ACL でこの PC から端末への通信が許可されているか'
    }
    return $false
}

function Get-LastTargets {
    $h = @{}
    if (Test-Path $StateFile) {
        try {
            (Get-Content $StateFile -Raw | ConvertFrom-Json).psobject.Properties |
                ForEach-Object { $h[$_.Name] = $_.Value }
        } catch { }
    }
    return $h
}

function Save-LastTarget([string]$TargetMode, [string]$TargetIp) {
    try {
        $h = Get-LastTargets
        $h[$TargetMode] = $TargetIp
        $h['LastMode'] = $TargetMode
        New-Item -ItemType Directory -Force $StateDir | Out-Null
        $h | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
    } catch { }
}

function Select-LanIp([string]$Default) {
    Write-Host '※ Android の「設定 > 開発者向けオプション > ワイヤレスデバッグ」に表示される IP アドレスを入力してください。'
    while ($true) {
        $v = Read-Input 'Android の IP アドレス' $Default
        if ($v) { return $v }
        Write-Host '[!] IP アドレスが未入力です。'
    }
}

function Select-TailscaleIp([string]$Default) {
    $peers = @()
    $ts = Find-Tailscale
    if (-not $ts) {
        Write-Host '[!] tailscale.exe が見つかりません。Tailscale の IP (100.x.x.x) を手入力してください。'
    } else {
        $json = (& $ts status --json 2>$null) -join "`n"
        $status = $null
        if ($json) { try { $status = $json | ConvertFrom-Json } catch { } }
        if (-not $status) {
            Write-Host '[!] Tailscale の状態を取得できませんでした。'
        } elseif ($status.BackendState -ne 'Running') {
            Write-Host "[!] この PC の Tailscale が接続中ではありません (状態: $($status.BackendState))。"
        } elseif ($status.Peer) {
            $peers = @(
                $status.Peer.psobject.Properties.Value |
                    Where-Object { $_.OS -eq 'android' } |
                    ForEach-Object {
                        $ipv4 = $_.TailscaleIPs | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
                        if ($ipv4) {
                            [pscustomobject]@{ Name = $_.HostName; Ip = $ipv4; Online = [bool]$_.Online }
                        }
                    } |
                    Sort-Object @{ Expression = 'Online'; Descending = $true }, Name
            )
        }
    }

    if ($peers.Count -eq 0) {
        if ($ts) { Write-Host '[!] Tailscale 上に Android 端末が見つかりません。IP を手入力してください。' }
        while ($true) {
            $v = Read-Input 'Android の Tailscale IP' $Default
            if ($v) { return $v }
            Write-Host '[!] IP アドレスが未入力です。'
        }
    }

    Write-Host 'Tailscale 上の Android 端末:'
    $defNum = ''
    for ($i = 0; $i -lt $peers.Count; $i++) {
        $p = $peers[$i]
        $state = if ($p.Online) { 'online' } else { 'offline' }
        Write-Host ('  {0}) {1,-24} {2,-16} {3}' -f ($i + 1), $p.Name, $p.Ip, $state)
        if ($p.Ip -eq $Default) { $defNum = "$($i + 1)" }
    }
    Write-Host '  m) IP を手入力'
    if (-not $defNum) { $defNum = '1' }

    while ($true) {
        $v = Read-Input '番号' $defNum
        if ($v -eq 'm') {
            $manual = Read-Input 'Android の Tailscale IP'
            if ($manual) { return $manual }
            continue
        }
        $n = 0
        if ([int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le $peers.Count) {
            $sel = $peers[$n - 1]
            if (-not $sel.Online) { Write-Host "[!] $($sel.Name) は offline と表示されています。接続できない場合は端末側の Tailscale を確認してください。" }
            return $sel.Ip
        }
        Write-Host '[!] 一覧の番号か m を入力してください。'
    }
}

# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

Write-Host '=== ADB ワイヤレスデバッグ接続ツール (Windows / LAN・Tailscale) ==='

$adb = Find-Adb
if (-not $adb) {
    Write-Host '[!] adb.exe が見つかりません。Android SDK Platform-Tools をインストールするか、ANDROID_HOME を設定してください。'
    exit 1
}
Write-Host "[+] adb: $adb"
& $adb start-server | Out-Null

$last = Get-LastTargets

# 1. 接続方式と接続先の選択
if (-not $Mode) {
    $defNum = if ($last['LastMode'] -eq 'Tailscale') { '2' } else { '1' }
    Write-Host '接続方式を選択してください (q で中断):'
    Write-Host '  1) LAN (同一ネットワーク)'
    Write-Host '  2) Tailscale (VPN)'
    while (-not $Mode) {
        switch (Read-Input '番号' $defNum) {
            '1'     { $Mode = 'Lan' }
            '2'     { $Mode = 'Tailscale' }
            default { Write-Host '[!] 1 か 2 を入力してください。' }
        }
    }
}

$TargetIp = if ($Ip) { $Ip }
            elseif ($Mode -eq 'Lan') { Select-LanIp $last['Lan'] }
            else { Select-TailscaleIp $last['Tailscale'] }
Write-Host "[+] 接続先: $TargetIp ($Mode)"
Write-Host '------------------------------------------------'

# 2. ポート番号の入力 (Android 側 UI の表示順に合わせ、接続用→ペアリング用)
$ConnPort = Read-Port '接続用ポート番号を入力してください'
$PairPort = Read-Port 'ペアリング用ポート番号を入力してください (ペアリング済みなら空欄)' -AllowEmpty

# 3. ペアリングフェーズ
if ($PairPort) {
    if (-not (Test-Reachable $TargetIp $PairPort 'ペアリング用')) {
        Write-Host '[!] ペアリングを中止します。'
        exit 1
    }

    Write-Host '[!] Android 画面に表示されている 6 桁のペアリングコードを入力してください。'
    do {
        $code = Read-Input 'ペアリングコード'
        $valid = $code -match '^\d{6}$'
        if (-not $valid) { Write-Host '[!] 6 桁の数字を入力してください。' }
    } until ($valid)

    # adb pair は失敗時も終了コード 0 を返すことがあるため、出力内容で判定する
    $pairOut = @(& $adb pair "${TargetIp}:${PairPort}" $code)
    $pairOut | ForEach-Object { Write-Host $_ }
    if (($pairOut -join "`n") -notmatch 'Successfully paired') {
        Write-Host '[!] ペアリングに失敗しました。コードとポート番号を確認して再実行してください。'
        exit 1
    }
    Write-Host '------------------------------------------------'
} else {
    Write-Host '[+] ペアリングを省略します。'
}

# 4. 接続フェーズ
if (-not (Test-Reachable $TargetIp $ConnPort '接続用')) {
    Write-Host '[!] 接続を中止します。'
    exit 1
}

# 同じ端末の古いポートでの接続が残っていると adb devices に offline として並ぶので切断しておく
$Serial = "${TargetIp}:${ConnPort}"
& $adb devices | ForEach-Object {
    $s = ($_ -split '\s+')[0]
    if ($s -like "${TargetIp}:*" -and $s -ne $Serial) {
        Write-Host "[+] 古い接続 $s を切断します。"
        & $adb disconnect $s | Out-Null
    }
}

Write-Host '[+] 接続を実行しています...'
& $adb connect $Serial

$state = ''
for ($i = 0; $i -lt 5; $i++) {
    $state = "$(& $adb -s $Serial get-state 2>$null)".Trim()
    if ($state -eq 'device') { break }
    Start-Sleep -Seconds 1
}

# 5. 完了
Write-Host '================================================'
if ($state -eq 'device') {
    Save-LastTarget $Mode $TargetIp
    Write-Host '接続プロセスが完了しました！'
} else {
    Write-Host "[!] 接続を確認できませんでした (状態: $(if ($state) { $state } else { '不明' }))。"
    Write-Host '    未ペアリングの場合はペアリング用ポートも入力して再実行してください。'
}
Write-Host '現在のデバイス一覧:'
& $adb devices
Write-Host '------------------------------------------------'
Write-Host "※ この端末を指定するには: adb -s $Serial <コマンド>"
Write-Host "  切断する際は: adb disconnect $Serial"
Write-Host '================================================'
if ($state -ne 'device') { exit 1 }
