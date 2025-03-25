Set-StrictMode -Version 3.0;

filter Set-cbtS3SecurityInformation {
	param (
		[Parameter(Mandatory)]
		[string]$Region,
		[Parameter(Mandatory)]
		[PSCredential]$SecretAndKeyAsCredentials,
		[switch]$Overwrite = $false
	);
	
	if (Test-S3SecurityInfoSet) {
		if (-not $Overwrite) {
			throw "S3SecurityInformation has ALREADY been set. Use the -Overwrite switch to force a replacement.";
		}
	}
	
	Initialize-AWSDefaultConfiguration -Region $Region -AccessKey ($SecretAndKeyAsCredentials.UserName) -SecretKey ($SecretAndKeyAsCredentials.GetNetworkCredential().Password);
}

Export-ModuleMember -Function Set-cbtS3SecurityInformation;