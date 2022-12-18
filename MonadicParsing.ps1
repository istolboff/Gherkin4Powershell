class SourceCodeLocation
{
    [int] $LineNumber
    [int] $OffsetInLine

    SourceCodeLocation([int] $ln, [int] $oil)
    {
        $this.LineNumber = $ln
        $this.OffsetInLine = $oil
    }
}

class SourceCodeFileContent
{
    [string[]] hidden   $TextLines
    [int] hidden        $CurrentLineNumber
    [int] hidden        $OffsetInCurrentLine

    SourceCodeFileContent([string[]] $textLines, [int] $currentLineNumber, [int] $offsetInCurrentLine)
    {
        Verify-That -condition ($currentLineNumber -lt $textLines.Length) -message 'Attempt to read past the end of file'
        $this.TextLines = $textLines
        $this.CurrentLineNumber = $currentLineNumber
        $this.OffsetInCurrentLine = $offsetInCurrentLine
    }

    [SourceCodeLocation] GetCurrentLocation()
    {
        return [SourceCodeLocation]::new($this.CurrentLineNumber, $this.OffsetInCurrentLine)
    }

    [string] GetCodePortion([SourceCodeLocation] $from, [SourceCodeLocation] $to)
    {
        Verify-That `
            -condition ($from.LineNumber -lt $this.TextLines.Length -and $to.LineNumber -lt $this.TextLines.Length) `
            -message 'Attempt to read past the end of file'
        if ($from.LineNumber -eq $to.LineNumber)
        {
            return $this.TextLines[$from.LineNumber].Substring($from.OffsetInLine, $to.OffsetInLine - $from.OffsetInLine)
        }

        $resultBuilder = [System.Text.StringBuilder]::new()
        $resultBuilder.AppendLine($this.TextLines[$from.LineNumber].Substring($from.OffsetInLine))
        for ($lineNumber = $from.LineNumber + 1; $lineNumber -lt $to.LineNumber; ++$lineNumber)
        {
            $resultBuilder.AppendLine($this.TextLines[$lineNumber])
        }

        $resultBuilder.Append($this.TextLines[$to.LineNumber].Substring(0, $to.OffsetInLine))
        return $resultBuilder.ToString()
    }

    [string] GetCurrentLineWithIndicatedPosition()
    {
        return $this.TextLines[$this.CurrentLineNumber].Insert($this.OffsetInCurrentLine, '↕')
    }

    [SourceCodeFileContent] Skip([int] $characterCount)
    {
        return [SourceCodeFileContent]::new($this.TextLines, $this.CurrentLineNumber, $this.OffsetInCurrentLine + $characterCount)
    }

    [bool] CurrentLineContainsNonSpaceCharacters()
    {
        $currentLineChars = $this.TextLines[$this.CurrentLineNumber]
        return $currentLineChars.Substring($this.OffsetInCurrentLine).Trim().Length -gt 0
    }

    [SourceCodeFileContent] GetNextLine()
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
                return [SourceCodeFileContent]::new($this.TextLines, $nextLineIndex, $offset)
            }
        }

        return $Null
    }
}

class ParsingResult
{
    [object] $Value

    [SourceCodeFileContent] $Rest

    ParsingResult([object] $value, [SourceCodeFileContent] $rest)
    {
        $this.Value = $value
        $this.Rest = $rest
    }
}

class Parser
{
    [array] $Parsers

    Parser([array] $p)
    {
        Verify-That -condition ($p.Length -gt 0) -message 'Program logic error: trying to parse content with an empty array of parsers'
        $this.Parsers = $p
    }
}

class MonadicParsing
{
    static [ParsingResult] ParseWith($parser, [SourceCodeFileContent] $content)
    {
        switch ($null)
        {
            { $parser -is [scriptblock] } {
                return & $parser $content
            }
            { $parser -is [string] } {
                $patternLength = $parser.Length
                $currentLineChars = $content.TextLines[$content.CurrentLineNumber]
                if ([string]::Compare($currentLineChars, $content.OffsetInCurrentLine, $parser, 0, $patternLength) -ne 0)
                {
                    Log-Parsing "Literal [$parser] failed on line $($content.GetCurrentLineWithIndicatedPosition()) at offset $($content.OffsetInCurrentLine)"
                    return $Null
                }

                Log-Parsing "Literal [$parser] matched on line $($content.GetCurrentLineWithIndicatedPosition()) at offset $($content.OffsetInCurrentLine)"
                return [ParsingResult]::new($parser, $content.Skip($patternLength))
            }
            { $parser -is [regex] } {
                $currentLineChars = $content.TextLines[$content.CurrentLineNumber]
                $matchingResult = $parser.Match($currentLineChars, $content.OffsetInCurrentLine)
                if (-Not $matchingResult.Success -or ($matchingResult.Index -ne $content.OffsetInCurrentLine))
                {
                    Log-Parsing "Regex [$parser] failed on line $($content.GetCurrentLineWithIndicatedPosition()) at offset $($content.OffsetInCurrentLine)"
                    return $Null
                }

                $parsedValue = $matchingResult.Groups[1].Value
                Log-Parsing "Regex [$parser] matched on line $($content.GetCurrentLineWithIndicatedPosition()) at offset $($content.OffsetInCurrentLine), length=$($matchingResult.Length). Match result: $parsedValue"
                return [ParsingResult]::new($parsedValue, $content.Skip($matchingResult.Length))
            }
            { $parser -is [Parser]} {
                return [MonadicParsing]::ParseWith($parser.Parsers, $content)
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

function SourceCode-Location
{
    return { 
        param ([SourceCodeFileContent] $content)
        return [ParsingResult]::new($content.GetCurrentLocation(), $content)
    }
}

function SourceCode-Content($from)
{
    return { 
        param ([SourceCodeFileContent] $content)
        if ($from -is [scriptblock])
        {
            $fromValue = [SourceCodeLocation](& $from)
        }
        elseif ($from) 
        {
            $fromValue = [SourceCodeLocation]$from
        }
        else
        {
            throw [System.ArgumentException]::new('$from', "Could not retrieve value of type [SourceCodeLocation] from $from")
        }

        return [ParsingResult]::new($content.GetCodePortion($fromValue, $content.GetCurrentLocation()), $content)
    }.GetNewClosure()
}

function Lexem-Parser([string] $lexem)
{
    if ($lexem.Length-eq 1 -and '[]().\^$|?*+{}'.IndexOf($lexem[0]) -ge 0)
    {
        ([regex]("\s*\$lexem\s*"))
    }
    else
    {
        ([regex]("\s*$lexem\s*"))
    }
}

function Optional( $parser, $orElse = $null)
{
    return {
        param ([SourceCodeFileContent] $content)
        switch ($parsingResult = [MonadicParsing]::ParseWith($parser, $content))
        {
            $null  { [ParsingResult]::new($orElse, $content) }
            default { $parsingResult }
        }
    }.GetNewClosure()
}

function Repeat($parser, $separator = $null, [int] $minimum = 1)
{
    return {
        param ([SourceCodeFileContent] $content)

        $values = @()

        $restOfContent = $content
        while ($True)
        {
            if ($null -ne $separator -and $values.Length -gt 0)
            {
                $separatorParsingResult = [MonadicParsing]::ParseWith($separator, $restOfContent)
                if ($Null -ne $separatorParsingResult)
                {
                    $parsingResult = [MonadicParsing]::ParseWith($parser, $separatorParsingResult.Rest)
                }
                else 
                {
                    $parsingResult = $null
                }
            }
            else
            {
                $parsingResult = [MonadicParsing]::ParseWith($parser, $restOfContent)
            }
            
            if ($Null -eq $parsingResult)
            {
                if ($values.Length -lt $minimum)
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
        param ([SourceCodeFileContent] $content)

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

function Anything-But( $parser)
{
    return {
        param ([SourceCodeFileContent] $content)

        $parsingResult = [MonadicParsing]::ParseWith($parser, $content)
        if ($Null -ne $parsingResult)
        {
            return $Null
        }

        return [ParsingResult]::new($True, $content)
    }.GetNewClosure()
}

function Complete-Line($parser)
{
    return {
            param ([SourceCodeFileContent] $content)

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
        param ([SourceCodeFileContent] $content)

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

function From-Parser
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True, Position=0)]
        [string]$parsingResultName,

        [Parameter(Mandatory=$true, Position=1)]
        [string][ValidateSet('in')]$textIn,

        [Parameter(Mandatory=$true, Position=2)]
        [object]$parser)

    $captured_LogParsing_Function = ${function:Log-Parsing}

    return {
        param ([SourceCodeFileContent] $content)

        function Dump($value)
        {
            if ($value -is [hashtable])
            {
                $value.GetEnumerator() | ForEach-Object { "$($_.Name)=$(Dump -value $_.Value)" }
            }
            elseif ($value -is [array])
            {
                "[$(($value | ForEach-Object { Dump -value $_ })-join ', ')]"
            }
            elseif ($null -ne $value)
            {
                $value.ToString()
            }
            else
            {
                '$null'
            }
        }

        $parsingResult = [MonadicParsing]::ParseWith($parser, $content)
        if ($Null -ne $parsingResult)
        {
            Set-Variable -Name $parsingResultName -Value $parsingResult.Value -Scope 2
            & $captured_LogParsing_Function "from_ $parsingResultName => $(Dump -value $parsingResult.Value)"
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
        [scriptblock]$parsedValueChecker)

    return  {
        param ([SourceCodeFileContent] $content)
        switch (& $parsedValueChecker) { $false { $null } default { [ParsingResult]::new($true, $content) } }
    }.GetNewClosure()
}

Set-Alias where_ Restrict-ParsedValue

function Select-ParsedValue
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True, Position=0)]
        [scriptblock]$parsedValueProducer)

    return {
        param ([SourceCodeFileContent] $content)
        # by now, all variables calculated in previous 'from_' invocations should be accessible in this scope, so $parsedValueProducer can do its job
        $calculatedValue = & $parsedValueProducer
        return [ParsingResult]::new($calculatedValue, $content)
    }.GetNewClosure()
}
Set-Alias select_ Select-ParsedValue