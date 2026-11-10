#Requires -Version 7
<#
.SYNOPSIS
    同一サブネット（/24）を ping スキャンして稼働ホストを列挙する。

.DESCRIPTION
    メトリックが最も小さいデフォルトルートから自分の IPv4 アドレスを検出し、
    同じ /24 の .1 から .254 に並列で ping を打ちます。結果は IP 順に表示します。
    ForEach-Object -Parallel を使うため PowerShell 7 以降が必要です。
#>

# 複数のデフォルトルート（VPN など）がある場合は、実際に使われるメトリック最小のものを選ぶ
$defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Sort-Object { $_.RouteMetric + $_.InterfaceMetric } |
    Select-Object -First 1
if ($defaultRoute) {
    $address = Get-NetIPAddress -InterfaceIndex $defaultRoute.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $address) {
    $address = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1
}

if (-not $address) {
    Write-Error "No active IPv4 address found."
    exit 1
}

$ipAddress = $address.IPAddress
Write-Host "Detected local IP address: $ipAddress/$($address.PrefixLength)"
if ($address.PrefixLength -ne 24) {
    Write-Warning "Subnet is /$($address.PrefixLength), but only the /24 range around this address is scanned."
}

if ($ipAddress -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.)\d{1,3}$') {
    $subnetPrefix = $Matches[1]
    Write-Host "Scanning subnet: ${subnetPrefix}1 to ${subnetPrefix}254"

    # 並列実行だと応答順に出てくるので、集めてから IP 順に並べる
    $upHosts = 1..254 | ForEach-Object -Parallel {
        $ip = "${using:subnetPrefix}$_"
        if (Test-Connection -TargetName $ip -Count 1 -TimeoutSeconds 1 -Quiet) {
            $ip
        }
    } -ThrottleLimit 50

    foreach ($ip in ($upHosts | Sort-Object { [version]$_ })) {
        Write-Output "$ip is UP"
    }
    Write-Host "$(@($upHosts).Count) host(s) found."
} else {
    Write-Error "Could not parse subnet from IP address: $ipAddress"
    exit 1
}
