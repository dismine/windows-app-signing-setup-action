# Connect-SimplySign-Enhanced.ps1
# Registry-Enhanced TOTP Authentication for SimplySign Desktop
# Uses registry pre-configuration + TOTP credential injection approach
# Based on Devas.life article: https://www.devas.life/how-to-automate-signing-your-windows-app-with-certum/

param(
    [string]$OtpUri = $env:CERTUM_OTP_URI,
    [string]$UserId = $env:CERTUM_USERNAME,
    [string]$KeyId = $env:CERTUM_KEY_ID,
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
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

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

# ------------------------------------------------------------------
# Helpers added for reliable credential injection and popup recovery
# ------------------------------------------------------------------

function Get-WindowTitle {
    param([IntPtr]$Handle)
    $sb = New-Object System.Text.StringBuilder 256
    [WinAPI]::GetWindowText($Handle, $sb, 256) | Out-Null
    return $sb.ToString()
}

function Get-WindowGeometry {
    param([IntPtr]$Handle)
    $rect = New-Object 'WinAPI+RECT'
    [WinAPI]::GetWindowRect($Handle, [ref]$rect) | Out-Null
    return [PSCustomObject]@{
        Left   = $rect.Left
        Top    = $rect.Top
        Width  = $rect.Right - $rect.Left
        Height = $rect.Bottom - $rect.Top
    }
}

function Write-WindowTitles {
    param([string]$Context)
    $wins = @(Get-SimplySignWindows)
    Write-Host "[$Context] Visible windows: $($wins.Count)"
    foreach ($h in $wins) {
        $g = Get-WindowGeometry -Handle $h
        Write-Host "  - handle=$h title='$(Get-WindowTitle -Handle $h)' size=$($g.Width)x$($g.Height) pos=($($g.Left),$($g.Top))"
    }
}

# The login dialog is substantially larger than the Yes/No update or OK error
# message boxes, so the largest-area window is the login window. All three share
# the title "SimplySign Desktop", so size is the reliable discriminator.
function Get-LoginWindow {
    param([System.Collections.IEnumerable]$Windows)
    $best = [IntPtr]::Zero
    $bestArea = -1
    foreach ($h in $Windows) {
        $rect = New-Object 'WinAPI+RECT'
        [WinAPI]::GetWindowRect($h, [ref]$rect) | Out-Null
        $area = ($rect.Right - $rect.Left) * ($rect.Bottom - $rect.Top)
        if ($area -gt $bestArea) { $bestArea = $area; $best = $h }
    }
    return $best
}

# Diagnostic screenshot — opt-in only (login email is visible, so never on by
# default for public users). Enabled via CAPTURE_DIAGNOSTICS=true in our tests.
# Each capture is numbered with an incrementing counter so repeated stages (e.g.
# a popup or submit on every retry) are all preserved, not overwritten — and the
# files sort in chronological order.
$script:diagSeq = 0
function Save-Screenshot {
    param([string]$Stage)
    if ($env:CAPTURE_DIAGNOSTICS -ne 'true') { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $safe = ($Stage -replace '[^A-Za-z0-9_-]', '_')
        $script:diagSeq++
        $seq = '{0:D3}' -f $script:diagSeq
        $path = Join-Path (Get-Location) "simplysign-diag-$seq-$safe.png"
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        Write-Host "Saved diagnostic screenshot: $path"
    } catch {
        Write-Host "Screenshot capture failed: $($_.Exception.Message)"
    }
}

# Record (for the test workflow) that a modal popup recovery path actually ran.
function Set-DialogHandledFlag {
    if ($env:GITHUB_ENV -and (Test-Path $env:GITHUB_ENV)) {
        "SS_DIALOG_HANDLED=true" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    }
}

# Generate a TOTP code with a healthy slice of its ~Period-second window left.
# SimplySign shows a ~29s window and validates a few seconds after submit, so a
# code sent in the back half of the window can be rejected as stale. If under
# 20s remain, wait for the next period so we always submit early in the window.
function Get-FreshTotpCode {
    $secondsLeft = $Period - ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % $Period)
    Write-Host "TOTP window: $secondsLeft s remaining (period: $Period s)"
    if ($secondsLeft -lt 20) {
        $wait = $secondsLeft + 1
        Write-Host "Under 20s left — waiting ${wait}s for a fresh period to submit early in the window..."
        Start-Sleep -Seconds $wait
    }
    $code = Get-TotpCode -Secret $Base32 -Digits $Digits -Period $Period -Algorithm $Algorithm
    $left = $Period - ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % $Period)
    Write-Host "TOTP generated (algorithm: $Algorithm) with ~${left}s of validity"
    return $code
}

# Enter credentials via the clipboard (Ctrl+V) instead of streaming keystrokes.
# SendKeys on Qt fields intermittently drops/reorders characters (a single lost
# digit => "Invalid user name or token"); an atomic paste removes that failure
# class. Fields are cleared first to drop any pre-filled/residual content.
function Invoke-CredentialSubmit {
    param([IntPtr]$Handle, [string]$Otp, [string]$UserName = $UserId)

    if (-not (Set-WindowFocus -Handle $Handle)) {
        Write-Host "WARNING: could not focus login dialog before submit"
    }
    Start-Sleep -Milliseconds 400

    # Diagnostic: dialog state before we type anything (is ID pre-filled/empty?
    # which field has focus?).
    Save-Screenshot -Stage "before-fill"

    # ID field (focused on a fresh dialog): clear, then paste username
    Set-Clipboard -Value $UserName
    $wshell.SendKeys("^a"); Start-Sleep -Milliseconds 120
    $wshell.SendKeys("{DEL}"); Start-Sleep -Milliseconds 120
    $wshell.SendKeys("^v"); Start-Sleep -Milliseconds 250

    # Diagnostic: where did the username text actually land?
    Save-Screenshot -Stage "after-userid"

    # Move to the Token field: clear, then paste the one-time code
    $wshell.SendKeys("{TAB}"); Start-Sleep -Milliseconds 250
    Set-Clipboard -Value $Otp
    $wshell.SendKeys("^a"); Start-Sleep -Milliseconds 120
    $wshell.SendKeys("{DEL}"); Start-Sleep -Milliseconds 120
    $wshell.SendKeys("^v"); Start-Sleep -Milliseconds 250

    # Submit
    $wshell.SendKeys("{ENTER}")
    Start-Sleep -Milliseconds 300

    # Diagnostic: result right after submit, before any popup appears.
    Save-Screenshot -Stage "after-submit"

    # Clear the clipboard so the secret token does not linger
    Set-Clipboard -Value ' '
}

# Re-enter only the token after dismissing an "Invalid user name or token"
# dialog. SimplySign leaves the ID value intact and the (now empty) Token field
# focused, so the full ID->Tab->Token sequence would instead paste the username
# into the focused Token field. Here we paste only the fresh code into the
# already-focused Token field and submit — no window re-focus and no Tab (either
# would move input off the Token field).
function Invoke-TokenResubmit {
    param([string]$Otp)

    # Diagnostic: dialog state before the token-only resubmit (where is focus,
    # does the ID field still hold its value?).
    Save-Screenshot -Stage "before-token-resubmit"

    Set-Clipboard -Value $Otp
    $wshell.SendKeys("^a"); Start-Sleep -Milliseconds 120
    $wshell.SendKeys("{DEL}"); Start-Sleep -Milliseconds 120
    $wshell.SendKeys("^v"); Start-Sleep -Milliseconds 250

    $wshell.SendKeys("{ENTER}")
    Start-Sleep -Milliseconds 300

    # Diagnostic: result right after the token-only resubmit.
    Save-Screenshot -Stage "after-token-resubmit"

    # Clear the clipboard so the secret token does not linger
    Set-Clipboard -Value ' '
}

# Dismiss a modal popup (update "New version" dialog OR "Invalid user name or
# token" error). Titles are identical, so we cannot tell them apart — instead
# use a ladder that re-checks after each step and NEVER presses the update
# dialog's default "Yes" (which would start a download): Alt+N selects "No";
# Tab+Space activates the focused "No"; Enter (last) can only reach an OK-only
# error box once any Yes/No dialog is already gone. Returns $true if cleared.
function Resolve-Popup {
    param([IntPtr]$LoginHandle)

    $popups = @(Get-SimplySignWindows | Where-Object { $_ -ne $LoginHandle })
    if ($popups.Count -eq 0) { return $false }

    $popup = $popups[0]
    # Titles are identical, so log geometry to tell the dialogs apart from text
    # logs alone (privacy-safe — no screenshot needed). The "New version found"
    # update prompt (#2, Yes/No, more text) is wider than the short "Invalid user
    # name or token" error box (#3, OK only); the width is a heuristic, not exact.
    $g = Get-WindowGeometry -Handle $popup
    $guess = if ($g.Width -ge 400) { 'likely #2 update dialog (Yes/No)' } else { 'likely #3 error dialog (OK only)' }
    Write-Host "Modal popup detected: handle=$popup title='$(Get-WindowTitle -Handle $popup)' size=$($g.Width)x$($g.Height) pos=($($g.Left),$($g.Top)) — $guess"
    Save-Screenshot -Stage "popup"

    $ladder = @(
        @{ Keys = '%n';      Desc = 'Alt+N (No)' },
        @{ Keys = '{TAB} ';  Desc = 'Tab + Space (activate No)' },
        @{ Keys = '{ENTER}'; Desc = 'Enter (OK on error dialog)' }
    )

    foreach ($step in $ladder) {
        Set-WindowFocus -Handle $popup | Out-Null
        Start-Sleep -Milliseconds 200
        $wshell.SendKeys($step.Keys)
        Write-Host "Dismissal attempt: $($step.Desc)"
        Start-Sleep -Milliseconds 800

        $remaining = @(Get-SimplySignWindows | Where-Object { $_ -ne $LoginHandle })
        if ($remaining.Count -eq 0) {
            Write-Host "Popup dismissed via $($step.Desc)"
            Set-DialogHandledFlag
            return $true
        }
        $popup = $remaining[0]
    }

    Write-Host "WARNING: popup still present after dismissal ladder"
    return $false
}

# Wait for the application to initialize
Write-Host "Waiting for SimplySign Desktop to initialize..."
$maxWaitSeconds = 30
$elapsed = 0
$windows = @()

while ($elapsed -lt $maxWaitSeconds) {
    $windows = @(Get-SimplySignWindows)
    if ($windows.Count -gt 0) {
        Write-Host "SimplySign Desktop ready after $elapsed seconds"
        break
    }

    # Check process hasn't crashed while waiting
    $proc.Refresh()
    if ($proc.HasExited) {
        Write-Error "SimplySign Desktop crashed during initialization (exit code: $($proc.ExitCode))"
        exit 1
    }

    Start-Sleep -Seconds 1
    $elapsed++
}

if ($windows.Count -eq 0) {
    Save-Screenshot -Stage "no-window"
    Write-Error "SimplySign Desktop did not open any windows within $maxWaitSeconds seconds"
    exit 1
}
Write-WindowTitles -Context "initial detection"

# Identify the login window (largest); any other visible window is a modal popup.
$loginHandle = Get-LoginWindow -Windows $windows
Write-Host "Login window: handle=$loginHandle title='$(Get-WindowTitle -Handle $loginHandle)'"

if (-not (Set-WindowFocus -Handle $loginHandle)) {
    Stop-Processing "Could not focus login dialog for credential injection"
}
# Small delay to ensure window is ready for input
Start-Sleep -Seconds 2

# Give the async version-check a brief chance to raise the "New version" dialog
# and dismiss it before we inject, so it cannot steal focus mid-submit.
$settle = 0
while ($settle -lt 6) {
    if (Resolve-Popup -LoginHandle $loginHandle) {
        Set-WindowFocus -Handle $loginHandle | Out-Null
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 1
    $settle++
}

# First credential submission
$forceBad = ($env:SS_TEST_FORCE_BAD_FIRST_TOKEN -eq 'true')
$forceBadUser = ($env:SS_TEST_FORCE_BAD_FIRST_USERNAME -eq 'true')
$otp = Get-FreshTotpCode
if ($forceBad) {
    Write-Host "TEST HOOK: SS_TEST_FORCE_BAD_FIRST_TOKEN=true — first submit uses a deliberately invalid token"
    # Guarantee a value different from the real code so it is always rejected.
    $submitOtp = if ($otp -eq ('0' * $Digits)) { '1' * $Digits } else { '0' * $Digits }
} else {
    $submitOtp = $otp
}

# Test-only: corrupt the username on the FIRST submit so a token-only retry can
# never recover it, forcing the full-re-entry escalation (which uses the real
# username) to run. The real $UserId is restored automatically on escalation.
$submitUser = if ($forceBadUser) {
    Write-Host "TEST HOOK: SS_TEST_FORCE_BAD_FIRST_USERNAME=true — first submit uses a deliberately invalid username"
    "$UserId-invalid"
} else {
    $UserId
}

Write-Host "Injecting credentials (clipboard paste): ID -> TAB -> Token -> ENTER..."
Invoke-CredentialSubmit -Handle $loginHandle -Otp $submitOtp -UserName $submitUser
Write-Host "Credentials submitted"
Write-Host ""

# Wait for the certificate; recover from any modal popup (invalid token / update)
Write-Host "Waiting for certificate to become available..."
$maxWaitSeconds = 180
$elapsed = 0
$match = $null
$retries = 0
# Modest cap, kept deliberately bounded: too many bad submissions can lock the
# Certum account, so this is NOT unbounded. Each recovery cycle waits for a fresh
# TOTP period (~30s) + validation, so 5 attempts comfortably fit the 180s window.
$maxRetries = 5

while ($elapsed -lt $maxWaitSeconds) {
    $signingCerts = Get-ChildItem -Path 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue |
        Where-Object { $_.EnhancedKeyUsageList -like '*Code Signing*' }

    $match = $signingCerts | Where-Object { $_.Thumbprint -eq $KeyId }

    if ($match) {
        Write-Host "Certificate available after $elapsed seconds"
        break
    }

    # A modal popup means the previous submit was rejected (or an update dialog
    # appeared). Dismiss it and re-submit with a fresh TOTP code.
    $popups = @(Get-SimplySignWindows | Where-Object { $_ -ne $loginHandle })
    if ($popups.Count -gt 0) {
        if ($retries -ge $maxRetries) {
            # Out of recovery attempts and the rejection dialog is still up — the
            # credential is being rejected every time (e.g. a bad token will never
            # recover). Fail fast with a precise reason instead of idling out the
            # remaining wait window doing nothing.
            Save-Screenshot -Stage "rejected"
            Write-WindowTitles -Context "credential rejected"
            Write-Error "Credential rejected $retries times (modal popup still present) — aborting. The submitted username/token was not accepted."
            exit 1
        }

        $retries++
        Write-Host ""
        Write-Host "Popup detected during wait (attempt $retries/$maxRetries) — recovering..."
        if (Resolve-Popup -LoginHandle $loginHandle) {
            Start-Sleep -Milliseconds 500
            $freshOtp = Get-FreshTotpCode
            if ($retries -eq 1) {
                # First recovery: SimplySign keeps the ID value and leaves the empty
                # Token field focused, so refill only the token — do NOT re-focus the
                # window or re-enter the ID (either moves input off the Token field).
                # This recovers a transient bad token while the username was correct.
                Write-Host "Re-submitting a fresh token into the focused Token field..."
                Invoke-TokenResubmit -Otp $freshOtp
            } else {
                # Still rejected after a token-only retry — the retained username may
                # itself be corrupt (token-only can never fix that). Escalate to a
                # full clean re-entry: re-focus resets Qt focus to the ID field, then
                # both username and token are cleared and re-pasted.
                Write-Host "Token-only retry still rejected — escalating to a full credential re-entry..."
                Invoke-CredentialSubmit -Handle $loginHandle -Otp $freshOtp
            }
        }
        Write-Host ""
    }

    Write-Host "Certificate not yet available, retrying... ($elapsed/$maxWaitSeconds seconds)"
    Start-Sleep -Seconds 5
    $elapsed += 5
}

if (-not $match) {
    Save-Screenshot -Stage "final-failure"
    Write-WindowTitles -Context "final failure"
    Write-Error "Certificate with thumbprint '$KeyId' not found after $maxWaitSeconds seconds"
    exit 1
}

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
