param ([string] $logger)

Set-StrictMode -Version Latest

if ($PSVersionTable.PSVersion.Major -eq 5)
{
	function Get-Error()
	{
        process 
        {
            function Try-AppendPositionMessage($errRec, $errorMessages)
            {
                if (($null -ne $errRec.Exception) -and ($errRec.Exception.PSobject.Properties.Name -contains 'ErrorRecord') -and ($null -ne $errRec.Exception.ErrorRecord))
                {
                    $errorMessages = Try-AppendPositionMessage -errRec $errRec.Exception.ErrorRecord -errorMessages $errorMessages
                }

                if ($null -ne $errRec.InvocationInfo -and $null -ne $errRec.InvocationInfo.PositionMessage)
                {
                    $errorMessages += ' ('
                    $errorMessages += $errRec.InvocationInfo.PositionMessage | Out-String
                    $errorMessages += ")$([Environment]::NewLine)"
                }

                $errorMessages
            }

            $errorRecord = $_
            if ($null -eq $errorRecord -and $Global:Error.Count -gt 0)
            {
                foreach ($errorRecord in $Global:Error[0])
                {
                    break
                }
            }

            $description = @()
            if ($errorRecord -is [Exception])
            {
                $description += $errorRecord.ToString()
            }
            else
            {
                if ($null -ne $errorRecord.Exception)
                {
                    $description += $errorRecord.Exception.ToString()
                }

                $description = Try-AppendPositionMessage -errRec $errorRecord -errorMessages $description

                if ($null -ne $errorRecord.ScriptStackTrace)
                {
                    $description += ($errorRecord.ScriptStackTrace | Out-String)
                }
            }

            $description
        }
	}
}

trap {
    throw (Get-Error | Out-String)
    exit 1;
    continue
}

Write-Host "`$logger = '$logger'"

. ..\Logging.ps1

[System.Diagnostics.TraceSource] $global:parser = $null
[System.Diagnostics.TraceSource] $global:testrunner = $null

function Log([System.Diagnostics.TraceSource] $traceSource, [System.Diagnostics.TraceEventType] $traceLevel, $what)
{
    [TraceLoggingApi]::Log($traceSource, $traceLevel, "`t{0:HH:mm:ss.ffff}`t{1}", [datetime]::Now, $what)
}

function Test-Logging([System.Diagnostics.TraceSource] $traceSource)
{
    foreach ($level in 'Critical', 'Error', 'Warning', 'Information', 'Verbose')
    {
        Log -traceSource $traceSource -traceLevel $level -what $level.ToString()
    }
}

$traceListener = TraceLoggingApi-SetupLogging `
    -logger $logger `
    -parser { 
        param($ts) 
        $global:parser = $ts 
    } `
    -testrunner { 
        param($ts) 
        $global:testrunner = $ts 
    }


Test-Logging -traceSource $parser
Test-Logging -traceSource $testrunner

if ($null -ne $traceListener)
{
    $traceListener.Close()
}