#!/usr/bin/env bash
set -euo pipefail

upstream=Lee-xeo/Claude-Cage
tag=${REQUESTED_TAG:-}
if [[ -z "$tag" ]]; then
  tag=$(gh api "repos/$upstream/releases/latest" --jq .tag_name)
fi
stable_tag='^v[0-9]+\.[0-9]+\.[0-9]+$'
if [[ ! "$tag" =~ $stable_tag ]]; then
  echo "::error::Expected a stable release tag such as v0.2.1"
  exit 1
fi
if [[ $(gh api "repos/$upstream/releases/tags/$tag" --jq '.draft or .prerelease') != false ]]; then
  echo "::error::$tag is not a stable published release"
  exit 1
fi

git remote add upstream "https://github.com/$upstream.git"
git fetch --tags upstream main:refs/remotes/upstream/main
git fetch --no-tags origin 'refs/heads/main:refs/remotes/origin/main' 'refs/heads/clashx/*:refs/remotes/origin/clashx/*'
base=$(git rev-parse "refs/tags/$tag^{commit}")
if ! git merge-base --is-ancestor "$base" upstream/main; then
  echo "::error::$tag is not on upstream/main"
  exit 1
fi
if ! git merge-base --is-ancestor origin/main upstream/main; then
  echo "::error::Fork main has diverged from upstream/main"
  exit 1
fi
if [[ $(git rev-parse origin/main) != "$(git rev-parse upstream/main)" ]]; then
  gh api --method POST "repos/$GITHUB_REPOSITORY/merge-upstream" -f branch=main --jq .message
  git fetch --no-tags origin main:refs/remotes/origin/main
  if [[ $(git rev-parse origin/main) != "$(git rev-parse upstream/main)" ]]; then
    echo "::error::Unable to verify fork main at the fetched upstream commit"
    exit 1
  fi
fi

branch="clashx/$tag"
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  source=$(git rev-parse "origin/$branch")
  if ! git merge-base --is-ancestor "$base" "$source"; then
    echo "::error::$branch is not based on $tag"
    exit 1
  fi
  if [[ ${REBUILD:-false} != true ]]; then
    printf '%s is already built.\n' "$branch" >> "$GITHUB_STEP_SUMMARY"
    exit 0
  fi
else
  patch_version=
  while IFS= read -r ref; do
    version=${ref#origin/clashx/}
    if [[ "$version" =~ $stable_tag ]] &&
       [[ "$version" != "$tag" ]] &&
       [[ $(printf '%s\n' "$version" "$tag" | sort -V | sed -n '1p') == "$version" ]]; then
      patch_version=$version
      break
    fi
  done < <(git for-each-ref --sort=-version:refname --format='%(refname:short)' refs/remotes/origin/clashx)
  if [[ -z "$patch_version" ]]; then
    echo "::error::No previous ClashX patch branch found"
    exit 1
  fi
  patch_head="origin/clashx/$patch_version"
  patch_base="refs/tags/$patch_version"
  patch_range="$patch_base..$patch_head"
  if ! git merge-base --is-ancestor "$patch_base" "$patch_head" ||
     [[ $(git rev-list --count "$patch_range") == 0 ]] ||
     [[ $(git rev-list --count --merges "$patch_range") != 0 ]]; then
    echo "::error::Expected a linear patch series on $patch_base"
    exit 1
  fi

  git switch --detach "$base"
  # Keep the entire patch series in Git so we can abort at the first conflict.
  if ! git cherry-pick -x "$patch_range"; then
    conflict_paths=$(git diff --name-only --diff-filter=U)
    git cherry-pick --abort
    if [[ -n "$conflict_paths" ]]; then
      title="ClashX patch conflict on $tag"
      existing=$(gh issue list --repo "$GITHUB_REPOSITORY" --state open --search "$title in:title" \
        --json title,url --jq '.[] | select(.title == "'"$title"'") | .url')
      if [[ -z "$existing" ]]; then
        issue_body="$RUNNER_TEMP/clashx-conflict.md"
        {
          printf '@%s，ClashX 补丁无法自动应用到 `%s`。\n\n' "$GITHUB_REPOSITORY_OWNER" "$tag"
          printf '补丁来源为 `%s`。冲突文件如下。\n\n```\n%s\n```\n\n' "$patch_head" "$conflict_paths"
          printf '处理方法见 [自动化说明](../blob/automation/README.md)。\n\n'
          printf '[查看运行日志](%s/%s/actions/runs/%s)\n' "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
        } > "$issue_body"
        existing=$(gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" --body-file "$issue_body" --assignee "$GITHUB_REPOSITORY_OWNER")
      fi
      printf 'Patch conflict for `%s`. %s\n' "$tag" "$existing" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 1
  fi
  source=$(git rev-parse HEAD)
fi

git update-ref "refs/heads/$branch" "$source"
git bundle create "$RUNNER_TEMP/clashx.bundle" "refs/heads/$branch" "^$base"
printf 'build=true\ntag=%s\nbase=%s\nbranch=%s\nsha=%s\n' "$tag" "$base" "$branch" "$source" >> "$GITHUB_OUTPUT"
