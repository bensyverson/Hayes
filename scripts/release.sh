#!/usr/bin/env bash
# Cuts a hayes release: bumps version, rebuilds the plugin binary, runs
# tests and lint, commits, and tags. Pushing is left to the developer.
#
# Usage:
#   ./scripts/release.sh 0.2.0
#   ./scripts/release.sh v0.2.0       # leading v is stripped
#
# Sync points (both updated atomically):
#   - plugin/.claude-plugin/plugin.json    (marketplace-visible version)
#   - Sources/HayesCommand/Hayes.swift     (reported by `hayes --version`)
#
# To undo before pushing:
#   git tag -d vX.Y.Z && git reset --hard HEAD^

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>     # e.g. 0.2.0 or v0.2.0" >&2
    exit 2
fi

version="${1#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
    echo "Error: version must look like X.Y.Z or X.Y.Z-suffix (got: $version)" >&2
    exit 2
fi
tag="v$version"

for tool in jq swiftformat swift git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: required tool '$tool' is not installed." >&2
        exit 2
    fi
done

if ! git diff-index --quiet HEAD --; then
    echo "Error: working tree has uncommitted changes. Commit or stash first." >&2
    exit 2
fi

if git rev-parse "refs/tags/$tag" >/dev/null 2>&1; then
    echo "Error: tag $tag already exists." >&2
    exit 2
fi

branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "<detached>")
if [[ "$branch" != "main" ]]; then
    echo "Warning: releasing from branch '$branch' (not main). Continuing." >&2
fi

manifest=plugin/.claude-plugin/plugin.json
swift_cli=Sources/HayesCommand/Hayes.swift

current_manifest=$(jq -r '.version' "$manifest")
if [[ "$current_manifest" == "$version" ]]; then
    echo "Error: $manifest is already at version $version. Nothing to bump." >&2
    exit 2
fi

echo "==> Bumping version: $current_manifest -> $version"

tmp=$(mktemp)
jq --arg v "$version" '.version = $v' "$manifest" > "$tmp"
mv "$tmp" "$manifest"

# BSD/GNU sed compatible: -i with a backup suffix, then remove the backup.
sed -i.bak -E "s/(version: \")[^\"]+(\",)/\1$version\2/" "$swift_cli"
rm -f "$swift_cli.bak"

echo "==> Running lint..."
swiftformat . --lint

echo "==> Running tests..."
swift test --quiet

echo "==> Building plugin binary..."
./scripts/build-plugin.sh

echo "==> Verifying staged binary reports $version..."
binary_version=$(./plugin/bin/hayes --version)
if [[ "$binary_version" != "$version" ]]; then
    echo "Error: built binary reports '$binary_version' (expected '$version')." >&2
    echo "       Bump in $swift_cli may have failed — check the file before retrying." >&2
    exit 1
fi

echo "==> Committing release..."
git add "$manifest" "$swift_cli" plugin/bin/hayes
git commit -m "Releases $version"

echo "==> Tagging $tag..."
git tag -a "$tag" -m "Release $version"

cat <<EOF

Release $version is staged locally. To publish:

  git push origin $branch $tag

To undo before pushing:

  git tag -d $tag && git reset --hard HEAD^

EOF
