param(
    [string]$Name = "ipc-e2e-x86-01",
    [Parameter(Mandatory = $true)][string]$InstallerIso,
    [Parameter(Mandatory = $true)][string]$VhdPath,
    [string]$SwitchName = "Default Switch",
    [int]$ProcessorCount = 2,
    [int]$MemoryGB = 4,
    [int]$DiskGB = 64
)

$ErrorActionPreference = "Stop"
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    throw "VM already exists: $Name"
}

$vhdDirectory = Split-Path -Parent $VhdPath
New-Item -ItemType Directory -Force -Path $vhdDirectory | Out-Null
$vm = New-VM -Name $Name -Generation 2 `
    -MemoryStartupBytes ($MemoryGB * 1GB) `
    -NewVHDPath $VhdPath -NewVHDSizeBytes ($DiskGB * 1GB) `
    -SwitchName $SwitchName
Set-VMProcessor -VMName $Name -Count $ProcessorCount
Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false
Set-VM -Name $Name -AutomaticCheckpointsEnabled $false
Set-VMFirmware -VMName $Name -EnableSecureBoot On `
    -SecureBootTemplate MicrosoftUEFICertificateAuthority

$installerDrive = Add-VMDvdDrive -VMName $Name -Path $InstallerIso -Passthru
Set-VMFirmware -VMName $Name -FirstBootDevice $installerDrive
Start-VM -Name $Name
Get-VM -Name $Name | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime
