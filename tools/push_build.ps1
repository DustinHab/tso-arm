# Copies build artifacts (x86 binaries, corpora, lists, litmus binary) to ~/tso-arm/build on the test machine.
param([string]$HostName = "pi5", [switch]$Corpus)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$b = Join-Path $root "build"
& ssh.exe $HostName "mkdir -p ~/tso-arm/build/x86 ~/tso-arm/build/lists"
& scp.exe -q (Join-Path $b "x86\*") "${HostName}:tso-arm/build/x86/"
& scp.exe -q (Join-Path $b "lists\*") "${HostName}:tso-arm/build/lists/"
& scp.exe -q (Join-Path $b "mp-x86") (Join-Path $b "expected.md5") "${HostName}:tso-arm/build/"
if ($Corpus) { & scp.exe -q (Join-Path $b "corpus.tar") (Join-Path $b "corpus8.tar") "${HostName}:tso-arm/build/" }
& ssh.exe $HostName "chmod +x ~/tso-arm/build/x86/* ~/tso-arm/build/mp-x86; ls -la ~/tso-arm/build ~/tso-arm/build/lists | head -20"
