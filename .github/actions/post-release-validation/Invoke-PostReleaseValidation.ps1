# Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Workflows)
$ErrorActionPreference='Stop'
if ($env:GITHUB_REPOSITORY -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid repository identity.' }
$selected=@(ConvertFrom-Json -InputObject $Workflows)
if (!$selected.Count -or @($selected | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^[A-Za-z0-9_.-]+\.ya?ml$' }).Count -or @($selected | Sort-Object -Unique).Count -ne $selected.Count) { throw 'Use a nonempty, unique list of workflow filenames.' }
$branch=gh api "repos/$env:GITHUB_REPOSITORY" --jq .default_branch
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) { throw 'Cannot resolve the default branch.' }
$revision=gh api "repos/$env:GITHUB_REPOSITORY/commits/$branch" --jq .sha
if ($LASTEXITCODE -ne 0 -or $revision -cnotmatch '^[0-9a-f]{40}$') { throw 'Cannot resolve the default-branch revision.' }
foreach ($workflow in $selected) {
    $json=gh api "repos/$env:GITHUB_REPOSITORY/actions/workflows/$workflow/runs?head_sha=$revision&per_page=100" --paginate --slurp
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect existing default-branch validation.' }
    $pages=ConvertFrom-Json -InputObject ($json | Out-String)
    $existing=@($pages | ForEach-Object { $_.workflow_runs } | Where-Object {
        $_.head_sha -ceq $revision -and $_.head_repository.full_name -ceq $env:GITHUB_REPOSITORY -and
        $_.event -in @('push','pull_request','workflow_dispatch')
    } | Sort-Object id -Descending)[0]
    if ($existing -and ($existing.status -ne 'completed' -or $existing.conclusion -eq 'success')) {
        Write-Output "Existing validation for $revision is $($existing.status)/$($existing.conclusion); no duplicate run is needed."
        continue
    }
    gh workflow run $workflow -R $env:GITHUB_REPOSITORY --ref $branch
    if ($LASTEXITCODE -ne 0) { throw 'Post-release validation dispatch failed.' }
}
