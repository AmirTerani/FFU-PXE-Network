param(
    [string]$DefaultSharePath   = "##PXE_SHARE_PATH##",
    [string]$RelativeFFUPath    = "##PXE_REL_FFU##",
    [string]$EncodedUsername    = "##PXE_USER##",
    [string]$EncodedPasswordB64 = "##PXE_PWD_BASE64##"
)

function Resolve-PxeToken {
    param([string]$Value)
    if ($Value -like '##PXE_*##') { return '' }
    return $Value
}

$DefaultSharePath   = Resolve-PxeToken $DefaultSharePath
$RelativeFFUPath    = Resolve-PxeToken $RelativeFFUPath
$EncodedUsername    = Resolve-PxeToken $EncodedUsername
$EncodedPasswordB64 = Resolve-PxeToken $EncodedPasswordB64

function ConvertTo-SafeName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    # Mirror the builder side idea: remove invalid file chars, trim
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $chars = $Name.ToCharArray()
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $chars) {
        if ($invalid -contains $ch) {
            [void]$sb.Append('_')
        }
        else {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString().Trim()
}

function Get-OfflineWindowsVolume {
    # Try to find the partition on disk 0 that contains a Windows folder
    try {
        $vol = Get-Partition -DiskNumber 0 -ErrorAction Stop |
               Get-Volume -ErrorAction Stop |
               Where-Object {
                    $_.DriveLetter -and
                    (Test-Path (Join-Path ("$($_.DriveLetter):") 'Windows\System32'))
               } |
               Select-Object -First 1

        if ($vol) {
            return "$($vol.DriveLetter):"
        }
    }
    catch {
        Write-Host "Failed to query partitions by disk. Falling back to brute-force drive scan."
    }

    # Fallback: brute force C through Z
    foreach ($letter in 'C'..'Z') {
        $root = "$letter`:"
        if (Test-Path $root) {
            if (Test-Path (Join-Path $root 'Windows\System32')) {
                return $root
            }
        }
    }

    return $null
}

function Get-DriverFolderByConvention {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriversRoot
    )

    $cs = Get-CimInstance Win32_ComputerSystem

    $manufacturer = ($cs.Manufacturer | Out-String).Trim()
    $model        = ($cs.Model        | Out-String).Trim()

    Write-Host "Fallback driver resolution using folder convention. Manufacturer='$manufacturer', Model='$model'"

    # Map manufacturer to vendor folder name used by the builder script
    function Get-VendorFolder {
        param([string]$Manufacturer)

        switch -Regex ($Manufacturer) {
            'HP|Hewlett-Packard|Hewlett Packard' { return 'HP' }
            'Dell'                               { return 'Dell' }
            'Lenovo'                             { return 'Lenovo' }
            'Microsoft'                          { return 'Microsoft' }
            default                              { return (ConvertTo-SafeName -Name $Manufacturer) }
        }
    }

    $vendorFolder = Get-VendorFolder -Manufacturer $manufacturer
    $vendorRoot   = Join-Path $DriversRoot $vendorFolder

    if (-not (Test-Path $vendorRoot)) {
        Write-Host "Vendor root folder not found: $vendorRoot"
        return $null
    }

    $modelFolderName = ConvertTo-SafeName -Name $model
    $candidate = Join-Path $vendorRoot $modelFolderName

    if (Test-Path $candidate) {
        Write-Host "Found model-specific driver folder: $candidate"
        return $candidate
    }

    # Heuristic search: look for a directory whose name roughly matches the model
    $dirs = Get-ChildItem -Path $vendorRoot -Directory
    $match = $dirs | Where-Object {
        $_.Name -eq $modelFolderName -or
        $_.Name -like "*$model*"      -or
        $model -like "*$($_.Name)*"
    } | Select-Object -First 1

    if ($match) {
        Write-Host "Heuristic match for model driver folder: $($match.FullName)"
        return $match.FullName
    }

    Write-Host "No driver folder found matching model under $vendorRoot"
    return $null
}

function Invoke-DriverInjection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShareRoot
    )

    $driversRoot = Join-Path $ShareRoot 'Drivers'
    if (-not (Test-Path $driversRoot)) {
        Write-Host "Drivers root not found at $driversRoot. Skipping driver injection."
        return
    }

    $osRoot = Get-OfflineWindowsVolume
    if (-not $osRoot) {
        Write-Host "Could not determine offline Windows volume. Skipping driver injection."
        return
    }

    Write-Host "Offline Windows path detected as $osRoot"

    
    $driverFolder = Get-DriverFolderByConvention -DriversRoot $driversRoot
    if (Test-Path -Path $driverFolder) {
        Write-Host "Injecting drivers from $driverFolder"
        $dismArgs = "/Image:$osRoot /Add-Driver /Driver:`"$driverFolder`" /Recurse"

        Write-Host "Running: dism $dismArgs"
        $proc = Start-Process -FilePath dism.exe -ArgumentList $dismArgs -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            Write-Host "Driver injection completed successfully."
        }
        else {
            Write-Host "Driver injection failed with exit code $($proc.ExitCode)."
        }
    } else {
        Write-Host "No drivers for $make\$model on share. Skipping injection."
    }
  
}


try {
    Write-Host "Starting FFU deployment from network share..."

    if ([string]::IsNullOrWhiteSpace($DefaultSharePath)) {
        Write-Host "PXE share path is not configured in this media. Aborting."
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace($RelativeFFUPath)) {
        Write-Host "PXE FFU path is not configured in this media. Aborting."
        exit 1
    }

    # Establish an authenticated session to the UNC using net use (no drive letter)
    if (-not [string]::IsNullOrWhiteSpace($EncodedUsername) -and
        -not [string]::IsNullOrWhiteSpace($EncodedPasswordB64)) {

        try {
            $bytes    = [Convert]::FromBase64String($EncodedPasswordB64)
            $plainPwd = [System.Text.Encoding]::UTF8.GetString($bytes)

            # Clean up any previous connection to this share (ignore errors)
            & net.exe use $DefaultSharePath "/delete" "/y" 2>$null | Out-Null

            $netArgs = @("use", $DefaultSharePath, $plainPwd, "/user:$EncodedUsername")
            & net.exe @netArgs | Out-Null

            Write-Host "PXE credentials applied for $DefaultSharePath"
        }
        catch {
            Write-Host "Failed to apply PXE credentials. Error: $($_.Exception.Message)"
            exit 1
        }
    }
    else {
        Write-Host "PXE credentials not embedded. Continuing without explicit credentials."
    }

    # Build full UNC path to the FFU
    $ffuPath = Join-Path $DefaultSharePath $RelativeFFUPath

    if (-not (Test-Path $ffuPath)) {
        Write-Host "FFU file not found at $ffuPath"
        exit 1
    }

    Write-Host "FFU file: $ffuPath"
    Write-Host "This will apply the FFU to disk 0. All data on that disk will be lost."
    Write-Host "Beginning apply operation in five seconds."
    Start-Sleep -Seconds 5

    Write-Host "Applying FFU to disk 0..."
    DISM /Apply-Image /ImageFile:"$ffuPath" /ApplyDrive:\\.\PhysicalDrive0 /SkipPlatformCheck

    Write-Host "FFU deployment complete. Injecting model-specific drivers from network share."

    Invoke-DriverInjection -ShareRoot $sharePath

    Write-Host "Driver injection phase complete. You can now reboot the device."

}
catch {
    Write-Host "Deployment failed: $($_.Exception.Message)"
}
