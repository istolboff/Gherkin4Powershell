class TraceLoggingApi
{
    static [void] Log(
        [System.Diagnostics.TraceSource] $traceSource, 
        [System.Diagnostics.TraceEventType] $traceLevel, 
        [string] $format, 
        [object] $arg1, 
        [object] $arg2)
    {
        [TraceLoggingApi]::LogCore($traceSource, $traceLevel, $format, @($arg1, $arg2))
    }

    static [void] LogCore(
        [System.Diagnostics.TraceSource] $traceSource,
        [System.Diagnostics.TraceEventType] $traceLevel,
        [string] $format,
        [array] $arguments)
    {
        function Dump
        {
            process
            {
                $value = $_

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
                    $value
                }
                else
                {
                    '$null'
                }
            }
        }

        if ($null -ne $traceSource)
        {
            $traceSource.TraceEvent($traceLevel, 1, $format -f @($arguments | Dump))
        }
    }
}


function TraceLoggingApi-SetupLogging([string] $logger)
{
    function Describe-LoggerParameterStructure([string[]] $traceSourceNames)
    {
@"
The folowing formats of -logger parameter are supported
-logger "{TraceListener}[;TraceOutputOptions={TraceOutputOptions}][;sourceLevel={SourceLevel}]"
-logger "{TraceListener}[;TraceOutputOptions={TraceOutputOptions}]{TraceSource}:sourceLevel={SourceLevel};[, ...n]"
where {TraceListener} is either 'console' or 'file=<path to log file>'; 
        {SourceLevel} is one of Critical, Error, Warning, Information, Verbose; 
        {TraceOutputOptions} is any combination of System.Diagnostics.TraceOptions Enum
        {TraceSource} is one of $($traceSourceNames -join, ', ')
"@
    }

    function Parse-SourceLevel([string] $part, [string] $sourceLevel)
    {
        try
        {
            return [System.Diagnostics.SourceLevels]$sourceLevel
        }
        catch
        {
            throw [System.ArgumentException]::new(
                "'$part' uses invalid SourceLevel '$sourceLevel'",
                '-logger',
                $_.Exception)
        }
    }

    $arguments = $Args

    if ([string]::IsNullOrWhiteSpace($logger))
    {
        return $null
    }

    if ($arguments.Length -eq 0 -or ($arguments.Length % 2) -ne 0)
    {
        throw [System.ArgumentException]::new(
            'Expect a sequence of parameter pairs of type -someName { param([System.Diagnostics.TraceSource] $traceSource) somehow-use-this $traceSource }',
            '-logger')
    }

    $traceSourceSetters = @{}
    foreach ($i in 0..($arguments.Length / 2 - 1))
    {
        $tsname = $arguments[$i * 2].TrimStart('-')
        $traceSourceSetter = $arguments[$i * 2 + 1]
        if (-not ($traceSourceSetter -is [scriptblock]))
        {
            throw [System.ArgumentException]::new("Expected parameter '$traceSourceSetter' to be a scriptblock.")
        }

        $traceSourceSetters.Add($tsname, $traceSourceSetter)
    }

    $traceSourceNames = @($traceSourceSetters.Keys)

    $loggerSettings = @{
        TraceListener = $null;
        TraceFilePath = $null;
        TraceOutputOptions = $null;
        DefaultSourceLevel = $null;
        ConcreteTraceSources = ([System.Collections.Generic.Dictionary[string, System.Diagnostics.SourceLevels]]::new())
    }

    foreach ($settingsPart in $logger -split ';')
    {
        switch -regex ($settingsPart)
        {
            '^console$' {
                if ($null -ne $loggerSettings.TraceListener)
                {
                    throw [System.ArgumentException]::new(
                        "Failed to build trace listener from '$logger': you specified more than one trace listener with 'console' or 'file=...' setting",
                        '-logger')
                }

                $loggerSettings.TraceListener = [System.Diagnostics.ConsoleTraceListener]::new($false)
            }
    
            '^file=(.+)$' {
                if ($null -ne $loggerSettings.TraceListener)
                {
                    throw [System.ArgumentException]::new(
                        "Failed to build trace listener from '$logger': you specified more than one trace listener with 'console' or 'file=...' setting",
                        '-logger')
                }

                $loggerSettings.TraceFilePath = $Matches[1]
                $loggerSettings.TraceListener = [System.Diagnostics.TextWriterTraceListener]::new($loggerSettings.TraceFilePath)
            }

            '^TraceOutputOptions=(.+)$' {
                if ($null -ne $loggerSettings.TraceOutputOptions)
                {
                    throw [System.ArgumentException]::new(
                        "Failed to build trace listener from '$logger': you specified more than one TraceOutputOptions combination with 'TraceOutputOptions=...' setting",
                        '-logger')
                }

                $traceOptions = $Matches[1]
                $tos = [System.Diagnostics.TraceOptions]::None
                try
                {
                    $tos = [System.Diagnostics.TraceOptions]$traceOptions
                }
                catch 
                {
                    throw [System.ArgumentException]::new(
                        "Failed to build trace listener from '$logger': invalid value '$traceOptions' for System.Diagnostics.TraceOptions specified in '$settingsPart'",
                        '-logger',
                        $_.Exception)
                }

                $loggerSettings.TraceOutputOptions = $tos
            }

            '^sourceLevel=(.*)$' {
                if ($null -ne $loggerSettings.DefaultSourceLevel)
                {
                    throw [System.ArgumentException]::new(
                        "Failed to build trace listener from '$logger': you specified more than one default sourcelevel with 'sourceLevel=...' setting",
                        '-logger')
                }

                $loggerSettings.DefaultSourceLevel = Parse-SourceLevel -part $settingsPart -sourceLevel $Matches[1]
            }

            '^([^:]+):sourceLevel=(.*)$' {
                $traceSourceName = $Matches[1]
                $traceSourceLevel = Parse-SourceLevel -part $settingsPart -sourceLevel $Matches[2]
                if ($loggerSettings.ConcreteTraceSources.ContainsKey($traceSourceName))
                {
                    throw [System.ArgumentException]::new(
                        "Failed to build trace listener from '$logger': you specified sourcelevel second time for '$traceSourceName' with '$settingsPart' setting",
                        '-logger')
                }

                $loggerSettings.ConcreteTraceSources.Add($traceSourceName, $traceSourceLevel)
            }

            default {
                throw [System.ArgumentException]::new(
                    "Failed to build trace listener from '$logger': invalid setting '$settingsPart'",
                    '-logger')
            }
        }
    }

    if ($null -eq $loggerSettings.TraceListener)
    {
        throw [System.ArgumentException]::new(
            "Failed to build trace listener from '$logger': $(Describe-LoggerParameterStructure -traceSourceNames $traceSourceNames)",
            '-logger')
    }

    if ($null -ne $loggerSettings.TraceOutputOptions)
    {
        $loggerSettings.TraceListener.TraceOutputOptions = $loggerSettings.TraceOutputOptions
    }

    if ($null -eq $loggerSettings.DefaultSourceLevel)
    {
        $loggerSettings.DefaultSourceLevel = [System.Diagnostics.SourceLevels]::Warning
    }

    if (-not [string]::IsNullOrWhiteSpace($loggerSettings.TraceFilePath) -and (Test-Path -Path $loggerSettings.TraceFilePath))
    {
        Remove-Item -Path $loggerSettings.TraceFilePath -Force
    }

    foreach ($tsSetter in $traceSourceSetters.GetEnumerator())
    {
        $traceSource = [System.Diagnostics.TraceSource]::new($tsSetter.Name)
        $sourceLevel = $loggerSettings.DefaultSourceLevel
        if ($loggerSettings.ConcreteTraceSources.ContainsKey($tsSetter.Name))
        {
            $sourceLevel = $loggerSettings.ConcreteTraceSources[$tsSetter.Name]
        }

        $traceSource.Switch = [System.Diagnostics.SourceSwitch]::new("switch$($tsSetter.Name)", $sourceLevel)
        $traceSource.Listeners.Remove('Default')
        [void] ($traceSource.Listeners.Add($loggerSettings.TraceListener))

        & $tsSetter.Value $traceSource
    }

    $loggerSettings.TraceListener
}