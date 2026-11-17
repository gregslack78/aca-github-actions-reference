#!/usr/bin/env bash
# Step 5: enable the reference repository's release, or seed a separate empty app repository.
# Run only after infrastructure, identities, environment approval and runners are ready.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require GH_OWNER GH_REPO

repo="$GH_OWNER/$GH_REPO"
samples="$POC_DIR/../samples"
[[ -d "$samples" ]] || die "Cannot find $samples. Run this from a full checkout of the reference repository."

if gh api "repos/$repo/contents/samples/app/server.py?ref=main" >/dev/null 2>&1; then
  log "Using the reference repository itself; app stays in samples/"
  gh api "repos/$repo/contents/.github/workflows/release.yml?ref=main" >/dev/null ||
    die "Push the root reference workflows before enabling deployment."
  production=$(gh api "repos/$repo/environments/production")
  jq -e '[.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]?] | length > 0' \
    <<< "$production" >/dev/null || die "Production must have a required reviewer before enabling deployment."
  for environment in build production; do
    policies=$(gh api "repos/$repo/environments/$environment/deployment-branch-policies")
    jq -e '.branch_policies | length == 1 and .[0].name == "main" and .[0].type == "branch"' \
      <<< "$policies" >/dev/null || die "$environment must allow only the main branch."
  done
  runners=$(gh api "repos/$repo/actions/runners")
  for label in aca-build-vmss aca-deploy-vmss; do
    jq -e --arg label "$label" \
      '[.runners[] | select(.status == "online") | select(any(.labels[]; .name == $label))] | length > 0' \
      <<< "$runners" >/dev/null || die "No online runner has label $label. Complete step 4 first."
  done
  read -r -p "Type $repo to enable Azure releases and start the first build: " answer
  [[ "$answer" == "$repo" ]] || die "Confirmation did not match; deployment remains disabled."
  gh variable set DEPLOYMENT_ENABLED --repo "$repo" --body true
  gh workflow run release.yml --repo "$repo" --ref main
  printf '\nRelease requested: https://github.com/%s/actions\nApprove production in the run after the build succeeds.\n' "$repo"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

log "Cloning $repo"
git clone --quiet "https://github.com/$repo.git" "$work/repo"
cd "$work/repo"
git checkout -q -B main

if [[ -n "$(git ls-files)" ]]; then
  die "$repo already has files. This script only seeds an empty repository. Copy the pipeline files in yourself (guide section 8)."
fi

log "Copying app and pipeline files (the Option B runner folder and the optional OIDC helper are left out)"
cp -a "$samples/." .
rm -rf runner .github/workflows/oidc-inspect.yml scripts/install-vm-runner.sh scripts/provision-vm-tools.sh
# Repository hygiene files: CODEOWNERS for the pipeline files and Dependabot for action/image pins.
sed "s|@@OWNER@@|@${GH_REVIEWER:-$GH_OWNER}|g" "$POC_DIR/repo-extras/CODEOWNERS" > .github/CODEOWNERS
cp "$POC_DIR/repo-extras/dependabot.yml" .github/dependabot.yml
find . -path ./.git -prune -o -type f -print | sed 's|^\./||' | sort

login=$(gh api user --jq .login)
user_id=$(gh api user --jq .id)
git add -A
git -c "user.name=$login" -c "user.email=$user_id+$login@users.noreply.github.com" \
  commit -q -m "Add sample app and pipeline from the reference guide" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"

log "Pushing to main (this starts the release workflow)"
git -c credential.helper= -c "credential.helper=!gh auth git-credential" push -q origin main

cat <<EOF

Pushed. Watch the run:  https://github.com/$repo/actions
The 'build' job starts on a build runner. When it finishes, the 'production' job waits for
approval from $GH_REVIEWER: approve it in the run page (Review deployments).

Next: scripts/06-protect-repo.sh (after the first push, because the ruleset blocks direct pushes to main),
then scripts/07-verify.sh (any time) and the test scenarios in POC.md.
EOF
