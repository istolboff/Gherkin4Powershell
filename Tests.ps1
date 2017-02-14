param ([string] $logToFolder)

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

function Running($scriptContent, $illustrating, $tags = $Null)
{
    try
    {
        $temporaryFilePath = Save-ContentToTemporaryFile $scriptContent
        $parsingLogFile = if (-Not [string]::IsNullOrEmpty($logToFolder)) { Join-Path $logToFolder 'parser.log' }
        $parsedScenarios = & $(Join-Path -Path $scriptFolder -ChildPath 'Run-GherkinScenarios.ps1') `
                                -scenarioFiles $temporaryFilePath `
                                -tags $tags `
                                -cultureName 'en-US' `
                                -logParsingToFile $parsingLogFile
        if ($parsedScenarios.Feature -eq $Null -and $scriptContent -ne '')
        {
            throw "Test case '$illustrating': feature file parsing failed."
        }

        if (-Not [string]::IsNullOrEmpty($logToFolder) -and ((Get-Command ConvertTo-Json -ErrorAction  SilentlyContinue) -ne $Null))
        {
            $parsedScenarios.Feature | ConvertTo-Json -Depth 10 | Out-File -FilePath (Join-Path $logToFolder 'ParsedFeature.json')
        }

        return @{ 
            TestDescription = $illustrating; 
            InvocationHistory = @(if ([TestRunContext]::Current.HasValue('InvocationHistory')) { [TestRunContext]::Current.GetValue('InvocationHistory') })
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
    if (-Not [string]::IsNullOrEmpty($logToFolder) -and ((Get-Command ConvertTo-Json -ErrorAction  SilentlyContinue) -ne $Null))
    {
        $referenceObject | ConvertTo-Json -Depth 10 | Out-File -FilePath (Join-Path $logToFolder 'ExpectedInvocationHistory.json')
        $differenceObject | ConvertTo-Json -Depth 10 | Out-File -FilePath (Join-Path $logToFolder 'ActualInvocationHistory.json')
    }

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

        throw "Test '$testDescription' failed: Expected (<=) and actual(=>) invocation history differ: $($hooksDifferencies | Format-Table -Expand EnumOnly | Out-String)"
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

    @{ StepType = $stepType; StepText = $stepText; TableArgument = $tableArgument; PyStringArgument = $pyStringArgument }
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
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'BeforeFeature' @{ Name = $feature.Title; Description = $feature.Description; Tags = @($feature.Tags | Except-Nulls) })) })
}

AfterFeature {
    param ($feature)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'AfterFeature')) })
}

BeforeScenario {
    param ($scenario)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Hook 'BeforeScenario' @{ Name = $scenario.Title; Description = $scenario.Description; Tags = @($scenario.Tags | Except-Nulls) })) })
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

Given ([regex]'Call me (.*)') {
    param ($myName)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -given "Call me Argument($myName)")) })
}

Given ([regex]'I have these friends') {
    param ($friendsTable)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -given "I have these friends" -tableArgument $friendsTable)) })
}

When ([regex]'(\d+) plus (\d+) gives (\d+)') {
    param ($firstAddend, $secondAddend, $sum)
    [TestRunContext]::Current.ModifyValue('InvocationHistory', { param($value) $value.Add((Step -when "Argument($firstAddend) plus Argument($secondAddend) gives Argument($sum)")) })
}

When ([regex]'I borrow (\d+) dollars from') {
    param ($borrowedAmount, $borrowedFromPersonsTable)
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
    (Hook 'BeforeScenario' -withContext @{ Name = 's4'; Description = ,'I am the scenario description'; Tags = 'Very', 'Complex', 'IamATag', 'NotADescription' }),
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
    (Hook 'BeforeTestRun'),
    (Hook 'BeforeFeature' -withContext @{ Name = 'f5'; Description = $Null; Tags = $Null }),
    (Hook 'BeforeScenario' -withContext @{ Name = 's5'; Description = $Null; Tags = $Null }),
    # Given-s I have these friends
    (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
    (Step `
        -given 'I have these friends' `
        -tableArgument @{ 
            Header = 'Friend Name', 'Age', 'Gender'; 
            Rows = ,@{ 'Friend Name' = 'Sam'; 'Age' = 45; 'Gender' = 'Male' }
        }),
    (Hook 'AfterStep'),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
    (Step `
        -given 'I have these friends' `
        -tableArgument @{ 
            Header = 'Friend Name', 'Age', 'Gender'; 
            Rows = ,@{ 'Friend Name' = 'Ann'; 'Age' = 32; 'Gender' = 'Female' } 
        }),
    (Hook 'AfterStep'),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
    (Step `
        -given 'I have these friends' `
        -tableArgument @{ 
            Header = 'Friend Name', 'Age', 'Gender'; 
            Rows = ,@{ 'Friend Name' = 'Tom'; 'Age' = 18; 'Gender' = 'Male' } 
        }),
    (Hook 'AfterStep'),
    (Hook 'AfterScenarioBlock'),
    # When-s I borrow X dollars from 
    (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
    (Step `
        -when 'I borrow Argument(50) dollars from' `
        -tableArgument @{ 
            Header = 'Friend Name', 'Borrow date'; 
            Rows = ,@{ 'Friend Name' = 'Sam'; 'Borrow date' = '06/25/2017' }
        }),
    (Hook 'AfterStep'),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
    (Step `
        -when 'I borrow Argument(40) dollars from' `
        -tableArgument @{ 
            Header = 'Friend Name', 'Borrow date'; 
            Rows = ,@{ 'Friend Name' = 'Tom'; 'Borrow date' = '08/13/2016' } 
        }),
    (Hook 'AfterStep'),
    (Hook 'AfterScenarioBlock'),
    #Then-s
    (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
    (Step -then 'I should have only Argument(Ann) left as a friend'),
    (Hook 'AfterStep'),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
    (Step -then 'everything should be alright'),
    (Hook 'AfterStep'),
    (Hook 'AfterScenarioBlock'),
    #end of steps
    (Hook 'AfterScenario'),
    (Hook 'AfterFeature'),
    (Hook 'AfterTestRun')


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
-illustrating 'Scenario with single step with one parameter' | should result in invocation of `
    (Hook 'BeforeTestRun'),
    (Hook 'BeforeFeature' -withContext @{ Name = 'f6'; Description = $Null; Tags = $Null }),
    (Hook 'BeforeScenario' -withContext @{ Name = 's6'; Description = $Null; Tags = $Null }),
    (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
    (Step -when 'you hear Argument(the) eternal' -pyStringArgument @"
To be or not to be,
That is the question!
"@),
    (Hook 'AfterStep'),
    (Hook 'AfterScenarioBlock'),
    (Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
    (Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
    (Step -then 'everything should be alright'),
    (Hook 'AfterStep'),
    (Hook 'AfterScenarioBlock'),
    (Hook 'AfterScenario'),
    (Hook 'AfterFeature'),
    (Hook 'AfterTestRun')


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
(Hook 'BeforeTestRun'),
(Hook 'BeforeFeature' -withContext @{ Name = 'f10'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenario' -withContext @{ Name = 's7-1'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'I have these friends' -tableArgument @{ Header = 'Friend Name', 'Age', 'Gender'; Rows = ,@{ 'Friend Name' = 'Sam'; 'Age' = '45'; 'Gender' = 'Male' } } ),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'I have these friends' -tableArgument @{ Header = 'Friend Name', 'Age', 'Gender'; Rows = ,@{ 'Friend Name' = 'Ann'; 'Age' = '32'; 'Gender' = 'Female' } } ),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'I have these friends' -tableArgument @{ Header = 'Friend Name', 'Age', 'Gender'; Rows = ,@{ 'Friend Name' = 'Tom'; 'Age' = '18'; 'Gender' = 'Male' } } ),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'I borrow Argument(50) dollars from' -tableArgument @{ Header = 'Friend Name', 'Borrow date'; Rows = ,@{ 'Friend Name' = 'Sam'; 'Borrow date' = '06/25/2017' } }),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'I borrow Argument(40) dollars from' -tableArgument @{ Header = 'Friend Name', 'Borrow date'; Rows = ,@{ 'Friend Name' = 'Tom'; 'Borrow date' = '08/13/2016' } }),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'I should have only Argument(Ann) left as a friend'),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'everything should be alright'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'BeforeScenario' -withContext @{ Name = 's7-2'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'I have these friends' -tableArgument @{ Header = 'Friend Name', 'Age', 'Gender'; Rows = ,@{ 'Friend Name' = 'Sam'; 'Age' = '45'; 'Gender' = 'Male' } } ),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'I have these friends' -tableArgument @{ Header = 'Friend Name', 'Age', 'Gender'; Rows = ,@{ 'Friend Name' = 'Ann'; 'Age' = '32'; 'Gender' = 'Female' } } ),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'I have these friends' -tableArgument @{ Header = 'Friend Name', 'Age', 'Gender'; Rows = ,@{ 'Friend Name' = 'Tom'; 'Age' = '18'; 'Gender' = 'Male' } } ),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'I borrow Argument(50) dollars from' -tableArgument @{ Header = 'Friend Name', 'Borrow date'; Rows = ,@{ 'Friend Name' = 'Sam'; 'Borrow date' = '06/25/2017' } }),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'I have these friends' -tableArgument @{ Header = 'Friend Name', 'Age', 'Gender'; Rows = ,@{ 'Friend Name' = 'Bob'; 'Age' = '64'; 'Gender' = 'Male' } } ),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'I borrow Argument(60) dollars from' -tableArgument @{ Header = 'Friend Name', 'Borrow date'; Rows = @{ 'Friend Name' = 'Bob'; 'Borrow date' = '11/05/2018' }, @{ 'Friend Name' = 'Ann'; 'Borrow date' = '05/12/2015' } }),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'I should have only Argument(Tom) left as a friend'),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'everything should be alright'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'AfterFeature'),
(Hook 'AfterTestRun')


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
(Hook 'BeforeTestRun'),
(Hook 'BeforeFeature' -withContext @{ Name = 'f11'; Description = $Null; Tags = $Null }),
(Hook 'BeforeScenario' -withContext @{ Name = 's11'; Description = $Null; Tags = $Null }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(Ismael)'),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(Bob)'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'Argument(1001) plus Argument(2002) gives Argument(42)'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'I should have only Argument(Bob) left as a friend'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'BeforeScenario' -withContext @{ Name = 's11'; Description = $Null; Tags = $Null }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(John Donn)'),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(Samuel L. Jackson)'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'Argument(666) plus Argument(1000) gives Argument(1000000)'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'I should have only Argument(Samuel L. Jackson) left as a friend'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'BeforeScenario' -withContext @{ Name = 's11'; Description = $Null; Tags = $Null }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(John)'),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(James)'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'Argument(33) plus Argument(123) gives Argument(1923)'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'I should have only Argument(James) left as a friend'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'AfterFeature'),
(Hook 'AfterTestRun')


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
(Hook 'BeforeTestRun'),
(Hook 'BeforeFeature' -withContext @{ Name = 'f12'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenario' -withContext @{ Name = 's12-1'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(Sam)'),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(Neo)'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'Argument(1001) plus Argument(2002) gives Argument(42)'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'I should have only Argument(Mike) left as a friend'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'BeforeScenario' -withContext @{ Name = 's12-1'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(Sam)'),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(Neo)'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'Argument(33) plus Argument(123) gives Argument(1923)'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'I should have only Argument(Peter) left as a friend'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'BeforeScenario' -withContext @{ Name = 's12-1'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(Sam)'),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(Neo)'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'Argument(666) plus Argument(1000) gives Argument(1000000)'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'I should have only Argument(John) left as a friend'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'BeforeScenario' -withContext @{ Name = 's12-2'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(Sam)'),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(Neo)'),
(Hook 'AfterStep'),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'I have these friends' -tableArgument @{ Header = 'Friend Name', 'Age', 'Gender'; Rows = ,@{ 'Friend Name' = 'Sam'; 'Age' = '45'; 'Gender' = 'Male' } } ),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'I borrow Argument(23) dollars from' -tableArgument @{ Header = 'Friend Name', 'Borrow date'; Rows = ,@{ 'Friend Name' = 'Sam'; 'Borrow date' = '06/25/2017' } }),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'I should have only Argument(Jane) left as a friend'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'AfterFeature'),
(Hook 'AfterTestRun')


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
(Hook 'BeforeTestRun'),
(Hook 'BeforeFeature' -withContext @{ Name = 'f13'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenario' -withContext @{ Name = 's13'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'I have these friends' -tableArgument @{ Header = 'Friend Name', 'Age', 'Gender'; Rows = @{ 'Friend Name' = 'Sam'; 'Age' = '45'; 'Gender' = 'Male' }, @{ 'Friend Name' = 'Tom'; 'Age' = '18'; 'Gender' = 'Male' } } ),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'I borrow Argument(1923) dollars from' -tableArgument @{ Header = 'Friend Name', 'Borrow date'; Rows = ,@{ 'Friend Name' = 'Tom'; 'Borrow date' = '08/13/2016' } }),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'I should have only Argument(Sam) left as a friend'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'BeforeScenario' -withContext @{ Name = 's13'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'I have these friends' -tableArgument @{ Header = 'Friend Name', 'Age', 'Gender'; Rows = @{ 'Friend Name' = 'Sam'; 'Age' = '45'; 'Gender' = 'Male' }, @{ 'Friend Name' = 'Tom'; 'Age' = '18'; 'Gender' = 'Male' } } ),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'I borrow Argument(1000000) dollars from' -tableArgument @{ Header = 'Friend Name', 'Borrow date'; Rows = ,@{ 'Friend Name' = 'Tom'; 'Borrow date' = '08/13/2016' } }),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'I should have only Argument(Sam) left as a friend'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'BeforeScenario' -withContext @{ Name = 's13'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'I have these friends' -tableArgument @{ Header = 'Friend Name', 'Age', 'Gender'; Rows = @{ 'Friend Name' = 'Sam'; 'Age' = '45'; 'Gender' = 'Male' }, @{ 'Friend Name' = 'Tom'; 'Age' = '18'; 'Gender' = 'Male' } } ),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'I borrow Argument(42) dollars from' -tableArgument @{ Header = 'Friend Name', 'Borrow date'; Rows = ,@{ 'Friend Name' = 'Tom'; 'Borrow date' = '08/13/2016' } }),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'I should have only Argument(Sam) left as a friend'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'AfterFeature'),
(Hook 'AfterTestRun')


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
(Hook 'BeforeTestRun'),
(Hook 'BeforeFeature' -withContext @{ Name = 'f14'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenario' -withContext @{ Name = 's14'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'I have these friends' -tableArgument @{ Header = 'Friend Name', 'Age', 'Gender'; Rows = @{ 'Friend Name' = 'Sam'; 'Age' = '45'; 'Gender' = 'Male' }, @{ 'Friend Name' = 'Tom'; 'Age' = '18'; 'Gender' = 'Male' } } ),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'I borrow Argument(1923) dollars from' -tableArgument @{ Header = 'Friend Name', 'Borrow date'; Rows = ,@{ 'Friend Name' = 'Tom'; 'Borrow date' = '08/13/2016' } }),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'I should have only Argument(Sam) left as a friend'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'BeforeScenario' -withContext @{ Name = 's14'; Description = $Null; Tags = @() }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'I have these friends' -tableArgument @{ Header = 'Friend Name', 'Age', 'Gender'; Rows = @{ 'Friend Name' = 'Sam'; 'Age' = '45'; 'Gender' = 'Male' }, @{ 'Friend Name' = 'Tom'; 'Age' = '18'; 'Gender' = 'Male' } } ),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.When }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.When }),
(Step -when 'I borrow Argument(42) dollars from' -tableArgument @{ Header = 'Friend Name', 'Borrow date'; Rows = ,@{ 'Friend Name' = 'Sam'; 'Borrow date' = '08/13/2016' } }),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'I should have only Argument(Tom) left as a friend'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'AfterFeature'),
(Hook 'AfterTestRun')


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
(Hook 'BeforeTestRun'),
(Hook 'BeforeFeature' -withContext @{ Name = 'Inheriting Feature Tags In Scenarios'; Description = $Null; Tags = @('FeatureLevelTag') }),
(Hook 'BeforeScenario' -withContext @{ Name = 'Scenario without its own tags'; Description = $Null; Tags = @('FeatureLevelTag') }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'everything should be alright'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'BeforeScenario' -withContext @{ Name = 'Scenario with its own tag'; Description = $Null; Tags = @('FeatureLevelTag', 'ScenarioLevelTag') }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'everything should be alright'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'AfterFeature'),
(Hook 'AfterTestRun')


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
(Hook 'BeforeTestRun'),
(Hook 'BeforeFeature' -withContext @{ Name = ''; Description = $Null; Tags = @() }),
(Hook 'BeforeScenario' -withContext @{ Name = 'Scenario with tag-2'; Description = $Null; Tags = @('tag-2') }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Then }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Then }),
(Step -then 'everything should be alright'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'AfterFeature'),
(Hook 'AfterTestRun')


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
(Hook 'BeforeTestRun'),
(Hook 'BeforeFeature' -withContext @{ Name = ''; Description = $Null; Tags = @() }),
(Hook 'BeforeScenario' -withContext @{ Name = 'Scenario with tag-1'; Description = $Null; Tags = @('tag-1') }),
(Hook 'BeforeScenarioBlock' -withContext @{ BlockType = $StepTypeEnum.Given }),
(Hook 'BeforeStep' -withContext @{ StepType = $StepTypeEnum.Given }),
(Step -given 'Call me Argument(Ishmael)'),
(Hook 'AfterStep'),
(Hook 'AfterScenarioBlock'),
(Hook 'AfterScenario'),
(Hook 'AfterFeature'),
(Hook 'AfterTestRun')
