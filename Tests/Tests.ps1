﻿param ([string] $logToFolder, [string] $extraLoggerParams = 'sourceLevel=Information')

$scriptFolder = $PSScriptRoot
. (Resolve-Path -Path (Join-Path -Path $scriptFolder -ChildPath '..\Define-GherkinHooksApi.ps1'))

trap {
    Get-Error | Out-Host
    exit 1;
    continue
}

function Save-ContentToTemporaryFile($scriptContent)
{
    $temporaryFilePath = [System.IO.Path]::GetTempFileName()
    $scriptContent | Out-File $temporaryFilePath
    return $temporaryFilePath
}

function Running($scriptContent, $illustrating, $tags = $Null, $cultureName = 'en', [switch] $expectFailures, [switch] $failFast)
{
    try
    {
        $temporaryFilePath = Save-ContentToTemporaryFile $scriptContent
        
        $logger = if (-Not [string]::IsNullOrEmpty($logToFolder)) { "file=$(Join-Path $logToFolder 'test-run.log');$extraLoggerParams" }
        $featureExecutionResults = @(& $(Join-Path -Path $scriptFolder -ChildPath '..\Run-GherkinScenarios.ps1') `
                                -scenarios $temporaryFilePath `
                                -tags $tags `
                                -cultureName $cultureName `
                                -logger $logger `
                                -doNotCleanupGherkinRunningInfrastructure `
                                -failFast:$failFast)
        if ($featureExecutionResults.Length -eq 0 -and $scriptContent -ne '')
        {
            throw "Test case '$illustrating': feature file parsing failed."
        }

        if (-Not [string]::IsNullOrEmpty($logToFolder) -and ($Null -ne (Get-Command ConvertTo-Json -ErrorAction  SilentlyContinue)))
        {
            $featureExecutionResults | `
				ForEach-Object { $_.Feature | ConvertTo-Json -Depth 20 } | Out-File -FilePath (Join-Path $logToFolder 'ParsedFeature.json')
        }

		if ($featureExecutionResults.Length -gt 0)
		{
			$failedScenarios = @($featureExecutionResults[0].ScenarioExecutionResults | Where-Object { $_.ScenarioOutcome -eq [ScenarioOutcome]::Failed })
			if (-not $expectFailures -and $failedScenarios.Length -gt 0)
			{
				$errors = @($failedScenarios | ForEach-Object { "Name: $($_.Scenario) Error: $($_.Error.ToString())" })
				throw "The following scenarios unexpectedly failed: $($errors -join [Environment]::NewLine)"
			}
		}

        return @{
            TestDescription = $illustrating;
            InvocationHistory = @(if ([TestRunContext]::Current.HasValue('InvocationHistory')) { [TestRunContext]::Current.GetValue('InvocationHistory') });
            ExecutionResults = & { switch ($expectFailures) { $true { $featureExecutionResults.ScenarioExecutionResults } $false { $null } } }
        }
    }
    finally
    {
        Remove-Item $temporaryFilePath -Force
    }
}

function Gherkin-Script($scriptContent)
{
    $scriptContent
}

function Compare-ObjectsWithNesting($referenceObject, $differenceObject)
{
    function Shift([string] $text = [string]::Empty, [int] $nestingLevel)
    {
        [string]::new(' ', $nestingLevel * 2) + $text
    }

    function ConvertTo-JsonWithOrderedProperties(
        $inputObject,
        [System.Collections.Generic.List[string]] $lines,
        [int] $nestingLevel)
    {
        function Dump-Array([array] $values, [string[]] $brackets)
        {
            if ($values.Length -eq 0)
            {
                $lines[-1] += "$($brackets[0])$($brackets[1])"
            }
            else
            {
                $lines[-1] += $brackets[0]
                for ($i = 0; $i -lt $values.Length; ++$i)
                {
                    $lines.Add((Shift -nestingLevel ($nestingLevel + 1)))
                    ConvertTo-JsonWithOrderedProperties `
                        -inputObject $values[$i] `
                        -lines $lines `
                        -nestingLevel ($nestingLevel + 1)
                    if (($i + 1) -lt $values.Length)
                    {
                        $lines[-1] += ','
                    }
                }

                $lines.Add((Shift -text $brackets[1] -nestingLevel $nestingLevel))
            }
        }

        if ($null -eq $inputObject)
        {
            $lines[-1] += 'null'
        }
        elseif ($inputObject -is [string])
        {
            $lines[-1] += "`"$($inputObject.Replace("`r`n", '\r\n').Replace("`n", '\r\n'))`""
        }
        elseif ($inputObject -is [array])
        {
            Dump-Array -values $inputObject -brackets '[',']'
        }
        elseif ($inputObject -is [hashtable])
        {
            Dump-Array -values @($inputObject.GetEnumerator() | Sort-Object -Property 'Name') -brackets '{','}'
        }
        elseif ($inputObject -is [GherkinTable])
        {
            ConvertTo-JsonWithOrderedProperties `
                    -inputObject @{ Header = $inputObject.Header; Rows = $inputObject.Rows } `
                    -lines $lines `
                    -nestingLevel $nestingLevel
        }
        elseif ($inputObject -is [System.Collections.DictionaryEntry])
        {
            $lines[-1] += "`"$($inputObject.Name)`": "
            ConvertTo-JsonWithOrderedProperties `
                -inputObject $inputObject.Value `
                -lines $lines `
                -nestingLevel $nestingLevel
        }
        elseif ($inputObject.GetType().IsEnum)
        {
            $lines[-1] += ([int]$inputObject).ToString()
        }
        else
        {
            throw "Do not know how to handle $($inputObject.GetType().Name)"
        }
    }

    function Get-JsonLines($value)
    {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add([string]::Empty)
        ConvertTo-JsonWithOrderedProperties -inputObject $value -lines $lines -nestingLevel 0
<#
    Commented code ensures that our Json representation has exactly the same set of strings as the
    standard Json represenation, but probably in a different order.

        $trueJson = ($value | ConvertTo-Json -Depth 20) -split [Environment]::NewLine
        $test = Compare-Object `
            -ReferenceObject @($trueJson | ForEach-Object { $_.TrimEnd(',') }) `
            -DifferenceObject @($lines | ForEach-Object { $_.TrimEnd(',') })

        if ($null -ne $test)
        {
            if ($trueJson -is [string[]] -and $trueJson.Length -eq 0 -and $lines.Count -eq 1 -and $lines[0] -eq '[]')
            {
                return $lines
            }

            if (-Not [string]::IsNullOrEmpty($logToFolder))
            {
                $trueJson | Out-File -FilePath (Join-Path $logToFolder 'ExpectedInvocationHistory.json')
                $lines | Out-File -FilePath (Join-Path $logToFolder 'ActualInvocationHistory.json')
            }

            throw ($test | Format-Table | Out-String)
        }
#>
        return $lines
    }

    $referenceLines = Get-JsonLines $referenceObject
    $differenceLines = Get-JsonLines $differenceObject

    if (-Not [string]::IsNullOrEmpty($logToFolder))
    {
        $referenceLines | Out-File -FilePath (Join-Path $logToFolder 'ExpectedInvocationHistory.json')
        $differenceLines | Out-File -FilePath (Join-Path $logToFolder 'ActualInvocationHistory.json')
    }

    Compare-Object -ReferenceObject @($referenceLines) -DifferenceObject @($differenceLines) -SyncWindow 0
}

function should
{
    $inputAsArray = @($input)
    $testDescription = $inputAsArray[0].TestDescription
    if (($args.Length -gt 4) -and ($Null -eq (Compare-Object -ReferenceObject $args[0..3] -DifferenceObject 'result', 'in', 'invocation', 'of')))
    {
        $actualInvocationHistory = $inputAsArray[0].InvocationHistory
        $hooksDifferencies = Compare-ObjectsWithNesting -ReferenceObject @($args[4]) -DifferenceObject $actualInvocationHistory
        if ($Null -eq $hooksDifferencies)
        {
            return
        }

        throw "Test '$testDescription' failed: Expected (<=) and actual(=>) invocation history differ: $($hooksDifferencies | Format-Table -Expand EnumOnly | Out-String)"
    }

    if (($args.Length -gt 5) -and ($Null -eq (Compare-Object -ReferenceObject $args[0..4] -DifferenceObject 'result', 'in', 'the', 'following', 'failure')))
    {
        $executionResults = $inputAsArray[0].ExecutionResults
        if ($executionResults.ScenarioOutcome -ne [ScenarioOutcome]::Failed)
        {
            Write-Host "`$executionResults.ScenarioOutcome = $($executionResults.ScenarioOutcome)"
            Write-Host "$($executionResults.ScenarioOutcome.GetType())"
            throw "Test '$testDescription' failed: the scenario in the feature file was supposed to fail, but it didn't. "
        }

        $failedAssertionsDifferencies = Compare-Object -ReferenceObject @($args[5]) -DifferenceObject @($executionResults.Error.Exception.Message -split [Environment]::NewLine)
        if ($Null -eq $failedAssertionsDifferencies)
        {
            Write-Host "Scenario $($executionResults.Scenario) ended with outcome=$($executionResults.ScenarioOutcome) as expected."
            return
        }

        throw "Test '$testDescription' failed: Expected (<=) and actual(=>) set of failed assertion messages differ: $($failedAssertionsDifferencies | Format-Table -Expand EnumOnly | Out-String)"
    }

    throw "Unknown arguments of 'should' in test '$testDescription': `$args=$args"
}

function Hook($hookType, $withContext)
{
    @{ HookType = $hookType; Context = $withContext }
}

function Step([switch]$given, [switch]$when, [switch]$then, $stepText, $tableArgument, $pyStringArgument)
{
    if ($given)
    {
        $stepType = [StepType]::Given
    }
    elseif ($when)
    {
        $stepType = [StepType]::When
    }
    elseif ($then)
    {
        $stepType = [StepType]::Then
    }
    else
    {
        throw 'Step(): neither one of Given/When/Then specified.'
    }

    @{ StepType = $stepType; StepText = $stepText; TableArgument = $tableArgument; PyStringArgument = $pyStringArgument }
}

function Insert($it, $between, $and_)
{
    $between | ForEach-Object { $_ }
    if ($null -ne $it)
    {
        $it | ForEach-Object { $_ }
    }
    $and_  | ForEach-Object { $_ }
}

function Fill-Context($context, [hashtable] $extraProperties = $null)
{
    $intermediateResult = switch ($null)
            {
                { $null -eq $context } { @{} }
                { $context -is [string] }  { @{ Name = $context; } }
                default { $context }
            }

    @{
        Name = [string]::Empty;
        Description = @();
        Tags = @()
    }.GetEnumerator() | `
        Where-Object { -not $intermediateResult.Contains($_.Name) } | `
        ForEach-Object { $intermediateResult.Add($_.Name, $_.Value) }

    # Exact order of properties in Hashtable is important for further comparison
    $result = @{ Name = $intermediateResult.Name; Description = @($intermediateResult.Description); Tags = @($intermediateResult.Tags) }
    if ($null -ne $extraProperties)
    {
        $result += $extraProperties
    }

    $result
}

function TestRun($with)
{
    Insert $with -between (Hook 'BeforeTestRun') -and_ (Hook 'AfterTestRun')
}

function Feature($withContext, $with)
{
    $feature = Insert $with -between (Hook 'BeforeFeature' -withContext (Fill-Context $withContext)) -and_ (Hook 'AfterFeature')
    (TestRun -with $feature)
}

function Scenario($withContext, $with)
{
    Insert $with -between (Hook 'BeforeScenario' -withContext (Fill-Context $withContext)) -and_ (Hook 'AfterScenario')
}

function Example($withContext, $from, $with)
{
    Insert $with -between (Hook 'BeforeScenario' -withContext (Fill-Context $withContext -extraProperties $from)) -and_ (Hook 'AfterScenario')
}

function Rule($withContext)
{
    $result = @{}
    (Fill-Context $withContext).GetEnumerator() | Where-Object { $_.Name -ne 'Tags' } | ForEach-Object { $result.Add("Rule$($_.Name)", $_.Value) }
    $result
}

function GivenBlock($with)
{
    Insert $with -between (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = [StepType]::Given }) -and_ (Hook 'AfterScenarioBlock')
}

function WhenBlock($with)
{
    Insert $with -between (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = [StepType]::When }) -and_ (Hook 'AfterScenarioBlock')
}

function ThenBlock($with)
{
    Insert $with -between (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = [StepType]::Then }) -and_ (Hook 'AfterScenarioBlock')
}

function GivenStep($stepText, $with)
{
    (Hook 'BeforeStep' -withContext @{ StepType = [StepType]::Given }),
    (Step -given $stepText -tableArgument $with),
    (Hook 'AfterStep')
}

function Single-GivenStep($stepText, $with)
{
    GivenBlock -with (GivenStep $stepText  $with)
}

function WhenStep($stepText, $with, $pyStringArgument)
{
    (Hook 'BeforeStep' -withContext @{ StepType = [StepType]::When }),
    (Step -when $stepText -tableArgument $with -pyStringArgument $pyStringArgument),
    (Hook 'AfterStep')
}

function Single-WhenStep($stepText, $with, $pyStringArgument)
{
    WhenBlock -with (WhenStep -stepText $stepText -with $with  -pyStringArgument $pyStringArgument)
}

function ThenStep($stepText, $with)
{
    (Hook 'BeforeStep' -withContext @{ StepType = [StepType]::Then }),
    (Step -then $stepText -tableArgument $with),
    (Hook 'AfterStep')
}

function Single-ThenStep($stepText, $with)
{
    ThenBlock -with (ThenStep $stepText $with)
}

function Table([string[]] $header, [array] $rows)
{
    $rowHashtables = @()
    if ($null -ne $rows)
    {
        $rowHashtables = $rows | ForEach-Object {
                $row = $_
                $result = @{}
                for ($i = 0; $i -ne $header.Length; ++$i)
                {
                    $result.Add($header[$i], $row[$i])
                }

                $result
            }
    }

    [GherkinTable]::new(@($header), @($rowHashtables))
}

function Build-ScenarioName($scenarioOutlineName, $parameterName, $parameterValue)
{
    "$scenarioOutlineName ($parameterName`: $parameterValue)"
}

class Pair
{
    [int] $First;
    [int] $Second;

    Pair([int] $f, [int] $s)
    {
        $this.First = $f;
        $this.Second = $s
    }
}

Clean-GherkinRunningInfrastructure

Set-Variable -Name GlobalCurrentStepDefinitionFilePath -Scope Global -Value  $myInvocation.MyCommand.Definition

BeforeTestRun {
    [TestRunContext]::Current.SetValue('InvocationHistory', (New-Object System.Collections.ArrayList))
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'BeforeTestRun')) })
}

AfterTestRun {
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'AfterTestRun')) })
}

BeforeFeature {
    $feature = [FeatureContext]::Current.FeatureInfo
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'BeforeFeature' @{ Name = $feature.Title; Description = $feature.Description; Tags = @($feature.Tags | Except-Nulls) })) })
}

BeforeFeature -tags @('DemonstratingFeatureHookFilteringByTags', 'SomeUnimportantTag') {
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'HookFilteringByTags_BeforeFeature')) })
}

AfterFeature {
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'AfterFeature')) })
}

BeforeScenario {
    [hashtable] $scenario = [ScenarioContext]::Current.ScenarioInfo
    $context = @{ Name = $scenario.Title; Description = $scenario.Description; Tags = @($scenario.Tags | Except-Nulls) }
    if ($scenario.ContainsKey('RuleTitle'))
    {
        $context += @{ RuleName = $scenario.RuleTitle; RuleDescription = $scenario.RuleDescription }
    }

    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'BeforeScenario' $context)) })
}

AfterScenario {
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'AfterScenario')) })
}

BeforeScenarioBlock {
    $blockType = [ScenarioContext]::Current.ScenarioInfo.CurrentScenarioBlock
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'BeforeScenarioBlock' @{ BlockType = $blockType })) })
}

AfterScenarioBlock {
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'AfterScenarioBlock')) })
}

BeforeStep {
    $stepType = [ScenarioContext]::Current.ScenarioInfo.CurrentScenarioBlock
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'BeforeStep' @{ StepType = $stepType })) })
}

AfterStep {
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'AfterStep')) })
}

AfterStep -tags @('AnotherUnimportantTag', 'DemonstratingScenarioHookFilteringByTags') {
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'HookFilteringByTags_AfterStep')) })
}

Given ([regex]'Call me (.*)') {
    param ($myName)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -given "Call me Argument($myName)")) })
}

Given ([regex]'I have these friends') {
    param ([GherkinTable] $friendsTable)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -given "I have these friends" -tableArgument $friendsTable)) })
}

When ([regex]'(\d+) plus (\d+) gives (\d+)') {
    param ($firstAddend, $secondAddend, $sum)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -when "Argument($firstAddend) plus Argument($secondAddend) gives Argument($sum)")) })
}

When ([regex]'I borrow (\d+) dollars from') {
    param ($borrowedAmount, [GherkinTable] $borrowedFromPersonsTable)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -when "I borrow Argument($borrowedAmount) dollars from" -tableArgument $borrowedFromPersonsTable)) })
}

When ('you hear (.*) eternal') {
    param ($article, $wordingPyString)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -when "you hear Argument($article) eternal" -pyStringArgument $wordingPyString)) })
}

Then ([regex]'everything should be alright') {
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -then 'everything should be alright')) })
}

Then ([regex]'I should have only (.*) left as a friend') {
    param ($friendName)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -then "I should have only Argument($friendName) left as a friend")) })
}

Given-WhenThen ([regex] "A failed Assertion with the text '(.*)' takes place") {
    param ($assertionMessage)
    Assert-That -condition $false -message $assertionMessage -omitCallStack -canProceed
}

Given ([regex] 'a timespan object with the value (.*)') {
    param ([TimeSpan] $timespan)
    [ScenarioContext]::Current.UpdateValue('CurrentTypedObject', $timespan)
}

Given ([regex] 'a StringComparison object with value (.*)') {
    param ([StringComparison] $stringComparison)
    [ScenarioContext]::Current.UpdateValue('CurrentTypedObject', $stringComparison)
}

Given ([regex] 'Pair object with the values (.*)') {
    param ([Pair] $pair)
    [ScenarioContext]::Current.UpdateValue('CurrentTypedObject', $pair)
}

Then ([regex] 'its (.*) property should be equal to (.*)') {
    param ([string] $propertyName, $expectedPropertyValue)
    $currentTypedObject = [ScenarioContext]::Current.GetValue('CurrentTypedObject')
    if ($expectedPropertyValue -ne $currentTypedObject.$propertyName)
    {
        throw "`$currentTypedObject.$propertyName is expected to be $expectedPropertyValue while it is $($currentTypedObject.$propertyName)"
    }
}

Then ([regex] 'its numerical value should be equal to (.*)') {
    param ([int] $expectedValue)
    $currentTypedObject = [ScenarioContext]::Current.GetValue('CurrentTypedObject')
    if ($expectedValue -ne [int] $currentTypedObject)
    {
        throw "`$currentTypedObject is expected to be $expectedValue while it is $currentTypedObject"
    }
}

CustomType-Converter ([Pair]) {
    param ($text) 
    $components = $text -split ','
    [Pair]::new($components[0], $components[1])
}


Running (Gherkin-Script '') -illustrating 'Empty *.feature' | should result in invocation of @()


Running (Gherkin-Script @"
     Feature: f0
"@) `
-illustrating 'Just one line with keyword <Feature:> in it' | should result in invocation of `
    (Feature 'f0')


Running (Gherkin-Script @"
     @SimplestTag
  @TagWithHeadAndTrailingSpaces   
  @FirstTag @SecondTag
 @Tag-1  	@Tag-2			@Tag3
Feature: Feature with explanation
  This is an explanation of this feature.
It spawns multiple lines
  Yet finally it finishes
"@) `
-illustrating 'Tags and description attached to a Feature' | should result in invocation of `
    (Feature -withContext @{
        Name = 'Feature with explanation';
        Description = 'This is an explanation of this feature.', 'It spawns multiple lines', 'Yet finally it finishes';
        Tags = 'SimplestTag', 'TagWithHeadAndTrailingSpaces', 'FirstTag', 'SecondTag', 'Tag-1', 'Tag-2', 'Tag3'
    })

Running (Gherkin-Script @"
Feature: f1
    describe feature here
Scenario: Checking addition
    describe scenario here
"@) `
-illustrating 'Feature with an empty Scenario in it' | should result in invocation of `
    (Feature -withContext @{ Name = 'f1'; Description = @('describe feature here') } `
                -with (Scenario -withContext @{ Name = 'Checking addition'; Description = @('describe scenario here') }))


Running (Gherkin-Script @"
Feature: f1.1
    describe feature here
@RequiresTransaction
Scenario: Checking addition
    describe scenario here
"@) `
-illustrating 'Feature with a Tagged and Scenario followed with description' | should result in invocation of `
    (Feature -withContext @{ Name = 'f1.1'; Description = @('describe feature here') } `
                -with (Scenario -withContext @{ Name = 'Checking addition'; Description = @('describe scenario here'); Tags = @('RequiresTransaction') }))


Running (Gherkin-Script @"
Feature: f2
Scenario: s2
    Then everything should be alright
"@) `
-illustrating 'Scenario with single parameterless step' | should result in invocation of `
    (Feature 'f2' -with (Scenario 's2' -with (Single-ThenStep 'everything should be alright')))


Running (Gherkin-Script @"
Feature: f3
Scenario: s3
    Given Call me Ishmael
"@) `
-illustrating 'Scenario with single step with one parameter' | should result in invocation of `
    (Feature 'f3' -with (Scenario 's3' -with (Single-GivenStep 'Call me Argument(Ishmael)')))


Running (Gherkin-Script @"
Feature: f3
Scenario: s3
    When 1 plus 2 gives 3
"@) `
-illustrating 'Scenario with single step with 3 parameters' | should result in invocation of `
    (Feature 'f3' `
        -with (Scenario 's3' `
            -with (Single-WhenStep 'Argument(1) plus Argument(2) gives Argument(3)')))


Running (Gherkin-Script @"
Feature: f4
Scenario: s4
    Given I have these friends
    | Friend Name | Age | Gender |
"@) `
-illustrating 'Step with an empty table parameter' | should result in invocation of `
    (Feature 'f4' `
        -with (Scenario 's4' `
            -with (Single-GivenStep 'I have these friends' -with (Table -header @('Friend Name', 'Age', 'Gender')))))


Running (Gherkin-Script @"
Feature: f4.0
Scenario: s4.0
    Given I have these friends
    | First Column | 2nd Column | Yet Another Column |
"@) `
-illustrating 'Step with an empty table parameter' | should result in invocation of `
    (Feature 'f4.0' `
        -with (Scenario 's4.0' `
            -with (Single-GivenStep 'I have these friends' `
                -with (Table -header 'First Column', '2nd Column', 'Yet Another Column' `
                             -rows   @() ))))


Running (Gherkin-Script @"
Feature: f4.1
Scenario: s4.1
    Given I have these friends
    | Friend Name |
    | Sam         |
    | Mary        |
    | John        |
"@) `
-illustrating 'Step with the single-column table parameter' | should result in invocation of `
    (Feature 'f4.1' `
        -with (Scenario 's4.1' `
            -with (Single-GivenStep 'I have these friends' `
                -with (Table -header @('Friend Name') `
                                -rows   @('Sam'),
                                        @('Mary'),
                                        @('John') ))))


Running (Gherkin-Script @"
Feature: f4.2
Scenario: s4.2
    Given I have these friends
    | Friend Name | Favorite Verse                                      |
    |-------------|-----------------------------------------------------|
    | Sam         | To be or not to be -                                |
    |             | That is the question!                               |
    |-------------|-----------------------------------------------------|
    | Mary        | When Israel was in Egypt land                       |
    |             | Let my people go!                                   |
    |             | Oppressed so hard they could not stand              |
    |             | Let my people go!                                   |
    |-------------|-----------------------------------------------------|
    | John        | There is a house in New Orleans...                  |
    |-------------|-----------------------------------------------------|
"@) `
-illustrating 'Step with the mulitline rows table' | should result in invocation of `
    (Feature 'f4.2' `
        -with (Scenario 's4.2' `
            -with (Single-GivenStep 'I have these friends' `
                -with (Table -header 'Friend Name', 'Favorite Verse' `
                                -rows   @('Sam', "To be or not to be -$([Environment]::NewLine)That is the question!"),
                                        @('Mary', "When Israel was in Egypt land$([Environment]::NewLine)Let my people go!$([Environment]::NewLine)Oppressed so hard they could not stand$([Environment]::NewLine)Let my people go!"),
                                        @('John', 'There is a house in New Orleans...') ))))


Running (Gherkin-Script @"
@Very @Complex
Feature: f4
    we also test how description of feature gets separated from first scenario tags
    @IamATag @NotADescription
Scenario: s4
    I am the scenario description
    Given I have these friends
        | Friend Name | Age | Gender |
        | Sam         | 45  | Male   |
        | Ann         | 32  | Female |
        | Tom         | 18  | Male   |
    When I borrow 50 dollars from 
        | Friend Name | Borrow date | 
        | Sam         | 06/25/2017  | 
        | Tom         | 08/13/2016  | 
    Then I should have only Ann left as a friend
"@) `
-illustrating 'Scenario with steps that have Table parameters' | should result in invocation of `
    (Feature -withContext @{ Name = 'f4'; Description = ,'we also test how description of feature gets separated from first scenario tags'; Tags = 'Very', 'Complex' } `
                -with (Scenario -withContext @{ Name = 's4'; Description = ,'I am the scenario description'; Tags = 'Very', 'Complex', 'IamATag', 'NotADescription' } `
                                -with (Single-GivenStep 'I have these friends' `
                                                        -with (Table -header 'Friend Name', 'Age', 'Gender' `
                                                                    -rows @('Sam', '45', 'Male'),
                                                                        @('Ann', '32', 'Female'),
                                                                        @('Tom', '18', 'Male'))),
                                    (Single-WhenStep 'I borrow Argument(50) dollars from' `
                                                    -with (Table -header 'Friend Name', 'Borrow date' `
                                                                    -row @('Sam','06/25/2017'),
                                                                        @('Tom','08/13/2016'))),
                                    (Single-ThenStep 'I should have only Argument(Ann) left as a friend')))

Running (Gherkin-Script @"
Feature: f5
Scenario: s5
    Given I have these friends
        | Friend Name | Age | Gender |
        | Sam         | 45  | Male   |
    And I have these friends
        | Friend Name | Age | Gender |
        | Ann         | 32  | Female |
    And I have these friends
        | Friend Name | Age | Gender |
        | Tom         | 18  | Male   |
    When I borrow 50 dollars from 
        | Friend Name | Borrow date | 
        | Sam         | 06/25/2017  | 
    And I borrow 40 dollars from 
        | Friend Name | Borrow date | 
        | Tom         | 08/13/2016  | 
    Then I should have only Ann left as a friend
     But everything should be alright
"@) `
-illustrating 'Scenario with several steps in each Given/When/Then group' | should result in invocation of `
    (Feature 'f5' `
                -with (Scenario 's5' `
                                -with (GivenBlock `
                                        -with (GivenStep 'I have these friends' `
                                                        -with (Table -header 'Friend Name', 'Age', 'Gender' -rows (,@('Sam', '45', 'Male')))),
                                            (GivenStep 'I have these friends' `
                                                        -with (Table -header 'Friend Name', 'Age', 'Gender' -rows (,@('Ann', '32', 'Female')))),
                                            (GivenStep 'I have these friends' `
                                                        -with (Table -header 'Friend Name', 'Age', 'Gender' -rows (,@('Tom', '18', 'Male'))))),
                                    (WhenBlock `
                                        -with (WhenStep 'I borrow Argument(50) dollars from' `
                                                        -with (Table -header 'Friend Name', 'Borrow date' -rows (,@('Sam', '06/25/2017')))),
                                            (WhenStep 'I borrow Argument(40) dollars from' `
                                                        -with (Table -header 'Friend Name', 'Borrow date' -rows (,@('Tom', '08/13/2016'))))),
                                    (ThenBlock `
                                        -with (ThenStep 'I should have only Argument(Ann) left as a friend'),
                                            (ThenStep 'everything should be alright'))))


Running (Gherkin-Script @"
Feature: f6
Scenario: s6
    When you hear the eternal 
        """
        To be or not to be,
        That is the question!
        """
    Then everything should be alright
"@) `
-illustrating 'Scenario with a step with PyStringArgument' | should result in invocation of `
    (Feature 'f6' `
        -with (Scenario 's6' `
                -with (Single-WhenStep 'you hear Argument(the) eternal' `
                                            -pyStringArgument @"
To be or not to be,
That is the question!
"@),
                        (Single-ThenStep 'everything should be alright')))


Running (Gherkin-Script @"
Feature: f10
Background:
    Given I have these friends
        | Friend Name | Age | Gender |
        | Sam         | 45  | Male   |
    And I have these friends
        | Friend Name | Age | Gender |
        | Ann         | 32  | Female |
    And I have these friends
        | Friend Name | Age | Gender |
        | Tom         | 18  | Male   |
    When I borrow 50 dollars from
        | Friend Name | Borrow date |
        | Sam         | 06/25/2017  |
Scenario: s7-1
    When I borrow 40 dollars from
        | Friend Name | Borrow date |
        | Tom         | 08/13/2016  |
    Then I should have only Ann left as a friend
     But everything should be alright
Scenario: s7-2
    Given I have these friends
        | Friend Name | Age | Gender |
        | Bob         | 64  | Male   |
    When I borrow 60 dollars from
        | Friend Name | Borrow date |
        | Bob         | 11/05/2018  |
        | Ann         | 05/12/2015  |
    Then I should have only Tom left as a friend
     But everything should be alright
"@)  `
-illustrating 'Background gets applied to all Scenarios from the Feature' | should result in invocation of `
        (Feature 'f10' -with `
            (Scenario 's7-1' -with `
                (GivenBlock -with `
                    (GivenStep 'I have these friends' `
                            -with (Table -header 'Friend Name', 'Age', 'Gender' -rows (,('Sam','45','Male')))),
                    (GivenStep 'I have these friends' `
                            -with (Table -header 'Friend Name', 'Age', 'Gender' -rows (,('Ann','32','Female')))),
                    (GivenStep 'I have these friends' `
                            -with (Table -header 'Friend Name', 'Age', 'Gender' -rows (,('Tom','18','Male'))))),
                (WhenBlock -with `
                    (WhenStep 'I borrow Argument(50) dollars from' `
                            -with (Table -header 'Friend Name', 'Borrow date' -rows (,('Sam', '06/25/2017')))),
                    (WhenStep 'I borrow Argument(40) dollars from' `
                            -with (Table -header 'Friend Name', 'Borrow date' -rows (,('Tom', '08/13/2016'))))),
                (ThenBlock -with `
                    (ThenStep 'I should have only Argument(Ann) left as a friend'),
                    (ThenStep 'everything should be alright'))),
            (Scenario 's7-2' -with `
                (GivenBlock -with `
                    (GivenStep 'I have these friends' `
                            -with (Table -header 'Friend Name', 'Age', 'Gender' -rows (,('Sam','45','Male')))),
                    (GivenStep 'I have these friends' `
                            -with (Table -header 'Friend Name', 'Age', 'Gender' -rows (,('Ann','32','Female')))),
                    (GivenStep 'I have these friends' `
                            -with (Table -header 'Friend Name', 'Age', 'Gender' -rows (,('Tom','18','Male'))))),
                (Single-WhenStep 'I borrow Argument(50) dollars from' `
                            -with (Table -header 'Friend Name', 'Borrow date' -rows (,('Sam', '06/25/2017')))),
                (Single-GivenStep 'I have these friends' `
                            -with (Table -header 'Friend Name', 'Age', 'Gender' -rows (,('Bob','64','Male')))),
                (Single-WhenStep 'I borrow Argument(60) dollars from' `
                            -with (Table -header 'Friend Name', 'Borrow date' -rows (('Bob','11/05/2018'),('Ann','05/12/2015')))),
                (ThenBlock -with `
                    (ThenStep 'I should have only Argument(Tom) left as a friend'),
                    (ThenStep 'everything should be alright'))))


Running (Gherkin-Script @"
@Tag0
Feature: f11-0
@Tag1
Scenario Outline: so
    Then I should have only <Second Customer Name> left as a friend
Examples:
    | First Customer Name | Second Customer Name | Number-1 | Number-2 | SumOfNumbers |
    | James               | Bob                  | 1001     | 2002     | 42           |
"@) `
-illustrating 'Tags propagation in Scenario Outline' | should result in invocation of `
    (Feature  -withContext @{ Name = 'f11-0'; Tags = @('Tag0') } -with `
        (Scenario -withContext @{ Name = (Build-ScenarioName 'so' 'First Customer Name' 'James'); Tags = @('Tag0', 'Tag1') } -with `
            (Single-ThenStep 'I should have only Argument(Bob) left as a friend')))


Running (Gherkin-Script @"
Feature: f11
Scenario Outline: s11
    Given Call me <First Customer Name>
    And Call me <Second Customer Name>
    When <Number-1> plus <Number-2> gives <SumOfNumbers>
    Then I should have only <Second Customer Name> left as a friend
Examples:
     | First Customer Name | Second Customer Name | Number-1 | Number-2 | SumOfNumbers | 
     | Ismael              | Bob                  | 1001     | 2002     | 42           | 
     | John                | James                | 33       | 123      | 1923         | 
     | John Donn           | Samuel L. Jackson    | 666      | 1000     | 1000000      |  
"@) `
-illustrating 'basic Scenario Outline' | should result in invocation of `
    (Feature 'f11' -with `
        (Scenario (Build-ScenarioName 's11' 'First Customer Name' 'Ismael') -with `
            (GivenBlock -with `
                (GivenStep 'Call me Argument(Ismael)'),
                (GivenStep 'Call me Argument(Bob)')),
            (Single-WhenStep 'Argument(1001) plus Argument(2002) gives Argument(42)'),
            (Single-ThenStep 'I should have only Argument(Bob) left as a friend')),
        (Scenario (Build-ScenarioName 's11' 'First Customer Name' 'John') -with `
            (GivenBlock -with `
                (GivenStep 'Call me Argument(John)'),
                (GivenStep 'Call me Argument(James)')),
            (Single-WhenStep 'Argument(33) plus Argument(123) gives Argument(1923)'),
            (Single-ThenStep 'I should have only Argument(James) left as a friend')),
        (Scenario (Build-ScenarioName 's11' 'First Customer Name' 'John Donn') -with `
            (GivenBlock -with `
                (GivenStep 'Call me Argument(John Donn)'),
                (GivenStep 'Call me Argument(Samuel L. Jackson)')),
            (Single-WhenStep 'Argument(666) plus Argument(1000) gives Argument(1000000)'),
            (Single-ThenStep 'I should have only Argument(Samuel L. Jackson) left as a friend')))


Running (Gherkin-Script @"
Feature: f12
Background: 
    Given Call me Sam
    And Call me Neo
Scenario Outline: s12-1
    When <Number-1> plus <Number-2> gives <SumOfNumbers>
    Then I should have only <Second Customer Name> left as a friend
Examples:
     | Number-1 | Number-2 | SumOfNumbers | Second Customer Name |
     | 1001     | 2002     | 42           | Mike                 |
     | 33       | 123      | 1923         | Peter                |
     | 666      | 1000     | 1000000      | John                 |
Scenario: s12-2
	Given I have these friends
        | Friend Name | Age | Gender |
        | Sam         | 45  | Male   |
	When I borrow 23 dollars from
        | Friend Name | Borrow date |
        | Sam         | 06/25/2017  |
    Then I should have only Jane left as a friend
"@) `
-illustrating 'Scenario Outline with Background' | should result in invocation of `
    (Feature 'f12' -with `
        (Scenario (Build-ScenarioName 's12-1' 'Number-1' '1001') -with `
            (GivenBlock -with `
                (GivenStep 'Call me Argument(Sam)'),
                (GivenStep 'Call me Argument(Neo)')),
            (Single-WhenStep 'Argument(1001) plus Argument(2002) gives Argument(42)'),
            (Single-ThenStep 'I should have only Argument(Mike) left as a friend')),
        (Scenario (Build-ScenarioName 's12-1' 'Number-1' '33') -with `
            (GivenBlock -with `
                (GivenStep 'Call me Argument(Sam)'),
                (GivenStep 'Call me Argument(Neo)')),
            (Single-WhenStep 'Argument(33) plus Argument(123) gives Argument(1923)'),
            (Single-ThenStep 'I should have only Argument(Peter) left as a friend')),
        (Scenario (Build-ScenarioName 's12-1' 'Number-1' '666') -with `
            (GivenBlock -with `
                (GivenStep 'Call me Argument(Sam)'),
                (GivenStep 'Call me Argument(Neo)')),
            (Single-WhenStep 'Argument(666) plus Argument(1000) gives Argument(1000000)'),
            (Single-ThenStep 'I should have only Argument(John) left as a friend')),
        (Scenario 's12-2' -with `
            (GivenBlock -with `
                (GivenStep 'Call me Argument(Sam)'),
                (GivenStep 'Call me Argument(Neo)'),
                (GivenStep `
                    'I have these friends' `
                    -with (Table -header 'Friend Name','Age','Gender' -rows (,@('Sam', '45', 'Male'))))),
            (Single-WhenStep `
                'I borrow Argument(23) dollars from' `
                -with (Table -header 'Friend Name', 'Borrow date' -rows (,@('Sam', '06/25/2017')))),
            (Single-ThenStep 'I should have only Argument(Jane) left as a friend')))


Running (Gherkin-Script @"
Feature: f13
Scenario Outline: s13
    Given I have these friends
        | Friend Name | Age | Gender |
        | Sam         | 45  | Male   |
        | Tom         | 18  | Male   |
    When I borrow <Amount> dollars from
        | Friend Name | Borrow date |
        | Tom         | 08/13/2016  |
    Then I should have only Sam left as a friend
Examples:
     | Amount  |
     | 1923    |
     | 1000000 |
     | 42      |
"@) `
-illustrating 'Scenario Outline with Table data' | should result in invocation of `
(Feature 'f13' -with `
    (Scenario (Build-ScenarioName 's13' 'Amount' '1923') -with `
        (Single-GivenStep 'I have these friends' `
            -with (Table -header 'Friend Name','Age','Gender' -rows @('Sam','45','Male'),@('Tom', '18','Male'))),
        (Single-WhenStep 'I borrow Argument(1923) dollars from' `
            -with (Table -header 'Friend Name', 'Borrow date' -rows (,@('Tom','08/13/2016')))),
        (Single-ThenStep 'I should have only Argument(Sam) left as a friend')),
    (Scenario (Build-ScenarioName 's13' 'Amount' '1000000') -with `
        (Single-GivenStep 'I have these friends' `
            -with (Table -header 'Friend Name','Age','Gender' -rows @('Sam','45','Male'),@('Tom', '18','Male'))),
        (Single-WhenStep 'I borrow Argument(1000000) dollars from' `
            -with (Table -header 'Friend Name', 'Borrow date' -rows (,@('Tom','08/13/2016')))),
        (Single-ThenStep 'I should have only Argument(Sam) left as a friend')),
    (Scenario (Build-ScenarioName 's13' 'Amount' '42') -with `
        (Single-GivenStep 'I have these friends' `
            -with (Table -header 'Friend Name','Age','Gender' -rows @('Sam','45','Male'),@('Tom', '18','Male'))),
        (Single-WhenStep 'I borrow Argument(42) dollars from' `
            -with (Table -header 'Friend Name', 'Borrow date' -rows (,@('Tom','08/13/2016')))),
        (Single-ThenStep 'I should have only Argument(Sam) left as a friend')))

Running (Gherkin-Script @"
Feature: f14
Scenario Outline: s14
    Given I have these friends
        | Friend Name | Age | Gender |
        | Sam         | 45  | Male   |
        | Tom         | 18  | Male   |
    When I borrow <Amount> dollars from
        | Friend Name | Borrow date |
        | <Friend>         | 08/13/2016  |
    Then I should have only <Friend that is left> left as a friend
Examples:
     | Amount | Friend | Friend that is left |
     | 1923   | Tom    | Sam                 |
     | 42     | Sam    | Tom                 |
"@) `
-illustrating 'Scenario Outline with Table data that contain Scenario Outline <variables>' | should result in invocation of `
    (Feature 'f14' -with `
        (Scenario (Build-ScenarioName 's14' 'Amount' '1923') -with `
            (Single-GivenStep 'I have these friends' `
                -with (Table -header 'Friend Name', 'Age', 'Gender' -rows @('Sam','45','Male'),@('Tom','18','Male'))),
            (Single-WhenStep 'I borrow Argument(1923) dollars from' `
                -with (Table -header 'Friend Name', 'Borrow date' -rows (,@('Tom','08/13/2016')))),
            (Single-ThenStep 'I should have only Argument(Sam) left as a friend')),
        (Scenario (Build-ScenarioName 's14' 'Amount' '42') -with `
            (Single-GivenStep 'I have these friends' `
                -with (Table -header 'Friend Name', 'Age', 'Gender' -rows @('Sam','45','Male'),@('Tom','18','Male'))),
            (Single-WhenStep 'I borrow Argument(42) dollars from' `
                -with (Table -header 'Friend Name', 'Borrow date' -rows (,@('Sam','08/13/2016')))),
            (Single-ThenStep 'I should have only Argument(Tom) left as a friend')))


Running (Gherkin-Script @"
@FeatureLevelTag
Feature: Inheriting Feature Tags In Scenarios
Scenario: Scenario without its own tags
	Then everything should be alright
@ScenarioLevelTag
Scenario: Scenario with its own tag
	Then everything should be alright
"@) `
-illustrating 'Propagating feature-level tags to the scenario level' | should result in invocation of `
    (Feature `
        -withContext @{ Name = 'Inheriting Feature Tags In Scenarios'; Tags = @('FeatureLevelTag') } `
        -with `
            (Scenario `
                -withContext @{ Name = 'Scenario without its own tags'; Tags = @('FeatureLevelTag') } `
                -with (Single-ThenStep 'everything should be alright')),
            (Scenario `
                -withContext @{ Name = 'Scenario with its own tag'; Tags = @('FeatureLevelTag', 'ScenarioLevelTag') } `
                -with (Single-ThenStep 'everything should be alright')))


Running (Gherkin-Script @"
Feature:
@tag-1
Scenario: Scenario with tag-1
	Given Call me Ishmael
@tag-2
Scenario: Scenario with tag-2
	Then everything should be alright
"@) -tags '@tag-2' `
-illustrating 'Using Run-GherkinScenarios''s parameter $tags: single tag, inclusion' | should result in invocation of `
    (Feature -with `
        (Scenario `
            -withContext @{ Name = 'Scenario with tag-2'; Tags = @('tag-2') } `
            -with (Single-ThenStep 'everything should be alright')))


Running (Gherkin-Script @"
Feature: 
@tag-1
Scenario: Scenario with tag-1
	Given Call me Ishmael
@tag-2
Scenario: Scenario with tag-2
	Then everything should be alright
"@) -tags '~@tag-2' `
-illustrating 'Using Run-GherkinScenarios''s parameter $tags: single tag, exclusion' | should result in invocation of `
    (Feature -with `
        (Scenario `
            -withContext @{ Name = 'Scenario with tag-1'; Tags = @('tag-1') } `
            -with (Single-GivenStep 'Call me Argument(Ishmael)')))


Running (Gherkin-Script @"
Feature: 
@billing @irrelevant
Scenario: Billing 
	Given Call me Ishmael
@jettisoned @discarded
Scenario: Left out
    When 4 plus 5 gives 9
@accounting @unimportant
Scenario: Accounting
	Then everything should be alright
"@) -tags '@billing,@accounting' `
-illustrating 'Using Run-GherkinScenarios''s parameter $tags: several tags, inclusion' | should result in invocation of `
    (Feature -with `
        (Scenario `
            -withContext @{ Name = 'Billing'; Tags = @('billing', 'irrelevant') } `
            -with (Single-GivenStep 'Call me Argument(Ishmael)')),
        (Scenario `
            -withContext @{ Name = 'Accounting'; Tags = @('accounting', 'unimportant') } `
            -with (Single-ThenStep 'everything should be alright')))


Running (Gherkin-Script @"
@DemonstratingFeatureHookFilteringByTags
Feature: Hooks Filtering by Tags
Scenario: No scenario-level hooks 
	Given Call me Ishmael
@DemonstratingScenarioHookFilteringByTags
Scenario: Accounting
	Then everything should be alright
"@) `
-illustrating 'Hooks Filtering by Tags' | should result in invocation of `
    (Feature `
        -withContext @{ Name = 'Hooks Filtering by Tags'; Tags = @('DemonstratingFeatureHookFilteringByTags') } `
        -with `
            (Hook 'HookFilteringByTags_BeforeFeature'),
            (Scenario `
                -withContext @{ Name = 'No scenario-level hooks'; Tags = @('DemonstratingFeatureHookFilteringByTags') } `
                -with (Single-GivenStep 'Call me Argument(Ishmael)')),
            (Scenario `
                -withContext @{ Name = 'Accounting'; Tags = @('DemonstratingFeatureHookFilteringByTags', 'DemonstratingScenarioHookFilteringByTags') } `
                -with (ThenBlock -with `
                        (ThenStep 'everything should be alright'),
                        (Hook 'HookFilteringByTags_AfterStep'))))


Running (Gherkin-Script @"
Feature: Testing scenario-level @ignore tag
@ignore
Scenario: Ignored scenario
	Given Call me Ishmael
Scenario: Accounting
	Then everything should be alright
"@) `
-illustrating 'Testing scenario-level @ignore tag' | should result in invocation of `
    (Feature `
        -withContext @{ Name = 'Testing scenario-level @ignore tag' } `
        -with (Scenario 'Accounting' -with (Single-ThenStep 'everything should be alright')))


Running (Gherkin-Script @"
@ignore
Feature: Testing feature-level @ignore tag 
Scenario: Test something
	Given Call me Ishmael
Scenario: Test something else
	Then everything should be alright
"@) `
-illustrating 'Testing feature-level @ignore tag' | should result in invocation of `
    (Feature -withContext @{ Name = 'Testing feature-level @ignore tag'; Tags = @('ignore') })


Running (Gherkin-Script @"
# @ThisTagShouldBeOmitted
   @Comments
# and this line too
Feature: Comments in all kinds of places
   Feature explanation
    #comment with heading spaces
 # Background: this is not a background, it's a comment
   this must be in description
 #    Given Call me Ishmael    -- comment too
  @Nope
 # Scenario: no, this is not a scenario
Scenario: Commenting steps and tables
   Given Call me Ishmael
#   Given Call me Rooth
   Given I have these friends
#   | Not  | a | Header |
   | Friend Name | Age | Gender |
#   | Sam         | 45  | Male   |
   | Tom         | 18  | Male   |
   # When 10 plus 20 gives 30
   When I borrow 1000 dollars from
   | Friend Name | Borrow date |
   | Tom         | 08/13/2016  |
#   | Sam         | 08/14/2017  |
Then I should have only Sara left as a friend
# And everything should be alright

#trailing comment

"@) `
-illustrating 'Comments in all kinds of places' | should result in invocation of `
    (Feature -withContext @{ Name = 'Comments in all kinds of places'; Description = @('Feature explanation','this must be in description'); Tags = @('Comments') } `
                -with (Scenario -withContext @{ Name = 'Commenting steps and tables'; Tags = @('Comments', 'Nope') } `
                                -with (GivenBlock `
                                        -with (GivenStep 'Call me Argument(Ishmael)'),
                                                (GivenStep 'I have these friends' `
                                                        -with (Table -header 'Friend Name', 'Age', 'Gender' `
                                                                        -rows (,@('Tom', '18', 'Male'))))),
                                    (WhenBlock `
                                        -with (WhenStep 'I borrow Argument(1000) dollars from' `
                                                        -with (Table -header 'Friend Name', 'Borrow date' `
                                                                        -rows (,@('Tom', '08/13/2016'))))),
                                    (ThenBlock -with (ThenStep 'I should have only Argument(Sara) left as a friend'))))


Running (Gherkin-Script @"
    Feature: Demonstrating free-form descriptions in all sorts of places

        this is a multi-line free-text
        description of the feature

    Background:

        the background also has
                   the description

        Given Call me Ishmael

    Scenario: test something

        description of the scenario, this time single-line
        Then everything should be alright

    Scenario Outline: test something else
        Scenario Outline can have description too

        Then I should have only <Friend Name> left as a friend
    Examples:
      First example block description
        | Friend Name |
        | Sara        |

    Examples:
        Second example block
            description
        | Friend Name |
        | John        |
"@) `
-illustrating "Free-form descriptions placed under 'Feature:', 'Background:', 'Scenario:', 'Scenario Outline:' and 'Examples:' sections" | should result in invocation of `
    (Feature `
        -withContext @{ Name = 'Demonstrating free-form descriptions in all sorts of places'; Description = 'this is a multi-line free-text','description of the feature' } `
        -with `
            (Scenario `
                -withContext @{ Name = 'test something'; Description = @('description of the scenario, this time single-line') } `
                -with `
                    (Single-GivenStep 'Call me Argument(Ishmael)'),
                    (Single-ThenStep 'everything should be alright')),
            (Scenario `
                -withContext @{ Name = (Build-ScenarioName 'test something else' 'Friend Name' 'Sara'); Description = @('First example block description') } `
                -with `
                    (Single-GivenStep 'Call me Argument(Ishmael)'),
                    (Single-ThenStep 'I should have only Argument(Sara) left as a friend')),
            (Scenario `
                -withContext @{ Name = (Build-ScenarioName 'test something else' 'Friend Name' 'John'); Description = 'Second example block','description' }`
                -with `
                    (Single-GivenStep 'Call me Argument(Ishmael)'),
                    (Single-ThenStep 'I should have only Argument(John) left as a friend')))

Running (Gherkin-Script @"
Feature: m-1
Scenario: s-1
    Given A failed Assertion with the text 'This is the first error coming from scenario' takes place
        When A failed Assertion with the text 'Another error came out' takes place
        Then A failed Assertion with the text 'And this is the 3rd, final error' takes place
"@) `
-expectFailures `
-illustrating 'All failed assertions get combined in the failed scenario outcome' | should result in the following failure `
    @('This is the first error coming from scenario', 'Another error came out', 'And this is the 3rd, final error')

#region Type convertors for step definition's parameters
[void] (Running (Gherkin-Script @"
Feature: z
Scenario: z-0
   Given a timespan object with the value 2:45:17
    Then its TotalSeconds property should be equal to 9917
   Given a StringComparison object with value InvariantCultureIgnoreCase
    Then its numerical value should be equal to 3
"@) `
    -illustrating "Application of standard type convertors for step definition's parameters" `
    -failFast)

[void] (Running (Gherkin-Script @"
Feature: z
Scenario: z-1
    Given a Pair object with the values 120,-5
    Then its First property should be equal to 120
    And its Second property should be equal to -5
"@) `
    -illustrating "Application of custom type convertors for step definition's parameters" `
    -failFast)
#endgion

#region Using Rule keyword
Running (Gherkin-Script @"
Feature: r-001
Rule: Always Be Closing
"@) `
    -illustrating 'Single Rule without Examples' | should result in invocation of `
    (Feature 'r-001')


Running (Gherkin-Script @"
Feature: r-002
Rule: Always Be Closing
Example: r-002, e-01
    Then everything should be alright
"@) `
    -illustrating 'Single Rule with a single example' | should result in invocation of `
    (Feature 'r-002' -with (Example 'r-002, e-01' -from (Rule 'Always Be Closing') -with (Single-ThenStep 'everything should be alright')))


Running (Gherkin-Script @"
Feature: r-003
Rule: Always Be Closing
Example: r-003, e-01
    Given Call me Ishmael
Example: r-003, e-02
    Then everything should be alright
"@) `
-illustrating 'Single Rule with several examples' | should result in invocation of `
(Feature 'r-003' -with `
    (Example 'r-003, e-01' -from (Rule 'Always Be Closing') -with (Single-GivenStep 'Call me Argument(Ishmael)')),
    (Example 'r-003, e-02' -from (Rule 'Always Be Closing') -with (Single-ThenStep 'everything should be alright')))


Running (Gherkin-Script @"
Feature: r-004
Rule: 1st rule
Example: r-004.1, e-01
    Given Call me Ishmael
Rule: 2nd rule
Example: r-004.2, e-01
    Then everything should be alright
"@) `
-illustrating 'Several Rules with single examples in each' | should result in invocation of `
(Feature 'r-004' -with `
    (Example 'r-004.1, e-01' -from (Rule '1st rule') -with (Single-GivenStep 'Call me Argument(Ishmael)')),
    (Example 'r-004.2, e-01' -from (Rule '2nd rule') -with (Single-ThenStep 'everything should be alright')))


Running (Gherkin-Script @"
Feature: r-005
Rule: Always Be Closing
    that's a quote from the 'Glengarry Glen Ross' movie
Background:
    Given Call me Ishmael
Example: r-005, e-01
    Then everything should be alright
Example: r-005, e-02
    When 1 plus 2 gives 3
"@) `
    -illustrating 'Rule with a description and a background' | should result in invocation of `
    (Feature 'r-005' -with `
        (Example 'r-005, e-01' `
            -from (Rule -withContext @{ Name = 'Always Be Closing'; Description = @("that's a quote from the 'Glengarry Glen Ross' movie") }) `
            -with `
                (Single-GivenStep 'Call me Argument(Ishmael)'), 
                (Single-ThenStep 'everything should be alright')),
        (Example 'r-005, e-02' `
            -from (Rule -withContext @{ Name = 'Always Be Closing'; Description = @("that's a quote from the 'Glengarry Glen Ross' movie") }) `
            -with `
                (Single-GivenStep 'Call me Argument(Ishmael)'),
                (Single-WhenStep 'Argument(1) plus Argument(2) gives Argument(3)')))
#endregion

#region Handling spaces after line-starting keywords

Running (Gherkin-Script @"
Feature:No spaces after colons
Scenario:001
    Given Call me Ishmael
Scenario:002
    When 4 plus 5 gives 9
Scenario:003
    Then everything should be alright
"@) `
    -illustrating 'No spaces after colons' | should result in invocation of `
        (Feature 'No spaces after colons' -with `
            (Scenario '001' `
                -with (Single-GivenStep 'Call me Argument(Ishmael)')),
            (Scenario '002' `
                -with (Single-WhenStep 'Argument(4) plus Argument(5) gives Argument(9)')),
            (Scenario '003' `
                -with (Single-ThenStep 'everything should be alright')))


foreach ($spaces in ' ', '  ', '   ', "`t", "`t `t ")
{
    $quotedSpaces = "``$($spaces.Replace("`t", '\t'))``"
    Running (Gherkin-Script @"
Feature:$($spaces)handling spaces $quotedSpaces after different keywords
Scenario:$($spaces)001 
    Given$($spaces)Call me Ishmael
Scenario:$($spaces)002
    When$($spaces)4 plus 5 gives 9
Scenario:$($spaces)003
    Then$($spaces)everything should be alright
"@) `
        -illustrating "handling spaces after different keywords: $quotedSpaces" | should result in invocation of `
            (Feature "handling spaces $quotedSpaces after different keywords" -with `
                (Scenario '001' `
                    -with (Single-GivenStep 'Call me Argument(Ishmael)')),
                (Scenario '002' `
                    -with (Single-WhenStep 'Argument(4) plus Argument(5) gives Argument(9)')),
                (Scenario '003' `
                    -with (Single-ThenStep 'everything should be alright')))
}

Running (Gherkin-Script @"
Функциональность: another bug
Сценарий: 002
Тогда everything should be alright
"@) `
    -cultureName 'ru' `
    -illustrating 'There should be a space after Given/When/Then keywords' | should result in invocation of `
        (Feature 'another bug' -with (Scenario '002' -with (Single-ThenStep 'everything should be alright')))
#endregion
