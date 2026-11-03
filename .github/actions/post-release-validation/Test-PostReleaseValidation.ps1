# Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
$ErrorActionPreference='Stop'
$repository=$env:GITHUB_REPOSITORY
$checks=0
try {
    $env:GITHUB_REPOSITORY='owner/product'
    $global:PostReleaseFixtureState=@{Revision=('a'*40);Scenario='';Dispatched=$null}
    function gh {
        $global:LASTEXITCODE=0
        $argsText=$args -join ' '
        if ($args[0] -eq 'workflow') {
            $global:PostReleaseFixtureState.Dispatched.Add([string]$args[2])
            if($global:PostReleaseFixtureState.Scenario -eq 'dispatch-failure'){$global:LASTEXITCODE=1}
            return
        }
        if ($args[1] -eq 'repos/owner/product') {
            if($global:PostReleaseFixtureState.Scenario -eq 'missing-branch'){return ''}
            return 'main'
        }
        if ($args[1] -eq 'repos/owner/product/commits/main') {
            if($global:PostReleaseFixtureState.Scenario -eq 'bad-sha'){return 'not-a-revision'}
            return $global:PostReleaseFixtureState.Revision
        }
        if ($argsText -like '*actions/workflows/*') {
            if($global:PostReleaseFixtureState.Scenario -eq 'api-failure'){$global:LASTEXITCODE=1;return '{}'}
            $runs=@()
            if($global:PostReleaseFixtureState.Scenario -in @('running','success','failed','foreign','old-sha','unsupported-event','pagination')) {
                $runs=@(@{id=3;head_sha=$global:PostReleaseFixtureState.Revision;head_repository=@{full_name='owner/product'};event='push';status='completed';conclusion='success'})
                switch($global:PostReleaseFixtureState.Scenario){
                    'running' {$runs[0].status='in_progress';$runs[0].conclusion=$null}
                    'failed' {$runs[0].conclusion='failure'}
                    'foreign' {$runs[0].head_repository.full_name='other/product'}
                    'old-sha' {$runs[0].head_sha='b'*40}
                    'unsupported-event' {$runs[0].event='schedule'}
                }
            }
            $pages=if($global:PostReleaseFixtureState.Scenario -eq 'pagination'){@(@{workflow_runs=@()},@{workflow_runs=$runs})}else{@(@{workflow_runs=$runs})}
            return ConvertTo-Json -InputObject $pages -Depth 8 -Compress
        }
        throw 'Unexpected GitHub invocation in regression fixture.'
    }
    function Check([string]$Scenario,[int]$ExpectedDispatches,[bool]$Reject=$false,[string]$Workflows='["tests.yml"]') {
        $global:PostReleaseFixtureState.Scenario=$Scenario
        $global:PostReleaseFixtureState.Dispatched=[Collections.Generic.List[string]]::new()
        $failed=$false
        $failureMessage=''
        try { & "$PSScriptRoot/Invoke-PostReleaseValidation.ps1" -Workflows $Workflows } catch {$failed=$true;$failureMessage=$_.Exception.Message}
        if($failed -ne $Reject -or $global:PostReleaseFixtureState.Dispatched.Count -ne $ExpectedDispatches){throw "Unexpected dispatcher outcome for ${Scenario}: $failureMessage"}
        $script:checks++
    }
    Check 'none' 1
    Check 'running' 0
    Check 'success' 0
    Check 'failed' 1
    Check 'foreign' 1
    Check 'old-sha' 1
    Check 'unsupported-event' 1
    Check 'pagination' 0
    Check 'missing-branch' 0 $true
    Check 'bad-sha' 0 $true
    Check 'api-failure' 0 $true
    Check 'dispatch-failure' 1 $true
    Check 'none' 0 $true '[]'
    Check 'none' 0 $true '["../tests.yml"]'
    Check 'none' 0 $true '["tests.yml","tests.yml"]'
    Check 'none' 2 $false '["tests.yml","discovery.yml"]'
    Write-Host "Passed $checks post-release dispatcher regression cases; no network calls were made."
} finally {
    $env:GITHUB_REPOSITORY=$repository
    Remove-Item Function:gh -ErrorAction SilentlyContinue
    Remove-Variable PostReleaseFixtureState -Scope Global -ErrorAction SilentlyContinue
}
