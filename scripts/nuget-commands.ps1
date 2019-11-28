param(
    [string] $ConfigName = '.\nuget-config.xml'
)

if (-not(Test-Path $ConfigName)) {
    $host.ui.WriteErrorLine('NuGet Configuration not found, aborting!')
    exit 1
}

$ConfigXml = [xml](Get-Content $ConfigName)
$sourceDirPath = Resolve-Path $ConfigXml.Configuration.SourceDir
$buildDirPath = Resolve-Path $ConfigXml.Configuration.PackagesDir
$nugetDirPath = Resolve-Path $ConfigXml.Configuration.NugetDir
$nuget = "$nugetDirPath\nuget.exe"

$pushSource = $ConfigXml.Configuration.PushSource
$restoreSource = @($ConfigXml.Configuration.RestoreSources.Source) -join ";"
$packages = @($ConfigXml.Configuration.Packages.Package)

#$packages = @()
#$ConfigXml.Configuration.Packages.Package | % { $packages += $_ }

function New-NuGetSpec {
    if (-not (Test-Path $nuget)) {
        $host.ui.WriteErrorLine('NuGet not installed, aborting!')
        exit 1
    }

    <# TOKENIZED #>
    Get-ChildItem -Path $sourceDirPath -r -filter *.csproj | % {

        $dirPath = $_.Directory
        $projectName = $_.Name
        $packageName = [System.IO.Path]::GetFileNameWithoutExtension($projectName)

        if ($packages.Contains($packageName)) {
            write-host "Creating spec for package $packageName"

            pushd $dirPath
            & $nuget 'spec' $projectName -Force
            popd
        }
    }

    Write-Host "NuGet spec files:"
    Get-ChildItem -Path $sourceDirPath -r -filter *.nuspec | % { write-host $_.FullName }
}

function New-NuGetPackages {
    if (-not (Test-Path $nuget)) {
        $host.ui.WriteErrorLine('NuGet not installed, aborting!')
        exit 1
    }

    if (-not (Test-Path $buildDirPath)) {
        New-Item $buildDirPath -ItemType Directory
    } 
    else {
        Get-ChildItem -Path $buildDirPath -File | Remove-Item -Force
    }

    Get-ChildItem -Path $sourceDirPath -r -filter *.nuspec | % {

        $dirPath = $_.Directory
        $packageName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
        $projectName = "$packageName.csproj"
        $projectPath = "$dirPath\$projectName"

        if ($packages.Contains($packageName)) {
            write-host "Creating package for project $projectName"

            & $nuget pack $projectPath `
                -IncludeReferencedProjects `
                -OutputDirectory $buildDirPath `
                -Properties Configuration=Release

            if (-not $? -or $lastexitcode -ne 0) {
                $host.ui.WriteErrorLine('Packaging failed, aborting!')
                exit 1
            }
        }

    }

    Write-Host "NuGet packages:"
    Get-ChildItem -Path $buildDirPath -filter *.nupkg | % { write-host $_.FullName }
}

function Push-NewGetPackages {
    if (-not (Test-Path $nuget)) {
        $host.ui.WriteErrorLine('NuGet not installed, aborting!')
        exit 1
    }

    if (-not (Test-Path $buildDirPath)) {
        $host.ui.WriteErrorLine('NuGet packages not found, aborting!')
        exit 1
    }

    Write-Host "NuGet packages to upload:"
    $packagesToUpload = Get-ChildItem -Path $buildDirPath -filter *.nupkg
    $packagesToUpload | % { Write-Host $_.FullName }

    # Ensure we haven't run this by accident.
    $yes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Yep, upload the packages"
    $no = New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Nope, cancel upload"
    $result = $host.ui.PromptForChoice("Upload packages", "Do you want to upload the NuGet packages to the NuGet server?", @($no, $yes), 0)
    if ($result -eq 0) {
        $host.ui.WriteErrorLine('Upload cancelled, aborting!')
        exit 1
    }

    $apiKey = Get-NuGetApiKey
    if ([string]::IsNullOrEmpty($apiKey)) {
        $host.ui.WriteErrorLine('NuGet API_KEY not found, aborting!')
        exit 1
    }

    Write-Host "Start uploading pacakges"
    Write-Host ""

    # upload
    $packagesToUpload | % { 
        $packagePath = $_.FullName
        $packageName = $_.Name

        if ([string]::IsNullOrEmpty($pushSource)) {
            $cmd = $('& "{0}" push "{1}" -ApiKey "{2}" -SkipDuplicate' -f `
                    $nuget, `
                    $packagePath, `
                    $apiKey)
        }
        else {
            $cmd = $('& "{0}" push "{1}" -ApiKey "{2}" -Source "{3}" -SkipDuplicate' -f `
                    $nuget, `
                    $packagePath, `
                    $apiKey, `
                    $pushSource)
        }
 
        $errout = $stdout = ""
        Invoke-Expression -Command:$cmd -ErrorVariable errout -OutVariable stdout | Out-Null
        $stdout | % { Write-Host $_ }

        if (-not $? -or $lastexitcode -ne 0) {
            $msg = ""
            if ($errout) {
                $msg = $errout[0].Exception
            }
            if ($msg -eq "") {
                $msg = [string]::Concat($stdout.ToArray())
            }

            Write-Host "ERROR!" -ForegroundColor "Red"
            Write-Host $msg -ForegroundColor "Red"
        }
 
        Write-Host ""
    }

    Write-Host "Upload completed!"
}


function Get-NuGetApiKey {

    [string]$apiKey = $ConfigXml.Configuration.ApiKey

    if ($apiKey) {
        if ($apiKey.StartsWith("%") -and $apiKey.EndsWith("%")) {
            $apiKey = [System.Environment]::ExpandEnvironmentVariables($apiKey)
        }
        elseif ($apiKey.StartsWith("$env")) {
            $apiKey = [System.Environment]::ExpandEnvironmentVariables($apiKey)
        }
    }

    if ([string]::IsNullOrEmpty($apiKey)) {
        if (Test-Path $ConfigXml.Configuration.ApiKeySecretFile) {
            $apiKey = Get-Content $ConfigXml.Configuration.ApiKeySecretFile
        }
    }

    return $apiKey
}

function Build-MSBuild {
    param (
        [switch]$Debug,
        [string]$Verbosity = 'minimal', #Normal Normal Detailed Diagnostic
        [string]$VisualStudioVersion = '16.0'
    )

    $msbuild = Get-MSBuild
    if (-not(Test-Path $msbuild)) {
        $host.ui.WriteErrorLine('MSBuild.exe not found, aborting!')
        exit 1
    }

    $solutionPath = (Get-ChildItem -Path $sourceDirPath -r -filter *.sln -File | Select-Object -First 1).FullName
    if (-not(Test-Path $solutionPath)) {
        $host.ui.WriteErrorLine('.sln not found, aborting!')
        exit 1
    }

    Download-NuGet
    if (-not (Test-Path $nuget)) {
        $host.ui.WriteErrorLine('Unable to download NuGet executable, aborting!')
        exit 1
    }

    $restored = Restore-NuGet $solutionPath
    if (-not($restored)) {
        $host.ui.WriteErrorLine('Failed to restore NuGet packages, aborting!')
        exit 1
    }

    $BuildConfig = 'Release'
    if ($Debug) {
        $BuildConfig = 'Debug' 
    }

    $cmd = $('& "{4}" "{0}" "/t:Clean;Build" "/nologo" "/m" "/p:Platform=Any CPU" "/verbosity:{1}" "/p:Configuration={2}" "/p:VisualStudioVersion={3}"' -f `
            $solutionPath, `
            $Verbosity, `
            $BuildConfig, `
            $VisualStudioVersion, `
            $msbuild)

    Write-Host "Building solution with command line:"
    Write-Host $cmd

    # run msbuild.exe with command line
    $errout = $stdout = ""
    Invoke-Expression -Command:$cmd -ErrorVariable errout -OutVariable stdout | Out-Null

    if (-not $? -or $lastexitcode -ne 0) {
        $host.ui.WriteErrorLine('Build failed, aborting!')

        $msg = ""
        if ($errout) {
            $msg = $errout[0].Exception
        }
        if ($msg -eq "") {
            $msg = [string]::Concat($stdout.ToArray())
        }

        $Msg = $('Error: {0}.' -f $msg);
        $Exception = $(New-Object -TypeName:'System.ApplicationException' -ArgumentList:$Msg);
        throw $Exception;
    }

    Write-Host "DONE!"
}

function Get-MSBuild {
    return 'C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin\MSBuild.exe'
    <#
    $msbuildDir = (dir HKLM:\SOFTWARE\Microsoft\MSBuild\ToolsVersions\* | Get-ItemProperty -Name MSBuildToolsPath).MSBuildToolsPath
    $msbuild = "$msbuildDir\MSBuild.exe"
    return $msbuild
    #>
}

function Download-NuGet {
    if (-not(Test-Path $nuget)) {
        if (-not (Test-Path $nugetDirPath)) {
            mkdir $nugetDirPath
        }
    
        Write-Host "Downloding Nuget.exe"

        $nugetSource = 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe'
        Invoke-WebRequest $nugetSource -OutFile $nuget
    }
}

function Restore-NuGet {
    param (
        [string]$SolutionPath
    )

    # Attempt to restore packages up to 3 times, to improve resiliency to connection timeouts and access denied errors.
    $restored = $false
    $maxAttempts = 3

    if ([string]::IsNullOrEmpty($restoreSource)) {
        $cmd = $('& "{0}" restore "{1}"' -f `
                $nuget, `
                $SolutionPath)
    }
    else {
        $cmd = $('& "{0}" restore "{1}" -source "{2}" ' -f `
                $nuget, `
                $SolutionPath, `
                $restoreSource)
    }

    Write-Host "Restoring NuGet packages"

    for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {
        $errout = $stdout = ""
        Invoke-Expression -Command:$cmd -ErrorVariable errout -OutVariable stdout | Out-Null

        if ($?) {
            $restored = $true
            break
        }
        elseIf (($attempt + 1) -eq $maxAttempts) {
            break
        }
    }

    return $restored
}
