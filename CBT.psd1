@{
	RootModule = 'CBT.psm1' # Critical-Backups Tools  (sigh. Yeah, I knew there was something wrong with this name: CBT: cognitive behavioral therapy)
	ModuleVersion = '0.3.0'
	GUID = '538cdae1-b45b-4f06-a3c5-ae2e77d06678'
	Author = 'Michael K. Campbell'
	CompanyName = 'OverAchiever Productions, LLC.'
	Copyright = '(c) 2025. All rights reserved.'
	Description = 'Module description'
	
	# Supported PSEditions
	# CompatiblePSEditions = @('Core', 'Desktop')
	
	PowerShellVersion = '7.2'
	
	PowerShellHostName = ''
	
	# Minimum version of the Windows PowerShell host required by this module
	PowerShellHostVersion = ''
	
	DotNetFrameworkVersion = '8.0'
	ProcessorArchitecture = 'None'
	RequiredModules	= @(
		@{ ModuleName = "psi"; RequiredVersion = "0.3.9.0"	}
		@{ ModuleName = "AWS.Tools.S3"; RequiredVersion = "4.1.737" }
	)
	RequiredAssemblies = @()
	ScriptsToProcess = @()
	TypesToProcess = @()
	FormatsToProcess = @()
	NestedModules = @()
	FunctionsToExport = '*' #For performance, list functions explicitly
	CmdletsToExport = '*' 
	VariablesToExport = '*'
	AliasesToExport = '*' #For performance, list alias explicitly
	ModuleList = @()
	FileList = @()
	PrivateData = @{
		#Support for PowerShellGet galleries.
		PSData = @{
			# Tags = @()
			# LicenseUri = ''
			# ProjectUri = ''
			# IconUri = ''
			# ReleaseNotes = ''
		} 
	}
}