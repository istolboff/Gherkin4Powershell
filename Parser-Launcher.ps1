param ([string] $scenarioFiles, $parsingLogFile)

$scriptFolder = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path -Path $scriptFolder -ChildPath 'Define-GherkinHooksApi.ps1')

Remove-Variable -Name GherkinHooksDictionary03C98485EFD84C888750187736C181A7 -Scope Global -ErrorAction SilentlyContinue
Remove-Variable -Name GherkinStepDefinitionDictionary03C98485EFD84C888750187736C181A7 -Scope Global -ErrorAction SilentlyContinue

Given ([regex]'(.*)') {
    param ($scenarioLine)
    Write-Host "Given: $scenarioLine"
}

When ([regex]'(.*)') {
    param ($scenarioLine)
    Write-Host "When: $scenarioLine"
}

Then ([regex]'(.*)') {
    param ($scenarioLine)
    Write-Host "Then: $scenarioLine"
}

$parsedScenarios = & $(Join-Path -Path $scriptFolder -ChildPath 'Run-GherkinScenarios.ps1') `
                        -scenarioFiles $scenarioFiles `
                        -logParsingToFile $parsingLogFile
