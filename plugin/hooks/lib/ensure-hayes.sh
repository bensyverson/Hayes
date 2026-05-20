#!/usr/bin/env bash
# Resolve a runnable `hayes` binary for the requested version, downloading
# it from the matching GitHub Release if it is not already cached, and print
# its absolute path to stdout.
#
# Usage:   ensure-hayes.sh <version>
# Output:  the path to an executable hayes binary, on stdout.
#
# This is the binary-distribution mechanism for the plugins: the binary is
# not committed to the repo, it is fetched once from the release and cached
# under ${XDG_CACHE_HOME:-$HOME/.cache}/hayes/. The same cache + asset
# convention is mirrored by the OpenCode plugin, so whichever harness runs
# first populates the shared cache.
#
# Failure is silent by design: every error path exits non-zero with no
# stdout, so a calling hook degrades to "no memory this turn" rather than
# breaking the user's session. The HAYES_BIN escape hatch lets local /
# `--plugin-dir` development point at a freshly built binary without a
# published release.

set -euo pipefail

version="${1:-}"
[[ -n "$version" ]] || exit 1

# Local-dev / test escape hatch: trust an explicitly provided binary.
if [[ -n "${HAYES_BIN:-}" && -x "${HAYES_BIN}" ]]; then
    echo "${HAYES_BIN}"
    exit 0
fi

repo="bensyverson/Hayes"
asset="hayes-macos-universal"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/hayes"
target="${cache_dir}/hayes-${version}"

# Fast path: already cached.
if [[ -x "$target" ]]; then
    echo "$target"
    exit 0
fi

command -v curl >/dev/null 2>&1 || exit 1
command -v shasum >/dev/null 2>&1 || exit 1

mkdir -p "$cache_dir"
base="https://github.com/${repo}/releases/download/v${version}"
tmp="$(mktemp -d "${cache_dir}/dl-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "${base}/${asset}" -o "${tmp}/hayes" || exit 1
curl -fsSL "${base}/${asset}.sha256" -o "${tmp}/hayes.sha256" || exit 1

# The sidecar is "<digest>  <filename>"; compare digests directly so the
# check does not depend on the filename recorded at publish time.
expected="$(awk 'NR==1 {print $1}' "${tmp}/hayes.sha256")"
actual="$(shasum -a 256 "${tmp}/hayes" | awk '{print $1}')"
[[ -n "$expected" && "$expected" == "$actual" ]] || exit 1

chmod +x "${tmp}/hayes"
mv -f "${tmp}/hayes" "$target"
echo "$target"
