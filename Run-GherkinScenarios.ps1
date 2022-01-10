param (
    [string] $scenarios,
	[string] $stepDefinitions = $null,
    [string] $tags = $Null,
    [string] $cultureName = 'en',
    [string] $logParsingToFile = $Null,
    [string] $logTestRunningToFile = $Null,
	[switch] $failFast,
    [switch] $doNotCleanupGherkinRunningInfrastructure,
    [switch] $showCurrentStepInConsoleTitle,
    [switch] $formatResultsToTable)

. (Join-Path -Path $PSScriptRoot -ChildPath 'Define-GherkinHooksApi.ps1')

trap {
    if ($global:Error.Count -gt 0)
    {
        foreach ($record in @($global:Error[0]))
        {
            $errorDescription = Describe-ErrorRecord -errorRecord $record
            if ($failFast)
            {
                Log-TestRunning -message $errorDescription
            }

            $errorDescription | Out-Host
        }
    }

    exit 1;
    continue
}

#region Miscellaneous
function Validate($parameters)
{
    foreach ($parameter in $parameters)
    {
        $parameterName = $parameter
        $parameterValue = & $parameter
        Verify-That -condition $(-Not [String]::IsNullOrEmpty($parameterValue)) -message "Parameter $parameterName is not specified."
    }
}

filter Except-Nulls
{
    if ($_ -ne $Null)
    {
        $_
    }
}

filter Trim-String
{
    switch ($_) { $Null { [string]::Empty } default { $_.Trim() } }
}

function True-ForAll([array] $items, [scriptblock] $condition)
{
    foreach ($item in $items)
    {
        [bool] $ok = & $condition $item
        if (-not $ok)
        {
            return $false
        }
    }

    $true
}

function Split-AndProject([array] $items, [scriptblock] $isSplitter, [scriptblock] $projectGroup)
{
    if ($null -eq $items -or $items.Length -eq 0)
    {
        return @()
    }

    $splittersIndexes = @(0..($items.Length - 1) | Where-Object { & $isSplitter $items[$_] })
    if ($splittersIndexes.Length -eq 0)
    {
        return & $projectGroup $items # since we have no splitters, then all items belong to a single group
    }

    $splittersIndexes += $items.Length

    $currentGroupStart = 0
    @($splittersIndexes | `
        ForEach-Object {
            $currentGroupEnd = $_
            if ($currentGroupStart -lt $currentGroupEnd)
            {
                & $projectGroup @($items[$currentGroupStart..($currentGroupEnd - 1)])
            }

            $currentGroupStart = $currentGroupEnd + 1
        } | `
        Where-Object { $null -ne $_ })
}

function Log-Parsing($message)
{
    if (-Not [string]::IsNullOrEmpty($logParsingToFile))
    {
        $message | Out-File -FilePath $logParsingToFile -Append
    }
}

function List-Files($fileSet)
{
	$resolvedPath = Resolve-Path $fileSet
    if ([System.IO.File]::Exists($resolvedPath))
    {
        return @($resolvedPath)
    }

    if ([System.IO.Directory]::Exists($resolvedPath))
    {
        return @(Get-ChildItem $resolvedPath -Recurse | Where-Object { $_ -is [System.IO.FileInfo] } | ForEach-Object { $_.FullName })
    }

    $folderPath = Split-Path -Path $resolvedPath -Parent
    $filter =  Split-Path -Path $resolvedPath -Leaf
    return @(Get-ChildItem -Path $folderPath -Filter $filter | Where-Object { $_ -is [System.IO.FileInfo] })
}
#endregion

class FeatureFileContent
{
    [string[]] hidden   $TextLines
    [int] hidden        $CurrentLineNumber
    [int] hidden        $OffsetInCurrentLine

    FeatureFileContent([string[]] $textLines, [int] $currentLineNumber, [int] $offsetInCurrentLine)
    {
        Verify-That -condition ($currentLineNumber -lt $textLines.Length) -message 'Attempt to read past the end of file'
        $this.TextLines = $textLines
        $this.CurrentLineNumber = $currentLineNumber
        $this.OffsetInCurrentLine = $offsetInCurrentLine
    }

    [FeatureFileContent] Skip([int] $characterCount)
    {
        return [FeatureFileContent]::new($this.TextLines, $this.CurrentLineNumber, $this.OffsetInCurrentLine + $characterCount)
    }

    [bool] CurrentLineContainsNonSpaceCharacters()
    {
        $currentLineChars = $this.TextLines[$this.CurrentLineNumber]
        return $currentLineChars.Substring($this.OffsetInCurrentLine).Trim().Length -gt 0
    }

    [FeatureFileContent] GetNextLine()
    {
        function Get-IndexOfFirstNonSpaceCharacter($lineChars)
        {
            if (-not ($lineChars -match '^\s*#.*$'))
            {
                $matchingResult = ([regex]'\S').Match($lineChars)
                switch ($matchingResult.Success) { $False { $Null } $True { $matchingResult.Index } }
            }
        }

        for ($nextLineIndex = $this.CurrentLineNumber + 1; $nextLineIndex -lt $this.TextLines.Length; $nextLineIndex++)
        {
            $lineChars = $this.TextLines[$nextLineIndex]
            $offset = Get-IndexOfFirstNonSpaceCharacter $lineChars
            if ($Null -ne $offset)
            {
                return [FeatureFileContent]::new($this.TextLines, $nextLineIndex, $offset)
            }
        }

        return $Null
    }
}

class ParsingResult
{
    [object] $Value

    [FeatureFileContent] $Rest

    ParsingResult([object] $value, [FeatureFileContent] $rest)
    {
        $this.Value = $value
        $this.Rest = $rest
    }
}

#region Monadic Parsing
class MonadicParsing
{
    static [ParsingResult] ParseWith($parser, [FeatureFileContent] $content)
    {
        switch ($null)
        {
            { $parser -is [scriptblock] } {
                return & $parser $content
            }
            { $parser -is [string] } {
                $patternLength = $parser.Length
                $currentLineChars = $content.TextLines[$content.CurrentLineNumber]
                if ([String]::Compare($currentLineChars, $content.OffsetInCurrentLine, $parser, 0, $patternLength) -ne 0)
                {
                    Log-Parsing "Literal [$parser] failed on line $currentLineChars at offset $($content.OffsetInCurrentLine)"
                    return $Null
                }

                Log-Parsing "Literal [$parser] matched on line $currentLineChars at offset $($content.OffsetInCurrentLine)"
                return [ParsingResult]::new($parser, $content.Skip($patternLength))
            }
            { $parser -is [regex] } {
                $currentLineChars = $content.TextLines[$content.CurrentLineNumber]
                $matchingResult = $parser.Match($currentLineChars, $content.OffsetInCurrentLine)
                if (-Not $matchingResult.Success -or ($matchingResult.Index -ne $content.OffsetInCurrentLine))
                {
                    Log-Parsing "Regex [$parser] failed on line $currentLineChars at offset $($content.OffsetInCurrentLine)"
                    return $Null
                }

                $parsedValue = $matchingResult.Groups[1].Value
                Log-Parsing "Regex [$parser] matched on line $($currentLineChars) at offset $($content.OffsetInCurrentLine), length=$($matchingResult.Length). Match result: $parsedValue"
                return [ParsingResult]::new($parsedValue, $content.Skip($matchingResult.Length))
            }
            { $parser -is [array] } {
                Verify-That -condition ($parser.Length -gt 0) -message 'Program logic error: trying to parse content with an empty array of parsers'
                [ParsingResult] $parsingResult = $null
                foreach ($nextParser in $parser)
                {
                    $parsingResult = [MonadicParsing]::ParseWith($nextParser, $content)
                    if ($Null -eq $parsingResult)
                    {
                        return $Null
                    }

                    $content = $parsingResult.Rest
                }

                return $parsingResult
            }
        }

        throw "Do not know how to parse with $parser of type $($parser.GetType())"
    }
}

function Optional([ValidateNotNullOrEmpty()] $parser, $orElse = $null)
{
    return {
        param ([FeatureFileContent] $content)
        switch ($parsingResult = [MonadicParsing]::ParseWith($parser, $content))
        {
            $null  { [ParsingResult]::new($orElse, $content) }
            default { $parsingResult }
        }
    }.GetNewClosure()
}

function Repeat([ValidateNotNullOrEmpty()]$parser, [switch] $allowZeroRepetition)
{
    return {
        param ([FeatureFileContent] $content)

        $values = @()

        $restOfContent = $content
        while ($True)
        {
            $parsingResult = [MonadicParsing]::ParseWith($parser, $restOfContent)
            if ($Null -eq $parsingResult)
            {
                if (-Not $allowZeroRepetition -and $values.Length -eq 0)
                {
                    return $Null
                }

                return [ParsingResult]::new($values, $restOfContent)
            }

            if ($parsingResult.Value -is [array])
            {
                $values += , $parsingResult.Value
            }
            else
            {
                $values += $parsingResult.Value
            }

            $restOfContent = $parsingResult.Rest
        }
    }.GetNewClosure()
}

function One-Of([array] $parsers)
{
    $parsers | ForEach-Object { Verify-That -condition ($_ -ne $Null) -message 'Program logic error: One-Of(...$Null...)' }

    return {
        param ([FeatureFileContent] $content)

        foreach ($parserAlternative in $parsers)
        {
            $parsingResult = [MonadicParsing]::ParseWith($parserAlternative, $content)
            if ($Null -ne $parsingResult)
            {
                return $parsingResult
            }
        }

        return $Null
    }.GetNewClosure()
}

function Anything-But([ValidateNotNullOrEmpty()] $parser)
{
    return {
        param ([FeatureFileContent] $content)

        $parsingResult = [MonadicParsing]::ParseWith($parser, $content)
        if ($Null -ne $parsingResult)
        {
            return $Null
        }

        return [ParsingResult]::new($True, $content)
    }.GetNewClosure()
}
#endregion

#region Parsing single line of text
function Complete-Line([ValidateNotNullOrEmpty()] $parser)
{
    return {
            param ([FeatureFileContent] $content)

            $nextLine = $content.GetNextLine()
            if ($Null -eq $nextLine)
            {
                return $Null
            }

            $parsingResult = [MonadicParsing]::ParseWith($parser, $nextLine)
            if ($Null -eq $parsingResult) # unrecognized pattern
            {
                return $Null
            }

            # If $parser matched the beginning of the line, but there still remain some unrecognized characters
            if ($parsingResult.Rest.CurrentLineContainsNonSpaceCharacters())
            {
                return $Null
            }

            return $parsingResult
        }.GetNewClosure()
}

function EndOfContent
{
    return {
        param ([FeatureFileContent] $content)

        while ($True)
        {
            $nextLine = $content.GetNextLine()
            if ($Null -eq $nextLine)
            {
                return [ParsingResult]::new($True, $content)
            }

            if ($nextLine.CurrentLineContainsNonSpaceCharacters())
            {
                return $Null
            }

            $content = $nextLine
        }
    }.GetNewClosure()
}
#endregion

#region Linq-like expressions
function From-Parser
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True, Position=0)]
        [string][ValidateNotNullOrEmpty()]$parsingResultName,

        [Parameter(Mandatory=$true, Position=1)]
        [string][ValidateSet('in')]$textIn,

        [Parameter(Mandatory=$true, Position=2)]
        [object][ValidateNotNullOrEmpty()]$parser)

    $captured_LogParsing_Function = ${function:Log-Parsing}

    return {
        param ([FeatureFileContent] $content)

        $parsingResult = [MonadicParsing]::ParseWith($parser, $content)
        if ($Null -ne $parsingResult)
        {
            Set-Variable -Name $parsingResultName -Value $parsingResult.Value -Scope 2
            & $captured_LogParsing_Function "from_ $parsingResultName => $($parsingResult.Value)"
        }

        return $parsingResult
    }.GetNewClosure()
}
Set-Alias from_ From-Parser

function Restrict-ParsedValue
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True, Position=0)]
        [scriptblock][ValidateNotNullOrEmpty()]$parsedValueChecker)

    return  {
        param ([FeatureFileContent] $content)
        switch (& $parsedValueChecker) { $false { $null } default { [ParsingResult]::new($true, $content) } }
    }.GetNewClosure()
}

Set-Alias where_ Restrict-ParsedValue

function Select-ParsedValue
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True, Position=0)]
        [scriptblock][ValidateNotNullOrEmpty()]$parsedValueProducer)

    return {
        param ([FeatureFileContent] $content)
        # by now, all variables calculated in previous 'from_' invocations should be accessible in this scope, so $parsedValueProducer can do its job
        $calculatedValue = & $parsedValueProducer
        return [ParsingResult]::new($calculatedValue, $content)
    }.GetNewClosure()
}
Set-Alias select_ Select-ParsedValue
#endregion

#region Gherkin Keywords in different languages
function Build-GherkinKeywordParsers($cultureName)
{
    $allGherkinKeywords = @{
        'af' = @{ And = "*","En"; Background = "Agtergrond"; But = "*","Maar"; Examples = "Voorbeelde"; Feature = "Funksie","Besigheid Behoefte","Vermoë"; Given = "*","Gegewe"; Name = "Afrikaans"; Native = "Afrikaans"; Rule = "Rule"; Scenario = "Voorbeeld","Situasie"; ScenarioOutline = "Situasie Uiteensetting"; Then = "*","Dan"; When = "*","Wanneer" };
        'am' = @{ And = "*","Եվ"; Background = "Կոնտեքստ"; But = "*","Բայց"; Examples = "Օրինակներ"; Feature = "Ֆունկցիոնալություն","Հատկություն"; Given = "*","Դիցուք"; Name = "Armenian"; Native = "հայերեն"; Rule = "Rule"; Scenario = "Օրինակ","Սցենար"; ScenarioOutline = "Սցենարի կառուցվացքը"; Then = "*","Ապա"; When = "*","Եթե","Երբ" };
        'an' = @{ And = "*","Y","E"; Background = "Antecedents"; But = "*","Pero"; Examples = "Eixemplos"; Feature = "Caracteristica"; Given = "*","Dau","Dada","Daus","Dadas"; Name = "Aragonese"; Native = "Aragonés"; Rule = "Rule"; Scenario = "Eixemplo","Caso"; ScenarioOutline = "Esquema del caso"; Then = "*","Alavez","Allora","Antonces"; When = "*","Cuan" };
        'ar' = @{ And = "*","و"; Background = "الخلفية"; But = "*","لكن"; Examples = "امثلة"; Feature = "خاصية"; Given = "*","بفرض"; Name = "Arabic"; Native = "العربية"; Rule = "Rule"; Scenario = "مثال","سيناريو"; ScenarioOutline = "سيناريو مخطط"; Then = "*","اذاً","ثم"; When = "*","متى","عندما" };
        'ast' = @{ And = "*","Y","Ya"; Background = "Antecedentes"; But = "*","Peru"; Examples = "Exemplos"; Feature = "Carauterística"; Given = "*","Dáu","Dada","Daos","Daes"; Name = "Asturian"; Native = "asturianu"; Rule = "Rule"; Scenario = "Exemplo","Casu"; ScenarioOutline = "Esbozu del casu"; Then = "*","Entós"; When = "*","Cuando" };
        'az' = @{ And = "*","Və","Həm"; Background = "Keçmiş","Kontekst"; But = "*","Amma","Ancaq"; Examples = "Nümunələr"; Feature = "Özəllik"; Given = "*","Tutaq ki","Verilir"; Name = "Azerbaijani"; Native = "Azərbaycanca"; Rule = "Rule"; Scenario = "Nümunə","Ssenari"; ScenarioOutline = "Ssenarinin strukturu"; Then = "*","O halda"; When = "*","Əgər","Nə vaxt ki" };
        'bg' = @{ And = "*","И"; Background = "Предистория"; But = "*","Но"; Examples = "Примери"; Feature = "Функционалност"; Given = "*","Дадено"; Name = "Bulgarian"; Native = "български"; Rule = "Rule"; Scenario = "Пример","Сценарий"; ScenarioOutline = "Рамка на сценарий"; Then = "*","То"; When = "*","Когато" };
        'bm' = @{ And = "*","Dan"; Background = "Latar Belakang"; But = "*","Tetapi","Tapi"; Examples = "Contoh"; Feature = "Fungsi"; Given = "*","Diberi","Bagi"; Name = "Malay"; Native = "Bahasa Melayu"; Rule = "Rule"; Scenario = "Senario","Situasi","Keadaan"; ScenarioOutline = "Kerangka Senario","Kerangka Situasi","Kerangka Keadaan","Garis Panduan Senario"; Then = "*","Maka","Kemudian"; When = "*","Apabila" };
        'bs' = @{ And = "*","I","A"; Background = "Pozadina"; But = "*","Ali"; Examples = "Primjeri"; Feature = "Karakteristika"; Given = "*","Dato"; Name = "Bosnian"; Native = "Bosanski"; Rule = "Rule"; Scenario = "Primjer","Scenariju","Scenario"; ScenarioOutline = "Scenariju-obris","Scenario-outline"; Then = "*","Zatim"; When = "*","Kada" };
        'ca' = @{ And = "*","I"; Background = "Rerefons","Antecedents"; But = "*","Però"; Examples = "Exemples"; Feature = "Característica","Funcionalitat"; Given = "*","Donat","Donada","Atès","Atesa"; Name = "Catalan"; Native = "català"; Rule = "Rule"; Scenario = "Exemple","Escenari"; ScenarioOutline = "Esquema de l'escenari"; Then = "*","Aleshores","Cal"; When = "*","Quan" };
        'cs' = @{ And = "*","A také","A"; Background = "Pozadí","Kontext"; But = "*","Ale"; Examples = "Příklady"; Feature = "Požadavek"; Given = "*","Pokud","Za předpokladu"; Name = "Czech"; Native = "Česky"; Rule = "Rule"; Scenario = "Příklad","Scénář"; ScenarioOutline = "Náčrt Scénáře","Osnova scénáře"; Then = "*","Pak"; When = "*","Když" };
        'cy-GB' = @{ And = "*","A"; Background = "Cefndir"; But = "*","Ond"; Examples = "Enghreifftiau"; Feature = "Arwedd"; Given = "*","Anrhegedig a"; Name = "Welsh"; Native = "Cymraeg"; Rule = "Rule"; Scenario = "Enghraifft","Scenario"; ScenarioOutline = "Scenario Amlinellol"; Then = "*","Yna"; When = "*","Pryd" };
        'da' = @{ And = "*","Og"; Background = "Baggrund"; But = "*","Men"; Examples = "Eksempler"; Feature = "Egenskab"; Given = "*","Givet"; Name = "Danish"; Native = "dansk"; Rule = "Rule"; Scenario = "Eksempel","Scenarie"; ScenarioOutline = "Abstrakt Scenario"; Then = "*","Så"; When = "*","Når" };
        'de' = @{ And = "*","Und"; Background = "Grundlage","Hintergrund","Voraussetzungen","Vorbedingungen"; But = "*","Aber"; Examples = "Beispiele"; Feature = "Funktionalität","Funktion"; Given = "*","Angenommen","Gegeben sei","Gegeben seien"; Name = "German"; Native = "Deutsch"; Rule = "Rule","Regel"; Scenario = "Beispiel","Szenario"; ScenarioOutline = "Szenariogrundriss","Szenarien"; Then = "*","Dann"; When = "*","Wenn" };
        'el' = @{ And = "*","Και"; Background = "Υπόβαθρο"; But = "*","Αλλά"; Examples = "Παραδείγματα","Σενάρια"; Feature = "Δυνατότητα","Λειτουργία"; Given = "*","Δεδομένου"; Name = "Greek"; Native = "Ελληνικά"; Rule = "Rule"; Scenario = "Παράδειγμα","Σενάριο"; ScenarioOutline = "Περιγραφή Σεναρίου","Περίγραμμα Σεναρίου"; Then = "*","Τότε"; When = "*","Όταν" };
        'em' = @{ And = "*","😂"; Background = "💤"; But = "*","😔"; Examples = "📓"; Feature = "📚"; Given = "*","😐"; Name = "Emoji"; Native = "😀"; Rule = "Rule"; Scenario = "🥒","📕"; ScenarioOutline = "📖"; Then = "*","🙏"; When = "*","🎬" };
        'en' = @{ And = "*","And"; Background = "Background"; But = "*","But"; Examples = "Examples","Scenarios"; Feature = "Feature","Business Need","Ability"; Given = "*","Given"; Name = "English"; Native = "English"; Rule = "Rule"; Scenario = "Example","Scenario"; ScenarioOutline = "Scenario Outline","Scenario Template"; Then = "*","Then"; When = "*","When" };
        'en-au' = @{ And = "*","Too right"; Background = "First off"; But = "*","Yeah nah"; Examples = "You'll wanna"; Feature = "Pretty much"; Given = "*","Y'know"; Name = "Australian"; Native = "Australian"; Rule = "Rule"; Scenario = "Awww, look mate"; ScenarioOutline = "Reckon it's like"; Then = "*","But at the end of the day I reckon"; When = "*","It's just unbelievable" };
        'en-lol' = @{ And = "*","AN"; Background = "B4"; But = "*","BUT"; Examples = "EXAMPLZ"; Feature = "OH HAI"; Given = "*","I CAN HAZ"; Name = "LOLCAT"; Native = "LOLCAT"; Rule = "Rule"; Scenario = "MISHUN"; ScenarioOutline = "MISHUN SRSLY"; Then = "*","DEN"; When = "*","WEN" };
        'en-old' = @{ And = "*","Ond","7"; Background = "Aer","Ær"; But = "*","Ac"; Examples = "Se the","Se þe","Se ðe"; Feature = "Hwaet","Hwæt"; Given = "*","Thurh","Þurh","Ðurh"; Name = "Old English"; Native = "Englisc"; Rule = "Rule"; Scenario = "Swa"; ScenarioOutline = "Swa hwaer swa","Swa hwær swa"; Then = "*","Tha","Þa","Ða","Tha the","Þa þe","Ða ðe"; When = "*","Tha","Þa","Ða" };
        'en-pirate' = @{ And = "*","Aye"; Background = "Yo-ho-ho"; But = "*","Avast!"; Examples = "Dead men tell no tales"; Feature = "Ahoy matey!"; Given = "*","Gangway!"; Name = "Pirate"; Native = "Pirate"; Rule = "Rule"; Scenario = "Heave to"; ScenarioOutline = "Shiver me timbers"; Then = "*","Let go and haul"; When = "*","Blimey!" };
        'en-Scouse' = @{ And = "*","An"; Background = "Dis is what went down"; But = "*","Buh"; Examples = "Examples"; Feature = "Feature"; Given = "*","Givun","Youse know when youse got"; Name = "Scouse"; Native = "Scouse"; Rule = "Rule"; Scenario = "The thing of it is"; ScenarioOutline = "Wharrimean is"; Then = "*","Dun","Den youse gotta"; When = "*","Wun","Youse know like when" };
        'eo' = @{ And = "*","Kaj"; Background = "Fono"; But = "*","Sed"; Examples = "Ekzemploj"; Feature = "Trajto"; Given = "*","Donitaĵo","Komence"; Name = "Esperanto"; Native = "Esperanto"; Rule = "Rule"; Scenario = "Ekzemplo","Scenaro","Kazo"; ScenarioOutline = "Konturo de la scenaro","Skizo","Kazo-skizo"; Then = "*","Do"; When = "*","Se" };
        'es' = @{ And = "*","Y","E"; Background = "Antecedentes"; But = "*","Pero"; Examples = "Ejemplos"; Feature = "Característica"; Given = "*","Dado","Dada","Dados","Dadas"; Name = "Spanish"; Native = "español"; Rule = "Regla"; Scenario = "Ejemplo","Escenario"; ScenarioOutline = "Esquema del escenario"; Then = "*","Entonces"; When = "*","Cuando" };
        'et' = @{ And = "*","Ja"; Background = "Taust"; But = "*","Kuid"; Examples = "Juhtumid"; Feature = "Omadus"; Given = "*","Eeldades"; Name = "Estonian"; Native = "eesti keel"; Rule = "Reegel"; Scenario = "Juhtum","Stsenaarium"; ScenarioOutline = "Raamjuhtum","Raamstsenaarium"; Then = "*","Siis"; When = "*","Kui" };
        'fa' = @{ And = "*","و"; Background = "زمینه"; But = "*","اما"; Examples = "نمونه ها"; Feature = "وِیژگی"; Given = "*","با فرض"; Name = "Persian"; Native = "فارسی"; Rule = "Rule"; Scenario = "مثال","سناریو"; ScenarioOutline = "الگوی سناریو"; Then = "*","آنگاه"; When = "*","هنگامی" };
        'fi' = @{ And = "*","Ja"; Background = "Tausta"; But = "*","Mutta"; Examples = "Tapaukset"; Feature = "Ominaisuus"; Given = "*","Oletetaan"; Name = "Finnish"; Native = "suomi"; Rule = "Rule"; Scenario = "Tapaus"; ScenarioOutline = "Tapausaihio"; Then = "*","Niin"; When = "*","Kun" };
        'fr' = @{ And = "*","Et que","Et qu'","Et"; Background = "Contexte"; But = "*","Mais que","Mais qu'","Mais"; Examples = "Exemples"; Feature = "Fonctionnalité"; Given = "*","Soit","Sachant que","Sachant qu'","Sachant","Etant donné que","Etant donné qu'","Etant donné","Etant donnée","Etant donnés","Etant données","Étant donné que","Étant donné qu'","Étant donné","Étant donnée","Étant donnés","Étant données"; Name = "French"; Native = "français"; Rule = "Règle"; Scenario = "Exemple","Scénario"; ScenarioOutline = "Plan du scénario","Plan du Scénario"; Then = "*","Alors","Donc"; When = "*","Quand","Lorsque","Lorsqu'" };
        'ga' = @{ And = "*","Agus"; Background = "Cúlra"; But = "*","Ach"; Examples = "Samplaí"; Feature = "Gné"; Given = "*","Cuir i gcás go","Cuir i gcás nach","Cuir i gcás gur","Cuir i gcás nár"; Name = "Irish"; Native = "Gaeilge"; Rule = "Rule"; Scenario = "Sampla","Cás"; ScenarioOutline = "Cás Achomair"; Then = "*","Ansin"; When = "*","Nuair a","Nuair nach","Nuair ba","Nuair nár" };
        'gj' = @{ And = "*","અને"; Background = "બેકગ્રાઉન્ડ"; But = "*","પણ"; Examples = "ઉદાહરણો"; Feature = "લક્ષણ","વ્યાપાર જરૂર","ક્ષમતા"; Given = "*","આપેલ છે"; Name = "Gujarati"; Native = "ગુજરાતી"; Rule = "Rule"; Scenario = "ઉદાહરણ","સ્થિતિ"; ScenarioOutline = "પરિદ્દશ્ય રૂપરેખા","પરિદ્દશ્ય ઢાંચો"; Then = "*","પછી"; When = "*","ક્યારે" };
        'gl' = @{ And = "*","E"; Background = "Contexto"; But = "*","Mais","Pero"; Examples = "Exemplos"; Feature = "Característica"; Given = "*","Dado","Dada","Dados","Dadas"; Name = "Galician"; Native = "galego"; Rule = "Rule"; Scenario = "Exemplo","Escenario"; ScenarioOutline = "Esbozo do escenario"; Then = "*","Entón","Logo"; When = "*","Cando" };
        'he' = @{ And = "*","וגם"; Background = "רקע"; But = "*","אבל"; Examples = "דוגמאות"; Feature = "תכונה"; Given = "*","בהינתן"; Name = "Hebrew"; Native = "עברית"; Rule = "Rule"; Scenario = "דוגמא","תרחיש"; ScenarioOutline = "תבנית תרחיש"; Then = "*","אז","אזי"; When = "*","כאשר" };
        'hi' = @{ And = "*","और","तथा"; Background = "पृष्ठभूमि"; But = "*","पर","परन्तु","किन्तु"; Examples = "उदाहरण"; Feature = "रूप लेख"; Given = "*","अगर","यदि","चूंकि"; Name = "Hindi"; Native = "हिंदी"; Rule = "Rule"; Scenario = "परिदृश्य"; ScenarioOutline = "परिदृश्य रूपरेखा"; Then = "*","तब","तदा"; When = "*","जब","कदा" };
        'hr' = @{ And = "*","I"; Background = "Pozadina"; But = "*","Ali"; Examples = "Primjeri","Scenariji"; Feature = "Osobina","Mogućnost","Mogucnost"; Given = "*","Zadan","Zadani","Zadano","Ukoliko"; Name = "Croatian"; Native = "hrvatski"; Rule = "Rule"; Scenario = "Primjer","Scenarij"; ScenarioOutline = "Skica","Koncept"; Then = "*","Onda"; When = "*","Kada","Kad" };
        'ht' = @{ And = "*","Ak","Epi","E"; Background = "Kontèks","Istorik"; But = "*","Men"; Examples = "Egzanp"; Feature = "Karakteristik","Mak","Fonksyonalite"; Given = "*","Sipoze","Sipoze ke","Sipoze Ke"; Name = "Creole"; Native = "kreyòl"; Rule = "Rule"; Scenario = "Senaryo"; ScenarioOutline = "Plan senaryo","Plan Senaryo","Senaryo deskripsyon","Senaryo Deskripsyon","Dyagram senaryo","Dyagram Senaryo"; Then = "*","Lè sa a","Le sa a"; When = "*","Lè","Le" };
        'hu' = @{ And = "*","És"; Background = "Háttér"; But = "*","De"; Examples = "Példák"; Feature = "Jellemző"; Given = "*","Amennyiben","Adott"; Name = "Hungarian"; Native = "magyar"; Rule = "Rule"; Scenario = "Példa","Forgatókönyv"; ScenarioOutline = "Forgatókönyv vázlat"; Then = "*","Akkor"; When = "*","Majd","Ha","Amikor" };
        'id' = @{ And = "*","Dan"; Background = "Dasar","Latar Belakang"; But = "*","Tapi","Tetapi"; Examples = "Contoh","Misal"; Feature = "Fitur"; Given = "*","Dengan","Diketahui","Diasumsikan","Bila","Jika"; Name = "Indonesian"; Native = "Bahasa Indonesia"; Rule = "Rule","Aturan"; Scenario = "Skenario"; ScenarioOutline = "Skenario konsep","Garis-Besar Skenario"; Then = "*","Maka","Kemudian"; When = "*","Ketika" };
        'is' = @{ And = "*","Og"; Background = "Bakgrunnur"; But = "*","En"; Examples = "Dæmi","Atburðarásir"; Feature = "Eiginleiki"; Given = "*","Ef"; Name = "Icelandic"; Native = "Íslenska"; Rule = "Rule"; Scenario = "Atburðarás"; ScenarioOutline = "Lýsing Atburðarásar","Lýsing Dæma"; Then = "*","Þá"; When = "*","Þegar" };
        'it' = @{ And = "*","E"; Background = "Contesto"; But = "*","Ma"; Examples = "Esempi"; Feature = "Funzionalità"; Given = "*","Dato","Data","Dati","Date"; Name = "Italian"; Native = "italiano"; Rule = "Rule"; Scenario = "Esempio","Scenario"; ScenarioOutline = "Schema dello scenario"; Then = "*","Allora"; When = "*","Quando" };
        'ja' = @{ And = "*","かつ"; Background = "背景"; But = "*","しかし","但し","ただし"; Examples = "例","サンプル"; Feature = "フィーチャ","機能"; Given = "*","前提"; Name = "Japanese"; Native = "日本語"; Rule = "Rule"; Scenario = "シナリオ"; ScenarioOutline = "シナリオアウトライン","シナリオテンプレート","テンプレ","シナリオテンプレ"; Then = "*","ならば"; When = "*","もし" };
        'jv' = @{ And = "*","Lan"; Background = "Dasar"; But = "*","Tapi","Nanging","Ananging"; Examples = "Conto","Contone"; Feature = "Fitur"; Given = "*","Nalika","Nalikaning"; Name = "Javanese"; Native = "Basa Jawa"; Rule = "Rule"; Scenario = "Skenario"; ScenarioOutline = "Konsep skenario"; Then = "*","Njuk","Banjur"; When = "*","Manawa","Menawa" };
        'ka' = @{ And = "*","და"; Background = "კონტექსტი"; But = "*","მაგ­რამ"; Examples = "მაგალითები"; Feature = "თვისება"; Given = "*","მოცემული"; Name = "Georgian"; Native = "ქართველი"; Rule = "Rule"; Scenario = "მაგალითად","სცენარის"; ScenarioOutline = "სცენარის ნიმუში"; Then = "*","მაშინ"; When = "*","როდესაც" };
        'kn' = @{ And = "*","ಮತ್ತು"; Background = "ಹಿನ್ನೆಲೆ"; But = "*","ಆದರೆ"; Examples = "ಉದಾಹರಣೆಗಳು"; Feature = "ಹೆಚ್ಚಳ"; Given = "*","ನೀಡಿದ"; Name = "Kannada"; Native = "ಕನ್ನಡ"; Rule = "Rule"; Scenario = "ಉದಾಹರಣೆ","ಕಥಾಸಾರಾಂಶ"; ScenarioOutline = "ವಿವರಣೆ"; Then = "*","ನಂತರ"; When = "*","ಸ್ಥಿತಿಯನ್ನು" };
        'ko' = @{ And = "*","그리고"; Background = "배경"; But = "*","하지만","단"; Examples = "예"; Feature = "기능"; Given = "*","조건","먼저"; Name = "Korean"; Native = "한국어"; Rule = "Rule"; Scenario = "시나리오"; ScenarioOutline = "시나리오 개요"; Then = "*","그러면"; When = "*","만일","만약" };
        'lt' = @{ And = "*","Ir"; Background = "Kontekstas"; But = "*","Bet"; Examples = "Pavyzdžiai","Scenarijai","Variantai"; Feature = "Savybė"; Given = "*","Duota"; Name = "Lithuanian"; Native = "lietuvių kalba"; Rule = "Rule"; Scenario = "Pavyzdys","Scenarijus"; ScenarioOutline = "Scenarijaus šablonas"; Then = "*","Tada"; When = "*","Kai" };
        'lu' = @{ And = "*","an","a"; Background = "Hannergrond"; But = "*","awer","mä"; Examples = "Beispiller"; Feature = "Funktionalitéit"; Given = "*","ugeholl"; Name = "Luxemburgish"; Native = "Lëtzebuergesch"; Rule = "Rule"; Scenario = "Beispill","Szenario"; ScenarioOutline = "Plang vum Szenario"; Then = "*","dann"; When = "*","wann" };
        'lv' = @{ And = "*","Un"; Background = "Konteksts","Situācija"; But = "*","Bet"; Examples = "Piemēri","Paraugs"; Feature = "Funkcionalitāte","Fīča"; Given = "*","Kad"; Name = "Latvian"; Native = "latviešu"; Rule = "Rule"; Scenario = "Piemērs","Scenārijs"; ScenarioOutline = "Scenārijs pēc parauga"; Then = "*","Tad"; When = "*","Ja" };
        'mk-Cyrl' = @{ And = "*","И"; Background = "Контекст","Содржина"; But = "*","Но"; Examples = "Примери","Сценарија"; Feature = "Функционалност","Бизнис потреба","Можност"; Given = "*","Дадено","Дадена"; Name = "Macedonian"; Native = "Македонски"; Rule = "Rule"; Scenario = "Пример","Сценарио","На пример"; ScenarioOutline = "Преглед на сценарија","Скица","Концепт"; Then = "*","Тогаш"; When = "*","Кога" };
        'mk-Latn' = @{ And = "*","I"; Background = "Kontekst","Sodrzhina"; But = "*","No"; Examples = "Primeri","Scenaria"; Feature = "Funkcionalnost","Biznis potreba","Mozhnost"; Given = "*","Dadeno","Dadena"; Name = "Macedonian (Latin)"; Native = "Makedonski (Latinica)"; Rule = "Rule"; Scenario = "Scenario","Na primer"; ScenarioOutline = "Pregled na scenarija","Skica","Koncept"; Then = "*","Togash"; When = "*","Koga" };
        'mn' = @{ And = "*","Мөн","Тэгээд"; Background = "Агуулга"; But = "*","Гэхдээ","Харин"; Examples = "Тухайлбал"; Feature = "Функц","Функционал"; Given = "*","Өгөгдсөн нь","Анх"; Name = "Mongolian"; Native = "монгол"; Rule = "Rule"; Scenario = "Сценар"; ScenarioOutline = "Сценарын төлөвлөгөө"; Then = "*","Тэгэхэд","Үүний дараа"; When = "*","Хэрэв" };
        'mr' = @{ And = "*","आणि","तसेच"; Background = "पार्श्वभूमी"; But = "*","पण","परंतु"; Examples = "उदाहरण"; Feature = "वैशिष्ट्य","सुविधा"; Given = "*","जर","दिलेल्या प्रमाणे"; Name = "Marathi"; Native = "मराठी"; Rule = "नियम"; Scenario = "परिदृश्य"; ScenarioOutline = "परिदृश्य रूपरेखा"; Then = "*","मग","तेव्हा"; When = "*","जेव्हा" };
        'ne' = @{ And = "*","र","अनी"; Background = "पृष्ठभूमी"; But = "*","तर"; Examples = "उदाहरण","उदाहरणहरु"; Feature = "सुविधा","विशेषता"; Given = "*","दिइएको","दिएको","यदि"; Name = "Nepali"; Native = "नेपाली"; Rule = "नियम"; Scenario = "परिदृश्य"; ScenarioOutline = "परिदृश्य रूपरेखा"; Then = "*","त्यसपछि","अनी"; When = "*","जब" };
        'nl' = @{ And = "*","En"; Background = "Achtergrond"; But = "*","Maar"; Examples = "Voorbeelden"; Feature = "Functionaliteit"; Given = "*","Gegeven","Stel"; Name = "Dutch"; Native = "Nederlands"; Rule = "Rule"; Scenario = "Voorbeeld","Scenario"; ScenarioOutline = "Abstract Scenario"; Then = "*","Dan"; When = "*","Als","Wanneer" };
        'no' = @{ And = "*","Og"; Background = "Bakgrunn"; But = "*","Men"; Examples = "Eksempler"; Feature = "Egenskap"; Given = "*","Gitt"; Name = "Norwegian"; Native = "norsk"; Rule = "Regel"; Scenario = "Eksempel","Scenario"; ScenarioOutline = "Scenariomal","Abstrakt Scenario"; Then = "*","Så"; When = "*","Når" };
        'pa' = @{ And = "*","ਅਤੇ"; Background = "ਪਿਛੋਕੜ"; But = "*","ਪਰ"; Examples = "ਉਦਾਹਰਨਾਂ"; Feature = "ਖਾਸੀਅਤ","ਮੁਹਾਂਦਰਾ","ਨਕਸ਼ ਨੁਹਾਰ"; Given = "*","ਜੇਕਰ","ਜਿਵੇਂ ਕਿ"; Name = "Panjabi"; Native = "ਪੰਜਾਬੀ"; Rule = "Rule"; Scenario = "ਉਦਾਹਰਨ","ਪਟਕਥਾ"; ScenarioOutline = "ਪਟਕਥਾ ਢਾਂਚਾ","ਪਟਕਥਾ ਰੂਪ ਰੇਖਾ"; Then = "*","ਤਦ"; When = "*","ਜਦੋਂ" };
        'pl' = @{ And = "*","Oraz","I"; Background = "Założenia"; But = "*","Ale"; Examples = "Przykłady"; Feature = "Właściwość","Funkcja","Aspekt","Potrzeba biznesowa"; Given = "*","Zakładając","Mając","Zakładając, że"; Name = "Polish"; Native = "polski"; Rule = "Rule"; Scenario = "Przykład","Scenariusz"; ScenarioOutline = "Szablon scenariusza"; Then = "*","Wtedy"; When = "*","Jeżeli","Jeśli","Gdy","Kiedy" };
        'pt' = @{ And = "*","E"; Background = "Contexto","Cenário de Fundo","Cenario de Fundo","Fundo"; But = "*","Mas"; Examples = "Exemplos","Cenários","Cenarios"; Feature = "Funcionalidade","Característica","Caracteristica"; Given = "*","Dado","Dada","Dados","Dadas"; Name = "Portuguese"; Native = "português"; Rule = "Regra"; Scenario = "Exemplo","Cenário","Cenario"; ScenarioOutline = "Esquema do Cenário","Esquema do Cenario","Delineação do Cenário","Delineacao do Cenario"; Then = "*","Então","Entao"; When = "*","Quando" };
        'ro' = @{ And = "*","Si","Și","Şi"; Background = "Context"; But = "*","Dar"; Examples = "Exemple"; Feature = "Functionalitate","Funcționalitate","Funcţionalitate"; Given = "*","Date fiind","Dat fiind","Dată fiind","Dati fiind","Dați fiind","Daţi fiind"; Name = "Romanian"; Native = "română"; Rule = "Rule"; Scenario = "Exemplu","Scenariu"; ScenarioOutline = "Structura scenariu","Structură scenariu"; Then = "*","Atunci"; When = "*","Cand","Când" };
        'ru' = @{ And = "*","И","К тому же","Также"; Background = "Предыстория","Контекст"; But = "*","Но","А","Иначе"; Examples = "Примеры"; Feature = "Функция","Функциональность","Функционал","Свойство"; Given = "*","Допустим","Дано","Пусть"; Name = "Russian"; Native = "русский"; Rule = "Правило"; Scenario = "Пример","Сценарий"; ScenarioOutline = "Структура сценария"; Then = "*","То","Затем","Тогда"; When = "*","Когда","Если" };
        'sk' = @{ And = "*","A","A tiež","A taktiež","A zároveň"; Background = "Pozadie"; But = "*","Ale"; Examples = "Príklady"; Feature = "Požiadavka","Funkcia","Vlastnosť"; Given = "*","Pokiaľ","Za predpokladu"; Name = "Slovak"; Native = "Slovensky"; Rule = "Rule"; Scenario = "Príklad","Scenár"; ScenarioOutline = "Náčrt Scenáru","Náčrt Scenára","Osnova Scenára"; Then = "*","Tak","Potom"; When = "*","Keď","Ak" };
        'sl' = @{ And = "In","Ter"; Background = "Kontekst","Osnova","Ozadje"; But = "Toda","Ampak","Vendar"; Examples = "Primeri","Scenariji"; Feature = "Funkcionalnost","Funkcija","Možnosti","Moznosti","Lastnost","Značilnost"; Given = "Dano","Podano","Zaradi","Privzeto"; Name = "Slovenian"; Native = "Slovenski"; Rule = "Rule"; Scenario = "Primer","Scenarij"; ScenarioOutline = "Struktura scenarija","Skica","Koncept","Oris scenarija","Osnutek"; Then = "Nato","Potem","Takrat"; When = "Ko","Ce","Če","Kadar" };
        'sr-Cyrl' = @{ And = "*","И"; Background = "Контекст","Основа","Позадина"; But = "*","Али"; Examples = "Примери","Сценарији"; Feature = "Функционалност","Могућност","Особина"; Given = "*","За дато","За дате","За дати"; Name = "Serbian"; Native = "Српски"; Rule = "Rule"; Scenario = "Пример","Сценарио","Пример"; ScenarioOutline = "Структура сценарија","Скица","Концепт"; Then = "*","Онда"; When = "*","Када","Кад" };
        'sr-Latn' = @{ And = "*","I"; Background = "Kontekst","Osnova","Pozadina"; But = "*","Ali"; Examples = "Primeri","Scenariji"; Feature = "Funkcionalnost","Mogućnost","Mogucnost","Osobina"; Given = "*","Za dato","Za date","Za dati"; Name = "Serbian (Latin)"; Native = "Srpski (Latinica)"; Rule = "Rule"; Scenario = "Scenario","Primer"; ScenarioOutline = "Struktura scenarija","Skica","Koncept"; Then = "*","Onda"; When = "*","Kada","Kad" };
        'sv' = @{ And = "*","Och"; Background = "Bakgrund"; But = "*","Men"; Examples = "Exempel"; Feature = "Egenskap"; Given = "*","Givet"; Name = "Swedish"; Native = "Svenska"; Rule = "Rule"; Scenario = "Scenario"; ScenarioOutline = "Abstrakt Scenario","Scenariomall"; Then = "*","Så"; When = "*","När" };
        'ta' = @{ And = "*","மேலும்","மற்றும்"; Background = "பின்னணி"; But = "*","ஆனால்"; Examples = "எடுத்துக்காட்டுகள்","காட்சிகள்","நிலைமைகளில்"; Feature = "அம்சம்","வணிக தேவை","திறன்"; Given = "*","கொடுக்கப்பட்ட"; Name = "Tamil"; Native = "தமிழ்"; Rule = "Rule"; Scenario = "உதாரணமாக","காட்சி"; ScenarioOutline = "காட்சி சுருக்கம்","காட்சி வார்ப்புரு"; Then = "*","அப்பொழுது"; When = "*","எப்போது" };
        'th' = @{ And = "*","และ"; Background = "แนวคิด"; But = "*","แต่"; Examples = "ชุดของตัวอย่าง","ชุดของเหตุการณ์"; Feature = "โครงหลัก","ความต้องการทางธุรกิจ","ความสามารถ"; Given = "*","กำหนดให้"; Name = "Thai"; Native = "ไทย"; Rule = "Rule"; Scenario = "เหตุการณ์"; ScenarioOutline = "สรุปเหตุการณ์","โครงสร้างของเหตุการณ์"; Then = "*","ดังนั้น"; When = "*","เมื่อ" };
        'tl' = @{ And = "*","మరియు"; Background = "నేపథ్యం"; But = "*","కాని"; Examples = "ఉదాహరణలు"; Feature = "గుణము"; Given = "*","చెప్పబడినది"; Name = "Telugu"; Native = "తెలుగు"; Rule = "Rule"; Scenario = "ఉదాహరణ","సన్నివేశం"; ScenarioOutline = "కథనం"; Then = "*","అప్పుడు"; When = "*","ఈ పరిస్థితిలో" };
        'tlh' = @{ And = "*","'ej","latlh"; Background = "mo'"; But = "*","'ach","'a"; Examples = "ghantoH","lutmey"; Feature = "Qap","Qu'meH 'ut","perbogh","poQbogh malja'","laH"; Given = "*","ghu' noblu'","DaH ghu' bejlu'"; Name = "Klingon"; Native = "tlhIngan"; Rule = "Rule"; Scenario = "lut"; ScenarioOutline = "lut chovnatlh"; Then = "*","vaj"; When = "*","qaSDI'" };
        'tr' = @{ And = "*","Ve"; Background = "Geçmiş"; But = "*","Fakat","Ama"; Examples = "Örnekler"; Feature = "Özellik"; Given = "*","Diyelim ki"; Name = "Turkish"; Native = "Türkçe"; Rule = "Rule"; Scenario = "Örnek","Senaryo"; ScenarioOutline = "Senaryo taslağı"; Then = "*","O zaman"; When = "*","Eğer ki" };
        'tt' = @{ And = "*","Һәм","Вә"; Background = "Кереш"; But = "*","Ләкин","Әмма"; Examples = "Үрнәкләр","Мисаллар"; Feature = "Мөмкинлек","Үзенчәлеклелек"; Given = "*","Әйтик"; Name = "Tatar"; Native = "Татарча"; Rule = "Rule"; Scenario = "Сценарий"; ScenarioOutline = "Сценарийның төзелеше"; Then = "*","Нәтиҗәдә"; When = "*","Әгәр" };
        'uk' = @{ And = "*","І","А також","Та"; Background = "Передумова"; But = "*","Але"; Examples = "Приклади"; Feature = "Функціонал"; Given = "*","Припустимо","Припустимо, що","Нехай","Дано"; Name = "Ukrainian"; Native = "Українська"; Rule = "Rule"; Scenario = "Приклад","Сценарій"; ScenarioOutline = "Структура сценарію"; Then = "*","То","Тоді"; When = "*","Якщо","Коли" };
        'ur' = @{ And = "*","اور"; Background = "پس منظر"; But = "*","لیکن"; Examples = "مثالیں"; Feature = "صلاحیت","کاروبار کی ضرورت","خصوصیت"; Given = "*","اگر","بالفرض","فرض کیا"; Name = "Urdu"; Native = "اردو"; Rule = "Rule"; Scenario = "منظرنامہ"; ScenarioOutline = "منظر نامے کا خاکہ"; Then = "*","پھر","تب"; When = "*","جب" };
        'uz' = @{ And = "*","Ва"; Background = "Тарих"; But = "*","Лекин","Бирок","Аммо"; Examples = "Мисоллар"; Feature = "Функционал"; Given = "*","Агар"; Name = "Uzbek"; Native = "Узбекча"; Rule = "Rule"; Scenario = "Сценарий"; ScenarioOutline = "Сценарий структураси"; Then = "*","Унда"; When = "*","Агар" };
        'vi' = @{ And = "*","Và"; Background = "Bối cảnh"; But = "*","Nhưng"; Examples = "Dữ liệu"; Feature = "Tính năng"; Given = "*","Biết","Cho"; Name = "Vietnamese"; Native = "Tiếng Việt"; Rule = "Rule"; Scenario = "Tình huống","Kịch bản"; ScenarioOutline = "Khung tình huống","Khung kịch bản"; Then = "*","Thì"; When = "*","Khi" };
        'zh-CN' = @{ And = "*","而且","并且","同时"; Background = "背景"; But = "*","但是"; Examples = "例子"; Feature = "功能"; Given = "*","假如","假设","假定"; Name = "Chinese simplified"; Native = "简体中文"; Rule = "Rule"; Scenario = "场景","剧本"; ScenarioOutline = "场景大纲","剧本大纲"; Then = "*","那么"; When = "*","当" };
        'zh-TW' = @{ And = "*","而且","並且","同時"; Background = "背景"; But = "*","但是"; Examples = "例子"; Feature = "功能"; Given = "*","假如","假設","假定"; Name = "Chinese traditional"; Native = "繁體中文"; Rule = "Rule"; Scenario = "場景","劇本"; ScenarioOutline = "場景大綱","劇本大綱"; Then = "*","那麼"; When = "*","當" }
    }

    Verify-That `
        -condition $allGherkinKeywords.ContainsKey($cultureName) `
        -message "No Gherkin keywords are known for culture name $cultureName. Use one of the following culture names: $([String]::Join(',', $allGherkinKeywords.Keys))"

    $localizedKeywords = $allGherkinKeywords[$cultureName]

    $result = @{
            Feature = (One-Of @($localizedKeywords.Feature | ForEach-Object { $_ + ':' }));
            Background = (One-Of @($localizedKeywords.Background | ForEach-Object { $_ + ':' }));
            Scenario = (One-Of @($localizedKeywords.Scenario | ForEach-Object { $_ + ':' }));
            ScenarioOutline = (One-Of @($localizedKeywords.ScenarioOutline | ForEach-Object { $_ + ':' }));
            Given = (One-Of ($localizedKeywords.Given));
            When = (One-Of ($localizedKeywords.When));
            Then = (One-Of ($localizedKeywords.Then));
            Examples = (One-Of ($localizedKeywords.Examples | ForEach-Object { $_ + ':' }));
            And = (One-Of ($localizedKeywords.And));
            But = (One-Of ($localizedKeywords.But));
            Rule = (One-Of ($localizedKeywords.Rule | ForEach-Object { $_ + ':' }))
        }
        $result.Add('Keywords', @($result.Feature, $result.Background, $result.Scenario, $result.ScenarioOutline, $result.Rule, $result.Given, $result.When, $result.Then, $result.Examples, $result.And, $result.But | ForEach-Object { $_ }))
    return $result
}

$GherkinKeywordParsers = Build-GherkinKeywordParsers -cultureName $cultureName
#endregion

#region Grammar from https://github.com/cucumber/gherkin/blob/master/gherkin.berp converted to Powershell
$Comment = ([regex]'\s*#.*$')

$TagLine = Repeat ([regex]'\s*@(\S+)')

$TagsParserCore = (from_ tagNames in (Repeat (Complete-Line $TagLine))),
              (select_ { @($tagNames | ForEach-Object { $_ }) })

$TagsParser = Optional $TagsParserCore -orElse @()

$Other = (Anything-But (One-Of @($GherkinKeywordParsers.Keywords, ([regex]'\s*(\|)'), ([regex]'\s*(@)'), ([regex]'\s*(""")\s*$') | ForEach-Object { $_ }))), ([regex]'(.*)$')

$DescriptionHelper = Repeat (One-Of (Complete-Line $Comment), (Complete-Line $Other)) -allowZeroRepetition

$TableRow = Complete-Line(@(([regex]'\s*[|]'), (Repeat ([regex]'\s*([^|]*)[|]'))))

$DataTable = (from_ parsedTableHeader in $TableRow),
             (from_ parsedTableData in (Repeat $TableRow -allowZeroRepetition)),
             (select_ {
                function IsSeparatorRow([hashtable] $row)
                {
                    True-ForAll `
                        -items $row.Values `
                        -condition {
                            param ($v)
                            True-ForAll `
                                -items ([char[]]$v) `
                                -condition { param ($ch) '-' -eq $ch }
                        }
                }

                function IsMultilineTable([hashtable[]] $rows)
                {
                    1 -eq @($rows | `
                        Where-Object { IsSeparatorRow -row $_ } | `
                        Select-Object -First 1).Length
                }

                $tableHeaderNames = @($parsedTableHeader | Trim-String)

                $parsedTableRows = @($parsedTableData | `
                    ForEach-Object {
                        $dataRow = @($_)

                        Verify-That `
                            -condition ($dataRow.Length -eq $tableHeaderNames.Length) `
                            -message "Table Header $([Environment]::NewLine)| $([String]::Join(' | ', $tableHeaderNames)) |$([Environment]::NewLine) has different number of columns compared to the data row $([Environment]::NewLine)| $([String]::Join(' | ', $dataRow)) |$([Environment]::NewLine)"

                        $resultingRow = @{}
                        for ($cellIndex = 0; $cellIndex -ne $tableHeaderNames.Length; $cellIndex++)
                        {
                            $resultingRow.Add($tableHeaderNames[$cellIndex], ($dataRow[$cellIndex] | Trim-String))
                        }

                        $resultingRow
                    })

                if (IsMultilineTable -rows $parsedTableRows)
                {
                    $mulilineRows = Split-AndProject `
                        -items $parsedTableRows `
                        -isSplitter { param($row) IsSeparatorRow -row $row } `
                        -projectGroup {
                            param([hashtable[]] $rowGroup)

                            $resultingRow = @{}
                            foreach ($columnName in $tableHeaderNames)
                            {
                                $cellValue = ($rowGroup | `
                                                ForEach-Object { $_[$columnName] } | `
                                                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) `
                                                    -join [Environment]::NewLine
                                $resultingRow.Add($columnName, $cellValue)
                            }

                            $resultingRow
                        }

                    [GherkinTable]::new($tableHeaderNames, $mulilineRows)
                }
                else
                {
                    [GherkinTable]::new($tableHeaderNames, $parsedTableRows)
                }
             })

$DocStringSeparator = [regex]'\s*(""")\s*$'

$DocString = (Complete-Line $DocStringSeparator),
             (from_ parsedDocStringLine in (Repeat -parser @((Anything-But (Complete-Line $DocStringSeparator)), (Complete-Line ([regex]'(.*)'))) -allowZeroRepetition)),
             (Complete-Line $DocStringSeparator),
             (select_ { [String]::Join([Environment]::NewLine, $parsedDocStringLine) })

$StepArgument = (One-Of $DataTable, $DocString)

function SingleStep-Parser($firstStepLineParser)
{
    (from_  parsedStepText in $firstStepLineParser),
    (from_ parsedStepExtraArgument in (Optional $StepArgument)),
    (select_ { @{ StepText = $parsedStepText; ExtraArgument = $parsedStepExtraArgument } })
}

function Gherkin-LineParser($keywordParser, [switch] $emptyRestOfLineIsAnError)
{
    $restOfLineParser = switch ($emptyRestOfLineIsAnError) { $False { (One-Of ([regex]'\s(.*)'), ([regex]'$')) } $True { ([regex]'\s(.*)') } }
    return $keywordParser,
           (from_ restOfLine in $restOfLineParser),
           (select_ { $restOfLine | Trim-String })
}

function StepBlock-Parser($stepKeywordParser, [StepType] $stepType)
{
    $allButFirstLineInBlockParser = One-Of @($stepKeywordParser, $GherkinKeywordParsers.And, $GherkinKeywordParsers.But | ForEach-Object { Complete-Line (Gherkin-LineParser $_ -emptyRestOfLineIsAnError) })

    return (from_ firstLineInBlock in (SingleStep-Parser (Complete-Line (Gherkin-LineParser $stepKeywordParser -emptyRestOfLineIsAnError)))),
           (from_ otherLinesInBlock in (Repeat (SingleStep-Parser ($allButFirstLineInBlockParser)) -allowZeroRepetition)),
           (select_ { @{
                          BlockType = $stepType;
                          Steps = @($firstLineInBlock) + @($otherLinesInBlock)
                        }
           }.GetNewClosure())
}

$ScenarioStepBlock = One-Of `
                        (StepBlock-Parser $GherkinKeywordParsers.Given ([StepType]::Given)), `
                        (StepBlock-Parser $GherkinKeywordParsers.When ([StepType]::When)), `
                        (StepBlock-Parser $GherkinKeywordParsers.Then ([StepType]::Then))

$Background = (from_ backgroundName in (Complete-Line (Gherkin-LineParser $GherkinKeywordParsers.Background))),
              (from_ backgroundDescription in $DescriptionHelper),
              (from_ backgroundStepBlocks in (Repeat $ScenarioStepBlock -allowZeroRepetition)),
              (select_ { @{ Name = $backgroundName; Description = $backgroundDescription; StepBlocks = $backgroundStepBlocks }})

function Scenario-Parser($scenarioOrScenarioOutlineLexem)
{
    return  (from_ scenarioTags in $TagsParser),
            (from_ scenarioName in (Complete-Line (Gherkin-LineParser $scenarioOrScenarioOutlineLexem))),
            (from_ scenarioDescription in $DescriptionHelper),
            (from_ scenarioStepBlocks in (Repeat $ScenarioStepBlock -allowZeroRepetition)),
            (select_ { @{ Title = $scenarioName; Description = $scenarioDescription; Tags = $scenarioTags; ScenarioBlocks = $scenarioStepBlocks } })
}

$Scenario = Scenario-Parser $GherkinKeywordParsers.Scenario

$ExamplesDefinition = (from_ examplesTags in $TagsParser),
                      (Complete-Line (Gherkin-LineParser $GherkinKeywordParsers.Examples)),
                      (from_ examplesDescription in $DescriptionHelper),
                      (from_ examplesTable in (Optional $DataTable)),
                      (select_ { @{
                                    Tags = $examplesTags;
                                    Description = $examplesDescription;
                                    ExampleVariableNames = $examplesTable.Header;
                                    ExamplesData = $examplesTable.Rows
                                    }})

$ScenarioOutline = (from_ scenarioTemplate in (Scenario-Parser $GherkinKeywordParsers.ScenarioOutline)),
                   (from_ examples in (Repeat $ExamplesDefinition -allowZeroRepetition)),
                   (select_ { @{ ScenarioTemplate = $scenarioTemplate; Examples = $examples } })

$RuleHeader = (from_ ruleName in (Complete-Line (Gherkin-LineParser $GherkinKeywordParsers.Rule))),
              (from_ ruleDescription in $DescriptionHelper),
              (from_ ruleBackground in (Optional -parser $Background -orElse @{ StepBlocks = $null })),
              (select_ { @{ RuleTitle = $ruleName; RuleDescription = $ruleDescription; RuleBackground = $ruleBackground } })

$RuleWithExamples = (from_ hdr in (Optional $RuleHeader)),
                    (from_ exmpls in (Repeat (One-Of $Scenario, $ScenarioOutline) -allowZeroRepetition)),
                    (where_ { ($null -ne $hdr) -or ($exmpls.Length -gt 0) }),
                    (select_ { @{ RuleHeader = $hdr; RuleExamples = $exmpls } })

$Feature_Header = (from_ featureTags in $TagsParser),
                  (from_ featureName in (Complete-Line (Gherkin-LineParser $GherkinKeywordParsers.Feature))),
                  (from_ featureDescription in $DescriptionHelper),
                  (select_ { @{ Name = $featureName; Description = $featureDescription; Tags = $featureTags } })

$Feature = (from_ featureHeader in $Feature_Header),
           (from_ parsedBackground in (Optional -parser $Background -orElse @{ StepBlocks = $null })),
           (from_ allRules in (Repeat $RuleWithExamples -allowZeroRepetition)),
           (select_ { @{
                        Title = $featureHeader.Name;
                        Description = $featureHeader.Description;
                        Tags = $featureHeader.Tags;
                        Background = $parsedBackground;
                        Rules = $allRules } })

$GherkinDocument = (from_ parsedFeature in (Optional $Feature)),
                   (EndOfContent),
                   (select_ { $parsedFeature })
#endregion

#region class ScenarioExecutionResults
function Build-ScenarioExecutionResults($scenario, [ScenarioOutcome] $scenarioOutcome, $exceptionInfo, $duration)
{
	if ($null -ne $exceptionInfo)
	{
        $exceptionDescription = Describe-ErrorRecord -errorRecord $exceptionInfo
        $message = "$([FeatureContext]::Current.FeatureInfo.Title).$($scenario.Title) $scenarioOutcome. $exceptionDescription"
        Log-TestRunning $message
		Write-Host $message
	}
	else
	{
		Write-Host "$([FeatureContext]::Current.FeatureInfo.Title).$($scenario.Title) $scenarioOutcome."
	}

	@{ Scenario = $scenario.Title; ScenarioOutcome = $scenarioOutcome; Error = $exceptionInfo; Duration = $duration }
}
#endregion

function Invoke-GherkinHooks([HookType] $hookType)
{
    function Tags-AllowHookInvocation([array] $requiredTags)
    {
        if ($requiredTags.Length -eq 0 -or $hookType.ToString().EndsWith('TestRun'))
        {
            return $True
        }

        $currentTags = switch -wildcard ($hookType)
        {
            '*Feature' { [FeatureContext]::Current.FeatureInfo.Tags }
            default    { [ScenarioContext]::Current.ScenarioInfo.Tags }
        }

        return @($currentTags | Where-Object { $requiredTags -contains $_ }).Length -gt 0
    }

    switch ($hookType)
    {
        [HookType]::SetupTestRun { Log-TestRunning 'Starting test run' }
        [HookType]::SetupFeature { Log-TestRunning "Starting feature '$([FeatureContext]::Current.FeatureInfo.Title)'" }
        [HookType]::SetupScenario { Log-TestRunning "Starting Scenario '$([ScenarioContext]::Current.ScenarioInfo.Title)'" }
    }

    foreach ($hookData in ([Known]::GherkinHooks.ForType($hookType) | Where-Object { Tags-AllowHookInvocation -requiredTags @($_.Tags | Except-Nulls) }))
    {
        & $hookData.Script
    }

    switch ($hookType)
    {
        [HookType]::TeardownTestRun { Log-TestRunning 'Finished test run' }
        [HookType]::TeardownFeature { Log-TestRunning "Finished feature '$([FeatureContext]::Current.FeatureInfo.Title)'" }
        [HookType]::TeardownScenario { Log-TestRunning "Finished scenario '$([ScenarioContext]::Current.ScenarioInfo.Title)'" }
    }
}

# $extraArgument's type should've been [string] as well, but see https://github.com/PowerShell/PowerShell/issues/4616
function Bind-ToStepExecuter([StepType] $stepType, [string] $stepText, $extraArgument)
{
    function Get-ScriptBlockParameterTypes([scriptblock] $scriptBlock)
    {
        try
        {
            $scriptBlock.Ast.ParamBlock.Parameters | ForEach-Object { $_.StaticType }
        }
        catch [System.Management.Automation.PropertyNotFoundException]
        {
            @()
        }
    }

    $match = [Known]::StepDefinitions.Match($stepType, $stepText)
    @{
        StepPattern = $match.StepBinding.Pattern;
        StepScript = $match.StepBinding.Script;
        StepArguments = [Known]::CustomTypeConverters.ApplyToAll(@($match.StepArguments) + @($extraArgument | Except-Nulls), @(Get-ScriptBlockParameterTypes $match.StepBinding.Script))
    }
}

function Run-ScenarioStep($stepType)
{
    process
    {
        $stepText = $_.StepText
        $extraArgument = $_.ExtraArgument
        $stepBinding = Bind-ToStepExecuter -stepType $stepType -stepText $stepText -extraArgument $extraArgument
        Log-TestRunning "Starting executing step '$($stepBinding.StepPattern)' with arguments $($stepBinding.StepArguments)"
        if ($showCurrentStepInConsoleTitle)
        {
            $host.ui.RawUI.WindowTitle = $_.StepText
        }

        $stepStopwatch = [system.diagnostics.stopwatch]::StartNew()
        Invoke-GherkinHooks -hookType ([HookType]::SetupScenarioStep)
        Invoke-Command -ScriptBlock $stepBinding.StepScript -ArgumentList $stepBinding.StepArguments
        Invoke-GherkinHooks -hookType ([HookType]::TeardownScenarioStep)
        Log-TestRunning "Finished executing step '$($stepBinding.StepPattern)' (took $([int]$stepStopwatch.Elapsed.TotalSeconds) seconds)."
    }
}

filter Run-ScenarioBlock
{
    $currentBlock = $_
    [ScenarioContext]::Current.ScenarioInfo.CurrentScenarioBlock = $currentBlock.BlockType
    Invoke-GherkinHooks -hookType ([HookType]::SetupScenarioBlock)
    $currentBlock.Steps | Run-ScenarioStep $currentBlock.BlockType
    Invoke-GherkinHooks -hookType ([HookType]::TeardownScenarioBlock)
}

function Join-ScenarioBlocks($backgroundBlocks, $scenarioBlocks)
{
    $currentBlockType = $null
    $encounteredBlocks = 0
    $encounteredSteps = 0
    @(@($backgroundBlocks | Except-Nulls) + @($scenarioBlocks | Except-Nulls) | `
        ForEach-Object {
            $it = $_
            $it.Steps | ForEach-Object { @{ BlockType = $it.BlockType; Step = $_ } }
        } | `
        ForEach-Object {
            if ($_.BlockType -ne $currentBlockType)
            {
                $currentBlockType = $_.BlockType
                $encounteredBlocks = $encounteredBlocks + 1
            }

            @{ BlockType = $_.BlockType; Step = $_.Step; BlockNumber = $encounteredBlocks; StepNumber = ++$encounteredSteps }
        }) | `
        Group-Object -Property { $_.BlockNumber } | `
        Sort-Object -Property Name | `
        ForEach-Object {
            @{
                BlockType = @($_.Group)[0].BlockType;
                Steps = @($_.Group | Sort-Object -Property { $_.StepNumber } | ForEach-Object { $_.Step })
            }
        }
}

function Run-SingleScenario($featureTags, $backgroundBlocks)
{
    process
    {
        function Scenario-ShouldBeIgnoredAccordingToItsTags($scenarioTags)
        {
            if ($scenarioTags -contains 'ignore')
            {
                return $True
            }

            if ([string]::IsNullOrEmpty($tags))
            {
                return $False
            }

            $tagsThatMustBePresent = @(@($tags -split ',') | Where-Object { -Not ([string]::IsNullOrEmpty($_)) -and $_.StartsWith('@') })
            $tagsThatMustBeAbsent = @(@($tags -split ',') | Where-Object { -Not ([string]::IsNullOrEmpty($_)) -and $_.StartsWith('~@') })

            $tagsThatMustBePresentAndScenarioTagsIntersection = @( $tagsThatMustBePresent | Where-Object { $scenarioTags -contains $_.Trim(@('@', '~')) } )
            $tagsThatMustBeAbsentAndScenarioTagsIntersection = @( $tagsThatMustBeAbsent | Where-Object { $scenarioTags -contains $_.Trim(@('@', '~')) } )

            $scenarioShouldBeExecuted = `
                (($tagsThatMustBePresent.Length -eq 0) -or ($tagsThatMustBePresentAndScenarioTagsIntersection.Length -gt 0)) -and `
                (($tagsThatMustBeAbsent.Length -eq 0) -or ($tagsThatMustBeAbsentAndScenarioTagsIntersection.Length -eq 0))

            return (-Not $scenarioShouldBeExecuted)
        }

        function Run-SingleScenarioCore($scenario, $stopwatch)
        {
            $scenario.Tags = @($featureTags | Except-Nulls) + @($scenario.Tags | Except-Nulls)
            if (Scenario-ShouldBeIgnoredAccordingToItsTags -scenarioTags $scenario.Tags)
            {
                return Build-ScenarioExecutionResults -scenario $scenario -scenarioOutcome ([ScenarioOutcome]::Ignored) -exceptionInfo $null -duration [timespan]::Zero
            }

            [ScenarioContext]::Current = New-Object ScenarioContext
            [ScenarioContext]::Current.ScenarioInfo = $scenario

            Invoke-GherkinHooks -hookType ([HookType]::SetupScenario)
            Join-ScenarioBlocks -backgroundBlocks $backgroundBlocks -scenarioBlocks $scenario.ScenarioBlocks | Run-ScenarioBlock
            Invoke-GherkinHooks -hookType ([HookType]::TeardownScenario)

            $failedAssertions = Get-AllFailedAssertionsInfo
            if ($null -ne $failedAssertions)
            {
                throw $failedAssertions
            }

            return Build-ScenarioExecutionResults -scenario $scenario -scenarioOutcome ([ScenarioOutcome]::Succeeded) -exceptionInfo $null -duration $stopwatch.Elapsed
        }

        $currentScenario = $_
        $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

        if ($failFast)
        {
            return Run-SingleScenarioCore -scenario $currentScenario -stopwatch $stopwatch
        }
        else
        {
            try
            {
                return Run-SingleScenarioCore -scenario $currentScenario -stopwatch $stopwatch
            }
            catch
            {
                return Build-ScenarioExecutionResults -scenario $currentScenario -scenarioOutcome ([ScenarioOutcome]::Failed) -exceptionInfo $PSItem.Exception -duration $stopwatch.Elapsed
            }
        }
    }
}

filter Apply-Rules
{
    [hashtable] $ruleHeader = $_.RuleHeader
    $_.RuleExamples | `
        ForEach-Object {
            $example = $_
            if ($null -ne $ruleHeader)
            {
                $scenario = switch ($example.ContainsKey('Examples')) 
                {
                    $true { $example.ScenarioTemplate } # scenario outline
                    default { $example } # plain scenario/example
                }

                'RuleTitle', 'RuleDescription' | ForEach-Object { $scenario.Add($_, $ruleHeader[$_]) }
                $scenario.ScenarioBlocks = @(Join-ScenarioBlocks -backgroundBlocks $ruleHeader.RuleBackground.StepBlocks -scenarioBlocks $scenario.ScenarioBlocks)
            }

            $example
        }
}

filter Expand-ScenarioOutline
{
    if (-not $_.ContainsKey('Examples'))
    {
        return $_
    }

    $scenarioTemplate = $_.ScenarioTemplate
    $_.Examples | `
        ForEach-Object {
            $currentSetOfExamples = $_

            $currentSetOfExamples.ExamplesData | `
                ForEach-Object {
                    $currentExample = $_

                    $scenarioBlocks = $scenarioTemplate.ScenarioBlocks | `
                        ForEach-Object {
                            $currentStepBlock = $_
                            $steps = $currentStepBlock.Steps | `
                                ForEach-Object {
                                    [string] $stepText = $_.StepText
                                    $extraArgument = $_.ExtraArgument

                                    foreach ($columnName in $currentSetOfExamples.ExampleVariableNames)
                                    {
                                        $exampleColumnValue = $currentExample[$columnName]
                                        $stepText = $stepText.Replace("<$columnName>", $exampleColumnValue)

                                        if ($Null -ne $extraArgument)
                                        {
                                            if ($extraArgument -is [string])
                                            {
                                                $extraArgument = $extraArgument.Replace("<$columnName>", $exampleColumnValue)
                                            }
                                            else
                                            {
                                                $adjustedHeader = @($extraArgument.Header | ForEach-Object { $_.Replace("<$columnName>", $exampleColumnValue) })
                                                $adjustedRows = @($extraArgument.Rows | `
                                                            ForEach-Object {
                                                                $originalRow = $_
                                                                $modifiedRow = @{}
                                                                $originalRow.GetEnumerator() | `
                                                                    ForEach-Object {
                                                                        $originalKey = $_.Key
                                                                        $originalValue = $_.Value
                                                                        $modifiedRow.Add($originalKey.Replace("<$columnName>", $exampleColumnValue), $originalValue.Replace("<$columnName>", $exampleColumnValue)) 
                                                                    }

                                                                $modifiedRow
                                                            })
                                                $extraArgument = [GherkinTable]::new($adjustedHeader, $adjustedRows)
                                            }
                                        }
                                    }

                                    @{ StepText = $stepText; ExtraArgument = $extraArgument }
                                }

                            @{ BlockType = $currentStepBlock.BlockType; Steps = @($steps) }
                        }

                    $firstParameterName = $currentSetOfExamples.ExampleVariableNames[0]
                    $exampleDescription = "$firstParameterName`: $($currentExample[$firstParameterName])"

                    @{
                        Title = "$($scenarioTemplate.Title) ($exampleDescription)";
                        Description = $currentSetOfExamples.Description;
                        Tags = ($scenarioTemplate.Tags + $currentSetOfExamples.Tags);
                        ScenarioBlocks = @($scenarioBlocks);
                        IsScenarioOutline = $False
                    }
                }
        }
}

function Run-FeatureScenarios($featureFile, $feature)
{
    [FeatureContext]::Current = New-Object FeatureContext
    [FeatureContext]::Current.FeatureInfo = $feature
    Invoke-GherkinHooks -hookType ([HookType]::SetupFeature)
	$scenarioExecutionResults = @()
    $feature.Rules | `
        Except-Nulls | `
        Apply-Rules | `
        Expand-ScenarioOutline | `
		Run-SingleScenario -featureTags $feature.Tags -backgroundBlocks $feature.Background.StepBlocks | `
		ForEach-Object { $scenarioExecutionResults += @($_) }
    Invoke-GherkinHooks -hookType ([HookType]::TeardownFeature)
	@{ Feature = $feature; ScenarioExecutionResults = $scenarioExecutionResults }
}
#endregion

function Clear-LogFile($filePath)
{
    if ((-Not [string]::IsNullOrEmpty($filePath)) -and (Test-Path $filePath))
    {
        Remove-Item $filePath
    }
}

Validate -parameters @( {$scenarios} )

Clear-LogFile -filePath $logParsingToFile
Clear-LogFile -filePath $logTestRunningToFile

if (-Not $doNotCleanupGherkinRunningInfrastructure)
{
	Clean-GherkinRunningInfrastructure
}

Register-AvailableTestParamers $args

if (-not [string]::IsNullOrEmpty($stepDefinitions))
{
	List-Files $stepDefinitions | Where-Object { $_.EndsWith('.ps1') } | ForEach-Object { . $_ }
}

Given-When ([regex] 'Halt\:(.*)') {
    param ($message)
    [void](Read-Host "$message$([Environment]::NewLine)Press Enter to continue...")
}

$parsedScenarios = @(List-Files $scenarios | ForEach-Object {
        $scriptFilePath = $_
        $scriptFileContent = [FeatureFileContent]::new(@(Get-Content $scriptFilePath), -1, 0)
        $parsingResult = [MonadicParsing]::ParseWith($GherkinDocument, $scriptFileContent)
        if ($null -eq $parsingResult)
        {
            throw "Failed to parse $scriptFilePath feature file"
        }

        @{ ScenarioFilePath = $scriptFilePath; Feature = $parsingResult.Value }
    })

[TestRunContext]::Current = [TestRunContext]::new()

$featureExecutionResults = @()

if ($parsedScenarios.Length -gt 1 -or ($parsedScenarios.Length -eq 1 -and $Null -ne $parsedScenarios[0].Feature))
{
    Invoke-GherkinHooks -hookType ([HookType]::SetupTestRun)
    $featureExecutionResults = @($parsedScenarios | ForEach-Object { Run-FeatureScenarios -featureFile $_.ScenarioFilePath -feature $_.Feature })
    Invoke-GherkinHooks -hookType ([HookType]::TeardownTestRun)
}

if ($formatResultsToTable)
{
    $featureExecutionResults | `
        ForEach-Object {
            $it = $_
            $it.ScenarioExecutionResults | `
                Foreach-Object { $_ + @{ Feature = $it.Feature.Title } }
        } | `
        ForEach-Object {
            [PSCustomObject]$_
        } | `
        Format-Table `
            -GroupBy Feature `
            -Property Scenario, ScenarioOutcome, Duration `
            -AutoSize
}
else
{
    $featureExecutionResults
}