$scriptFolder = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path -Path $scriptFolder -ChildPath 'Define-GherkinHooksApi.ps1')

trap { 
    if ($global:Error.Count -gt 0)
    {
        foreach ($record in @($global:Error[0]))
        {
            $record | Format-List * -Force | Out-Host
            $record.InvocationInfo | Format-List * | Out-Host
            $Exception = $record.Exception | Out-Host
        }
    }

    exit 1; 
    continue 
}

function Save-ContentToTemporaryFile($scriptContent)
{
    $temporaryFilePath = [System.IO.Path]::GetTempFileName()
    $scriptContent | Out-File $temporaryFilePath
    return $temporaryFilePath 
}

function Running($scriptContent, $illustrating)
{
    try
    {
        $temporaryFilePath = Save-ContentToTemporaryFile $scriptContent
        $parsedScenarios = & $(Join-Path -Path $scriptFolder -ChildPath 'Run-GherkinScenarios.ps1') -scenarioFiles $temporaryFilePath
        if ($parsedScenarios.Feature -eq $Null -and $scriptContent -ne '')
        {
            throw "Test case '$illustrating': feature file parsing failed."
        }

        if ([TestRunContext]::Current.HasValue('InvocationHistory'))
        {
            return @{ TestDescription = $illustrating; InvocationHistory = ([TestRunContext]::Current.GetValue('InvocationHistory')) }
        }
        
        return @{ TestDescription = $illustrating; InvocationHistory = @() }
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

function Convert-ToXmlLines($complexObject)
{
    $sw = New-Object System.IO.StringWriter
    $writer = New-Object System.Xml.XmlTextwriter($sw)
    try
    {
        $writer.Formatting = [System.XML.Formatting]::Indented
        ($complexObject | ConvertTo-Xml -NoTypeInformation).WriteContentTo($writer)
        return @($sw.ToString().Split([Environment]::NewLine) | Where { $_ -ne ''} )
    }
    finally
    {
        $writer.Close()
        $sw.Close()
    }
}

function Compare-ObjectsWithNesting($referenceObject, $differenceObject)
{
    $referenceLines = Convert-ToXmlLines $referenceObject
    $differenceLines = Convert-ToXmlLines $differenceObject
    Compare-Object -ReferenceObject @($referenceLines) -DifferenceObject @($differenceLines)
}

function should 
{ 
    $inputAsArray = @($input)
    $actualInvocationHistory = $inputAsArray[0].InvocationHistory
    $testDescription = $inputAsArray[0].TestDescription
    if (($args.Length -gt 4) -and ((Compare-Object -ReferenceObject $args[0..3] -DifferenceObject 'result', 'in', 'invocation', 'of') -eq $Null))
    {

        $hooksDifferencies = Compare-ObjectsWithNesting -ReferenceObject @($args[4]) -DifferenceObject $actualInvocationHistory
        if ($hooksDifferencies -eq $Null)
        {
            return
        }

        throw "Test $testDescription failed: Expected (<=) and actual(=>) invocation history differ: $($hooksDifferencies | Format-Table -Expand EnumOnly | Out-String)"
    }

    throw "Unknown arguments of 'should' in test '$testDescription': `$args=$args"
}

function Hook($hookType, $withContext)
{
    @{ HookType = $hookType; Context = $withContext }
}

function Step([switch]$given, [switch]$when, [switch]$then, $stepText, $tableArgument)
{
    if ($given) 
    { 
        $stepType = $StepTypeEnum.Given 
    } 
    elseif ($when) 
    { 
        $stepType = $StepTypeEnum.When 
    } 
    elseif ($then) 
    { 
        $stepType = $StepTypeEnum.Then 
    } 
    else 
    { 
        throw 'Step(): neither one of Given/When/Then specified.' 
    }    

    @{ StepType = $stepType; StepText = $stepText; TableArgument = $tableArgument }
}

Remove-Variable -Name GherkinHooksDictionary03C98485EFD84C888750187736C181A7 -Scope Global -ErrorAction SilentlyContinue
Remove-Variable -Name GherkinStepDefinitionDictionary03C98485EFD84C888750187736C181A7 -Scope Global -ErrorAction SilentlyContinue

BeforeTestRun {
    [TestRunContext]::Current.SetValue('InvocationHistory', (New-Object System.Collections.ArrayList))
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'BeforeTestRun')) })
}

AfterTestRun {
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'AfterTestRun')) })
}

BeforeFeature {
    param ($feature)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'BeforeFeature' @{ Name = $feature.Name; Description = $feature.Description; Tags = @($feature.Tags | Except-Nulls) })) })
}

AfterFeature {
    param ($feature)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'AfterFeature')) })
}

BeforeScenario {
    param ($scenario)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'BeforeScenario' @{ Name = $scenario.Name; Description = $scenario.Description; Tags = @($scenario.Tags | Except-Nulls) })) })
}

AfterScenario {
    param ($scenario)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'AfterScenario')) })
}

BeforeScenarioBlock {
    param ($blockType)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'BeforeScenarioBlock' @{ BlockType = $blockType })) })
}

AfterScenarioBlock {
    param ($blockType)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'AfterScenarioBlock')) })
}

BeforeStep {
    param ($stepType)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'BeforeStep' @{ StepType = $stepType })) })
}

AfterStep {
    param ($stepType)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'AfterStep')) })
}

Given_ ([regex]'Call me (.*)') {
    param ($myName)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -given "Call me Argument($myName)")) })
}

Given_ ([regex]'I have these friends') {
    param ($friendsTable)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -given "I have these friends" -tableArgument $friendsTable)) })
}

When_ ([regex]'(\d+) plus (\d+) gives (\d+)') {
    param ($firstAddend, $secondAddend, $sum)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -when "Argument($firstAddend) plus Argument($secondAddend) gives Argument($sum)")) })
}

When_ ([regex]'I borrow (\d+) dollars from') {
    param ($borrowedAmount, $borrowedFromPersonsTable)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -when "I borrow Argument($borrowedAmount) dollars from" -tableArgument $borrowedFromPersonsTable)) })
}

Then_ ([regex]'everything should be alright') {
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -then 'everything should be alright')) })
}

Then_ ([regex]'I should have only (.*) left as a friend') {
    param ($friendName)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -then "I should have only Argument($friendName) left as a friend")) })
}

Running (Gherkin-Script "") -illustrating 'Empty *.feature' | should result in invocation of @()


Running (Gherkin-Script @"
     Feature: f0
"@) `
-illustrating 'Just one line with keyword <Feature:> in it' | should result in invocation of `
    (Hook 'BeforeTestRun'),
    (Hook 'BeforeFeature' -withContext @{ Name = 'f0'; Description = $Null; Tags = $Null }),
    (Hook 'AfterFeature'),
    (Hook 'AfterTestRun')


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
    (Hook 'BeforeTestRun'),
    (Hook 'BeforeFeature' -withContext @{ Name = 'Feature with explanation'; 
                                          Description = 'This is an explanation of this feature.', 'It spawns multiple lines', 'Yet finally it finishes'; 
                                          Tags = 'SimplestTag', 'TagWithHeadAndTrailingSpaces', 'FirstTag', 'SecondTag', 'Tag-1', 'Tag-2', 'Tag3'
                                       }),
    (Hook 'AfterFeature'),
    (Hook 'AfterTestRun')


Running (Gherkin-Script @"
Feature: f1
    describe feature here
Scenario: Checking addition
    describe scenario here
"@) `
-illustrating 'Feature with an empty Scenario in it' | should result in invocation of `
    (Hook 'BeforeTestRun'),
    (Hook 'BeforeFeature' -withContext @{ Name = 'f1'; Description = @('describe feature here'); Tags = $Null }),
    (Hook 'BeforeScenario' -withContext @{ Name = 'Checking addition'; Description = @('describe scenario here'); Tags = $Null }),
    (Hook 'AfterScenario'),
    (Hook 'AfterFeature'),
    (Hook 'AfterTestRun')


Running (Gherkin-Script @"
Feature: f1
    describe feature here
@RequiresTransaction
Scenario: Checking addition
    describe scenario here
"@) `
-illustrating 'Feature with a Tagged and Scenario followed with description' | should result in invocation of `
    (Hook 'BeforeTestRun'),
    (Hook 'BeforeFeature' -withContext @{ Name = 'f1'; Description = @('describe feature here'); Tags = $Null }),
    (Hook 'BeforeScenario' -withContext @{ Name = 'Checking addition'; Description = @('describe scenario here'); Tags = @('RequiresTransaction') }),
    (Hook 'AfterScenario'),
    (Hook 'AfterFeature'),
    (Hook 'AfterTestRun')


Running (Gherkin-Script @"
Feature: f2
Scenario: s2
    Then everything should be alright
"@) `
-illustrating 'Scenario with single parameterless step' | should result in invocation of `
    (Hook 'BeforeTestRun'),
    (Hook 'BeforeFeature' -withContext @{ Name = 'f2'; Description = $Null; Tags = $Null }),
    (Hook 'BeforeScenario' -withContext @{ Name = 's2'; Description = $Null; Tags = $Null }),
    (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
    (Step -then 'everything should be alright'),
    (Hook 'AfterStep'),
    (Hook 'AfterScenarioBlock'),
    (Hook 'AfterScenario'),
    (Hook 'AfterFeature'),
    (Hook 'AfterTestRun')


Running (Gherkin-Script @"
Feature: f3
Scenario: s3
    Given Call me Ishmael
"@) `
-illustrating 'Scenario with single step with one parameter' | should result in invocation of `
    (Hook 'BeforeTestRun'),
    (Hook 'BeforeFeature' -withContext @{ Name = 'f3'; Description = $Null; Tags = $Null }),
    (Hook 'BeforeScenario' -withContext @{ Name = 's3'; Description = $Null; Tags = $Null }),
    (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
    (Step -given 'Call me Argument(Ishmael)'),
    (Hook 'AfterStep'),
    (Hook 'AfterScenarioBlock'),
    (Hook 'AfterScenario'),
    (Hook 'AfterFeature'),
    (Hook 'AfterTestRun')


Running (Gherkin-Script @"
Feature: f3
Scenario: s3
    When 1 plus 2 gives 3
"@) `
-illustrating 'Scenario with single step with 3 parameters' | should result in invocation of `
    (Hook 'BeforeTestRun'),
    (Hook 'BeforeFeature' -withContext @{ Name = 'f3'; Description = $Null; Tags = $Null }),
    (Hook 'BeforeScenario' -withContext @{ Name = 's3'; Description = $Null; Tags = $Null }),
    (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
    (Step -when 'Argument(1) plus Argument(2) gives Argument(3)'),
    (Hook 'AfterStep'),
    (Hook 'AfterScenarioBlock'),
    (Hook 'AfterScenario'),
    (Hook 'AfterFeature'),
    (Hook 'AfterTestRun')


Running (Gherkin-Script @"
Feature: f4
Scenario: s4
    Given I have these friends
    | Friend Name | Age | Gender |
"@) `
-illustrating 'Step with an empty table parameter' | should result in invocation of `
    (Hook 'BeforeTestRun'),
    (Hook 'BeforeFeature' -withContext @{ Name = 'f4'; Description = $Null; Tags = $Null }),
    (Hook 'BeforeScenario' -withContext @{ Name = 's4'; Description = $Null; Tags = $Null }),
    (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
    (Step -given 'I have these friends' -tableArgument @{ Header = 'Friend Name', 'Age', 'Gender'; Rows = @() } ),
    (Hook 'AfterStep'),
    (Hook 'AfterScenarioBlock'),
    (Hook 'AfterScenario'),
    (Hook 'AfterFeature'),
    (Hook 'AfterTestRun')

    
Running (Gherkin-Script @"
Feature: f4
Scenario: s4
    Given I have these friends
    | Friend Name | 
    | Sam         |
    | Mary        |
    | John        |
"@) `
-illustrating 'Step with the single-column table parameter' | should result in invocation of `
    (Hook 'BeforeTestRun'),
    (Hook 'BeforeFeature' -withContext @{ Name = 'f4'; Description = $Null; Tags = $Null }),
    (Hook 'BeforeScenario' -withContext @{ Name = 's4'; Description = $Null; Tags = $Null }),
    (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
    (Step `
        -given 'I have these friends' `
        -tableArgument @{ 
            Header = ,'Friend Name'; 
            Rows = @{ 'Friend Name' = 'Sam' },
                   @{ 'Friend Name' = 'Mary' },
                   @{ 'Friend Name' = 'John' }
        }),
    (Hook 'AfterStep'),
    (Hook 'AfterScenarioBlock'),
    (Hook 'AfterScenario'),
    (Hook 'AfterFeature'),
    (Hook 'AfterTestRun')


Running (Gherkin-Script @"
@Very @Complex
Feature: f4
    we aslo test how description of feature gets separated from first scenario tags
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
    (Hook 'BeforeTestRun'),
    (Hook 'BeforeFeature' -withContext @{ Name = 'f4'; Description = ,'we aslo test how description of feature gets separated from first scenario tags'; Tags = 'Very', 'Complex' }),
    (Hook 'BeforeScenario' -withContext @{ Name = 's4'; Description = ,'I am the scenario description'; Tags = 'IamATag', 'NotADescription' }),
    # Given I have these friends
    (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
    (Step `
        -given 'I have these friends' `
        -tableArgument @{ 
            Header = 'Friend Name', 'Age', 'Gender'; 
            Rows = @{ 'Friend Name' = 'Sam'; 'Age' = 45; 'Gender' = 'Male' },
                   @{ 'Friend Name' = 'Ann'; 'Age' = 32; 'Gender' = 'Female' },
                   @{ 'Friend Name' = 'Tom'; 'Age' = 18; 'Gender' = 'Male' } 
        }),
    (Hook 'AfterStep'),
    (Hook 'AfterScenarioBlock'),
    # When I borrow 50 dollars from 
    (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
    (Step `
        -when 'I borrow Argument(50) dollars from' `
        -tableArgument @{ 
            Header = 'Friend Name', 'Borrow date'; 
            Rows = @{ 'Friend Name' = 'Sam'; 'Borrow date' = '06/25/2017' },
                   @{ 'Friend Name' = 'Tom'; 'Borrow date' = '08/13/2016' } 
        }),
    (Hook 'AfterStep'),
    (Hook 'AfterScenarioBlock'),
    #Then I should have only Ann left as a friend
    (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
    (Step -then 'I should have only Argument(Ann) left as a friend'),
    (Hook 'AfterStep'),
    (Hook 'AfterScenarioBlock'),
    #end of steps
    (Hook 'AfterScenario'),
    (Hook 'AfterFeature'),
    (Hook 'AfterTestRun')