# Check if the ThreadJob module is available, and install it for the current user if not
if (!(Get-Module -Name "Microsoft.PowerShell.ThreadJob")) {
    Install-Module ThreadJob -Scope CurrentUser
}
# Load the modules we need
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Collections
# ---------------------------------------------------------
#
# CONFIGURATION
#
# ---------------------------------------------------------
#
# The data source to use for the API calls. This can be "tranquility" for live data, or "singularity" for the test server.
$global:Source = "tranquility"
$global:API= "latest"
#
# MaxJobs controls how many threads we will use to query the API. The optimal number depends on your system and network, 
# but 4-8 is usually a good range for ESI.
$MaxJobs = 4
#
# Data folder path. This is where we will read and write our CSV files. It is set to the "Data" folder in the parent directory
# of the script.
$datafolder = $PSScriptRoot.Replace("\Powershell","")+'\Data'
#----------------------------------------------------------------------------------------------------------
#
# FUNCTIONS
#
#----------------------------------------------------------------------------------------------------------
# ---------------------------------------------------------
# DATA FUNCTIONS
# ---------------------------------------------------------
#
# Get-JsonFromUrl -Url <string> -Session <WebRequestSession> -MaxRetries <int> -DelaySec <int>
#
# Parameters:
#   - Url: The URL to query for JSON data
#   - Session: An optional WebRequestSession object to reuse for cookies and connection pooling. If null, a new session will be created.
#   - MaxRetries: The maximum number of retries for transient errors (e.g. HTTP 429, 503)
#   - DelaySec: The delay in seconds between retries
# Returns:
#   A PSCustomObject with the following properties:
#   - StatusCode: The HTTP status code of the response, or 0 if the request failed without a response
#   - Json: The parsed JSON object from the response content, or null if parsing failed or no content was returned
#   - Error: An error message if the request failed or JSON parsing failed, or null on success
# Description:
# This function performs an HTTP GET request to the specified URL, with built-in retry logic for transient errors. It attempts to
# parse the response content as JSON and returns a structured result object. The function also suppresses progress output 
# from Invoke-WebRequest to avoid cluttering the console during batch operations.
#----------------------------------------------------------------------------------------------------------
function Get-JsonFromUrl {
    param(
        # URL to query
        [Parameter(Mandatory)]
        [string]$Url,
        # Web session
        [Parameter(Mandatory)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        # Retry count
        [Parameter(Mandatory)]
        [int]$MaxRetries,
        # Delay between retries
        [Parameter(Mandatory)]
        [int]$DelaySec
    )
    # Save caller's progress preference
    $OldProgressPreference = $ProgressPreference
    # Disable Invoke-WebRequest progress spam
    $ProgressPreference = 'SilentlyContinue'
    # Retryable HTTP status codes
    $RetryableStatuses = @{
        420 = "Error Limited"          # ESI specific
        429 = "Too Many Requests"
        500 = "Internal Server Error"
        502 = "Bad Gateway"
        503 = "Service Unavailable"
        504 = "Gateway Timeout"
    }
    # Make sure we handle any errors that occur
    try {
        # Create session only if missing
        if (-not $Session) {$Session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()}
        # Retry loop, make sure we do not exceed the specified number of retries for transient errors
        for ($Try = 1; $Try -le $MaxRetries; $Try++) {
            # Catch and handle any errors that occur during the request or JSON parsing
            try {
                # Invoke request
                $Response = Invoke-WebRequest -Uri $Url -WebSession $Session -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
                # Set the default JSON object
                $Json = $null
                # Convert JSON only if content exists
                if (![string]::IsNullOrWhiteSpace($Response.Content)) {
                   try {
                        $Json = $Response.Content | ConvertFrom-Json
                    } catch {
                        # JSON parsing failure
                        return [PSCustomObject]@{
                            StatusCode = $Response.StatusCode
                            Json       = $null
                            Error      = "JSON parse error: $($_.Exception.Message)"
                        }
                    }
                }
                # Success
                return [PSCustomObject]@{
                    StatusCode = $Response.StatusCode
                    Json       = $Json
                    Error      = $null
                }
            } catch {
                # Safely extract status code
                $Status = $null
                # If we have a response, try to get the status code. If we don't have a response, this will throw and we will
                # just return 0 for the status code.
                if ($_.Exception.Response) {try {$Status = $_.Exception.Response.StatusCode.Value__} catch {}}
                # Retryable HTTP status codes
                if ($RetryableStatuses.ContainsKey($Status)) {
                    # Respect Retry-After header if present
                    $RetryAfter = $null
                    if ($Response.Headers["Retry-After"]) {[int]::TryParse($Response.Headers["Retry-After"], [ref]$RetryAfter) | Out-Null}
                    # ESI-specific headers
                    $EsiRemain = $Response.Headers["X-Esi-Error-Limit-Remain"]
                    $EsiReset  = $Response.Headers["X-Esi-Error-Limit-Reset"]
                    # Use Retry-After first, otherwise exponential backoff
                    if (-not $RetryAfter) {$RetryAfter = [Math]::Min(300,[Math]::Pow(2, $Try) + (Get-Random -Minimum 1 -Maximum 5))}
                    # Extra protection when nearing ESI error limit
                    if ($EsiRemain -and [int]$EsiRemain -lt 5) {$ExtraDelay = if ($EsiReset) {[int]$EsiReset} else {60}
                        # If the ESI headers indicate we are close to the error limit, we will use the reset time as the delay if it
                        # is provided, or a default of 60 seconds if not. We will also log a warning about the low remaining limit and
                        # the reset time. This is important to avoid hitting the error limit and getting blocked by ESI, which can happen
                        # if we keep retrying without enough delay when we are close to the limit.
                        $RetryAfter = [Math]::Max($RetryAfter, $ExtraDelay)
                        # Log a warning about the low remaining limit and the reset time, which can help with debugging and monitoring our
                        # API usage.
                        Write-Warning ("ESI error limit low: Remaining=$EsiRemain " + "Reset=$EsiReset sec")
                    }
                    # Log a warning about the retryable error and the delay before retrying, which can help with debugging and monitoring our
                    # API usage.
                    Write-Warning ("HTTP $Status [$($RetryableStatuses[$Status])]. " + "Retrying in $RetryAfter sec " + "($($MaxRetries - $Try) retries left)")
                    # Wait the specified delay before retrying
                    Start-Sleep -Seconds $RetryAfter
                    # Continue to the next iteration of the retry loop
                    continue
                }
                # Non-retryable error
                return [PSCustomObject]@{
                    StatusCode = $Status
                    Json       = $null
                    Error      = $_.Exception.Message
                }
            }
        }
        # Retries exhausted
        return [PSCustomObject]@{
            StatusCode = 0
            Json       = $null
            Error      = "Failed after $MaxRetries retries"
        }
    } finally {
        # Always restore caller's progress preference
        $ProgressPreference = $OldProgressPreference
    }
}
# ---------------------------------------------------------
# BATCH PROCESSOR
# ---------------------------------------------------------
#
# Invoke-URLBatchProcessor -Queue <Queue> -JobBlock <ScriptBlock> -Activity <string> -MaxJobs <int> -BatchSize <int>
#
# Parameters:
#   - Queue: A System.Collections.Queue containing the items to process. The items will be passed as an array to the 
#   JobBlock in batches.
#   - JobBlock: A ScriptBlock that will be executed in a separate thread for each batch of items. The ScriptBlock should
#   accept three parameters: the batch of items, the API version string, and the data source string. It should return an array
#   of results.
#   - Activity: A string describing the activity being performed, used for the progress bar display.
#   - MaxJobs: The maximum number of concurrent jobs to run. This controls the level of parallelism.
#   - BatchSize: The number of items to include in each batch passed to the JobBlock. This allows you to balance the workload
#   and reduce overhead from too many small jobs.
# Returns:
#   An array of results collected from all the completed jobs. Each job should return an array of results, and this function
#   will aggregate them into a single array before returning to the caller.
# Description:
# This function manages the execution of a batch processing workflow using PowerShell jobs. It takes a queue of items to process,
# executes a specified ScriptBlock in parallel on batches of these items, and collects the results. It also includes robust error
# handling and retry logic for jobs that fail, as well as a progress bar to provide feedback on the overall progress of the operation.
#----------------------------------------------------------------------------------------------------------
function Invoke-URLBatchProcessor {
    param(
        # The queue of items to process
        [Parameter(Mandatory)]
        [System.Collections.Queue]$Queue,
        # The scriptblock we need to execute
        [Parameter(Mandatory)]
        [scriptblock]$JobBlock,
        # The Activity value for the progress bar
        [Parameter(Mandatory)]
        [String]$Activity,
        # The Maximum number of jobs we allow in the job table
        [Parameter(Mandatory)]
        [int]$MaxJobs,
        # How many API calls we can add to each batch
        [Parameter(Mandatory)]
        [int]$BatchSize
    )
    # Use generic list instead for efficiency when adding results from each job
    $Results = [System.Collections.Generic.List[object]]::new()
    # Any jobs in these states will be restarted
    $BadStates = @("Failed","Stopped","Blocked")
    # Retry tracking
    $RetryTable = @{}
    $MaxRetries = 5
    # Progress values
    $Done = 0
    $Running = 0
    $Pct = 0
    $JobCount = 0
    # Total items to process
    $Total = $Queue.Count
    # Clean up old jobs
    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
    # Initialize progress bar with 0% completion
    Write-Progress -Activity $Activity -Status "Completed: $Done / $Total  Jobs: $JobCount" -PercentComplete $Pct
    # Refresh cached jobs table
    $Jobs = Get-Job
    # While there are jobs in the queue or job table, keep processing
    while (($Queue.Count -gt 0) -or ((Get-Job).Count -gt 0)) {
        # Cache jobs table
        $Jobs = Get-Job
        # Launch new jobs if we have capacity
        while (($Queue.Count -gt 0) -and ($Jobs.Count -lt $MaxJobs)) {
            # Create a new batch
            $Batch = @()
            # Fill batch
            for ($i = 1; $i -le $BatchSize -and $Queue.Count -gt 0; $i++) {$Batch += $Queue.Dequeue()}
            # Start thread job
            Start-ThreadJob  -ScriptBlock $JobBlock  -ArgumentList $Batch,$global:API,$global:Source | Out-Null
            # Refresh cached jobs table
            $Jobs = Get-Job
        }
        # Get active job count
        $JobCount = $Jobs.Count
        # Calculate percentage complete
        $Pct = [Math]::Min(100, [int](($Done / $Total) * 100))
        # Update progress bar
        Write-Progress -Activity $Activity -Status "Completed: $Done / $Total  Jobs: $JobCount" -PercentComplete $Pct
        # Wait efficiently for any job to complete
        if ($Jobs.Count -gt 0) {Wait-Job -Job $Jobs -Any -Timeout 1 | Out-Null}
        # Process completed jobs
        foreach ($job in Get-Job -State Completed) {
            # Collect results
            $out = Receive-Job $job
            # Remove completed job
            Remove-Job $job
            # Process returned results
            foreach ($R in $out) {
                # Add result to output list
                $Results.Add($R)
                # Increment completed count
                $Done++
            }
        }
        # Restart bad-state jobs
        foreach ($state in $BadStates) {
            foreach ($job in Get-Job -State $state) {
                # Recover failed batch
                $Batch = $job.Command[0].Arguments[0]
                # Build retry tracking key
                $RetryKey = ($Batch -join ',')
                # Initialize retry counter
                if (!$RetryTable.ContainsKey($RetryKey)) {$RetryTable[$RetryKey] = 0}
                # Increment retry count
                $RetryTable[$RetryKey]++
                # Retry only within limits
                if ($RetryTable[$RetryKey] -le $MaxRetries) {
                    # Uncomment for debugging
                    Write-Warning "Restarting batch job for IDs $($Batch -join ', ') (state: $state retry: $($RetryTable[$RetryKey]))"
                    # Remove failed job
                    Remove-Job $job
                    # Small stabilization delay
                    Start-Sleep -Milliseconds 200
                    # Restart SAME job block
                    Start-ThreadJob -ScriptBlock $JobBlock -ArgumentList $Batch,$global:API,$global:Source | Out-Null
                } else {
                    # Permanent failure after retries, log and skip
                    Write-Error "Batch permanently failed after $MaxRetries retries: $($Batch -join ', ')"
                    # Remove failed job
                    Remove-Job $job
                }
            }
        }
    }
    # Close and hide progress bar
    Write-Progress -Activity $Activity -Completed
    # Return results to caller
    return $Results
}
# ---------------------------------------------------------
# CSV IMPORT/EXPORT
# ---------------------------------------------------------
#
# Get_FromCSV -filepath <string> -keyname <string>
#
# Parameters:
#   - filepath: The full path to the CSV file we want to read
#   - keyname: The name of the column to use as the key (Index) for the hashtable. If null, the row number will be used as the key.
# Returns:
#   A PSCustomObject with the following properties:
#   - A hashtable of the data from the CSV file, indexed by the specified key column. Each value in the hashtable is itself a
#   - hashtable containing the data for that row, with keys corresponding to the column headers.
# Description:
# This function reads a CSV file and returns a hashtable of the data, indexed by the specified key column. It also attempts to 
# convert numeric values to their appropriate types (int32, int64, double) for easier processing later on. This processing
# is critical because hash keys are stronly typed. An Int64 will NOT match an Int32 key, and will cause lookups to fail if 
# the types do not match.
#----------------------------------------------------------------------------------------------------------
function Get_FromCSV {
    param(
        # The full path to the file we are importing
        [Parameter(Mandatory=$true)][string]$filepath,
        # Either the column name to use as an index, or $null to use the row number
        [string]$keyname = $null
    )
    # Read the file into an array
    $rows = Import-Csv -LiteralPath $filepath
    # If nothing was read, return a blank hash and skip further processing
    if(-not $rows){return @{}}
    # Get the headers from the first row
    $headers = $rows[0].PSObject.Properties.Name
    # If we don't find the index header, throw and error
    if (($keyname) -and ($headers -notcontains $keyname)) {throw "Key '$keyname' not found."}
    # Create a hash to hold the results
    $csv_data = @{}
    # Start processing at the second row (zero based). If no index was specified, we will use this counter
    $rowctr = 1
    # Proceess each line in the file
    foreach($row in $rows){
        # Create a hash, preserving the order of the data inserted
        $typedRow = [ordered]@{}
        # Iterate through the headers
        foreach($h in $headers){
            # Get the value from the specified column
            $v = Get-Typed -value $row.$h
            # Add the value to the typed row hash, using the header as the key. This will convert numeric
            # values to their appropriate.    
            $typedRow[$h] = $v
        }
        # Determine the key value for this row based on the specified keyname. If no keyname was specified,
        # use the row counter as the key.
        if($keyname){$keyval = $typedRow[$keyname]} else {$keyval = $rowctr}
        # Add the converted data to the indexed hash
        $csv_data[$keyval] = $typedRow
        # Increment the row counter
        $rowctr++
    }
    # Send the data back to the caller
    return $csv_data
}
# Save-ToCsv -FilePath <string> -Data <hashtable>
#
# Parameters:
#   - FilePath: The full path to the CSV file to write. If the file already exists, it will be overwritten.
#   - Data: A hashtable containing the data to write to the CSV file. The keys of the hashtable will be ignored, 
#    and the values will be written as rows in the CSV file. Each value in the hashtable should itself be a hashtable
#    representing a row of data, with keys corresponding to column headers and values corresponding to the cell values for that row.
# Returns:
#   None. This function writes the data to a CSV file at the specified path.
# Description:
# This function takes a hashtable of data and writes it to a CSV file. The keys of the outer hashtable are ignored, and the values
# are expected to be hashtables representing rows of data. The function writes a header row based on the keys of the first row's hashtable,
# and then writes each row of data, quoting string values and leaving numeric values unquoted for better compatibility with Excel and other
# CSV readers.
#----------------------------------------------------------------------------------------------------------
function Save-ToCsv {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [hashtable]$Data
    )
    # Create a StreamWriter for UTF-8 output
    $writer = [System.IO.StreamWriter]::new($FilePath, $false, [System.Text.UTF8Encoding]::new($false))
    try {
        $lineCtr = 0
        # Iterate through the hashtable entries
        foreach ($thiskey in $Data.keys) {
            # Get the sub-hash that actually contains the data
            $row = $Data[$thisKey]
            # First line → write header
            if ($lineCtr -eq 0) {
                $header = ($row.Keys | ForEach-Object { '"{0}"' -f $_ }) -join ","
                $writer.WriteLine($header)
            }
            # Write values (quote strings, leave numbers unquoted)
            $line = ($row.Values | ForEach-Object {
                if ($_ -is [string]) {
                    '"{0}"' -f $_
                } else {
                    $_.ToString()
                }
            }) -join ","
            # Write the data
            $writer.WriteLine($line)
            $lineCtr++
        }
    }
    finally {
        $writer.Close()
    }
}
# ---------------------------------------------------------
# DATA CONVERSION, TYPING
# ---------------------------------------------------------
#
# Get-Typed -value <string>
#
# Parameters:
#   - value: The string value to convert to its appropriate type.
# Returns:
#   The converted value with the appropriate type (int32, int64, or double).
# Description:
# This function attempts to convert a string value to its appropriate numeric type (int32, int64, or double) for easier processing later on. This processing
# is critical because hash keys are strongly typed. An Int64 will NOT match an Int32 key, and will cause lookups to fail if 
# the types do not match.
#----------------------------------------------------------------------------------------------------------
function Get-Typed() {
    param(
        # The value to convert to its appropriate type
        [Parameter(Mandatory=$true)]
        $value
    )
    $RtnVal = $null
    # If there are only 0-9 characters in the value, it's an integer
    if($value -match '^[+-]?\d+$') {
        try {
            # If converting it to an int32 causes an overflow, convert it to an int64
            $RtnVal = [int32]$value
        } catch {$RtnVal = [int64]$value}
    # If there are only 0-9 characters in the value with a decimal, convert it to a double
    } elseif ($value -match '^[+-]?\d+\.\d+$'){
        $RtnVal = [double]$value
    # Anything else does not need a conversion
    } else {$RtnVal = $value}
    return $RtnVal
}
# ---------------------------------------------------------
#
# END FUNCTIONS
#
# ---------------------------------------------------------
# Clear the screen
clear-host
#
# Set our start time
$StartTime = [datetime]::now
# Announce start
$Message = "Beginning process..." + $StartTime.ToString()
write-host $Message
#
#----------------------------------------------------------------------------------------------------------
# Load existing Structures
#----------------------------------------------------------------------------------------------------------
# Create the hash
$Structures = @{}
# Check if the Structures CSV file exists
$thisFile = $datafolder + "\Structures.csv"
if (Test-Path -Path $thisFile) {
    write-host "Querying Structures from CSV..."
    $Structures = Get_FromCSV -filepath $thisfile -keyname "ID"
    # Annouce the success
    Write-Host "Loaded $($Structures.Count) Structure entries"
} else {
    write-host "Structures file not found. Please run OAuth2.ps1 to create and populate it."
    exit(1)
}
#----------------------------------------------------------------------------------------------------------
# Load existing Stations
#----------------------------------------------------------------------------------------------------------
$Stations = @{}
# Set the full path for the CSV file
$thisFile = Join-Path $datafolder '\Stations.csv'
# If the file exists
if (Test-Path $thisFile) {
    # Announce the action
    Write-Host "Loading existing Stations..."
    # Load the existing Types from the CSV
    $Stations = Get_FromCSV -filepath $thisFile -keyname "ID"
    # Annouce the success
    Write-Host "Loaded $($Stations.Count) Station entries"
}
#----------------------------------------------------------------------------------------------------------
# Load Regions
#
# Description:
# The previous two sections (Structures and Stations) are straightforward because they are relatively small datasets
# that can be quickly loaded from CSV or queried from the API without much overhead. The Regions section is more complex
# because it involves multiple API calls to get the list of region IDs and then get the details for each region. This is
# done in a way that allows us to show progress and handle potential issues with the API, while also caching the results
# in a CSV file for future runs.
#
# The Systems section that follows is similar in complexity to the Regions section, but it also demonstrates how to use the
# Invoke-URLBatchProcessor function to efficiently process a large number of API calls in parallel with robust error handling
# and progress reporting.
#----------------------------------------------------------------------------------------------------------
# Create the hash
$Regions = @{}
# Check if the Regions CSV file exists
$thisFile = $datafolder + "\Regions.csv"
if (Test-Path -Path $thisFile) {
    # Annouce the action
    write-host "Querying Regions from CSV..."
    # Perform the action
    $Regions = Get_FromCSV -filepath $thisfile -keyname "ID"
    # Annouce the success
    Write-Host "Loaded $($Regions.Count) Region entries"
} else {
    write-host("Querying Regions from API...")
    # Turn off the invoke-webrequest progress bar
    $ProgressPreference = 'SilentlyContinue'
    # Get the list of region ID's from the API and create the session
    $URL = "https://esi.evetech.net/$API/universe/regions/?datasource=$Source"
    $RegionIDResult = Invoke-RestMethod -URI $URL -Method GET -UseBasicParsing -ContentType application/json -SessionVariable session
    # Restore normal operation of the progress bar
    $ProgressPreference = 'Continue'
    # Initialize the Progress Bar
    Write-Progress -Activity "Processing Regions" -Status "0% Complete:" -PercentComplete 0
    # Set our item processed counter to 0
    $Ctr = 0
    # Iterate through each ID from the results
    foreach ($thisID in $RegionIDResult) {
        # Get the region name
        $URL = "https://esi.evetech.net/$API/universe/regions/$thisID/?datasource=$Source&language=en"
        $RegionResult = Get-JsonFromUrl -Url $URL -Session $session -maxRetries 5 -delaySec 5
        # Create the hash entry
        $RegionID = [Int32]$thisID
        $Regions[$RegionID] = [ordered]@{}
        $Regions[$RegionID]["ID"] = $RegionID
        $Regions[$RegionID]["Name"] = $RegionResult.json.Name
        # Update progress bar
        $Ctr++
        $Pct = [Int32](($Ctr/$RegionIDResult.Count)*100)
        Write-Progress -Activity "Processing Regions" -Status "$PCT% Complete:" -PercentComplete $Pct
    }
    # Close and hide the progress bar
    Write-Progress -Activity "Processing Regions" -Complete
    # Export the Region ID's
    Save-ToCsv -FilePath $thisfile -Data $Regions
}
#----------------------------------------------------------------------------------------------------------
# Load Systems
#
# Description:
# The Systems section is more complex because it involves a large number of API calls to get the details for each
# system. To handle this efficiently, we use the Invoke-URLBatchProcessor function defined earlier, which allows us
# to process the system IDs in batches with multiple concurrent jobs, while also providing robust error handling and
# progress reporting. This approach is necessary to avoid overwhelming the API and to ensure that we can recover from
# any transient errors that may occur during the data retrieval process.
#----------------------------------------------------------------------------------------------------------
# Create the hash
$Systems = @{}
# Check if the Systems CSV file exists
$thisFile = $datafolder + "\Systems.csv"
if (Test-Path -Path $thisFile) {
    # Announce the action
    write-host "Querying Systems from CSV..."
    # Get the data from the CSV file
    $Systems = Get_FromCSV -filepath $thisfile -keyname "ID"
} else {
    # Announce the action
    write-host("Querying Systems from API...")
    # Turn off the invoke-webrequest progress bar
    $ProgressPreference = 'SilentlyContinue'
    # Get the list of System ID's from the API 
    $URL = "https://esi.evetech.net/$API/universe/systems/?datasource=$Source"
    $SystemIDResult = Invoke-RestMethod -URI $URL -Method GET -UseBasicParsing -ContentType application/json
    # Restore normal operation of the progress bar
    $ProgressPreference = 'Continue'
    #---------------------------------------------
    # Build the Queue
    #---------------------------------------------
    $SystemQueue   = [System.Collections.Queue]::new()
    foreach ($thisID in $SystemIDResult) {$SystemQueue.Enqueue($thisID)}
    #---------------------------------------------
    # Build the ScriptBlock
    #---------------------------------------------
    $SystemJobBlock = {
        param($Batch, $API, $Source, $RegionID)
        # Suppress noise
        $ProgressPreference    = 'SilentlyContinue'
        $ErrorActionPreference = 'Stop'
        # Faster than array +=
        $Output = [System.Collections.Generic.List[object]]::new()
        # Persistent HttpClient for this worker
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        # Recommended for ESI
        $client.DefaultRequestHeaders.UserAgent.ParseAdd("EveMarketTool/1.0")
        # Retry parameters
        $maxTries  = 5
        $baseDelay = 500   # milliseconds
        # Iterate through the batch
        foreach ($id in $Batch) {
            # Retry loop for each ID, with exponential backoff and handling of ESI throttling
            for ($try = 1; $try -le $maxTries; $try++) {
                # Try to get the system details
                try {
                    # Build URL
                    $url = "https://esi.evetech.net/$API/universe/systems/$id/?datasource=$Source&language=en"
                    # Execute request
                    $response = $client.GetAsync($url).Result
                    # Handle ESI throttling
                    $status = [int]$response.StatusCode
                    # If we are being throttled, wait and retry. ESI can return either 420 or 429 for throttling, 
                    # and may include headers indicating how long to wait.
                    if ($status -eq 420 -or $status -eq 429) {
                        # Default delay if no headers are present
                        $delaySeconds = 10
                        # Check for ESI-specific headers that indicate how long to wait. ESI may return either Retry-After
                        # or X-Esi-Error-Limit-Reset, and we should respect these if they are present.
                        # Prefer Retry-After for 429
                        if ($response.Headers.Contains("Retry-After")) {
                            # This header indicates how many seconds to wait before retrying, which is the most direct way to know how long to wait.
                            # We will use this as the delay if it is present and can be parsed as an integer.
                            $retry = $response.Headers.GetValues("Retry-After") | Select-Object -First 1
                            # Initialize thw variable we will use to store the parsed value
                            $parsed = 0
                            # Try to parse the header value as an integer number of seconds. If parsing fails, we will just use the default delay.
                            if ([int]::TryParse($retry, [ref]$parsed)) {$delaySeconds = $parsed}
                        } elseif ($response.Headers.Contains("X-Esi-Error-Limit-Reset")) {
                            # This header indicates how many seconds until the ESI error limit resets, which can be useful to avoid hitting the
                            # limit again on the next request. We will use this as the delay if it is present and can be parsed as an integer.
                            $reset = $response.Headers.GetValues("X-Esi-Error-Limit-Reset") | Select-Object -First 1
                            # Try to parse the header value as an integer number of seconds. If parsing fails, we will just use the default delay.
                            $parsed = 0
                            if ([int]::TryParse($reset, [ref]$parsed)) {$delaySeconds = $parsed}
                        }
                        # Wait the specified delay before retrying
                        Start-Sleep -Seconds $delaySeconds
                        # Do not process this ID further in this iteration, just go to the next try to retry the same ID
                        continue
                    }
                    # Stop on missing pages
                    if ([int]$response.StatusCode -eq 404) {break}
                    # Throw for non-success codes
                    $null = $response.EnsureSuccessStatusCode()
                    # Read content
                    $json = $response.Content.ReadAsStringAsync().Result
                    # Validate response
                    if ([string]::IsNullOrWhiteSpace($json)) {throw "Empty JSON returned by ESI"}
                    # Parse JSON
                    $objects = $json | ConvertFrom-Json
                    # Validate parsed JSON
                    if ($null -eq $objects) {throw "Invalid JSON returned by ESI"}
                    # Build output
                    foreach ($o in $objects) {
                        $Output.Add([PSCustomObject]@{
                            ID    = [int]$id
                            Name  = $o.name
                            Security = $o.security_status
                            Error = $null
                        })
                    }
                    # Success
                    break
                } catch {
                    # Final failure
                    if ($try -eq $maxTries) {
                        # Log the error for this ID and continue with the next one. We will include the ID and
                        # the error message in the output so that we can review it later.
                        $Output.Add([PSCustomObject]@{
                            ID    = [int]$id
                            Name  = $null
                            Security = $null
                            Error = $_.Exception.Message
                        })
                    }
                    # Exponential backoff
                    $sleep = [int]($baseDelay * [math]::Pow(2, $try - 1))
                    Start-Sleep -Milliseconds $sleep
                }
            }
        }
        # Cleanup
        $client.Dispose()
        $handler.Dispose()
        # Return ONLY final collection
        return ,$Output
    }
    #---------------------------------------------
    # Process the queue
    #---------------------------------------------
    # Set the number of jobs to run
    $MaxJobs = 4
    # Set the size of each batch
    $BatchSize = 100
    # Call the Batch Processor and store the results
    $Results = Invoke-URLBatchProcessor -Queue $SystemQueue -JobBlock $SystemJobBlock -Activity "Processing Systems" -MaxJobs $MaxJobs -BatchSize $BatchSize
    #---------------------------------------------
    # Process the results
    #---------------------------------------------
    # Process each individual result in the array
    foreach ($R in $Results) {
        # If it's an error report
        if ($R.Error) {
            # Warn the user
            Write-Warning "Failed ID $($R.ID): $($R.Error)"
            # Stop processing this entry and go to the next
            continue
        }
        # Create an ordered hash, preserving the order the items were added and populate from the PSCustomObject
        $Systems[$R.ID] = [ordered]@{
            ID = $R.ID
            Name = $R.Name
            Security = $R.Security
        }
    }
    # Export the System ID's
    Save-ToCsv -FilePath $thisfile -Data $Systems
}
#----------------------------------------------------------------------------------------------------------
# Load Types
#
# Description:
# When querying Type data, we have implemented a periodic save to ensure we can restart and do not
# have to requery the data from scratch. 
#
# Using normal methods, the time to totally rebuild the types data can take up to 3 hours. This makes
# sure we can restart after an error or other critical failure, and save time.
#
# It also allows incremental updates over time.
#
#----------------------------------------------------------------------------------------------------------
# CONFIGURATION: Set the $SaveInterval variable to control how often we save the data. 
# This is a tradeoff between performance and data safety.
# Autosave after 500 items have been successfully queried.  
$SaveInterval = 500
# -----------------------------
# Load existing Types
# -----------------------------
# Create a hash to hold our types data
$TypeIDs  = @{}
# Set the full path for the CSV file
$thisFile = Join-Path $datafolder 'Types.csv'
# If the file exists
if (Test-Path $thisFile) {
    # Announce the action
    Write-Host "Loading existing Types..."
    # Load the existing Types from the CSV
    $TypeIDs = Get_FromCSV -filepath $thisFile -keyname "ID"
    # Annouce the success
    Write-Host "Loaded $($TypeIDs.Count) Type entries"
}
# -----------------------------
# Fetch all TypeID pages
# -----------------------------
# Announce the action
Write-Host "Querying TypeID pages..."
# Turn off the invoke-webrequest progress bar
$ProgressPreference = 'SilentlyContinue'
# Create the URL
$URL = "https://esi.evetech.net/$API/universe/types/?datasource=$Source&page=1" 
# Use Invoke-WebRequest to extract the page count from the response header
$MaxPage = (Invoke-WebRequest -UseBasicParsing -Uri $URL | Select-Object -ExpandProperty Headers).'X-Pages'
# Restore progress bar behaviour
$ProgressPreference = 'Continue'
# -----------------------------
# Create and populate the queue
# -----------------------------
$PageQueue   = [System.Collections.Queue]::new()
1..$MaxPage | ForEach-Object { $PageQueue.Enqueue($_) }
# -----------------------------
# Page job block
# -----------------------------
$PageJobBlock = {
    param($Batch, $API, $Source, $RegionID)
    # Suppress noise
    $ProgressPreference    = 'SilentlyContinue'
    $ErrorActionPreference = 'Stop'
    # Faster than array +=
    $Output = [System.Collections.Generic.List[object]]::new()
    # Persistent HttpClient for this worker
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    # Recommended for ESI
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("EveMarketTool/1.0")
    # Retry parameters
    $maxTries  = 5
    $baseDelay = 500   # milliseconds
    # Iterate through the batch of page IDs
    foreach ($id in $Batch) {
        # Retry loop for each page, with exponential backoff and handling of ESI throttling
        for ($try = 1; $try -le $maxTries; $try++) {
            # Try to get the page of Type IDs
            try {
                # Build URL
                $url = "https://esi.evetech.net/$API/universe/types/?datasource=$Source&page=$id"
                # Execute request
                $response = $client.GetAsync($url).Result
                # Safely extract status code for throttling logic, default to 0 if we don't have a response
                $status = [int]$response.StatusCode
                # Handle ESI throttling
                if ($status -eq 420 -or $status -eq 429) {
                    # Default delay if no headers are present
                    $delaySeconds = 10
                    # Prefer Retry-After for 429
                    if ($response.Headers.Contains("Retry-After")) {
                        # This header indicates how many seconds to wait before retrying, which is the most direct way
                        # to know how long to wait.
                        $retry = $response.Headers.GetValues("Retry-After") | Select-Object -First 1
                        # Initialize the variable we will use to store the parsed value
                        $parsed = 0
                        # Try to parse the header value as an integer number of seconds. If parsing fails,
                        # we will just use the default delay.
                        if ([int]::TryParse($retry, [ref]$parsed)) {$delaySeconds = $parsed}
                    # Check for ESI-specific headers that indicate how long to wait. ESI may return either Retry-After or 
                    # X-Esi-Error-Limit-Reset, and we should respect these if they are present. Prefer Retry-After for 429,
                    # but if it's not present, check for X-Esi-Error-Limit-Reset.  
                    } elseif ($response.Headers.Contains("X-Esi-Error-Limit-Reset")) {
                        # This header indicates how many seconds until the ESI error limit resets, which can be useful to avoid
                        # hitting the limit again on the next request. We will use this as the delay if it is present and can be
                        # parsed as an integer.
                        $reset = $response.Headers.GetValues("X-Esi-Error-Limit-Reset") | Select-Object -First 1
                        # Initialize the variable we will use to store the parsed value
                        $parsed = 0
                        # Try to parse the header value as an integer number of seconds. If parsing fails, we will just
                        # use the default delay.
                        if ([int]::TryParse($reset, [ref]$parsed)) {$delaySeconds = $parsed}
                    }
                    # Wait the specified delay before retrying
                    Start-Sleep -Seconds $delaySeconds
                    # Do not process this page further in this iteration, just go to the next try to retry the same page
                    continue
                }
                # Optional: stop on missing pages
                if ([int]$response.StatusCode -eq 404) {break}
                # Throw for non-success codes
                $null = $response.EnsureSuccessStatusCode()
                # Read content
                $json = $response.Content.ReadAsStringAsync().Result
                # Validate response
                if ([string]::IsNullOrWhiteSpace($json)) {throw "Empty JSON returned by ESI"}
                # Parse JSON
                $orders = $json | ConvertFrom-Json
                # Validate parsed JSON
                if ($null -eq $orders) {throw "Invalid JSON returned by ESI"}
                # Build output
                foreach ($o in $orders) {
                    # Add the page ID and the list of Type IDs to the output collection. We will include the page number
                    # and the list of IDs, and set Error to null since this is a successful result.
                    $Output.Add([PSCustomObject]@{
                        Page    = [int]$id
                        IDs = $o
                        Error = $null
                    })
                }
                # Success
                break
            } catch {
                # Final failure
                if ($try -eq $maxTries) {
                    # Log the error for this page and continue with the next one. We will include the page number
                    # and the error message
                    $Output.Add([PSCustomObject]@{
                        Page    = [int]$id
                        IDs  = $null
                        Error = $_.Exception.Message
                    })
                }
                # Exponential backoff
                $sleep = [int]($baseDelay * [math]::Pow(2, $try - 1))
                Start-Sleep -Milliseconds $sleep
            }
        }
    }
    # Cleanup
    $client.Dispose()
    $handler.Dispose()
    # Return ONLY final collection
    return ,$Output
}
# -----------------------------
# Process the queue with the batch processor
# -----------------------------
# Set the batch size for the worker threads
$BatchSize = 100
# Call the Batch Processor and store the results
$Results = Invoke-URLBatchProcessor -Queue $PageQueue -JobBlock $PageJobBlock -Activity "Fetching TypeID Pages" -MaxJobs 3 -BatchSize $BatchSize
# Extract all IDs
$AllTypeIDs = $Results | Where-Object { -not $_.Error } | Select-Object -ExpandProperty IDs | Sort-Object -Unique
# Announce the result
Write-Host "Total TypeIDs: $($AllTypeIDs.Count)"
# -----------------------------
# Determine missing IDs
# -----------------------------
# Make a list of all Type IDs not found in the data we got from the CSV file
$Missing = $AllTypeIDs | Where-Object { -not $TypeIDs.ContainsKey([int32]$_) }
# Get the total count of the missing IDs
$TotalMissing = $Missing.Count
# Announce the result
Write-Host "Missing Types: $TotalMissing"
# -----------------------------
# Process any missing types
# -----------------------------
if ($TotalMissing -gt 0) {
    # -----------------------------
    # Build queue for missing types
    # -----------------------------
    $Queue = [System.Collections.Queue]::new()
    foreach ($id in $Missing) { $Queue.Enqueue($id) }
    # -----------------------------
    # Batched type job block
    # -----------------------------
    $TypeJobBlock = {
        param($Batch, $API, $Source, $RegionID)
        # Suppress noise
        $ProgressPreference    = 'SilentlyContinue'
        $ErrorActionPreference = 'Stop'
        # Faster than array +=
        $Output = [System.Collections.Generic.List[object]]::new()
        # Persistent HttpClient for this worker
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        # Recommended for ESI
        $client.DefaultRequestHeaders.UserAgent.ParseAdd("EveMarketTool/1.0")
        # Retry parameters
        $maxTries  = 5
        $baseDelay = 500   # milliseconds
        # Iterate through the batch of Type IDs
        foreach ($id in $Batch) {
            # Try to get the details for this Type ID, with retries and handling of ESI throttling. We will retry
            # up to $maxTries times with exponential backoff,
            for ($try = 1; $try -le $maxTries; $try++) {
                # Try to get the details for this Type ID
                try {
                    # Build URL
                    $url = "https://esi.evetech.net/$API/universe/types/$id/?datasource=$Source&language=en"
                    # Execute request
                    $response = $client.GetAsync($url).Result
                    # Safely extract status code for throttling logic, default to 0 if we don't have a response
                    $status = [int]$response.StatusCode
                    # Handle ESI throttling
                    if ($status -eq 420 -or $status -eq 429) {
                        # Default delay if no headers are present
                        $delaySeconds = 10
                        # Prefer Retry-After for 429
                        if ($response.Headers.Contains("Retry-After")) {
                            # This header indicates how many seconds to wait before retrying, which is the most direct
                            # way to know how long to wait.
                            $retry = $response.Headers.GetValues("Retry-After") | Select-Object -First 1
                            # Initialize the variable we will use to store the parsed value
                            $parsed = 0
                            # Try to parse the header value as an integer number of seconds. If parsing fails, we will just use the default delay.
                            if ([int]::TryParse($retry, [ref]$parsed)) {$delaySeconds = $parsed}
                        #  Retry-After is not present, check for X-Esi-Error-Limit-Reset.
                        } elseif ($response.Headers.Contains("X-Esi-Error-Limit-Reset")) {
                            # This header indicates how many seconds until the ESI error limit resets, which can be useful to avoid hitting the limit
                            # again on the next request. We will use this as the delay if it is present and can be parsed as an integer.
                            $reset = $response.Headers.GetValues("X-Esi-Error-Limit-Reset") | Select-Object -First 1
                            # Initialize the variable we will use to store the parsed value
                            $parsed = 0
                            # Try to parse the header value as an integer number of seconds. If parsing fails, we will just use the default delay.
                            if ([int]::TryParse($reset, [ref]$parsed)) {$delaySeconds = $parsed}
                        }
                        # Wait the specified delay before retrying
                        Start-Sleep -Seconds $delaySeconds
                        # Do not process this ID further in this iteration, just go to the next try to retry the same ID
                        continue
                    }
                    # Optional: stop on missing pages
                    if ([int]$response.StatusCode -eq 404) {break}
                    # Throw for non-success codes
                    $null = $response.EnsureSuccessStatusCode()
                    # Read content
                    $json = $response.Content.ReadAsStringAsync().Result
                    # Validate response
                    if ([string]::IsNullOrWhiteSpace($json)) {throw "Empty JSON returned by ESI"}
                    # Parse JSON
                    $orders = $json | ConvertFrom-Json
                    # Validate parsed JSON
                    if ($null -eq $orders) {throw "Invalid JSON returned by ESI"}
                    # Build output
                    foreach ($o in $orders) {
                        # Add the Type ID and the details to the output collection. We will include the ID and the name, and set Error to null
                        # since this is a successful result.
                        $Output.Add([PSCustomObject]@{
                            ID    = [int]$id
                            Name  = $o.name
                            Error = $null
                        })
                    }
                    # Success
                    break
                } catch {
                    # Final failure
                    if ($try -eq $maxTries) {
                        # Log the error for this ID and continue with the next one. We will include the ID and the error message in the output
                        # so that we can review it later.
                        $Output.Add([PSCustomObject]@{
                            ID    = [int]$id
                            Name  = $null
                            Error = $_.Exception.Message
                        })
                    }
                    # Exponential backoff
                    $sleep = [int]($baseDelay * [math]::Pow(2, $try - 1))
                    Start-Sleep -Milliseconds $sleep
                }
            }
        }
        # Cleanup
        $client.Dispose()
        $handler.Dispose()
        # Return ONLY final collection
        return ,$Output
    }
    # -----------------------------
    # Process missing types
    #
    # Normally, we would use Invoke-URLBatchProcessor, but we need an periodic save.
    # Thus, we have to use the modified code here.
    # -----------------------------
    # Use generic list instead of array +=
    $Results = [System.Collections.Generic.List[object]]::new()
    # Retryable job states
    $BadStates = @("Failed","Stopped","Blocked")
    # Retry tracking
    $RetryTable = @{}
    $MaxRetries = 5
    # Progress throttling
    $LoopCtr = 0
    # Progress tracking
    $Done = 0
    $Pct = 0
    # Maximum concurrent jobs
    $MaxJobs = 4
    # Batch size
    $BatchSize = 200
    # Clear job table
    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
    # Main scheduler loop
    while (($Queue.Count -gt 0) -or ((Get-Job).Count -gt 0)) {
        # Cache jobs once
        $Jobs = Get-Job
        # ------------------------------------------------
        # Launch jobs
        # ------------------------------------------------
        while (($Queue.Count -gt 0) -and ($Jobs.Count -lt $MaxJobs)) {
            # Use strongly typed list for batch creation
            $Batch = [System.Collections.Generic.List[object]]::new()
            # Fill batch
            for ($i = 0; ($i -lt $BatchSize) -and ($Queue.Count -gt 0); $i++) {$Batch.Add($Queue.Dequeue())}
            # Convert once for ArgumentList
            $BatchArray = $Batch.ToArray()
            # Start thread job
            Start-ThreadJob -ScriptBlock $TypeJobBlock -ArgumentList $BatchArray,$global:API,$global:Source | Out-Null
            # Refresh cached jobs
            $Jobs = Get-Job
        }
        # Active jobs
        $JobCount = $Jobs.Count
        # ------------------------------------------------
        # Progress updates
        # ------------------------------------------------
        if (($LoopCtr -eq 0) -or ($LoopCtr -gt 50)) {
            # Calculate percentage complete, ensuring we don't divide by zero and capping at 100%
            $Pct = [Math]::Min(100,[int](($Done / $TotalMissing) * 100))
            # Build status message
            $Status = "Completed: $Done / $TotalMissing  Jobs: $JobCount Percent: $Pct"
            # Update progress bar
            Write-Progress -Activity "Fetching Missing Type Details" -Status $Status -PercentComplete $Pct
            # Reset loop counter
            $LoopCtr = 0
        }
        # Increment loop counter
        $LoopCtr++
        # ------------------------------------------------
        # Efficient waiting
        # ------------------------------------------------
        # Instead of waiting on each job individually, we can wait on all running jobs at once with a timeout.
        # This allows us to efficiently check for completed jobs and update the progress without blocking
        # indefinitely on any single job.
        $RunningJobs = $Jobs | Where-Object State -eq "Running"
        # If there are running jobs, wait for any of them to complete with a short timeout. This allows us to 
        # periodically check for completed jobs and update the progress.
        if ($RunningJobs.Count -gt 0) {Wait-Job -Job $RunningJobs -Any -Timeout 1 | Out-Null}
        # ------------------------------------------------
        # Process completed jobs
        # ------------------------------------------------
        # We process completed jobs first to free up resources and update our results, which can also help us make
        # informed decisions about retrying failed jobs in the same loop iteration.
        foreach ($job in ($Jobs | Where-Object State -eq "Completed")) {
            # Collect results
            $out = Receive-Job $job
            # Remove completed job
            Remove-Job $job
            # Add results
            foreach ($R in $out) {
                # Add the result to our main results collection. We will process these results for saving and error
                # handling in the next steps.
                $Results.Add($R)
                # Increment the done counter for progress tracking. We do this here after receiving the results to
                # ensure that we only count jobs that have fully completed and whose results we have collected.
                $Done++
            }
        }
        # ------------------------------------------------
        # Restart failed jobs
        # ------------------------------------------------
        # After processing completed jobs, we check for any jobs that are in a failed state and decide whether to retry
        # them based on our retry policy.
        foreach ($job in ($Jobs | Where-Object State -in $BadStates)) {
            # Recover failed batch
            $Batch = $job.Command[0].Arguments[0]
            # Faster retry key generation
            $RetryKey = [string]::Join(',', $Batch)
            # Increment retry counter
            if ($RetryTable.ContainsKey($RetryKey)) {$RetryTable[$RetryKey]++} else { $RetryTable[$RetryKey] = 1 }
            # Retry if allowed
            if ($RetryTable[$RetryKey] -le $MaxRetries) {
                # Uncomment for debugging
                # Write-Warning "Restarting batch job"
                # Remove the job from the job table
                Remove-Job $job
                # To avoid hammering the API in case of repeated failures, we can add a short delay before restarting
                # the job. This can help to mitigate issues such as transient network errors or temporary ESI throttling
                # that may be causing the failures.
                Start-Sleep -Milliseconds 200
                # Restart the job with the same batch. We will use the same script block and arguments to ensure that we
                # are retrying
                Start-ThreadJob -ScriptBlock $TypeJobBlock -ArgumentList $Batch,$global:API,$global:Source | Out-Null
            } else {
                # If we've exceeded the maximum number of retries for this batch, we will log an error message and skip
                # retrying this batch again. This allows us to avoid getting stuck in an infinite retry loop for batches
                # that are consistently failing due to issues that cannot be resolved by simply retrying (e.g., invalid 
                # data, permanent API issues, etc.). By logging the error, we can review these cases later and take any
                # necessary actions (e.g., manual review, adjustments to the batch, etc.).
                Write-Error "Batch permanently failed after $MaxRetries retries"
                # Remove the failed job from the table
                Remove-Job $job
            }
        }
        # ------------------------------------------------
        # Periodic save
        # ------------------------------------------------
        # After processing completed jobs and handling retries, we check if we have reached our save interval for successfully
        # processed items. If we have, we will process the results we have collected so far and save them to the CSV file.
        # This allows us to ensure that we are periodically saving our progress and can recover from any potential issues without
        # losing too much data.
        if ($Results.Count -ge $SaveInterval) {
            # Process each of the returned results
            foreach ($R in $Results) {
                # If it was an error, warn the user and/or skip further processing for this result
                if ($R.Error) {
                    # Uncomment for debugging
                    # Write-Warning "Failed ID $($R.ID): $($R.Error)"                    
                    continue
                }
                # Create an ordered hash for the details, preserving the order in which the key/value pairs were added
                $TypeIDs[$R.ID] = [ordered]@{
                    ID   = $R.ID
                    Type = $R.Name
                }
            }
            # Clear efficiently
            $Results.Clear()
            # Save to CSV
            Save-ToCsv -FilePath $thisFile -Data $TypeIDs
        }
    }
    # Clear progress bar
    Write-Progress -Activity "Fetching Missing Type Details" -Completed
    # -----------------------------
    # Final save
    # -----------------------------
    # Process each of the returned results one last time to catch any remaining results that were not saved during the periodic
    # saves. This ensures that we have all the data saved, even if we did not hit the save interval on the last batch of results.
    foreach ($R in $Results) {
        # If it was an error, warn the user and/or skip further processing for this result
        if ($R.Error) {
            # Uncomment for debugging
            # Write-Warning "Failed ID $($R.ID): $($R.Error)"
            continue
        }
        # Create an ordered hash for the details, preserving the order in which the key/value pairs were added
        $TypeIDs[$R.ID] = [ordered]@{
            ID   = $R.ID
            Type = $R.Name
        }
    }
    # Save the Types hash
    Save-ToCsv -FilePath $thisFile -Data $TypeIDs
    # Announce the status
    Write-Host "Types update complete..."
} else {
    # Announce the status
    Write-Host "No Types to update."
}
#----------------------------------------------------------------------------------------------------------
# Load the market watch list
#
# Description:
# The market watch list is a user-maintained list of stations/structures that the user wants to track for market data.
#
# We use this to filter order data to save storage space and processing time.
#
#----------------------------------------------------------------------------------------------------------
$WatchMarkets = @{}
# Check if the Types CSV file exists
$thisFile = $dataFolder + "\WatchMarkets.csv"
# -----------------------------
# If the file exists
# -----------------------------
if (Test-Path $thisFile) {
    # Announce the action
    Write-Host "Loading existing Watched Markets..."
    # Load the existing Types from the CSV
    $WatchMarkets = Get_FromCSV -filepath $thisFile -keyname "StationName"
    # Announce the success
    Write-Host "Loaded $($WatchMarkets.Count) Watched Market entries"
}
# -----------------------------
# Post-Processing for missing ID's
# -----------------------------
foreach ($thisMarket in $WatchMarkets.Keys) {
    # If the Region ID is NULL
    if (($null -eq $WatchMarkets[$thisMarket]["RegionID"]) -or ($WatchMarkets[$thisMarket]["RegionID"] -eq "")) {
        # Iterate through all the Region keys, look the Region ID up in the Regions hash
        foreach ($thisID in $Regions.Keys) {
            # If the region name matches the data in WatchMarkets
            if ($Regions[$thisID]["Name"] -eq $WatchMarkets[$thisMarket]["RegionName"]) {
                # Update the missing ID
                $WatchMarkets[$thisMarket]["RegionID"] = $thisID
            }
        }
    }
    # -----------------------------
    # If the Station ID is NULL
    # -----------------------------
    if (($null = $WatchMarkets[$thisMarket]["ID"]) -or ($WatchMarkets[$thisMarket]["ID"] -eq "")) {
        # Iterate through all the Station keys, look the Station ID up in the Stations hash
        foreach ($thisID in $Stations.Keys) {
            # If the station name matches the data in WatchMarkets
            if ($Stations[$thisID]["Name"] -eq $WatchMarkets[$thisMarket]["StationName"]) {
                # Update the missing ID
                $WatchMarkets[$thisMarket]["ID"] = $thisID
            }
        }
    }
    # -----------------------------
    # If it is still null, might be a player owned structure
    # -----------------------------
    if (($null = $WatchMarkets[$thisMarket]["ID"]) -or ($WatchMarkets[$thisMarket]["ID"] -eq "")) {
        # Iterate through all the Structure keys, look the Structure ID up in the Structures hash
        foreach ($thisID in $Structures.Keys) {
            # If the Structure name matches the data in WatchMarkets
            if ($Structures[$thisID]["Name"] -eq $WatchMarkets[$thisMarket]["StationName"]) {
                # Update the missing ID
                $WatchMarkets[$thisMarket]["ID"] = $thisID
            }
        }
    }
}
# -----------------------------
# Save the WatchMarkets hash
# -----------------------------
Save-ToCsv -FilePath $thisFile -Data $WatchMarkets
# Announce the status
Write-Host "Watched Markets update complete..."
#----------------------------------------------------------------------------------------------------------
# Load the item (Type) watch list
#
# Description:
# The item (Type) watch list is a user-maintained list of Types that the user wants to track for market data.
#
# We use this to filter order data to save storage space and processing time.
#
#----------------------------------------------------------------------------------------------------------
# Import the Item watch list
$WatchItems = @{}
# Check if the Types CSV file exists
$thisFile = $dataFolder + "\WatchItems.csv"
# If the file exists
if (Test-Path $thisFile) {
    # Announce the action
    Write-Host "Loading existing Watched Items..."
    # Load the existing Types from the CSV using the row counter as the index since the Item ID may be missing
    $WatchItems = Get_FromCSV -filepath $thisFile -keyname $null
}
# -----------------------------
# Post-Processing
# Note: As we iterate through a hash, we can only modify the Values and not the keys. This is why we first
# load the data using the row number as the key, so we can fix any missing type IDs, save back to the file
# and then reload the data with the new (complete) index values.
# -----------------------------
# Get all missing Type IDs
foreach ($ItemKey in $WatchItems.Keys) {
    # Store the item name to speed up future comparisons
    $ItemName = $WatchItems[$ItemKey]["ItemName"]
    $ItemID = $WatchItems[$ItemKey]["ItemID"]
    # Only process valid lines with an actual type name
    if (($ItemName -ne "") -and ($null -ne $ItemName)) {
        # If the Type ID is NULL, look the Type ID up in the Types hash
        if (($null -eq $ItemID) -or ($ItemID -eq "")) {
            # Iterate through all the types
            foreach ($thisID in $TypeIDs.Keys) {
                # If we have a match by the item name
                if ($ItemName -eq $TypeIDs[$thisID]["Type"]) {
                    # Update the ID in the Value portion of the Hash
                    $WatchItems[$ItemKey]["ItemID"] = $thisID
                    # Skips the processing for the rest of the loop
                    continue
                }
            }
        }
    }
}
# -----------------------------
# Save the updated WatchItems
# -----------------------------
Save-ToCsv -FilePath $thisFile -Data $WatchItems
# -----------------------------
# Reload the WatchItems using the correct index
# -----------------------------
$WatchItems = Get_FromCSV -filepath $thisFile -keyname "ItemID"
# Announce the success
Write-Host "Loaded $($WatchItems.Count) Watched Item entries"
#----------------------------------------------------------------------------------------------------------
# Load the buy/sell orders for each listed region
#
# Description:
# The market orders data is the most voluminous data we need to collect, and it can change frequently. To manage this,
# we have implemented a system where we only track orders for specific regions and items that the user has indicated
# they want to watch. This allows us to focus our data collection on the most relevant information and avoid collecting
# large amounts of data that we do not need.
#
# Since we have to pass an additional parameter to the ScriptBlock, we cannot use Invoke-URLBatchProcessor
# Note for future enhancement: See if we can pass a hash with various parameters via Invoke-URLBatchProcessor to the ScriptBlock
#----------------------------------------------------------------------------------------------------------
# Keep a list of queried regions so we don't duplicate effort
$ReportedRegions = New-Object -TypeName System.Collections.Generic.List[int]
# Create the hash to hold market orders
$Orders = @{}
# Create an Array to hold missing Station IDs
$MissingStations = New-Object -TypeName System.Collections.Generic.List[int]
# -----------------------------
# Batched Order job block
# -----------------------------
$OrderJobBlock = {
    param($Batch, $API, $Source, $RegionID)
    # Suppress noise
    $ProgressPreference    = 'SilentlyContinue'
    $ErrorActionPreference = 'Stop'
    # Faster than array +=
    $Output = [System.Collections.Generic.List[object]]::new()
    # Persistent HttpClient for this worker
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    # Recommended for ESI
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("EveMarketTool/1.0")
    # Retry parameters
    $maxTries  = 5
    $baseDelay = 500   # milliseconds
    # Iterate through the batch of page IDs
    foreach ($id in $Batch) {
        # Try to get the page of market orders, with retries and handling of ESI throttling. We will retry up to $maxTries times
        for ($try = 1; $try -le $maxTries; $try++) {
            # Try to get the page of market orders
            try {
                # Build URL
                $url = "https://esi.evetech.net/$API/markets/$RegionID/orders/?datasource=$Source&order_type=all&page=$id"
                # Execute request
                $response = $client.GetAsync($url).Result
                # Safely extract status code for throttling logic, default to 0 if we don't have a response
                $status = [int]$response.StatusCode
                # Handle ESI throttling
                if ($status -eq 420 -or $status -eq 429) {
                    # Default delay if no headers are present
                    $delaySeconds = 10
                    # Check for 429 responses first, as they are more likely to include the Retry-After header which gives
                    #a direct indication of how long to wait. If it's not present, then check for ESI-specific headers.
                    # Prefer Retry-After for 429
                    if ($response.Headers.Contains("Retry-After")) {
                        # This header indicates how many seconds to wait before retrying, which is the most direct way to know how long to wait.
                        $retry = $response.Headers.GetValues("Retry-After") | Select-Object -First 1
                        # Initialize the variable we will use to store the parsed value
                        $parsed = 0
                        # Try to parse the header value as an integer number of seconds. If parsing fails, we will just use the default delay.
                        if ([int]::TryParse($retry, [ref]$parsed)) {$delaySeconds = $parsed}
                    # Check for ESI 420 responses, which will not have Retry-After but may have X-Esi-Error-Limit-Reset to indicate how long until
                    # the error limit resets.
                    } elseif ($response.Headers.Contains("X-Esi-Error-Limit-Reset")) {
                        # This header indicates how many seconds until the ESI error limit resets, which can be useful to avoid hitting the limit again
                        # on the next request. We will use this as the delay if it is present and can be parsed as an integer.
                        $reset = $response.Headers.GetValues("X-Esi-Error-Limit-Reset") | Select-Object -First 1
                        # Initialize the variable we will use to store the parsed value
                        $parsed = 0
                        # Try to parse the header value as an integer number of seconds. If parsing fails, we will just use the default delay.
                        if ([int]::TryParse($reset, [ref]$parsed)) {$delaySeconds = $parsed}
                    }
                    # Wait the specified delay before retrying
                    Start-Sleep -Seconds $delaySeconds
                    # Do not process this page further in this iteration, just go to the next try to retry the same page
                    continue
                }
                # Optional: stop on missing pages
                if ([int]$response.StatusCode -eq 404) {break}
                # Throw for non-success codes
                $null = $response.EnsureSuccessStatusCode()
                # Read content
                $json = $response.Content.ReadAsStringAsync().Result
                # Validate response
                if ([string]::IsNullOrWhiteSpace($json)) {throw "Empty JSON returned by ESI"}
                # Parse JSON
                $orders = $json | ConvertFrom-Json
                if ($null -eq $orders) {throw "Invalid JSON returned by ESI"}
                # Build output
                foreach ($o in $orders) {
                    # Add the page ID and the details of each order to the output collection. We will include the page number and the relevant details
                    # of each order, and set Error to null since this is a successful result.
                    $Output.Add([PSCustomObject]@{
                        Page      = [int]$id
                        # Returns Int32 for a station, int64 for a structure
                        StationID = $o.location_id
                        TypeID    = $o.type_id
                        IsBuy     = $o.is_buy_order
                        Price     = $o.price
                        Remaining = $o.volume_remain
                        Total     = $o.volume_total
                        OrderId   = $o.order_id
                        Error     = $null
                    })
                }
                # Success
                break
            } catch {
                # Final failure
                if ($try -eq $maxTries) {
                    # Log the error for this page and continue with the next one. We will include the page number and the error message in the output
                    $Output.Add([PSCustomObject]@{
                        Page      = [int]$id
                        StationID = $null
                        TypeID    = $null
                        IsBuy     = $null
                        Price     = $null
                        Remaining = $null
                        Total     = $null
                        OrderId   = $null
                        Error     = $_.Exception.Message
                    })
                }
                # Exponential backoff
                $sleep = [int]($baseDelay * [math]::Pow(2, $try - 1))
                Start-Sleep -Milliseconds $sleep
            }
        }
    }
    # Cleanup
    $client.Dispose()
    $handler.Dispose()
    # Return ONLY final collection
    return ,$Output
}
# ----------------------------------------------------------
# Process Orders for every market in WatchMarkets
# ----------------------------------------------------------
# Iterate through all the markets in our WatchMarkets hash
foreach ($MarketName in $WatchMarkets.Keys) {
    # Save repeated lookups locally
    $RegionID   = $WatchMarkets[$MarketName]["RegionID"]
    $RegionName = $WatchMarkets[$MarketName]["RegionName"]
    # Only process if we have not processed it
    # (Market orders are reported by Region and are not specific to a market)
    if ($ReportedRegions.Contains($RegionID)) {continue}
    # Add it to ReportedRegions so we don't query it again
    $ReportedRegions.Add($RegionID)
    # Turn off the Invoke-WebRequest progress bar interference
    $ProgressPreference = 'SilentlyContinue'
    # Get the total number of pages
    $URI = "https://esi.evetech.net/$API/markets/$RegionID/orders/?datasource=$Source&order_type=all&page=1"
    # Get the number of pages of data to query from the response header
    $MaxPage = (Invoke-WebRequest -UseBasicParsing -Uri $URI | Select-Object -ExpandProperty Headers).'X-Pages'
    # Restore progress bar default behaviour
    $ProgressPreference = 'Continue'
    # -----------------------------
    # Create the queue of pages to process for this region. We will use a simple queue data structure to hold the page numbers that we need
    # to process.
    # -----------------------------
    # Create and populate the queue
    $PageQueue = [System.Collections.Queue]::new()
    1..$MaxPage | ForEach-Object {$PageQueue.Enqueue($_)}
    # -----------------------------
    # Process Orders by Region and page
    # -----------------------------
    # Use generic list instead of array +=
    $Results = [System.Collections.Generic.List[object]]::new()
    # Jobs in these states will be restarted
    $BadStates = @("Failed","Stopped","Blocked")
    # Retry tracking
    $RetryTable = @{}
    $MaxRetries = 5
    # Progress throttling counter
    $LoopCtr = 0
    # Progress tracking values
    $Done = 0
    $JobCount = 0
    $Pct = 0
    # Max concurrent jobs
    $MaxJobs = 4
    # Batch size
    $BatchSize = 100
    # Announce
    Write-Host "Reading market data from $RegionName"
    # Clear the job table
    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
    # Keep processing while we have queued items or running jobs
    while (($PageQueue.Count -gt 0) -or ((Get-Job).Count -gt 0)) {
        # Cache jobs table
        $Jobs = Get-Job
        # Fill available worker slots
        while (($PageQueue.Count -gt 0) -and ($Jobs.Count -lt $MaxJobs)) {
            # Create a new batch
            $Batch = @()
            # Fill batch
            for ($i = 1; $i -le $BatchSize -and $PageQueue.Count -gt 0; $i++) {$Batch += $PageQueue.Dequeue()}
            # Start thread job
            Start-ThreadJob -ScriptBlock $OrderJobBlock -ArgumentList $Batch,$global:API,$global:Source,$RegionID | Out-Null
            # Refresh jobs cache
            $Jobs = Get-Job
        }
        # Get current job count
        $JobCount = $Jobs.Count
        # Throttled progress updates
        if (($LoopCtr -eq 0) -or ($LoopCtr -gt 40)) {
            # Calculate percentage complete, ensuring we don't divide by zero and capping at 100%
            $Pct = [Math]::Min(100, [int](($Done / $MaxPage) * 100))
            # Update progress bar
            Write-Progress -Activity "Fetching Orders for $RegionName"  -Status "Completed: $Done / $MaxPage Jobs: $JobCount"  -PercentComplete $Pct
            # Reset loop counter
            $LoopCtr = 0
        }
        # Increment loop counter
        $LoopCtr++
        # Wait efficiently for any job to complete
        if ($Jobs.Count -gt 0) {Wait-Job -Job $Jobs -Any -Timeout 1 | Out-Null}
        # Process completed jobs
        foreach ($job in Get-Job -State Completed) {
            # Get results
            $out = Receive-Job $job
            # Remove completed job
            Remove-Job $job
            # Add results to list
            foreach ($R in $out) {$Results.Add($R)}
            # Update completed counter correctly
            $Done += [math]::Ceiling($out.Count / 1000)
        }
        # Restart bad-state jobs
        foreach ($state in $BadStates) {
            # Cache jobs in this state
            $BadJobs = Get-Job -State $state
            # Process each bad job
            foreach ($job in $BadJobs) {
                # Recover failed batch
                $Batch = $job.Command[0].Arguments[0]
                # Retry key
                $RetryKey = ($Batch -join ',')
                # Initialize retry counter
                if (!$RetryTable.ContainsKey($RetryKey)) {$RetryTable[$RetryKey] = 0}
                # Increment retry count
                $RetryTable[$RetryKey]++
                # Retry only within limits
                if ($RetryTable[$RetryKey] -le $MaxRetries) {
                    # Uncomment for debugging
                    Write-Warning "Restarting batch job for IDs $($Batch -join ', ') (retry $($RetryTable[$RetryKey]))"
                    # Remove failed job
                    Remove-Job $job
                    # Small stabilization delay
                    Start-Sleep -Milliseconds 200
                    # Restart SAME job block
                    Start-ThreadJob -ScriptBlock $OrderJobBlock -ArgumentList $Batch,$global:API,$global:Source,$RegionID | Out-Null
                } else {
                    # Log permanent failure
                    Write-Error "Batch permanently failed after $MaxRetries retries: $($Batch -join ', ')"
                    # Remove failed job
                    Remove-Job $job
                }
            }
        }
    }
    # Clear progress bar
    Write-Progress -Activity "Fetching Orders for $RegionName" -Completed
    # ----------------------------------------------------------
    # Post Process Orders
    # ----------------------------------------------------------
    foreach ($thisOrder in $Results) {
        # Skip errored pages
        if ($thisOrder.Error) {Write-Warning "Failed Page for $RegionName $($thisOrder.Page): $($thisOrder.Error)";continue}
        # Skip unwatched items immediately
        if (!$WatchItems.ContainsKey($thisOrder.TypeID)) {continue}
        # Save these to make things easier to read
        $TypeID    = $thisOrder.TypeID
        # StationIDs can be Int32 or Int64, we retain these structures and hash keys are strongly typed, so be careful.
        # Int32 values are actual Stations, Int64 are Player owned Structures. Both can have markets.
        $StationID = Get-Typed($thisOrder.StationID)
        # We use the OrderID as a unique identifier for each order, which is important for identifying individual orders.
        $OrderID   = $thisOrder.OrderId
        # Is it in a station we are watching?
        foreach ($thisMarket in $WatchMarkets.Keys) {
            # If not, don't process the order, move to the next one.
            if ($WatchMarkets[$thisMarket]["ID"] -ne $StationID) {continue}
            # Initialize hash structure if needed
            if (!$Orders.ContainsKey($TypeID)) {$Orders[$TypeID] = @{}}
            if (!$Orders[$TypeID].ContainsKey($StationID)) {
                $Orders[$TypeID][$StationID] = @{
                    Buy  = @{}
                    Sell = @{}
                }
            }
            # Select buy/sell table once
            if ($thisOrder.IsBuy -eq $true) {$TargetTable = $Orders[$TypeID][$StationID]["Buy"]} else {$TargetTable = $Orders[$TypeID][$StationID]["Sell"]}
            # Insert the order into the hashtable using the OrderID as the key
            $TargetTable[$OrderID] = @{
                Price     = $thisOrder.Price
                Remaining = $thisOrder.Remaining
                Total     = $thisOrder.Total
            }
        }
        # Track missing stations
        if ($StationID -lt 1000000000000) {
            if ((!$Stations.ContainsKey($StationID)) -and (!$MissingStations.Contains($StationID))) {$MissingStations.Add($StationID)}
        }
    }
}
# ----------------------------------------------------------
# Save the Orders
#
# Because of the complex structure of the Orders hash, we will write the CSV manually with a StreamWriter. This allows us to
# control the output format and ensure that we are writing the data in the correct structure for our needs. We will write a
# header row first, and then iterate through the Orders hash to write each order as a line in the CSV file. 
# ----------------------------------------------------------
# Filename
$thisFile = $dataFolder + "\Orders.csv"
# Create a StreamWriter for UTF-8 output
$writer = [System.IO.StreamWriter]::new($thisFile, $false, [System.Text.UTF8Encoding]::new($false))
# Write the header
$header = "TypeID,StationID,Type,OrderID,Price,Total,Remaining"
$writer.WriteLine($header)
# Build each line from the complex hash
foreach ($TypeID in ($Orders.Keys | Sort-Object)) {
    foreach ($StationID in ($Orders[$TypeID].Keys | Sort-Object)) {
        foreach ($TxnType in @("Buy","Sell")) {
            foreach ($OrderID in $Orders[$TypeID][$StationID][$TxnType].Keys) {
                $Price = $Orders[$TypeID][$StationID][$TxnType][$OrderId]["Price"]
                $Total = $Orders[$TypeID][$StationID][$TxnType][$OrderId]["Total"]
                $Remaining = $Orders[$TypeID][$StationID][$TxnType][$OrderId]["Remaining"]
                # Form the output
                $LineData = "$TypeID,$StationID," + '"' + $TxnType + '",' + "$OrderID,$Price,$Total,$Remaining"
                # Write the data
                $writer.WriteLine($LineData)            }
        }
    }
}
$writer.Close()
# ----------------------------------------------------------
# Process missing stations
#
# There is no ESI endpoint to get station details in bulk, so we have to query each station individually. To do 
# this efficiently, we can build a list of missing stations from the market data since all stations have a market.
# Once we know which stations we are missing, we can use a batched approach with multiple threads to query the station
# details in parallel. We will implement retries and throttling handling in the same way as we do for orders to ensure
# that we can get as much data as possible even if there are transient issues with the API. Finally, we will save the
# station details to our Stations hash and persist it to the CSV file.
# ----------------------------------------------------------
if ($MissingStations.Count -gt 0) {
    # -----------------------------
    # Batched type job block
    # -----------------------------
    $StationJobBlock = {
        param($Batch, $API, $Source)
        # Suppress noise
        $ProgressPreference    = 'SilentlyContinue'
        $ErrorActionPreference = 'Stop'
        # Faster than += arrays
        $Results = [System.Collections.Generic.List[object]]::new()
        # Persistent HttpClient
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        # Recommended for ESI
        $client.DefaultRequestHeaders.UserAgent.ParseAdd("EveMarketTool/1.0")
        # Retry settings
        $maxTries  = 5
        $baseDelay = 500   # milliseconds
        # Process each station ID
        foreach ($id in $Batch) {
            # Retry loop
            for ($try = 1; $try -le $maxTries; $try++) {
                # Try to get station details, with handling for ESI throttling and retries. We will attempt to get the
                # station details up to $maxTries times before giving up and logging an error.
                try {
                    # API endpoint
                    $url = "https://esi.evetech.net/$API/universe/stations/$id/?datasource=$Source"
                    # Execute request
                    $response = $client.GetAsync($url).Result
                    # Get any returned status code for throttling logic, default to 0 if we don't have a response
                    $status = [int]$response.StatusCode
                    # Handle ESI throttling
                    if ($status -eq 420 -or $status -eq 429) {
                        # Default delay if no headers are present
                        $delaySeconds = 10
                        # Prefer Retry-After for 429
                        if ($response.Headers.Contains("Retry-After")) {
                            # This header indicates how many seconds to wait before retrying, which is the most direct way 
                            # to know how long to wait.
                            $retry = $response.Headers.GetValues("Retry-After") | Select-Object -First 1
                            # Initialize the variable we will use to store the parsed value
                            $parsed = 0
                            # Try to parse the header value as an integer number of seconds. If parsing fails, we will just use
                            # the default delay.
                            if ([int]::TryParse($retry, [ref]$parsed)) {$delaySeconds = $parsed}
                        # Check for ESI 420 responses, which will not have Retry-After but may have X-Esi-Error-Limit-Reset to
                        # indicate how long until the error limit resets.
                        } elseif ($response.Headers.Contains("X-Esi-Error-Limit-Reset")) {
                            # This header indicates how many seconds until the ESI error limit resets, which can be useful to avoid
                            # hitting the limit again on the next request. We will use this as the delay if it is present and can be
                            # parsed as an integer.
                            $reset = $response.Headers.GetValues("X-Esi-Error-Limit-Reset") | Select-Object -First 1
                            # Initialize the variable we will use to store the parsed value
                            $parsed = 0
                            # Try to parse the header value as an integer number of seconds. If parsing fails, we will just use the default delay.
                            if ([int]::TryParse($reset, [ref]$parsed)) {$delaySeconds = $parsed}
                        }
                        # Wait the specified delay before retrying
                        Start-Sleep -Seconds $delaySeconds
                        # Do not process this station further in this iteration, just go to the next try to retry the same station ID
                        continue
                    }
                    # Optional: station does not exist
                    if ([int]$response.StatusCode -eq 404) {
                        # Log the missing station and continue with the next one. We will include the station ID and an error message in
                        # the output.
                        $Results.Add([PSCustomObject]@{
                            ID       = [int64]$id
                            Name     = $null
                            SystemID = $null
                            Error    = "Station not found"
                        })
                        # Exit the retry loop for this station since it does not exist and we don't want to waste retries on it
                        break
                    }
                    # Throw for non-success codes
                    $null = $response.EnsureSuccessStatusCode()
                    # Read content
                    $json = $response.Content.ReadAsStringAsync().Result
                    # Validate response
                    if ([string]::IsNullOrWhiteSpace($json)) {throw "Empty JSON returned by ESI"}
                    # Parse JSON
                    $R = $json | ConvertFrom-Json
                    # Validate parsed JSON
                    if ($null -eq $R) {throw "Invalid JSON returned by ESI"}
                    # Build result object
                    $Results.Add([PSCustomObject]@{
                        ID       = [int64]$id
                        Name     = $R.name
                        SystemID = [int32]$R.system_id
                        Error    = $null
                    })
                    # Success
                    break
                } catch {
                    # Final failure
                    if ($try -eq $maxTries) {
                        # Log the error for this station and continue with the next one. We will include the station ID
                        # and the error message in the output.
                        $Results.Add([PSCustomObject]@{
                            ID       = [int64]$id
                            Name     = $null
                            SystemID = $null
                            Error    = $_.Exception.Message
                        })
                    }
                    # Exponential backoff
                    $sleep = [int]($baseDelay * [math]::Pow(2, $try - 1))
                    Start-Sleep -Milliseconds $sleep
                }
            }
        }
        # Cleanup
        $client.Dispose()
        $handler.Dispose()
        # Return ONLY final collection
        return ,$Results
    }
    # -----------------------------
    # Batch Queue
    # -----------------------------
    # Create and populate the queue
    $Queue   = [System.Collections.Queue]::new()
    ForEach ($StationID in $MissingStations) {$Queue.Enqueue($StationID)}
    # -----------------------------
    # Process the Queue
    # -----------------------------
    # Set the MaxJobs
    $MaxJobs = 4
    # Set the batch size
    $BatchSize = [int]($MissingStations.Count / $MaxJobs) + 1
    if ($BatchSize -lt 200) {$BatchSize = 200}
    # Call the Batch Processor and store the results
    $Results = Invoke-URLBatchProcessor -Queue $Queue -JobBlock $StationJobBlock -Activity "Fetching Missing Stations" -MaxJobs $MaxJobs -BatchSize $BatchSize
    # -----------------------------
    # Process the Results
    # -----------------------------
    foreach ($R in $Results) {
        # If it was an error, warn the user and/or skip further processing for this result
        if ($R.Error) {
            Write-Warning "Failed ID $($R.ID): $($R.Error)"
            continue
        }
        # Create an ordered hash for the details, preserving the order in which the key/value pairs were added
        $Stations[$R.ID] = [ordered]@{
            ID   = $R.ID
            Name = $R.Name
            SystemID = $R.SystemID
        }
    }
    # -----------------------------
    # Save the updated Stations data
    # -----------------------------
    $thisFile = $datafolder + '\Stations.csv'
    Save-ToCsv -FilePath $thisFile -Data $Stations
}
#
# Calculate the Price Spreads and summary
#
$Prices = @{}
# Iterate through all the TypeIDs
foreach ($TypeID in ($Orders.Keys | Sort-Object)) {
    # Ensure TypeID container exists
    if (-not $Prices.ContainsKey($TypeID)) {$Prices[$TypeID] = @{}}
    # Process stations
    foreach ($StationID in ($Orders[$TypeID].Keys | Sort-Object)) {
        # Ensure StationID container exists
        if (-not $Prices[$TypeID].ContainsKey($StationID)) {$Prices[$TypeID][$StationID] = @{}}
        # Process Buy/Sell orders
        foreach ($TxnType in @("Buy", "Sell")) {
            # Safely retrieve order set
            $OrderSet = $Orders[$TypeID][$StationID][$TxnType]
            # Skip missing or empty order groups
            if ($null -eq $OrderSet -or $OrderSet.Count -eq 0) {continue}
            # Create output container ONLY if data exists
            $Prices[$TypeID][$StationID][$TxnType] = @{}
            # Initialize summary stats
            $High = 0.0
            $Low = [double]::MaxValue
            $TotalRemaining = 0
            $TotalPrice = 0.0
            # Process all orders
            foreach ($OrderID in $OrderSet.Keys) {
                # Get the individual order data
                $Order = $OrderSet[$OrderID]
                # Force numeric typing
                $Price = [double]$Order["Price"]
                $Remaining = [int]$Order["Remaining"]
                # High / Low tracking
                if ($Price -gt $High) {$High = $Price}
                if ($Price -lt $Low) {$Low = $Price}
                # Weighted average accumulation
                $TotalRemaining += $Remaining
                $TotalPrice += ($Price * $Remaining)
            }
            # Calculate weighted average
            if ($TotalRemaining -gt 0) {$Average = $TotalPrice / $TotalRemaining} else {$Average = 0}
            # Store summary data
            $Prices[$TypeID][$StationID][$TxnType]["High"] = $High
            $Prices[$TypeID][$StationID][$TxnType]["Low"] = $Low
            $Prices[$TypeID][$StationID][$TxnType]["Average"] = $Average
        }
    }
}
# -----------------------------
# Save the Prices data
# -----------------------------
$thisFile = $datafolder + '\Prices.csv'
Save-ToCsv -FilePath $thisFile -Data $Prices
# Create a StreamWriter for UTF-8 output
$writer = [System.IO.StreamWriter]::new($thisFile, $false, [System.Text.UTF8Encoding]::new($false))
# Write the header
$header = '"TypeID","StationID","Type","High","Low","Average"'
$writer.WriteLine($header)
# Build each line from the complex hash. We will iterate through the Prices hash and write each entry to
# the CSV file. We will include the TypeID, StationID, Transaction Type (Buy/Sell), and the calculated High,
# Low, and Average prices for each combination of TypeID and StationID. We will also ensure that we only write
# entries where we have valid price data (e.g., High is not zero) to avoid cluttering the output with invalid entries.
foreach ($TypeID in ($Prices.Keys | Sort-Object)) {
    foreach ($StationID in ($Prices[$TypeID].Keys | Sort-Object)) {
        foreach ($TxnType in @("Buy", "Sell")) {
            # Safely retrieve transaction data
            $TxnData = $Prices[$TypeID][$StationID][$TxnType]
            # Skip missing or empty entries
            if ($null -eq $TxnData -or $TxnData.Count -eq 0) {continue}
            # Retrieve summary values
            $High = [double]$TxnData["High"]
            $Low = [double]$TxnData["Low"]
            $Average = [double]$TxnData["Average"]
            # Skip invalid entries
            if ($High -eq 0) {continue}
            # Build output line
            $LineData = ("$TypeID,$StationID," + '"' + $TxnType + '",' + "$High,$Low,$Average")
            # Write the output line
            $writer.WriteLine($LineData)
        }
    }
}
# Close the writer to flush the data to the file
$writer.close()
#------------------------------------------
# Announce the finish
#------------------------------------------
# Get the End Time
$EndTime = [datetime]::Now
# Announce Finish
$Message = "Processing Complete..." + $EndTime.ToString()
write-host $Message
# Report how many minutes it took
$minutes = ($EndTime - $StartTime).TotalMinutes
$Message = "Elapsed: $minutes minutes..."
write-host $Message