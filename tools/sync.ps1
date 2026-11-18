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
    # tar from Windows carries no execute bits: the command gets its own back
    & ssh.exe $HostName "mkdir -p ~/tso-arm && tar -xf /tmp/tso-arm.tar -C ~/tso-arm && find ~/tso-arm -name '*.sh' -exec sed -i 's/\r$//' {} + && chmod +x ~/tso-arm/bin/tso-arm && rm /tmp/tso-arm.tar"
} finally {
    Pop-Location
}
