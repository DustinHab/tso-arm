#!/bin/sh
# Prepares the x86-64 study environment in WSL: DynamoRIO and build tools.
# Run as root once:  wsl.exe -d Ubuntu -u root -- sh /mnt/c/Users/dusti/tso-arm/study/setup_wsl.sh
set -e
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cmake ninja-build zstd xz-utils pigz curl >/dev/null
V=11.91.20771
D=/opt/dynamorio
if [ ! -d $D/DynamoRIO-Linux-$V ]; then
    mkdir -p $D && cd $D
    curl -sSLf -o dr.tar.gz https://github.com/DynamoRIO/dynamorio/releases/download/cronbuild-$V/DynamoRIO-Linux-$V.tar.gz
    tar xzf dr.tar.gz && rm dr.tar.gz
fi
ln -sfn $D/DynamoRIO-Linux-$V $D/current
$D/current/bin64/drrun -version
