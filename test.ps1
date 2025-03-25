
Import-Module -Name "D:\Dropbox\Repositories\cbt" -Force;

$module = Build-cbtS3BackupsFileManifest -BucketName "s4-tests" -PathPrefix "s3-backups-test" -Database "Billing";

