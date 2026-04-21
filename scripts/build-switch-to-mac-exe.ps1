param(
    [string]$OutputPath = (
        Join-Path (Split-Path -Parent $PSScriptRoot) ([string]([char[]](0x5207,0x5230,0x004D,0x0061,0x0063,0x002E,0x0065,0x0078,0x0065)))
    ),
    [string]$SourcePngPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'icons8-mac-os-480.png'),
    [string]$IconPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\switch-to-mac.ico')
)

$ErrorActionPreference = 'Stop'

function Get-CscPath {
    $candidates = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw 'Unable to find csc.exe.'
}

$tempSource = Join-Path $env:TEMP 'switch-to-mac-launcher.cs'
$cscPath = Get-CscPath
$iconBuilderPath = Join-Path $PSScriptRoot 'generate-switch-to-mac-icon.ps1'

$source = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        var baseDir = AppDomain.CurrentDomain.BaseDirectory;
        var scriptPath = Path.Combine(baseDir, "scripts", "switch-to-mac-now.ps1");

        if (!File.Exists(scriptPath))
        {
            MessageBox.Show(
                "Script not found: " + scriptPath,
                "SwitchToMac",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            Environment.Exit(1);
            return;
        }

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"",
            WorkingDirectory = baseDir,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };

        try
        {
            using (var process = Process.Start(psi))
            {
                if (process == null)
                {
                    throw new InvalidOperationException("powershell.exe did not start.");
                }
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Launch failed: " + ex.Message,
                "SwitchToMac",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            Environment.Exit(1);
        }
    }
}
'@

[IO.File]::WriteAllText($tempSource, $source, [Text.UTF8Encoding]::new($false))

$outputDir = Split-Path -Parent $OutputPath
if ($outputDir) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $iconBuilderPath)) {
    throw "Icon builder not found: $iconBuilderPath"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $iconBuilderPath -SourcePath $SourcePngPath -OutputPath $IconPath
if ($LASTEXITCODE -ne 0) {
    throw "Icon build failed with exit code: $LASTEXITCODE"
}

& $cscPath `
    /nologo `
    /target:winexe `
    /optimize+ `
    /utf8output `
    /out:$OutputPath `
    /win32icon:$IconPath `
    /reference:System.Windows.Forms.dll `
    /reference:System.dll `
    $tempSource

if ($LASTEXITCODE -ne 0) {
    throw "Build failed with exit code: $LASTEXITCODE"
}

Write-Host "Built: $OutputPath"
