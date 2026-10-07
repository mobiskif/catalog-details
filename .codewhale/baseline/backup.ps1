$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Here
New-Item -ItemType Directory -Force -Path ".\dataackups" | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
Copy-Item ".\dataacation.db" ".\dataackups\manual-$stamp.db" -Force
Write-Host "Копия: .\dataackups\manual-$stamp.db" -ForegroundColor Green
