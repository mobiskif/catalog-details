$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)
docker compose down
Write-Host "Остановлено. База в .\data сохранена." -ForegroundColor Green
