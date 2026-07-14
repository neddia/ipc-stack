param(
    [string]$Name = "ipc-e2e-x86-01",
    [int]$InstallTimeoutMinutes = 60,
    [int]$AddressTimeoutMinutes = 15
)

$ErrorActionPreference = "Stop"
$installDeadline = (Get-Date).AddMinutes($InstallTimeoutMinutes)
Write-Output "Waiting for Ubuntu autoinstall to power off $Name"
while ((Get-VM -Name $Name).State -ne "Off") {
    if ((Get-Date) -ge $installDeadline) {
        throw "Ubuntu autoinstall did not power off within $InstallTimeoutMinutes minutes"
    }
    Start-Sleep -Seconds 10
}

Get-VMDvdDrive -VMName $Name | Remove-VMDvdDrive
$disk = Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1
Set-VMFirmware -VMName $Name -FirstBootDevice $disk
Start-VM -Name $Name

function Find-NeighborIPv4 {
    $adapter = Get-VMNetworkAdapter -VMName $Name | Select-Object -First 1
    if (-not $adapter) {
        return $null
    }

    $mac = ($adapter.MacAddress -replace '(.{2})(?!$)', '$1-')
    $candidates = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LinkLayerAddress -eq $mac -and
            $_.State -notin @('Unreachable', 'Incomplete')
        } |
        Select-Object -ExpandProperty IPAddress -Unique

    foreach ($candidate in $candidates) {
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $pending = $client.BeginConnect($candidate, 22, $null, $null)
            if ($pending.AsyncWaitHandle.WaitOne(500)) {
                $client.EndConnect($pending)
                return $candidate
            }
        }
        catch {
            # A stale neighbor entry is normal after recreating an E2E VM.
        }
        finally {
            $client.Dispose()
        }
    }
    return $null
}

$addressDeadline = (Get-Date).AddMinutes($AddressTimeoutMinutes)
do {
    $addresses = Get-VMNetworkAdapter -VMName $Name | Select-Object -ExpandProperty IPAddresses
    $ipv4 = $addresses | Where-Object {
        $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^169\.254\.'
    } | Select-Object -First 1
    if ($ipv4) {
        Write-Output "IPv4=$ipv4"
        exit 0
    }
    $ipv4 = Find-NeighborIPv4
    if ($ipv4) {
        Write-Output "IPv4=$ipv4"
        exit 0
    }
    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $addressDeadline)

throw "Installed VM did not report an IPv4 address within $AddressTimeoutMinutes minutes"
