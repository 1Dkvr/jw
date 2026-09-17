<#
.SYNOPSIS
    JW Countdown - Lightweight multi-monitor countdown timer.

.DESCRIPTION
    JW Countdown displays a transparent countdown overlay on a selected monitor.

    The user only needs to:
        1. Select the meeting start time.
        2. Select the destination display.
        3. Optionally identify connected displays.
        4. Start the countdown.

    Countdown format:
        - Less than 1 hour remaining: MM:SS
        - 1 hour or more remaining:   HH:MM:SS

    If the selected meeting time has already passed today,
    the timer automatically targets the same time tomorrow.

.NOTES
    Product      : JW Countdown
    Component    : Main application
    Created      : 26.09.01
    Version      : 26.09.15
    Developer    : 1Dkvr
    Platform     : Microsoft Windows
    Runtime      : Windows PowerShell 5.1+
    Dependencies : System.Windows.Forms, System.Drawing
    License      : Proprietary

    Copyright © 2026 1Dkvr. All rights reserved.

    This software and its source code are proprietary and protected by
    applicable intellectual property laws.

    Unauthorized copying, modification, distribution, publication,
    sublicensing or commercial use is prohibited without prior authorization
    from the copyright holder.

    No external module or third-party dependency is required.
#>
# =====================================================================
# 1. INITIALIZATION
# =====================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =====================================================================
# 2. APPLICATION CONSTANTS
# =====================================================================
$script:AppName = "JW Countdown"
$script:Version = "26.09.15"
$script:Developer = "1Dkvr"

# =====================================================================
# 2.1. SINGLE TIMER INSTANCE
# =====================================================================
$script:TimerMutex = New-Object System.Threading.Mutex($false, "JWCountdown.SingleTimer")
$script:TimerMutexOwned = $false
if(-not $script:TimerMutex.WaitOne(0, $false)){
    [System.Windows.Forms.MessageBox]::Show("A JW Countdown is already running.", $script:AppName, "OK", "Information")
    exit
}
$script:TimerMutexOwned = $true

$script:SelectedScreenIndex = 0

# =====================================================================
# 3. UI COLORS
# =====================================================================
$ColorBackground = [System.Drawing.Color]::FromArgb(245, 247, 250)
$ColorSurface = [System.Drawing.Color]::White

$ColorTextPrimary = [System.Drawing.Color]::FromArgb(30, 35, 45)
$ColorTextSecondary = [System.Drawing.Color]::FromArgb(100, 110, 125)

$ColorBorder = [System.Drawing.Color]::FromArgb(215, 220, 228)

$ColorAccent = [System.Drawing.Color]::FromArgb(37, 99, 235)
$ColorAccentLight = [System.Drawing.Color]::FromArgb(235, 243, 255)

$ColorWhite = [System.Drawing.Color]::White
$ColorBlack = [System.Drawing.Color]::Black
$ColorTimer = [System.Drawing.Color]::Silver

# =====================================================================
# 4. CONSOLE HIDING
# =====================================================================
$consoleInterop = @'
using System;
using System.Runtime.InteropServices;

public static class JWCountdownConsole
{
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(
        IntPtr hWnd,
        int nCmdShow
    );
}
'@

try {
    Add-Type -TypeDefinition $consoleInterop -Language CSharp -ErrorAction SilentlyContinue
} catch {
    [System.Diagnostics.Debug]::WriteLine("[JW Countdown] Unable to initialize console interop.")
}

try {
    $consoleWindow = [JWCountdownConsole]::GetConsoleWindow()
    if($consoleWindow -ne [IntPtr]::Zero){
        [JWCountdownConsole]::ShowWindow($consoleWindow, 0) | Out-Null
    }
} catch {
    [System.Diagnostics.Debug]::WriteLine(
        "[JW Countdown] Unable to hide the PowerShell console window."
    )
}

# =====================================================================
# 5. FONT HELPER
# =====================================================================
function New-JWFont {
    param([float]$Size, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    return New-Object System.Drawing.Font("Arial", $Size, $Style)
}

# =====================================================================
# 6. CONNECTED DISPLAYS
# =====================================================================
$screens = [System.Windows.Forms.Screen]::AllScreens

if($screens.Count -eq 0){
    [System.Windows.Forms.MessageBox]::Show("No display was detected.", $script:AppName, "OK", "Error")
    exit
}

# =====================================================================
# 7. DISPLAY IDENTIFICATION
# =====================================================================
function Show-DisplayIdentification {
    param([System.Windows.Forms.Screen[]]$Displays)
    $identifierWindows = @()
    try {
        for($i=0; $i -lt $Displays.Count; $i++){
            $screen = $Displays[$i]
            $identifierForm = New-Object System.Windows.Forms.Form
            $identifierForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
            $identifierForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
            $identifierForm.Bounds = $screen.Bounds
            $identifierForm.TopMost = $true
            $identifierForm.ShowInTaskbar = $false
            $identifierForm.BackColor = [System.Drawing.Color]::Black
            $identifierLabel = New-Object System.Windows.Forms.Label
            $identifierLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $identifierLabel.Text = ($i + 1).ToString()
            $identifierLabel.ForeColor = [System.Drawing.Color]::White
            $identifierLabel.BackColor = [System.Drawing.Color]::Black
            $identifierLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
            $identifierLabel.Font = New-JWFont -Size 150 -Style ([System.Drawing.FontStyle]::Bold)
            $identifierForm.Controls.Add($identifierLabel)
            $identifierWindows += $identifierForm
            $identifierForm.Show()
        }

        #
        # Force all identification windows to render before waiting.
        #
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 1800
    } finally {
        foreach($identifierForm in $identifierWindows){
            if($null -ne $identifierForm -and -not $identifierForm.IsDisposed){
                $identifierForm.Close()
                $identifierForm.Dispose()
            }
        }
    }
}

# =====================================================================
# 8. COUNTDOWN OVERLAY
# =====================================================================
function Show-CountdownOverlay {
    param([System.Windows.Forms.Screen]$Display, [datetime]$TargetTime)

    # -----------------------------------------------------------------
    # Overlay window
    # -----------------------------------------------------------------
    $overlay = New-Object System.Windows.Forms.Form
    $overlay.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $overlay.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $overlay.TopMost = $true
    $overlay.ShowInTaskbar = $false
    $overlay.KeyPreview = $true

    #
    # Black is used as the transparency key.
    #
    $overlay.BackColor = $ColorBlack
    $overlay.TransparencyKey = $ColorBlack

    #
    # The overlay occupies the bottom 25% of the selected monitor,
    # preserving the behavior of the original JW Countdown implementation.
    #
    $overlayHeight = [int]($Display.Bounds.Height * 0.25)

    $overlay.Left = $Display.Bounds.X
    $overlay.Width = $Display.Bounds.Width
    $overlay.Height = $overlayHeight
    $overlay.Top = $Display.Bounds.Y + $Display.Bounds.Height - $overlayHeight

    # -----------------------------------------------------------------
    # Countdown label
    # -----------------------------------------------------------------
    $timerLabel = New-Object System.Windows.Forms.Label
    $timerLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $timerLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $timerLabel.BackColor = $ColorBlack
    $timerLabel.ForeColor = $ColorTimer
    $timerLabel.Font = New-JWFont -Size 45 -Style ([System.Drawing.FontStyle]::Regular)
    $timerLabel.Text = "00:00"
    $overlay.Controls.Add($timerLabel)

    # -----------------------------------------------------------------
    # Emergency close actions
    # -----------------------------------------------------------------
    $timerLabel.Add_DoubleClick({$overlay.Close()})
    $overlay.Add_KeyDown({
        if($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape){
            $overlay.Close()
        }
    })

    # -----------------------------------------------------------------
    # Countdown timer
    # -----------------------------------------------------------------
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $now = [datetime]::Now
        $remaining = $TargetTime - $now

        #
        # Stop automatically when the meeting starts.
        #
        if($remaining.TotalSeconds -le 0){
            $timer.Stop()
            $overlay.Close()
            return
        }

        if($remaining.TotalHours -ge 1){ # 1 hour or more : HH:MM:SS
            $totalHours = [int][Math]::Floor($remaining.TotalHours)
            $timerLabel.Text = "{0:D2}:{1:D2}:{2:D2}" -f $totalHours, $remaining.Minutes, $remaining.Seconds
        } else { # Less than 1 hour : MM:SS
            $totalMinutes = [int][Math]::Floor($remaining.TotalMinutes)
            $timerLabel.Text = "{0:D2}:{1:D2}" -f $totalMinutes,$remaining.Seconds
        }
    })

    # -----------------------------------------------------------------
    # Render the initial countdown immediately
    # -----------------------------------------------------------------
    $initialRemaining = $TargetTime - [datetime]::Now
    if($initialRemaining.TotalHours -ge 1){
        $initialHours = [int][Math]::Floor($initialRemaining.TotalHours)
        $timerLabel.Text = "{0:D2}:{1:D2}:{2:D2}" -f $initialHours, $initialRemaining.Minutes, $initialRemaining.Seconds
    } else {
        $initialMinutes = [int][Math]::Floor($initialRemaining.TotalMinutes)
        $timerLabel.Text = "{0:D2}:{1:D2}" -f $initialMinutes, $initialRemaining.Seconds
    }

    # -----------------------------------------------------------------
    # Cleanup
    # -----------------------------------------------------------------
    $overlay.Add_FormClosed({$timer.Stop()})

    # -----------------------------------------------------------------
    # Run overlay
    # -----------------------------------------------------------------
    $timer.Start()

    try {
        $overlay.ShowDialog() | Out-Null
    } finally {
        $timer.Stop()
        $timer.Dispose()
        $timerLabel.Dispose()
        $overlay.Dispose()
    }
}

# =====================================================================
# 9. MAIN WINDOW
# =====================================================================
$setupForm = New-Object System.Windows.Forms.Form
$setupForm.Text = $script:AppName
$setupForm.Size = New-Object System.Drawing.Size(620, 660)
$setupForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$setupForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$setupForm.MaximizeBox = $false
$setupForm.MinimizeBox = $true
$setupForm.BackColor = $ColorBackground
$setupForm.Font = New-JWFont -Size 10

# =====================================================================
# 10. HEADER
# =====================================================================
$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "JW Countdown"
$titleLabel.Location = New-Object System.Drawing.Point(30, 25)
$titleLabel.AutoSize = $true
$titleLabel.Font = New-JWFont -Size 23 -Style ([System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = $ColorTextPrimary

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "Simple countdown for meetings start"
$subtitleLabel.Location = New-Object System.Drawing.Point(32, 68)
$subtitleLabel.AutoSize = $true
$subtitleLabel.Font = New-JWFont -Size 9
$subtitleLabel.ForeColor = $ColorTextSecondary

# =====================================================================
# 11. TIME SECTION
# =====================================================================
$timePanel = New-Object System.Windows.Forms.Panel
$timePanel.Location = New-Object System.Drawing.Point(30, 110)
$timePanel.Size = New-Object System.Drawing.Size(545, 125)
$timePanel.BackColor = $ColorSurface
$timePanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$timeTitle = New-Object System.Windows.Forms.Label
$timeTitle.Text = "Meeting start time"
$timeTitle.Location = New-Object System.Drawing.Point(18, 15)
$timeTitle.AutoSize = $true
$timeTitle.Font = New-JWFont -Size 11 -Style ([System.Drawing.FontStyle]::Bold)
$timeTitle.ForeColor = $ColorTextPrimary

$timeDescription = New-Object System.Windows.Forms.Label
$timeDescription.Text = "Select the time when the meeting is scheduled to begin."
$timeDescription.Location = New-Object System.Drawing.Point(18, 42)
$timeDescription.AutoSize = $true
$timeDescription.Font = New-JWFont -Size 8.5
$timeDescription.ForeColor = $ColorTextSecondary

# ---------------------------------------------------------------------
# Native time selector
# ---------------------------------------------------------------------
$timePicker = New-Object System.Windows.Forms.DateTimePicker
$timePicker.Location = New-Object System.Drawing.Point(18, 72)
$timePicker.Size = New-Object System.Drawing.Size(160, 35)
$timePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$timePicker.CustomFormat = "HH:mm"

#
# ShowUpDown removes free keyboard-style date entry and gives
# the user a compact native time selector.
#
$timePicker.ShowUpDown = $true
$timePicker.Font = New-JWFont -Size 13
#
# Default to approximately 30 minutes from now.
#
$timePicker.Value = [datetime]::Now.AddMinutes(30)

$timePanel.Controls.Add($timeTitle)
$timePanel.Controls.Add($timeDescription)
$timePanel.Controls.Add($timePicker)

# =====================================================================
# 12. DISPLAY SECTION
# =====================================================================
$displayPanel = New-Object System.Windows.Forms.Panel
$displayPanel.Location = New-Object System.Drawing.Point(30, 250)
$displayPanel.Size = New-Object System.Drawing.Size(545, 265)
$displayPanel.BackColor = $ColorSurface
$displayPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$displayTitle = New-Object System.Windows.Forms.Label
$displayTitle.Text = "Destination display"
$displayTitle.Location = New-Object System.Drawing.Point(18, 15)
$displayTitle.AutoSize = $true
$displayTitle.Font = New-JWFont -Size 11 -Style ([System.Drawing.FontStyle]::Bold)
$displayTitle.ForeColor = $ColorTextPrimary

$displayDescription = New-Object System.Windows.Forms.Label
$displayDescription.Text = "Select where the countdown should appear."
$displayDescription.Location = New-Object System.Drawing.Point(18, 42)
$displayDescription.AutoSize = $true
$displayDescription.Font = New-JWFont -Size 8.5
$displayDescription.ForeColor = $ColorTextSecondary

# ---------------------------------------------------------------------
# Display cards
# ---------------------------------------------------------------------
$screenFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$screenFlow.Location = New-Object System.Drawing.Point(18, 72)
$screenFlow.Size = New-Object System.Drawing.Size(505, 125)
$screenFlow.BackColor = $ColorSurface
$screenFlow.AutoScroll = $true
$screenFlow.WrapContents = $false
$screenFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$screenButtons = @()

# =====================================================================
# 13. SCREEN SELECTION VISUAL UPDATE
# =====================================================================
function Update-ScreenSelection {
    for($buttonIndex = 0; $buttonIndex -lt $screenButtons.Count; $buttonIndex++){
        $screenButton = $screenButtons[$buttonIndex]
        if($buttonIndex -eq $script:SelectedScreenIndex){
            $screenButton.BackColor = $ColorAccentLight
            $screenButton.FlatAppearance.BorderColor = $ColorAccent
            $screenButton.FlatAppearance.BorderSize = 2
        } else {
            $screenButton.BackColor = $ColorSurface
            $screenButton.FlatAppearance.BorderColor = $ColorBorder
            $screenButton.FlatAppearance.BorderSize = 1
        }
    }
}

# =====================================================================
# 14. CREATE DISPLAY CARDS
# =====================================================================
for($i = 0; $i -lt $screens.Count; $i++){
    $screen = $screens[$i]
    $screenNumber = $i + 1

    if($screen.Primary){
        $screenType = "Primary display"
    } else {
        $screenType = "Display"
    }

    $resolution = "$($screen.Bounds.Width) x $($screen.Bounds.Height)"

    $screenButton = New-Object System.Windows.Forms.Button
    $screenButton.Size = New-Object System.Drawing.Size(145, 100)
    $screenButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)

    $screenButton.Text = "$screenNumber`r`n$screenType`r`n$resolution"
    $screenButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

    $screenButton.Font = New-JWFont -Size 9 -Style ([System.Drawing.FontStyle]::Bold)
    $screenButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $screenButton.FlatAppearance.BorderColor = $ColorBorder
    $screenButton.FlatAppearance.BorderSize = 1
    $screenButton.BackColor = $ColorSurface
    $screenButton.ForeColor = $ColorTextPrimary
    $screenButton.Cursor = [System.Windows.Forms.Cursors]::Hand

    # ---------------------------------------------------------------
    # Store the monitor index directly on the button.
    # ---------------------------------------------------------------
    $screenButton.Tag = $i

    # ---------------------------------------------------------------
    # When clicked, read the index directly from the clicked button.
    # This avoids any closure/captured-variable issue.
    # ---------------------------------------------------------------
    $screenButton.Add_Click({
        $script:SelectedScreenIndex = [int]$this.Tag
        Update-ScreenSelection
    })

    $screenButtons += $screenButton
    $screenFlow.Controls.Add($screenButton)
}

Update-ScreenSelection

# =====================================================================
# 15. IDENTIFY DISPLAYS BUTTON
# =====================================================================
$identifyButton = New-Object System.Windows.Forms.Button
$identifyButton.Text = "IDENTIFY DISPLAYS"
$identifyButton.Location = New-Object System.Drawing.Point(18, 210)
$identifyButton.Size = New-Object System.Drawing.Size(180, 38)
$identifyButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$identifyButton.FlatAppearance.BorderColor = $ColorBorder
$identifyButton.FlatAppearance.BorderSize = 1
$identifyButton.BackColor = $ColorSurface
$identifyButton.ForeColor = $ColorTextPrimary
$identifyButton.Font = New-JWFont -Size 8.5 -Style ([System.Drawing.FontStyle]::Bold)
$identifyButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$identifyButton.Add_Click({
    $identifyButton.Enabled = $false
    $startButton.Enabled = $false
    try {
        Show-DisplayIdentification -Displays $screens
    } finally {
        $identifyButton.Enabled = $true
        $startButton.Enabled = $true
    }
})

$displayPanel.Controls.Add($displayTitle)
$displayPanel.Controls.Add($displayDescription)
$displayPanel.Controls.Add($screenFlow)
$displayPanel.Controls.Add($identifyButton)

# =====================================================================
# 16. START BUTTON
# =====================================================================
$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = "START TIMER"
$startButton.Location = New-Object System.Drawing.Point(30, 535)
$startButton.Size = New-Object System.Drawing.Size(545, 50)
$startButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$startButton.FlatAppearance.BorderSize = 0
$startButton.BackColor = $ColorAccent
$startButton.ForeColor = $ColorWhite
$startButton.Font = New-JWFont -Size 11 -Style ([System.Drawing.FontStyle]::Bold)
$startButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$startButton.Add_Click({
    try {
        $now = [datetime]::Now
        $selectedTime = $timePicker.Value

        #
        # Build today's target using the selected hour and minute.
        #
        $targetTime = [datetime]::new($now.Year, $now.Month, $now.Day, $selectedTime.Hour, $selectedTime.Minute, 0)

        #
        # Windows PowerShell 5.1 does not support the C#-style ::new()
        # syntax reliably on all target systems, so fallback if required.
        #
    } catch {
        $targetTime = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $selectedTime.Hour -Minute $selectedTime.Minute -Second 0
    }

    #
    # If the selected time already passed today,
    # schedule the next occurrence tomorrow.
    #
    if($targetTime -le $now){
        $targetTime = $targetTime.AddDays(1)
    }


    if($script:SelectedScreenIndex -lt 0 -or $script:SelectedScreenIndex -ge $screens.Count){
        [System.Windows.Forms.MessageBox]::Show("Please select a valid destination display.", $script:AppName, "OK", "Warning")
        return
    }

    $selectedScreen = $screens[$script:SelectedScreenIndex]

    #
    # Hide configuration while countdown is running.
    #
    $setupForm.Hide()

    try {
        Show-CountdownOverlay -Display $selectedScreen -TargetTime $targetTime
    } finally {
        if(-not $setupForm.IsDisposed){
            #$setupForm.Show()
            #$setupForm.Activate()
        }
    }
})

# =====================================================================
# 17. FOOTER
# =====================================================================
$footerLabel = New-Object System.Windows.Forms.Label
# $footerLabel.Text = "JW Countdown $($script:Version)  |  Developed by $($script:Developer)"
$footerLabel.Text = "v$($script:Version)"
$footerLabel.Location = New-Object System.Drawing.Point(30, 595)
$footerLabel.AutoSize = $true
$footerLabel.Font = New-JWFont -Size 8
$footerLabel.ForeColor = $ColorTextSecondary

# =====================================================================
# 18. ADD CONTROLS
# =====================================================================
$setupForm.Controls.Add($titleLabel)
$setupForm.Controls.Add($subtitleLabel)
$setupForm.Controls.Add($timePanel)
$setupForm.Controls.Add($displayPanel)
$setupForm.Controls.Add($startButton)
$setupForm.Controls.Add($footerLabel)
$setupForm.AcceptButton = $startButton

# =====================================================================
# 19. RUN APPLICATION
# =====================================================================
try {
    $setupForm.ShowDialog() | Out-Null
} finally {
    $setupForm.Dispose()
}

# =====================================================================
# 20. RELEASE SINGLE TIMER INSTANCE
# =====================================================================
if($script:TimerMutexOwned){
    try {
        $script:TimerMutex.ReleaseMutex()
    } catch {
        [System.Diagnostics.Debug]::WriteLine("[JW Countdown] Unable to release the single-instance mutex.")
    }
}
try {
    $script:TimerMutex.Dispose()
} catch {
    [System.Diagnostics.Debug]::WriteLine("[JW Countdown] Unable to dispose the single-instance mutex.")
}
