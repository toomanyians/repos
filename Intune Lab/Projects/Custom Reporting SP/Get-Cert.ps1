$params = @{
    Type = 'Custom'
    DnsName = 'ianbaxter.onmicrosoft.com' 
    CertStoreLocation = 'Cert:\CurrentUser\My'
    KeyExportPolicy = 'Exportable'
    KeySpec = 'Signature'
    Subject = 'CN=Data Collect'
    KeyUsage = "DigitalSignature" 
    KeyAlgorithm = 'RSA'
    KeyLength = 2048
    HashAlgorithm = 'SHA256'
    NotBefore = (Get-Date)
    NotAfter = (Get-Date).AddMonths(24)
    }
#
# Create the Self-Signed Certificate
New-SelfSignedCertificate @params
# Locate and load the certificate we just created
$cert = Get-ChildItem -Path "Cert:\CurrentUser\My" | Where-Object {$_.Subject -Match "Data Collect"} 
# Get thumbprint
$thumbprint = ($cert | Select-Object Thumbprint, FriendlyName).Thumbprint
#
# Export the Public Key (.CER)
Export-Certificate -Cert $cert -FilePath "$env:USERPROFILE\Documents\Data_Collect.cer"
#
# Create the password we need for the Private Key
# Enter password here
$MyPassword = "SomePassword"
$mypwd = ConvertTo-SecureString -String $MyPassword -Force -AsPlainText
#
# Export the Private Key (.PFX)
Export-PfxCertificate -Cert $cert -FilePath "$env:USERPROFILE\Documents\Data_Collect.pfx" -Password $mypwd
#
# Delete by ThumbPrint
Remove-Item -Path "Cert:\CurrentUser\My\$thumbprint" -DeleteKey

