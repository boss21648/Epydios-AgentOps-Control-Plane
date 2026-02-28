# Provenance and Lockfiles

This directory holds lightweight lockfiles that should be updated as components are pinned for deployment.

The goal is to start provenance tracking now and tighten enforcement later.

## Validation Gate

Run lockfile validation in development mode (structure and pin sanity, warnings for unresolved release data):

```bash
./platform/local/bin/verify-provenance-lockfiles.sh
```

Run strict release mode (blocking for unresolved required image digests and unverified required licenses):

```bash
STRICT=1 ./platform/local/bin/verify-provenance-lockfiles.sh
```

Use strict mode as the release gate after digests and license verification are fully populated.

Strict mode also rejects placeholder digests for release-synced image entries, including all-zero
SHA-256 values such as `sha256:000...000`.

Release image digests are produced by:

```bash
.github/workflows/release-images-ghcr.yml
```

The workflow emits:
- `release-image-digests.json`
- `release-image-digests.md`
- per-component signature/attestation verification artifacts in `release-digest-*` artifacts
- per-component SBOM (`*.sbom.spdx.json`) and vulnerability report (`*.trivy.json`) artifacts
- strict lockfile validation output by running `go run ./cmd/provenance-lock-check -strict -repo-root dist/repo-root` on the synced artifact before publish

These artifacts are the CI handoff for lockfile sync automation.

CI lockfile sync entrypoint:

```bash
./platform/ci/bin/sync-release-digests-to-lockfile.sh
```

Expected CI inputs:
- `DIGEST_MANIFEST` (for example `dist/release-image-digests.json`)
- `LOCKFILE` (target `images.lock.yaml` path)

This syncs component `tag` + immutable `digest` fields and stamps `status: release-synced`.

Auto-sync image digests from live cluster image IDs and (optionally) registry pulls:

```bash
./platform/local/bin/sync-provenance-image-digests.sh
```

Allow registry pulls for unresolved tags:

```bash
ALLOW_DOCKER_PULL=1 ./platform/local/bin/sync-provenance-image-digests.sh
```

## Files

- `charts.lock.yaml` Helm/OCI chart versions
- `images.lock.yaml` image tags and digests
- `crds.lock.yaml` CRD source/version references
- `licenses.lock.yaml` license expectations and verification status
- `aimxs/` private AIMXS publication evidence for M10.2 (tag + digest evidence + staging strict proof)

## Relationship to Workspace-Level Provenance

The workspace root also contains:

- `../provenance/third_party_sources.yaml`

That file tracks local upstream source clones and zip backups. These repo-local lockfiles track what the control plane actually deploys.

## Filling Image Digests

Use `images.lock.yaml` as the source of truth for image tags first, then fill `digest` values after the image is pushed.

Example flow (per image):

```bash
IMAGE=ghcr.io/epydios/epydios-extension-provider-registry-controller
TAG=0.1.0
crane digest "${IMAGE}:${TAG}"
```

Alternative with Docker Buildx:

```bash
docker buildx imagetools inspect "${IMAGE}:${TAG}" --format '{{json .Manifest.Digest}}'
```

Update the corresponding `digest: sha256:...` entry in `images.lock.yaml` only after verifying the tag matches the intended build commit.
