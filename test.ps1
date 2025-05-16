
Import-Module -Name "D:\Dropbox\Repositories\cbt" -Force;

#[ScriptBlock]$fileThingy = {
#	param (
#		[string]$FileName,
#		[string]$DatabaseName
#	);
#	
#	return "bite me";
#}


$manifest = Build-cbtBackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing"; # - TimeExtractor $fileThingy;

$manifest.Files | ForEach-Object { $_ };

#Build-cbtBackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing" | Test-cbtBackupsCoverage;

Build-cbtBackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing" | Compare-cbtManifestAgainstLocalFiles -TargetDirectory "X:\SQLBackups\";

Build-cbtBackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing" | Copy-cbtS3BackupFilesLocally -TargetDirectory "X:\SQLBackups\";