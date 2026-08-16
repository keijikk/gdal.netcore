$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$workRoot = if ($env:RUNNER_TEMP) {
    Join-Path $env:RUNNER_TEMP 'gdal-clean-runtime'
}
else {
    Join-Path $repoRoot 'build-clean-runtime'
}
$sourceRoot = Join-Path $workRoot 'source'
$gdalSource = Join-Path $sourceRoot 'gdal'
$projSource = Join-Path $sourceRoot 'proj'
$vcpkgRoot = Join-Path $workRoot 'vcpkg'
$vcpkgInstalled = Join-Path $vcpkgRoot 'installed\x64-windows'
$projBuild = Join-Path $workRoot 'proj-build'
$projInstall = Join-Path $workRoot 'proj-install'
$gdalBuild = Join-Path $workRoot 'gdal-build'
$runtimeRoot = Join-Path $workRoot 'runtime'
$outRoot = Join-Path $repoRoot 'out'
$sqliteExecutable = Join-Path $vcpkgInstalled 'tools\sqlite3.exe'

function Invoke-External {
    param([Parameter(Mandatory)] [scriptblock] $Command)

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "External command failed with exit code $LASTEXITCODE."
    }
}

function Clone-Release {
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Tag,
        [Parameter(Mandatory)] [string] $Destination)

    Invoke-External { git clone -c core.longpaths=true --depth 1 --branch $Tag $Repository $Destination }
}

function Clone-Commit {
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Commit,
        [Parameter(Mandatory)] [string] $Destination)

    Invoke-External { git clone -c core.longpaths=true --filter=blob:none --no-checkout $Repository $Destination }
    Invoke-External { git -C $Destination fetch --depth 1 origin $Commit }
    Invoke-External { git -C $Destination checkout --detach FETCH_HEAD }
}

function Initialize-Msvc {
    $vsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsInstall = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsInstall) {
        throw 'A Visual Studio C++ toolchain was not found.'
    }

    $vsDevCmd = Join-Path $vsInstall 'Common7\Tools\VsDevCmd.bat'
    $environment = cmd.exe /c "`"$vsDevCmd`" -arch=x64 -host_arch=x64 >nul && set"
    foreach ($entry in $environment) {
        if ($entry -match '^(.*?)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
}

New-Item -ItemType Directory -Force -Path $sourceRoot, $outRoot | Out-Null
Initialize-Msvc

# GDAL 3.13.2 is the current stable release. PROJ 9.8.1 is its current
# stable companion. Both are built from their official source repositories.
Clone-Release 'https://github.com/OSGeo/gdal.git' 'v3.13.2' $gdalSource
Clone-Release 'https://github.com/OSGeo/PROJ.git' '9.8.1' $projSource
Clone-Commit 'https://github.com/microsoft/vcpkg.git' 'c3867e714dd3a51c272826eea77267876517ed99' $vcpkgRoot

Invoke-External { & (Join-Path $vcpkgRoot 'bootstrap-vcpkg.bat') '-disableMetrics' }
Invoke-External {
    & (Join-Path $vcpkgRoot 'vcpkg.exe') install 'sqlite3[tool,rtree]' 'nlohmann-json' expat 'arrow[core,parquet]' --triplet x64-windows
}
if (-not (Test-Path $sqliteExecutable -PathType Leaf)) {
    throw "vcpkg did not install sqlite3.exe at $sqliteExecutable."
}

# PROJ's documented source-build requirements are SQLite and nlohmann/json.
# Network and GeoTIFF support are intentionally excluded from this first,
# license-auditable runtime profile.
Invoke-External {
    cmake -S $projSource -B $projBuild -G Ninja `
        "-DCMAKE_INSTALL_PREFIX=$projInstall" `
        "-DCMAKE_PREFIX_PATH=$vcpkgInstalled" `
        "-DEXE_SQLITE3=$sqliteExecutable" `
        -DCMAKE_BUILD_TYPE=Release `
        -DBUILD_SHARED_LIBS=ON `
        -DBUILD_APPS=OFF `
        -DBUILD_TESTING=OFF `
        -DENABLE_CURL=OFF `
        -DENABLE_TIFF=OFF `
        -DEMBED_PROJ_DATA_PATH=OFF
}
Invoke-External { cmake --build $projBuild --parallel }
Invoke-External { cmake --install $projBuild }

# This is the commercial-distribution clean profile. It enables only the
# selected file formats and the explicit, license-audited dependencies they
# require: SQLite3, Expat, and Apache Arrow/Parquet.
Invoke-External {
    cmake -S $gdalSource -B $gdalBuild -G Ninja `
        "-DCMAKE_INSTALL_PREFIX=$runtimeRoot" `
        "-DCMAKE_PREFIX_PATH=$projInstall;$vcpkgInstalled" `
        "-DPROJ_DIR=$(Join-Path $projInstall 'lib\cmake\proj')" `
        -DCMAKE_BUILD_TYPE=Release `
        -DGDAL_BUILD_OPTIONAL_DRIVERS=OFF `
        -DOGR_BUILD_OPTIONAL_DRIVERS=OFF `
        -DOGR_ENABLE_DRIVER_DXF=ON `
        -DOGR_ENABLE_DRIVER_CSV=ON `
        -DOGR_ENABLE_DRIVER_KML=ON `
        -DOGR_ENABLE_DRIVER_GML=ON `
        -DOGR_ENABLE_DRIVER_GPX=ON `
        -DOGR_ENABLE_DRIVER_SQLITE=ON `
        -DOGR_ENABLE_DRIVER_GPKG=ON `
        -DOGR_ENABLE_DRIVER_MVT=ON `
        -DOGR_ENABLE_DRIVER_FLATGEOBUF=ON `
        -DOGR_ENABLE_DRIVER_OPENFILEGDB=ON `
        -DOGR_ENABLE_DRIVER_PARQUET=ON `
        -DGDAL_ENABLE_DRIVER_BMP=ON `
        -DGDAL_ENABLE_DRIVER_GIF=ON `
        -DGDAL_ENABLE_DRIVER_JPEG=ON `
        -DGDAL_ENABLE_DRIVER_PNG=ON `
        -DGDAL_ENABLE_DRIVER_MBTILES=ON `
        -DGDAL_USE_EXTERNAL_LIBS=OFF `
        -DGDAL_USE_INTERNAL_LIBS=ON `
        -DGDAL_USE_EXPAT=ON `
        -DGDAL_USE_SQLITE3=ON `
        -DGDAL_USE_ARROW=ON `
        -DGDAL_USE_PARQUET=ON `
        -DGDAL_USE_PROJ=ON `
        -DBUILD_TESTING=OFF `
        -DBUILD_CSHARP_BINDINGS=ON `
        -DCSHARP_LIBRARY_VERSION:STRING=net10.0 `
        -DCSHARP_APPLICATION_VERSION:STRING=net10.0 `
        -DGDAL_CSHARP_APPS=OFF `
        -DGDAL_CSHARP_TESTS=OFF `
        -DGDAL_CSHARP_BUILD_NUPKG=OFF `
        -DBUILD_PYTHON_BINDINGS=OFF `
        -DBUILD_JAVA_BINDINGS=OFF
}
Invoke-External { cmake --build $gdalBuild --parallel }
Invoke-External { cmake --install $gdalBuild }

Copy-Item -Force (Join-Path $projInstall 'bin\*.dll') (Join-Path $runtimeRoot 'bin')
Copy-Item -Recurse -Force (Join-Path $projInstall 'share\proj') (Join-Path $runtimeRoot 'share\proj')
Copy-Item -Force (Join-Path $vcpkgInstalled 'bin\*.dll') (Join-Path $runtimeRoot 'bin')

$licensesRoot = Join-Path $runtimeRoot 'licenses'
New-Item -ItemType Directory -Force -Path $licensesRoot | Out-Null
Copy-Item -Force (Join-Path $gdalSource 'LICENSE.TXT') (Join-Path $licensesRoot 'GDAL.txt')
Copy-Item -Force (Join-Path $projSource 'COPYING') (Join-Path $licensesRoot 'PROJ.txt')
Get-ChildItem -Path (Join-Path $vcpkgInstalled 'share') -Recurse -File -Filter copyright | ForEach-Object {
    Copy-Item -Force $_.FullName (Join-Path $licensesRoot ("vcpkg-$($_.Directory.Name).txt"))
}

$runtimeBin = Join-Path $runtimeRoot 'bin'
$gdalData = Join-Path $runtimeRoot 'share\gdal'
$projData = Join-Path $runtimeRoot 'share\proj'
if (-not (Test-Path $gdalData -PathType Container)) {
    throw "GDAL data directory was not installed: $gdalData"
}
if (-not (Test-Path $projData -PathType Container)) {
    throw "PROJ data directory was not installed: $projData"
}

$env:PATH = $runtimeBin + ';' + $env:PATH
$env:GDAL_DATA = $gdalData
$env:PROJ_DATA = $projData

function Get-Formats {
    param([Parameter(Mandatory)] [string] $Program)

    if (-not (Test-Path $Program -PathType Leaf)) {
        throw "GDAL command-line verifier was not installed: $Program"
    }

    $formats = & $Program --formats 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    Write-Host "$([IO.Path]::GetFileName($Program)) --formats output:`n$formats"
    if ($exitCode -ne 0) {
        throw "$([IO.Path]::GetFileName($Program)) --formats failed with exit code $exitCode."
    }

    return $formats
}

function Assert-RegisteredFormats {
    param(
        [Parameter(Mandatory)] [string] $Formats,
        [Parameter(Mandatory)] [string[]] $Required,
        [Parameter(Mandatory)] [string] $ProgramName)

    $missing = $Required | Where-Object { $Formats -notmatch ([Regex]::Escape($_) + '\s+-') }
    if ($missing) {
        throw "$ProgramName is missing required formats: $($missing -join ', ')"
    }
}

$vectorFormats = Get-Formats (Join-Path $runtimeBin 'ogrinfo.exe')
Assert-RegisteredFormats $vectorFormats @(
    'GeoJSON', 'GeoJSONSeq', 'TopoJSON', 'ESRIJSON', 'DXF', 'ESRI Shapefile',
    'CSV', 'KML', 'GML', 'GPX', 'SQLite', 'GPKG', 'MVT', 'FlatGeobuf',
    'OpenFileGDB', 'Parquet'
) 'ogrinfo'

$rasterFormats = Get-Formats (Join-Path $runtimeBin 'gdalinfo.exe')
Assert-RegisteredFormats $rasterFormats @(
    'VRT', 'GTiff', 'COG', 'BMP', 'GIF', 'JPEG', 'PNG', 'MBTiles'
) 'gdalinfo'

$csharpBindings = Join-Path $runtimeRoot 'share\csharp'
$requiredCsharpFiles = @(
    'gdalconst_csharp.dll', 'osr_csharp.dll', 'ogr_csharp.dll', 'gdal_csharp.dll',
    'gdalconst_wrap.dll', 'osr_wrap.dll', 'ogr_wrap.dll', 'gdal_wrap.dll'
)
$missingCsharpFiles = $requiredCsharpFiles | Where-Object { -not (Test-Path (Join-Path $csharpBindings $_) -PathType Leaf) }
if ($missingCsharpFiles) {
    throw "C# bindings are missing from the runtime: $($missingCsharpFiles -join ', ')"
}

$forbidden = 'poppler|mysql|geos|pdfium|openjpeg|hdf|netcdf|spatialite'
$forbiddenFiles = Get-ChildItem -Path $runtimeRoot -Recurse -File | Where-Object { $_.Name -match $forbidden }
if ($forbiddenFiles) {
    throw "The clean runtime contains excluded dependencies: $($forbiddenFiles.Name -join ', ')"
}

$zipPath = Join-Path $outRoot 'gdal-windows-x64-clean-runtime.zip'
Remove-Item -Force $zipPath -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $runtimeRoot '*') -DestinationPath $zipPath
