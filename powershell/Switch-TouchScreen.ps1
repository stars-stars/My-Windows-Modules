<#
.SYNOPSIS
    タッチスクリーン（Intel(R) Precise Touch Device）の有効 / 無効を切り替える。

.DESCRIPTION
    管理者権限がない場合は UAC で自分自身を管理者として起動し直し、
    切り替えが終わったら元のコンソールに結果を表示します。
#>

$deviceName = "Intel(R) Precise Touch Device"

function Get-TouchDevice {
    Get-PnpDevice -Class HIDClass |
        Where-Object { $_.FriendlyName -eq $deviceName } |
        Select-Object -First 1
}

function Write-TouchState($dev) {
    if ($dev.Status -eq "OK") {
        Write-Host "Touch Screen ON" -ForegroundColor Green
    } else {
        Write-Host "Touch Screen OFF" -ForegroundColor Green
    }
}

$device = Get-TouchDevice
if (-not $device) {
    Write-Host "$deviceName が見つかりません。" -ForegroundColor Red
    exit 1
}

# 管理者権限があるかを確認
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    # 同じ PowerShell（pwsh / powershell）で管理者として起動し直し、終わるまで待つ
    $exe = (Get-Process -Id $PID).Path
    try {
        Start-Process -FilePath $exe -Verb RunAs -Wait -WindowStyle Hidden `
            -ArgumentList '-NoProfile', '-File', "`"$PSCommandPath`""
    } catch {
        Write-Host "管理者権限で実行できませんでした（UAC がキャンセルされました）。" -ForegroundColor Red
        exit 1
    }
    Write-TouchState (Get-TouchDevice)
    exit 0
}

if ($device.Status -eq "OK") {
    Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
} else {
    Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
}
Write-TouchState (Get-TouchDevice)
