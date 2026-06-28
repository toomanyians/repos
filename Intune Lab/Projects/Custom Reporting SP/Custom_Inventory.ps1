#
# BEGIN CONFIGURATION
#
# Modules
Add-Type -AssemblyName System.Web
#
# Service Principal Data (Required for Token)
$ApplicationID = "f68fd352-af49-4987-8868-21ca40ee352e"
$TenantID = "0d6451ad-114c-4d3a-ae83-93e99688a435"
$CertName = "Data Collect"
#
# Log Analytics Data (for JSON submission)
$DcrImmutableId = "" # id available in DCR > JSON view > immutableId
$DceURI = "" # available in DCE > Logs Ingestion value
$Table = "CustomInventory_CL" # custom log to create
#
# Script logging
$LogFile = ""
#
# BEGIN FUNCTIONS
#
# ToBase64Url - Takes a custom PSObject, converts it to JSON, ensures UTF-8 encoding,
# then coverts that to a Base64 encoded string and then URLEncodes it.
# Parameter(s):
#  object - The PSObject to convert
# Return(s):
#  The coverted object in JSON format
#
function ToBase64Url {
    param ([Parameter(Mandatory = $true)] $object)
    # Convert the PSObject to JSON
    $json = ConvertTo-Json $object -Compress
    # Turn that into an array of bytes representing the UFT-encoding of the JSON
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    # Convert that into Base64 encoding
    $base64 = [Convert]::ToBase64String($bytes)
    # URL encode the result
    $base64Url = $base64 -replace '\+', '-' -replace '/', '_' -replace '='
    # Send that back tot he caller
    return $base64Url
}
#
# Get-AuthTokenWithCert - Takes the necessary information to obtain an OAUTH2 token from Azure based
# on an App Registration and a client certificate and either returns the token or an error message.
# Parameter(s):
#  TenantId - A unique identifier assinged to every AzureAD tenant.
#  ClientId - Also known as an Apolication ID, uniquely identifies the App Registration in the Tenant.
#  CertThumbprint - A unique identifier for the certificate we are going to use.
# Return(s):
#  An access token or error message.
#
function Get-AuthTokenWithCert {
    param ([Parameter(Mandatory = $true)] [string]$TenantId, [Parameter(Mandatory = $true)] [string]$ClientId,
        [Parameter(Mandatory = $true)] [string]$CertThumbprint )
    try {
        # Read the certificate from the Local Machine keystore.
        $cert = Get-ChildItem -Path Cert:\LocalMachine\My\$CertThumbprint
        # Throw an error if it doesn't exist
        if (-not $cert) {throw "Certificate with thumbprint '$CertThumbprint' not found."}
        # Get the RSA Private Key.
        $privateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        # Thow an error if it's not present and reaadable
        if (-not $privateKey) { throw "Unable to Get Certificate Private Key."}
        # Time based data for the payload
        $now = [DateTime]::UtcNow
        $exp = $now.AddMinutes(10)
        $epoch = [datetime]'1970-01-01T00:00:00Z'
        # Create a new GUID for the payload
        $jti = [guid]::NewGuid().ToString()
        # Create the payload
        $jwtPayload = @{
            aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
            iss = $ClientId
            sub = $ClientId
            jti = $jti
            nbf = [int]($now - $epoch).TotalSeconds
            exp = [int]($exp - $epoch).TotalSeconds
        }
        # Convert to Base64, URL encoded
        $payload = ToBase64Url -object $jwtPayload
        # Populate the header
        $jwtHeader = @{alg = "RS256"; typ = "JWT"; x5t = [System.Convert]::ToBase64String($cert.GetCertHash())}
        # Convert to Base64, URL encoded
        $header = ToBase64Url -object $jwtHeader
        # Concatenate the Header and Payload with a dot
        $jwtToSign = "$header.$payload" 
        # Hash the JWT to create a byte encoded signature
        $bytesToSign = [System.Text.Encoding]::UTF8.GetBytes($jwtToSign)
        # Encode the signature in SHA256
        $signatureBytes = $privatekey.SignData(
            $bytesToSign,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
        # Convert the signature to Base64 Url encoded format
        $signature = [Convert]::ToBase64String($signatureBytes) -replace '\+', '-' -replace '/', '_' -replace '=' 
        # Concatednate the JWT request and the Signature
        $clientAssertion = "$jwtToSign.$signature" 
        # Create the body for the request including the Client Assertion
        $body = @{ 
            client_id = $ClientId
            scope = "https://monitor.azure.com//.default"
            client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
            client_assertion = $clientAssertion
            grant_type = "client_credentials"
        }
        # Request the token
        $response = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -ContentType "application/x-www-form-urlencoded" -Body $body
        # Send the access token back to the caller
        return $response.access_token
    } catch { return "Failed to get token: $Error"}
}
#
# write-log - Basic logging function, only works when LogFile is populated.
# Parameter(s):
#  LogFile - The full path of the file you wish to create.
#  Message - The message to wite with a timestamp
#
function Write-Log {
    param ([Parameter(Mandatory = $false)] [string]$LogFile,[Parameter(Mandatory = $true)] [string]$Message)
    # If a Log filename has been specified
    if ($LogFile.Length -gt 0) {
        # Make sure we write in UTF-8
        $encoding = New-Object System.Text.UTF8Encoding($false)
        # Open or create the file for appending
        $writer = New-Object System.IO.StreamWriter($LogFile, $true, $encoding)
        # Write the message
        try {
            # Get the timestamp
            $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            # write the timestamp, a tab and the message
            $writer.WriteLine("$timestamp`t$Message")
        } finally {$writer.Close()}
    }
}


function Get-ValidCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CertName
    )

    $now = Get-Date

    foreach ($cert in Get-ChildItem -Path Cert:\LocalMachine\My) {
        if ($cert.Subject -like "*$CertName*" -and
            $cert.NotBefore -le $now -and
            $cert.NotAfter  -ge $now) {

            return $cert
        }
    }

    return $null
}
#
# BEGIN SCRIPT
#
#
# Get the first valid certificate that matches $CertName
$cert = Get-ValidCertificate -CertName $CertName
# If one was found
if ($cert) {
    # Get the thumbprint
    $thumbprint = (Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object {$_.Subject -Match $CertName}).Thumbprint
    #
    # BEGIN INVENTORY
    #
    #
    #
    # Get the ManagedDeviceID and Name from Intune enrollment
    try {
        # If the device is enrolled
        if (@(Get-ChildItem HKLM:SOFTWARE\Microsoft\Enrollments\ -Recurse | Where-Object { $_.PSChildName -eq 'MS DM Server' })) {
            # Get the source for the managed device information
            $MSDMServerInfo = Get-ChildItem HKLM:SOFTWARE\Microsoft\Enrollments\ -Recurse | Where-Object { $_.PSChildName -eq 'MS DM Server' }
            $ManagedDeviceInfo = Get-ItemProperty -LiteralPath "Registry::$($MSDMServerInfo)"
        } else {
            Write-Log -LogFile $LogFile -Message "Device has not been enrolled."
        }
        # Get Intune DeviceID and ManagedDeviceName from the registry or nhulls if not
        $ManagedDeviceName = $ManagedDeviceInfo.EntDeviceName
        $ManagedDeviceID = $ManagedDeviceInfo.EntDMID
    } catch {
        # Form the message
        $Message = "Error reading enrollment data: "+ $Error
        # Write the message
        Write-Log -LogFile $LogFile -Message $Message
        # Clear the error
        $error.clear()
    }
    #
    # Get the AzureADDeviceID from Azure client certificate
    try {
	    # Define Cloud Domain Join information registry path
	    $AzureADJoinInfoRegistryKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo"
	    # Retrieve the child key name that is the thumbprint of the machine certificate containing the device identifier guid
	    $AzureADJoinInfoThumbprint = Get-ChildItem -Path $AzureADJoinInfoRegistryKeyPath | Select-Object -ExpandProperty "PSChildName"
        
	    if ($AzureADJoinInfoThumbprint -ne $null) {
		    # Retrieve the machine certificate based on thumbprint from the registry
		    $AzureADJoinCertificate = Get-ChildItem -Path "Cert:\LocalMachine\My" -Recurse | Where-Object { $PSItem.Thumbprint -eq $AzureADJoinInfoThumbprint }
		    if ($AzureADJoinCertificate -ne $null) {
			    # Determine the device identifier from the subject name
			    $AzureADDeviceID = ($AzureADJoinCertificate | Select-Object -ExpandProperty "Subject") -replace "CN=", ""
		    }
	    } else {
            Write-Log -LogFile $LogFile -Message "Azure client certificate not found."
        }
    } catch {
        # Form the message
        $Message = "Error reading Azure client certificate: "+ $Error
        # Write the message
        Write-Log -LogFile $LogFile -Message $Message
        # Clear the error
        $error.clear()
    }
    #
    # Antivirus - Hardware info in Intune runs every 7 days, we need reporting more often.
    # Key Compliance Indicators:
    #   Service Start
    #   Service State
    #   AntispywareSignatureAge (Days) -
    #   NISSignatureAge (Days) - 
    #   AntivirusSignatureAge
    #   AMEngineVersion
    try {
        # Query the service
        $DefSvc = Get-Service -name WinDefend
        # Get the data we need to report
        switch ([int]$DefSvc.Status) {
            1 {$Defender_State = "Stopped"}
            2 {$Defender_State = "StartPending"}
            3 {$Defender_State = "StopPending"}
            4 {$Defender_State = "Running"}
            5 {$Defender_State = "ContinuePending"}
            6 {$Defender_State = "PausePending"}
            7 {$Defender_State = "Paused"}
        }
        # Get the data we need to report
        switch ([int]$DefSvc.StartType) {
            0 {$Defender_Start = "Boot"}
            1 {$Defender_Start = "System"}
            2 {$Defender_Start = "Automatic"}
            3 {$Defender_Start = "Manual"}
            4 {$Defender_Start = "Disabled"}
        }
    } catch {
        # Form the message
        $Message = "Error reading Defender service data: "+ $Error
        # Write the message
        Write-Log -LogFile $LogFile -Message $Message
        # Clear the error
        $error.clear()
    }
    try {
        # Query WMI Data
        $DefWMI = Get-CimInstance -ClassName MSFT_MpComputerStatus -Namespace root/microsoft/windows/defender -Property *
        # Get the data we need to report
        $Defender_SpySigAge = $DefWMI.AntispywareSignatureAge
        $Defender_NisSigAge = $DefWMI.NISSignatureAge
        $Defender_AVSigAge = $DefWMI.AntivirusSignatureAge
        $Defender_AMEgine = $DefWMI.AMEngineVersion
    } catch {
        # Form the message
        $Message = "Error reading Defender WMI data: "+ $Error
        # Write the message
        Write-Log -LogFile $LogFile -Message $Message
        # Clear the error
        $error.clear()
    }
    #
    # Bitlocker - Hardware info in Intune runs every 7 days, we need reporting more often.
    # Key Compliance Indicators:
    #   Service Start
    #   Service Status
    #   Device Encryption
    #   Device Protection Status
    #   Device Protector
    #   Encryption Algorithm
    try {
        # Query the service
        $BitSvc = Get-Service -name WinDefend
        # Get the data we need to report
        switch ([int]$BitSvc.Status) {
            1 {$Bitlocker_State = "Stopped"}
            2 {$Bitlocker_State = "StartPending"}
            3 {$Bitlocker_State = "StopPending"}
            4 {$Bitlocker_State = "Running"}
            5 {$Bitlocker_State = "ContinuePending"}
            6 {$Bitlocker_State = "PausePending"}
            7 {$Bitlocker_State = "Paused"}
        }
        # Get the data we need to report
        switch ([int]$BitSvc.StartType) {
            0 {$Bitlocker_Start = "Boot"}
            1 {$Bitlocker_Start = "System"}
            2 {$Bitlocker_Start = "Automatic"}
            3 {$Bitlocker_Start = "Manual"}
            4 {$Bitlocker_Start = "Disabled"}
        }
    } catch {
        # Form the message
        $Message = "Error reading Bitlocker service data: "+ $Error
        # Write the message
        Write-Log -LogFile $LogFile -Message $Message
        # Clear the error
        $error.clear()
    }
    try {
        # Query WMI Data
        $BitWMI = Get-CimInstance -Namespace "Root\CIMV2\Security\MicrosoftVolumeEncryption" -Class Win32_EncryptableVolume -Property * | Sort-Object DriveLetter
        # Get the data we need to report
        # Encryption status for every drive
        $BitEncrypted = $null
        foreach ($thisDrive in $BitWMI) {
            $DriveLetter = $thisDrive.DriveLetter
            switch ([int]$thisDrive.GetConversionStatus) {
                0 {$Status = "FullyDecrypted"}
                1 {$Status = "FullyEncrypted"}
                2 {$Status = "EncryptionInProgress"}
                3 {$Status = "DecryptionInProgress"}
                4 {$Status = "EncryptionPaused"}
                5 {$Status = "DecryptionPaused"}
            }        
            if ($BitEncrypted) {$BitEncrypted += ";$DriveLetter$Status"} else {$BitEncrypted = "$DriveLetter$Status"}        
        }
        # Encryption Algorithm for each drive
        $BitEncryption = $null
        foreach ($thisDrive in $BitWMI) {
            $DriveLetter = $thisDrive.DriveLetter
            switch ([int]$thisDrive.GetProtectionStatus) {
                0 {$Status = "None"}
                1 {$Status = "AES_128_WITH_DIFFUSER"}
                2 {$Status = "AES_256_WITH_DIFFUSER"}
                3 {$Status = "AES_128"}
                4 {$Status = "AES_256"}
                5 {$Status = "HARDWARE_ENCRYPTION"}
                6 {$Status = "XTS_AES_128"}
                7 {$Status = "XTS_AES_256"}
            }        
            if ($BitEncryption) {$BitEncryption += ";$DriveLetter$Status"} else {$BitEncryption = "$DriveLetter$Status"}        
        }
        # Protection status for each drive
        $BitProtected = $null
        foreach ($thisDrive in $BitWMI) {
            $DriveLetter = $thisDrive.DriveLetter
            switch ([int]$thisDrive.GetProtectionStatus) {
                0 {$Status = "Unprotected"}
                1 {$Status = "Protected"}
                2 {$Status = "Unknown"}
            }        
            if ($BitProtected) {$BitProtected += ";$DriveLetter$Status"} else {$BitProtected = "$DriveLetter$Status"}        
        }
        # Protector for each drive
        $BitProtector = $null
        foreach ($thisDrive in $BitWMI) {
            $DriveLetter = $thisDrive.DriveLetter
            switch ([int]$thisDrive.GetProtectionStatus) {
                0 {$Status = "Unknown"}
                1 {$Status = "TPM"}
                2 {$Status = "External key"}
                3 {$Status = "Numerical password"}
                4 {$Status = "TPM and PIN"}
                5 {$Status = "TPM and Startup key"}
                6 {$Status = "TPM and PIN and Startup key"}
                7 {$Status = "Public key"}
                8 {$Status = "Passphrase"}
                9 {$Status = "TPM Certificate"}
                10 {$Status = "CNG protector"}
            }        
            if ($BitProtector) {$BitProtector += ";$DriveLetter$Status"} else {$BitProtector = "$DriveLetter$Status"}        
        }
    } catch {
        # Form the message
        $Message = "Error reading Bitlocker WMI data: "+ $Error
        # Write the message
        Write-Log -LogFile $LogFile -Message $Message
        # Clear the error
        $error.clear()
    }
    #
    # Physical device Mac Addresses
    # Key Compliance Indicators:
    # We just need the Description and Mac Address seperated by a pipe character for the
    # first 6 listed adapters
    try {
    # Perform the WMI query and filter for physical adapters with Mac Addresses
        $NetAdapters = Get-CimInstance Win32_NetworkAdapter -Property * |
        Where-Object {
            $_.PhysicalAdapter -eq $true -and
            $_.PNPDeviceID -ne $null -and
            ($_.AdapterTypeID -eq 0 -or $_.AdapterTypeID -eq 9) -and
            $_.MACAddress -ne $null
        }
        # Use a hash to hold the data
        $hashCtr = 0
        $NetHash = @{}
        # Iterate through all the adapters
        foreach ($adapter in $NetAdapters) {
            if ($hashCtr -le 5) {
                $datarow = $adapter.Name +"|" + $adapter.MACAddress
                $NetHash[$hashCtr] = $datarow
            }
            # Increment the hash counter
            $hashCtr++
        }
        # Fill in the blanks
        while ($hashCtr -le 5) {
            $NetHash[$hashCtr] = ""
            $hashCtr++
        }
    } catch {
        # Form the message
        $Message = "Error reading NetworkAdapter WMI data: "+ $Error
        # Write the message
        Write-Log -LogFile $LogFile -Message $Message
        # Clear the error
        $error.clear()
    }
    #
	# Compile all the settings in a form we can easily convert to JSON
	$Inventory = New-Object System.Object
	$Inventory | Add-Member -MemberType NoteProperty -Name "ManagedDeviceName" -Value $ManagedDeviceName -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "AzureADDeviceID" -Value $AzureADDeviceID -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "ManagedDeviceID" -Value $ManagedDeviceID -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "DefenderState" -Value $Defender_State -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "DefenderStart" -Value $Defender_Start -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "DefSpySigAge" -Value $Defender_SpySigAge -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "DefNisSigAge" -Value $Defender_NisSigAge -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "DefAVSigAge" -Value $Defender_AVSigAge -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "DefAMEngine" -Value $Defender_AMEgine -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "BitlockerState" -Value $Bitlocker_State -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "BitlockerStart" -Value $Bitlocker_Start -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "BitEncrypted" -Value $BitEncrypted -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "BitEncryption" -Value $BitEncryption -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "BitProtected" -Value $BitProtected -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "BitProtector" -Value $BitProtector -Force
    foreach ($thiskey in ($NetHash.Keys | Sort-Object)) {
        $Name = "MAC" + $thiskey.ToString()
        $Value = $NetHash[$thiskey]
    	$Inventory | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
    #
    # Convert to JSON for sending the data to Log Analytics Workspace
    $body = $Inventory | ConvertTo-Json
    #
    # END INVENTORY
    #
    #
    # UnComment for DEBUGGING
    $body
    # We may need the entire JSON for debugging
    $Message = "JSON : " + $body
    Write-Log -LogFile $LogFile -Message $Message
    #
    # Get the auth token
    $bearerToken = Get-AuthTokenWithCert -TenantId $TenantID -ClientId $ApplicationID -CertThumbprint $thumbprint
    #
    # UnComment for DEBUGGING
    $bearerToken
    # Don't save the whole token to the log, just enough to know we got it
    $Message = "Token : " + $bearerToken.Substring(0, [Math]::Min(40, $bearerToken.Length))
    Write-Log -LogFile $LogFile -Message $Message
    #
    # Send the JSON to the Log Analytics Data Ingestion API
    $headers = @{"Authorization" = "Bearer $bearerToken"; "Content-Type" = "application/json" }
    $uri = "$DceURI/dataCollectionRules/$DcrImmutableId/streams/Custom-$Table"+"?api-version=2023-01-01"
    $uploadResponse = Invoke-RestMethod -Uri $uri -Method "Post" -Body $body -Headers $headers
    # Report back status
    $date = Get-Date -Format "dd-MM HH:mm"
    $OutputMessage = "InventoryDate:$date "
    # Append Success or Fail to the Output Message
    if ($uploadResponse -match "200 :") {$OutputMessage += "DeviceInventory:OK " + $uploadResponse} else {$OutputMessage += "DeviceInventory:Fail " + $uploadResponse}
} else {
    # Report back status
    $date = Get-Date -Format "dd-MM HH:mm"
    $OutputMessage = "InventoryDate:$date "
    $OutputMessage += "DeviceInventory:Fail No certificate."
}
Write-Output $OutputMessage
Exit 0