param (
    [string] $scenarioFiles,
    [string] $tags = $Null,
    [string] $cultureName = 'en-US',
    [string] $logParsingToFile = $Null)

trap { 
    if ($global:Error.Count -gt 0)
    {
        foreach ($record in @($global:Error[0]))
        {
            $record | Format-List * -Force | Out-Host
            $record.InvocationInfo | Format-List * | Out-Host
            $Exception = $record.Exception | Out-Host
            for ($i = 0; $Exception; $i++, ($Exception = $Exception.InnerException))
            {
                "$i" * 80 | Out-Host
                $Exception | Format-List * -Force | Out-Host
            }
        }
    }

    exit 1; 
    continue 
}

$totalScenarios = 0
$succeededScenarios = 0

#region class TextLine
function Build-TextLine([string] $chars, [int] $offset)
{
    @{ Chars = $chars; Offset = $offset }
}

function Line-ContainsNonSpaceCharacters($textLine)
{
    return $textLine.Chars.Substring($textLine.Offset).Trim().Length -gt 0
}
#endregion

#region class ParsingResult
function Build-ParsingResult($value, $rest)
{
    @{ Value = $value; Rest = $rest }
}
#endregion

#region class Content
function Build-Content([array] $lines, [int] $currentLine)
{
    @{ Lines = $lines; CurrentLine = $currentLine }
}

function Get-IndexOfFirstNonSpaceCharacter($lineChars)
{
    $matchingResult = ([regex]'\S').Match($lineChars)
    switch ($matchingResult.Success) { $False { $Null } $True { $matchingResult.Index } }
}

function Get-NextLine($content)
{
    for ($nextLineIndex = $content.CurrentLine + 1; $nextLineIndex -lt $content.Lines.Length; $nextLineIndex++)
    {
        $lineChars = $content.Lines[$nextLineIndex]
        $offset = Get-IndexOfFirstNonSpaceCharacter $lineChars
        if ($offset -ne $Null)
        {
            return @{
                Line = (Build-TextLine -chars $lineChars -offset $offset);
                Rest = (Build-Content -lines $content.Lines -currentLine $nextLineIndex)
            }
        }
    }

    return $Null
}
#endregion 

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

function List-ScenarioFiles($scenarioFiles)
{
    if ([System.IO.File]::Exists($scenarioFiles))
    {
        return @($scenarioFiles)
    }

    if ([System.IO.Directory]::Exists($scenarioFiles))
    {
        return @(Get-ChildItem $scenarioFiles -Recurse | Where { $_ -is [System.IO.FileInfo] } | ForEach-Object { $_.FullName })
    }

    $folderPath = Split-Path -Path $scenarioFiles -Parent
    $filter =  Split-Path -Path $scenarioFiles -Leaf
    return @(Get-ChildItem -Path $folderPath -Filter $filter | Where { $_ -is [System.IO.FileInfo] })
}
#endregion

#region Monadic Parsing
function Parse-ContentWithParser($parser, $content)
{
    if ($parser -is [scriptblock])
    {
        return & $parser $content
    }

    if ($parser -is [string])
    {
        $patternLength = $parser.Length
        if ([String]::Compare($content.Chars, $content.Offset, $parser, 0, $patternLength) -ne 0)
        {
            Log-Parsing "Literal [$parser] failed on line $($content.Chars) at offset $($content.Offset)"
            return $Null
        }

        $parsedValue = $parser
        $restOfLine = Build-TextLine -chars $content.Chars -offset ($content.Offset + $patternLength)
        Log-Parsing "Literal [$parser] matched on line $($content.Chars) at offset $($content.Offset)"
        return Build-ParsingResult -value $parsedValue -rest $restOfLine
    }

    if ($parser -is [regex])
    {
        $matchingResult = $parser.Match($content.Chars, $content.Offset)
        if (-Not $matchingResult.Success -or ($matchingResult.Index -ne $content.Offset))
        {
            Log-Parsing "Regex [$parser] failed on line $($content.Chars) at offset $($content.Offset)"
            return $Null
        }

        $parsedValue = $matchingResult.Groups[1].Value
        $restOfLine = Build-TextLine -chars $content.Chars -offset ($content.Offset + $matchingResult.Length)
        Log-Parsing "Regex [$parser] matched on line $($content.Chars) at offset $($content.Offset), length=$($matchingResult.Length). Match result: $parsedValue"
        return Build-ParsingResult -value $parsedValue -rest $restOfLine
    }

    if ($parser -is [array])  
    {
        $value = $Null  # when many parsers are specified then the result will be the last one's output
        $restOfContent = $content
        foreach ($nextParser in $parser)
        {
            $parsingResult = Parse-ContentWithParser -content $restOfContent -parser $nextParser
            if ($parsingResult -eq $Null)
            {
                return $Null
            }

            $value = $parsingResult.Value  
            $restOfContent = $parsingResult.Rest
        }

        return Build-ParsingResult -value $value -rest $restOfContent 
    }

    throw "Do not know how to parse with $parser of type $($parser.GetType())"
}

function Optional($parser)
{
    Verify-That -condition ($parser -ne $Null) -message 'Program logic error: Optional($Null)'

    $captured_ParseContentWithParser_function = ${function:Parse-ContentWithParser}
    $captured_BuildParsingResult_function = ${function:Build-ParsingResult}

    return {
        param ($content)

        $parsingResult = & $captured_ParseContentWithParser_function -parser $parser -content $content
        if ($parsingResult -ne $Null)
        {
            return $parsingResult 
        }

        return (& $captured_BuildParsingResult_function -value $Null -rest $content)
    }.GetNewClosure()
}

function Repeat($parser)
{
    Verify-That -condition ($parser -ne $Null) -message 'Program logic error: Repeat($Null)'

    $captured_ParseContentWithParser_function = ${function:Parse-ContentWithParser}
    $captured_BuildParsingResult_function = ${function:Build-ParsingResult}

    return {
        param ($content)

        $values = @()

        $restOfContent = $content
        while ($True)
        {
            $parsingResult = & $captured_ParseContentWithParser_function -content $restOfContent -parser $parser
            if ($parsingResult -eq $Null)
            {
                if ($values.Length -eq 0)
                {
                    return $Null
                }

                return & $captured_BuildParsingResult_function -value $values -rest $restOfContent
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

    $captured_ParseContentWithParser_function = ${function:Parse-ContentWithParser}

    return {
        param ($content)

        foreach ($parserAlternative in $parsers)
        {
            $parsingResult = & $captured_ParseContentWithParser_function -content $content -parser $parserAlternative
            if ($parsingResult -ne $Null)
            {
                return $parsingResult 
            }
        }

        return $Null
    }.GetNewClosure()
}

function Anything-But($parser)
{
    Verify-That -condition $parser -ne $Null -message 'Program logic error: Anything-But($Null)' 

    $captured_ParseContentWithParser_function = ${function:Parse-ContentWithParser}
    $captured_BuildParsingResult_function = ${function:Build-ParsingResult}

    return {
        param ($content)

        $parsingResult = & $captured_ParseContentWithParser_function -content $content -parser $parser
        if ($parsingResult -ne $Null)
        {
            return $Null 
        }

        return (& $captured_BuildParsingResult_function -value $True -rest $content)
    }.GetNewClosure()
}
#endregion

#region Parsing single line of text 
function Parse-TextLineWithTokenParser($tokenParser, $textLine)
{
    $parsingResult = Parse-ContentWithParser -parser $tokenParser -content $textLine

    if ($parsingResult -eq $Null) # unrecognized pattern
    {
        return $Null
    }

    if (Line-ContainsNonSpaceCharacters $parsingResult.Rest) # token parser matched the beginning of the line, but there still remain some unrecognized characters 
    {
        return $Null
    }

    return $parsingResult.Value
}

function Token($tokenParser)
{
    Verify-That -condition ($tokenParser -ne $Null) -message "Program logic error: `$tokenParser is Null"

    $captured_GetNextLine_function = ${function:Get-NextLine}
    $captured_ParseTextLineWithTokenParser_function = ${function:Parse-TextLineWithTokenParser}
    $captured_BuildContent_function = ${function:Build-Content}
    return {
            param ($content)

            $nextLine = & $captured_GetNextLine_function $content
            if ($nextLine -eq $Null)
            {
                return $Null
            }

            $lineParsingResult = & $captured_ParseTextLineWithTokenParser_function -textLine $nextLine.Line -tokenParser $tokenParser
            if ($lineParsingResult -eq $Null)
            {
                return $Null
            }

            return @{ Value = $lineParsingResult;  Rest = $nextLine.Rest }
        }.GetNewClosure()
}

function EndOfContent
{
    $captured_GetNextLine_function = ${function:Get-NextLine}
    $captured_BuildParsingResult_function = ${function:Build-ParsingResult}
    $captured_LineContainsNonSpaceCharacters_function = ${function:Line-ContainsNonSpaceCharacters}

    return {
        param ($content)

        while ($True)
        {
            $nextLine = & $captured_GetNextLine_function $content
            if ($nextLine -eq $Null)
            {
                return (& $captured_BuildParsingResult_function -value $True -rest $content)
            }

            if (& $captured_LineContainsNonSpaceCharacters_function -textLine $nextLine.Line)
            {
                return $Null
            }

            $content = $nextLine.Rest
        }
    }.GetNewClosure()
}

function Attach-Debugger($contextHint)
{
    $captured_BuildParsingResult_function = ${function:Build-ParsingResult}
    return {
        param ($content)
        Write-Host "Attaching Debugger at $contextHint..."
        return (& $captured_BuildParsingResult_function -value $True -rest $content)
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
 
    Verify-That -condition ($parser -ne $Null) -message "Program logic error: (from_ $parsingResultName in `$Null)"

    $captured_ParseContentWithParser_Function = ${function:Parse-ContentWithParser}
    $captured_LogParsing_Function = ${function:Log-Parsing}

    return {
        param ($content)

        $parsingResult = & $captured_ParseContentWithParser_Function -parser $parser -content $content

        if ($parsingResult -ne $Null)
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

    $captured_BuildParsingResult_function = ${function:Build-ParsingResult}

    return {
        param ($content)
        # by now, all variables calculated in previous 'from_' invocations should be accessible in this scope, so $parsedValueProducer can do its job
        $calculatedValue = & $parsedValueProducer
        return & $captured_BuildParsingResult_function -value $calculatedValue -rest $content
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
            'en-EN' = @{ Feature='Feature'; Background='Background'; Scenario='Scenario'; ScenarioOutline='Scenario Outline','Scenario Template'; Examples='Examples','Scenarios'; Given='Given'; When='When'; Then='Then'; And='And'; But='But' };
            'en-US' = @{ Feature='Feature'; Background='Background'; Scenario='Scenario'; ScenarioOutline='Scenario Outline','Scenario Template'; Examples='Examples','Scenarios'; Given='Given'; When='When'; Then='Then'; And='And'; But='But' };
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

    $localizedKeywords = $allGherkinKeywords[$cultureName]
    Verify-That `
        -condition $localizedKeywords -ne $Null `
        -message "No Gherkin keywords are known for culture name $cultureName. Use one of the following culture names: $([String]::Join(',', $allGherkinKeywords.Keys))"

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

# region Grammar from https://github.com/cucumber/gherkin/blob/master/gherkin.berp converted to powershell 
function Gherkin-LineParser($keywordParser, [switch] $emptyRestOfLineIsAnError)
{
    $restOfLineParser = switch ($emptyRestOfLineIsAnError) { $False { (One-Of ([regex]'\s(.*)'), ([regex]'$')) } $True { ([regex]'\s(.*)') } }
    return $keywordParser,
           (from_ restOfLine in $restOfLineParser),
           (select_ { $restOfLine | Trim-String })
}

$Comment = ([regex]'\s*#.*$')

$TagLine = (from_ firstTagName in ([regex]'\s*@(\S+)')),
           (from_ theOtherTagNames in (Optional (Repeat ([regex]'\s+@(\S+)')))),
           (select_ { @($firstTagName) + @($theOtherTagNames | Except-Nulls) })

$TagsParser = (from_ tagNames in (Repeat (Token $TagLine))), 
        (select_ { @($tagNames | ForEach-Object { $_ }) })

$Other = (Anything-But (One-Of @($GherkinKeywordParsers.Keywords, ([regex]'\s*(\|)'), ([regex]'\s*(@)'), ([regex]'\s*(""")\s*$') | ForEach-Object { $_ }))), ([regex]'(.*)$')

$DescriptionHelper = (Optional (Repeat (One-Of (Token $Comment), (Token $Other))))

$TableRow = Token(([regex]'\s*[|]'), (Repeat ([regex]'\s*([^|]*)[|]')))

$DataTable = (from_ parsedTableHeader in $TableRow),
             (from_ parsedTableData in (Optional (Repeat $TableRow))),
             (select_ { 
                 $tableHeaderNames = @($parsedTableHeader | ForEach-Object { switch ($_) { $Null { '' } default { $_.Trim() } } })
                 if ($parsedTableData -eq $Null)
                 {
                     return @{ Header = @($tableHeaderNames); Rows = @() } 
                 }

                 $parsedTableRows = @($parsedTableData | `
                                    ForEach-Object {
                                        $dataRow = @($_)

                                        if ($dataRow.Length -ne $tableHeaderNames.Length)
                                        { 
                                            throw "Table Header $([String]::Join('|', $tableHeaderNames)) has different number of columns compared to the data row $([String]::Join('|', $dataRow))" 
                                        }

                                        $resultingRow = @{}
                                        for ($cellIndex = 0; $cellIndex -ne $tableHeaderNames.Length; $cellIndex++)
                                        {
                                            $cellValue = $dataRow[$cellIndex]
                                            $trimmedCellValue = switch ($cellValue) { $Null { '' } default { $cellValue.Trim() } } 
                                            $resultingRow.Add($tableHeaderNames[$cellIndex], $trimmedCellValue)
                                        }

                                        $resultingRow 
                                    })
                 @{ Header = @($tableHeaderNames); Rows = @($parsedTableRows) } })

$DocStringSeparator = [regex]'\s*(""")\s*$'

$DocString = (Token $DocStringSeparator), 
             (from_ parsedDocStringLine in (Optional (Repeat (Anything-But (Token $DocStringSeparator)), (Token ([regex]'(.*)'))))), 
             (Token $DocStringSeparator),
             (select_ { [String]::Join([Environment]::NewLine, $parsedDocStringLine) })

$StepArgument = (One-Of $DataTable, $DocString)

function SingleStep-Parser($firstStepLineParser)
{
    (from_  parsedStepText in $firstStepLineParser),
    (from_ parsedStepExtraArgument in (Optional $StepArgument)),
    (select_ { @{ StepText = $parsedStepText; ExtraArgument = $parsedStepExtraArgument } })
}

function StepBlock-Parser($stepKeywordParser)
{
    if ([Object]::ReferenceEquals($stepKeywordParser, $GherkinKeywordParsers.Given))
    {
        $stepType = '[StepTypeEnum]::Given'
    }
    elseif ([Object]::ReferenceEquals($stepKeywordParser, $GherkinKeywordParsers.When))
    {
        $stepType = '[StepTypeEnum]::When'
    }
    elseif ([Object]::ReferenceEquals($stepKeywordParser, $GherkinKeywordParsers.Then))
    {
        $stepType = '[StepTypeEnum]::Then'
    }

    $allButFirstLineInBlockParser = One-Of @($stepKeywordParser, $GherkinKeywordParsers.And, $GherkinKeywordParsers.But | ForEach-Object { Token (Gherkin-LineParser $_ -emptyRestOfLineIsAnError) })
    $captured_ExceptNulls_function = ${function:Except-Nulls}

    return (from_ firstLineInBlock in (SingleStep-Parser (Token (Gherkin-LineParser $stepKeywordParser -emptyRestOfLineIsAnError)))),
           (from_ otherLinesInBlock in (Optional (Repeat (SingleStep-Parser ($allButFirstLineInBlockParser))))),
           (select_ { @{ BlockType = $stepType; Steps = @($firstLineInBlock) + @($otherLinesInBlock | & $captured_ExceptNulls_function) } }.GetNewClosure() ) 
}

$ScenarioStepBlock = One-Of (StepBlock-Parser $GherkinKeywordParsers.Given), (StepBlock-Parser $GherkinKeywordParsers.When), (StepBlock-Parser $GherkinKeywordParsers.Then)

$Background = (from_ backgroundName in (Token (Gherkin-LineParser $GherkinKeywordParsers.Background))),
              (from_ backgroundDescription in $DescriptionHelper),
              (from_ backgroundStepBlocks in (Optional (Repeat $ScenarioStepBlock))),
              (select_ { @{ Name = $backgroundName; Description = $backgroundDescription; StepBlocks = $backgroundStepBlocks }})

$Scenario = (from_ scenarioTags in (Optional $TagsParser)), 
            (from_ scenarioName in (Token (Gherkin-LineParser $GherkinKeywordParsers.Scenario))), 
            (from_ scenarioDescription in $DescriptionHelper),
            (from_ scenarioStepBlocks in (Optional (Repeat $ScenarioStepBlock))),
            (select_ { @{ Title = $scenarioName; Description = $scenarioDescription; Tags = $scenarioTags; ScenarioBlocks = $scenarioStepBlocks; IsScenarioOutline = $False } })

$ExamplesDefinition = (from_ examplesTags in (Optional $TagsParser)), 
                      (Token (Gherkin-LineParser $GherkinKeywordParsers.Examples)),
                      (from_ examplesDescription in $DescriptionHelper),
                      (from_ examplesTable in (Optional $DataTable)),
                      (select_ { @{
                                    Tags = $examplesTags;
                                    Description = $examplesDescription;
                                    ExampleVariableNames = $examplesTable.Header;
                                    ExamplesData = $examplesTable.Rows
                                    }})


$ScenarioOutline = (from_ scenarioOutlineName in (Token (Gherkin-LineParser $GherkinKeywordParsers.ScenarioOutline))),
                   (from_ scenarioOutlineDescription in $DescriptionHelper),
                   (from_ scenarioOutlineStepBlocks in (Optional (Repeat $ScenarioStepBlock))),
                   (from_ scenarioOutlineExamples in (Optional (Repeat $ExamplesDefinition))),
                   (select_ { @{
                                Title = $scenarioOutlineName;
                                Description = $scenarioOutlineDescription;
                                StepBlocks = $scenarioOutlineStepBlocks;
                                SetsOfExamples = $scenarioOutlineExamples;
                                IsScenarioOutline = $True
                               }})

$Feature_Header = (from_ featureTags in (Optional $TagsParser)), 
                  (from_ featureName in (Token (Gherkin-LineParser $GherkinKeywordParsers.Feature))), 
                  (from_ featureDescription in $DescriptionHelper),
                  (select_ { @{ Name = $featureName; Description = $featureDescription; Tags = $featureTags } })

$Feature = (from_ featureHeader in $Feature_Header), 
           (from_ parsedBackground in (Optional $Background)), 
           (from_ scenarios in (Optional (Repeat (One-Of $Scenario, $ScenarioOutline)))),
           (select_ { @{ 
                        Title = $featureHeader.Name; 
                        Description = $featureHeader.Description; 
                        Tags = $featureHeader.Tags; 
                        Background = $parsedBackground; 
                        Scenarios = $scenarios } })

$GherkinDocument = (from_ parsedFeature in (Optional $Feature)),
                   (EndOfContent),
                   (select_ { $parsedFeature })
#endregion

#region Running scenarios
function Setup-GherkinHookInfrastructure
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

    public void ModifyValue(string name, ScriptBlock modifyValue)
    {
        modifyValue.Invoke(GetValue(name));
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

function Invoke-GherkinHooks($hookType, $hookArgument)
{
    foreach ($hook in (Get-GherkinHooks -hookType $hookType))
    {
        if ($hookArgument -ne $Null)
        {
            & $hook $hookArgument
        }
        else
        {
            & $hook 
        }
    }
}

function Get-GherkinStepDefinitions($stepType)
{
    if (-Not (Test-Path variable:global:GherkinStepDefinitionDictionary03C98485EFD84C888750187736C181A7))
    {
        return @()
    }

    $stepDefinitionDictionary = Get-Variable -Name GherkinStepDefinitionDictionary03C98485EFD84C888750187736C181A7 -Scope Global -ValueOnly
    if (-Not ($stepDefinitionDictionary.Contains($stepType)))
    {
        return @()
    }

    return $stepDefinitionDictionary[$stepType]
}

function Bind-ToStepExecuter($stepType, $stepText, $extraArgument)
{
    $stepDefinitions = Get-GherkinStepDefinitions -stepType $stepType
    $matchingStepDefinitions = @($stepDefinitions | `
                                 ForEach-Object { @{ StepPattern = $_.StepPattern; StepPatternMatchingResult = $_.StepPattern.Match($stepText); StepScript = $_.StepScript } } | `
                                 Where { $_.StepPatternMatchingResult.Success})
    switch ($matchingStepDefinitions.Length) {
        0 { 
            $Null 
        }
        1 { 
            $matchingStep = $matchingStepDefinitions[0]
            $matchedGroups = $matchingStep.StepPatternMatchingResult.Groups
            $argumentsNumber = @($matchedGroups).Length
            $stepArguments = @(@($matchedGroups)[1..$argumentsNumber]) + @($extraArgument | Except-Nulls)
            @{ StepScript = $matchingStep.StepScript; StepArguments = $stepArguments }
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

function Report-MissingStepDefinition($stepType, $stepText)
{
    Write-Host "Could not locate step definition for the step [$stepText] of type [$stepType]."
}

function Run-ScenarioStep($stepType)
{
    process
    {
        $stepText = $_.StepText
        $extraArgument = $_.ExtraArgument
        $stepBinding = Bind-ToStepExecuter -stepType $stepType -stepText $stepText -extraArgument $extraArgument
        if ($stepBinding -ne $Null)
        {
            Invoke-GherkinHooks -hookType SetupScenarioStep -hookArgument $stepType
            Invoke-Command -ScriptBlock $stepBinding.StepScript -ArgumentList $stepBinding.StepArguments
            Invoke-GherkinHooks -hookType TeardownScenarioStep -hookArgument $stepType
        }
        else
        {
            Report-MissingStepDefinition -stepType $stepType -stepText $stepText
        }
    }
}

filter Run-ScenarioBlock
{
    $currentBlock = $_
    [ScenarioContext]::Current.CurrentScenarioBlock = $currentBlock.BlockType
    Invoke-GherkinHooks -hookType SetupScenarioBlock -hookArgument $currentBlock.BlockType
    $currentBlock.Steps | Run-ScenarioStep $currentBlock.BlockType
    Invoke-GherkinHooks -hookType TeardownScenarioBlock -hookArgument $currentBlock.BlockType
}

function IsNull-OrEmptyArray($collection)
{
    $collection -eq $Null -or ($collection -is [array] -and $collection.Length -eq 0)
}

function Join-ScenarioBlocks($backgroundBlocks, $scenarioBlocks)
{
    Verify-That -condition ($backgroundBlocks -eq $Null -or $backgroundBlocks -is [array]) -message '-backgroundBlocks is not an array'
    Verify-That -condition ($scenarioBlocks  -eq $Null -or $scenarioBlocks -is [array]) -message '-scenarioBlocks is not an array'

    if (IsNull-OrEmptyArray $backgroundBlocks)
    {
        return $scenarioBlocks
    }

    if (IsNull-OrEmptyArray $scenarioBlocks)
    {
        return $backgroundBlocks
    }

    $lastBackgroundBlockIsOfSameTypeAsFirstScenarioBlock = ($backgroundBlocks[-1].BlockType -eq $scenarioBlocks[0].BlockType)
    if (-Not $lastBackgroundBlockIsOfSameTypeAsFirstScenarioBlock)
    {
        return @($backgroundBlocks) + @($scenarioBlocks)
    }

    $result = @()
    for ($i = 0; $i -lt $backgroundBlocks.Length - 1; $i++)
    {
        $result += @($backgroundBlocks[$i])
    }

    $joinedLastBackgroundBlockAndFirstScenarioBlockSteps = @($backgroundBlocks[$backgroundBlocks.Length - 1].Steps) + @($scenarioBlocks[0].Steps)
    $result += @(@{ BlockType = $scenarioBlocks[0].BlockType; Steps = $joinedLastBackgroundBlockAndFirstScenarioBlockSteps })
    $result += @($scenarioBlocks[1..($scenarioBlocks.Length - 1)])

    return @($result)
}

function Scenario-ShouldBeIgnoredAccordingToItsTags($scenarioTags)
{
    if ([string]::IsNullOrEmpty($tags))
    {
        return $False
    }

    $requiredTagsAndScenarioTagsIntersection = @( @($tags -split ',') | Where { -Not ([string]::IsNullOrEmpty($_)) -and ($scenarioTags -contains $_.Trim(@('@', '~'))) } )
    return $requiredTagsAndScenarioTagsIntersection.Length -eq 0
}

function Run-SingleScenario($featureTags, $backgroundBlocks)
{
    process
    {
        try
        {
            $scenario = $_

            $scenario.Tags = @($featureTags | Except-Nulls) + @($scenario.Tags | Except-Nulls)
            if (Scenario-ShouldBeIgnoredAccordingToItsTags -scenarioTags $scenario.Tags)
            {
                return
            }

            [ScenarioContext]::Current = New-Object ScenarioContext
            [ScenarioContext]::Current.ScenarioInfo = $scenario 

            $script:totalScenarios++
            Invoke-GherkinHooks -hookType SetupScenario -hookArgument $scenario
            Join-ScenarioBlocks -backgroundBlocks @($backgroundBlocks | Except-Nulls) -scenarioBlocks @($scenario.ScenarioBlocks | Except-Nulls) | Run-ScenarioBlock
            Invoke-GherkinHooks -hookType TeardownScenario -hookArgument $scenario
            $script:succeededScenarios++
            Write-Host "$([FeatureContext]::Current.FeatureInfo.Title).$($scenario.Title)`t`tsucceeded."
        }
        catch
        {
            Write-Host "$([FeatureContext]::Current.FeatureInfo.Title).$($scenario.Title)`t`tfailed."
        }
    }
}

function Run-SingleScenarioOrScenarioOutline($featureTags, $backgroundBlocks)
{
    process
    {
        $scenario = $_
        if ($scenario.IsScenarioOutline)
        {
            $scenario.SetsOfExamples | `
                ForEach-Object {
                    $currentSetOfExamples = $_
                    $firstColumnName = $currentSetOfExamples.ExampleVariableNames[0]

                    $currentSetOfExamples.ExamplesData | `
                        ForEach-Object { 
                            $currentExample = $_

                            $scenarioBlocks = $scenario.StepBlocks | `
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

                                                if ($extraArgument -ne $Null)
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

                            @{ 
                                Title = $scenario.Title; 
                                Description = $currentSetOfExamples.Description; 
                                Tags = $currentSetOfExamples.Tags; 
                                ScenarioBlocks = @($scenarioBlocks); 
                                IsScenarioOutline = $False 
                            } 
                        } | `
                        Run-SingleScenario -featureTags $featureTags -backgroundBlocks $backgroundBlocks 
                }
        }
        else
        {
            $scenario | Run-SingleScenario -featureTags $featureTags -backgroundBlocks $backgroundBlocks
        }
    }
}

function Run-FeatureScenarios($featureFile, $feature)
{
    [FeatureContext]::Current = New-Object FeatureContext
    [FeatureContext]::Current.FeatureInfo = $feature
    Invoke-GherkinHooks -hookType SetupFeature -hookArgument $feature
    @($feature.Scenarios | Except-Nulls) | Run-SingleScenarioOrScenarioOutline -featureTags $feature.Tags -backgroundBlocks $feature.Background.StepBlocks
    Invoke-GherkinHooks -hookType TeardownFeature -hookArgument $feature
}
#endregion

Validate -parameters @( {$scenarioFiles} )

if ((-Not [string]::IsNullOrEmpty($logParsingToFile)) -and (Test-Path $logParsingToFile))
{
    Remove-Item $logParsingToFile
}

$parsedScenarios = @(List-ScenarioFiles $scenarioFiles | ForEach-Object { 
        $scriptFilePath = $_
        $scriptFileContent = Build-Content -lines (Get-Content $scriptFilePath) -currentLine -1
        $parsingResult = Parse-ContentWithParser -content $scriptFileContent -parser $GherkinDocument 
        @{ ScenarioFilePath = $scriptFilePath; Feature = $parsingResult.Value }
    })

Setup-GherkinHookInfrastructure

if ($parsedScenarios.Length -gt 1 -or ($parsedScenarios.Length -eq 1 -and $parsedScenarios[0].Feature -ne $Null))
{
    Invoke-GherkinHooks -hookType SetupTestRun 
    $parsedScenarios | ForEach-Object { Run-FeatureScenarios -featureFile $_.ScenarioFilePath -feature $_.Feature }
    Invoke-GherkinHooks -hookType TeardownTestRun
}

Write-Host "Total scenarios: $totalScenarios. Succeeded scenarios: $succeededScenarios, Failed scenarios: $($totalScenarios - $succeededScenarios)"

return $parsedScenarios 