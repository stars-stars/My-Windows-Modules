$defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($defaultRoute) {
    $ipAddress = (Get-NetIPAddress -InterfaceIndex $defaultRoute.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
}
if (-not $ipAddress) {
    $ipAddress = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
}

if (-not $ipAddress) {
    Write-Error "No active IPv4 address found."
    exit 1
}

Write-Host "Detected local IP address: $ipAddress"

if ($ipAddress -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.)\d{1,3}$') {
    $subnetPrefix = $Matches[1]
    Write-Host "Scanning subnet: ${subnetPrefix}1 to ${subnetPrefix}254"
    
    1..254 | ForEach-Object -Parallel {
        $ip = "${using:subnetPrefix}$_"
        if (Test-Connection -ComputerName $ip -Count 1 -Quiet) {
            Write-Output "$ip is UP"
        }
    } -ThrottleLimit 50
} else {
    Write-Error "Could not parse subnet from IP address: $ipAddress"
}