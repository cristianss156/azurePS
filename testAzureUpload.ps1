# Directory where new files will be placed in specific subdirectories
$directoryToWatch = "C:\testAzure\Watch" 

# Directory where files will be moved to when uploaded succesfully to the cloud. Make sure it is not a subdirectory of the directory to watch.
$directoryUploaded = "C:\testAzure\Uploaded" 

# Directory where a log file for each day will be stored
$directoryLogs = "C:\testAzure\Logs" 

# Regex expression that filters the files on their name or extension.
$filePattern = "(.*\.csv)$" 

# The cloud blob storage connection string (=URI with SAS token)
$StorageConnectionString = "";

#Header
function ShowHeader() {
  Write-Tee $(Get-Date) -consoleColor Yellow
  Write-Tee "----------------------------------------------------------------------------------------------------------" -consoleColor Yellow
  Write-Tee "Test local files upload" -consoleColor Yellow
  Write-Tee "Watching files in $($directoryToWatch)" -consoleColor Yellow
  Write-Tee "----------------------------------------------------------------------------------------------------------" -consoleColor Yellow
}

#Download AzCopy
function DownloadDependencies() {
  $azCopyPath = "$(Get-Location)\AzCopy"
  if (-NOT(Test-Path $azCopyPath)) {
    if (Test-Path $azCopyPath) {
      Get-ChildItem $azCopyPath | Remove-Item -Confirm:$false -Force
    }

    $zip = "$azCopyPath\AzCopy.zip"

    $null = New-Item -Type Directory -Path $azCopyPath -Force

    Start-BitsTransfer -Source "https://aka.ms/downloadazcopy-v10-windows" -Destination $zip

    Expand-Archive $zip $azCopyPath -Force

    Get-ChildItem "$($azCopyPath)\*\*" | Move-Item -Destination "$(Get-Location)\" -Force

    Remove-Item $zip -Force -Confirm:$false
    Get-ChildItem "$($azCopyPath)\*" -Directory | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -Confirm:$false }
  }
}

#Sanity checks
function SanityChecks() {
  $azCopyPath = Join-Path -Path $(Get-Location) -ChildPath "azcopy.exe"
  If (-NOT(Test-Path $azCopyPath)) {
    Write-Tee "AzCopy has not been downloaded correctly" -consoleColor Red
    exit
  }

  If (-NOT (Test-Path -Path $directoryToWatch -PathType Container)) {
    Write-Tee "Directory with files that should be uploaded $($directoryToWatch) does not exist, check configuration" -consoleColor Red
    exit
  }
  
  If (-NOT (Test-Path -Path $directoryUploaded -PathType Container)) {
    Write-Tee "Directory for files that are uploaded $($directoryUploaded) does not exist, check configuration" -consoleColor Red
    exit
  }
}

function UploadMetadataToCheckConnection() {
  $metadata = 
  "Script: $($ScriptFilename)`r`n" +
  "Version: $($version)`r`n" +
  "Directory to watch: $($directoryToWatch)`r`n" +
  "Directory uploaded: $($directoryUploaded)`r`n" +
  "Directory logs: $($directoryLogs)`r`n" +
  "File pattern: $($filePattern)"
  $metadataFile = Join-Path -Path $($directoryLogs) -ChildPath uploadmetadata.txt
  
  New-Item -ItemType "file" -Force -Path $metadataFile | Out-Null
  Set-Content $metadataFile $metadata

  $StorageDestinationFile = $StorageConnectionString.Replace("?sv=", "/metadata/metadata.txt?sv=")

  $uploadResult = ./azcopy copy $metadataFile $StorageDestinationFile
  $uploadCompleted = $uploadResult -contains "Final Job Status: Completed"

  if ($uploadCompleted -eq $False) {
    Write-Tee "Test upload to $($StorageConnectionString) failed, check connection string" -consoleColor Red
    exit
  }
  else {
    Write-Tee "Test upload to $($StorageConnectionString) successful" -consoleColor Green
  }
}

#Logging
function Write-Tee ( [parameter(Mandatory = $true)]  $message,
  [parameter(Mandatory = $false)] $consoleColor = "white"
) {
  If (!(test-path $directoryLogs)) {
    New-Item -ItemType Directory -Force -Path $directoryLogs | Out-Null
  }

  $logFile = "$(Get-Date -Format "MMddyyyy")-Upload.log"
  $log = Join-Path -Path $directoryLogs -ChildPath $logFile
  Write-Host $message -ForegroundColor $consoleColor
  if (!($null -eq $log) -and !($log -eq "")) {
    Add-content $log -value $message
  }
}

#Upload and move files
function ProcessFiles() {
  Get-ChildItem -path $directoryToWatch -Recurse | 
  Where-Object { [System.IO.Path]::GetFileName($_.FullName) -match $filePattern  } |
  ForEach-Object {
    if (-not(TestFileLock($_.FullName))) {
      if (UploadToBlobStorage $_.FullName) {
        MoveToUploadedDirectory $_.FullName
        return $true
        exit
      }
      else {
        Write-Tee "$($_.FullName) upload to cloud failed and will be retried later" -consoleColor Magenta
      }
    }
    else {
      Write-Tee "$($_.FullName) is locked and will be retried later" -consoleColor Magenta
    }
  }
  return $false
}

function UploadToBlobStorage {
  param([string]$fullPath)
  Write-Tee "$($fullPath) start uploading to cloud ..."

  # Inject the relative path starting from the directory to watch into the tenant storage connection string. This recreates the same structure in the tenant storage
  $filename = [System.IO.Path]::GetFileName($fullPath);
  $relativePath = $fullPath.Replace($directoryToWatch, '').Replace($filename, '')
  if ($platform -eq "win-x64" -or $platform -eq "win-x32") {
    $relativePath = $relativePath.Replace('\', '/');
  }    

  $StorageConnectionStringWithRelativePath = $StorageConnectionString.Replace('?sv=', "$($relativePath)?sv=")

  $uploadResult = ./azcopy copy $fullPath $StorageConnectionStringWithRelativePath
  $uploadCompleted = $uploadResult -contains "Final Job Status: Completed"

  if ($uploadCompleted) {
    Write-Tee "$($fullPath) upload completed" -consoleColor Green
  }
  else {
    Write-Tee "$($fullPath) upload failed" -consoleColor Red
    Write-Tee $uploadResult -consoleColor Red
  }
  
  return $uploadCompleted  
}

function MoveToUploadedDirectory {
  param([string]$fullPath)
  $relativePath = $fullPath.Replace($directoryToWatch, '')
  $directoryToCopyTo = Join-Path -Path $directoryUploaded -ChildPath $relativePath
  $null = New-Item -ItemType File -Path $directoryToCopyTo -Force # Create empty file to ensure path is created
  Move-Item -Force -Path $fullPath -Destination $directoryToCopyTo    
  Write-Tee "$($fullPath) moved to $directoryToCopyTo" -consoleColor Green
}

function TestFileLock {
  param ([parameter(Mandatory = $true)][string]$path)

  $oFile = New-Object System.IO.FileInfo $path

  if ((Test-Path -Path $path) -eq $false) { return $false }
  try {
    $oStream = $oFile.Open([System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)

    if ($oStream) { $oStream.Close() }
    return $false
  }
  catch { return $true }
}

#Initialization

# Global variables
$version = "3.0"
$ScriptFilename = $MyInvocation.MyCommand.Name

ShowHeader
DownloadDependencies
SanityChecks
UploadMetadataToCheckConnection

#Main
Write-Tee "Watching for changes in $directoryToWatch"

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $directoryToWatch
$watcher.IncludeSubdirectories = $true
$ChangeTypes = [System.IO.WatcherChangeTypes]::Created

try {
  $i = 60
  do {
    $result = $watcher.WaitForChanged($ChangeTypes, 1000)
    # Immediately pick up file changes
    if (!$result.TimedOut)  {
      # And keep on doing so as long as files are uploaded
      while (ProcessFiles) { }
    }
    # Or deal with files that were left behind every minute
    else {
      $i++
      if ($i -gt 60) {
        $i = 0
        $null = ProcessFiles
      }
    }
    Write-Host "." -NoNewline        
  } while ($true)
}
finally {
  Write-Tee "Upload exited"
}