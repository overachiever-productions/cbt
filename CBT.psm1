Set-StrictMode -Version 3.0;

##############################################################################################################
##  Public:
##############################################################################################################

function Build-cbtS3BackupsFileManifest {
	param (
		[Parameter(Mandatory)]
		[string]$BucketName,
		# TODO: might need some sort of @{} (dictionary) of path prefixes - for situations where FULL|DIFF|LOG files are kept in different buckets.
		[string]$PathPrefix = "",
		[Parameter(Mandatory)]
		[string]$Database,
		[DateTime]$StopAt = [DateTime]::MinValue # When $StopAt is a) specified, and b) 'farther back' than most RECENT FULL/DIFF backups, this'll grab most recent files from BEFORE $StopAt
	);
	
	begin {
		filter Get-S3FileDetailsByPath {
			param (
				[string]$Type,
				# FULL, DIFF, LOG
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
				
				$fileDetail = @{
					BackupType = $Type.ToUpperInvariant()
					Stripe	   = $stripe
					TimeStamp  = $timestamp
					FileName   = $fileName
					FullPath   = $s3Object.Key
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
			
			# NOTE: Because the filter here is on TimeStamp - any backups that are striped don't need any additional logic. 
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
		
		[PSCustomObject[]]$manifest = @();
	}
	
	process {
		$full = Get-S3FileDetailsByPath -Type 'FULL';
		if ($null -eq $full) {
			throw "No Full-Backups found for Database [$Database] in Bucket [$BucketName] at Prefix: [$PathPrefix]. Can NOT continue building a Recovery-Manifest.";
		}
		
		Write-Verbose "Starting Manifest with FULL Backup: [$($full.FullPath)].";
		
		$manifest += $full;
		$predecessor = $full.TimeStamp;
		
		$diff = Get-S3FileDetailsByPath -Type 'DIFF' -Predecessor $predecessor;
		if ($null -ne $diff) {
			$predecessor = $diff.TimeStamp;
			$manifest += $diff;
		}
		
		$manifest += Get-S3FileDetailsByPath -Type 'LOG' -Predecessor $predecessor;
	}
	
	end {
		return $manifest;
	}
}

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

function Test-cbtBackupsCoverage {
	param (
		[Parameter(Mandatory)]
		[PSCustomObject]$Manifest,
		[int]$RpoSeconds = 660,
		[switch]$SkipDiffBackups = $true # Arguably, we're NOT just looking to see if we can recover without RPO violations; we're looking to see if there are ANY RPO violations within the backup chain. 
	);
	
	begin {
		
	};
	
	process {
		$full = $Manifest | Where-Object { $_.BackupType -eq 'FULL' } | Select-Object -First 1;
		
		[DateTime]$previousStart = $full.TimeStamp;
		$previousFile = 'FULL';
		
		if (-not $SkipDiffBackups) {
			
			Write-Verbose "-SkipDiffBackups is `$true. Checking for DIFF Backup....";
			
			$diff = $Manifest | Where-Object { $_.BackupType -eq 'DIFF' } | Select-Object -First 1;
			if ($null -ne $diff) {
				$previousStart = $diff.TimeStamp;
				$previousFile = 'DIFF';
				Write-Verbose "`tDIFF Found.";
			}
		}
		
		[PSCustomObject[]]$gaps = @();
		[PSCustomObject]$previousLogFile = $null;
		foreach ($logBackup in $Manifest | Where-Object { $_.BackupType -eq 'LOG'	} | Sort-Object { $_.TimeStamp }) {
			[TimeSpan]$span = $logBackup.TimeStamp - $previousStart;
			if ($span.TotalSeconds -gt $RpoSeconds) {
				$gaps += @{
					GapType	      		= "$($previousFile)-to-LOG"; # could be between FULL\DIFF and LOG, or could be between LOG and LOG.
					GapSeconds    		= $span.TotalSeconds;
					RpoExceededBy 		= ($span.TotalSeconds - $RpoSeconds);
					PreviousFile  		= $previousLogFile.FileName;
					GappedFile    		= $logBackup.FileName;
					PreviousTimeStamp 	= $previousFile.TimeStamp;
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
				PreviousTimeStamp 	= $previousFile.TimeStamp;
			}   
		}		
		
		return $gaps;
	};
	
	end {
		
	};
}

filter Test-cbtS3SecurityInfoIsSet {
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

Export-ModuleMember -Function Build-cbtS3BackupsFileManifest, Set-cbtS3SecurityInformation, Test-cbtBackupsCoverage, Test-cbtS3SecurityInfoIsSet;