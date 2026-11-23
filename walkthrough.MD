# Customer walkthrough: from code change to approved release

This demonstration follows a small application change through GitHub and into Azure Container Apps (ACA). It shows how developers get fast feedback while production deployment remains a separate, controlled decision.

There are two ways to present it:

- **Walkthrough 1: quick demonstration** - follow the developer experience from branch to browser.
- **Walkthrough 2: technical walkthrough** - start at the commit and explain the workflow code behind each transition.

The central message is: **validate the change, build a release image once, approve its deployment, and verify the exact commit serving traffic.**

## Demo context and preparation

The application serves an HTML welcome page at `/` and a JSON health response at `/health`. Both identify the release commit. The production-style path uses a private registry, a private app, and self-hosted runners with network access to those services.

For browser demonstrations, a separate optional app receives the same image after the private app is deployed. This does not make the original app or registry public.

Before presenting:

- Open the repository in VS Code and have the GitHub **Pull requests** and **Actions** tabs available.
- Open the configured browser demo URL. Its hostname is stored in the repository variable `DEMO_APP_FQDN`.
- Confirm the build and deploy runners are online and a production reviewer is available.
- Use a unique branch name and visible message for each demonstration.
- Avoid merging another change while the demonstrated release waits for approval: the deployment deliberately rejects an outdated `main` commit.
- Allow time for the optional demo to start if it has scaled to zero.

**Recorded example:** the change adding "And another small change." to [the server](samples/app/server.py) was merged through [PR #11](https://github.com/gregslack78/aca-github-actions-reference/pull/11). As checked on November 20, 2026, its [release run](https://github.com/gregslack78/aca-github-actions-reference/actions/runs/44172446419) completed successfully. This is historical pipeline evidence, not a continuous availability check.

At that check, `DEPLOYMENT_ENABLED`, `DEMO_DEPLOYMENT_ENABLED`, and `DEMO_PUBLIC_ACCESS` were all `true`. The browser demo was therefore configured for public, unauthenticated HTTPS. Keep its content non-sensitive. The private architecture remains separate; see the [browser demo setup and access options](poc/POC.md#t8-optional-browser-welcome-page).

## Walkthrough 1: quick demonstration

### 1. Create a branch

From the repository root, start from the latest `main`:

```powershell
git switch main
git pull --ff-only
git switch -c demo/customer-welcome
```

Start with a clean worktree; preserve any existing uncommitted work before switching branches.

**Explain:** "A branch isolates our proposed change. We can review and test it before it becomes part of the release branch."

### 2. Make a visible application change

Open [the server](samples/app/server.py#L41) and add a short paragraph alongside the existing welcome-page messages:

```html
<p>Customer demo: this change followed the approved release path.</p>
```

Leave the health response unchanged.

**Explain:** "This is intentionally a small application change. The purpose is to show the delivery controls, not to introduce application complexity."

### 3. Commit and push

```powershell
git add samples\app\server.py
git commit -m "Update welcome message for customer demo"
git push -u origin demo/customer-welcome
```

**Explain:** "The commit gives this version of the source a unique identity. Pushing makes it available for collaboration. A local commit alone does not start GitHub Actions."

### 4. Open a pull request and watch the checks

```powershell
gh pr create --base main --title "Update customer demo welcome message" --body "Demonstrate the reviewed and approved release path."
```

In the pull request, show the diff and open **Checks**. Follow **Unprivileged pull request checks**.

**Explain:** "Opening the PR starts automated validation on a GitHub-hosted runner. It tests the application and deployment automation and checks that a container can be built. It does not sign in to Azure or publish an image."

Wait for the checks to pass. Use the normal review and merge process configured for the repository.

### 5. Merge and watch the release build

After merging, open **Actions > Build once and deploy immutable image** and select the run for the new `main` commit.

Show these build steps:

1. Application tests.
2. Azure sign-in.
3. **Build, push and resolve digest**.
4. **Retain release evidence**.

**Explain:** "Merging updates `main`, which starts the release workflow. The trusted build runner packages the application, publishes it to the private registry, and records the image's content digest. Production will use that exact image rather than rebuilding it."

### 6. Pause at production approval

When the build finishes, show **Waiting for review**.

**Explain:** "Build success is not permission to change production. GitHub's production environment requires a reviewer before the deployment job can begin."

Select **Review deployments**, choose `production`, and approve when ready. PR review and deployment approval are separate decisions.

### 7. Watch the approved deployment

Expand **Stage, smoke test and promote**, then **Deploy optional browser demo**.

**Explain:** "The deploy job checks that this is still the latest `main` commit. It creates a candidate revision while traffic remains on the previous revision, checks health and commit identity, moves traffic to the candidate, and checks again. The optional browser app is updated afterward with the same image."

Wait for the run to finish successfully.

### 8. Show the result in the browser

Refresh the configured demo URL and point out:

- The new welcome-page message.
- The **Release commit** value.
- The **View application health** link and its matching JSON commit.

Compare that commit with the release run's `main` commit, not necessarily the feature-branch commit: merging can produce a different commit SHA.

**Close with:** "We can trace the visible change back to a reviewed commit, a specific container image, an approved deployment, and a verified running revision."

## Walkthrough 2: technical walkthrough

This walkthrough repeats the same delivery path, starting with the commit. Source links point to the workflow and script line numbers in this version of the repository; recheck them if those files change.

### 1. Commit and push: establish source identity

The commit records the change to [the server](samples/app/server.py). Pushing uploads that history to GitHub.

The current workflows do **not** run just because any branch receives a push. Both automatic push triggers are restricted to `main`. For a feature branch, opening a PR targeting `main` is what starts the PR checks; subsequent pushes to that open PR also cause checks to run.

**Why it matters:** source identity is carried into the image and health response, allowing the release process to verify more than a generic HTTP 200.

### 2. Pull request: why GitHub starts the checks

Open [the root CI workflow](.github/workflows/ci.yml#L3):

```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
```

The `pull_request` branch filter refers to the PR's **target branch**, not its source branch. A PR from the demo branch into `main` matches. With no explicit activity types, the standard PR activities include opening, reopening, and updating the PR's head branch.

The same workflow also runs after a push to `main`, including a merge. Seeing checks on both the PR and `main` is therefore expected.

At [CI line 14](.github/workflows/ci.yml#L14), the concurrency group identifies a PR or branch, and `cancel-in-progress: true` cancels superseded checks in that group. The latest proposed version is the useful validation target.

**Important distinction:** the actual workflows GitHub runs are in [the root workflow directory](.github/workflows). The files in [the sample workflow directory](samples/.github/workflows) are portable source templates. The root files are generated from those templates by [the workflow renderer](_authoring/render_workflows.py), with repository-specific working directories. Future workflow changes should follow that generation pattern.

### 3. PR validation: test and package without deployment access

Use these source stops in [the CI workflow](.github/workflows/ci.yml):

| Source stop | What happens | Why it is there |
|---|---|---|
| [Line 11](.github/workflows/ci.yml#L11) | Shell commands default to the sample application directory. | The app and its Dockerfile are not at the repository root. |
| [Line 12](.github/workflows/ci.yml#L12) | The token has `contents: read`; no OIDC permission is granted. | PR validation does not need Azure deployment credentials. |
| [Line 19](.github/workflows/ci.yml#L19) | `ubuntu-24.04` selects a GitHub-hosted runner. | Unreviewed changes are kept off the trusted private-network runners. |
| [Line 22](.github/workflows/ci.yml#L22) | Checkout retrieves source without persisting Git credentials. | Later application commands do not need retained checkout credentials. |
| [Line 25](.github/workflows/ci.yml#L25) | Runs deployment-automation regression tests from the repository root. | Checks the delivery tooling as well as the app. |
| [Line 28](.github/workflows/ci.yml#L28) | Runs application unit and HTTP tests. | Checks response content, commit handling, routes, and response headers. |
| [Line 30](.github/workflows/ci.yml#L30) | Builds a local `hello:pr` image. | Confirms packaging works without Azure login or registry push. |

The optional [demo access-boundary job at line 32](.github/workflows/ci.yml#L32) runs only on `main` when enabled. It expects HTTP 200 for explicit public demo mode, or HTTP 403 for an internet client outside the restricted demo allow list. It checks the configured access boundary; it is not the candidate release's health/commit smoke test.

**Presenter distinction:** a successful PR container build is a packaging check, not the published release artifact. These steps do not claim to perform vulnerability scanning or a full end-to-end application test.

### 4. Merge: start the trusted release workflow

At [release line 3](.github/workflows/release.yml#L3), the release workflow listens for pushes to `main` and offers `workflow_dispatch` for manual runs.

At [release line 16](.github/workflows/release.yml#L16), the build also requires:

```yaml
if: github.ref == 'refs/heads/main' && vars.DEPLOYMENT_ENABLED == 'true'
```

This keeps deployment disabled until the repository is deliberately configured and prevents a manual feature-branch run from releasing.

At [release line 17](.github/workflows/release.yml#L17), `environment: build` selects the build environment. The next line selects the runner labels from repository variables. The POC configures those labels for self-hosted VMSS build runners in [the GitHub setup script](poc/scripts/03-configure-github.sh).

**Why a self-hosted runner:** it can reach the private registry from the provisioned network. Authentication alone does not provide private network connectivity.

**Do not imply a dependency that is not present:** CI and release are separate workflows triggered by the same `main` update. The release workflow does not wait on the entire CI workflow. PR checks are enforced through the configured merge controls; the release build also reruns the application tests.

### 5. Build authentication: use federation instead of an Azure secret

At [release line 20](.github/workflows/release.yml#L20), the build job grants `contents: read` and `id-token: write`. The latter permits GitHub to issue an OIDC identity token; it does not itself grant Azure resource permissions.

At [release line 32](.github/workflows/release.yml#L32), temporary Azure and Docker configuration directories isolate job credentials. Checkout and app tests follow, then [Azure login at line 43](.github/workflows/release.yml#L43) uses environment-scoped client, tenant, and subscription IDs.

Microsoft Entra ID accepts the GitHub token only when it matches the configured federated trust. Azure RBAC determines what the identity may do. The setup assigns different client IDs to the build and production environments in [the GitHub configuration script](poc/scripts/03-configure-github.sh#L57).

**Explain:** "The workflow stores identity identifiers, not an Azure client secret. Build and deployment authenticate separately and have different responsibilities."

### 6. Package and push: turn source into an immutable release reference

Open [release line 48](.github/workflows/release.yml#L48), **Build, push and resolve digest**.

The [tag at line 53](.github/workflows/release.yml#L53) includes the commit, workflow run ID, and attempt:

```bash
tag="sha-${GITHUB_SHA}-r${GITHUB_RUN_ID}-a${GITHUB_RUN_ATTEMPT}"
```

This distinguishes builds and reruns. In the POC's `vmss` mode, [lines starting at 55](.github/workflows/release.yml#L55) execute:

```bash
az acr login --name "$ACR_NAME" --output none
docker build --build-arg APP_COMMIT="$GITHUB_SHA" \
  -t "$ACR_LOGIN_SERVER/$IMAGE_REPOSITORY:$tag" .
docker push "$ACR_LOGIN_SERVER/$IMAGE_REPOSITORY:$tag"
```

- `az acr login` authenticates Docker to Azure Container Registry (ACR) using the signed-in identity.
- The final `.` is the build context: the sample application directory, because of the workflow defaults.
- `docker build` uses [the application Dockerfile](samples/Dockerfile#L1). It starts from Python 3.12 slim, embeds `APP_COMMIT`, copies the server, selects a non-root user, and starts the server on port 8080.
- `docker push` uploads the built image to the named registry repository. This publishes an artifact; it does not yet update Container Apps.

The alternate [ACR Tasks branch at line 61](.github/workflows/release.yml#L61) delegates the build to a configured registry agent pool. It is included for runners that cannot run Docker; the POC setup selects `vmss`.

At [release line 69](.github/workflows/release.yml#L69), the workflow resolves the tag to its digest, validates the SHA-256 format, and constructs:

```text
<registry>/<repository>@sha256:<content-digest>
```

That digest reference is written to the step output. The [build job output at line 29](.github/workflows/release.yml#L29) exposes it to the deploy job.

At [release line 74](.github/workflows/release.yml#L74), the workflow also records the image, commit, and run in a JSON release record. [Line 77](.github/workflows/release.yml#L77) uploads that record as an artifact retained for 30 days, and the run summary displays the image and commit.

**Why the digest matters:** tags are names that can be reassigned. The content digest identifies the image being deployed. Production consumes the published image; it does not rebuild source after approval. This identifies the application image, but does not by itself promise reproducible future rebuilds of the Dockerfile's tagged base image.

### 7. Production approval: how the wait was implemented

At [release line 90](.github/workflows/release.yml#L90), the deploy job starts with:

```yaml
deploy:
  needs: build
  environment: production
```

These settings do different jobs:

- `needs: build` requires the build job to succeed first.
- `environment: production` attaches the job to GitHub's production environment and its protection rules.

**The required reviewer is configured in GitHub, not in a YAML sleep or approval command.**

The provisioning code is in [the GitHub setup script](poc/scripts/03-configure-github.sh#L23):

- [Line 27](poc/scripts/03-configure-github.sh#L27) constructs the environment configuration, including `reviewers` and `prevent_self_review`.
- [Line 32](poc/scripts/03-configure-github.sh#L32) applies it with the GitHub API.
- [Line 35](poc/scripts/03-configure-github.sh#L35) ensures a `main` deployment branch policy exists.
- [Line 42](poc/scripts/03-configure-github.sh#L42) resolves the configured reviewer's GitHub user ID.
- [Line 44](poc/scripts/03-configure-github.sh#L44) creates/configures `production` with that reviewer; `build` is configured without a required reviewer.

Show the result under **Settings > Environments > production**. The self-review setting is configurable and defaults to allowing self-review for a single-operator POC; do not describe the demo as enforcing two-person approval unless that setting and a separate reviewer have been configured. Required-reviewer availability also depends on GitHub plan and repository visibility.

While the run waits, the image has already been published, but the deploy job's steps have not begun. A reviewer selects **Review deployments**, chooses `production`, and approves or rejects.

**Why it matters:** code review decides whether to merge a change. Environment approval decides whether this built release should change production now.

### 8. After approval: select the exact image and reject stale releases

After approval, the deployment can proceed on the selected deploy runner, subject to runner availability and concurrency controls.

At [release line 95](.github/workflows/release.yml#L95), the production concurrency group is shared with [the rollback workflow](.github/workflows/rollback.yml#L28). `cancel-in-progress: false` avoids canceling an active rollout when another run arrives. This is serialization, not a promise of an unlimited FIFO release queue.

At [release line 106](.github/workflows/release.yml#L106):

```yaml
IMAGE: ${{ needs.build.outputs.image }}
```

The deploy job receives the exact digest reference from its build job.

Next, [Reject stale commits at line 118](.github/workflows/release.yml#L118) compares the run's commit with the current head of `main`. If a newer merge arrived during the approval wait, this run fails rather than releasing an older version. Approve the latest intended release instead.

[Azure login at line 129](.github/workflows/release.yml#L129) uses the production environment's deploy identity, then [line 134](.github/workflows/release.yml#L134) calls the deployment script.

### 9. Stage, verify, promote, and verify again

Open [the deployment script](samples/scripts/deploy.sh#L1). The YAML delegates the rollout mechanics to this script so release and optional demo deployment use the same logic.

| Source stop | What happens | Why it matters |
|---|---|---|
| [Line 3](samples/scripts/deploy.sh#L3) | Requires the inputs and validates the expected registry/repository and image digest shape. | Refuses missing inputs or an unexpected image reference. |
| [Line 7](samples/scripts/deploy.sh#L7) | Reads the app, requires multiple-revision mode, and requires one explicit existing revision at 100% traffic. | Establishes an unambiguous serving revision and rollback target. |
| [Line 19](samples/scripts/deploy.sh#L19) | Registers error handling that attempts to restore previous traffic if promotion has started. | A failed rollout remains a failure, even if traffic restoration succeeds. |
| [Line 34](samples/scripts/deploy.sh#L34) | Records the old revision, candidate revision, and image in the run summary. | Gives operators release evidence and a recovery reference. |
| [Line 36](samples/scripts/deploy.sh#L36) | Updates the app with the digest and a run-specific revision suffix. | Creates a candidate while the explicit traffic rule keeps the old revision serving. |
| [Line 39](samples/scripts/deploy.sh#L39) | Polls the candidate's health, up to 60 checks with five-second sleeps. | Requires platform-reported health before testing the candidate endpoint. |
| [Line 49](samples/scripts/deploy.sh#L49) | Gets the candidate hostname and smoke-tests it. | Checks the new revision directly before moving application traffic. |
| [Line 51](samples/scripts/deploy.sh#L51) | Marks promotion as started and moves 100% of traffic to the candidate. | Makes this verified revision the serving release. |
| [Line 54](samples/scripts/deploy.sh#L54) | Smoke-tests the app's normal hostname after the switch. | Verifies the user-facing routing path serves the expected commit. |

The [smoke-test script](samples/scripts/smoke.sh#L6) retries HTTPS requests to `/health`. It requires both `message == "Hello from ACA"` and `commit ==` the expected release SHA. A response from an old revision is not accepted merely because its HTTP status is 200.

If staging or candidate testing fails, the previous revision still has traffic. If an error occurs after promotion begins, the script attempts to restore the previous revision's 100% traffic rule and reports any restoration failure explicitly. Operators must verify recovery; this is not a guarantee of application-level correctness or automatic recovery from every failure.

### 10. Update the browser demo and show the result

At [release line 137](.github/workflows/release.yml#L137), the optional browser step runs only when `DEMO_DEPLOYMENT_ENABLED == 'true'`. It overrides the app name with `DEMO_ACA_APP` and calls the same deployment script, retaining the same image digest and expected commit.

The private deployment happens first. If the optional demo fails afterward, the workflow reports failure, but it does not undo the already successful private deployment. Review each app's state independently.

In the browser:

1. Refresh the demo homepage and show the changed paragraph.
2. Compare **Release commit** with the release workflow's commit.
3. Open **View application health** and show the matching JSON commit.
4. Return to the run summary to connect the commit, image digest, and promoted revision.

The commit is embedded by [the Dockerfile](samples/Dockerfile#L2), exposed by [the response function](samples/app/server.py#L7), and rendered by [the welcome page](samples/app/server.py#L11). The browser check confirms the visible message; the automated smoke test confirms health and commit identity. Neither should be presented as a full application acceptance suite.

### 11. Optional close: demonstrate the recovery path

For a separate recovery demonstration, open **Actions > Roll back to an existing revision**. Choose `private` or `demo`, supply a known earlier revision belonging to that app, and use the production approval process.

The [rollback workflow](.github/workflows/rollback.yml#L3) is manually triggered, uses the same production environment and concurrency group, and invokes [the rollback script](samples/scripts/rollback.sh). It restores an existing revision rather than rebuilding an old commit. Do not run this step during the normal forward-release demonstration unless rollback is part of the agreed scenario.

## Presentation checkpoints

| Show | Customer takeaway |
|---|---|
| Branch and PR diff | A small, reviewable change enters the delivery process. |
| Green PR checks | Proposed code is validated without private-network deployment access. |
| Release build and digest | Trusted automation publishes a specific, traceable image. |
| Waiting for production review | Build completion and permission to deploy are separate controls. |
| Candidate test and traffic promotion | The release is verified before and after the traffic switch. |
| Updated page and matching commit | The running result can be traced back to the approved release. |

For initial provisioning, identity configuration, network requirements, and teardown, use the [setup guide](README.md) and [POC instructions](poc/POC.md). This walkthrough explains the delivery demonstration; it does not replace the production readiness and operational review.
