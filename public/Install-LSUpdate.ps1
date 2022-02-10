﻿function Install-LSUpdate {
    <#
        .SYNOPSIS
        Installs a Lenovo update package. Downloads it if not previously downloaded.

        .PARAMETER Package
        The Lenovo package object to install

        .PARAMETER Path
        If you previously downloaded the Lenovo package to a custom directory, specify its path here so that the package can be found

        .PARAMETER SaveBIOSUpdateInfoToRegistry
        If a BIOS update is successfully installed, write information about it to 'HKLM\Software\LSUClient\BIOSUpdate'.
        This is useful in automated deployment scenarios, especially the 'ActionNeeded' key which will tell you whether a shutdown or reboot is required to apply the BIOS update.
        The created registry values will not be deleted by this module, only overwritten on the next installed BIOS Update.
    #>

    [CmdletBinding()]
    [OutputType('PackageInstallResult')]
    Param (
        [Parameter( Position = 0, ValueFromPipeline = $true, Mandatory = $true )]
        [pscustomobject]$Package,
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [System.IO.DirectoryInfo]$Path = "$env:TEMP\LSUPackages",
        [switch]$SaveBIOSUpdateInfoToRegistry,
        [Uri]$Proxy,
        [pscredential]$ProxyCredential,
        [switch]$ProxyUseDefaultCredentials
    )

    begin {
        if ($PSBoundParameters['Debug'] -and $DebugPreference -eq 'Inquire') {
            Write-Verbose "Adjusting the DebugPreference to 'Continue'."
            $DebugPreference = 'Continue'
        }
    }

    process {
        foreach ($PackageToProcess in $Package) {
            $Extracter = $PackageToProcess.Files | Where-Object { $_.Kind -eq 'Installer' }
            $PackageDirectory = Join-Path -Path $Path -ChildPath $PackageToProcess.ID
            if (-not (Test-Path -LiteralPath $PackageDirectory -PathType Container)) {
                $null = New-Item -Path $PackageDirectory -Force -ItemType Directory
            }

            $SpfParams = @{
                'SourceFile' = $Extracter
                'Directory' = $PackageDirectory
                'Proxy' = $Proxy
                'ProxyCredential' = $ProxyCredential
                'ProxyUseDefaultCredentials' = $ProxyUseDefaultCredentials
            }
            $FullPath = Save-PackageFile @SpfParams
            if (-not $FullPath) {
                Write-Error "The installer of package '$($PackageToProcess.ID)' could not be accessed or found and will be skipped"
                continue
            }

            Expand-LSUpdate -Package $PackageToProcess -WorkingDirectory $PackageDirectory

            Write-Verbose "Installing package $($PackageToProcess.ID) ..."

            switch ($PackageToProcess.Installer.InstallType) {
                'CMD' {
                    # Special-case ThinkPad and ThinkCentre (winuptp.exe and Flash.cmd/wflash2.exe)
                    # BIOS updates because we can install them silently and unattended with custom arguments
                    # Other BIOS updates are not classified as unattended and will be treated like any other package.
                    if ($PackageToProcess.Installer.Command -match 'winuptp\.exe|Flash\.cmd') {
                        # We are dealing with a known kind of BIOS Update
                        $installProcess = Install-BiosUpdate -PackageDirectory $PackageDirectory
                    } else {
                        # Correct typo from Lenovo ... yes really...
                        $InstallCMD = $PackageToProcess.Installer.Command -replace '-overwirte', '-overwrite'
                        $installProcess = Invoke-PackageCommand -Path $PackageDirectory -Command $InstallCMD
                    }

                    $Success = $installProcess.Err -eq [ExternalProcessError]::NONE -and $(
                        if ($installProcess.Info -is [BiosUpdateInfo] -and $null -ne $installProcess.Info.SuccessOverrideValue) {
                            $installProcess.Info.SuccessOverrideValue
                        } else {
                            $installProcess.Info.ExitCode -in $PackageToProcess.Installer.SuccessCodes
                        }
                    )

                    $PendingAction = if (-not $Success) {
                        'NONE'
                    } elseif ($installProcess.Info -is [BiosUpdateInfo]) {
                        if ($installProcess.Info.ActionNeeded -eq 'SHUTDOWN') {
                            'SHUTDOWN'
                        } elseif ($installProcess.Info.ActionNeeded -eq 'REBOOT') {
                            'REBOOT_MANDATORY'
                        }
                    } elseif ($PackageToProcess.RebootType -eq 0) {
                        'NONE'
                    } elseif ($PackageToProcess.RebootType -eq 3) {
                        'REBOOT_SUGGESTED'
                    } elseif ($PackageToProcess.RebootType -eq 5) {
                        'REBOOT_MANDATORY'
                    }

                    [PackageInstallResult]@{
                        ID             = $PackageToProcess.ID
                        Title          = $PackageToProcess.Title
                        Type           = $PackageToProcess.Type
                        Success        = $Success
                        FailureReason  = if ($installProcess.Err) { "$($installProcess.Err)" } elseif (-not $Success) { 'INSTALLER_EXITCODE' } else { '' }
                        PendingAction  = $PendingAction
                        ExitCode       = $installProcess.Info.ExitCode
                        StandardOutput = $installProcess.Info.StandardOutput
                        StandardError  = $installProcess.Info.StandardError
                        LogOutput      = if ($installProcess.Info -is [BiosUpdateInfo]) { $installProcess.Info.LogMessage } else { '' }
                        Runtime        = if ($installProcess.Err) { [TimeSpan]::Zero } else { $installProcess.Info.Runtime }
                    }

                    # Extra handling for BIOS updates
                    if ($installProcess.Info -is [BiosUpdateInfo]) {
                        if ($Success) {
                            # BIOS Update successful
                            Write-Information -MessageData "BIOS UPDATE SUCCESS: An immediate full $($installProcess.Info.ActionNeeded) is strongly recommended to allow the BIOS update to complete!" -InformationAction Continue
                            if ($SaveBIOSUpdateInfoToRegistry) {
                                Set-BIOSUpdateRegistryFlag -Timestamp $installProcess.Info.Timestamp -ActionNeeded $installProcess.Info.ActionNeeded -PackageHash $Extracter.Checksum
                            }
                        }
                    }
                }
                'INF' {
                    $InfSuccessCodes = @(0, 3010) + $PackageToProcess.Installer.SuccessCodes
                    $InstallCMD = "${env:SystemRoot}\system32\pnputil.exe /add-driver $($PackageToProcess.Installer.InfFile) /install"
                    $installProcess = Invoke-PackageCommand -Path $PackageDirectory -Command $InstallCMD

                    $Success = $installProcess.Err -eq [ExternalProcessError]::NONE -and $installProcess.Info.ExitCode -in $InfSuccessCodes

                    [PackageInstallResult]@{
                        ID             = $PackageToProcess.ID
                        Title          = $PackageToProcess.Title
                        Type           = $PackageToProcess.Type
                        Success        = $Success
                        FailureReason  = if ($installProcess.Err) { "$($installProcess.Err)" } elseif (-not $Success) { 'INSTALLER_EXITCODE' } else { '' }
                        PendingAction  = if ($Success -and $installProcess.Info.ExitCode -eq 3010) { 'REBOOT_SUGGESTED' } else { 'NONE' }
                        ExitCode       = $installProcess.Info.ExitCode
                        StandardOutput = $installProcess.Info.StandardOutput
                        StandardError  = $installProcess.Info.StandardError
                        LogOutput      = ''
                        Runtime        = if ($installProcess.Err) { [TimeSpan]::Zero } else { $installProcess.Info.Runtime }
                    }
                }
                default {
                    Write-Warning "Unsupported package installtype '$_', skipping installation!"
                }
            }
        }
    }
}
