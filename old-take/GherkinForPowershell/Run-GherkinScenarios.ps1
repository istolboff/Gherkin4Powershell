param(
	[string] $featuresFolder		= $(throw "Invalid script invocation. Parameter 'featuresFolder' is required"), 
	[string] $stepDefinitionsFolder	= $(throw "Invalid script invocation. Parameter 'stepDefinitionsFolder' is required")
)

$ErrorActionPreference = "Stop"

trap { 
    if ($global:Error.Count -gt 0)
    {
		foreach ($record in @($global:Error[0]))
		{
			$record | Format-List * -Force
			$record.InvocationInfo | Format-List *
			$Exception = $record.Exception
			for ($i = 0; $Exception; $i++, ($Exception = $Exception.InnerException))
			{
				"$i" * 80
				$Exception | Format-List * -Force
			}
		}
    }

	throw $_.Exception; 
	exit 1; 
	continue 
}

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition

#------------------------- Miscellaneous -------------------------------

function Create-CustomObjectFromHashtable([hashtable] $source)
{
	$result = New-Object PSObject

	$source.GetEnumerator() | Foreach-Object {
		$memberType = switch ($_.Value -is [ScriptBlock]) { $True { 'ScriptMethod' } default { 'NoteProperty' } }
		$result = $result | Add-Member -MemberType $memberType -Name $_.Key -Value $_.Value -passThru
    }

	return $result
}

function Enumerable-Single($collectionDescription)
{
	begin 
	{ 
		[int] $elementsCount = 0
	}
	process 
	{
		$_
		$elementsCount++
	}
	end 
	{
		switch ($elementsCount)
		{
			0 { throw "Collection $collectionDescription is supposed to have exactly 1 item, but it is actually empty." }
			1 { }
			default { throw "Collection $collectionDescription is supposed to have exactly 1 item, but it actually contains $elementsCount elements." }
		}
	}
}

function Enumerable-Select($collection, [scriptblock] $indexedSelector)
{
	$result = @()
	$index = 0
	foreach ($item in $collection)
	{
		$result += & $indexedSelector $item $index
		$index += 1
	}

	return $result
}


#------------------------- Monadic parsing -------------------------------
# This is a Powershell way of doing "Monadic Parser Combinators" as described here 
# http://blogs.msdn.com/b/lukeh/archive/2007/08/19/monadic-parser-combinators-using-c-3-0.aspx

function New-ParsingResult($parsedEntity, $remainingInput)
{
	return @{ ParsedEntity = $parsedEntity; RemainingInput = $remainingInput }
}

function New-ParsingHistory
{
	Create-CustomObjectFromHashtable @{
		FarthestInput = $Null;

		ExpectedPattern = "";

		MatchingFailed = {
			param ($regex, $remainingInput)

			if ($this.CompareInputPositions($this.FarthestInput, $remainingInput) -lt 0)
			{
				$this.FarthestInput = $remainingInput
				$this.ExpectedPattern = $regex
			}
		};

		CompareInputPositions = {
			param ($inputPosition1, $inputPosition2)

			if ($inputPosition1 -eq $Null)
			{
				return -1
			}

			if ($inputPosition1.Line -eq $inputPosition2.Line -and $inputPosition1.Column -eq $inputPosition2.Column)
			{
				return 0
			}

			if ($inputPosition1.Line -lt $inputPosition2.Line)
			{
				return -1
			}

			if ($inputPosition1.Line -eq $inputPosition2.Line -and $inputPosition1.Column -lt $inputPosition2.Column)
			{
				return -1
			}

			return 1
		}
	}
}

function New-MonadicParser
{
	Create-CustomObjectFromHashtable @{
		ParsingHistory = New-ParsingHistory;

		Parse = {
			param ($grammar, $remainingInput)

			switch ($this.GetGrammarType($grammar))
			{
				'[array]' { return $this.ParseSubGrammarSequence($grammar, $remainingInput) }
				'[hashtable]' { return $this.ParseNamedSubgrammar($grammar, $remainingInput) }
				'[scriptblock]' { return $this.RunScriptBlockParser($grammar, $remainingInput) }
				'[regex]' { return $this.ParseRegEx($grammar, $remainingInput) }
				'[string]' { return $this.ParseToken($grammar, $remainingInput) }
				default { throw "Do not know how to parse with this object: $grammar of type $($grammar.GetType())" } 
			}
		};

		ParseSubGrammarSequence = {
			param ([array] $grammarCollection, $remainingInput)

			$parsedSequence = @()
			foreach ($grammar in $grammarCollection)
			{
				$parsingResult = $this.Parse($grammar, $remainingInput)
				if ($parsingResult -eq $Null)
				{
					return $Null
				}

				$parsedSequence += $parsingResult.ParsedEntity
				$remainingInput = $parsingResult.RemainingInput
			}

			return $this.WrapParsedSequence($parsedSequence, $remainingInput)
		};

		ParseNamedSubgrammar = {
			param ([hashtable] $namedGrammar, $remainingInput)

			$grammarName = $namedGrammar.Keys | Enumerable-Single "of sub-grammar $($namedGrammar) elements"

			$grammar = $namedGrammar.Get_Item($grammarName)
			$parsingResult = $this.Parse($grammar, $remainingInput)

			if ($parsingResult -eq $Null)
			{
				return $Null
			}

			$result = @{}
			$result.Set_Item($grammarName, $parsingResult.ParsedEntity)
			return New-ParsingResult -ParsedEntity $result -RemainingInput $parsingResult.RemainingInput
		};

		RunScriptBlockParser = {
			param ([scriptblock] $parser, $remainingInput)
			& $parser -monadicParser $this -remainingInput $remainingInput
		};

		ParseRegEx = {
			param ([regex] $regexGrammar, $remainingInput)

			$parsingResult = $remainingInput.MatchRegexp($regexGrammar)
			if ($parsingResult -eq $Null)
			{
				$this.ParsingHistory.MatchingFailed($regexGrammar, $remainingInput)
			}

			return $parsingResult 
		};

		ParseToken = {
			param ([string] $token, $remainingInput)

			$parsingResult = $remainingInput.MatchToken($token)
			if ($parsingResult -eq $Null)
			{
				$this.ParsingHistory.MatchingFailed($token, $remainingInput)
			}

			return $parsingResult 
		};

		WrapParsedSequence = {
			param ([array] $parsedSequence, $remainingInput)

			$resultAsHashtable = @{}
			$resultAsUnnamedObject = $Null

			foreach ($parsedElement in $parsedSequence)
			{
				if ($parsedElement -is [hashtable])
				{
					$resultAsHashtable += $parsedElement
				}
				else
				{
					$resultAsUnnamedObject = $parsedElement
				}
			}

			$parsedEntity = switch ($resultAsHashtable.Count) { 0 { $resultAsUnnamedObject } default { $resultAsHashtable } }
			return New-ParsingResult -ParsedEntity $parsedEntity -RemainingInput $remainingInput
		};

		GetGrammarType = {
			param ($grammar)

			if ($grammar -is [array])
			{
				return '[array]'
			}

			if ($grammar -is [hashtable])
			{
				return '[hashtable]'
			}

			if ($grammar -is [scriptblock])
			{
				return '[scriptblock]'
			}

			if ($grammar -is [regex])
			{
				return '[regex]'
			}

			if ($grammar -is [string])
			{
				return '[string]'
			}
            
			throw "Do not know how to parse with this object: $grammar of type $($grammar.GetType())"
		}
	}
}

function Constant($value)
{
	$functionNewParsingResultThatIsVisibleFromClosure = ${function:New-ParsingResult}
	return {
			param ($monadicParser, $remainingInput)
			& $functionNewParsingResultThatIsVisibleFromClosure -ParsedEntity $value -RemainingInput $remainingInput 
		}.GetNewClosure()
}

function Optional($grammar)
{
	$functionNewParsingResultThatIsVisibleFromClosure = ${function:New-ParsingResult}
	return {
			param ($monadicParser, $remainingInput)

			$parsingResult = $monadicParser.Parse($grammar, $remainingInput)
			if ($parsingResult -ne $Null)
			{
				return $parsingResult
			}
			
			return & $functionNewParsingResultThatIsVisibleFromClosure -ParsedEntity $Null -RemainingInput $remainingInput
		}.GetNewClosure()
}

function Repeated($grammar)
{
	$functionNewParsingResultThatIsVisibleFromClosure = ${function:New-ParsingResult}
	return {
			param ($monadicParser, $remainingInput)

			$parsedEntities = @()
			$currentInput = $remainingInput

			while ($True)
			{
				$parsingResult = $monadicParser.Parse($grammar, $currentInput)
				if ($parsingResult -eq $Null)
				{
					break;
				}

				$parsedEntities += $parsingResult.ParsedEntity
				$currentInput = $parsingResult.RemainingInput
			}

			switch ($parsedEntities.Length) { 
				0 { $Null } 
				default { & $functionNewParsingResultThatIsVisibleFromClosure -ParsedEntity @($parsedEntities) -RemainingInput $currentInput } }
		}.GetNewClosure()
}

function One-Of($alternatives)
{
	return {
			param ($monadicParser, $remainingInput)

			foreach($alternative in $alternatives)
			{
				$parsingResult = $monadicParser.Parse($alternative, $remainingInput)
				if ($parsingResult -ne $Null)
				{
					return $parsingResult
				}
			}

			return $Null
		}.GetNewClosure()
}

function Parse-Grammar($grammar, $remainingInput)
{
	$parser = New-MonadicParser
	$parsingResult = $parser.Parse($grammar, $remainingInput)
	switch ($parsingResult) { $Null { throw $parser.ParsingHistory } default { $parsingResult.ParsedEntity } }
}


#------------------------- Gherkin Keywords -------------------------------

function Append-ColonToKeywords([array] $keywords)
{
	$keywords | ForEach-Object { $_ + ':' }
}

function New-GherkinKeywords($languagesXmlPath, $cultureName = 'ru')
{
	[xml] $languages = Get-Content $languagesXmlPath
	$localization = $languages.SpecFlowLanguages.Language | Where-Object { $_.cultureInfo -eq $cultureName }
	$allKeywords = (Append-ColonToKeywords $localization.Feature) + `
				   (Append-ColonToKeywords $localization.Background) + `
				   (Append-ColonToKeywords $localization.Scenario) + `
				   (Append-ColonToKeywords $localization.ScenarioOutline) + `
				   (Append-ColonToKeywords $localization.Examples) + `
				   $localization.Given + `
				   $localization.When + `
				   $localization.Then + `
				   $localization.And + `
				   $localization.But

	return @{ 
		Keywords = $allKeywords;
		Feature = $localization.Feature; 
		Background = $localization.Background; 
		Scenario = $localization.Scenario; 
		ScenarioOutline = $localization.ScenarioOutline; 
		Examples = $localization.Examples; 
		Given = $localization.Given; 
		When = $localization.When; 
		Then = $localization.Then; 
		And = $localization.And; 
		But = $localization.But
		}
}


#------------------------- Gherkin Script Stream and Input Position -------

function New-GherkinScriptLine([string] $line, [int] $lineIndex, $keywords)
{
	foreach ($keyword in $keywords)
	{
		$lineStartsWithKeyword = $line -match "^\s*$keyword\s"
		if ($lineStartsWithKeyword)
		{
			return Create-CustomObjectFromHashtable @{
				_line = $line;
				_lineIndex = $lineIndex;

				GetTail = {
					param ([int] $columnIndex)
					return $this._line.Substring($columnIndex)
				}
			}
		}
	}

	return $Null
}

function New-GherkinStream($content, $gherkinKeywords)
{
	$scriptLinesWithIndexes = Enumerable-Select `
		-collection $content `
		-indexedSelector { 
			param ($item, $index) 

			New-GherkinScriptLine -line $item -lineIndex $index -keywords $gherkinKeywords
		} 

	$nonEmptyScriptLines = @($scriptLinesWithIndexes | Where-Object { $_ -ne $Null })

	Create-CustomObjectFromHashtable @{ 
		_scriptLines = $nonEmptyScriptLines;

		LinesCount = $nonEmptyScriptLines.Length

		GetLineTail = {
			param ([int] $lineIndex, [int] $columnIndex)

			return $this._scriptLines[$lineIndex].GetTail($columnIndex)
		}
	}
}

function New-GherkinInputPosition($gherkinStream, [int] $currentLine, [int] $currentColumn)
{
	Create-CustomObjectFromHashtable @{ 
		_content = $gherkinStream; 

		_currentLineRemaining = $gherkinStream.GetLineTail($currentLine, $currentColumn)

		Line = $currentLine; 

		Column = $currentColumn; 

		MatchToken = {
			param ([string] $token)

			$trimmedCurrentLineRemaining = $this._currentLineRemaining.TrimStart()
			if (-Not $trimmedCurrentLineRemaining.StartsWith($token))
			{
				return $Null
			}

			return $this.MakeMatchingResult($token, $this._currentLineRemaining.Length - $trimmedCurrentLineRemaining.Length + $token.Length)
		};

		MatchRegexp = {
			param ([regex] $regexGrammar)

			if (-Not ($this._currentLineRemaining -match $regexGrammar))
			{
				return $Null
			}

			return $this.MakeMatchingResult($Matches[0], $Matches[0].Length)
		}

		MakeMatchingResult = {
			param ([string] $match, $matchLength)

			$matchEatsUpTheRestOfCurrentString = $matchLength -ge $this._currentLineRemaining.Length

			if (-Not $matchEatsUpTheRestOfCurrentString)
			{
				$newCurrentLine = $this.Line
				$newCurrentColumn = $this.Column + $matchLength
			}
			else
			{
				$thereRemainUnreadLines = $this.Line + 1 -lt $this._content.LinesCount

				if ($thereRemainUnreadLines)
				{
					$newCurrentLine = $this.Line + 1 
					$newCurrentColumn = 0
				}
				else
				{
					$newCurrentLine = $this.Line 
					$newCurrentColumn = $this.Column + $this._currentLineRemaining.Length
				}
			}

			$remainingInput = New-GherkinInputPosition -gherkinStream $this._content -currentLine $newCurrentLine -currentColumn $newCurrentColumn
			return New-ParsingResult -ParsedEntity $match -RemainingInput $remainingInput
		};
	}
}


#------------------------- Gherkin Grammar --------------------------------

function New-GherkinGrammar($gherkinKeywords)
{
	[regex] $spaces = '\s+'

	$rules = @{}
	$rules += @{ Givens			= (One-Of $gherkinKeywords.Given), $spaces, (Constant 'Given') }
	$rules += @{ Whens			= (One-Of $gherkinKeywords.When),  $spaces, (Constant 'When')  }
	$rules += @{ Thens			= (One-Of $gherkinKeywords.Then),  $spaces, (Constant 'Then')  }
	$rules += @{ Ands			= (One-Of $gherkinKeywords.And),   $spaces, (Constant 'And')   }
	$rules += @{ Buts			= (One-Of $gherkinKeywords.But),   $spaces, (Constant 'But')   }
	$rules += @{ Phrase			= [regex] '(.*)$' }
	$rules += @{ StepType		= One-Of $rules.Givens, $rules.Whens, $rules.Thens, $rules.Ands, $rules.Buts }
	$rules += @{ SingleStep		= @{ StepType = $rules.StepType }, @{ Phrase = $rules.Phrase } }
	$rules += @{ TableRow		= '|', (Repeated [regex] '([^|]*)|') }
	$rules += @{ ScenarioBody	= Repeated (One-Of $rules.SingleStep, $rules.TableRow) }
	$rules += @{ Background		= (One-Of $gherkinKeywords.Background), (Optional $rules.Phrase), @{ Steps = $rules.ScenarioBody } }
	$rules += @{ SingleScenario	= (One-Of $gherkinKeywords.Scenario), @{ Title = $rules.Phrase }, @{ Steps = $rules.ScenarioBody } }
	$rules += @{ ScenarioOutline= (One-Of $gherkinKeywords.ScenarioOutline), @{ Title = $rules.Phrase }, @{ Steps = $rules.ScenarioBody }, (One-Of $gherkinKeywords.Examples), @{ Examples = Repeated $rules.TableRow } }
	$rules += @{ Feature		= (One-Of $gherkinKeywords.Feature), @{ Title = $rules.Phrase }, @{ Background = Optional $rules.Background }, @{ Scenarios = (Repeated (One-Of $rules.SingleScenario, $rules.ScenarioOutline)) } }
	return $rules 
}

#------------------------- Expanding Scenario Outlines -------------------

filter Expand-ScenarioOutlines 
{
	$_
}

#------------------------- Binding Scenario steps to Step Definitions -------------------

function New-StepDefinitionRegistry($stepTypeName)
{
	Create-CustomObjectFromHashtable @{ 
		_stepTypeName = $stepTypeName;

		_stepDefinitions = @{};

		RegisterStepDefinition = {
			param ([regex] $stepPattern, [scriptblock] $stepDefinitionScript)

			$fullLineStepPattern = $this.EnsureRegexMatchesFullLineOnly($stepPattern)
			if ($this._stepDefinitions.ContainsKey($fullLineStepPattern))
			{
				throw "Duplicate $($this._stepTypeName) pattern $stepPattern found"
			}

			$this._stepDefinitions.Add($fullLineStepPattern, $stepDefinitionScript)

			Write-Host "Added $($this._stepTypeName) '$($stepPattern.ToString())' { $($stepDefinitionScript.ToString()) }"
		};

		LocateAppropriateStepDefinition = {
			param ([string] $phrase)

			$appropriateStepDefinition = `
				$this._stepDefinitions.GetEnumerator() | `
				Where-Object { $phrase.Trim() -match $_.Name } | `
				Enumerable-Single "of [$($this._stepTypeName)] step definitions that would match phrase [$phrase]" 

			@{ StepScript = $appropriateStepDefinition.Value ; ParsedArguments = @($Matches.Values)[1, $Matches.Values.Length]; }
		}


		EnsureRegexMatchesFullLineOnly = {
			param ([regex] $pattern)

			$patternText = $pattern.ToString()
			$hasStartSign = $patternText.StartsWith('^')
			$hasEndSign = $patternText.EndsWith('$')
			if ($hasStartSign -and $hasEndSign)
			{
				return $pattern
			}

			if (-Not $hasStartSign)
			{
				$patternText = "^$patternText"
			}

			if (-Not $hasEndSign)
			{
				$patternText = "$patternText$"
			}

			[regex]$patternText
		}
	}
}

$KnownStepDefinitions = @{ 
	Given = New-StepDefinitionRegistry 'Given'; 
	When  = New-StepDefinitionRegistry 'When'; 
	Then  = New-StepDefinitionRegistry 'Then'
}

function Given
{
	[CmdletBinding()]
	param (
		[parameter(Mandatory=$true)]
		[regex] $phrasePattern,
		[parameter(Mandatory=$true)]
		[scriptblock] $stepDefinitionCode
	)

	$KnownStepDefinitions.Given.RegisterStepDefinition($phrasePattern, $stepDefinitionCode)
}

function When
{
	[CmdletBinding()]
	param (
		[parameter(Mandatory=$true)]
		[regex] $phrasePattern,
		[parameter(Mandatory=$true)]
		[scriptblock] $stepDefinitionCode
	)

	$KnownStepDefinitions.When.RegisterStepDefinition($phrasePattern, $stepDefinitionCode)
}

function Then
{
	[CmdletBinding()]
	param (
		[parameter(Mandatory=$true)]
		[regex] $phrasePattern,
		[parameter(Mandatory=$true)]
		[scriptblock] $stepDefinitionCode
	)

	$KnownStepDefinitions.Then.RegisterStepDefinition($phrasePattern, $stepDefinitionCode)
}

#------------------------- Resolving Scenario steps to Step Definitions -------------------

function Resolve-ScenarioStep
{
	begin
	{
		$lastResolvedStepDefinitionsType = $Null
	}
	process
	{
		$currentStepType = $_.StepType
		if ((($currentStepType -eq 'And') -or ($currentStepType -eq 'But')))
		{
			if ($lastResolvedStepDefinitionsType -eq $Null)
			{
				throw "unexpected $currentStepType $_.Phrase, it should be preceeded with 'Given', 'When', or 'Then'"
			}

			$currentStepType = $lastResolvedStepDefinitionsType
		}
		else
		{
			$lastResolvedStepDefinitionsType = $currentStepType
		}

		$appropriateStepDefinition = $KnownStepDefinitions.Get_Item($currentStepType).LocateAppropriateStepDefinition($_.Phrase)

		Create-CustomObjectFromHashtable @{ 
			_scriptBlock = $appropriateStepDefinition.StepScript;

			_arguments = $appropriateStepDefinition.ParsedArguments;

			Run = {
				 Invoke-Command -ScriptBlock $this._scriptBlock -ArgumentList $this._arguments
			}
		}
	}
	end
	{
	}
}

filter Resolve-SingleScenario
{
	@{ Title = $_.Title; Steps = $_.Steps | Resolve-ScenarioStep }
}

filter Resolve-FeatureScenarios
{
	$resolvedBackgroundSteps = $Null 
	if ($_.Background -ne $Null)
	{
		$resolvedBackgroundSteps = $_.Background.Steps | Resolve-ScenarioStep 
	}

	$resolvedScenarios = $_.Scenarios | Resolve-SingleScenario
	@{ Title = $_.Title; BackgroundSteps = $resolvedBackgroundSteps; Scenarios = $resolvedScenarios }
}


#------------------------- Hooks -------------------------

function Setup-TestRun 
{
}

function Teardown-TestRun
{
}


#------------------------- Scenario Execution -------------------------

function Run-ScenarioStep
{
	process
	{
		$_.Run()
	}
}

function Run-ScenarioSteps($scenarioTitle, $backgroundSteps)
{
	begin
	{
		Setup-Scenario $scenarioTitle
		$backgroundSteps | Run-ScenarioStep
	}
	process
	{
		$_.Steps | Run-ScenarioStep
	}
	end
	{
		Teardown-Scenario $scenarioTitle
	}
}

function Run-Scenario($featureTitle, $backgroundSteps)
{
	begin 
	{
		Setup-Feature $featureTitle
	}
	process 
	{
		$_.Steps | Run-ScenarioSteps -scenarioTitle $_.Title -backgroundSteps $backgroundSteps
	}
	end
	{
		Teardown-Feature $featureTitle
	}
}


function Run-FeatureScenarios
{
	begin 
	{ 
		Setup-TestRun 
	}
	process 
	{
		 $_.Scenarios | Run-Scenario -featureTitle $_.Title -backgroundSteps $_.BackgroundSteps
	}
	end 
	{
		Teardown-TestRun
	}
}


#------------------------- Main script --------------------------------

function Main([string] $featuresFolder, [string] $stepDefinitionsFolder)
{
    $gherkinLanguagesXmlPath = Join-Path -Path $scriptPath -ChildPath 'GherkinLanguages.xml'
    $gherkinKeywords = New-GherkinKeywords $gherkinLanguagesXmlPath
    $gherkinGrammar = New-GherkinGrammar $gherkinKeywords

    $features = `
    	Get-ChildItem (Join-Path -Path $featuresFolder -ChildPath *.feature) | `
    	ForEach-Object { New-GherkinStream -content (Get-Content $_) -gherkinKeywords $gherkinKeywords.Keywords } | `
    	ForEach-Object { New-GherkinInputPosition -gherkinStream $_ -currentLine 0 -currentColumn 0 } | `
    	ForEach-Object { Parse-Grammar -grammar $gherkinGrammar.Feature -remainingInput $_ }

	Get-ChildItem (Join-Path -Path $stepDefinitionsFolder -ChildPath *.ps1) | `
	ForEach-Object { 
		"Loading step definition script from $_"
		. $_ 
		"Script loaded"
	}

	$features | Expand-ScenarioOutlines | Resolve-FeatureScenarios | Run-FeatureScenarios
}

Main -featuresFolder $featuresFolder -stepDefinitionsFolder $stepDefinitionsFolder