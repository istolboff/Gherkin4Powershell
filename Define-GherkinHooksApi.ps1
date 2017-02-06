#region Miscellaneous
function Define-Enumeration
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True, Position=0)]
        [string][ValidateNotNullOrEmpty()]$enumTypeName,
 
        [Parameter(Mandatory=$true, Position=1)]
        [char][ValidateSet('=')]$link,
 
        [Parameter(Mandatory=$true, Position=2)]
        [array][ValidateNotNullOrEmpty()]$enumMemberNames)
 
	$enumMembers = @{}
	foreach ($enumMemberName in $enumMemberNames)
	{
		$enumMembers.Add($enumMemberName, "[$enumTypeName]::$enumMemberName")
	}
	
    Set-Variable -Name $enumTypeName -Value $enumMembers -Option Constant -Scope script -Force
}
Set-Alias enum Define-Enumeration
#endregion

#region Enumeartions
enum StepTypeEnum = Given, When, Then
#endregion

#region Hook setters
function Add-GherkinHook($hookType, [scriptblock] $hookScript)
{
    if (-Not (Test-Path variable:global:GherkinHooksDictionary03C98485EFD84C888750187736C181A7))
    {
        Set-Variable -Name GherkinHooksDictionary03C98485EFD84C888750187736C181A7 -Scope Global -Value @{}
    }

    $hooksDictionary = Get-Variable -Name GherkinHooksDictionary03C98485EFD84C888750187736C181A7 -Scope Global -ValueOnly

    if (-Not ($hooksDictionary.Contains($hookType)))
    {
        $newArrayList = New-Object System.Collections.ArrayList
        $hooksDictionary.Add($hookType, $newArrayList)
    }

    $allHooksOfType = $hooksDictionary.Item($hookType)
    $allHooksOfType.Add($hookScript) | Out-Null
}

function BeforeTestRun([scriptblock] $hookScript)
{
    Add-GherkinHook SetupTestRun $hookScript
}

function AfterTestRun([scriptblock] $hookScript)
{
    Add-GherkinHook TeardownTestRun $hookScript
}

function BeforeFeature([scriptblock] $hookScript)
{
    Add-GherkinHook SetupFeature $hookScript
}

function AfterFeature([scriptblock] $hookScript)
{
    Add-GherkinHook TeardownFeature $hookScript
}

function BeforeScenario([scriptblock] $hookScript)
{
    Add-GherkinHook SetupScenario $hookScript
}

function AfterScenario([scriptblock] $hookScript)
{
    Add-GherkinHook TeardownScenario $hookScript
}

function BeforeScenarioBlock([scriptblock] $hookScript)
{
    Add-GherkinHook SetupScenarioBlock $hookScript
}

function AfterScenarioBlock([scriptblock] $hookScript)
{
    Add-GherkinHook TeardownScenarioBlock $hookScript
}

function BeforeStep([scriptblock] $hookScript)
{
    Add-GherkinHook SetupScenarioStep $hookScript
}

function AfterStep([scriptblock] $hookScript)
{
    Add-GherkinHook TeardownScenarioStep $hookScript
}
#endregion

#region Step definitions
function Add-GherkinStepDefinition($stepType, [regex]$stepPattern, [scriptblock]$stepScript)
{
    if (-Not (Test-Path variable:global:GherkinStepDefinitionDictionary03C98485EFD84C888750187736C181A7))
    {
        Set-Variable `
            -Name GherkinStepDefinitionDictionary03C98485EFD84C888750187736C181A7 `
            -Scope Global `
            -Value @{ 
                "$($StepTypeEnum.Given)" = (New-Object System.Collections.ArrayList); 
                "$($StepTypeEnum.When)" = (New-Object System.Collections.ArrayList); 
                "$($StepTypeEnum.Then)" = (New-Object System.Collections.ArrayList)
            }
    }

    $stepDefinitionDictionary = Get-Variable -Name GherkinStepDefinitionDictionary03C98485EFD84C888750187736C181A7 -Scope Global -ValueOnly
    $allStepDefinitionsOfType = $stepDefinitionDictionary.Item($stepType)
    $allStepDefinitionsOfType.Add(@{ StepPattern = $stepPattern; StepScript = $stepScript }) | Out-Null
}

function Given_([regex]$stepPattern, [scriptblock] $stepScript)
{
    Add-GherkinStepDefinition -stepType $StepTypeEnum.Given -stepPattern $stepPattern -stepScript $stepScript
}

function When_([regex]$stepPattern, [scriptblock] $stepScript)
{
    Add-GherkinStepDefinition -stepType $StepTypeEnum.When -stepPattern $stepPattern -stepScript $stepScript
}

function Then_([regex]$stepPattern, [scriptblock] $stepScript)
{
    Add-GherkinStepDefinition -stepType $StepTypeEnum.Then -stepPattern $stepPattern -stepScript $stepScript
}
#endregion