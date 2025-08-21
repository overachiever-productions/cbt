
<#

	BASIC MANIFEST EXTRACTION:

			Import-Module -Name "D:\Dropbox\Repositories\CBT" -Force;
			$manifest = Build-cbtBackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing" -Verbose; # - TimeExtractor $fileThingy;
			Write-Host "----------------------";
			$manifest.Files | ForEach-Object { $_; Write-Host "----------------------"; };

	
	CHECK MANIFEST FOR RPO COVERAGE:
			
			Import-Module -Name "D:\Dropbox\Repositories\CBT" -Force;
			#Build-cbtBackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing" | Test-cbtBackupsCoverage -RpoSeconds 640;
			$gaps = Build-cbtBackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing" | Test-cbtBackupsCoverage -RpoSeconds 640;
			
			Write-Host "----------------------";
			$gaps | Foreach-Object { $_; Write-Host "----------------------"; };

	
	COMPARE CONTINGENCY BACKUPS AGAINST LOCAL BACKUPs: 

			Import-Module -Name "D:\Dropbox\Repositories\cbt" -Force;
			
			$details = Build-cbtBackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing" | Compare-cbtManifestAgainstLocalFiles -TargetDirectory "X:\SQLBackups\";
			Write-Host "----------------------";
			$details | Foreach-Object { $_; Write-Host "----------------------"; };


	DOWNLOAD CONTINGENCY BACKUPS NOT IN LOCAL DIRECTORY: 
		
			Import-Module -Name "D:\Dropbox\Repositories\cbt" -Force;
			Build-cbtBackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing" | Copy-cbtBackupFilesLocally -TargetDirectory "X:\SQLBackups\";

			
	CUSTOM PATH TRANSLATORS:
			
		# FULL backups and logs are in top-level folders - with db-folders per each top-level-folder - e.g., \FULL\<dbname>\etc... instead of \<dbname>\FULL_xxxx 

			
		[ScriptBlock]$tea_SystemPaths = {
			param (
				[string[]]$MatchingDatabases = "{SYSTEM}",		## NOTE this parameter is a LIE - it's actually used for hash-table mapping
				[string]$PathPrefix,
				[string]$Database,
				[string]$Type,
				[string]$ServerName = ""
			);
			
			# TODO: IF $ServerName <> '' ... guess we can also look for just dbs against the specific server-name ? e.g., <prefix>/<database>/<serverName>/<type> ... 
			#return $PathPrefix + "/$Database/$($Type.ToUpperInvariant())";
			return $PathPrefix + "/$($Type.ToLowerInvariant())/$Database/$($Type.ToUpperInvariant())";
		}

		[ScriptBlock]$tea_UserPaths = {
			param (
				[string[]]$MatchingDatabases = "{USER}",	 ## NOTE this parameter is a LIE - it's actually used for hash-table mapping
				[string]$PathPrefix,
				[string]$Database,
				[string]$Type,
				[string]$ServerName = ""
			);
			
			#return $PathPrefix + "/$Database/$($Type.ToUpperInvariant())";
			return $PathPrefix + "/$($Type.ToLowerInvariant())/$Database/$($Type.ToUpperInvariant())";
		}			
		
		[ScriptBlock[]]$tea_PathProviders = @($tea_SystemPaths, $tea_UserPaths);
		
		Import-Module -Name "D:\Dropbox\Repositories\cbt" -Force;
		$manifest = Build-cbtBackupsFileManifest -BucketName "s4-tests" -PathPrefix "tea_test" -Database "webapi_staging" -PathTranslators $tea_PathProviders; # -Verbose;# - TimeExtractor $fileThingy;
		Write-Host "----------------------";
		$manifest.Files | ForEach-Object { $_; Write-Host "----------------------"; };



#>


#Build-cbtBackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing" | Copy-cbtBackupFilesLocally -TargetDirectory "X:\SQLBackups\";