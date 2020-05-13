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

enum HookType
{
    SetupTestRun
    TeardownTestRun
    SetupFeature
    TeardownFeature
    SetupScenario
    TeardownScenario
    SetupScenarioBlock
    TeardownScenarioBlock
    SetupScenarioStep
    TeardownScenarioStep
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

class ExecutionHook
{
    [scriptblock] $Script

    [string[]] $Tags

    ExecutionHook([scriptblock] $sb, [string[]] $t)
    {
        $this.Script = $sb
        $this.Tags = $t
    }
}

class GherkinHooks
{
    [System.Collections.Generic.IDictionary[HookType, System.Collections.Generic.List[ExecutionHook]]] hidden $_registeredHooks

    GherkinHooks()
    {
        $this._registeredHooks = [System.Collections.Generic.Dictionary[HookType, System.Collections.Generic.List[ExecutionHook]]]::new()
        [Enum]::GetValues([HookType]) | ForEach-Object { $this._registeredHooks.Add($_, [System.Collections.Generic.List[ExecutionHook]]::new()) }
    }

    [void] RegisterHook([HookType] $hookType, [ExecutionHook] $hook)
    {
        $this._registeredHooks[$hookType].Add($hook)
    }

    [ExecutionHook[]] ForType([HookType] $hookType)
    {
        return $this._registeredHooks[$hookType].ToArray()
    }

    [void] Clear()
    {
        $this._registeredHooks.Values | ForEach-Object { $_.Clear() }
    }
}

class StepBinding
{
    [regex] $Pattern

    [scriptblock] $Script

    StepBinding([regex] $sp, [scriptblock] $ss)
    {
        $this.Pattern = $sp
        $this.Script = $ss
    }

    [MatchedStepBinding] TryMatch([string] $stepText)
    {
        $matchingResult = $this.Pattern.Match($stepText)
        if (-not $matchingResult.Success)
        {
            return $null
        }

        $matchedGroups = $matchingResult.Groups
        if ($matchedGroups.Count -le 1)
        {
            return [MatchedStepBinding]::new($this, @())
        }

        return [MatchedStepBinding]::new($this, @(@($matchedGroups)[1..($matchedGroups.Count - 1)] | ForEach-Object { $_.ToString() }))
    }
}

class MatchedStepBinding
{
    [StepBinding] $StepBinding

    [string[]] $StepArguments 

    MatchedStepBinding([StepBinding] $sb, [string[]] $sa )
    {
        $this.StepBinding = $sb
        $this.StepArguments = $sa
    }
}

class StepDefinitions
{
    [System.Collections.Generic.IDictionary[StepType, System.Collections.Generic.List[StepBinding]]] hidden $_registeredDefinitions

    StepDefinitions()
    {
        $this._registeredDefinitions = [System.Collections.Generic.Dictionary[StepType, System.Collections.Generic.List[StepBinding]]]::new()
        [Enum]::GetValues([StepType]) | ForEach-Object { $this._registeredDefinitions.Add($_, [System.Collections.Generic.List[StepBinding]]::new()) }
    }

    [void] RegisterDefinition([StepType] $stepType, [StepBinding] $stepBinding)
    {
        $this._registeredDefinitions[$stepType].Add($stepBinding)
    }

    [MatchedStepBinding] Match([StepType] $stepType, [string] $stepText)
    {
        $matchingStepDefinitions = @($this._registeredDefinitions[$stepType] | `
                                        ForEach-Object { $_.TryMatch($stepText) } | `
                                        Where-Object { $null -ne $_ })

        Verify-That `
            -condition ($matchingStepDefinitions.Length -gt 0) `
            -message "Could not locate step definition for the step [$stepText] of type [$stepType]."

        Verify-That `
            -condition ($matchingStepDefinitions.Length -lt 2) `
            -message @"
The step with text [$stepText] is matched by each one of the following StepDefinition patterns:
$([String]::Join([Environment]::NewLine, @($matchingStepDefinitions | ForEach-Object { "$($_.StepBinding.Pattern)" })))
Please refine the pattern's regex-es so that each step text was matched by exaqclty one pattern.
"@

        return $matchingStepDefinitions[0]
    }

    [void] Clear()
    {
        $this._registeredDefinitions.Values | ForEach-Object { $_.Clear() }
    }
}

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
    static [GherkinHooks] $GherkinHooks = [GherkinHooks]::new()
    static [StepDefinitions] $StepDefinitions = [StepDefinitions]::new()
    static [CustomTypeConverters] $CustomTypeConverters = [CustomTypeConverters]::new()
}

#region Gherkin Test Infrastructure
function Clean-GherkinRunningInfrastructure()
{
    [Known]::GherkinHooks.Clear()
    [Known]::StepDefinitions.Clear()
}

function Setup-TestRunContext
{
    [TestRunContext]::Current = [TestRunContext]::new()
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
function BeforeTestRun([scriptblock] $hookScript, [string[]] $tags)
{
    [Known]::GherkinHooks.RegisterHook([HookType]::SetupTestRun, [ExecutionHook]::new($hookScript, $tags))
}

function AfterTestRun([scriptblock] $hookScript, [string[]] $tags)
{
    [Known]::GherkinHooks.RegisterHook([HookType]::TeardownTestRun, [ExecutionHook]::new($hookScript, $tags))
}

function BeforeFeature([scriptblock] $hookScript, [string[]] $tags)
{
    [Known]::GherkinHooks.RegisterHook([HookType]::SetupFeature, [ExecutionHook]::new($hookScript, $tags))
}

function AfterFeature([scriptblock] $hookScript, [string[]] $tags)
{
    [Known]::GherkinHooks.RegisterHook([HookType]::TeardownFeature, [ExecutionHook]::new($hookScript, $tags))
}

function BeforeScenario([scriptblock] $hookScript, [string[]] $tags)
{
    [Known]::GherkinHooks.RegisterHook([HookType]::SetupScenario, [ExecutionHook]::new($hookScript, $tags))
}

function AfterScenario([scriptblock] $hookScript, [string[]] $tags)
{
    [Known]::GherkinHooks.RegisterHook([HookType]::TeardownScenario, [ExecutionHook]::new($hookScript, $tags))
}

function BeforeScenarioBlock([scriptblock] $hookScript, [string[]] $tags)
{
    [Known]::GherkinHooks.RegisterHook([HookType]::SetupScenarioBlock, [ExecutionHook]::new($hookScript, $tags))
}

function AfterScenarioBlock([scriptblock] $hookScript, [string[]] $tags)
{
    [Known]::GherkinHooks.RegisterHook([HookType]::TeardownScenarioBlock, [ExecutionHook]::new($hookScript, $tags))
}

function BeforeStep([scriptblock] $hookScript, [string[]] $tags)
{
    [Known]::GherkinHooks.RegisterHook([HookType]::SetupScenarioStep, [ExecutionHook]::new($hookScript, $tags))
}

function AfterStep([scriptblock] $hookScript, [string[]] $tags)
{
    [Known]::GherkinHooks.RegisterHook([HookType]::TeardownScenarioStep, [ExecutionHook]::new($hookScript, $tags))
}
#endregion

#region Step definitions
function Given([regex]$stepPattern, [scriptblock] $stepScript)
{
    [Known]::StepDefinitions.RegisterDefinition([StepType]::Given, [StepBinding]::new($stepPattern, $stepScript))
}

function When([regex]$stepPattern, [scriptblock] $stepScript)
{
    [Known]::StepDefinitions.RegisterDefinition([StepType]::When, [StepBinding]::new($stepPattern, $stepScript))
}

function Then([regex]$stepPattern, [scriptblock] $stepScript)
{
    [Known]::StepDefinitions.RegisterDefinition([StepType]::Then, [StepBinding]::new($stepPattern, $stepScript))
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