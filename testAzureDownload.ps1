# Directory where export files will be downloaded to
$directoryDownloaded = "C:\testAzure\Downloaded" 
 
# Directory where a log file for each day will be stored
$directoryLogs = "C:\testAzure\logs"

# The cloud blob storage connection string (=URI with SAS token)
$StorageConnectionString = "";

# Number of seconds the polling loop will wait before checking the tenant storage for new files
$timerInSeconds = 60

#Header
function ShowHeader() {
  Write-Tee $(Get-Date) -consoleColor Yellow
  Write-Tee "----------------------------------------------------------------------------------------------------------" -consoleColor Yellow
  Write-Tee "Test export files download" -consoleColor Yellow
  Write-Tee "Downloading exports to $($directoryDownloaded)" -consoleColor Yellow
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
function Checks() {
  $azCopyPath = "$(Get-Location)\azcopy.exe"
  If(-NOT(Test-Path $azCopyPath)) {
    Write-Tee "AzCopy has not been downloaded correctly" -consoleColor red
    exit
  }
  If (-NOT (Test-Path -Path $directoryDownloaded -PathType Container)) {
    Write-Tee "The local download directory $($directoryDownloaded) does not exist, check configuration" -consoleColor Red
    exit
  }
}

#Checks downloads files after download again
function CheckDownload( [Parameter(Mandatory=$true)][string] $testFile ) {
  foreach ($item in Get-ChildItem "$($directoryDownloaded)\") {
    $item = Split-Path $item -leaf
    if($item -match $testFile){
      return $false
      exit
    }
  }
  return $true
}

#Download files
function DownloadFiles() {
  ./azcopy list $StorageConnectionString | ForEach-Object {   
    If($_ -match "Content Length"){ # We only care about the objects containing a file
      $fileName = $_.Split(";")[0].Replace("INFO: ", "")
      if(CheckDownload -testFile $fileName){
        Write-Host ""
        Write-Tee "Downloading: $($fileName)..." -consoleColor Green
        $cloudPath = $StorageConnectionString.Replace("?sv=", "/$($fileName)?sv=");

        Write-Tee $cloudPath

        $downloadResult = ./azcopy copy $cloudPath $directoryDownloaded

        $downloadCompleted = $downloadResult -contains "Final Job Status: Completed"
        if ($downloadCompleted -eq $False) {
          Write-Tee "Download failed: $($fileName), file download will be retried" -consoleColor Red
        }
        else {
          Write-Tee "Download completed: $($fileName)" -consoleColor Green

          # Remove the downloaded files from the Blob container
          $removeResult = ./azcopy remove $cloudPath
          Write-Tee $removeResult
          if ($removeResult -eq $False) {
            Write-Tee "Delete in tenant storage failed: $($fileName), file download and delete will be retried" -consoleColor Red
          }
        }
      }
    }
    elseif ($_ -match "failed") {
      Write-Tee "Failed to connect, please verify connection string" -consoleColor Red
      exit;
    }
  }
}

function Write-Tee ( [parameter(Mandatory = $true)]  $message,
  [parameter(Mandatory = $false)] $consoleColor = "white"
) {
  If (!(test-path $directoryLogs)) {
    New-Item -ItemType Directory -Force -Path $directoryLogs | Out-Null
  }

  $logFile = "$(Get-Date -Format "MMddyyyy")-Download.log"
  $log = Join-Path -Path $directoryLogs -ChildPath $logFile             
  Write-Host $message -ForegroundColor $consoleColor
  if (!($null -eq $log) -and !($log -eq "")) {
    Add-content $log -value $message
  }
}

ShowHeader
DownloadDependencies
Checks
DownloadFiles

Write-Tee "Poll every $($timerInSeconds) seconds for new files and download them to $($directoryDownloaded)"

try {
  $i = 0
  do {
    Wait-Event -Timeout 1
    Write-Host "." -NoNewline 
    $i++
    
    # Poll for new files in the tenant storage's export container
    if ($i -gt $timerInSeconds) {
      $i = 0
      DownloadFiles
    }
  } while ($true)
}
finally {
  Write-Host ""
  Write-Tee "Download exited"
}