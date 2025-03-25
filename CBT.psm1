Set-StrictMode -Version 3.0;

##############################################################################################################
##  Public:
##############################################################################################################
function Build-cbtS3BackupsFileManifest {
	param (
		[Parameter(Mandatory)]
		[string]$BucketName,
		[string]$PathPrefix = "",   # TODO: might need some sort of @{} (dictionary) of path prefixes - for situations where FULL|DIFF|LOG files are kept in different buckets.
		[Parameter(Mandatory)]
		[string]$Database,
		[DateTime]$StopAt = [DateTime]::MinValue # When $StopAt is a) specified, and b) 'farther back' than most RECENT FULL/DIFF backups, this'll grab most recent files from BEFORE $StopAt
	);
	
	begin {
		if (-not (Test-cbtS3SecurityInfoIsSet)) {
			throw "Security Credentials have NOT been set. Use 'Set-cbtS3SecurityInformation' before proceeding.";
		}
		
		filter Get-S3FileDetailsByPath {
			param (
				[ValidateSet("FULL", "DIFF", "LOG")]
				[string]$Type,
				[DateTime]$Predecessor = [DateTime]::MinValue # i.e., previous file in the restore-chain (DIFF or FULL)
			);
			
			if ($PathPrefix.EndsWith('/')) {
				$PathPrefix = $PathPrefix.Substring(0, $PathPrefix.Length - 1);
			}
			
			$path = $PathPrefix + "/$Database/$($Type.ToUpperInvariant())";
			
			[PSCustomObject[]]$fileDetails = @();
			$s3Objects = Get-S3Object -BucketName $BucketName -Prefix $path;
			foreach ($s3Object in $s3Objects) {
				[string]$fileName = ($s3Object.Key -split "/") | Select-Object -Last 1;
				[System.DateTime]$timestamp = Get-DateTimeFromS3FileName -FileName $fileName;
				[int]$stripe = Get-StripeNumberFromS3FileName -FileName $fileName;
				
				[PSCustomObject]$fileDetail = [PSCustomObject]@{
					BackupType = $Type.ToUpperInvariant()
					Stripe	   = $stripe
					TimeStamp  = $timestamp
					FileName   = $fileName
					FullPath   = $s3Object.Key
					Size 	   = $s3Object.Size
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
		$full = Get-S3FileDetailsByPath -Type 'FULL';
		if ($null -eq $full) {
			throw "No Full-Backups found for Database [$Database] in Bucket [$BucketName] at Prefix: [$PathPrefix]. Can NOT continue building a Recovery-Manifest.";
		}
		
		Write-Verbose "Starting Manifest with FULL Backup: [$($full.FullPath)].";
		
		$manifest.Files += $full;
		$predecessor = $full.TimeStamp;
		
		$diff = Get-S3FileDetailsByPath -Type 'DIFF' -Predecessor $predecessor;
		if ($null -ne $diff) {
			$predecessor = $diff.TimeStamp;
			$manifest.Files += $diff;
		}
		
		$manifest.Files += Get-S3FileDetailsByPath -Type 'LOG' -Predecessor $predecessor;
	}
	
	end {
		return $manifest;
	}
}

function Copy-cbtS3BackupFilesLocally {
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
		if (-not (Test-cbtS3SecurityInfoIsSet)) {
			throw "Security Credentials have NOT been set. Use 'Set-cbtS3SecurityInformation' before proceeding.";
		}
		
		if ($TargetDirectory.EndsWith('\')) {
			$TargetDirectory = $TargetDirectory.Substring(0, $TargetDirectory.Length - 1);
		}
		
		if (-not (Test-Path $TargetDirectory)) {
			throw "Target Directory [$TargetDirectory] does NOT exist.";
		}
		
		filter Copy-S3FileToLocal {
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
			Copy-S3FileToLocal -File $full;
		}
		# TODO: OPTION to initiate/kick-off RESTORE operation. (This'd HAVE to be done via START of an MSDB JOB - so that this is asynchronous.)
		
		$diff = $Manifest.Files | Where-Object { $_.BackupType -eq 'DIFF'	} | Select-Object -First 1;
		if ($null -ne $diff) {
			Copy-S3FileToLocal -File $diff;
		}
		# TODO: OPTION to 'apply' (which is a bit complicated.)
		# 		So. There are 2 main options for the ability to kick-off RESTORE operations here. 
		# 		a) WAIT UNTIL we get to a DIFF (if there is/was one - i.e., BEFORE we start on LOGs). And then just restore FULL + DIFF (if there was one). 		
		# 		b) TWEAK admindb/S4's dbo.restore_databases. KEEP the OPTION to 'REPLACE', default that to 'THROW', and provide a new option for 'APPLY'... 
		# 			and then change the name of the variable. Idea then becomes that dbo.restore_databases CAN 'pick up' from a previous RESTORE and attempt
		# 			to simply apply a DIFF, then LOGs, or JUST logs (though... that's starting to be a hell of an overlap on/against dbo.apply_logs)
		# 				ah. woah. maybe dbo.restore_databases calls into dbo.apply_logs once we get to logs? 
		
		foreach ($logBackup in $Manifest.Files | Where-Object { $_.BackupType -eq 'LOG'	} | Sort-Object { $_.TimeStamp }) {
			Copy-S3FileToLocal -File $logBackup;
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


function Set-cbtS3SecurityInformation {
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

function Test-cbtS3SecurityInfoIsSet {
	$exists = Get-AWSCredential -ListProfileDetail;
	if ($null -eq $exists) {
		return $false;
	}
	
	return $true;
}

##############################################################################################################
##  Internal:
##############################################################################################################
filter Get-DateTimeFromS3FileName {
	param (
		[string]$FileName
		# TODO: might need to send in some sort of template pattern? 
		# 		if so, might need to SET that as a 'global' property vs having it sent in as an argument? 
	);
	
	# This is 1000% hard-coded/keyed against S4 backup naming conventions:
	# NOTE: i could treat this code "effectively like" a delegate - 
	$parts = $FileName -Split "_";
	$hour = $parts[6].Substring(0, 2);
	$minute = $parts[6].Substring(2, 2);
	$second = $parts[6].Substring(4, 2);
	$millisecond = $parts[7].Substring(0, 3);
	
	return New-Object System.DateTime($parts[3], $parts[4], $parts[5], $hour, $minute, $second, $millisecond);
}

filter Get-StripeNumberFromS3FileName {
	param (
		[string]$FileName
		# TODO: might need to send in some sort of template pattern? 
		# 		if so, might need to SET that as a 'global' property vs having it sent in as an argument? 
	);
	
	# NOT YET IMPLEMENTED.
	
	return 0;
}

Export-ModuleMember -Function Build-cbtS3BackupsFileManifest, Compare-cbtManifestAgainstLocalFiles, Copy-cbtS3BackupFilesLocally, Set-cbtS3SecurityInformation, Test-cbtBackupsCoverage, Test-cbtS3SecurityInfoIsSet;