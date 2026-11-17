$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

function Assert-NativeSuccess {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE."
    }
}

function Assert-BuildOutput {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-Item -LiteralPath $Path).Length -le 0) {
        throw "Build did not create a nonempty output: $Path"
    }
}

foreach ($artifact in @('dist\GuixInstall.exe', 'dist\GuixInstall.msi')) {
    if (Test-Path -LiteralPath $artifact) {
        Remove-Item -LiteralPath $artifact -Force
    }
}

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'Python 3.12+ is required. Install it from python.org.'
}

python -m venv .winvenv
Assert-NativeSuccess 'Python virtual environment creation'
& .\.winvenv\Scripts\python.exe -m pip install --quiet --upgrade pip
Assert-NativeSuccess 'pip upgrade'
& .\.winvenv\Scripts\python.exe -m pip install --quiet pyinstaller
Assert-NativeSuccess 'PyInstaller installation'

& .\.winvenv\Scripts\pyinstaller.exe --noconfirm --clean --onefile `
    --name GuixInstall `
    --icon assets\guix-logo.ico `
    --add-data "assets\guix-logo.txt;assets" `
    --add-data "LICENSE;." `
    --add-data "COPYING;." `
    windows_main.py
Assert-NativeSuccess 'PyInstaller executable build'
Assert-BuildOutput 'dist\GuixInstall.exe'

if (-not (Get-Command candle.exe -ErrorAction SilentlyContinue)) {
    choco install wixtoolset -y --no-progress
    Assert-NativeSuccess 'WiX installation'
    $env:Path = "$env:Path;C:\Program Files (x86)\WiX Toolset v3.14\bin"
}

New-Item -ItemType Directory -Force -Path dist | Out-Null
candle.exe -nologo -arch x64 windows\wix\guix-install.wxs -out dist\
Assert-NativeSuccess 'WiX object compilation'
light.exe -nologo -ext WixUtilExtension dist\guix-install.wixobj `
    -out dist\GuixInstall.msi
Assert-NativeSuccess 'WiX MSI linking'
Assert-BuildOutput 'dist\GuixInstall.msi'

Get-Item dist\GuixInstall.exe, dist\GuixInstall.msi | Select-Object Name, Length
