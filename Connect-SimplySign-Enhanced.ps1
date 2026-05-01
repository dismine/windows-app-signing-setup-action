# Connect-SimplySign-Enhanced.ps1
# Registry-Enhanced TOTP Authentication for SimplySign Desktop
# Uses registry pre-configuration + TOTP credential injection approach
# Based on Devas.life article: https://www.devas.life/how-to-automate-signing-your-windows-app-with-certum/

param(
    [string]$OtpUri = $env:CERTUM_OTP_URI,
    [string]$UserId = $env:CERTUM_USERNAME,
    [string]$InstallPath = $env:SS_PATH
)

# Validate required parameters
if (-not $OtpUri) {
    Write-Host "ERROR: CERTUM_OTP_URI environment variable not provided"
    exit 1
}

if (-not $UserId) {
    Write-Host "ERROR: CERTUM_USERNAME environment variable not provided"
    exit 1
}

# Resolve full exe path
$ExePath = "$InstallPath\SimplySignDesktop.exe"
if (-not (Test-Path $ExePath)) {
    $ExePath = "$env:ProgramFiles\Certum\SimplySign Desktop\SimplySignDesktop.exe"
}

Write-Host "=== REGISTRY-ENHANCED TOTP AUTHENTICATION ==="
Write-Host "Using registry pre-configuration + credential injection"
Write-Host "OTP URI provided (length: $($OtpUri.Length))"
Write-Host "User ID: $UserId"
Write-Host "Executable: $ExePath"
Write-Host ""

# Verify SimplySign Desktop exists
if (-not (Test-Path $ExePath)) {
    Write-Host "ERROR: SimplySign Desktop not found at: $ExePath"
    exit 1
}

# Parse the otpauth:// URI
$uri = [Uri]$OtpUri

# Parse query parameters (compatible with both PowerShell 5.1 and 7+)
try {
    Add-Type -AssemblyName System.Web -ErrorAction Stop
    $q = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
} catch {
    $q = @{}
    foreach ($part in $uri.Query.TrimStart('?') -split '&') {
        $kv = $part -split '=', 2
        if ($kv.Count -eq 2) { 
            $q[$kv[0]] = [Uri]::UnescapeDataString($kv[1]) 
        }
    }
}

$Base32 = $q['secret']
$Digits = if ($q['digits']) { [int]$q['digits'] } else { 6 }
$Period = if ($q['period']) { [int]$q['period'] } else { 30 }
$Algorithm = if ($q['algorithm']) { $q['algorithm'].ToUpper() } else { 'SHA256' }

# Validate supported algorithms
$SupportedAlgorithms = @('SHA1', 'SHA256', 'SHA512')
if ($Algorithm -notin $SupportedAlgorithms) {
    Write-Host "ERROR: Unsupported algorithm: $Algorithm. Supported: $($SupportedAlgorithms -join ', ')"
    exit 1
}

# TOTP Generator (inline C# implementation)
Add-Type -Language CSharp @"
using System;
using System.Security.Cryptography;

public static class Totp
{
    private const string B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    private static byte[] Base32Decode(string s)
    {
        s = s.TrimEnd('=').ToUpperInvariant();
        int byteCount = s.Length * 5 / 8;
        byte[] bytes = new byte[byteCount];

        int bitBuffer = 0, bitsLeft = 0, idx = 0;
        foreach (char c in s)
        {
            int val = B32.IndexOf(c);
            if (val < 0) throw new ArgumentException("Invalid Base32 char: " + c);

            bitBuffer = (bitBuffer << 5) | val;
            bitsLeft += 5;

            if (bitsLeft >= 8)
            {
                bytes[idx++] = (byte)(bitBuffer >> (bitsLeft - 8));
                bitsLeft -= 8;
            }
        }
        return bytes;
    }

    private static HMAC GetHmacAlgorithm(string algorithm, byte[] key)
    {
        switch (algorithm.ToUpper())
        {
            case "SHA1":
                return new HMACSHA1(key);
            case "SHA256":
                return new HMACSHA256(key);
            case "SHA512":
                return new HMACSHA512(key);
            default:
                throw new ArgumentException("Unsupported algorithm: " + algorithm);
        }
    }

    public static string Now(string secret, int digits, int period, string algorithm = "SHA256")
    {
        byte[] key = Base32Decode(secret);
        long counter = DateTimeOffset.UtcNow.ToUnixTimeSeconds() / period;

        byte[] cnt = BitConverter.GetBytes(counter);
        if (BitConverter.IsLittleEndian) Array.Reverse(cnt);

        byte[] hash;
        using (var hmac = GetHmacAlgorithm(algorithm, key))
        {
            hash = hmac.ComputeHash(cnt);
        }

        int offset = hash[hash.Length - 1] & 0x0F;
        int binary =
            ((hash[offset] & 0x7F) << 24) |
            ((hash[offset + 1] & 0xFF) << 16) |
            ((hash[offset + 2] & 0xFF) << 8) |
            (hash[offset + 3] & 0xFF);

        int otp = binary % (int)Math.Pow(10, digits);
        return otp.ToString(new string('0', digits));
    }
}
"@

function Get-TotpCode {
    param([string]$Secret, [int]$Digits = 6, [int]$Period = 30, [string]$Algorithm = 'SHA256')
    [Totp]::Now($Secret, $Digits, $Period, $Algorithm)
}

# Launch SimplySign Desktop (registry should auto-open login dialog)
Write-Host "Launching SimplySign Desktop..."
Write-Host "Registry pre-configuration should auto-open login dialog"
$proc = Start-Process -FilePath $ExePath -PassThru
if (-not $proc) {
    Write-Error "Failed to start SimplySign Desktop"
    exit 1
}

# Verify process is actually running
Start-Sleep -Milliseconds 500
$proc.Refresh()
if ($proc.HasExited) {
    Write-Error "SimplySign Desktop exited immediately after launch (exit code: $($proc.ExitCode))"
    exit 1
}
Write-Host "Process started with ID: $($proc.Id)"
Write-Host ""

# Create WScript.Shell for window interaction
$wshell = New-Object -ComObject WScript.Shell

# WinAPI for reliable window management
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Text;
public class WinAPI {
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public static List<IntPtr> GetVisibleWindows(uint pid) {
        var list = new List<IntPtr>();
        EnumWindows((hWnd, lParam) => {
            uint wPid;
            GetWindowThreadProcessId(hWnd, out wPid);
            if (wPid == pid && IsWindowVisible(hWnd)) {
                var sb = new StringBuilder(256);
                GetWindowText(hWnd, sb, 256);
                if (sb.Length > 0) list.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
"@

function Get-SimplySignWindows {
    return [WinAPI]::GetVisibleWindows([uint32]$proc.Id)
}

function Stop-Processing {
    param([string]$Reason)
    Write-Host "ERROR: $Reason"
    exit 1
}

function Set-WindowFocus {
    param(
        [IntPtr]$Handle,
        [int]$MaxAttempts = 10,
        [int]$DelayMs = 500
    )

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        [WinAPI]::SetForegroundWindow($Handle) | Out-Null
        Start-Sleep -Milliseconds $DelayMs

        $foreground = [WinAPI]::GetForegroundWindow()
        if ($foreground -eq $Handle) {
            Write-Host "Window focused successfully on attempt $i"
            Write-Host ""
            return $true
        }

        Write-Host "Focus attempt $i of $MaxAttempts failed, retrying..."
    }

    return $false
}

# Wait for the application to initialize
Write-Host "Waiting for SimplySign Desktop to initialize..."
Start-Sleep -Seconds 3

# Check window count and handle update dialog if present
$windows = Get-SimplySignWindows
Write-Host "Visible windows detected: $($windows.Count)"

switch ($windows.Count) {
    0 {
        Stop-Processing "SimplySign Desktop failed to open any windows"
        break
    }
    1 {
        Write-Host "Single window detected - skipping update dialog handling"
        break
    }
    2 {
        Write-Host "Two windows detected - update dialog likely present, dismissing..."

        $updateDialog = $windows[0]
        if (-not (Set-WindowFocus -Handle $updateDialog)) {
            Stop-Processing "Could not focus update dialog"
        }

        Start-Sleep -Milliseconds 300
        $wshell.SendKeys("{TAB}")
        Start-Sleep -Milliseconds 200
        $wshell.SendKeys("{ENTER}")
        Write-Host "Dismissed first window"
        Start-Sleep -Seconds 2

        $windows = Get-SimplySignWindows
        Write-Host "Visible windows after dismissal: $($windows.Count)"

        if ($windows.Count -eq 0) {
            Stop-Processing "SimplySign Desktop closed after dismissing update dialog"
        }
        if ($windows.Count -ne 1) {
            Stop-Processing "Unexpected window count after dismissing update dialog: $($windows.Count)"
        }

        Write-Host "Update dialog dismissed successfully"
        break
    }
    default {
        Stop-Processing "Unexpected number of windows: $($windows.Count)"
        break
    }
}

# Exactly 1 window remains - focus it for credential injection
Write-Host "Focusing login dialog for credential injection..."
$loginDialog = $windows[0]
if (-not (Set-WindowFocus -Handle $loginDialog)) {
    Stop-Processing "Could not focus login dialog for credential injection"
}
# Small delay to ensure window is ready for input
Start-Sleep -Milliseconds 400

# Generate current TOTP code
$otp = Get-TotpCode -Secret $Base32 -Digits $Digits -Period $Period -Algorithm $Algorithm
Write-Host "TOTP code generated successfully (algorithm: $Algorithm)"
Write-Host ""

# Inject credentials: Username + TAB + TOTP + ENTER
Write-Host "Injecting credentials into login dialog..."
Write-Host "Sending: Username -> TAB -> TOTP -> ENTER"

# Send the credential sequence
$wshell.SendKeys($UserId)
Start-Sleep -Milliseconds 200
$wshell.SendKeys("{TAB}")
Start-Sleep -Milliseconds 200
$wshell.SendKeys($otp)
Start-Sleep -Milliseconds 200
$wshell.SendKeys("{ENTER}")

Write-Host "Credentials injected successfully"
Write-Host ""

# Wait for authentication to process
Write-Host "Waiting for authentication to complete..."
Start-Sleep -Seconds 5

# Verify SimplySign Desktop is still running
$stillRunning = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
if ($stillRunning) {
    Write-Host "SUCCESS: SimplySign Desktop is running"
    Write-Host "Authentication should be complete"
    Write-Host "Cloud certificate should now be available"
} else {
    Write-Host "WARNING: SimplySign Desktop process has exited"
    Write-Host "This may indicate authentication failure"
}

Write-Host ""
Write-Host "=== TOTP AUTHENTICATION COMPLETE ==="
Write-Host "Registry pre-configuration + credential injection finished"
