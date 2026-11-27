#!/usr/bin/env bash
# ------------------------------------------------------------------------
#
# Copyright 2026 WSO2, LLC. (http://wso2.com)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License
#
# ------------------------------------------------------------------------
#
# Opens (or refreshes) a pull request in the Docker image build pipeline repository that sets
# each product version's docker_release_version to the latest v<X.Y.Z>.<N> tag of this repository.
#
# The pipeline repository is private and this repository is public, so its location comes only
# from secrets (masked in logs) and this script never prints it, the file path or file content.
#
# Environment:
#   GITHUB_REPOSITORY      this repository, owner/repo (required)
#   GH_TOKEN               token that can read this repository's tags (required)
#   PIPELINE_TOKEN         token with contents:write and pull-requests:write on the pipeline repo (required)
#   PIPELINE_REPO          pipeline repository, owner/repo (required)
#   PIPELINE_BASE_BRANCH   branch the pull request targets (required)
#   PIPELINE_FILE_PATH     path of the product data file in the pipeline repo (required)
#   PIPELINE_PR_BRANCH     branch the bot pushes to (default: docker-is/update-release-versions)
#   DRY_RUN                "true" to only print the version changes

set -euo pipefail

: "${GITHUB_REPOSITORY:?}" "${GH_TOKEN:?}" "${PIPELINE_TOKEN:?}" \
  "${PIPELINE_REPO:?}" "${PIPELINE_BASE_BRANCH:?}" "${PIPELINE_FILE_PATH:?}"
PR_BRANCH="${PIPELINE_PR_BRANCH:-docker-is/update-release-versions}"
DRY_RUN="${DRY_RUN:-false}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Latest tag per product version, e.g. "7.2.0=7.2.0.9", from this repository's v<X.Y.Z>.<N> tags.
pairs=$(gh api --paginate "repos/${GITHUB_REPOSITORY}/git/matching-refs/tags/v" --jq '.[].ref' \
  | sed -n 's|^refs/tags/v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\.\([0-9][0-9]*\)$|\1 \2|p' \
  | sort -k1,1 -k2,2n \
  | awk '{ last[$1] = $2 } END { for (v in last) print v "=" v "." last[v] }' | sort -V)

# Everything below talks to the pipeline repository with its own token. Keep gh quiet on errors so
# request URLs (which contain the repository and path) are not written to the public log.
pipeline_api() { GH_TOKEN="$PIPELINE_TOKEN" gh api "$@" 2>/dev/null; }
fail() { echo "::error::$1"; exit 1; }

base_sha=$(pipeline_api "repos/${PIPELINE_REPO}/git/ref/heads/${PIPELINE_BASE_BRANCH}" --jq '.object.sha') \
  || fail "Could not read the build pipeline base branch (check the PIPELINE_* secrets and token access)"
file_meta=$(pipeline_api "repos/${PIPELINE_REPO}/contents/${PIPELINE_FILE_PATH}?ref=${base_sha}") \
  || fail "Could not read the product data file from the build pipeline repository"
blob_sha=$(jq -r '.sha' <<< "$file_meta")
jq -r '.content' <<< "$file_meta" | base64 -d > "$work/data.json"

# shellcheck disable=SC2086 # pairs is a whitespace-separated list
changes=$(python3 "$SCRIPT_DIR/bump_release_versions.py" "$work/data.json" $pairs) \
  || fail "Could not update the product data file"

if [[ -z "$changes" ]]; then
  echo "Build pipeline already has the latest release versions."
  exit 0
fi
echo "Release version changes:"
# shellcheck disable=SC2001
sed 's/^/  /' <<< "$changes"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] not opening a pull request"
  exit 0
fi

# Reset the bot branch to the base branch, so the PR always holds one commit with every change.
if pipeline_api "repos/${PIPELINE_REPO}/git/ref/heads/${PR_BRANCH}" >/dev/null; then
  pipeline_api -X PATCH "repos/${PIPELINE_REPO}/git/refs/heads/${PR_BRANCH}" \
    -f sha="$base_sha" -F force=true >/dev/null || fail "Could not reset the pull request branch"
else
  pipeline_api -X POST "repos/${PIPELINE_REPO}/git/refs" \
    -f ref="refs/heads/${PR_BRANCH}" -f sha="$base_sha" >/dev/null || fail "Could not create the pull request branch"
fi

# shellcheck disable=SC2001
summary=$(sed 's/^\([^ ]*\) \([^ ]*\) -> \(.*\)$/\1: \2 → \3/' <<< "$changes")
message="Update IS docker release versions"$'\n\n'"${summary}"
pipeline_api -X PUT "repos/${PIPELINE_REPO}/contents/${PIPELINE_FILE_PATH}" \
  -f message="$message" -f branch="$PR_BRANCH" -f sha="$blob_sha" \
  -f content="$(base64 < "$work/data.json" | tr -d '\n')" >/dev/null || fail "Could not commit the updated file"

body=$(cat <<EOF
Updates \`docker_release_version\` to the latest releases of [${GITHUB_REPOSITORY}](https://github.com/${GITHUB_REPOSITORY}/releases):

$(while read -r product old _ new; do
  echo "* ${product}: ${old} → [${new}](https://github.com/${GITHUB_REPOSITORY}/releases/tag/v${new})"
done <<< "$changes")

This pull request is opened and kept up to date by the release workflow in ${GITHUB_REPOSITORY}.
EOF
)

pr_number=$(pipeline_api "repos/${PIPELINE_REPO}/pulls?state=open&head=${PIPELINE_REPO%%/*}:${PR_BRANCH}" --jq '.[0].number // empty') \
  || fail "Could not look up existing pull requests"
if [[ -n "$pr_number" ]]; then
  pipeline_api -X PATCH "repos/${PIPELINE_REPO}/pulls/${pr_number}" -f body="$body" >/dev/null \
    || fail "Could not update the pull request"
  echo "Updated the existing build pipeline pull request."
else
  pipeline_api -X POST "repos/${PIPELINE_REPO}/pulls" \
    -f title="Update IS docker release versions" -f head="$PR_BRANCH" \
    -f base="$PIPELINE_BASE_BRANCH" -f body="$body" >/dev/null || fail "Could not open the pull request"
  echo "Opened a build pipeline pull request."
fi
