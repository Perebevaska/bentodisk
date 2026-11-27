#!/bin/bash
set -euo pipefail
destination=${1:?Python installation directory required}
work=${2:?Build scratch directory required}
release=20261124
version=3.13.18
project=https://github.com/astral-sh/python-build-standalone
source=https://raw.githubusercontent.com/astral-sh/python-build-standalone/48d61fcd7d85d7013b95576f62f779008c316a63

fetch_runtime() {
    local target=$1 checksum=$2 archive="$work/$1.tar.gz"
    local origin="${BENTODISK_PYTHON_ARCHIVES:-}"
    if [[ -n "$origin" ]]; then
        cp "$origin/$target.tar.gz" "$archive"
    else
        curl -fLsS --retry 3 "$project/releases/download/$release/cpython-$version%2B$release-$target-apple-darwin-install_only_stripped.tar.gz" -o "$archive"
    fi
    echo "$checksum  $archive" | shasum -a 256 -c -
    mkdir -p "$work/$target"
    tar -xzf "$archive" -C "$work/$target" python/bin/python3.13 python/lib/python3.13
}

fetch_runtime aarch64 296f0903cccda15a5c9d3d8393cd2204718aeffd9b095a00f812d75c7b1c0967
fetch_runtime x86_64 bb16e167ec9e38368118ce3e43ba2c7852fea2cdba16e1852555a8997747f78a
mkdir -p "$destination/bin" "$destination/lib/python3.13/lib-dynload" "$destination/licenses"
xcrun lipo -create "$work/aarch64/python/bin/python3.13" "$work/x86_64/python/bin/python3.13" -output "$destination/bin/python3"
# BentoDisk uses the built-in native modules and pure Python standard library.
rsync -a --exclude='lib-dynload/' --exclude='site-packages/' \
    --exclude='ensurepip/' --exclude='idlelib/' --exclude='tkinter/' --exclude='_sysconfigdata*' \
    --include='*/' --include='*.py' --exclude='*' "$work/aarch64/python/lib/python3.13/" "$destination/lib/python3.13/"
for license in LICENSE LICENSE.{cpython,bzip2,expat,libffi,liblzma,mpdecimal,openssl-3,sqlite,zlib,zlib-ng,zstd}.txt; do
    curl -fLsS --retry 3 "$source/$license" -o "$destination/licenses/$license"
done
echo "$project/tree/48d61fcd7d85d7013b95576f62f779008c316a63" > "$destination/licenses/Source.txt"
