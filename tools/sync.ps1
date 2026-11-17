# Copies the tracked and untracked (not ignored) files of the repository to ~/tso-arm on the test machine.
param([string]$HostName = "pi5")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $list = Join-Path $env:TEMP "tso-arm-files.txt"
    $tar = Join-Path $env:TEMP "tso-arm.tar"
    git ls-files -co --exclude-standard | Set-Content -Encoding ascii $list
    if (Test-Path $tar) { Remove-Item $tar }
    & tar.exe -cf $tar -T $list
    & scp.exe -q $tar "${HostName}:/tmp/tso-arm.tar"
    & ssh.exe $HostName "mkdir -p ~/tso-arm && tar -xf /tmp/tso-arm.tar -C ~/tso-arm && find ~/tso-arm -name '*.sh' -exec sed -i 's/\r$//' {} + && rm /tmp/tso-arm.tar"
} finally {
    Pop-Location
}
