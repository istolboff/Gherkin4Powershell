Set-StrictMode -Version Latest

#region Miscellaneous
function Verify-That($condition, $message)
{
    if (-Not $condition)
    {
        $exactMessage = switch($null)
                        {
                            { $message -is [string] } { $message }
                            { $message -is [scriptblock] } { & $message }
                        }
        throw $exactMessage
    }
}

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
            $errorMessages += ' ('
            $errorMessages += $errRec.InvocationInfo.PositionMessage | Out-String
            $errorMessages += ")$([Environment]::NewLine)"
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
#endregion

#region Enumerations
enum StepType
{
    Given
    When
    Then
}

enum ScenarioOutcome
{
    Failed
    Ignored
    Succeeded
}
#endregion

#region [TestRun|Feature|Scenario]Context
class GherkinContextBase 
{
    [System.Collections.Generic.IDictionary[string, object]] hidden $_values = [System.Collections.Generic.Dictionary[string, object]]::new()

    [bool] HasValue([string] $name) { return $this._values.ContainsKey($name) }

    [object] GetValue([string] $name) { return $this._values[$name] }

    [void] SetValue([string] $name, [object] $value) { $this._values.Add($name, $value) }

    [void] UpdateValue([string] $name, [object] $value) { $this._values[$name] = $value }

    [void] ModifyValue([string] $name, [ScriptBlock] $modifyValue) { & $modifyValue $this.GetValue($name) }
}

class TestRunContext : GherkinContextBase
{
    static [TestRunContext] $Current
}

class FeatureContext : GherkinContextBase
{
    [PSObject] $FeatureInfo

    static [FeatureContext] $Current
}

class ScenarioContext : GherkinContextBase
{
    [PSObject] $ScenarioInfo

    [PSObject] $CurrentScenarioBlock

    [void] Pending() { throw 'Step definition is not properly implemented.' }

    static [ScenarioContext] $Current
}
#endregion

class CustomTypeConverters
{
    [System.Collections.Generic.IDictionary[Type, System.Reflection.MethodInfo]] hidden $_registeredConverters = [System.Collections.Generic.Dictionary[Type, System.Reflection.MethodInfo]]::new()

    [void] RegisterConverter([System.Reflection.MethodInfo] $method)
    {
        $targetType = $method.ReturnType
        Verify-That `
            -condition (-not $this._registeredConverters.ContainsKey($targetType)) `
            -message { 
                $duplicateConverter = $this._registeredConverters[$targetType]
                "Both method $($method.DeclaringType.Name).$($method.Name) and method $($duplicateConverter.DeclaringType.Name).$($duplicateConverter.Name) define custom conversion to the type $($targetType.FullName)" 
            }

        $this._registeredConverters.Add($targetType, $method)
    }

    [object] ApplyTo([object] $value, [Type] $type)
    {
        $result = switch ($this._registeredConverters.ContainsKey($type))
                {
                    $false { $value }
                    $true  { $this._registeredConverters[$type].Invoke($null, @($value)) }
                }
        return $result
    }

    [object[]] ApplyToAll([object[]] $values, [Type[]] $targetTypes)
    {
        Verify-That `
            -condition ($values.Length -eq $targetTypes.Length) `
            -message "Program logic error: there's a mismatch between the actual values ($($values.Length)) and target types ($($targetTypes.Length)) for those values"

        $result = switch ($values.Length)
                {
                    0 { @() }
                    default { @(0..($values.Length - 1) | ForEach-Object { $this.ApplyTo($values[$_], $targetTypes[$_]) }) }
                }

        return $result
    }
}

class Known
{
    static [CustomTypeConverters] $CustomTypeConverters = [CustomTypeConverters]::new()
}

#region Gherkin Hooks Infrastructure
function Clean-GherkinRunningInfrastructure()
{
	Remove-Variable -Name GherkinHooksDictionary03C98485EFD84C888750187736C181A7 -Scope Global -ErrorAction SilentlyContinue
	Remove-Variable -Name GherkinStepDefinitionDictionary03C98485EFD84C888750187736C181A7 -Scope Global -ErrorAction SilentlyContinue
}

function Setup-TestRunContext
{
    [TestRunContext]::Current = [TestRunContext]::new()
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
        throw "Define-[Optional]TestParameters expects a set of paired parameters: the first element of the pair is the argument's name, the second is a ref parameter that will accept the value"
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

#region Custom Type Converters
function Register-CustomTypeConverter([Type] $typeWithConverterMethods)
{
    $typeWithConverterMethods.GetMethods([System.Reflection.BindingFlags]::Static + [System.Reflection.BindingFlags]::Public) | `
        ForEach-Object {
            [Known]::CustomTypeConverters.RegisterConverter($_)
        } 
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
function Add-GherkinStepDefinition([StepType] $stepType, [regex]$stepPattern, [scriptblock]$stepScript)
{
    if (-Not (Test-Path variable:global:GherkinStepDefinitionDictionary03C98485EFD84C888750187736C181A7))
    {
        Set-Variable `
            -Name GherkinStepDefinitionDictionary03C98485EFD84C888750187736C181A7 `
            -Scope Global `
            -Value @{ 
                [StepType]::Given = (New-Object System.Collections.ArrayList); 
                [StepType]::When = (New-Object System.Collections.ArrayList); 
                [StepType]::Then = (New-Object System.Collections.ArrayList)
            }
    }

    $stepDefinitionDictionary = Get-Variable -Name GherkinStepDefinitionDictionary03C98485EFD84C888750187736C181A7 -Scope Global -ValueOnly
    $allStepDefinitionsOfType = $stepDefinitionDictionary.Item($stepType)
    $allStepDefinitionsOfType.Add(@{ StepPattern = $stepPattern; StepScript = $stepScript }) | Out-Null
}

function Given([regex]$stepPattern, [scriptblock] $stepScript)
{
    Add-GherkinStepDefinition -stepType ([StepType]::Given) -stepPattern $stepPattern -stepScript $stepScript
}

function When([regex]$stepPattern, [scriptblock] $stepScript)
{
    Add-GherkinStepDefinition -stepType ([StepType]::When) -stepPattern $stepPattern -stepScript $stepScript
}

function Then([regex]$stepPattern, [scriptblock] $stepScript)
{
    Add-GherkinStepDefinition -stepType ([StepType]::Then) -stepPattern $stepPattern -stepScript $stepScript
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

#region Logging API
function Log-TestRunning($message)
{
    if (-Not [string]::IsNullOrEmpty($logTestRunningToFile))
    {
        "$([datetime]::Now.ToString("HH:mm:ss.ffff"))   $message" | Out-File -FilePath $logTestRunningToFile -Append
    }
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
        else
        {
            Log-TestRunning -message "Assertion failed: $message"
        }
    }

    if ($passThrough)
    {
        return $condition
    }
}
#endregion