# Sanitized Installer Implementation Plan

This task board defines how to deliver a customer installer bundle without exposing
private source code. Implementation work happens in the private engineering repo;
this public repo tracks customer-visible process and release readiness only.

## Objective

Produce and publish a signed installer artifact that supports full deployment:

`CTRL1 -> CTRL2 -> BRAIN1 -> BRAIN2 -> EDGE1 -> EDGE2`

while shipping no private source trees.

## Phase 1 - Bundle Contract Definition

- [ ] Define bundle v2 layout (`images/`, `bin/`, `ansible/`, `scripts/`, `docs/`)
- [ ] Define artifact manifest format (`bundle-manifest.json` with SHA256)
- [ ] Define strict deny-list (`src/`, internal CI, vault files, private keys)
- [ ] Define acceptance checks for sanitized bundle

Deliverables:
- public-facing bundle contract doc update
- release checklist draft

## Phase 2 - Private Repo Refactor (No Public Source Exposure)

- [ ] Replace source-sync deployment paths with prebuilt artifact consumption
- [ ] Refactor node bootstrap flow to require artifacts, not source checkout
- [ ] Ensure all node roles work from packaged binaries/images only
- [ ] Add fail-fast checks when required artifacts are missing

Validation gates:
- [ ] clean-room deployment test on fresh VMs
- [ ] no `src/` required during deployment

## Phase 3 - Build/Release Pipeline

- [ ] Build images/binaries in private CI
- [ ] Assemble sanitized installer tarball
- [ ] Generate `CHECKSUM.sha256`
- [ ] Sign release (`SIGNATURE.asc`)
- [ ] Verify signature/checksum in CI before publish

## Phase 4 - Public Release Publication

- [ ] Publish installer assets to public Releases:
  - [ ] `aetheria-<version>-installer.tar.gz`
  - [ ] `aetheria-<version>-installer.tar.gz.sha256`
  - [ ] `aetheria-<version>-installer.tar.gz.asc`
- [ ] Confirm `deploy-cluster.sh` auto-download resolves latest release asset
- [ ] Update public docs with version-specific example commands

## Phase 5 - Compliance & Safety Audit (Per Release)

- [ ] Run public repo safety audit (file inventory + sensitive pattern scan)
- [ ] Verify CI guard is enabled and passing
- [ ] Verify no private implementation files in public repo
- [ ] Log publication and audit result in MCP Sentinel

## Ownership

- Private implementation work: private repo maintainers only
- Public publication/docs/audit: public bootstrap repo maintainers

## Exit Criteria

All boxes above complete, latest public release assets downloadable, and full
6-node deployment succeeds using only public bootstrap repo + released installer.
