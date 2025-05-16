
<#

	BASIC MANIFEST EXTRACTION:

			Import-Module -Name cbt -Force;
			$manifest = Build-cbtBackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing"; # - TimeExtractor $fileThingy;
			Write-Host "----------------------";
			$manifest.Files | ForEach-Object { $_; Write-Host "----------------------"; };

	
	CHECK MANIFEST FOR RPO COVERAGE:
			
			Import-Module -Name "D:\Dropbox\Repositories\cbt" -Force;
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

			

#>








Build-cbtBackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing" | Copy-cbtBackupFilesLocally -TargetDirectory "X:\SQLBackups\";