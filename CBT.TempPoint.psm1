Set-StrictMode -Version 3.0;

<# 
	NOTES / SCOPE: 
		S3, B2 and other 'prefixes' can/should exist. 
		BUT, I'm going to use -CloudProvider or something similar to direct WHICH of these is responsible for getting stuff. 
			which, yeah... means abstraction of the 'fetch' (i.e., get details) and 'copy' (download) operations for each provider. 

		Likewise, paths... will assume/use providers. 

	ROADMAP: 
		More or less an extension of the above: 
			- 0.3.0 - Bare-Bones Implementation. 
				- Manifests						- DONE. 
				- Manifest Testing (RPO checks) - DONE. 
				- PATHs (providers/funcs) 		- PENDING. 
				- DOWNLOADS	(S3 Only and hard-coded) - PENDING
				
			- 0.4.0 - 'Cloud Providers' - i.e., abstractions for different providers - enumerate/find files, get timestamps and other details, download/synchronize with local. 
				- i.e., time to replace HARD-CODED S3 logic with: 
					- options for authentication. 
					- extensible 'providers' (i.e., abstraction). 
					- MAKE SURE to START with support for both: 
						- S3
						- WindowFileSystem - i.e., no reason to NOT treat it like a 'cloud'. 
							as, then, I can 'test' and/or restore from a UNC share/etc.
#>

# ===========================================================================================================
# Providers (Defaults and Validation):
# ===========================================================================================================
# MKC: BUG/PROBLEM. No Idea what I'm doing wrong here - in terms of scope. 
# 		but these 'variables' are 10000000% just NOT visible to Build-cbtBackupsFileManifest UNLESS they're declared globally here. 
[ScriptBlock]$global:cbt_s4Get_DateTimeFromFileName = {
	param (
		[string]$FileName,
		[string]$DatabaseName
	);
	
	try {
		$parts = $FileName -Split "_";
		$hour = $parts[6].Substring(0, 2);
		$minute = $parts[6].Substring(2, 2);
		$second = $parts[6].Substring(4, 2);
		$millisecond = $parts[7].Substring(0, 3);
		
		return New-Object System.DateTime($parts[3], $parts[4], $parts[5], $hour, $minute, $second, $millisecond);
	}
	catch {
		# MKC: no... don't handle this here ... handle it in the part of the code that runs this extraction - i.e., where this 'delegate/interface' is run. 
		# 		that way I can keep errors fairly standard. 
		throw "DateTime Extraction From File Error... "
	}
}

[ScriptBlock]$global:cbt_s4Get_StripeNumberFromFileName = {
	param (
		[string]$FileName,
		[string]$DatabaseName
	);
	
	# place-holder for now. 
	# i.e., not yet implemented. 
	
	return 0; # or -1? 
}

# MKC: Both of these funcs/ScriptBlocks are a LIE. They specify a list of $MatchingDatabases - but those are NEVER used within the func itself... (once it is created)
# 	instead, those matches are 1) EXTRACTED (dynamically), 2) shoved into a hashtable, and 3) then used for 'routing' by logic below. 
# 	ARGUABLY, COULD require users to pass in a compound object - an array of (Databases + ScriptBlock) that would do this same thing. 
# 		but, seems a bit more EASY for devs/consumers of this to specify specific DBs and the logic they expect - in one 'tidy' definition. 
# 		i.e., this LIES because it's easier for consumers.  That results in some contortion within the module .. but, meh. 

# NOTE: 3x allowable tokens: USER (master, tempdb, msdb, model), USER: anything OTHER than SYSTEM, ALL = anything/everything.
# TODO: maybe some sort of switch / $prefs something that lets us treat admindb as a systemdb? ah... and/or something that lets us a) modify SYSTEM (add/remove?) and/or, b) something that lets us create other 'collections'/tokens
[ScriptBlock]$global:cbt_s4Get_SystemPaths = {
	param (
		[string[]]$MatchingDatabases = "{SYSTEM}",
		[string]$PathPrefix,
		[string]$Database,
		[string]$Type
	);
	
	$output = $PathPrefix + "/$Database/$($Type.ToUpperInvariant())";
	return $output;
}

[ScriptBlock]$global:cbt_s4Get_UserPaths = {
	param (
		[string[]]$MatchingDatabases = "{USER}",
		[string]$PathPrefix,
		[string]$Database,
		[string]$Type
	);
	
	$output = $PathPrefix + "/$Database/$($Type.ToUpperInvariant())";
	return $output;
}

[ScriptBlock[]]$global:cbt_s4Get_PathProviders = @($global:cbt_s4Get_SystemPaths, $global:cbt_s4Get_UserPaths);

# ===========================================================================================================
# Public:
# ===========================================================================================================
function Build-cbtBackupsFileManifest {
	param (
		[Parameter(Mandatory)]
		[string]$BucketName,
		[string]$PathPrefix = "",   # TODO: might need some sort of @{} (dictionary) of path prefixes - for situations where FULL|DIFF|LOG files are kept in different buckets.
		[Parameter(Mandatory)]
		[string]$Database,
		[DateTime]$StopAt = [DateTime]::MinValue, # When $StopAt is a) specified, and b) 'farther back' than most RECENT FULL/DIFF backups, this'll grab most recent files from BEFORE $StopAt
		[ScriptBlock]$TimeExtractor = $global:cbt_s4Get_DateTimeFromFileName,
		[ScriptBlock]$StripeExtractor = $global:cbt_s4Get_StripeNumberFromFileName,
		[ScriptBlock[]]$PathTranslators = $global:cbt_s4Get_PathProviders
	);
	
	begin {
		if (-not (Test-cbtSecurityInfoIsSet)) {
			throw "Security Credentials have NOT been set. Use 'Set-cbtS3SecurityInformation' before proceeding.";
		}
		
		#TODO: validate the 'interfaces' of the $TimeExtractor and $StripeExtractor - i.e. make sure
		# 		they both accepts the same 2x params: fileName, dbName. 
		Define-PathProviderRouting -Providers $PathTranslators;
		
		New-Item -Path function:Provider-GetDateTimeFromFileName -Value ($TimeExtractor.ToString()) -Force;
		New-Item -Path function:Provider-GetStripeFromFileName -Value ($StripeExtractor.ToString()) -Force;
		
		filter Get-FileDetailsByPath {
			param (
				[ValidateSet("FULL", "DIFF", "LOG")]
				[string]$Type,
				[DateTime]$Predecessor = [DateTime]::MinValue # i.e., previous file in the restore-chain (DIFF or FULL)
			);
			
			# Path Normalization:
			if ($PathPrefix.EndsWith('/')) {
				$PathPrefix = $PathPrefix.Substring(0, $PathPrefix.Length - 1);
			}
			
			#$path = $PathPrefix + "/$Database/$($Type.ToUpperInvariant())";
			$path = Get-ProviderTranslatedPath -Prefix $PathPrefix -Database $Database -Type $Type;
			
			[PSCustomObject[]]$fileDetails = @();
			$objects = Get-S3Object -BucketName $BucketName -Prefix $path;
			foreach ($object in $Objects) {
				[string]$fileName = ($object.Key -split "/") | Select-Object -Last 1;
				
				try{
					[System.DateTime]$timestamp = Provider-GetDateTimeFromFileName -FileName $fileName -DatabaseName $Database;
				}
				catch {
					throw;
				}
				
				try {
					[int]$stripe = Provider-GetStripeFromFileName -FileName $fileName -DatabaseName $Database;
				}
				catch {
					throw;
				}
				
				[PSCustomObject]$fileDetail = [PSCustomObject]@{
					BackupType = $Type.ToUpperInvariant()
					Stripe	   = $stripe
					TimeStamp  = $timestamp
					FileName   = $fileName
					FullPath   = $object.Key
					Size 	   = $object.Size
				};
				
				$fileDetails += $fileDetail;
			}
			Write-Verbose "Count of [$Type] Backup-Files found: $($fileDetails.Count).";
			
			if ($fileDetails.Count -lt 1) {
				Write-Verbose "No matching [$Type] files found for database [$Database].";
				return $null;
			}
			
			if ($StopAt -ne [DateTime]::MinValue) {
				$fileDetails = $fileDetails | Where-Object {
					$_.TimeStamp -le $StopAt
				}
				
				if ($fileDetails.Count -lt 1) {
					Write-Verbose "No matching [$Type] files found for database [$Database] -after removing files greater-than -StopAt.";
					return $null;
				}
			}
			
			switch ($Type) {
				'FULL' {
					return $fileDetails | Sort-Object -Property TimeStamp | Select-Object -Last 1;
				}
				'DIFF' {
					return $fileDetails | Where-Object { $_.TimeStamp -gt $Predecessor } |  Sort-Object -Property TimeStamp | Select-Object -Last 1;
				}
				'LOG' {
					return $fileDetails | Where-Object { $_.TimeStamp -gt $Predecessor } | Sort-Object -Property TimeStamp;
				}
			}
		}
		
		[PSCustomObject]$manifest = [PSCustomObject]@{
			PSTypeName = "CloudFilesManifest"
			BucketName = $BucketName
			Database = $Database
			Files = @()
		};
	}
	
	process {
		$full = Get-FileDetailsByPath -Type 'FULL';
		if ($null -eq $full) {
			throw "No Full-Backups found for Database [$Database] in Bucket [$BucketName] at Prefix: [$PathPrefix]. Can NOT continue building a Recovery-Manifest.";
		}
		
		Write-Verbose "Starting Manifest with FULL Backup: [$($full.FullPath)].";
		
		$manifest.Files += $full;
		$predecessor = $full.TimeStamp;
		
		$diff = Get-FileDetailsByPath -Type 'DIFF' -Predecessor $predecessor;
		if ($null -ne $diff) {
			$predecessor = $diff.TimeStamp;
			$manifest.Files += $diff;
		}
		
		$manifest.Files += Get-FileDetailsByPath -Type 'LOG' -Predecessor $predecessor;
	}
	
	end {
		return $manifest;
	}
}

function Copy-cbtBackupFilesLocally {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[PSCustomObject]$Manifest,
		[DateTime]$StopAt = [DateTime]::MinValue,			# ONLY exists for hand-off to RESTORE operations... 
		[string]$TargetDirectory, # hmm. do i need any kind of pattern thingy here? 
		# TODO: Set up option for these if/as needed (which'll supersede the locally defined creds)
		#$S3ArnRoleCredentials 
		[switch]$Force = $false  		# When TRUE, will re-download files if/when they're already present (path exists and file sizes are the same)
	);
	
	begin {
		if (-not (Test-cbtSecurityInfoIsSet)) {
			throw "Security Credentials have NOT been set. Use 'Set-cbtSecurityInformation' before proceeding.";
		}
		
		if ($TargetDirectory.EndsWith('\')) {
			$TargetDirectory = $TargetDirectory.Substring(0, $TargetDirectory.Length - 1);
		}
		
		if (-not (Test-Path $TargetDirectory)) {
			throw "Target Directory [$TargetDirectory] does NOT exist.";
		}
		
		filter Copy-FileToLocal {
			param (
				[PSCustomObject]$File
			);
			
			try {
				$targetPath = "$TargetDirectory\$($Manifest.Database)\$($File.FileName)";
				
				if (-not $Force) {
					$localFile = Get-ChildItem $targetPath -ErrorAction SilentlyContinue;
					if ($null -ne $localFile) {
						if ($localFile.Length -eq $File.Size) {
							Write-Verbose "File [$($File.FileName)] already exists locally - and has same file-length ([$($File.Size)]) as cloud file. Skipping Download.";
							return;
						}
					}
				}
				
				Read-S3Object -BucketName ($Manifest.BucketName) -Key $File.FullPath -File $targetPath | Out-Null;
			}
			catch {
				throw;
			}
		}
		
		$progressPref = $global:ProgressPreference;  # gets reset to this value in end{}
	};
	
	process {
		$global:ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue;
		
		# NOTE: if there's NOT a FULL (or DIFF) backup - that's fine, we MIGHT be 'topping up' (synchronizing) additional backups/etc. 
		$full = $Manifest.Files | Where-Object { $_.BackupType -eq 'FULL'	} | Select-Object -First 1;
		if ($null -ne $full) {
			Copy-FileToLocal -File $full;
		}
		# TODO: OPTION to initiate/kick-off RESTORE operation. (This'd HAVE to be done via START of an MSDB JOB - so that this is asynchronous.)
		
		$diff = $Manifest.Files | Where-Object { $_.BackupType -eq 'DIFF'	} | Select-Object -First 1;
		if ($null -ne $diff) {
			Copy-FileToLocal -File $diff;
		}
		# TODO: OPTION to 'apply' (which is a bit complicated.)
		# 		So. There are 2 main options for the ability to kick-off RESTORE operations here. 
		# 		a) WAIT UNTIL we get to a DIFF (if there is/was one - i.e., BEFORE we start on LOGs). And then just restore FULL + DIFF (if there was one). 		
		# 		b) TWEAK admindb/S4's dbo.restore_databases. KEEP the OPTION to 'REPLACE', default that to 'THROW', and provide a new option for 'APPLY'... 
		# 			and then change the name of the variable. Idea then becomes that dbo.restore_databases CAN 'pick up' from a previous RESTORE and attempt
		# 			to simply apply a DIFF, then LOGs, or JUST logs (though... that's starting to be a hell of an overlap on/against dbo.apply_logs)
		# 				ah. woah. maybe dbo.restore_databases calls into dbo.apply_logs once we get to logs? 
		
		foreach ($logBackup in $Manifest.Files | Where-Object { $_.BackupType -eq 'LOG'	} | Sort-Object { $_.TimeStamp }) {
			Copy-FileToLocal -File $logBackup;
		}
	};
	
	end {
		$global:ProgressPreference = $progressPref;
	};
}

# TODO: MIGHT make sense to add a -PassThru here ... (just not sure how i'd differentiate that from the @results collection... )
function Compare-cbtManifestAgainstLocalFiles {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[PSCustomObject]$Manifest,
		[string]$TargetDirectory,
		[switch]$ShowMatches = $false    # by default, only show missing or different.
	);
	
	begin {
		if ($TargetDirectory.EndsWith('\')) {
			$TargetDirectory = $TargetDirectory.Substring(0, $TargetDirectory.Length - 1);
		}
		
		if (-not (Test-Path $TargetDirectory)) {
			throw "Target Directory [$TargetDirectory] does NOT exist.";
		}
		
		$results = @();
	};
	
	process {
		foreach ($manifestFile in $Manifest.Files) {
			
			# TODO: create an internal func/filter to return file-size (KB/MB/GB) based on overall SIZE of the file. e.g., a 222GB file shouldn't be reporting size as KB or MB... but as GB'
			# 				likewise, no sense reporting on a 220KB log file in terms of GBs... 
			
			$targetPath = "$TargetDirectory\$($Manifest.Database)\$($manifestFile.FileName)";
			$localFile = Get-ChildItem $targetPath -ErrorAction SilentlyContinue;
			if ($null -ne $localFile) {
				if ($localFile.Length -eq $manifestFile.Size) {
					if ($ShowMatches) {
						$results += @{
							Static	= "Cloud and Local Files are Identical"
							File	= "$($manifestFile.FileName). Size: ($($manifestFile.Size / 1MB)MB).";
						}
					}
				}
				else {
					$results += @{
						Status	= "Different-File-Sizes"
						File	= "$($manifestFile.FileName). Cloud: ($($manifestFile.Size / 1MB)MB) - Local: ($($localFile.Length / 1MB)).";
					}
				}
			}
			else {
				$results += @{
					Status	= "Cloud-Only"
					File	= "$($manifestFile.FileName). Size: ($($manifestFile.Size / 1MB)MB)";
				}
			}
		}
	};
	
	end {
		
		# this needs better factors (i.e., probably custom formatting):
		if ($results.Count -lt 1) {
			Write-Host "Manifest and Local Files are IDENTICAL.";
		}
		
		return $results;
	};
}

function Set-cbtSecurityInformation {
	param (
		[Parameter(Mandatory)]
		[string]$Region,
		[Parameter(Mandatory)]
		[PSCredential]$SecretAndKeyAsCredentials,
		[switch]$Overwrite = $false
	);
	
	if (Test-cbtSecurityInfoIsSet) {
		if (-not $Overwrite) {
			throw "S3SecurityInformation has ALREADY been set. Use the -Overwrite switch to force a replacement.";
		}
	}
	
	Initialize-AWSDefaultConfiguration -Region $Region -AccessKey ($SecretAndKeyAsCredentials.UserName) -SecretKey ($SecretAndKeyAsCredentials.GetNetworkCredential().Password);
}

# NOTE: I should NOT need to pass in ANY transformers/funcs for extraction of timestamp or type into this func. that 'stuff' should have already been handled via Build-cbtS3BackupsManifest
function Test-cbtBackupsCoverage {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[PSCustomObject]$Manifest,
		[int]$RpoSeconds = 660,
		[switch]$SkipDiffBackups = $true # Arguably, we're NOT just looking to see if we can recover without RPO violations; we're looking to see if there are ANY RPO violations within the backup chain. 
	);
	
	begin {
		
	};
	
	process {
		$full = $Manifest.Files | Where-Object { $_.BackupType -eq 'FULL' } | Select-Object -First 1;
		
		[DateTime]$previousStart = $full.TimeStamp;
		$previousFile = 'FULL';
		
		if (-not $SkipDiffBackups) {
			
			Write-Verbose "-SkipDiffBackups is `$true. Checking for DIFF Backup....";
			
			$diff = $Manifest.Files | Where-Object { $_.BackupType -eq 'DIFF' } | Select-Object -First 1;
			if ($null -ne $diff) {
				$previousStart = $diff.TimeStamp;
				$previousFile = 'DIFF';
				Write-Verbose "`tDIFF Found.";
			}
		}
		
		[PSCustomObject[]]$gaps = @();
		[PSCustomObject]$previousLogFile = $null;
		foreach ($logBackup in $Manifest.Files | Where-Object { $_.BackupType -eq 'LOG'	} | Sort-Object { $_.TimeStamp }) {
			[TimeSpan]$span = $logBackup.TimeStamp - $previousStart;
			if ($span.TotalSeconds -gt $RpoSeconds) {
				$gaps += @{
					GapType	      		= "$($previousFile)-to-LOG"; # could be between FULL\DIFF and LOG, or could be between LOG and LOG.
					GapSeconds    		= $span.TotalSeconds;
					RpoExceededBy 		= ($span.TotalSeconds - $RpoSeconds);
					PreviousFile  		= $previousLogFile.FileName;
					GappedFile    		= $logBackup.FileName;
					PreviousTimeStamp 	= $previousLogFile.TimeStamp;
					GappedTimeStamp 	= $logBackup.TimeStamp;
					
				}
			}
			
			$previousFile = 'LOG';
			$previousStart = $logBackup.TimeStamp;
			$previousLogFile = $logBackup;
		}
		
		# TODO: 
		# 	NEED to account for TimeZone 'stuff' here. 
		# 	both in terms of potentially the time-zone of the Server - where backups were taken. 
		# 		and in terms of the time-zone where this script is running. HAPPILY, I can get that from the OS and such. 
		# 			i.e., so, cast/convert the 'backup timezone if/as needed' - and if it's different than local/current ... do whatever. 
		[DateTime]$dateTimeNowThatIsNotTimeZoneShifted = Get-Date;
		[TimeSpan]$span = $dateTimeNowThatIsNotTimeZoneShifted - $previousStart;
		if ($span.TotalSeconds -gt $RpoSeconds) {
			
			if ($previousFile -eq 'LOG') {
				$previousFile = 'LATEST_LOG';
			}
			$gaps += @{
				GapType	      		= "$($previousFile)-to-CHECK_TIME"; # there might not (yet?) be any DIFFs/T-LOGs... 
				GapSeconds    		= $span.TotalSeconds;
				RpoExceededBy 		= ($span.TotalSeconds - $RpoSeconds);
				PreviousFile  		= $previousLogFile.FileName;
				PreviousTimeStamp 	= $previousLogFile.TimeStamp;
			}   
		}		
		
		return $gaps;
	};
	
	end {
		
	};
}

function Test-cbtSecurityInfoIsSet {
	$exists = Get-AWSCredential -ListProfileDetail;
	if ($null -eq $exists) {
		return $false;
	}
	
	return $true;
}

# ===========================================================================================================
# Internal:
# ===========================================================================================================

$global:cbtMappedPathingProviders = @{};
filter Define-PathProviderRouting {
	param (
		[ScriptBlock[]]$Providers
	);
	
	$global:cbtMappedPathingProviders = @{}; # always clear upon execution. 
	
	[ScriptBlock]$wildcardMapper = $null;
	[ScriptBlock]$userDbMapper = $null;
	
	$systemDbs  @("master", "tempdb", "model", "msdb");
	
	foreach ($provider in $Providers) {
		
		$specifiedDatabases = $provider.Ast.FindAll({
				$args[0] -is [System.Management.Automation.Language.ParameterAst]
			}, $false) | Where-Object {
			$_.Name -like "*MatchingDatabases"
		} | Select-Object -Property DefaultValue;
		
		$specifiedDatabases = ($specifiedDatabases.DefaultValue -replace '"', '');
		
		switch ($specifiedDatabases) {
			"{ALL}" {
				$wildcardMapper = $provider;
			}
			"{SYSTEM}" {
				
			}
			"{USER}" {
				
			}
			default {
				# actually, might make more sense to just define a custom object here - with .Databases (array) and .ScriptBlock as properties. 
				# 	and... maybe even throw in a .IsCatchAll or .IsUserDb or whatever set of properties as well. 
				$global:cbtMappedPathingProviders["key of databases here (can I make this an array? why not?)"] = $mapper;
			}
		}
		
	}
	
	if ($null -ne $userDbMapper) {
		$global:cbtMappedPathingProviders["some kind of I'm the USER DB MAPPER = true"] = $wildcardMapper;
	}
	if ($null -ne $wildcardMapper) {
		$global:cbtMappedPathingProviders["some kind of I'm a wildcard thingy = true"] = $wildcardMapper;
	}
	
	throw 'and stuff'
	
}

filter Get-PathTranslator {
	param (
		[string]$Database
	);
	
	[bool]$isSystem = $false;
	if ($Database in @("master", "model", "tempdb", "msdb")) {
		$isSystem = $true;
	}
	
	if ($isSystem) {
		# see if there's a system mapper. 
		# if so, return. 
	}
	
	# otherwise, if we're still here. 
	# foreach($kvp in $global:cbtMappedPathingProviders) 
	# 		if $kvp.Key -contains $Database 
	# 		return $kvp.Value; 
	
	# if we're still here
	# 	look for + return either "USER" or "*" wildcard/all. 
}

filter Get-ProviderTranslatedPath {
	param (
		[string]$PathPrefix,
		[string]$Database,
		[string]$Type
	);
	
	[ScriptBlock]$matchedProvider = Get-PathTranslator -Database $Database;
	
	if ($null -eq $matchedProvider) {
		throw "ruh row... "
	}
	
	# otherwise, get the result via Invoke-xxx -Command... or whatever. 
	
}


Export-ModuleMember -Function Build-cbtBackupsFileManifest, Compare-cbtManifestAgainstLocalFiles, Copy-cbtBackupFilesLocally, Set-cbtSecurityInformation, Test-cbtBackupsCoverage, Test-cbtSecurityInfoIsSet;