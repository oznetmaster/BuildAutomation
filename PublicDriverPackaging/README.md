# Public driver packaging

Crestron submission help PDFs belong only in separately prepared Crestron submission packages. Public driver `.pkg` files, NuGet wrappers, documentation ZIPs and other public downloads must not include them. Public documentation is the repository README and normal public documentation.

Driver projects filter PDF entries from `IncludeInPkgFiles` before staging resources for ManifestUtil. The source help PDF can remain in the repository for submission preparation. Release workflows run `Assert-PublicDriverArtifacts.ps1` against the actual assets before any publication; the guard inspects nested `.pkg`, `.nupkg`, `.snupkg` and `.zip` archives. It fails on PDFs, unreadable archives, missing paths and an empty asset selection.

The two scripts in this directory are distributed byte-for-byte into each driver's `tools` directory. `build/public-driver-packaging.json` records the shared source commit and file hashes so a later task can update them consistently. Keep the local scripts available to ordinary clones; release checks must not depend on a sibling checkout.

Run the regression suite with:

```powershell
pwsh -File PublicDriverPackaging/Test-PublicDriverArtifacts.ps1
```

For a Crestron submission, prepare a separate copy of the frozen public package with the maintained DevTools `submission package-help` command and a pinned help profile. Add the required PDF and submission metadata there, then compare all entries: runtime DLL, UI resources, translations and other runtime bytes must remain unchanged. Run the submission-specific validator, review/signing and approval steps. Never rebuild or silently replace an already published package to add submission material.

Existing GitHub/NuGet releases and prior submission receipts remain immutable. This policy applies to future public artifacts; it does not rewrite historical assets or change their recorded hashes. Processor test-package documentation remains normal public documentation and is permitted when it contains no submission PDF.
