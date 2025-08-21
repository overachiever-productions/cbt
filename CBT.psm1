Set-StrictMode -Version 3.0;

<# 

	RENAME: 
		- To OBT or OSSBT: Offbox (SQL Server) Backup Tools. 
		- Critical Backup tools ... no worky, it's too close to CBT. 

	NOTES / SCOPE: 
		S3, B2 and other 'prefixes' can/should exist. 
		BUT, I'm going to use -CloudProvider or something similar to direct WHICH of these is responsible for getting stuff. 
			which, yeah... means abstraction of the 'fetch' (i.e., get details) and 'copy' (download) operations for each provider. 

		Likewise, paths... will assume/use providers. 

	ROADMAP: 
		More or less an extension of the above: 
			- 0.3.0 - Bare-Bones Implementation. 
				- Manifests													- DONE. 
				- Manifest Testing (RPO checks) 							- DONE. 
				- DOWNLOADS	(S3 Only and hard-coded) 						- DONE.
				- PATHs (providers/funcs) 									- DONE.
				- BUGFIX: (issue with [db_names]) (i.e., _ in names) 		- DONE. (Well, implemented within $script|$global:cbt_s4Get_DateTimeFromFileName. 
				- BUGFIX: odd issue with $globalScope (providers below)		- PENDING
				
				
			- 0.3.8 - Bare Bones - but Documented. 
				To Document: 
					- Module Installation and Import, etc. 
					- SETTING default zone and creds for AWS. 
					- Prefixes. 
					- Server Names. 
					- Basic operations - and the pipeline - i.e., create-manifest | check-manifest; or ... create_manifest | download-manifest-files and such. 
					- CUSTOM Paths. 
						A. Basic Idea: swappable/overwrite-able code that YOU can provide for YOUR environment for things like: extracting time from file-name, extracting timestamp from file-name, or ... controlling where FULLs are vs DIFFs , LOGs whatever. 
						B. An 'oddity' with providers - i.e., Tokens for MatchingDatabases. This isn't code. It's passed in as a parameter, just cuz that's easier for authors. OSSBT then shreds your inputs into dictionary of options matching DB names/etc. ... i.e., it's a NICE lie. 
						C. be careful when SPLITTING backup file-names into parts. 
							e.g., default approach used by OSSBT is admindb/s4 convention - i.e., split by the "_" char. 
								Only that's a huge problem if ... your database has the name "my_database" or something similar - you'll eff up the slots/spaces. 
								translation - if you're using the value "x" for splitting/chunking, you'll want to watch for DBs with that exact char in the name. 
								OSSBT uses a simple work-around for this - in the form of ... xxx. 
									Yeah, it's hacky, but a) it's fast, b) it works, c) it works. 

			- 0.4.0 - 'Cloud Providers' - i.e., abstractions for different providers - enumerate/find files, get timestamps and other details, download/synchronize with local. 
				- i.e., time to replace HARD-CODED S3 logic with: 
					- options for authentication. 
					- extensible 'providers' (i.e., abstraction). 
					- MAKE SURE to START with support for both: 
						- S3
						- SMB - i.e., no reason to NOT treat it like a 'cloud'. 
							as, then, I can 'test' and/or restore from a UNC share/etc.
							 - CREDS? 

						- B2
							- hmm. would this need their little .exe deployed as well? 
							- I THINK it would. 
								Meaning, I think that B2 would be an optional provider in the form of a full-on diff 'project' - like OSSBT.B2
									Which'd ... grab/download their .exe and place it on your box. 
									and... wire up 'providers' for enumeration + download. 

						-Azure? 
							would probably have to be similar to the above (B2)? in that it's potentially a whole other set of downloads? 

						- Which ... might mean that i technically 'need' OSSBT.S3 as well? don't really want to 'go there'. but I'll evaluate. 
							actually. i think I just bundle, S3, SMB, Azure, B2 logic into this same, single, monolithic-y module (code within the module can be extensible/non-monolithic - but I don't need N projects).


			- 0.4.2 - ditto (i.e., same as above) but with Docs. 
				Things to document: 
					- Examples
						- Here's how to execute against S3
						- Here's how to execute against an SMB share on your network. 
						- Here's how to execute against B2. 
						- or azure. 
				!! obviously: need to make sure I've got the functionality in place to showcase these examples (i.e., not exactly sure how to tackle SMB auth... but... yeah). 
#>

# ===========================================================================================================
# Providers (Defaults and Validation):
# ===========================================================================================================
# MKC: BUG/PROBLEM. No Idea what I'm doing wrong here - in terms of scope. 
# 		but these 'variables' are 10000000% just NOT visible to Build-cbtBackupsFileManifest UNLESS they're declared globally here. 

[ScriptBlock]$global:cbt_s4Get_DateTimeFromFileName = {
	param (
		[Parameter(Mandatory)]
		[string]$FileName,
		[Parameter(Mandatory)]
		[string]$DatabaseName,
		[string]$ServerName  # not needed by S4 ... but COULD, in theory, be needed by other providers. 
	);
	
	try {
		Write-Verbose "		Attempting Extraction of DateTime from File-Name: $FileName";
		
		if ($DatabaseName -like '*_*') {
			$FileName = $FileName.Replace($DatabaseName, 'xxx');
		}
		
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
	
	# TODO: NOTE the need to potentially handle _'s in database-names - as per what's going on in $global:cbt_s4Get_DateTimeFromFileName
	
	
	
	return 1; # i.e., always assume only 1x file - until implemented.
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
		[string[]]$MatchingDatabases = "{SYSTEM}",  ## NOTE this parameter is a LIE - it's actually used for hash-table mapping
		[string]$PathPrefix,
		[string]$Database,
		[string]$Type,
		[string]$ServerName = ""
	);
	
	# TODO: IF $ServerName <> '' ... guess we can also look for just dbs against the specific server-name ? e.g., <prefix>/<database>/<serverName>/<type> ... 
	return $PathPrefix + "/$Database/$($Type.ToUpperInvariant())";
}

[ScriptBlock]$global:cbt_s4Get_UserPaths = {
	param (
		[string[]]$MatchingDatabases = "{USER}",	## NOTE this parameter is a LIE - it's actually used for hash-table mapping
		[string]$PathPrefix,
		[string]$Database,
		[string]$Type,
		[string]$ServerName = ""
	);
	
	return $PathPrefix + "/$Database/$($Type.ToUpperInvariant())";
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
		[string]$SourceServerName, 		# Optional - for situations/scenarios/paths that use the server-name for part of the backup. 
		[DateTime]$StopAt = [DateTime]::MinValue, # When $StopAt is a) specified, and b) 'farther back' than most RECENT FULL/DIFF backups, this'll grab most recent files from BEFORE $StopAt
		[ScriptBlock[]]$PathTranslators = $global:cbt_s4Get_PathProviders,
		[ScriptBlock]$TimeExtractor = $global:cbt_s4Get_DateTimeFromFileName,
		[ScriptBlock]$StripeExtractor = $global:cbt_s4Get_StripeNumberFromFileName
	);
	
	begin {
		if (-not (Test-cbtSecurityInfoIsSet)) {
			throw "Security Credentials have NOT been set. Use 'Set-cbtS3SecurityInformation' before proceeding.";
		}
		
		#TODO: validate the 'interfaces' of the $TimeExtractor and $StripeExtractor - i.e. make sure
		# 		they both accept the same 2x params: fileName, dbName and... an optional -ServerName 
		Define-PathProviderRouting -Providers $PathTranslators;
		
		New-Item -Path function:Provider-GetDateTimeFromFileName -Value ($TimeExtractor.ToString()) -Force | Out-Null;
		New-Item -Path function:Provider-GetStripeFromFileName -Value ($StripeExtractor.ToString()) -Force | Out-Null;
		
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
			
			$path = Get-ProviderTranslatedPath -PathPrefix $PathPrefix -Database $Database -Type $Type -ServerName $SourceServerName;
			
			Write-Verbose "Translated Path for [$Type] Backup: $($path)*"
			
			[PSCustomObject[]]$fileDetails = @();
			$objects = Get-S3Object -BucketName $BucketName -Prefix $path;
			
			foreach ($object in $Objects) {
				[string]$fileName = ($object.Key -split "/") | Select-Object -Last 1;
						
				try{
					[System.DateTime]$timestamp = Provider-GetDateTimeFromFileName -FileName $fileName -DatabaseName $Database -ServerName $SourceServerName;
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
			Provider = "S3"		# TODO: once dynamic providers are a feature, make sure to update this - i.e., FileSystem, B2, ABS (azure block storage), etc. 
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
		[Parameter(Mandatory, Position = 0, ValueFromPipeline)]
		[PSCustomObject]$Manifest,
		[int]$RpoSeconds = 660,
		[switch]$SkipDiffBackups = $true # Arguably, we're NOT just looking to see if we can recover without RPO violations; we're looking to see if there are ANY RPO violations within the backup chain. 
	);
	
	begin {
		
	};
	
	process {
		$full = $Manifest.Files | Where-Object { $_.BackupType -eq 'FULL' } | Select-Object -First 1;
		
		if ($null -eq $full) {
			throw "hmmm. don't think FULL can be missing/empty, right? ";
		}
		
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
		# 		and in terms of the time-zone where this script is running. HAPPILY, I can get that (LOCAL server time-zone) from the OS and such. 
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

$global:cbt_systemDbs = @("master", "tempdb", "model", "msdb");
$global:cbt_MappedPathingProviders = @{ };
$global:cbt_CachedPathingProviders = @{ };
filter Define-PathProviderRouting {
	param (
		[ScriptBlock[]]$Providers
	);
	
	# always clear upon execution: 
	$global:cbt_MappedPathingProviders = @{};
	$global:cbt_CachedPathingProviders = @{};
	[ScriptBlock]$wildcardMapper = $null;
	[ScriptBlock]$systemDbMapper = $null;
	[ScriptBlock]$userDbMapper = $null;
	
	foreach ($provider in $Providers) {
		
		$specifiedDatabases = $provider.Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst]	}, $false) | Where-Object { $_.Name -like "*MatchingDatabases"	} | Select-Object -Property DefaultValue;
		
		$specifiedDatabases = ($specifiedDatabases.DefaultValue -replace '"', '');
		
		switch ($specifiedDatabases) {
			{ $_ -in @("*", "{ALL}") } {
				$wildcardMapper = $provider;
			}
			"{SYSTEM}" {
				$systemDbMapper = $provider;
			}
			"{USER}" {
				$userDbMapper = $provider;
			}
			default {
				$global:cbtMappedPathingProviders[$specifiedDatabases] = $mapper;
			}
		}
	}
	
	if ($null -ne $userDbMapper) {
		$global:cbt_MappedPathingProviders["{USER}"] = $userDbMapper;
	}
	if ($null -ne $systemDbMapper) {
		$global:cbt_MappedPathingProviders["{SYSTEM}"] = $systemDbMapper;
	}
	if ($null -ne $wildcardMapper) {
		$global:cbt_MappedPathingProviders["{ALL}"] = $wildcardMapper;
	}
}

filter Get-PathTranslator {
	param (
		[string]$Database
	);
	
	if ($global:cbt_CachedPathingProviders.ContainsKey($Database)) {
		Write-Debug "Returning Cached Provider.";
		return $global:cbt_CachedPathingProviders[$Database];
	}
	
	if ($Database -in $global:cbt_systemDbs) {
	Write-Host "$Database was in SYSTEM DBs."	
		if ($global:cbt_MappedPathingProviders.ContainsKey("{SYSTEM}")) {
			$output = $global:cbt_CachedPathingProviders[$Database];
			$global:cbt_CachedPathingProviders[$Database] = $output;
			return $output;
		}
	}
	
	# if NOT a system-database (or there was no explicit mapping for system-dbs):
	foreach ($kvp in $global:cbt_MappedPathingProviders.GetEnumerator()) {
		if ($kvp.Key -notin @("{ALL}", "{USER}", "{SYSTEM}")) {
			if ($kvp.Key -like '*,*') {
				if ($Database -in ($kvp.Key -split ',')) {
					$global:cbt_CachedPathingProviders[$Database] = $kvp.Value;
					return $kvp.Value;
				}
			}
			else {
				if ($kvp.Key -eq $Database) {
					$global:cbt_CachedPathingProviders[$Database] = $kvp.Value;
					return $kvp.Value;
				}
			}
		}
	}
	
	if ($global:cbt_MappedPathingProviders.ContainsKey("{USER}")) {
		
		$output = $global:cbt_MappedPathingProviders["{USER}"];
		$global:cbt_CachedPathingProviders[$Database] = $output;
		
		return $output;
	}
	
	if ($global:cbt_MappedPathingProviders.ContainsKey("{ALL}")) {
		$output = $global:cbt_MappedPathingProviders["{ALL}"];
		$global:cbt_CachedPathingProviders[$Database] = $output;
		return $output;
	}
	
	return $null;
}

filter Get-ProviderTranslatedPath {
	param (
		[string]$PathPrefix,
		[string]$Database,
		[string]$Type,
		[string]$ServerName = ""
	);
	
	[ScriptBlock]$matchedProvider = Get-PathTranslator -Database $Database;
	
	if ($null -eq $matchedProvider) {
		throw "ruh row... "
	}
	
	# MKC: hmmm. I need named params here... to 'bypass' $MatchingDatabases
	# 		right now, i'm testing a proof of concept. But... feels 'dirty' to keep spamming a func into creation ... 
	# 			though... honestly, not a big deal (but... feels dirty)
	# 		OTHER options: 
	# 			A. move $MatchingDatabases to the BOTTOM of the list of params? 
	# 				and then run the code like THIS: $matchedProvider.Invoke($PathPrefix, $Database, $Type, $ServerName); - i.e., .Invoke expects NAMED params. 
	# 			B. similar to the above but look to see if I can SPLAT? params in a KVP/Hashtable? 
	# 			C. MAYBE look at stripping OUT $MatchingDatabases (line/everything) from $matchingProvider AFTER I get the names of the DBs from the AST, but before I push into the hashtable
	# 				that's used to grab the implementation code? 
	try {
		New-Item -Path function:cbt_temp_NeedsNamedParams -Value ($matchedProvider.ToString()) -Force | Out-Null;
		$outputPath = cbt_temp_NeedsNamedParams -PathPrefix $PathPrefix -Database $Database -Type $Type -ServerName $ServerName;
	}
	catch {
		throw;
	}
	
	return $outputPath;
}

Export-ModuleMember -Function Build-cbtBackupsFileManifest, Copy-cbtBackupFilesLocally, Compare-cbtManifestAgainstLocalFiles, Set-cbtSecurityInformation, Test-cbtBackupsCoverage, Test-cbtSecurityInfoIsSet;