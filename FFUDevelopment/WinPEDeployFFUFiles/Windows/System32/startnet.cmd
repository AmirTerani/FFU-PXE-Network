@echo off
wpeinit > NUL
powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c > NUL
powershell -Noprofile -ExecutionPolicy Bypass -File X:\DeployFFUFromShare.ps1
exit

