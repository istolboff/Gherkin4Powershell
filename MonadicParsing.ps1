class SourceCodeLocation
{
    [int] $LineNumber
    [int] $OffsetInLine

    SourceCodeLocation([int] $ln, [int] $oil)
    {
        $this.LineNumber = $ln
        $this.OffsetInLine = $oil
    }

    [string] ToString()
    {
        return "line: $($this.LineNumber), char: $($this.OffsetInLine)"
    }
}

class SourceCodeFileContent
{
    hidden [string[]]           $_textLines
    hidden [SourceCodeLocation] $_currentLocation

    SourceCodeFileContent([string[]] $textLines, [SourceCodeLocation] $currentLocation)
    {
        if ($currentLocation.LineNumber -ge $textLines.Length)
        {
            throw [System.InvalidOperationException]::new('Attempt to read past the end of file')
        }

        $this._textLines = $textLines
        $this._currentLocation = $currentLocation
    }

    [string] GetCodePortion([SourceCodeLocation] $from, [SourceCodeLocation] $to)
    {
        if ($from.LineNumber -ge $this._textLines.Length -or $to.LineNumber -ge $this._textLines.Length)
        {
            throw [System.InvalidOperationException]::new('Attempt to read past the end of file')
        }

        if ($from.LineNumber -eq $to.LineNumber)
        {
            return $this._textLines[$from.LineNumber].Substring($from.OffsetInLine, $to.OffsetInLine - $from.OffsetInLine)
        }

        $resultBuilder = [System.Text.StringBuilder]::new()
        $resultBuilder.AppendLine($this._textLines[$from.LineNumber].Substring($from.OffsetInLine))
        for ($lineNumber = $from.LineNumber + 1; $lineNumber -lt $to.LineNumber; ++$lineNumber)
        {
            $resultBuilder.AppendLine($this._textLines[$lineNumber])
        }

        $resultBuilder.Append($this._textLines[$to.LineNumber].Substring(0, $to.OffsetInLine))
        return $resultBuilder.ToString()
    }

    [SourceCodeLocation] GetCurrentLocation()
    {
        return [SourceCodeLocation]::new($this._currentLocation.LineNumber, $this._currentLocation.OffsetInLine)
    }

    [string] GetCurrentLine()
    {
        return $this._textLines[$this._currentLocation.LineNumber]
    }

    [int] GetOffsetInCurrentLine()
    {
        return $this._currentLocation.OffsetInLine
    }

    [string] GetCurrentLineWithIndicatedPosition()
    {
        return $this._textLines[$this._currentLocation.LineNumber].Insert($this._currentLocation.OffsetInLine, '↕')
    }

    [SourceCodeFileContent] Skip([int] $characterCount)
    {
        return [SourceCodeFileContent]::new(
            $this._textLines, 
            [SourceCodeLocation]::new($this._currentLocation.LineNumber, $this._currentLocation.OffsetInLine + $characterCount))
    }

    [bool] CurrentLineContainsNonSpaceCharacters()
    {
        $currentLineChars = $this._textLines[$this._currentLocation.LineNumber]
        return $currentLineChars.Substring($this._currentLocation.OffsetInLine).Trim().Length -gt 0
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

        for ($nextLineIndex = $this._currentLocation.LineNumber + 1; $nextLineIndex -lt $this._textLines.Length; $nextLineIndex++)
        {
            $lineChars = $this._textLines[$nextLineIndex]
            $offset = Get-IndexOfFirstNonSpaceCharacter $lineChars
            if ($Null -ne $offset)
            {
                return [SourceCodeFileContent]::new($this._textLines, [SourceCodeLocation]::new($nextLineIndex, $offset))
            }
        }

        return $Null
    }

    [string] ToString()
    {
        return "$($this.GetCurrentLineWithIndicatedPosition()): line $($this._currentLocation.LineNumber + 1), char: $($this._currentLocation.OffsetInLine + 1)"
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
        if ($null -eq $p -or $p.Length -eq 0)
        {
            throw [System.InvalidOperationException]::new('Program logic error: trying to parse content with an empty array of parsers')
        }

        $this.Parsers = $p
    }
}

class MonadicParsing
{
    static [System.Diagnostics.TraceSource] $TraceSource = $null

    static [System.Diagnostics.TraceEventType] $TraceEventType = [System.Diagnostics.TraceEventType]::Information

    static [ParsingResult] ParseWith($parser, [SourceCodeFileContent] $content)
    {
        switch ($null)
        {
            { $parser -is [scriptblock] } {
                return & $parser $content
            }
            { $parser -is [string] } {
                $patternLength = $parser.Length
                $currentLineChars = $content.GetCurrentLine()
                if ([string]::Compare($currentLineChars, $content.GetOffsetInCurrentLine(), $parser, 0, $patternLength) -ne 0)
                {
                    [MonadicParsing]::Log('Literal {0} failed on line {1}', $parser, $content)
                    return $Null
                }

                [MonadicParsing]::Log('Literal {0} matched on line {1}', $parser, $content)
                return [ParsingResult]::new($parser, $content.Skip($patternLength))
            }
            { $parser -is [regex] } {
                $currentLineChars = $content.GetCurrentLine()
                $matchingResult = $parser.Match($currentLineChars, $content.GetOffsetInCurrentLine())
                if (-Not $matchingResult.Success -or ($matchingResult.Index -ne $content.GetOffsetInCurrentLine()))
                {
                    [MonadicParsing]::Log('Regex {0} failed on line {1}', $parser, $content)
                    return $Null
                }

                $parsedValue = $matchingResult.Groups[1].Value
                [MonadicParsing]::Log('Regex {0} matched on line {1}', $parser, $content)
                return [ParsingResult]::new($parsedValue, $content.Skip($matchingResult.Length))
            }
            { $parser -is [Parser]} {
                return [MonadicParsing]::ParseWith($parser.Parsers, $content)
            }
            { $parser -is [array] } {
                if ($parser.Length -eq 0)
                {
                    throw [System.InvalidOperationException]::new('Program logic error: trying to parse content with an empty array of parsers')
                }

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

        throw [System.InvalidOperationException]::new("Do not know how to parse with $parser of type $($parser.GetType())")
    }

    static hidden [void] Log([string] $format, $arg1, $arg2)
    {
        [TraceLoggingApi]::Log(([MonadicParsing]::TraceSource), [MonadicParsing]::TraceEventType, $format, $arg1, $arg2)
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
    $parsers | ForEach-Object { 
        if ($null -eq $_)
        {
            throw [System.ArgumentException]::new('parsers', 'Program logic error: One-Of(...$Null...)')
        }
    }

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

    return {
        param ([SourceCodeFileContent] $content)

        $parsingResult = [MonadicParsing]::ParseWith($parser, $content)
        if ($Null -ne $parsingResult)
        {
            Set-Variable -Name $parsingResultName -Value $parsingResult.Value -Scope 2
            [MonadicParsing]::Log('from {0} => {1}', $parsingResultName, $parsingResult.Value)
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