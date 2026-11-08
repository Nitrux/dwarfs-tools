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

case "$architecture" in
    amd64)
        upstream_arch="x86_64"
        ;;
    arm64)
        upstream_arch="aarch64"
        ;;
    *)
        echo "Unsupported package architecture: $architecture" >&2
        exit 1
        ;;
esac

echo "Packaging DwarFS $version universal binary for $architecture"

### Basic Packages
apt -qq update
apt -qq -yy install ca-certificates curl devscripts equivs jq lintian xz-utils --no-install-recommends

### Get the upstream asset checksums
release_info="$(curl --fail --location --silent --show-error \
    "https://api.github.com/repos/mhx/dwarfs/releases/tags/v${version}")"
universal_asset="dwarfs-universal-${version}-Linux-${upstream_arch}"
source_asset="dwarfs-${version}.tar.xz"

if [[ "$version" == "0.15.8" && "$upstream_arch" == "x86_64" ]]; then
    universal_sha256="0ed66df82f9bb6671c1f898404ff4d57c263460078d46dbac8efb9d8eec271b7"
    source_sha256="a2382a2d06f4539b1c53b8b4f800776945e2f13f71c0a3226d3bab3e1b25fe04"
elif [[ "$version" == "0.15.8" && "$upstream_arch" == "aarch64" ]]; then
    universal_sha256="f21cbc33840bbffe410c7043fab85e0d1b4eee86d77bcc0fbf3a51b94fc4b222"
    source_sha256="a2382a2d06f4539b1c53b8b4f800776945e2f13f71c0a3226d3bab3e1b25fe04"
else
    universal_digest="$(jq --exit-status --raw-output --arg name "$universal_asset" \
        '.assets[] | select(.name == $name) | .digest // empty' <<< "$release_info")"
    source_digest="$(jq --exit-status --raw-output --arg name "$source_asset" \
        '.assets[] | select(.name == $name) | .digest // empty' <<< "$release_info")"
    if [[ "$universal_digest" =~ ^sha256:([[:xdigit:]]{64})$ ]]; then
        universal_sha256="${BASH_REMATCH[1]}"
    else
        echo "Upstream release is missing the universal binary SHA-256 digest." >&2
        exit 1
    fi
    if [[ "$source_digest" =~ ^sha256:([[:xdigit:]]{64})$ ]]; then
        source_sha256="${BASH_REMATCH[1]}"
    else
        echo "Upstream release is missing the source archive SHA-256 digest." >&2
        exit 1
    fi
fi

### Download and verify the upstream universal binary and license files
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
source_dir="${work_dir}/source"
universal_binary="${work_dir}/dwarfs-universal"
source_archive="${work_dir}/${source_asset}"

curl --fail --location --retry 3 \
    --output "$universal_binary" \
    "${upstream_url}/releases/download/v${version}/${universal_asset}"
curl --fail --location --retry 3 \
    --output "$source_archive" \
    "${upstream_url}/releases/download/v${version}/${source_asset}"
echo "$universal_sha256  $universal_binary" | sha256sum --check --status || {
    echo "SHA-256 verification failed for $universal_asset" >&2
    exit 1
}
echo "$source_sha256  $source_archive" | sha256sum --check --status || {
    echo "SHA-256 verification failed for $source_asset" >&2
    exit 1
}

mkdir -p "$source_dir"
tar --extract --xz --file "$source_archive" --directory "$source_dir" --strip-components=1
mkdir -p "$source_dir/.upstream-bin"
install --mode=0755 "$universal_binary" "$source_dir/.upstream-bin/dwarfs-universal"
cp --recursive "$repo_root/debian" "$source_dir/debian"
cd "$source_dir"

### Set the package version
current_version="$(dpkg-parsechangelog --show-field Version)"
current_upstream_version="${current_version%-*}"
if [[ "$current_upstream_version" != "$version" ]]; then
    expected_version="${version}-1"
    dch --newversion "$expected_version" --distribution unstable --force-bad-version --maintmaint \
        "New upstream version $version."
else
    expected_version="$current_version"
fi

### Install Dependencies
mk-build-deps -i -t "apt-get --yes" -r

### Build Deb
debuild -b -uc -us

### Move Deb to current directory because debuild decided
### that it was a GREAT IDEA TO PUT THE FILE ONE LEVEL ABOVE
mv ../*.deb "$repo_root/"
