#!/usr/bin/env bash

# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 Nitrux Latinoamericana S.C.

set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
version="${1:-latest}"
version="${version#v}"
architecture="$(dpkg --print-architecture)"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes --no-install-recommends ca-certificates curl devscripts equivs jq xz-utils

if [[ "$architecture" != amd64 && "$architecture" != arm64 ]]; then
    printf 'Unsupported package architecture: %s\n' "$architecture" >&2
    exit 1
fi

if [[ "$version" == latest ]]; then
    release_info="$(curl --fail --location --silent --show-error \
        https://api.github.com/repos/mhx/dwarfs/releases/latest)"
    version="$(jq --exit-status --raw-output '.tag_name | sub("^v"; "")' <<< "$release_info")"
fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Invalid DwarFS version: %s\n' "$version" >&2
    exit 1
fi

source_sha256=""
if [[ "$version" == 0.15.8 ]]; then
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
        printf 'No SHA-256 digest published for upstream source archive %s.\n' "$asset_name" >&2
        exit 1
    fi
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
archive="${work_dir}/dwarfs-${version}.tar.xz"
source_dir="${work_dir}/source"

archive_url="https://github.com/mhx/dwarfs/releases/download/v${version}/dwarfs-${version}.tar.xz"
curl --fail --location --retry 3 --output "$archive" "$archive_url"
printf '%s  %s\n' "$source_sha256" "$archive" | sha256sum --check --status || {
    printf 'SHA-256 verification failed for %s\n' "$archive_url" >&2
    exit 1
}

mkdir -p "$source_dir"
tar --extract --xz --file "$archive" --directory "$source_dir" --strip-components=1
cp --recursive "$repo_root/debian" "$source_dir/debian"

expected_version="${version}-1"
current_version="$(dpkg-parsechangelog --file "$source_dir/debian/changelog" --show-field Version)"
if [[ "$current_version" != "$expected_version" ]]; then
    dch --changelog "$source_dir/debian/changelog" \
        --newversion "$expected_version" \
        --distribution unstable \
        --force-bad-version \
        "New upstream version ${version}."
fi

cd "$source_dir"
mk-build-deps --install --remove --tool 'apt-get --yes' debian/control
debuild -b -uc -us

package_file="${work_dir}/dwarfs-tools_${expected_version}_${architecture}.deb"
if [[ ! -f "$package_file" ]]; then
    printf 'Expected package was not created: %s\n' "$package_file" >&2
    exit 1
fi
install --mode=0644 "$package_file" "$repo_root/"
printf 'Built %s\n' "$repo_root/$(basename "$package_file")"
