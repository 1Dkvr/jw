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
        - Every selected display receives its own visual overlay.
        - All overlays are driven by one shared timer.
        - All displays therefore remain synchronized to the same target time.
        - Less than 1 hour remaining: MM:SS
        - 1 hour or more remaining: HH:MM:SS

    Target-time behavior:
        - If the selected meeting time has already passed today,
          the timer automatically targets the same time tomorrow.

    Overlay behavior:
        - The countdown is displayed in the lower 25% of each selected monitor.
        - The overlay is borderless, always-on-top and visually transparent.
        - Double-clicking a countdown closes all countdown overlays.
        - Pressing Escape on an overlay closes all countdown overlays.
        - When the countdown reaches zero, all overlays close automatically.

    Application lifecycle:
        - Only one JW Countdown process may own the application mutex.
        - Starting a second instance displays an informational message and exits.
        - When the countdown is closed or completed, the setup application exits
          cleanly and releases the mutex so a new instance can be launched.

    Release metadata:
        - Application identity and release version are defined in one location.
        - No application version is duplicated throughout the source code.
        - The release version is intentionally prepared for future automated
          release and update management.

.NOTES
    Product      : JW Countdown
    Component    : Main application
    Created      : 26.09.01
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

Set-StrictMode -Version Latest

# =====================================================================
# 1. INITIALIZATION
# =====================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =====================================================================
# 2. APPLICATION METADATA
# =====================================================================
# This block is the single source of truth for the application identity
# and release version.
#
# The future release/build system should update only the Version value
# below when preparing a new release.
#
# No other part of the application should contain a hard-coded release
# version.
#
$script:ApplicationMetadata = [ordered]@{
    Name      = "JW Countdown"
    Version   = "26.09.15"
    Developer = "1Dkvr"
}

# Convenient application aliases used throughout the application.
#
$script:AppName   = $script:ApplicationMetadata.Name
$script:Version   = $script:ApplicationMetadata.Version
$script:Developer = $script:ApplicationMetadata.Developer


# =====================================================================
# 2.1. SINGLE APPLICATION INSTANCE
# =====================================================================
#
# A named system-wide mutex prevents multiple JW Countdown processes
# from running simultaneously.
#
# The mutex remains owned for the complete lifetime of the application
# process and is released during the final cleanup stage.
#
$script:TimerMutex = New-Object System.Threading.Mutex($false, "JWCountdown.SingleTimer")
$script:TimerMutexOwned = $false

try {
    if(-not $script:TimerMutex.WaitOne(0, $false)){
        [System.Windows.Forms.MessageBox]::Show(
            "A JW Countdown is already running.",
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }
    $script:TimerMutexOwned = $true

    # ================================================================
    # 2.2. DISPLAY SELECTION STATE
    # ================================================================
    #
    # Selected monitors are stored by their index in the Screen[] collection returned by Screen.AllScreens.
    $script:SelectedScreenIndexes = New-Object System.Collections.Generic.List[int]
    $script:ScreenButtons = @()

    # ================================================================
    # 2.3. COUNTDOWN STATE
    # ================================================================
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
    # 4. CONSOLE HIDING
    # =================================================================
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
        [System.Diagnostics.Debug]::WriteLine("[$script:AppName] Unable to initialize console interop.")
    }

    try {
        $consoleWindow = JWCountdownConsole]::GetConsoleWindow()
        if($consoleWindow -ne [IntPtr]::Zero){
            [JWCountdownConsole]::ShowWindow($consoleWindow, 0) | Out-Null
        }
    } catch {
        [System.Diagnostics.Debug]::WriteLine("[$script:AppName] Unable to hide the PowerShell console window.")
    }

    # =================================================================
    # 5. FONT HELPER
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

    # =================================================================
    # 6. CONNECTED DISPLAYS
    # =================================================================
    $screens = [System.Windows.Forms.Screen]::AllScreens

    if($null -eq $screens -or $screens.Count -eq 0){
        [System.Windows.Forms.MessageBox]::Show(
            "No display was detected.",
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    # Select the primary display by default.
    #
    # Screen.Primary is preferred over assuming that index zero is the
    # primary monitor because Windows does not guarantee enumeration order.
    #
    for($i = 0; $i -lt $screens.Count; $i++){
        if($screens[$i].Primary){
            $script:SelectedScreenIndexes.Add($i)
            break
        }
    }

    # Fallback in the unlikely case that no primary screen is reported.
    #
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

    # =================================================================
    # 8. COUNTDOWN DISPLAY HELPERS
    # =================================================================
    function Get-JWCountdownText {
        param(
            [Parameter(Mandatory = $true)]
            [timespan]$Remaining
        )

        if($Remaining.TotalSeconds -le 0){
            return "00:00"
        }

        if($Remaining.TotalHours -ge 1){
            $totalHours = [int][Math]::Floor($Remaining.TotalHours)

            return "{0:D2}:{1:D2}:{2:D2}" -f $totalHours, $Remaining.Minutes, $Remaining.Seconds
        }

        $totalMinutes = [int][Math]::Floor($Remaining.TotalMinutes)

        return "{0:D2}:{1:D2}" -f $totalMinutes, $Remaining.Seconds
    }

    function Close-JWCountdownOverlays {
        param(
            [Parameter(Mandatory = $true)]
            [System.Windows.Forms.Form[]]$Overlays,

            [Parameter(Mandatory = $true)]
            [System.Windows.Forms.Timer]$Timer
        )

        # Prevent recursive close events from attempting to close the
        # same group of overlays more than once.
        #
        if($script:CountdownClosing){ return }
        
        $script:CountdownClosing = $true

        try {
            if($null -ne $Timer){
                $Timer.Stop()
            }

            foreach($overlay in $Overlays){
                if($null -ne $overlay -and -not $overlay.IsDisposed){
                    $overlay.Close()
                }
            }
        } catch {
            [System.Diagnostics.Debug]::WriteLine("[$script:AppName] Error while closing countdown overlays: $($_.Exception.Message)")
        }
    }

    # =================================================================
    # 9. MULTI-DISPLAY COUNTDOWN OVERLAY
    # =================================================================
    # 
    # One overlay window is created for each selected display.
    # All overlays use ONE shared timer and ONE target time so every display remains synchronized.
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

        # --------------------------------------------------------------
        # Shared countdown timer
        # --------------------------------------------------------------
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 1000

        # --------------------------------------------------------------
        # Create one overlay per selected display
        # --------------------------------------------------------------
        foreach($display in $Displays){
            # ----------------------------------------------------------
            # Overlay window
            # ----------------------------------------------------------
            $overlay = New-Object System.Windows.Forms.Form
            $overlay.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
            $overlay.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
            $overlay.TopMost = $true
            $overlay.ShowInTaskbar = $false
            $overlay.KeyPreview = $true

            # ----------------------------------------------------------
            # Transparency configuration
            # ----------------------------------------------------------
            # Black is used as the transparency key.
            #
            $overlay.BackColor = $ColorBlack
            $overlay.TransparencyKey = $ColorBlack

            # ----------------------------------------------------------
            # Overlay geometry
            # ----------------------------------------------------------
            # The countdown occupies the bottom 25% of the monitor.
            #
            $overlayHeight = [int]($display.Bounds.Height * 0.25)
            $overlay.Left = $display.Bounds.X
            $overlay.Width = $display.Bounds.Width
            $overlay.Height = $overlayHeight
            $overlay.Top = $display.Bounds.Y + $display.Bounds.Height - $overlayHeight

            # ----------------------------------------------------------
            # Countdown label
            # ----------------------------------------------------------
            $timerLabel = New-Object System.Windows.Forms.Label
            $timerLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $timerLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
            $timerLabel.BackColor = $ColorBlack
            $timerLabel.ForeColor = $ColorTimer
            $timerLabel.Font = New-JWFont -Size 45 -Style ([System.Drawing.FontStyle]::Regular)
            $timerLabel.Text = "00:00"
            $overlay.Controls.Add($timerLabel)

            # ----------------------------------------------------------
            # Emergency close - double click
            # ----------------------------------------------------------
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

            # ----------------------------------------------------------
            # Emergency close - Escape
            # ----------------------------------------------------------
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

        # --------------------------------------------------------------
        # Shared timer tick
        # --------------------------------------------------------------
        #
        # The current time is calculated once per tick and the same
        # resulting string is assigned to every selected display.
        #
        $timer.Add_Tick({
            $now = [datetime]::Now
            $remaining = $TargetTime - $now

            # ----------------------------------------------------------
            # Meeting has started
            # ----------------------------------------------------------
            if($remaining.TotalSeconds -le 0){
                Close-JWCountdownOverlays `
                    -Overlays $overlayWindows `
                    -Timer $timer

                return
            }

            # ----------------------------------------------------------
            # Update every selected display
            # ----------------------------------------------------------
            $countdownText = Get-JWCountdownText -Remaining $remaining

            foreach($label in $timerLabels){
                if($null -ne $label -and -not $label.IsDisposed){
                    $label.Text = $countdownText
                }
            }
        })

        # --------------------------------------------------------------
        # Initial render
        # --------------------------------------------------------------
        #
        # Display the correct countdown immediately instead of waiting
        # for the first timer tick.
        #
        $initialRemaining = $TargetTime - [datetime]::Now
        $initialText = Get-JWCountdownText -Remaining $initialRemaining

        foreach($label in $timerLabels){
            $label.Text = $initialText
        }

        try {
            # ----------------------------------------------------------
            # Start all secondary overlays first.
            #
            # The first overlay will then provide the modal WinForms
            # message loop for the countdown session.
            # ----------------------------------------------------------
            for($overlayIndex = 1; $overlayIndex -lt $overlayWindows.Count; $overlayIndex++){
                $overlayWindows[$overlayIndex].Show()
            }

            # ----------------------------------------------------------
            # Start shared countdown.
            # ----------------------------------------------------------
            $timer.Start()

            # ----------------------------------------------------------
            # Run the first overlay as the modal UI loop.
            # ----------------------------------------------------------
            if($overlayWindows.Count -gt 0){
                $overlayWindows[0].ShowDialog() | Out-Null
            }
        } finally {
            # ----------------------------------------------------------
            # Guaranteed cleanup.
            # ----------------------------------------------------------
            $timer.Stop()

            foreach($overlay in $overlayWindows){
                if($null -ne $overlay -and -not $overlay.IsDisposed){
                    try {
                        $overlay.Close()
                    } catch {
                        # Ignore secondary close errors during cleanup.
                    }
                }
            }

            foreach($overlay in $overlayWindows){
                if($null -ne $overlay -and -not $overlay.IsDisposed){
                    $overlay.Dispose()
                }
            }

            foreach($label in $timerLabels){
                if($null -ne $label -and -not $label.IsDisposed){
                    $label.Dispose()
                }
            }

            $timer.Dispose()
            $script:CountdownClosing = $false
        }
    }

    # =================================================================
    # 10. MAIN WINDOW
    # =================================================================
    $setupForm = New-Object System.Windows.Forms.Form
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

    # -----------------------------------------------------------------
    # Native time selector
    # -----------------------------------------------------------------
    $timePicker = New-Object System.Windows.Forms.DateTimePicker
    $timePicker.Location = New-Object System.Drawing.Point(18, 72)
    $timePicker.Size = New-Object System.Drawing.Size(160, 35)
    $timePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
    $timePicker.CustomFormat = "HH:mm"
    $timePicker.ShowUpDown = $true
    $timePicker.Font = New-JWFont -Size 13
    $timePicker.Value = [datetime]::Now.AddMinutes(30) # Default to approximately 30 minutes from now.

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

        # --------------------------------------------------------------
        # Selection summary
        # --------------------------------------------------------------
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

        # Store the monitor index directly on the button.
        #
        # This avoids depending on the loop variable inside the event
        # handler.
        #
        $screenButton.Tag = $i

        # Toggle display selection when the card is clicked.
        #
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
    $selectAllButton.FlatAppearance.BorderSize = 1

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
            # ----------------------------------------------------------
            # Build target time using the selected hour and minute.
            # ----------------------------------------------------------
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
                # Windows PowerShell 5.1 compatibility fallback.
                #
                $targetTime =
                    Get-Date `
                        -Year $now.Year `
                        -Month $now.Month `
                        -Day $now.Day `
                        -Hour $selectedTime.Hour `
                        -Minute $selectedTime.Minute `
                        -Second 0
            }

            # ----------------------------------------------------------
            # If the selected time has already passed today,
            # schedule tomorrow's occurrence.
            # ----------------------------------------------------------
            if($targetTime -le $now){
                $targetTime = $targetTime.AddDays(1)
            }

            # ----------------------------------------------------------
            # Validate display selection.
            # ----------------------------------------------------------
            if($script:SelectedScreenIndexes.Count -eq 0){
                [System.Windows.Forms.MessageBox]::Show(
                    "Please select at least one destination display.",
                    $script:AppName,
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null

                return
            }

            # ----------------------------------------------------------
            # Resolve selected indexes into Screen objects.
            # ----------------------------------------------------------
            $selectedScreens = @()

            foreach($screenIndex in $script:SelectedScreenIndexes){
                if($screenIndex -ge 0 -and $screenIndex -lt $screens.Count){
                    $selectedScreens += $screens[$screenIndex]
                }
            }

            if($selectedScreens.Count -eq 0){
                [System.Windows.Forms.MessageBox]::Show(
                    "The selected displays are no longer available.",
                    $script:AppName,
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null

                return
            }

            # ----------------------------------------------------------
            # Hide configuration while the countdown is running.
            # ----------------------------------------------------------
            $setupForm.Hide()

            try {
                Show-CountdownOverlays `
                    -Displays $selectedScreens `
                    -TargetTime $targetTime

            } finally {
                # ------------------------------------------------------
                # The configuration window must never be shown again
                # after a countdown session has started.
                # ------------------------------------------------------
                if($null -ne $setupForm -and -not $setupForm.IsDisposed){
                    $setupForm.Close()
                }
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "An unexpected error occurred.`r`n`r`n$($_.Exception.Message)",
                $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
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
    $setupForm.AcceptButton = $startButton # Pressing Enter starts the timer.

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
            [System.Diagnostics.Debug]::WriteLine("[JW Countdown] Unable to release the single-instance mutex.")
        }
    }

    # =================================================================
    # 28. DISPOSE MUTEX
    # =================================================================
    try {
        if($null -ne $script:TimerMutex){
            $script:TimerMutex.Dispose()
        }
    } catch {
        [System.Diagnostics.Debug]::WriteLine("[JW Countdown] Unable to dispose the single-instance mutex.")
    }
}
