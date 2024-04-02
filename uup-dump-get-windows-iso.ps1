#!/usr/bin/pwsh
param(
    [string]$windowsTargetName,
    [string]$destinationDirectory='output'
)

Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
trap {
    Write-Host "ERROR: $_"
    @(($_.ScriptStackTrace -split '\r?\n') -replace '^(.*)$','ERROR: $1') | Write-Host
    @(($_.Exception.ToString() -split '\r?\n') -replace '^(.*)$','ERROR EXCEPTION: $1') | Write-Host
    Exit 1
}

$TARGETS = @{
    # see https://en.wikipedia.org/wiki/Windows_11
    # see https://en.wikipedia.org/wiki/Windows_11_version_history
    "windows-11" = @{
        search = "windows 11 22631 amd64" # aka 23H2. Enterprise EOL: November 10, 2026.
        edition = "Professional"
        virtualEdition = "Enterprise"
    }
    # see https://en.wikipedia.org/wiki/Windows_Server_2022
    "windows-2022" = @{
        search = "feature update server operating system 20348 amd64" # aka 21H2. Mainstream EOL: October 13, 2026.
        edition = "ServerStandard"
        virtualEdition = $null
    }
}

function New-QueryString([hashtable]$parameters) {
    @($parameters.GetEnumerator() | ForEach-Object {
        "$($_.Key)=$([System.Web.HttpUtility]::UrlEncode($_.Value))"
    }) -join '&'
}

function Invoke-UupDumpApi([string]$name, [hashtable]$body) {
    # see https://git.uupdump.net/uup-dump/json-api
    for ($n = 0; $n -lt 15; ++$n) {
        if ($n) {
            Write-Host "Waiting a bit before retrying the uup-dump api ${name} request #$n"
            Start-Sleep -Seconds 10
            Write-Host "Retrying the uup-dump api ${name} request #$n"
        }
        try {
            return Invoke-RestMethod `
                -Method Get `
                -Uri "https://api.uupdump.net/$name.php" `
                -Body $body
        } catch {
            Write-Host "WARN: failed the uup-dump api $name request: $_"
        }
    }
    throw "timeout making the uup-dump api $name request"
}

function Get-UupDumpIso($name, $target) {
    Write-Host "Getting the $name metadata"
    $result = Invoke-UupDumpApi listid @{
        search = $target.search
    }
    $result.response.builds.PSObject.Properties `
        | ForEach-Object {
            $id = $_.Value.uuid
            $uupDumpUrl = 'https://uupdump.net/selectlang.php?' + (New-QueryString @{
                id = $id
            })
            Write-Host "Processing $name $id ($uupDumpUrl)"
            $_
        } `
        | Where-Object {
            # ignore previews when they are not explicitly requested.
            $result = $target.search -like '*preview*' -or $_.Value.title -notlike '*preview*'
            if (!$result) {
                Write-Host "Skipping. Expected preview=false. Got preview=true."
            function Get-WindowsIso($name, $destinationDirectory) {
                $iso = Get-UupDumpIso $name $TARGETS.$name

                # ensure the build is a version number.
                if ($iso.build -notmatch '^\d+\.\d+$') {
                    throw "unexpected $name build: $($iso.build)"
                }

                $buildDirectory = "$destinationDirectory/$name"
                $destinationIsoPath = "$buildDirectory.iso"
                $destinationIsoMetadataPath = "$destinationIsoPath.json"
                $destinationIsoChecksumPath = "$destinationIsoPath.sha256.txt"

                # create the build directory.
                if (Test-Path $buildDirectory) {
                    Remove-Item -Force -Recurse $buildDirectory | Out-Null
                }
                New-Item -ItemType Directory -Force $buildDirectory | Out-Null

                # define the iso title.
                $edition = if ($iso.virtualEdition) {
                    $iso.virtualEdition
                } else {
                    $iso.edition
                }
                $title = "$name $edition $($iso.build)"

                Write-Host "Downloading the UUP dump download package for $title from $($iso.downloadPackageUrl)"
                $downloadPackageBody = if ($iso.virtualEdition) {
                    @{
                        autodl = 3
                        updates = 1
                        cleanup = 1
                        'virtualEditions[]' = $iso.virtualEdition
                    }
                } else {
                    @{
                        autodl = 2
                        updates = 1
                        cleanup = 1
                    }
                }
                Invoke-WebRequest `
                    -Method Post `
                    -Uri $iso.downloadPackageUrl `
                    -Body $downloadPackageBody `
                    -OutFile "$buildDirectory.zip" `
                    | Out-Null
                Expand-Archive "$buildDirectory.zip" $buildDirectory

                # patch the uup-converter configuration.
                # see the ConvertConfig $buildDirectory/ReadMe.html documentation.
                # see https://github.com/abbodi1406/BatUtil/tree/master/uup-converter-wimlib
                $convertConfig = (Get-Content $buildDirectory/ConvertConfig.ini) `
                    -replace '^(AutoExit\s*)=.*','$1=1' `
                    -replace '^(ResetBase\s*)=.*','$1=1' `
                    -replace '^(SkipWinRE\s*)=.*','$1=1'
                if ($iso.virtualEdition) {
                    $convertConfig = $convertConfig `
                        -replace '^(StartVirtual\s*)=.*','$1=1' `
                        -replace '^(vDeleteSource\s*)=.*','$1=1' `
                        -replace '^(vAutoEditions\s*)=.*',"`$1=$($iso.virtualEdition)"
                }
                Set-Content `
                    -Encoding ascii `
                    -Path $buildDirectory/ConvertConfig.ini `
                    -Value $convertConfig

                Write-Host "Creating the $title iso file inside the $buildDirectory directory"
                Push-Location $buildDirectory
                # NB we have to use powershell cmd to workaround:
                #       https://github.com/PowerShell/PowerShell/issues/6850
                #       https://github.com/PowerShell/PowerShell/pull/11057
                # NB we have to use | Out-String to ensure that this powershell instance
                #    waits until all the processes that are started by the .cmd are
                #    finished.
                powershell cmd /c uup_download_windows.cmd | Out-String -Stream
                if ($LASTEXITCODE) {
                    throw "uup_download_windows.cmd failed with exit code $LASTEXITCODE"
                }
                Pop-Location

                $sourceIsoPath = Resolve-Path $buildDirectory/*.iso

                Write-Host "Getting the $sourceIsoPath checksum"
                $isoChecksum = (Get-FileHash -Algorithm SHA256 $sourceIsoPath).Hash.ToLowerInvariant()
                Set-Content -Encoding ascii -NoNewline `
                    -Path $destinationIsoChecksumPath `
                    -Value $isoChecksum

                $windowsImages = Get-IsoWindowsImages $sourceIsoPath

                # create the iso metadata file.
                Set-Content `
                    -Path $destinationIsoMetadataPath `
                    -Value (
                        ([PSCustomObject]@{
                            name = $name
                            title = $iso.title
                            build = $iso.build
                            checksum = $isoChecksum
                            images = @($windowsImages)
                            uupDump = @{
                                id = $iso.id
                                apiUrl = $iso.apiUrl
                                downloadUrl = $iso.downloadUrl
                                downloadPackageUrl = $iso.downloadPackageUrl
                            }
                        } | ConvertTo-Json -Depth 99) -replace '\\u0026','&'
                    )

                Write-Host "Moving the created $sourceIsoPath to $destinationIsoPath"
                Move-Item -Force $sourceIsoPath $destinationIsoPath

                Write-Host 'All Done.'
            }

            $windows10TargetName = "Windows10"
            $windows11UITargetName = "Windows11UI"
            $destinationDirectory = "C:\ISOs"

            Get-WindowsIso $windows10TargetName $destinationDirectory
            Get-WindowsIso $windows11UITargetName $destinationDirectory
