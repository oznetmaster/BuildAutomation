# Public library symbols

Every maintained public binary library/client package produces portable PDBs and a separate `.snupkg` from the same optimized Release build as its `.nupkg`. Publish both files on GitHub and publish the symbols to NuGet's symbol server. Symbols are optional downloads for consumers and do not enable runtime diagnostic logging.

Copy `LibrarySymbols.props` to the consumer's `build` directory and import it last in each published binary library project. Keeping this small file in the checkout preserves normal clone and IDE builds without downloading build tooling. The shared validator and regression tests enforce the policy. The props enable the SDK's repository metadata/Source Link integration; no runtime dependency is added.

The shared release configuration marks binary packages with `"symbols": true`. It verifies the DLL/portable-PDB GUID and stamp for every framework, package identity/version/type, exact PDB coverage, allowed content and safe archive paths. Missing, nonportable or mismatched symbols stop publication. Metapackages containing no DLLs have nothing to symbolize.

Older publication wrappers use the pinned `.github/actions/library-symbols` action before requesting publishing credentials, retain both artifact types, push the main package with `--no-symbols`, then call that action with `publish: true` and the caller's short-lived NuGet key. No trust-policy, environment, runtime, public version or existing release change is needed.

Run `./LibrarySymbols/Test-LibrarySymbols.ps1` for real compiled DLL/PDB fixture checks. `./ReleasePublishing/Test-ReleasePublishing.ps1` also verifies that a required symbol package cannot disappear from release preparation. Actual consumer package validation remains necessary when rolling out this policy.
