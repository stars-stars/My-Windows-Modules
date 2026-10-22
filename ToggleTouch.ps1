$device = Get-PnpDevice -Class HIDClass |
    Where-Object { $_.FriendlyName -eq "Intel(R) Precise Touch Device" }

if (-not $device) {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
        "Intel(R) Precise Touch Device が見つかりません。",
        "Touch Toggle"
    )
    exit 1
}

# 管理者権限があるかを確認
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "管理者権限で実行されていません。"
    exit 1
}

if ($device.Status -eq "OK") {
    Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
    Write-Host "`e[2K`rTouch Screen OFF" -ForegroundColor Green
} else {
    Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
    Write-Host "Touch Screen ON" -ForegroundColor Green
}