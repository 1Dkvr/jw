<#
.SYNOPSIS
    JW Countdown - Lightweight multi-monitor countdown timer.

.DESCRIPTION
    JW Countdown displays a transparent countdown overlay simultaneously on one or more selected monitors.

    The user only needs to:
        1. Select the meeting start time.
        2. Select one or more destination displays.
        3. Optionally identify connected displays.
        4. Start the countdown.

    Display selection:
        - Click a display card to select or deselect it.
        - Multiple displays can be selected simultaneously.
        - "SELECT ALL" selects every connected display.
        - "CLEAR SELECTION" removes all display selections.

    Countdown behavior:
        - Every selected display receives its own overlay.
        - All overlays use the same target time and timer.
        - All displays therefore remain synchronized.
        - Less than 1 hour remaining: MM:SS
        - 1 hour or more remaining: HH:MM:SS

    Target-time behavior:
        - If the selected meeting time has already passed today,
          the timer automatically targets the same time tomorrow.

    Overlay behavior:
        - The countdown is displayed in the lower 25% of each selected monitor.
        - The overlay is borderless, always-on-top and visually transparent.
        - Double-clicking or closing any countdown overlay closes the full session.
        - Pressing Escape closes the full countdown session.
        - When the countdown reaches zero, all overlays close automatically.
        - If a selected display disappears or its display bounds change while
          the countdown is running, the current countdown session is closed
          cleanly.

    Application lifecycle:
        - Only one JW Countdown process may run in the current Windows session.
        - Starting a second instance displays an informational message and exits.
        - Once a countdown session has started, the setup window is never shown again.
        - When the countdown ends or is closed, the application exits cleanly.

    DPI behavior:
        - Per-Monitor DPI awareness is enabled when supported by Windows.
        - The application falls back to the older Per-Monitor DPI API when needed.
        - A final System-DPI-aware fallback is used for older or restricted systems.

    Release metadata:
        - Application identity and release version are defined in one place.
        - No release version is hard-coded elsewhere in the application.
        - The metadata structure is intended to be consumed by future
          release and update tooling.

.NOTES
    Product      : JW Countdown
    Component    : Main application
    Created      : 26.09.01
    Developer    : 1Dkvr
    Licensor     : Hold'inCorp.
    Platform     : Microsoft Windows
    Runtime      : Windows PowerShell 5.1+
    Dependencies : System.Windows.Forms, System.Drawing
    License      : Custom Non-Commercial Source-Available
    License URL  : https://github.com/1Dkvr/jw/blob/main/LICENSE.md

    Copyright © 2026 [Licensor]. All rights reserved.

    This source code is subject to the terms and conditions defined in the 'LICENSE.md' file located in the root directory of this repository or online at at the URL above.
    No external module or third-party dependency is required.
    Future release tooling may add package integrity and Authenticode signature verification without changing the countdown application itself.
#>
Set-StrictMode -Version Latest

# =====================================================================
# 1. INITIALIZATION
# =====================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =====================================================================
# 2. APPLICATION METADATA
# =====================================================================
#
# Keep release information in one place. Future build tooling can update this block without having to modify the application logic.
#
$script:ApplicationMetadata = [ordered]@{
    Name      = "JW Countdown"
    Version   = "26.09.20"
    Developer = "1Dkvr"
}

$script:AppName   = $script:ApplicationMetadata.Name
$script:Version   = $script:ApplicationMetadata.Version
$script:Developer = $script:ApplicationMetadata.Developer

# =====================================================================
# 2.1. APPLICATION CONSTANTS
# =====================================================================
$script:MutexName = "Local\JWCountdown.SingleTimer"
$script:DisplayIdentificationDuration = 1800
$script:CountdownTimerInterval = 1000
$script:OverlayHeightRatio = 0.25

# =====================================================================
# 2.2. SINGLE APPLICATION INSTANCE
# =====================================================================
#
# The mutex is explicitly scoped to the current Windows session. A second JW Countdown may therefore run in another Windows session.
#
$script:TimerMutex = New-Object System.Threading.Mutex($false, $script:MutexName)
$script:TimerMutexOwned = $false

try {
    try {
        $mutexAcquired = $script:TimerMutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $mutexAcquired = $true
    }

    if(-not $mutexAcquired){
        [System.Windows.Forms.MessageBox]::Show(
            "A $($script:AppName) is already running.",
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null

        return
    }

    $script:TimerMutexOwned = $true

    # =================================================================
    # 2.3. DISPLAY SELECTION STATE
    # =================================================================
    $script:SelectedScreenIndexes = New-Object System.Collections.Generic.List[int]
    $script:ScreenButtons = @()

    # =================================================================
    # 2.4. COUNTDOWN STATE
    # =================================================================
    $script:CountdownClosing = $false

    # =================================================================
    # 3. UI COLORS
    # =================================================================
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

    # =================================================================
    # 4. WINDOWS NATIVE INTEROP
    # =================================================================
    #
    # Keep native calls together so platform-specific behavior remains isolated from the application logic.
    #
    $nativeInterop = @'
using System;
using System.Runtime.InteropServices;

public static class JWCountdownNative {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindow(
        IntPtr hWnd,
        int nCmdShow
    );

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetProcessDpiAwarenessContext(
        IntPtr dpiContext
    );

    [DllImport("shcore.dll")]
    private static extern int SetProcessDpiAwareness(
        int value
    );

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetProcessDPIAware();

    public static bool EnablePerMonitorDpiAwareness(){
        try {
            // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
            if(SetProcessDpiAwarenessContext(new IntPtr(-4))){
                return true;
            }
        } catch (EntryPointNotFoundException) {
        } catch (DllNotFoundException) {
        }

        try {
            // PROCESS_PER_MONITOR_DPI_AWARE
            if(SetProcessDpiAwareness(2) == 0){
                return true;
            }
        } catch (DllNotFoundException) {
        }

        try {
            // Final fallback for older systems.
            return SetProcessDPIAware();
        } catch {
            return false;
        }
    }
}
'@

    try {
        Add-Type `
            -TypeDefinition $nativeInterop `
            -Language CSharp `
            -ErrorAction Stop
    }
    catch {
        [System.Diagnostics.Debug]::WriteLine("[$($script:AppName)] Unable to initialize Windows native interop.")
    }

    # =================================================================
    # 4.1. DPI CONFIGURATION
    # =================================================================
    try {
        if([JWCountdownNative]::EnablePerMonitorDpiAwareness()){
            [System.Diagnostics.Debug]::WriteLine("[$($script:AppName)] Per-monitor DPI awareness enabled.")
        } else {
            [System.Diagnostics.Debug]::WriteLine("[$($script:AppName)] Unable to enable DPI awareness.")
        }
    } catch {
        [System.Diagnostics.Debug]::WriteLine("[$($script:AppName)] Unable to configure DPI awareness.")
    }

    # =================================================================
    # 4.2. CONSOLE HIDING
    # =================================================================
    try {
        $consoleWindow = [JWCountdownNative]::GetConsoleWindow()

        if($consoleWindow -ne [IntPtr]::Zero){
            [JWCountdownNative]::ShowWindow($consoleWindow, 0) | Out-Null
        }
    } catch {
        [System.Diagnostics.Debug]::WriteLine("[$($script:AppName)] Unable to hide the PowerShell console window.")
    }

    # =================================================================
    # 5. HELPER FUNCTIONS
    # =================================================================
    function New-JWFont {
        param(
            [Parameter(Mandatory = $true)]
            [float]$Size,

            [System.Drawing.FontStyle]$Style =
                [System.Drawing.FontStyle]::Regular
        )

        return New-Object System.Drawing.Font("Arial", $Size, $Style)
    }


    function Show-JWMessage {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Message,

            [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK,

            [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
        )

        return [System.Windows.Forms.MessageBox]::Show($Message, $script:AppName, $Buttons, $Icon)
    }

    # =================================================================
    # 6. CONNECTED DISPLAYS
    # =================================================================
    $screens = [System.Windows.Forms.Screen]::AllScreens

    if($null -eq $screens -or $screens.Count -eq 0){
        Show-JWMessage `
            -Message "No display was detected." `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Error) |
            Out-Null

        return
    }

    # Select the primary display by default.
    #
    for($i = 0; $i -lt $screens.Count; $i++){
        if($screens[$i].Primary){
            $script:SelectedScreenIndexes.Add($i)
            break
        }
    }

    if($script:SelectedScreenIndexes.Count -eq 0){
        $script:SelectedScreenIndexes.Add(0)
    }

    # =================================================================
    # 7. DISPLAY IDENTIFICATION
    # =================================================================
    function Show-DisplayIdentification {
        param(
            [Parameter(Mandatory = $true)]
            [System.Windows.Forms.Screen[]]$Displays
        )

        $identifierWindows = @()

        try {
            for($i = 0; $i -lt $Displays.Count; $i++){
                $screen = $Displays[$i]
                $identifierForm = New-Object System.Windows.Forms.Form
                $identifierForm.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
                $identifierForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
                $identifierForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
                $identifierForm.Bounds = $screen.Bounds
                $identifierForm.TopMost = $true
                $identifierForm.ShowInTaskbar = $false
                $identifierForm.BackColor = $ColorBlack

                $identifierLabel = New-Object System.Windows.Forms.Label
                $identifierLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
                $identifierLabel.Text = ($i + 1).ToString()
                $identifierLabel.ForeColor = [System.Drawing.Color]::White
                $identifierLabel.BackColor = $ColorBlack
                $identifierLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
                $identifierLabel.Font = New-JWFont -Size 150 -Style ([System.Drawing.FontStyle]::Bold)
                $identifierForm.Controls.Add($identifierLabel)
                
                $identifierWindows += $identifierForm
                $identifierForm.Show()
            }

            [System.Windows.Forms.Application]::DoEvents()

            Start-Sleep -Milliseconds $script:DisplayIdentificationDuration
        }
        finally {
            foreach($identifierForm in $identifierWindows){
                if($null -ne $identifierForm -and -not $identifierForm.IsDisposed){
                    try {
                        $identifierForm.Close()
                    } catch {
                    }

                    try {
                        $identifierForm.Dispose()
                    } catch {
                    }
                }
            }
        }
    }

    # =================================================================
    # 8. COUNTDOWN HELPERS
    # =================================================================
    function Get-JWCountdownText {
        param(
            [Parameter(Mandatory = $true)]
            [timespan]$Remaining
        )

        if($Remaining.TotalSeconds -le 0){ return "00:00" }

        if($Remaining.TotalHours -ge 1){
            $totalHours = [int][Math]::Floor($Remaining.TotalHours)
            return "{0:D2}:{1:D2}:{2:D2}" -f $totalHours, $Remaining.Minutes, $Remaining.Seconds
        }

        $totalMinutes = [int][Math]::Floor($Remaining.TotalMinutes)
        return "{0:D2}:{1:D2}" -f $totalMinutes, $Remaining.Seconds
    }


    function Get-JWDisplaySignature {
        param(
            [Parameter(Mandatory = $true)]
            [System.Windows.Forms.Screen]$Display
        )

        return "{0}|{1}|{2}|{3}|{4}" -f `
            $Display.DeviceName,
            $Display.Bounds.X,
            $Display.Bounds.Y,
            $Display.Bounds.Width,
            $Display.Bounds.Height
    }


    function Test-JWDisplayConfiguration {
        param(
            [Parameter(Mandatory = $true)]
            [System.Windows.Forms.Screen[]]$Displays,

            [Parameter(Mandatory = $true)]
            [hashtable]$OriginalSignatures
        )

        $currentScreens = [System.Windows.Forms.Screen]::AllScreens

        foreach($display in $Displays){
            $currentDisplay = $currentScreens | Where-Object {$_.DeviceName -eq $display.DeviceName} | Select-Object -First 1

            if($null -eq $currentDisplay){ return $false }

            $currentSignature = Get-JWDisplaySignature -Display $currentDisplay

            if($currentSignature -ne $OriginalSignatures[$display.DeviceName]){ return $false }
        }

        return $true
    }


    function Close-JWCountdownOverlays {
        param(
            [Parameter(Mandatory = $true)]
            [System.Windows.Forms.Form[]]$Overlays,

            [Parameter(Mandatory = $true)]
            [System.Windows.Forms.Timer]$Timer
        )

        if($script:CountdownClosing){ return }

        $script:CountdownClosing = $true

        try {
            if($null -ne $Timer){ $Timer.Stop() }

            foreach($overlay in $Overlays){
                if($null -ne $overlay -and -not $overlay.IsDisposed){
                    $overlay.Close()
                }
            }
        }
        catch {
            [System.Diagnostics.Debug]::WriteLine("[$($script:AppName)] Error while closing countdown overlays: $($_.Exception.Message)")
        }
    }

    # =================================================================
    # 9. MULTI-DISPLAY COUNTDOWN OVERLAY
    # =================================================================
    #
    # All overlay creation, execution and cleanup lives inside one try/finally block so an unexpected error cannot leave resources behind.
    #
    function Show-CountdownOverlays {
        param(
            [Parameter(Mandatory = $true)]
            [System.Windows.Forms.Screen[]]$Displays,

            [Parameter(Mandatory = $true)]
            [datetime]$TargetTime
        )

        $overlayWindows = @()
        $timerLabels = @()
        $timer = $null
        $originalSignatures = @{}

        foreach($display in $Displays){
            $originalSignatures[$display.DeviceName] = Get-JWDisplaySignature -Display $display
        }

        try {
            $timer = New-Object System.Windows.Forms.Timer
            $timer.Interval = $script:CountdownTimerInterval

            foreach($display in $Displays){
                $overlay = New-Object System.Windows.Forms.Form
                $overlay.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
                $overlay.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
                $overlay.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
                $overlay.TopMost = $true
                $overlay.ShowInTaskbar = $false
                $overlay.KeyPreview = $true
                $overlay.BackColor = $ColorBlack
                $overlay.TransparencyKey = $ColorBlack
                
                $overlayHeight = [int]($display.Bounds.Height * $script:OverlayHeightRatio)
                $overlay.Left = $display.Bounds.X
                $overlay.Top = $display.Bounds.Y + $display.Bounds.Height - $overlayHeight
                $overlay.Width = $display.Bounds.Width
                $overlay.Height = $overlayHeight

                $timerLabel = New-Object System.Windows.Forms.Label
                $timerLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
                $timerLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
                $timerLabel.BackColor = $ColorBlack
                $timerLabel.ForeColor = $ColorTimer
                $timerLabel.Font = New-JWFont -Size 45 -Style ([System.Drawing.FontStyle]::Regular)
                $timerLabel.Text = "00:00"
                $overlay.Controls.Add($timerLabel)

                # Closing any one overlay ends the full countdown session.
                #
                $overlay.Add_FormClosed({
                    Close-JWCountdownOverlays `
                        -Overlays $overlayWindows `
                        -Timer $timer
                })

                $overlay.Add_DoubleClick({
                    Close-JWCountdownOverlays `
                        -Overlays $overlayWindows `
                        -Timer $timer
                })

                $timerLabel.Add_DoubleClick({
                    Close-JWCountdownOverlays `
                        -Overlays $overlayWindows `
                        -Timer $timer
                })

                $overlay.Add_KeyDown({
                    if($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape){
                        Close-JWCountdownOverlays `
                            -Overlays $overlayWindows `
                            -Timer $timer
                    }
                })

                $overlayWindows += $overlay
                $timerLabels += $timerLabel
            }

            $timer.Add_Tick({
                # Display changes are checked before updating the labels.
                # This prevents orphaned windows after a monitor is removed or its desktop bounds change during the countdown.
                #
                if(
                    -not (
                        Test-JWDisplayConfiguration `
                            -Displays $Displays `
                            -OriginalSignatures $originalSignatures
                    )
                ){
                    [System.Diagnostics.Debug]::WriteLine("[$($script:AppName)] Display configuration changed during countdown.")

                    Close-JWCountdownOverlays `
                        -Overlays $overlayWindows `
                        -Timer $timer

                    return
                }

                $remaining = $TargetTime - [datetime]::Now

                if($remaining.TotalSeconds -le 0){
                    Close-JWCountdownOverlays `
                        -Overlays $overlayWindows `
                        -Timer $timer

                    return
                }

                $countdownText = Get-JWCountdownText -Remaining $remaining

                foreach($label in $timerLabels){
                    if($null -ne $label -and -not $label.IsDisposed){
                        $label.Text = $countdownText
                    }
                }
            })

            # Show the correct value immediately.
            #
            $initialRemaining = $TargetTime - [datetime]::Now
            $initialText = Get-JWCountdownText -Remaining $initialRemaining

            foreach($label in $timerLabels){
                $label.Text = $initialText
            }

            # Show all overlays except the first one. The first overlay
            # owns the modal message loop for the countdown session.
            #
            for($overlayIndex = 1; $overlayIndex -lt $overlayWindows.Count; $overlayIndex++){
                $overlayWindows[$overlayIndex].Show()
            }

            $timer.Start()

            if($overlayWindows.Count -gt 0){
                $overlayWindows[0].ShowDialog() | Out-Null
            }
        } finally {
            if($null -ne $timer){ $timer.Stop() }

            foreach($overlay in $overlayWindows){
                if($null -ne $overlay -and -not $overlay.IsDisposed){
                    try {
                        $overlay.Close()
                    } catch {
                        # The overlay may already have been closed.
                    }
                }
            }

            foreach($overlay in $overlayWindows ){
                if($null -ne $overlay -and -not $overlay.IsDisposed){
                    try {
                        $overlay.Dispose()
                    } catch {
                    }
                }
            }

            foreach($label in $timerLabels){
                if($null -ne $label -and -not $label.IsDisposed){
                    try {
                        $label.Dispose()
                    } catch {
                    }
                }
            }

            if($null -ne $timer){
                try {
                    $timer.Dispose()
                } catch {
                }
            }

            $script:CountdownClosing = $false
        }
    }

    # =================================================================
    # 10. MAIN WINDOW
    # =================================================================
    $setupForm = New-Object System.Windows.Forms.Form
    $setupForm.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $setupForm.Text = $script:AppName
    $setupForm.Size = New-Object System.Drawing.Size(620, 660)
    $setupForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $setupForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $setupForm.MaximizeBox = $false
    $setupForm.MinimizeBox = $true
    $setupForm.BackColor = $ColorBackground
    $setupForm.Font = New-JWFont -Size 10

    # =================================================================
    # 11. HEADER
    # =================================================================
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $script:AppName
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

    # =================================================================
    # 12. TIME SECTION
    # =================================================================
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

    $timePicker = New-Object System.Windows.Forms.DateTimePicker
    $timePicker.Location = New-Object System.Drawing.Point(18, 72)
    $timePicker.Size = New-Object System.Drawing.Size(160, 35)
    $timePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
    $timePicker.CustomFormat = "HH:mm"
    $timePicker.ShowUpDown = $true
    $timePicker.Font = New-JWFont -Size 13
    $timePicker.Value = [datetime]::Now.AddMinutes(30)

    $timePanel.Controls.Add($timeTitle)
    $timePanel.Controls.Add($timeDescription)
    $timePanel.Controls.Add($timePicker)

    # =================================================================
    # 13. DISPLAY SECTION
    # =================================================================
    $displayPanel = New-Object System.Windows.Forms.Panel
    $displayPanel.Location = New-Object System.Drawing.Point(30, 250)
    $displayPanel.Size = New-Object System.Drawing.Size(545, 265)
    $displayPanel.BackColor = $ColorSurface
    $displayPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    $displayTitle = New-Object System.Windows.Forms.Label
    $displayTitle.Text = "Destination displays"
    $displayTitle.Location = New-Object System.Drawing.Point(18, 15)
    $displayTitle.AutoSize = $true
    $displayTitle.Font = New-JWFont -Size 11 -Style ([System.Drawing.FontStyle]::Bold)
    $displayTitle.ForeColor = $ColorTextPrimary

    $displayDescription = New-Object System.Windows.Forms.Label
    $displayDescription.Text = "Select one or more displays where the countdown should appear."
    $displayDescription.Location = New-Object System.Drawing.Point(18, 42)
    $displayDescription.AutoSize = $true
    $displayDescription.Font = New-JWFont -Size 8.5
    $displayDescription.ForeColor = $ColorTextSecondary

    # =================================================================
    # 14. DISPLAY CARDS
    # =================================================================
    $screenFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $screenFlow.Location = New-Object System.Drawing.Point(18, 72)
    $screenFlow.Size = New-Object System.Drawing.Size(505, 112)
    $screenFlow.BackColor = $ColorSurface
    $screenFlow.AutoScroll = $true
    $screenFlow.WrapContents = $false
    $screenFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight

    $script:ScreenButtons = @()

    # =================================================================
    # 15. SCREEN SELECTION VISUAL UPDATE
    # =================================================================
    function Update-ScreenSelection {
        for($buttonIndex = 0; $buttonIndex -lt $script:ScreenButtons.Count; $buttonIndex++){
            $screenButton = $script:ScreenButtons[$buttonIndex]
            $isSelected = $script:SelectedScreenIndexes.Contains($buttonIndex)

            if($isSelected){
                $screenButton.BackColor = $ColorAccentLight
                $screenButton.FlatAppearance.BorderColor = $ColorAccent
                $screenButton.FlatAppearance.BorderSize = 2
            } else {
                $screenButton.BackColor = $ColorSurface
                $screenButton.FlatAppearance.BorderColor = $ColorBorder
                $screenButton.FlatAppearance.BorderSize = 1
            }
        }

        $selectedCount = $script:SelectedScreenIndexes.Count
        $totalCount = $screens.Count

        if($selectedCount -eq 0){
            $selectionSummaryLabel.Text = "No display selected."
        } elseif($selectedCount -eq 1){
            $selectionSummaryLabel.Text = "1 display selected."
        } elseif($selectedCount -eq $totalCount){
            $selectionSummaryLabel.Text = "All $totalCount displays selected."
        } else {
            $selectionSummaryLabel.Text = "$selectedCount displays selected."
        }
    }

    # =================================================================
    # 16. CREATE DISPLAY CARDS
    # =================================================================
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
        $screenButton.FlatAppearance.MouseOverBackColor = $ColorAccentLight
        $screenButton.BackColor = $ColorSurface
        $screenButton.ForeColor = $ColorTextPrimary
        $screenButton.Cursor = [System.Windows.Forms.Cursors]::Hand
        $screenButton.Tag = $i

        $screenButton.Add_Click({
            $screenIndex = [int]$this.Tag
            
            if($script:SelectedScreenIndexes.Contains($screenIndex)){
                $script:SelectedScreenIndexes.Remove($screenIndex) | Out-Null
            } else {
                $script:SelectedScreenIndexes.Add($screenIndex)
            }

            Update-ScreenSelection
        })

        $script:ScreenButtons += $screenButton
        $screenFlow.Controls.Add($screenButton)
    }

    # =================================================================
    # 17. SELECTION SUMMARY
    # =================================================================
    $selectionSummaryLabel = New-Object System.Windows.Forms.Label
    $selectionSummaryLabel.Location = New-Object System.Drawing.Point(18, 188)
    $selectionSummaryLabel.Size = New-Object System.Drawing.Size(505, 20)
    $selectionSummaryLabel.AutoSize = $false
    $selectionSummaryLabel.Font = New-JWFont -Size 8.5 -Style ([System.Drawing.FontStyle]::Bold)
    $selectionSummaryLabel.ForeColor = $ColorTextSecondary
    $selectionSummaryLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft

    # =================================================================
    # 18. SELECT ALL BUTTON
    # =================================================================
    $selectAllButton = New-Object System.Windows.Forms.Button
    $selectAllButton.Text = "SELECT ALL"
    $selectAllButton.Location = New-Object System.Drawing.Point(18, 215)
    $selectAllButton.Size = New-Object System.Drawing.Size(140, 38)
    $selectAllButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $selectAllButton.FlatAppearance.BorderColor = $ColorBorder
    $selectAllButton.FlatAppearance.BorderSize =1
    $selectAllButton.BackColor = $ColorSurface
    $selectAllButton.ForeColor = $ColorTextPrimary
    $selectAllButton.Font = New-JWFont -Size 8.5 -Style ([System.Drawing.FontStyle]::Bold)
    $selectAllButton.Cursor = [System.Windows.Forms.Cursors]::Hand

    $selectAllButton.Add_Click({
        $script:SelectedScreenIndexes.Clear()

        for($screenIndex = 0; $screenIndex -lt $screens.Count; $screenIndex++){
            $script:SelectedScreenIndexes.Add($screenIndex)
        }

        Update-ScreenSelection
    })

    # =================================================================
    # 19. CLEAR SELECTION BUTTON
    # =================================================================
    $clearSelectionButton = New-Object System.Windows.Forms.Button
    $clearSelectionButton.Text = "CLEAR SELECTION"
    $clearSelectionButton.Location = New-Object System.Drawing.Point(168, 215)
    $clearSelectionButton.Size = New-Object System.Drawing.Size(155, 38)
    $clearSelectionButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $clearSelectionButton.FlatAppearance.BorderColor = $ColorBorder
    $clearSelectionButton.FlatAppearance.BorderSize = 1
    $clearSelectionButton.BackColor = $ColorSurface
    $clearSelectionButton.ForeColor = $ColorTextPrimary
    $clearSelectionButton.Font = New-JWFont -Size 8.5 -Style ([System.Drawing.FontStyle]::Bold)
    $clearSelectionButton.Cursor = [System.Windows.Forms.Cursors]::Hand

    $clearSelectionButton.Add_Click({
        $script:SelectedScreenIndexes.Clear()
        Update-ScreenSelection
    })

    # =================================================================
    # 20. IDENTIFY DISPLAYS BUTTON
    # =================================================================
    $identifyButton = New-Object System.Windows.Forms.Button
    $identifyButton.Text = "IDENTIFY DISPLAYS"
    $identifyButton.Location = New-Object System.Drawing.Point(333, 215)
    $identifyButton.Size = New-Object System.Drawing.Size(190, 38)
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
        $selectAllButton.Enabled = $false
        $clearSelectionButton.Enabled = $false
        try {
            Show-DisplayIdentification -Displays $screens
        } finally {
            $identifyButton.Enabled = $true
            $startButton.Enabled = $true
            $selectAllButton.Enabled = $true
            $clearSelectionButton.Enabled = $true
        }
    })

    # =================================================================
    # 21. ADD DISPLAY CONTROLS
    # =================================================================
    $displayPanel.Controls.Add($displayTitle)
    $displayPanel.Controls.Add($displayDescription)
    $displayPanel.Controls.Add($screenFlow)
    $displayPanel.Controls.Add($selectionSummaryLabel)
    $displayPanel.Controls.Add($selectAllButton)
    $displayPanel.Controls.Add($clearSelectionButton)
    $displayPanel.Controls.Add($identifyButton)

    # =================================================================
    # 22. START BUTTON
    # =================================================================
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

            try {
                $targetTime = [datetime]::new(
                        $now.Year,
                        $now.Month,
                        $now.Day,
                        $selectedTime.Hour,
                        $selectedTime.Minute,
                        0
                    )
            } catch {
                $targetTime =
                    Get-Date `
                        -Year $now.Year `
                        -Month $now.Month `
                        -Day $now.Day `
                        -Hour $selectedTime.Hour `
                        -Minute $selectedTime.Minute `
                        -Second 0
            }

            if($targetTime -le $now){ $targetTime = $targetTime.AddDays(1) }

            if($script:SelectedScreenIndexes.Count -eq 0){
                Show-JWMessage `
                    -Message "Please select at least one destination display." `
                    -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning) |
                    Out-Null

                return
            }

            $selectedScreens = @()

            foreach($screenIndex in $script:SelectedScreenIndexes){
                if($screenIndex -ge 0 -and $screenIndex -lt $screens.Count){
                    $selectedScreens += $screens[$screenIndex]
                }
            }

            if($selectedScreens.Count -eq 0){
                Show-JWMessage `
                    -Message "The selected displays are no longer available." `
                    -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning) |
                    Out-Null

                return
            }

            $setupForm.Hide()

            try {
                Show-CountdownOverlays `
                    -Displays $selectedScreens `
                    -TargetTime $targetTime
            } finally {
                if($null -ne $setupForm -and -not $setupForm.IsDisposed){
                    $setupForm.Close()
                }
            }
        } catch {
            Show-JWMessage `
                -Message ("An unexpected error occurred.`r`n`r`n" + $_.Exception.Message) `
                -Icon ([System.Windows.Forms.MessageBoxIcon]::Error) |
                Out-Null
        }
    })

    # =================================================================
    # 23. FOOTER
    # =================================================================
    $footerLabel = New-Object System.Windows.Forms.Label
    $footerLabel.Text = "v$($script:Version)"
    $footerLabel.Location = New-Object System.Drawing.Point(30, 595)
    $footerLabel.AutoSize = $true
    $footerLabel.Font = New-JWFont -Size 8
    $footerLabel.ForeColor = $ColorTextSecondary

    # =================================================================
    # 24. ADD MAIN CONTROLS
    # =================================================================
    $setupForm.Controls.Add($titleLabel)
    $setupForm.Controls.Add($subtitleLabel)
    $setupForm.Controls.Add($timePanel)
    $setupForm.Controls.Add($displayPanel)
    $setupForm.Controls.Add($startButton)
    $setupForm.Controls.Add($footerLabel)

    $setupForm.AcceptButton = $startButton

    # =================================================================
    # 25. INITIAL UI STATE
    # =================================================================
    Update-ScreenSelection

    # =================================================================
    # 26. RUN APPLICATION
    # =================================================================
    try {
        $setupForm.ShowDialog() | Out-Null
    } finally {
        if($null -ne $setupForm -and -not $setupForm.IsDisposed){
            $setupForm.Dispose()
        }
    }
} finally {
    # =================================================================
    # 27. RELEASE SINGLE INSTANCE MUTEX
    # =================================================================
    if($script:TimerMutexOwned){
        try {
            $script:TimerMutex.ReleaseMutex()
        } catch {
            [System.Diagnostics.Debug]::WriteLine("[$($script:AppName)] Unable to release the single-instance mutex.")
        }
    }

    # =================================================================
    # 28. DISPOSE MUTEX
    # =================================================================
    try {
        if($null -ne $script:TimerMutex){ $script:TimerMutex.Dispose() }
    } catch {
        [System.Diagnostics.Debug]::WriteLine("[$($script:AppName)] Unable to dispose the single-instance mutex.")
    }
}
