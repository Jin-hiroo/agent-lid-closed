# Builds AgentLidClosed.exe with the C# compiler that ships with the .NET Framework 4.
param([string]$Output = (Join-Path $PSScriptRoot 'AgentLidClosed.exe'))
$ErrorActionPreference = 'Stop'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw '.NET Framework 4 C# compiler (csc.exe) not found' }
$sources = @(Join-Path $PSScriptRoot 'native\AgentLidClosed.cs'; Join-Path $PSScriptRoot 'native\Ui.cs')
& $csc /nologo /target:winexe /optimize+ /codepage:65001 "/out:$Output" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll `
    $sources
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
Write-Host "Built $Output"
