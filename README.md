# Shared build automation

Cake Frosting build component for Neil Colvin's .NET clients, libraries, Crestron drivers and development tools. Component version: **1.0.0**. Consumers pin an immutable Git commit, not a moving branch. This project is build tooling and is not packed into product NuGet packages or driver packages.

GitHub Actions continues to own jobs, matrices, runner selection, permissions, approvals, resource reservations, validation reuse and publication locks. The component executes repository recipes and verifies declared test results. It does not deploy to processors, sign submissions, publish packages or grant approval to reuse validation.

## Calling a repository recipe

```powershell
./Invoke-Build.ps1 -Root C:/Projects/SomeClient -Task unit-tests
```

The caller installs .NET SDK 10 and uses the recipe's existing tool prerequisites. Script recipes additionally require their declared shell. The component itself is tested on Windows, Linux and macOS. Product frameworks and packaging tools may require Windows; runner selection remains in the calling workflow.

```yaml
- uses: oznetmaster/BuildAutomation@FULL_40_CHARACTER_COMMIT
  env:
    BUILD_FRAMEWORK: ${{ matrix.framework }}
  with:
    task: unit-tests
    # root: driver       # for repositories checked out into a subdirectory
```

## Recipe schema 1

Repository-owned `build/recipe.json` declares named tasks. Commands run in order, from the repository root, and stop on failure. Existing GitHub job dependencies continue to control cross-job ordering; recipes do not invent another scheduler or acquire processor reservations.

```json
{
  "schema": 1,
  "tasks": {
    "unit-tests": {
      "commands": [{
        "executable": "dotnet",
        "arguments": ["test", "Tests/Tests.csproj", "-c", "Release", "-f", "${env:BUILD_FRAMEWORK}", "--filter", "TestCategory!=Live", "--logger", "trx", "--results-directory", "TestResults"]
      }],
      "results": ["TestResults/*.trx"]
    }
  }
}
```

Arguments use `ProcessStartInfo.ArgumentList`; spaces and metacharacters remain argument data. `${env:NAME}` requires that environment input. Environment values and full argument lists are not written into receipts. Child output remains visible in the calling terminal/CI and retains normal GitHub masking.

For existing multi-command checks, a command can instead declare `executable`, `script` and `shell` (`pwsh` or `bash`). A repository script preserves the previous workflow command text and any explicit native-exit checks. PowerShell uses GitHub's Stop-on-error and LASTEXITCODE behavior; bash uses `-e -o pipefail`. Expression inputs are restricted to trusted matrix/workspace values during migration. Secrets and publication steps stay in the existing workflow.

Each command defaults to a 30-minute timeout, configurable from 1 to 120 minutes. Existing shorter GitHub job timeouts still apply. Paths for recipes, scripts and result directories must remain within the product repository. Receipts are written into a unique `artifacts/build-automation/<run>/receipt.json` directory, with the recipe hash, completed commands, timing and success/failure. Temporary expanded scripts are deleted after execution.

Declared result globs support `directory/*.trx` and `directory/**/*.trx`. Every declared glob must produce fresh results. Missing, stale, empty, failed, aborted or inconsistent results fail the task. Skipped tests are reported separately and are never counted as executed. Discovery-only commands must not declare execution results.

## Migration and release boundaries

1. Keep existing project paths, arguments, filters, framework matrices, job identifiers and artifact upload rules.
2. Replace build/test/package command steps with pinned calls. Keep specialized build/package scripts authoritative.
3. Compare recipe commands against the original workflow, then verify hosted CI and download results.
4. For the first driver, verify its merged assembly/package checks before migrating the remaining drivers.
5. Keep public publication workflows, approvals, locks, validation evidence and live processor orchestration intact. Migrate their build implementation only after separate equivalence verification.

No product release/version bump is needed for adopting this component. Updating a component pin requires review and CI validation; a mutable tag is insufficient.

## Component verification

```powershell
dotnet restore Tests/BuildAutomation.Tests.csproj --locked-mode
dotnet test Tests/BuildAutomation.Tests.csproj -c Release --no-restore
```

Dependency lock files include the patched PKCS 10.0.13 build-only dependency. Cake 6.3.0's older transitive version is not used. See [Cake reuse guidance](https://cakebuild.net/docs/writing-builds/reusing-builds).

The component has its own `Directory.Build.props`, `Directory.Build.targets` and NuGet source configuration. A local cache beneath a product repository therefore cannot inherit that product's build, packaging or deployment hooks.
