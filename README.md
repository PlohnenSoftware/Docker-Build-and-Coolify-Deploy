# Docker Build and Coolify Deploy

[![Test](https://github.com/PlohnenSoftware/Docker-Build-and-Coolify-Deploy/actions/workflows/test.yml/badge.svg)](https://github.com/PlohnenSoftware/Docker-Build-and-Coolify-Deploy/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Build a Docker image in GitHub Actions, push it to a registry, and tell
[Coolify](https://coolify.io) to pull it — so nothing is ever compiled on the
server.

```
git push main ── build ──> ghcr.io/your-org/your-app:latest
                              │
              webhook ──> Coolify: docker pull ──> redeploy
```

- **Nothing builds on the VPS.** Your `docker-compose.yml` carries an `image:`
  and no `build:`, so a deploy is a pull and a restart.
- **No attestation manifests.** `provenance` and `sbom` default to off, because
  the extra entries they add to the image index are what makes a Coolify pull
  fail.
- **`force=true` is added for you.** Without it Coolify can answer `200` and
  still leave the old container running, because the tag it points at has not
  changed name.
- **A webhook that never connects fails the job**, instead of passing quietly on
  an HTTP status of `000`.

```yaml
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write # required: this is what lets the push to GHCR succeed
    steps:
      - uses: actions/checkout@v7.0.1
      - uses: PlohnenSoftware/Docker-Build-and-Coolify-Deploy@v2
        with:
          image: your-org/your-app
          coolify_webhook_url: ${{ vars.COOLIFY_WEBHOOK_URL }}
          coolify_token: ${{ secrets.COOLIFY_TOKEN }}
```

That is the whole thing. The registry defaults to `ghcr.io`, the credentials
default to the token GitHub already gives the job, and the redeploy fires only
when an image was actually pushed.

---

## Usage

Every example below is **synthetic** — image names, hosts and URLs are
placeholders. Swap in your own.

### What the action does, in order

1. **Resolves the settings.** Lowercases the image name, decides whether this
   run pushes, logs in, needs QEMU and redeploys.
2. **Sets up QEMU**, only when `platforms` names an architecture the runner is
   not.
3. **Sets up Buildx.**
4. **Logs in to the registry**, only when the image is being pushed.
5. **Extracts tags and labels** with [`docker/metadata-action`][meta].
6. **Builds, and pushes** with [`docker/build-push-action`][bp].
7. **Triggers the Coolify webhook**, only when the image was pushed and both
   Coolify inputs are set.
8. **Writes a job summary** with the image, digest, tags and deploy result.

It does **not** check out your repository and it does **not** run your tests.
Both belong to the calling workflow — see below.

[meta]: https://github.com/docker/metadata-action
[bp]: https://github.com/docker/build-push-action

### Gate the image on your test suite

A published tag can be pulled at any time, so nothing known-broken should ever
reach one. Keep the test job in your own workflow, where it can be written in
whatever your project actually uses, and depend on it:

```yaml
name: Docker publish

on:
  push:
    branches: ["main"]
  workflow_dispatch:

concurrency:
  group: docker-publish-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7.0.1
      - uses: actions/setup-go@v7.0.0
        with:
          go-version-file: go.mod
          cache: true
      - run: go vet ./...
      - run: go test ./...

  publish:
    needs: test
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v7.0.1
      - uses: PlohnenSoftware/Docker-Build-and-Coolify-Deploy@v2
        with:
          image: your-org/your-service
          coolify_webhook_url: ${{ vars.COOLIFY_WEBHOOK_URL }}
          coolify_token: ${{ secrets.COOLIFY_TOKEN }}
```

### Checking out something unusual

The checkout is yours, so anything it needs stays in your hands — submodules,
LFS, a deeper history:

```yaml
      - uses: actions/checkout@v7.0.1
        with:
          # A font or theme submodule the Dockerfile reads during the build.
          # Public submodules over https need nothing beyond GITHUB_TOKEN.
          submodules: recursive
```

### Building on pull requests without publishing

`push` defaults to `auto`, which means *push on everything except a
`pull_request` event*. Add `pull_request` to your triggers and a PR builds as a
check that can never overwrite a tag the server may pull:

```yaml
on:
  push:
    branches: ["main"]
  pull_request:
```

No further configuration. On a PR the action skips the registry login, builds
only, and skips the redeploy.

### Several images from one repository

Build them as a matrix, then redeploy **once** in a job of its own:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    strategy:
      fail-fast: false
      matrix:
        include:
          - image: your-org/app-api
            context: ./backend
            file: ./backend/Dockerfile
          - image: your-org/app-frontend
            context: .
            file: ./Dockerfile.frontend
    steps:
      - uses: actions/checkout@v7.0.1
      - uses: PlohnenSoftware/Docker-Build-and-Coolify-Deploy@v2
        with:
          image: ${{ matrix.image }}
          context: ${{ matrix.context }}
          file: ${{ matrix.file }}
          # No Coolify inputs here on purpose.

  deploy:
    needs: build
    if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: PlohnenSoftware/Docker-Build-and-Coolify-Deploy/coolify-deploy@v2
        with:
          webhook_url: ${{ vars.COOLIFY_WEBHOOK_URL }}
          token: ${{ secrets.COOLIFY_TOKEN }}
```

Triggering from inside the matrix instead would fire the webhook once per leg
and start concurrent deploys of a half-published set of images. The
`coolify-deploy` sub-action exists for exactly this: it is the trigger on its
own, with no build attached.

The cache is namespaced per image automatically (`cache_scope` defaults to the
last path segment of `image`), so two legs cannot overwrite each other's entry
and leave neither with a hit.

### Tags

The default rules cover the normal cases:

```
type=ref,event=branch                          # main
type=ref,event=pr                              # pr-42
type=semver,pattern={{version}}                # 1.4.0, from a v1.4.0 tag
type=sha,format=long                           # sha-9f8e7d6…
type=raw,value=latest,enable={{is_default_branch}}
```

Point Coolify at whichever of those you prefer to track — `latest`, the branch
name, or a pinned `sha-…` if you would rather promote deliberately. Override
the whole set with `tags:`, which is passed through to `docker/metadata-action`
verbatim:

```yaml
        with:
          image: your-org/your-app
          tags: |
            type=raw,value=stable
            type=sha,format=long
```

### Build arguments, and why runtime environment variables are not enough

Anything a framework inlines at build time — `NEXT_PUBLIC_*`, `VITE_*` — must
be present while the image is built. Setting it in Coolify afterwards is too
late: the value is already baked into the JavaScript bundle, or missing from it.

```yaml
        with:
          image: your-org/your-site
          build_args: |
            NEXT_PUBLIC_SERVER_URL=${{ vars.NEXT_PUBLIC_SERVER_URL }}
            NEXT_PUBLIC_APP_SLUG=${{ vars.NEXT_PUBLIC_APP_SLUG }}
```

Repository **variables**, not secrets, for values like these: they end up in a
public bundle either way, and an unmasked log is easier to debug.

For values that must *not* end up in the image, use `build_secrets`, which maps
to BuildKit secrets:

```yaml
        with:
          build_secrets: |
            npm_token=${{ secrets.NPM_TOKEN }}
```

```dockerfile
RUN --mount=type=secret,id=npm_token \
    NPM_TOKEN="$(cat /run/secrets/npm_token)" pnpm install --frozen-lockfile
```

### Caching

`cache: gha` (the default) uses the GitHub cache service. On a self-hosted
runner that service may be unreachable; `cache: registry` stores the cache as
`<image>:buildcache` instead, and needs no extra setup beyond the registry
login the action already does:

```yaml
        with:
          cache: registry
```

`cache: none` turns it off. `cache_from` / `cache_to` take raw Buildx values if
you need something else entirely.

### Multi-architecture images

```yaml
        with:
          platforms: linux/amd64,linux/arm64
```

QEMU is installed automatically, because the requested list names something the
runner is not. A plain multi-architecture index is fine for Coolify to pull —
it is *attestation* manifests, not architectures, that break it.

### Why `provenance` and `sbom` default to off

A build with attestations enabled pushes an image index containing extra
manifests alongside the real ones. Coolify's `docker pull` / `docker compose
pull` does not expect them and the deploy fails, usually with an unhelpful
manifest error. Keeping both off makes the pushed artifact a plain image.

Turn them back on if whatever pulls the image copes with them:

```yaml
        with:
          provenance: true
          sbom: true
```

### The Coolify trigger

```yaml
        with:
          coolify_webhook_url: ${{ vars.COOLIFY_WEBHOOK_URL }}
          coolify_token: ${{ secrets.COOLIFY_TOKEN }}
```

Leave both out and the action just builds and pushes; nothing is called.

**Every call is a POST.** Coolify's deploy webhook used to accept `GET` as
well and now answers it with a wrong-method error, so there is nothing to
choose and no input for it.

**`force=true` is appended for you.** Coolify compares the tag it is configured
with against what is running, and a mutable tag like `latest` or `main` has not
changed name even though the digest behind it has. Without the force flag the
webhook can return `200` while the old container keeps running — the single most
confusing way for this to go wrong. If your URL already carries a `force`
parameter, yours wins. `coolify_force: false` turns the behaviour off.

**The URL can be a variable rather than a secret.** It does nothing without the
token, and leaving it unmasked means a failed call shows the real address in the
log instead of `***`. The token is a secret.

On a GitHub Free organisation, put the token in the **repository** secrets, not
the organisation's: org-level secrets are not available to private repos on that
plan and resolve to an empty string in silence. The action warns when exactly
one of the two inputs is set, which is what that failure looks like.

**Failures are reported with the body.** Coolify answers a bad UUID, a token
scoped to another team and a missing permission all with a bare `404`, and only
the response body says which — so the body is printed rather than discarded.
Connection failures, `429` and `5xx` are retried (`coolify_retries`, default
`2`); a `4xx` is a real answer and is never retried.

### Input reference

| Input | Default | Description |
|---|---|---|
| `image` | *(required)* | Image repository without the registry. Lowercased for you. |
| `registry` | `ghcr.io` | Registry host. Empty means Docker Hub. |
| `username` | `${{ github.actor }}` | Registry username. |
| `password` | `${{ github.token }}` | Registry password or token. |
| `login` | `auto` | Log in: `true`, `false`, or only when pushing. |
| `context` | `.` | Build context path. |
| `file` | *(empty)* | Dockerfile path. Empty means `<context>/Dockerfile`. |
| `target` | *(empty)* | Dockerfile stage to build. |
| `build_args` | *(empty)* | `KEY=value` per line. |
| `build_secrets` | *(empty)* | `KEY=value` per line, as BuildKit secrets. |
| `platforms` | *(empty)* | e.g. `linux/amd64,linux/arm64`. |
| `qemu` | `auto` | Install QEMU: `true`, `false`, or only when cross-building. |
| `push` | `auto` | Push: `true`, `false`, or on every event but `pull_request`. |
| `provenance` | `false` | Provenance attestation. Off — Coolify trips over it. |
| `sbom` | `false` | SBOM attestation. Off, same reason. |
| `tags` | *(see above)* | Tag rules for `docker/metadata-action`. |
| `flavor` | *(empty)* | Flavor rules, e.g. `suffix=-alpine`. |
| `labels` | *(empty)* | Extra labels, on top of the generated OCI ones. |
| `cache` | `gha` | `gha`, `registry` or `none`. |
| `cache_scope` | last segment of `image` | Cache key namespace. |
| `cache_from` | *(empty)* | Raw override. |
| `cache_to` | *(empty)* | Raw override. |
| `coolify_webhook_url` | *(empty)* | Deploy Webhook URL. Empty skips the trigger. |
| `coolify_token` | *(empty)* | Coolify API token. |
| `coolify_force` | `true` | Append `force=true` unless the URL already sets it. |
| `coolify_retries` | `2` | Extra attempts on a connection failure, `429` or `5xx`. |
| `deploy` | `auto` | Trigger: `true`, `false`, or when pushed and configured. |

### Output reference

| Output | Description |
|---|---|
| `image` | Fully qualified image name, lowercased, without a tag. |
| `tags` | Newline-separated list of tags that were built. |
| `version` | Primary version `docker/metadata-action` derived. |
| `digest` | Digest of the built image. |
| `pushed` | `true` if the image was pushed. |
| `deploy_status` | `success`, `failed` or `skipped`. |

### `coolify-deploy` reference

`PlohnenSoftware/Docker-Build-and-Coolify-Deploy/coolify-deploy@v2` — the webhook on its
own, for a job that redeploys after several images have been published.

| Input | Default | Description |
|---|---|---|
| `webhook_url` | *(required)* | Deploy Webhook URL. |
| `token` | *(required)* | Coolify API token. |
| `force` | `true` | Append `force=true` unless the URL already sets it. |
| `retries` | `2` | Extra attempts on a connection failure, `429` or `5xx`. |
| `fail_on_error` | `true` | Fail the step when the redeploy is not accepted. |

| Output | Description |
|---|---|
| `status` | HTTP status of the last attempt, `000` if Coolify was never reached. |
| `outcome` | `success` or `failed`. |

---

## Setup

Three unrelated sets of credentials, in three places. Only the third is
something this action asks you for.

### 1. The push, from Actions to the registry

Nothing to create. `permissions: packages: write` on the job is what makes the
default `${{ github.token }}` able to push to GHCR:

```yaml
    permissions:
      contents: read
      packages: write
```

For a registry that is not GHCR, set `registry`, `username` and `password`
yourself.

### 2. The pull, from the server to the registry

A **private** package needs the Docker daemon on your host to be logged in.
Create a classic personal access token with `read:packages` only, then, once, as
the user the daemon runs as:

```console
$ docker login ghcr.io -u <your-github-username>
```

This is not a repository secret and it is not rotated by the workflow. Skip it
entirely by making the package public.

Then point the Coolify resource at the image and remove any `build:` stanza:

```yaml
services:
  app:
    image: ghcr.io/your-org/your-app:latest
```

### 3. The redeploy webhook

In Coolify, open the resource → **Webhooks** → copy the **Deploy Webhook** URL,
and create an API token under **Keys & Tokens → API tokens** with permission to
deploy. Then, in the GitHub repository:

- **Settings → Secrets and variables → Actions → Variables**:
  `COOLIFY_WEBHOOK_URL`
- **Settings → Secrets and variables → Actions → Secrets**: `COOLIFY_TOKEN`

Check it by hand before wiring it up:

```console
$ curl -i -X POST -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_WEBHOOK_URL&force=true"
```

## Requirements

- A Linux runner with Docker — the GitHub-hosted `ubuntu-*` images qualify.
  `bash`, `curl` and `python3` are all already present there.
- A Dockerfile that builds without the server's help.
- Coolify only for the redeploy step; the build and push work without it.

## Contributing

`.github/workflows/test.yml` runs the action against `test/fixture` and the
webhook against a local stub, so the whole path is covered without a registry or
a Coolify instance.

Releasing is a tag push:

```console
$ git tag -a v2.0.1 -m v2.0.1 && git push origin v2.0.1
```

`.github/workflows/release.yml` then refuses to go on unless the self-test is
green on that commit, force-moves `v2` to it, and creates the GitHub release.
Consumers pin to the moving major tag, so a bad release breaks all of them at
once — which is what that gate is for.

## License

MIT — see [LICENSE](LICENSE).
