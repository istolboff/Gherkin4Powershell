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
function Add-GherkinHook($hookType, [scriptblock] $hookScript, [array] $tags)
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
    $allHooksOfType.Add(@{ Script = $hookScript; Tags = $tags }) | Out-Null
}

function BeforeTestRun([scriptblock] $hookScript, [array] $tags)
{
    Add-GherkinHook SetupTestRun $hookScript $tags
}

function AfterTestRun([scriptblock] $hookScript, [array] $tags)
{
    Add-GherkinHook TeardownTestRun $hookScript $tags
}

function BeforeFeature([scriptblock] $hookScript, [array] $tags)
{
    Add-GherkinHook SetupFeature $hookScript $tags
}

function AfterFeature([scriptblock] $hookScript, [array] $tags)
{
    Add-GherkinHook TeardownFeature $hookScript $tags
}

function BeforeScenario([scriptblock] $hookScript, [array] $tags)
{
    Add-GherkinHook SetupScenario $hookScript $tags
}

function AfterScenario([scriptblock] $hookScript, [array] $tags)
{
    Add-GherkinHook TeardownScenario $hookScript $tags
}

function BeforeScenarioBlock([scriptblock] $hookScript, [array] $tags)
{
    Add-GherkinHook SetupScenarioBlock $hookScript $tags
}

function AfterScenarioBlock([scriptblock] $hookScript, [array] $tags)
{
    Add-GherkinHook TeardownScenarioBlock $hookScript $tags
}

function BeforeStep([scriptblock] $hookScript, [array] $tags)
{
    Add-GherkinHook SetupScenarioStep $hookScript $tags
}

function AfterStep([scriptblock] $hookScript, [array] $tags)
{
    Add-GherkinHook TeardownScenarioStep $hookScript $tags
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

function Given([regex]$stepPattern, [scriptblock] $stepScript)
{
    Add-GherkinStepDefinition -stepType $StepTypeEnum.Given -stepPattern $stepPattern -stepScript $stepScript
}

function When([regex]$stepPattern, [scriptblock] $stepScript)
{
    Add-GherkinStepDefinition -stepType $StepTypeEnum.When -stepPattern $stepPattern -stepScript $stepScript
}

function Then([regex]$stepPattern, [scriptblock] $stepScript)
{
    Add-GherkinStepDefinition -stepType $StepTypeEnum.Then -stepPattern $stepPattern -stepScript $stepScript
}
#endregion