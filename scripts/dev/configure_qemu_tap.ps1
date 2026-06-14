param(
    [string]$TapIfName = 'OpenVPN TAP-Windows6',
    [string]$HostAddress = '10.0.2.2',
    [byte]$PrefixLength = 24
)

$ErrorActionPreference = 'Stop'

$adapter = Get-NetAdapter -Name $TapIfName -ErrorAction Stop
Write-Host "Configuring TAP adapter: $($adapter.Name)" -ForegroundColor Cyan

Set-NetIPInterface -InterfaceAlias $TapIfName -AddressFamily IPv4 -Dhcp Disabled | Out-Null

$existing = Get-NetIPAddress -InterfaceAlias $TapIfName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -ne $HostAddress -or $_.PrefixLength -ne $PrefixLength }
foreach ($addr in $existing) {
    Remove-NetIPAddress -InterfaceAlias $TapIfName -IPAddress $addr.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
}

$current = Get-NetIPAddress -InterfaceAlias $TapIfName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $HostAddress -and $_.PrefixLength -eq $PrefixLength }
if (-not $current) {
    New-NetIPAddress -InterfaceAlias $TapIfName -IPAddress $HostAddress -PrefixLength $PrefixLength | Out-Null
}

Write-Host "TAP host address ready: $HostAddress/$PrefixLength" -ForegroundColor Green
