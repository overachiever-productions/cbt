
Import-Module -Name "D:\Dropbox\Repositories\cbt" -Force;

#$manifest = Build-cbtS3BackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing";

#$manifest;
#
#Test-cbtBackupsCoverage -Manifest $manifest | ForEach-Object {
#	Write-Host "----------------------------------";
#	$_;
#}

#Build-cbtS3BackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing" | Test-cbtBackupsCoverage;


Build-cbtS3BackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing" | Copy-cbtS3BackupFilesLocally -TargetDirectory "X:\SQLBackups\";