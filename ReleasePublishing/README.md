# Shared public library publication

Repository-owned GitHub workflows retain their filename, triggers, job permissions, protected environments, validation policy, publication lock and runner selection. Pinned composite actions share preparation, freezing and publication. Keeping the steps in the caller workflow preserves its NuGet Trusted Publishing identity. This component does not create or broaden a trust policy.

The normal path is:

1. Check out the exact workflow commit. Validate a canonical `MAJOR.MINOR.PATCH`, maintained project version, linked changelog, versioned notes, existing tag identity and unpublished package versions.
2. Run the existing shared validation policy. Explicit desktop/processor reuse inputs retain their evidence requirements; this component grants no test waiver.
3. Use Cake's `release-assets` recipe to run repository-specific prerequisites and the common local `Stage-Release.ps1`. The Cake bootstrap supplies `BUILD_AUTOMATION_COMPONENT_ROOT`; `RELEASE_VERSION` is the explicit caller input.
4. Verify all configured NuGet identities, versions, DLL/XML framework assets and README/release-note presence. Freeze the exact flat asset set, hashes, source commit and configuration hash. Retain it as a GitHub artifact before requesting publishing credentials.
5. A separate publication job downloads that artifact, verifies it, obtains a short-lived NuGet credential through the caller's existing trust policy, publishes the packages, uploads and verifies a GitHub draft, and only then publishes that draft.

The three composite actions live at `.github/actions/release-prepare`, `release-freeze` and `release-publish`. Every consumer must pin their reviewed full commit. The publication job needs `contents: write` and `id-token: write`; build jobs need only their existing read/check permissions. Locks remain repository-scoped, queued and non-cancelling. Other repositories and independent processors are not locked by this component.

## Configuration

`build/release.json` uses schema 1:

```json
{
  "schema": 1,
  "name": "ExampleClient",
  "versionFile": "Directory.Build.props",
  "versionXPath": "/Project/PropertyGroup/Version",
  "notesFile": "release-notes/v{version}.md",
  "packages": [
    { "id": "ExampleClient", "project": "src/ExampleClient/ExampleClient.csproj", "frameworks": ["net472", "net10.0"] }
  ],
  "applications": [],
  "documents": ["README.md", "CHANGELOG.md", "LICENSE"],
  "rawLibraries": false,
  "libraryArchive": false
}
```

The notes start with `# ExampleClient 1.2.3` and a non-empty explanation. A metapackage declares an empty framework list. Applications declare a repository-relative `project`, an artifact `name`, and an optional `framework`. Application output is framework dependent; the component does not install or bundle a runtime. `rawLibraries` extracts the DLL/XML bytes from the actual nupkg rather than selecting potentially stale build outputs. `libraryArchive` creates a library ZIP from those same packages. Optional `documentationArchive` names an already-validated HTML site; repository documentation recipes remain authoritative.

Common staging is local-only and refuses non-empty output directories. It never uses device pairings, creates tags, obtains credentials or publishes. It can be called directly for diagnostics, but normal local and CI usage is the same Cake `release-assets` task. Existing specialized package checks remain prerequisites/postchecks in the repository recipe.

## Interrupted publication

Use **Re-run failed jobs** on the original run. Do not rerun its successful build job. The publication job redownloads the exact retained artifact and revalidates it. An existing NuGet version is accepted only after comparing every logical ZIP payload entry with the frozen package; the repository signature is the only excluded entry. A different payload stops recovery. Existing GitHub assets must match their SHA-256 and size; missing draft assets may be added, but existing files are never overwritten or removed. A tag pointing to different source is never moved. A published release is never silently edited.

If the original artifact expired or was deleted, stop and recover the exact retained bytes/provenance before another attempt. A fresh build is not evidence that it reproduces already-published bytes. Do not use `--skip-duplicate` to conceal an ambiguous main-package upload. Symbol packages use that switch only after the main package has been submitted or its exact logical payload verified.

If the publishing implementation itself needs repair, the caller's recovery job accepts the original `artifact_run_id` and full `source_commit`. It skips the build, verifies the completed run belongs to the same repository and workflow and contains a successful build, checks out that original source, and downloads its retained artifact. The corrected shared publisher still checks every frozen byte and existing NuGet payload. Permissions include `actions: read` for this cross-run artifact lookup. The workflow execution revision may differ from the original build revision; the release tag and payload remain bound to the original build revision.

Protected environments continue to evaluate the **workflow execution ref**. Start normal releases or recovery from a ref allowed by the repository's existing rules. A tag-only environment may use an explicitly retained `v-publication-*` execution tag for a repaired workflow; that is an execution/provenance reference, not another product release version. Caller push triggers select numeric product-version tags, so creating this execution ref does not start another release. Do not change environment restrictions to make an unapproved branch eligible.

GitHub drafts are resolved by release ID. A newly created draft can have the requested `tag_name` before its physical Git tag exists; the publisher verifies its exact target commit, verifies an existing tag when present, and requires the final published tag to resolve to the original source. The regression fixture models this behavior and rejects attempts to look up a tagless draft through the published-release-by-tag endpoint.

`publication-receipt.json` records partial progress without credentials, allowing failures after NuGet publication to be reconciled. This does not promise transactional publication across GitHub and NuGet.

Run `./ReleasePublishing/Test-ReleasePublishing.ps1` for mocked package/hash, path, metadata, interrupted-upload, retry, mismatched-existing-version and secret-exclusion regressions. Tests use no real credentials or external mutations. The normal shared component CI runs them on Windows, Linux and macOS.
