# If you want to run this script, you need to have the .NET Framework installed on your machine, as it relies
# on .NET classes for HTTP requests and OAuth handling. The script is designed to be run in a PowerShell
# environment on Windows.
#
# Note: This script is intended for educational purposes and may require modifications to work in your specific
# environment. Always review and test scripts before running them, especially when they involve authentication and API interactions.
#
# You will need to load the system.web assembly to use HttpUtility for URL encoding/decoding as well as Invoke-Web request for API calls.
Add-Type -AssemblyName System.Web
# ---------------------------------------------------------
#
# CONFIGURATION
#
# ---------------------------------------------------------
#
# Source data center for ESI API calls
$Source = "tranquility"
$API= "latest"
#
# This specifies the common folder where we will save the data we get from ESI. It assumes a certain folder structure, so you may need
# to adjust it based on where you want to save your data.
$dataFolder = $PSScriptRoot.Replace('Powershell','')
$dataFolder += "Data\"
#
# These are the parameters for the OAuth2 authentication process. You will need to register an application in the EVE Online developers portal
# to get a Client ID, and you should set the callback URL to match what you have registered. The scopes should be set based on the permissions
# your application needs.
$ClientID = "6e99142b1a1248c8b07550f2211c96be"
$CallBack = "http://localhost/callback/"
$Scopes = "publicData esi-universe.read_structures.v1 esi-markets.structure_markets.v1"
$State = "AOW Market Login"
#
# Test for admin privileges, which are required to run the local HTTP listener for OAuth callback handling. If the script is not run as admin,
# it will prompt the user and exit.
if (!(([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))) {
    Write-Host "You need to run Powershell as Administrator before this script will work." -ForegroundColor Red
    Exit
}

# ---------------------------------------------------------
#
# FUNCTIONS
#
# ---------------------------------------------------------
# ---------------------------------------------------------
# PKCE HELPERS
# ---------------------------------------------------------
#
# base64URLEncode -Bytes <byte[]>
#
# Parameters:
#   - Bytes: The byte array to encode.
# Returns:
#   The base64 URL-encoded string.
# Description:
# This function takes a byte array, encodes it to base64, and then modifies the resulting string to be URL-safe
# by replacing certain characters and removing padding. This is commonly used in OAuth2 PKCE flows for encoding
# the code verifier and code challenge.
#----------------------------------------------------------------------------------------------------------
function base64URLEncode($Bytes) {
    # Encode the string to Base 64
    $Encoded = [Convert]::ToBase64String($Bytes)
    $Encoded = $Encoded.replace('+', '-').replace('/', '_').replace('=', '')
    # Return what we got
    return $Encoded
}
# ---------------------------------------------------------
# LOCAL HTTP LISTENER FOR AUTH CODE
# ---------------------------------------------------------
# Get-AuthCode -Url <string>
#
# Parameters:
#   - Url: The URL to initiate the OAuth2 authorization flow.
# Returns:
#   The authorization code received from the OAuth2 provider.
# Description:
# This function sets up a local HTTP listener to handle the OAuth2 callback and retrieve the authorization code.
# It launches the user's default web browser to the specified URL, waits for the OAuth2 provider to redirect back
# with the authorization code, and then extracts and returns that code. The function also includes error handling
# and ensures that resources are cleaned up properly.
#----------------------------------------------------------------------------------------------------------
function Get-AuthCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Url
    )
    # Create listener
    $HttpListener = [System.Net.HttpListener]::new()
    # OAuth callback endpoint
    $HttpListener.Prefixes.Add('http://localhost/callback/')
    try {
        # Start listener
        $HttpListener.Start()
        # Launch browser
        $Proc = Start-Process $Url -PassThru
        # Wait for OAuth redirect
        $Context = $HttpListener.GetContext()
        # Get redirected URL
        $ResponseUrl = $Context.Request.Url
        # Auto-close browser tab/window
        $Html = @"
<html>
<head>
<title>Authentication Complete</title>
<script>
window.open('','_self');
window.close();
</script>
</head>
<body>
Authentication successful. You may close this window.
</body>
</html>
"@
        # Convert response to bytes
        $Content = [System.Text.Encoding]::UTF8.GetBytes($Html)
        # Configure response
        $Context.Response.ContentType = 'text/html'
        $Context.Response.ContentEncoding = [System.Text.Encoding]::UTF8
        $Context.Response.ContentLength64 = $Content.Length
        $Context.Response.KeepAlive = $false
        $Context.Response.StatusCode = 200
        # Send response
        $Context.Response.OutputStream.Write($Content, 0, $Content.Length)
        # Close response cleanly
        $Context.Response.OutputStream.Close()
        $Context.Response.Close()
        # Extract authorization code and return it to the caller
        if ($ResponseUrl.Query -match 'code=([^&]+)') {return [System.Web.HttpUtility]::UrlDecode($Matches[1])}
        # If we got here, something went wrong
        return "Invalid response."
    } finally {
        # Always close listener
        if ($HttpListener.IsListening) {$HttpListener.Stop()}
        # Close listener to free resources
        $HttpListener.Close()
        # Optional browser cleanup
        if ($Proc -and !$Proc.HasExited) {
            try {
                # Only close if still running
                $Proc.CloseMainWindow() | Out-Null
            } catch {}
        }
    }
}
# ---------------------------------------------------------
# TOKEN MANAGEMENT
# ---------------------------------------------------------
#
# Test-Token -RefreshBufferSeconds <int>
#
# Parameters:
#   - RefreshBufferSeconds: The number of seconds before expiry to refresh the token.
# Returns:
#   A boolean indicating whether the token was refreshed successfully.
# Description:
# This function tests the validity of the current OAuth token and refreshes it if necessary.
#----------------------------------------------------------------------------------------------------------
function Test-Token {
    [CmdletBinding()]
    param(
        # Refresh token this many seconds before expiry
        [int]$RefreshBufferSeconds = 5
    )
    # Validate token existence
    if (!$Global:Token) {throw "Global token object is missing."}
    # Validate expiry existence
    if (!$Global:TokenExpires) {throw "Global token expiration timestamp is missing."}
    # Current UTC time
    $Now = [DateTime]::UtcNow
    # Refresh threshold
    $RefreshTime = $Global:TokenExpires.AddSeconds(-$RefreshBufferSeconds)
    # Token still valid
    if ($Now -lt $RefreshTime) {return $true}
    # OAuth token endpoint
    $TokenUrl = "https://login.eveonline.com/v2/oauth/token/"
    # Request body
    $Body = @{
        grant_type   = "refresh_token"
        refresh_token = $Global:Token.refresh_token
        client_id    = $Global:ClientID
    }
    # Request headers
    $Headers = @{
        'Content-Type' = 'application/x-www-form-urlencoded'
        'Host'         = 'login.eveonline.com'
    }
    try {
        # Request refreshed token
        $Response = Invoke-WebRequest -Uri $TokenUrl -Headers $Headers -Body $Body -Method Post -UseBasicParsing -ErrorAction Stop
        # Parse token
        $NewToken = $Response.Content | ConvertFrom-Json
        # Update globals atomically
        $Global:Token = $NewToken
        # Use actual expires_in value if present
        if ($NewToken.expires_in) {
            $Global:TokenExpires = [DateTime]::UtcNow.AddSeconds([int]$NewToken.expires_in)
        } else {
            # Fallback safety
            $Global:TokenExpires = [DateTime]::UtcNow.AddMinutes(20)
        }
        # Indicate success
        return $true
    } catch {
        # Log the error for debugging purposes. In a production environment, you might want to implement more robust logging
        # or error handling here.
        Write-Error "Token refresh failed: $($_.Exception.Message)"
        # Indicate failure
        return $false
    }
}
# ---------------------------------------------------------
# MAIN AUTHENTICATION
# ---------------------------------------------------------
#
# Get-EveOAuthToken -ClientID <string> -Callback <string> -Scopes <string> -State <string>
#
# Parameters:
#   - ClientID: The EVE Online OAuth client ID.
#   - Callback: The OAuth callback URL.
#   - Scopes: The OAuth scopes.
#   - State: The OAuth state value.
# Returns:
#   The OAuth access token.
# Description:
# This function handles the OAuth2 flow for authenticating with the EVE Online API. It generates a PKCE verifier and
# challenge, builds the authorization URL, launches the browser, retrieves the authorization code, and exchanges it
# for an access token.
#----------------------------------------------------------------------------------------------------------
function Get-EveOAuthToken {
    [CmdletBinding()]
    param(
        # EVE Online OAuth Client ID
        [Parameter(Mandatory)]
        [string]$ClientID,
        # OAuth callback URL
        [Parameter(Mandatory)]
        [string]$Callback,
        # OAuth scopes
        [Parameter(Mandatory)]
        [string]$Scopes,
        # OAuth state value
        [Parameter(Mandatory)]
        [string]$State
    )
    # ------------------------------------------------
    # Generate PKCE verifier/challenge
    # ------------------------------------------------
    # Generate a random 32-byte value for the PKCE code verifier. This will be used in the OAuth2 flow to enhance security by
    # preventing authorization code interception attacks.
    $Bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($Bytes)
    # PKCE verifier
    $CodeVerifier = base64URLEncode($Bytes)
    # SHA256 hash of verifier
    $Hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($CodeVerifier))
    # PKCE challenge
    $CodeChallenge = base64URLEncode($Hash)
    # ------------------------------------------------
    # Build authorization URL
    # ------------------------------------------------
    $QueryParams = @(
        "response_type=code"
        "redirect_uri=$([System.Web.HttpUtility]::UrlEncode($Callback))"
        "client_id=$ClientID"
        "scope=$([System.Web.HttpUtility]::UrlEncode($Scopes))"
        "code_challenge=$CodeChallenge"
        "code_challenge_method=S256"
        "state=$([System.Web.HttpUtility]::UrlEncode($State))"
    )
    # Build the full URL
    $AuthUrl = "https://login.eveonline.com/v2/oauth/authorize/?"
    $AuthUrl += ($QueryParams -join '&')
    # ------------------------------------------------
    # Launch browser and retrieve auth code
    # ------------------------------------------------
    # This will open the user's default web browser to the EVE Online login page. After the user logs in and authorizes the application,
    # the OAuth provider will redirect back to the specified callback URL, which is handled by the Get-AuthCode function to extract the
    # authorization code.
    $AuthCode = Get-AuthCode -Url $AuthUrl
    # Validate the authorization code
    if ([string]::IsNullOrWhiteSpace($AuthCode) -or ($AuthCode -eq "Invalid response.")) {throw "Failed to retrieve OAuth authorization code."}
    # ------------------------------------------------
    # Token request
    # ------------------------------------------------
    # Now that we have the authorization code, we need to exchange it for an access token. This involves making a POST request to the EVE Online
    # token endpoint with the appropriate parameters, including the client ID, code verifier, and the authorization code we just received.
    $TokenUrl = "https://login.eveonline.com/v2/oauth/token/"
    # Request body for token exchange
    $Body = @{
        grant_type   = "authorization_code"
        code         = $AuthCode
        client_id    = $ClientID
        code_verifier = $CodeVerifier
    }
    # Request headers
    $Headers = @{
        'Content-Type' = 'application/x-www-form-urlencoded'
        'Host'         = 'login.eveonline.com'
    }
    try {
        # Make the token request and parse the response. If the request is successful, we will receive a JSON response containing the access
        # token and its expiration time. We convert this JSON response into a PowerShell object for easier access to the token properties.
        $Response = Invoke-WebRequest -Uri $TokenUrl -Headers $Headers -Body $Body -Method Post -UseBasicParsing -ErrorAction Stop
        # Parse the token response
        $Token = $Response.Content | ConvertFrom-Json
        # Return structured result
        return [PSCustomObject]@{
            Token        = $Token
            Expires      = [DateTime]::Now.AddSeconds($Token.expires_in)
            AuthCode     = $AuthCode
            CodeVerifier = $CodeVerifier
        }
    } catch {throw "OAuth token request failed: $($_.Exception.Message)"}
}
# ---------------------------------------------------------
# DATA FUNCTIONS
# ---------------------------------------------------------
#
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
                # Refresh the token if necessary
                if (!(Test-Token)) {
                    throw "Token not valid."
                }
                # Create the header
                $Headers = @{Authorization="Bearer $($Global:token.access_token)"; Accept="application/json"}
                # Invoke request
                $Response = Invoke-WebRequest -Uri $Url -WebSession $Session -Headers $Headers -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
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
            # Refresh the token if necessary
            if (!(Test-Token)) {
                throw "Token not valid."
            }
            # Start thread job
            Start-ThreadJob  -ScriptBlock $JobBlock  -ArgumentList $Batch,$global:API,$global:Source, $Global:Token | Out-Null
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
                    # Refresh the token if necessary
                    if (!(Test-Token)) {
                        throw "Token not valid."
                    }
                    # Restart SAME job block
                    Start-ThreadJob -ScriptBlock $JobBlock -ArgumentList $Batch,$global:API,$global:Source, $Global:Token | Out-Null
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
Clear-Host
# Announce start
Write-Host "Starting ESI Data Retrieval..." -ForegroundColor Green
# Authenticate and get OAuth token
$OAuth = Get-EveOAuthToken -ClientID $ClientID -Callback $Callback -Scopes $Scopes -State $State
# Store token and expiration globally for use in other functions. This allows the Test-Token function to access and
# refresh the token as needed
$Global:Token = $OAuth.Token
$Global:TokenExpires = $OAuth.Expires
#------------------------------------------
# Get the Structure List
#-------------------------------------------
# Create the hash for ID->Name match, Name is key, ID is Value
$Structures = @{}
# Get the list of Structure ID's from the API. This will be used to retrieve details for each structure in the next step.
# The API endpoint returns a list of structure IDs that we will iterate over.
$URL = "https://esi.evetech.net/$API/universe/structures/?datasource=$Source"
# Create a new websession
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
#
$StructureIDResult = Get-JsonFromUrl -Url $URL -Session $session -maxRetries 5 -delaySec 5
#
$StructureIDs = $StructureIDResult.json
#
# -----------------------------
# Batched structure job block
# -----------------------------
$StructureJobBlock = {
    param($Batch, $API, $Source, $Token)
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
    # Add Accept header
    $client.DefaultRequestHeaders.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new("application/json"))
    # Add Bearer token
    $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer",$Token.access_token)
    # Retry settings
    $maxTries  = 5
    $baseDelay = 500   # milliseconds
    # Process each structure ID
    foreach ($id in $Batch) {
        # Retry loop
        for ($try = 1; $try -le $maxTries; $try++) {
            # Try to get station details, with handling for ESI throttling and retries. We will attempt to get the
            # station details up to $maxTries times before giving up and logging an error.
            try {
                # API endpoint
                $url = "https://esi.evetech.net/$API/universe/structures/$id/?datasource=$Source"
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
                    SystemID = [int32]$R.solar_system_id
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
ForEach ($StructureID in $StructureIDs) {$Queue.Enqueue($StructureID)}
# -----------------------------
# Process the Queue
# -----------------------------
# Set the MaxJobs
$MaxJobs = 4
# Set the batch size
$BatchSize = [int]($StructureIDs.Count / $MaxJobs) + 1
if ($BatchSize -lt 100) {$BatchSize = 100}
# Call the Batch Processor and store the results
$Results = Invoke-URLBatchProcessor -Queue $Queue -JobBlock $StructureJobBlock -Activity "Fetching Structures" -MaxJobs $MaxJobs -BatchSize $BatchSize
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
    $Structures[$R.ID] = [ordered]@{
        ID   = $R.ID
        Name = $R.Name
        SystemID = $R.SystemID
    }
}
# -----------------------------
# Save the updated Stations data
# -----------------------------
$thisFile = $datafolder + '\Structures.csv'
Save-ToCsv -FilePath $thisFile -Data $Structures
