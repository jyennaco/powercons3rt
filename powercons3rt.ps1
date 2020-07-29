#!/usr/bin/env pwsh
<#

Useful fucntions for use in powershell assets:

* Logging methods: logInfo, logWarn, logErr
* get_asset_dir - Determines ASSET_DIR when not set
* get_deployment_home - Determines DEPLOYMENT_HOME
* get_deployment_properties - Globally imports the Powershell deployment-properties.ps1 contents into the environment
* reliable_download - Downloads files from external sources and outputs progress

#>

# Set the Error action preference when an exception is caught
$ErrorActionPreference = "Stop"

# Start a stopwatch to record asset run time
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

########################### VARIABLES ###############################

# Get the CONS3RT environment variables
$global:ASSET_DIR = $null
$global:DEPLOYMENT_HOME = $null
$global:DEPLOYMENT_PROPERTIES = $null

# Example file download URL
$fileDownloadUrl = "https://example.com/download.zip"

# Example file download destination
$fileDownloadDestination = "C:\download.zip"

# Configure the log file
$logTag = 'sample-install.ps1'
$logFileTimestamp = Get-Date -f "yyyyMMdd-HHmmss"
$logFile = "C:\cons3rt-agent\log\$logTag-$logFileTimestamp.log"

# Logging methods
function logger($level, $logstring) {
    $stamp = get-date -f "yyyyMMdd HH:mm:ss"
    "$stamp $logTag [$level]: $logstring"
}
function logErr($logstring) { logger "ERROR" $logstring }
function logWarn($logstring) { logger "WARNING" $logstring }
function logInfo($logstring) { logger "INFO" $logstring }

function get_asset_dir() {
    if ($env:ASSET_DIR) {
        $global:ASSET_DIR = $env:ASSET_DIR
        return
    }
    else {
        logWarn "ASSET_DIR environment variable not set, attempting to determine..."
        if (!$PSScriptRoot) {
            logInfo "Determining script directory using the pre-Powershell v3 method..."
            $scriptDir = split-path -parent $MyInvocation.MyCommand.Definition
        }
        else {
            logInfo "Determining the script directory using the PSScriptRoot variable..."
            $scriptDir = $PSScriptRoot
        }
        if (!$scriptDir) {
            $msg =  "Unable to determine the script directory to get ASSET_DIR"
            logErr $msg
            throw $msg
        }
        else {
            $global:ASSET_DIR = "$scriptDir\.."
            logInfo "Determined ASSET_DIR to be: $global:ASSET_DIR"
        }
    }
}

function get_deployment_home() {
    # Ensure DEPLOYMENT_HOME is set
    if ($env:DEPLOYMENT_HOME) {
        $global:DEPLOYMENT_HOME = $env:DEPLOYMENT_HOME
        logInfo "Found DEPLOYMENT_HOME set to $global:DEPLOYMENT_HOME"
    }
    else {
        logWarn "DEPLOYMENT_HOME is not set, attempting to determine..."
        # CONS3RT Agent Run directory location
        $cons3rtAgentRunDir = "C:\cons3rt-agent\run"
        $deploymentDirName = get-childitem $cons3rtAgentRunDir -name -dir | select-string "Deployment"
        $deploymentDir = "$cons3rtAgentRunDir\$deploymentDirName"
        if (test-path $deploymentDir) {
            $global:DEPLOYMENT_HOME = $deploymentDir
        }
        else {
            $msg = "Unable to determine DEPLOYMENT_HOME from: $deploymentDir"
            logErr $msg
            throw $msg
        }
    }
    logInfo "Using DEPLOYMENT_HOME: $global:DEPLOYMENT_HOME"
}

function get_deployment_properties() {
    $deploymentPropertiesFile = "$global:DEPLOYMENT_HOME\deployment-properties.ps1"
    if ( !(test-path $deploymentPropertiesFile) ) {
        $msg = "Deployment properties not found: $deploymentPropertiesFile"
        logErr $msg
        throw $msg
    }
    else {
        $global:DEPLOYMENT_PROPERTIES = $deploymentPropertiesFile
        logInfo "Found deployment properties file: $global:DEPLOYMENT_PROPERTIES"
    }
    import-module $global:DEPLOYMENT_PROPERTIES -force -global
}

function reliable_download() {
    logInfo "Attempting to download file from URL: $fileDownloadUrl"

    # Attempt to download multiple times
    $numAttempts = 1
    $maxAttempts = 10
    $retryTime = 10
    while($true) {

        if($numAttempts -gt $maxAttempts) {
            $errMsg = "The number of attempts to download the file exceeded: $maxAttempts"
            logErr $errMsg
            throw $errMsg
        }

        logInfo "Attempting to download file, attempt #: $numAttempts of $maxAttempts"
        $downloadComplete = $false

        # Download the media file
        logInfo "Attempting to download file: $fileDownloadUrl to: $fileDownloadDestination"
        $start = get-date
        $Job = Start-BitsTransfer -Source $fileDownloadUrl -Destination $fileDownloadDestination -Asynchronous

        $checkTime = 10
        while (($Job.JobState -eq "Transferring") -or ($Job.JobState -eq "Connecting")) {
            $percentComplete = [math]::round(($Job.BytesTransferred / $Job.BytesTotal)*100, 2)
            $timeElapsed = $((get-date).subtract($start).ticks/10000000)
            msg = "Download in progress, state: [{1}], time elapsed: [{2}], bytes downloaded: [{3}], percent complete: [{4}]" -f $Job.JobState, $timeElapsed, $Job.BytesTransferred, $percentComplete
            logInfo $msg
            sleep $checkTime
        }

        $percentComplete = [math]::round(($Job.BytesTransferred / $Job.BytesTotal)*100, 2)
        $timeElapsed = $((get-date).subtract($start).ticks/10000000)
        Switch($Job.JobState)
        {
            "Transferred" {
                $msg = "Download completed, total time taken: [{1}], total bytes transferred: [{2}]" -f $timeElapsed, $Job.BytesTransferred
                logInfo $msg
                Complete-BitsTransfer -BitsJob $Job
                $downloadComplete = $true
            }
            "Error" {
                $msg = "Download failed after [{1}], total bytes transferred: [{2}/{3}], percent completed: {4}" -f $timeElapsed, $Job.BytesTransferred, $Job.BytesTotal, $percentComplete
                logWarn $msg
                logWarn "Download failed with error: $formattedError"
            }
            default {
                logWarn "Unable to determine the failure status, will retry"
            }
        }

        if ($downloadComplete) {
            logInfo "Download complete, exiting the while loop..."
            break
        }

        $numAttempts++
        logInfo "Retrying in $retryTime seconds..."
        sleep $retryTime
    }
    logInfo "File download complete to: $fileDownloadDestination"
}
