#requires -Version 5.1
<#
.SYNOPSIS
    Parses, analyzes, and tests the launcher without starting Chrome.
.DESCRIPTION
    Requires Pester 5.7.1 and PSScriptAnalyzer. Installs nothing automatically.
    Run from a fresh Windows PowerShell 5.1 or PowerShell 7 session.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$source = Join-Path -Path $PSScriptRoot -ChildPath 'chrome.ps1'
$testFile = Join-Path -Path $PSScriptRoot -ChildPath 'tests\Chrome.Tests.ps1'
foreach ($file in @($source, $testFile, $PSCommandPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Parse failure in '$file': $($errors | Out-String)" }
}
if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -eq [version]'5.7.1' })) {
    throw 'Install the test dependency first: Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser'
}
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    throw 'Install the analyzer first: Install-Module PSScriptAnalyzer -Scope CurrentUser'
}
Import-Module -Name PSScriptAnalyzer -ErrorAction Stop
$findings = @(Invoke-ScriptAnalyzer -Path $source -Settings (Join-Path -Path $PSScriptRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'))
if ($findings.Count -gt 0) {
    $findings | Format-Table -AutoSize | Out-Host
    throw 'Static analysis reported warnings or errors. Resolve them before production use.'
}
Import-Module -Name Pester -RequiredVersion 5.7.1 -ErrorAction Stop
$configuration = New-PesterConfiguration
$configuration.Run.Path = $testFile
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { throw 'One or more automated tests failed.' }
Write-Information -MessageData ("Validation passed: {0} tests passed, {1} skipped." -f $result.PassedCount, $result.SkippedCount) -InformationAction Continue
