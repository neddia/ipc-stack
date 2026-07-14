param(
    [string]$Name = "ipc-e2e-x86-01",
    [Parameter(Mandatory = $true)][string]$VhdPath
)

$ErrorActionPreference = "Stop"
$vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
if ($vm) {
    Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-VM -Name $Name -Force
}
Remove-Item -Force -ErrorAction SilentlyContinue $VhdPath
