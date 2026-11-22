#!/bin/bash
set -euo pipefail

# Publish the prepared 1.0 release, including its compiled application.
project_dir=$(cd "$(dirname "$0")/.." && pwd)
release_tag="v1.0.0"
release_repo="Meiphia/iSyncer"
release_zip="$project_dir/build/iSyncer-1.0.0.zip"
release_sum="$release_zip.sha256"
release_notes="$project_dir/RELEASE-1.0.0.md"

git_project() {
    if [[ -d "$project_dir/.git-data" ]]; then
        git --git-dir="$project_dir/.git-data" --work-tree="$project_dir" "$@"
    else
        git -C "$project_dir" "$@"
    fi
}

command -v gh >/dev/null
[[ -s "$release_zip" && -s "$release_sum" && -s "$release_notes" ]] || {
    echo "Missing prepared release files. Build and package iSyncer 1.0.0 first." >&2
    exit 1
}
[[ "$(git_project rev-parse HEAD)" == "$(git_project rev-parse "refs/tags/$release_tag^{commit}")" ]] || {
    echo "Check out the prepared v1.0.0 commit before publishing." >&2
    exit 1
}
[[ -z "$(git_project status --porcelain --untracked-files=no)" ]] || {
    echo "Commit or set aside tracked changes before publishing." >&2
    exit 1
}
(cd "$project_dir/build" && shasum -a 256 -c "$(basename "$release_sum")")
unzip -tq "$release_zip"
gh auth status --hostname github.com
git_project push origin HEAD:refs/heads/main "refs/tags/$release_tag"

if gh release view "$release_tag" --repo "$release_repo" >/dev/null 2>&1; then
    gh release upload "$release_tag" "$release_zip" "$release_sum" --repo "$release_repo" --clobber
else
    # Keep it as a draft until the app and its checksum are both present.
    gh release create "$release_tag" "$release_zip" "$release_sum" --repo "$release_repo" \
        --verify-tag --draft --title "iSyncer 1.0" --notes-file "$release_notes"
fi

assets_ready=$(gh release view "$release_tag" --repo "$release_repo" --json assets \
    --jq '[.assets[].name] | (index("iSyncer-1.0.0.zip") != null and index("iSyncer-1.0.0.zip.sha256") != null)')
[[ "$assets_ready" == "true" ]] || {
    echo "The app or checksum is missing from the release. Publication stopped." >&2
    exit 1
}
gh release edit "$release_tag" --repo "$release_repo" --draft=false --latest \
    --title "iSyncer 1.0" --notes-file "$release_notes"
gh release view "$release_tag" --repo "$release_repo" --json url --jq .url
