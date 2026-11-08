#!/usr/bin/env bash

# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 <Nitrux Latinoamericana S.C. <hello@nxos.org>>

set -e

upstream_url="https://github.com/mhx/dwarfs"
version="${1:-latest}"
architecture="$(dpkg --print-architecture)"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$version" == "latest" ]]; then
    release_url="$(curl --fail --location --silent --show-error \
        --output /dev/null --write-out '%{url_effective}' \
        "${upstream_url}/releases/latest")"
    version="${release_url##*/}"
fi
version="${version#v}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid DwarFS version: $version" >&2
    exit 1
fi

if [[ "$architecture" != "amd64" && "$architecture" != "arm64" ]]; then
    echo "Unsupported package architecture: $architecture" >&2
    exit 1
fi

echo "Building DwarFS $version for $architecture"

### Basic Packages
apt -qq update
apt -qq -yy install ca-certificates curl devscripts equivs jq lintian xz-utils --no-install-recommends

### Get the upstream source archive checksum
source_sha256=""
if [[ "$version" == "0.15.8" ]]; then
    source_sha256="a2382a2d06f4539b1c53b8b4f800776945e2f13f71c0a3226d3bab3e1b25fe04"
else
    release_info="$(curl --fail --location --silent --show-error \
        "https://api.github.com/repos/mhx/dwarfs/releases/tags/v${version}")"
    asset_name="dwarfs-${version}.tar.xz"
    asset_digest="$(jq --exit-status --raw-output --arg name "$asset_name" \
        '.assets[] | select(.name == $name) | .digest // empty' <<< "$release_info")"
    if [[ "$asset_digest" =~ ^sha256:([[:xdigit:]]{64})$ ]]; then
        source_sha256="${BASH_REMATCH[1]}"
    else
        echo "No SHA-256 digest published for upstream source archive $asset_name." >&2
        exit 1
    fi
fi

### Download and verify the source
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
archive="${work_dir}/dwarfs-${version}.tar.xz"
source_dir="${work_dir}/source"
archive_url="${upstream_url}/releases/download/v${version}/dwarfs-${version}.tar.xz"

curl --fail --location --retry 3 --output "$archive" "$archive_url"
echo "$source_sha256  $archive" | sha256sum --check --status || {
    echo "SHA-256 verification failed for $archive_url" >&2
    exit 1
}

mkdir -p "$source_dir"
tar --extract --xz --file "$archive" --directory "$source_dir" --strip-components=1
cp --recursive "$repo_root/debian" "$source_dir/debian"
cd "$source_dir"

### Set the package version
expected_version="${version}-1"
current_version="$(dpkg-parsechangelog --show-field Version)"
if [[ "$current_version" != "$expected_version" ]]; then
    dch --newversion "$expected_version" --distribution unstable --force-bad-version --maintmaint \
        "New upstream version $version."
fi

### Install Dependencies
mk-build-deps -i -t "apt-get --yes" -r

### Build Deb
debuild -b -uc -us

### Move Deb to current directory because debuild decided
### that it was a GREAT IDEA TO PUT THE FILE ONE LEVEL ABOVE
mv ../*.deb "$repo_root/"
