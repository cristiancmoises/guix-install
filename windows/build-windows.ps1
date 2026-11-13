$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'Python 3.12+ is required. Install it from python.org.'
}

python -m venv .winvenv
& .\.winvenv\Scripts\python.exe -m pip install --quiet --upgrade pip
& .\.winvenv\Scripts\python.exe -m pip install --quiet pyinstaller

& .\.winvenv\Scripts\pyinstaller.exe --noconfirm --clean --onefile `
    --name GuixInstall `
    --icon assets\guix-logo.ico `
    --add-data "assets\guix-logo.txt;assets" `
    windows_main.py

if (-not (Get-Command candle.exe -ErrorAction SilentlyContinue)) {
    choco install wixtoolset -y --no-progress
    $env:Path = "$env:Path;C:\Program Files (x86)\WiX Toolset v3.14\bin"
}

New-Item -ItemType Directory -Force -Path dist | Out-Null
candle.exe -nologo -arch x64 windows\wix\guix-install.wxs -out dist\
light.exe -nologo -ext WixUtilExtension dist\guix-install.wixobj `
    -out dist\GuixInstall.msi

Get-Item dist\GuixInstall.exe, dist\GuixInstall.msi | Select-Object Name, Length
