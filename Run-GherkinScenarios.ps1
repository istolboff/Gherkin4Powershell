param (
    [string] $scenarios,
	[string] $stepDefinitions = $null,
    [string] $tags = $Null,
    [string] $cultureName = 'en-US',
    [string] $logParsingToFile = $Null,
    [string] $logTestRunningToFile = $Null,
	[switch] $failFast,
    [switch] $doNotCleanupGherkinRunningInfrastructure,
    [switch] $showCurrentStepInConsoleTitle)

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
function Verify-That($condition, $message)
{
    if (-Not $condition)
    {
        throw $message
    }
}

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
    switch ($_) { $Null { '' } default { $_.Trim() } }
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
            'ar-AR' = @{ Feature='خاصية'; Background='الخلفية'; Scenario='سيناريو'; ScenarioOutline='سيناريو مخطط'; Examples='امثلة'; Given='بفرض'; When='متى','عندما'; Then='اذاً','ثم'; And='و'; But='لكن' };
            'bg-BG' = @{ Feature='Функционалност'; Background='Предистория'; Scenario='Сценарий'; ScenarioOutline='Рамка на сценарий'; Examples='Примери'; Given='Дадено'; When='Когато'; Then='То'; And='И'; But='Но' };
            'ca-CA' = @{ Feature='Característica','Funcionalitat'; Background='Rerefons','Antecedents'; Scenario='Escenari'; ScenarioOutline='Esquema de l''escenari'; Examples='Exemples'; Given='Donat','Donada','Atès','Atesa'; When='Quan'; Then='Aleshores','Cal'; And='I'; But='Però' };
            'cs-CS' = @{ Feature='Požadavek'; Background='Pozadí','Kontext'; Scenario='Scénář'; ScenarioOutline='Náčrt Scénáře','Osnova scénáře'; Examples='Příklady'; Given='Pokud'; When='Když'; Then='Pak'; And='A','A také'; But='Ale' };
            'cy-GB-CY-GB' = @{ Feature='Arwedd'; Background='Cefndir'; Scenario='Scenario'; ScenarioOutline='Scenario Amlinellol'; Examples='Enghreifftiau'; Given='Anrhegedig a'; When='Pryd'; Then='Yna'; And='A'; But='Ond' };
            'da-DA' = @{ Feature='Egenskab'; Background='Baggrund'; Scenario='Scenarie'; ScenarioOutline='Abstrakt Scenario'; Examples='Eksempler'; Given='Givet'; When='Når'; Then='Så'; And='Og'; But='Men' };
            'de-DE' = @{ Feature='Funktionalität'; Background='Grundlage'; Scenario='Szenario'; ScenarioOutline='Szenariogrundriss'; Examples='Beispiele'; Given='Angenommen','Gegeben sei','Gegeben seien'; When='Wenn'; Then='Dann'; And='Und'; But='Aber' };
            'en-EN' = @{ Feature='Feature'; Background='Background'; Scenario='Scenario','Example'; ScenarioOutline='Scenario Outline','Scenario Template'; Examples='Examples','Scenarios'; Given='Given'; When='When'; Then='Then'; And='And'; But='But' };
            'en-US' = @{ Feature='Feature'; Background='Background'; Scenario='Scenario','Example'; ScenarioOutline='Scenario Outline','Scenario Template'; Examples='Examples','Scenarios'; Given='Given'; When='When'; Then='Then'; And='And'; But='But' };
            'en-AU-EN-AU' = @{ Feature='Pretty much'; Background='First off'; Scenario='Awww, look mate'; ScenarioOutline='Reckon it''s like'; Examples='You''ll wanna'; Given='Y''know'; When='It''s just unbelievable'; Then='But at the end of the day I reckon'; And='Too right'; But='Yeah nah' };
            'en-EN-LOL' = @{ Feature='OH HAI'; Background='B4'; Scenario='MISHUN'; ScenarioOutline='MISHUN SRSLY'; Examples='EXAMPLZ'; Given='I CAN HAZ'; When='WEN'; Then='DEN'; And='AN'; But='BUT' };
            'en-EN-PIRATE' = @{ Feature='Ahoy matey!'; Background='Yo-ho-ho'; Scenario='Heave to'; ScenarioOutline='Shiver me timbers'; Examples='Dead men tell no tales'; Given='Gangway!'; When='Blimey!'; Then='Let go and haul'; And='Aye'; But='Avast!' };
            'en-EN-SCOUSE' = @{ Feature='Feature'; Background='Dis is what went down'; Scenario='The thing of it is'; ScenarioOutline='Wharrimean is'; Examples='Examples'; Given='Givun','Youse know when youse got'; When='Wun','Youse know like when'; Then='Dun','Den youse gotta'; And='An'; But='Buh' };
            'en-EN-TX' = @{ Feature='Feature'; Background='Background'; Scenario='Scenario'; ScenarioOutline='All y''all'; Examples='Examples'; Given='Given y''all'; When='When y''all'; Then='Then y''all'; And='And y''all'; But='But y''all' };
            'es-ES' = @{ Feature='Característica'; Background='Antecedentes'; Scenario='Escenario'; ScenarioOutline='Esquema del escenario'; Examples='Ejemplos'; Given='Dado','Dada','Dados','Dadas'; When='Cuando'; Then='Entonces'; And='Y'; But='Pero' };
            'et-ET' = @{ Feature='Omadus'; Background='Taust'; Scenario='Stsenaarium'; ScenarioOutline='Raamstsenaarium'; Examples='Juhtumid'; Given='Eeldades'; When='Kui'; Then='Siis'; And='Ja'; But='Kuid' };
            'fi-FI' = @{ Feature='Ominaisuus'; Background='Tausta'; Scenario='Tapaus'; ScenarioOutline='Tapausaihio'; Examples='Tapaukset'; Given='Oletetaan'; When='Kun'; Then='Niin'; And='Ja'; But='Mutta' };
            'fr-FR' = @{ Feature='Fonctionnalité'; Background='Contexte'; Scenario='Scénario'; ScenarioOutline='Plan du scénario','Plan du Scénario'; Examples='Exemples'; Given='Soit','Etant donné','Etant donnée','Etant donnés','Etant données','Étant donné','Étant donnée','Étant donnés','Étant données'; When='Quand','Lorsque','Lorsqu'''; Then='Alors'; And='Et'; But='Mais' };
            'he-HE' = @{ Feature='תכונה'; Background='רקע'; Scenario='תרחיש'; ScenarioOutline='תבנית תרחיש'; Examples='דוגמאות'; Given='בהינתן'; When='כאשר'; Then='אז','אזי'; And='וגם'; But='אבל' };
            'hr-HR' = @{ Feature='Osobina','Mogućnost','Mogucnost'; Background='Pozadina'; Scenario='Scenarij'; ScenarioOutline='Skica','Koncept'; Examples='Primjeri','Scenariji'; Given='Zadan','Zadani','Zadano'; When='Kada','Kad'; Then='Onda'; And='I'; But='Ali' };
            'hu-HU' = @{ Feature='Jellemző'; Background='Háttér'; Scenario='Forgatókönyv'; ScenarioOutline='Forgatókönyv vázlat'; Examples='Példák'; Given='Amennyiben','Adott'; When='Majd','Ha','Amikor'; Then='Akkor'; And='És'; But='De' };
            'id-ID' = @{ Feature='Fitur'; Background='Dasar'; Scenario='Skenario'; ScenarioOutline='Skenario konsep'; Examples='Contoh'; Given='Dengan'; When='Ketika'; Then='Maka'; And='Dan'; But='Tapi' };
            'is-IS' = @{ Feature='Eiginleiki'; Background='Bakgrunnur'; Scenario='Atburðarás'; ScenarioOutline='Lýsing Atburðarásar','Lýsing Dæma'; Examples='Dæmi','Atburðarásir'; Given='Ef'; When='Þegar'; Then='Þá'; And='Og'; But='En' };
            'it-IT' = @{ Feature='Funzionalità'; Background='Contesto'; Scenario='Scenario'; ScenarioOutline='Schema dello scenario'; Examples='Esempi'; Given='Dato','Data','Dati','Date'; When='Quando'; Then='Allora'; And='E'; But='Ma' };
            'ja-JA' = @{ Feature='フィーチャ','機能'; Background='背景'; Scenario='シナリオ'; ScenarioOutline='シナリオアウトライン','シナリオテンプレート','テンプレ','シナリオテンプレ'; Examples='例','サンプル'; Given='前提'; When='もし'; Then='ならば'; And='かつ'; But='しかし','但し','ただし' };
            'ko-KO' = @{ Feature='기능'; Background='배경'; Scenario='시나리오'; ScenarioOutline='시나리오 개요'; Examples='예'; Given='조건','먼저'; When='만일','만약'; Then='그러면'; And='그리고'; But='하지만','단' };
            'lt-LT' = @{ Feature='Savybė'; Background='Kontekstas'; Scenario='Scenarijus'; ScenarioOutline='Scenarijaus šablonas'; Examples='Pavyzdžiai','Scenarijai','Variantai'; Given='Duota'; When='Kai'; Then='Tada'; And='Ir'; But='Bet' };
            'lb-LU-LB-LU' = @{ Feature='Funktionalitéit'; Background='Hannergrond'; Scenario='Szenario'; ScenarioOutline='Plang vum Szenario'; Examples='Beispiller'; Given='ugeholl'; When='wann'; Then='dann'; And='an','a'; But='awer','mä' };
            'lv-LV' = @{ Feature='Funkcionalitāte','Fīča'; Background='Konteksts','Situācija'; Scenario='Scenārijs'; ScenarioOutline='Scenārijs pēc parauga'; Examples='Piemēri','Paraugs'; Given='Kad'; When='Ja'; Then='Tad'; And='Un'; But='Bet' };
            'nl-NL' = @{ Feature='Functionaliteit'; Background='Achtergrond'; Scenario='Scenario'; ScenarioOutline='Abstract Scenario'; Examples='Voorbeelden'; Given='Gegeven','Stel'; When='Als'; Then='Dan'; And='En'; But='Maar' };
            'no-NO' = @{ Feature='Egenskap'; Background='Bakgrunn'; Scenario='Scenario'; ScenarioOutline='Scenariomal','Abstrakt Scenario'; Examples='Eksempler'; Given='Gitt'; When='Når'; Then='Så'; And='Og'; But='Men' };
            'pl-PL' = @{ Feature='Właściwość'; Background='Założenia'; Scenario='Scenariusz'; ScenarioOutline='Szablon scenariusza'; Examples='Przykłady'; Given='Zakładając','Mając'; When='Jeżeli','Jeśli'; Then='Wtedy'; And='Oraz','I'; But='Ale' };
            'pt-PT' = @{ Feature='Funcionalidade'; Background='Contexto'; Scenario='Cenário','Cenario'; ScenarioOutline='Esquema do Cenário','Esquema do Cenario'; Examples='Exemplos'; Given='Dado','Dada','Dados','Dadas'; When='Quando'; Then='Então','Entao'; And='E'; But='Mas' };
            'ro-RO' = @{ Feature='Functionalitate','Funcționalitate','Funcţionalitate'; Background='Context'; Scenario='Scenariu'; ScenarioOutline='Structura scenariu','Structură scenariu'; Examples='Exemple'; Given='Date fiind','Dat fiind','Dati fiind','Dați fiind','Daţi fiind'; When='Cand','Când'; Then='Atunci'; And='Si','Și','Şi'; But='Dar' };
            'ru-RU' = @{ Feature='Функция','Функционал','Свойство'; Background='Предыстория','Контекст'; Scenario='Сценарий'; ScenarioOutline='Структура сценария'; Examples='Примеры'; Given='Допустим','Дано','Пусть'; When='Если','Когда'; Then='То','Тогда'; And='И','К тому же'; But='Но','А' };
            'sk-SK' = @{ Feature='Požiadavka'; Background='Pozadie'; Scenario='Scenár'; ScenarioOutline='Náčrt Scenáru'; Examples='Príklady'; Given='Pokiaľ'; When='Keď'; Then='Tak'; And='A'; But='Ale' };
            'sr-SR-CYRL' = @{ Feature='Функционалност','Могућност','Особина'; Background='Контекст','Основа','Позадина'; Scenario='Сценарио','Пример'; ScenarioOutline='Структура сценарија','Скица','Концепт'; Examples='Примери','Сценарији'; Given='Задато','Задате','Задати'; When='Када','Кад'; Then='Онда'; And='И'; But='Али' };
            'sr-SR-LATN' = @{ Feature='Funkcionalnost','Mogućnost','Mogucnost','Osobina'; Background='Kontekst','Osnova','Pozadina'; Scenario='Scenario','Primer'; ScenarioOutline='Struktura scenarija','Skica','Koncept'; Examples='Primeri','Scenariji'; Given='Zadato','Zadate','Zatati'; When='Kada','Kad'; Then='Onda'; And='I'; But='Ali' };
            'sv-SV' = @{ Feature='Egenskap'; Background='Bakgrund'; Scenario='Scenario'; ScenarioOutline='Abstrakt Scenario','Scenariomall'; Examples='Exempel'; Given='Givet'; When='När'; Then='Så'; And='Och'; But='Men' };
            'tr-TR' = @{ Feature='Özellik'; Background='Geçmiş'; Scenario='Senaryo'; ScenarioOutline='Senaryo taslağı'; Examples='Örnekler'; Given='Diyelim ki'; When='Eğer ki'; Then='O zaman'; And='Ve'; But='Fakat','Ama' };
            'uk-UK' = @{ Feature='Функціонал'; Background='Передумова'; Scenario='Сценарій'; ScenarioOutline='Структура сценарію'; Examples='Приклади'; Given='Припустимо','Припустимо, що','Нехай','Дано'; When='Якщо','Коли'; Then='То','Тоді'; And='І','А також','Та'; But='Але' };
            'uz-UZ' = @{ Feature='Функционал'; Background='Тарих'; Scenario='Сценарий'; ScenarioOutline='Сценарий структураси'; Examples='Мисоллар'; Given='Агар'; When='Агар'; Then='Унда'; And='Ва'; But='Лекин','Бирок','Аммо' };
            'vi-VI' = @{ Feature='Tính năng'; Background='Bối cảnh'; Scenario='Tình huống','Kịch bản'; ScenarioOutline='Khung tình huống','Khung kịch bản'; Examples='Dữ liệu'; Given='Biết','Cho'; When='Khi'; Then='Thì'; And='Và'; But='Nhưng' };
            'zh-CN-ZH-CN' = @{ Feature='功能'; Background='背景'; Scenario='场景'; ScenarioOutline='场景大纲'; Examples='例子'; Given='假如'; When='当'; Then='那么'; And='而且'; But='但是' };
            'zh-TW-ZH-TW' = @{ Feature='功能'; Background='背景'; Scenario='場景','劇本'; ScenarioOutline='場景大綱','劇本大綱'; Examples='例子'; Given='假設'; When='當'; Then='那麼'; And='而且','並且'; But='但是' };
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
            But = (One-Of ($localizedKeywords.But))
        }
    $result.Add('Keywords', @($result.Feature, $result.Background, $result.Scenario, $result.ScenarioOutline, $result.Given, $result.When, $result.Then, $result.Examples, $result.And, $result.But | ForEach-Object { $_ }))
    return $result
}

$GherkinKeywordParsers = Build-GherkinKeywordParsers -cultureName $cultureName
#endregion

#region Grammar from https://github.com/cucumber/gherkin/blob/master/gherkin.berp converted to Powershell
$Comment = ([regex]'\s*#.*$')

$TagLine = Repeat ([regex]'\s*@(\S+)')

$TagsParser = (from_ tagNames in (Repeat (Complete-Line $TagLine))),
              (select_ { @($tagNames | ForEach-Object { $_ }) })

$Other = (Anything-But (One-Of @($GherkinKeywordParsers.Keywords, ([regex]'\s*(\|)'), ([regex]'\s*(@)'), ([regex]'\s*(""")\s*$') | ForEach-Object { $_ }))), ([regex]'(.*)$')

$DescriptionHelper = Repeat (One-Of (Complete-Line $Comment), (Complete-Line $Other)) -allowZeroRepetition

$TableRow = Complete-Line(@(([regex]'\s*[|]'), (Repeat ([regex]'\s*([^|]*)[|]'))))

$DataTable = (from_ parsedTableHeader in $TableRow),
             (from_ parsedTableData in (Repeat $TableRow -allowZeroRepetition)),
             (select_ {
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
                 @{ Header = @($tableHeaderNames); Rows = @($parsedTableRows) }
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
    return  (from_ scenarioTags in (Optional $TagsParser)),
            (from_ scenarioName in (Complete-Line (Gherkin-LineParser $scenarioOrScenarioOutlineLexem))),
            (from_ scenarioDescription in $DescriptionHelper),
            (from_ scenarioStepBlocks in (Repeat $ScenarioStepBlock -allowZeroRepetition)),
            (select_ { @{ Title = $scenarioName; Description = $scenarioDescription; Tags = $scenarioTags; ScenarioBlocks = $scenarioStepBlocks } })
}

$Scenario = Scenario-Parser $GherkinKeywordParsers.Scenario

$ExamplesDefinition = (from_ examplesTags in (Optional $TagsParser)),
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

$Feature_Header = (from_ featureTags in (Optional $TagsParser)),
                  (from_ featureName in (Complete-Line (Gherkin-LineParser $GherkinKeywordParsers.Feature))),
                  (from_ featureDescription in $DescriptionHelper),
                  (select_ { @{ Name = $featureName; Description = $featureDescription; Tags = $featureTags } })

$Feature = (from_ featureHeader in $Feature_Header),
           (from_ parsedBackground in (Optional -parser $Background -orElse @{ StepBlocks = $null })),
           (from_ allScenarios in (Repeat (One-Of $Scenario, $ScenarioOutline) -allowZeroRepetition)),
           (select_ { @{
                        Title = $featureHeader.Name;
                        Description = $featureHeader.Description;
                        Tags = $featureHeader.Tags;
                        Background = $parsedBackground;
                        Scenarios = $allScenarios } })

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

function Invoke-GherkinHooks($hookType)
{
    function Tags-AllowHookInvocation([array] $requiredTags)
    {
        if ($requiredTags.Length -eq 0 -or $hookType.EndsWith('TestRun'))
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
        'SetupTestRun' { Log-TestRunning 'Starting test run' }
        'SetupFeature' { Log-TestRunning "Starting feature '$([FeatureContext]::Current.FeatureInfo.Title)'" }
        'SetupScenario' { Log-TestRunning "Starting Scenario '$([ScenarioContext]::Current.ScenarioInfo.Title)'" }
    }

    foreach ($hookData in (Get-GherkinHooks -hookType $hookType | Where-Object { Tags-AllowHookInvocation -requiredTags @($_.Tags | Except-Nulls) }))
    {
        & $hookData.Script
    }

    switch ($hookType)
    {
        'TeardownTestRun' { Log-TestRunning 'Finished test run' }
        'TeardownFeature' { Log-TestRunning "Finished feature '$([FeatureContext]::Current.FeatureInfo.Title)'" }
        'TeardownScenario' { Log-TestRunning "Finished scenario '$([ScenarioContext]::Current.ScenarioInfo.Title)'" }
    }
}

function Bind-ToStepExecuter($stepType, $stepText, $extraArgument)
{
    $stepDefinitionsOfGivenType = switch ($stepDefinitionDictionary = Get-Variable -Name GherkinStepDefinitionDictionary03C98485EFD84C888750187736C181A7 -Scope Global -ValueOnly -ErrorAction Ignore)
    {
        $null { @() }
        default { @($stepDefinitionDictionary[$stepType] | Except-Nulls) }
    }

    $matchingStepDefinitions = @($stepDefinitionsOfGivenType | `
                                 ForEach-Object { @{ StepPattern = $_.StepPattern; StepPatternMatchingResult = $_.StepPattern.Match($stepText); StepScript = $_.StepScript } } | `
                                 Where-Object { $_.StepPatternMatchingResult.Success})

    switch ($matchingStepDefinitions.Length) {
        0 {
            throw "Could not locate step definition for the step [$stepText] of type [$stepType]."
        }
        1 {
            $matchingStep = $matchingStepDefinitions[0]
            $matchedGroups = $matchingStep.StepPatternMatchingResult.Groups
            $matchedArgumentValues = switch ($argumentsNumber = $matchedGroups.Count)
                {
                    { $argumentsNumber -gt 1 } { @(@($matchedGroups)[1..($argumentsNumber - 1)] | ForEach-Object { $_.ToString() }) }
                    default { @() }
                }
            @{ StepPattern = $matchingStep.StepPattern; StepScript = $matchingStep.StepScript; StepArguments = @($matchedArgumentValues) + @($extraArgument | Except-Nulls) }
        }
        default {
            throw @"
The step with text [$stepText] is matched by each one of the following StepDefinition patterns:
$([String]::Join([Environment]::NewLine, @($matchingStepDefinitions | ForEach-Object { "$($_.StepPattern)" })))
Please refine the pattern's regex-es so that each step text was matched by exaqclty one pattern
"@
        }
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
        Invoke-GherkinHooks -hookType SetupScenarioStep
        Invoke-Command -ScriptBlock $stepBinding.StepScript -ArgumentList $stepBinding.StepArguments
        Invoke-GherkinHooks -hookType TeardownScenarioStep
        Log-TestRunning "Finished executing step '$($stepBinding.StepPattern)' (took $([int]$stepStopwatch.Elapsed.TotalSeconds) seconds)."
    }
}

filter Run-ScenarioBlock
{
    $currentBlock = $_
    [ScenarioContext]::Current.ScenarioInfo.CurrentScenarioBlock = $currentBlock.BlockType
    Invoke-GherkinHooks -hookType SetupScenarioBlock
    $currentBlock.Steps | Run-ScenarioStep $currentBlock.BlockType
    Invoke-GherkinHooks -hookType TeardownScenarioBlock
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

            Invoke-GherkinHooks -hookType SetupScenario
            Join-ScenarioBlocks -backgroundBlocks $backgroundBlocks -scenarioBlocks $scenario.ScenarioBlocks | Run-ScenarioBlock
            Invoke-GherkinHooks -hookType TeardownScenario

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
                                                $extraArgument = @{
                                                    Header = @($extraArgument.Header | ForEach-Object { $_.Replace("<$columnName>", $exampleColumnValue) });
                                                    Rows = @($extraArgument.Rows | `
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
                                                }
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
    Invoke-GherkinHooks -hookType SetupFeature
	$scenarioExecutionResults = @()
    $feature.Scenarios | `
        Except-Nulls | `
        Expand-ScenarioOutline | `
		Run-SingleScenario -featureTags $feature.Tags -backgroundBlocks $feature.Background.StepBlocks | `
		ForEach-Object { $scenarioExecutionResults += @($_) }
    Invoke-GherkinHooks -hookType TeardownFeature
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
        @{ ScenarioFilePath = $scriptFilePath; Feature = $parsingResult.Value }
    })

Setup-TestRunContext

$featureExecutionResults = @()

if ($parsedScenarios.Length -gt 1 -or ($parsedScenarios.Length -eq 1 -and $Null -ne $parsedScenarios[0].Feature))
{
    Invoke-GherkinHooks -hookType SetupTestRun
    $featureExecutionResults = @($parsedScenarios | ForEach-Object { Run-FeatureScenarios -featureFile $_.ScenarioFilePath -feature $_.Feature })
    Invoke-GherkinHooks -hookType TeardownTestRun
}

return $featureExecutionResults