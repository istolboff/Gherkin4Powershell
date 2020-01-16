Set-StrictMode -Version Latest

#region Miscellaneous
function Describe-ErrorRecord($errorRecord)
{
    function Try-AppendPositionMessage($errRec, $errorMessages)
    {
        if (($null -ne $errRec.Exception) -and ($errRec.Exception.PSobject.Properties.Name -contains 'ErrorRecord') -and ($null -ne $errRec.Exception.ErrorRecord))
        {
            $errorMessages = Try-AppendPositionMessage -errRec $errRec.Exception.ErrorRecord -errorMessages $errorMessages
        }

        if ($null -ne $errRec.InvocationInfo -and $null -ne $errRec.InvocationInfo.PositionMessage)
        {
            $errorMessages += $errRec.InvocationInfo.PositionMessage | Out-String
        }

        $errorMessages
    }

    $description = @()
    if ($errorRecord -is [Exception])
    {
        $description += $errorRecord.ToString()
    }
    else
    {
        if ($null -ne $errorRecord.Exception)
        {
            $description += $errorRecord.Exception.ToString()
        }

        $description = Try-AppendPositionMessage -errRec $errorRecord -errorMessages $description

        if ($null -ne $errorRecord.ScriptStackTrace)
        {
            $description += ($errorRecord.ScriptStackTrace | Out-String)
        }
    }

    $description
}

function Define-Enumeration
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True, Position=0)]
        [string][ValidateNotNullOrEmpty()]$enumTypeName,

        [Parameter(Mandatory=$true, Position=1)]
        [array][ValidateNotNullOrEmpty()]$enumMemberNames)


	if (-not (Test-Path "variable:script:$enumTypeName"))
	{
        $enumMembers = @{}
        foreach ($enumMemberName in $enumMemberNames)
        {
            $enumMembers.Add($enumMemberName, "[$enumTypeName]::$enumMemberName")
        }

        Set-Variable -Name $enumTypeName -Value $enumMembers -Option Constant -Scope script -Force
	}
}
#endregion

#region Enumeartions
Define-Enumeration -enumTypeName StepTypeEnum -enumMemberNames Given, When, Then
Define-Enumeration -enumTypeName ScenarioOutcome -enumMemberNames Failed, Ignored, Succeeded
#endregion

#region Gherkin Hooks Infrastructure
function Clean-GherkinRunningInfrastructure()
{
	Remove-Variable -Name GherkinHooksDictionary03C98485EFD84C888750187736C181A7 -Scope Global -ErrorAction SilentlyContinue
	Remove-Variable -Name GherkinStepDefinitionDictionary03C98485EFD84C888750187736C181A7 -Scope Global -ErrorAction SilentlyContinue
}

function Setup-TestRunContext
{
    if (-Not ([System.Management.Automation.PSTypeName]'TestRunContext').Type)
    {
        Add-Type @'
using System;
using System.Collections.Generic;
using System.Management.Automation;
using System.Globalization;

public abstract class GherkinContextBase
{
    public bool HasValue(string name)
    {
        return _values.ContainsKey(name);
    }

    public object GetValue(string name)
    {
        return _values[name];
    }

    public void SetValue(string name, object value)
    {
        _values.Add(name, value);
    }

    public void UpdateValue(string name, object value)
    {
        _values[name] = value;
    }

    private readonly IDictionary<string, object> _values = new Dictionary<string, object>();
}

public class TestRunContext : GherkinContextBase
{
    public static TestRunContext Current;
}

public class FeatureContext : GherkinContextBase
{
	public PSObject FeatureInfo;

    public static FeatureContext Current;
}

public class ScenarioContext : GherkinContextBase
{
    public PSObject ScenarioInfo;

    public PSObject CurrentScenarioBlock;

    public void Pending()
    {
        throw new NotSupportedException("Step definition is not properly implemented.");
    }

    public static ScenarioContext Current;
}
'@
    }

    [TestRunContext]::Current = New-Object TestRunContext
}

function Get-GherkinHooks($hookType)
{
    if (-Not (Test-Path variable:global:GherkinHooksDictionary03C98485EFD84C888750187736C181A7))
    {
        return @()
    }

    $hooksDictionary = Get-Variable -Name GherkinHooksDictionary03C98485EFD84C888750187736C181A7 -Scope Global -ValueOnly
    if (-Not ($hooksDictionary.Contains($hookType)))
    {
        return @()
    }

    return $hooksDictionary[$hookType]
}
#endregion

#region Global Test Parameters
function Define-TestParametersCore($parameters, [switch] $optional)
{
    if ($parameters.Length % 2 -ne 0)
    {
        throw "Define-TestParameters expects a set of paired parameters: the first element of the pair is the argument's name, the second is a ref parameter that will accept the value"
    }

    $availableParameters = (Get-Variable -Name GlobalTestParametersHashtable -Scope Global).Value

    0..($parameters.Length / 2 - 1) | ForEach-Object {
        $parameterName = $parameters[2 * $_]
        if ($availableParameters.ContainsKey($parameterName))
        {
            $parameters[2 * $_ + 1].Value = $availableParameters[$parameterName]
        }
        elseif (-not $optional)
        {
            throw "The parameter with the name $parameterName was not specified. Only the following parameters are available: $($availableParameters.Keys)$([Environment]::NewLine)"
        }
    }
}

function Define-TestParameters
{
    Define-TestParametersCore -parameters $args
}

function Define-OptionalTestParameters
{
    Define-TestParametersCore -parameters $args -optional
}

function Register-AvailableTestParamers([array] $dynamicParamers)
{
    $result = @{}

    if ($dynamicParamers.Length -gt 0)
    {
        0..($dynamicParamers.Length / 2 - 1) | ForEach-Object { $result.Add($dynamicParamers[2 * $_], $dynamicParamers[2 * $_ + 1]) }
    }

    Set-Variable -Name GlobalTestParametersHashtable -Scope Global -Value $result
}
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

function Given-When([regex]$stepPattern, [scriptblock] $stepScript)
{
    Given -stepPattern $stepPattern -stepScript $stepScript
    When -stepPattern $stepPattern -stepScript $stepScript
}

function Given-WhenThen([regex]$stepPattern, [scriptblock] $stepScript)
{
    Given -stepPattern $stepPattern -stepScript $stepScript
    When -stepPattern $stepPattern -stepScript $stepScript
    Then -stepPattern $stepPattern -stepScript $stepScript
}
#endregion

#region Assert API
$failedAssertionsListName = '__FailedAssertions_F0FA5986-216F-4791-BE7E-3E50989A5720'

function Get-AllFailedAssertionsInfo
{
    switch ([ScenarioContext]::Current.HasValue($failedAssertionsListName)) {
        $false { $null }
        $true { [ScenarioContext]::Current.GetValue($failedAssertionsListName) -join [Environment]::NewLine }
    }
}

function Assert-That($condition, $message, [switch] $fatal, [switch] $passThrough)
{
    function Add-FailedAssertionInfo($message)
    {
        if (-not [ScenarioContext]::Current.HasValue($failedAssertionsListName))
        {
            [ScenarioContext]::Current.SetValue($failedAssertionsListName, (New-Object System.Collections.ArrayList))
        }

        [void] [ScenarioContext]::Current.GetValue($failedAssertionsListName).Add($message)
    }

    if (-not $condition)
    {
        Add-FailedAssertionInfo $message
        if ($fatal)
        {
            throw (Get-AllFailedAssertionsInfo)
        }
    }

    if ($passThrough)
    {
        return $condition
    }
}
#endregion