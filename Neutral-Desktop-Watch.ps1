# Neon Clock - purple glow desktop clock (top-right)
# Run: Set-ExecutionPolicy -Scope Process Bypass; .\Neon-Clock.ps1
# Left-drag = move, Right-click = close

# ---- Settings ----
$AlwaysOnTop = $false         # set $false once it works, to let apps cover it
$MarginRight = 60
$MarginTop   = 30
$GlowColor   = '#FFFFFF'
$TimeColor   = '#8CFFFFFF'
$DateColor   = '#80FFFFFF'
$Font        = 'Orbitron, Bahnschrift, Segoe UI Black'   # install Orbitron for the exact look
$Use24h      = $true
# ------------------

$ErrorActionPreference = 'Stop'
$LogPath = Join-Path $PSScriptRoot 'Neon-Clock.log'
function Log($m) { Add-Content -LiteralPath $LogPath -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NeonNative {
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string n);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
}
"@

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True"
        Background="Transparent" ShowInTaskbar="False" SizeToContent="WidthAndHeight">
  <StackPanel Margin="40,20,40,30">
    <TextBlock Name="Clock" Text="00:00" FontSize="130" FontWeight="Black"
               Foreground="$TimeColor" TextAlignment="Center" FontFamily="$Font">
      <TextBlock.Effect>
        <DropShadowEffect Color="$GlowColor" BlurRadius="25" ShadowDepth="0" Opacity="0.35"/>
      </TextBlock.Effect>
    </TextBlock>
    <TextBlock Name="DateLine" Text="" FontSize="26" FontWeight="Bold"
               Foreground="$DateColor" TextAlignment="Center" FontFamily="$Font" Margin="0,-8,0,0">
      <TextBlock.Effect>
        <DropShadowEffect Color="$GlowColor" BlurRadius="10" ShadowDepth="0" Opacity="0.3"/>
      </TextBlock.Effect>
    </TextBlock>
  </StackPanel>
</Window>
"@
    $window   = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $clock    = $window.FindName('Clock')
    $dateLine = $window.FindName('DateLine')
    $window.Topmost = $AlwaysOnTop

    $hair = [string][char]0x200A
    $refresh = {
        $now = Get-Date
        $fmt = if ($Use24h) { 'HH:mm' } else { 'hh:mm' }
        $clock.Text = $now.ToString($fmt)
        $d = $now.ToString('ddd, dd MMM yyyy').ToUpperInvariant()
        $dateLine.Text = ($d.ToCharArray() -join $hair)   # letter-spacing
    }
    & $refresh
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick($refresh)
    $timer.Start()

    # Hide from Alt+Tab (TOOLWINDOW)
    $pin = {
        $h  = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $pm = [NeonNative]::FindWindow('Progman', [NullString]::Value)
        $prev = [NeonNative]::GetWindow($pm, 3)   # window directly above the desktop
        if ($prev -eq $h) { return }
        # NOSIZE | NOMOVE | NOACTIVATE
        [void][NeonNative]::SetWindowPos($h, $prev, 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor 0x0010)
    }
    $window.Add_SourceInitialized({
        $h  = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $ex = [NeonNative]::GetWindowLong($h, -20)
        # TOOLWINDOW | NOACTIVATE
        [void][NeonNative]::SetWindowLong($h, -20, ($ex -bor 0x80 -bor 0x08000000))
    })
    $pinTimer = New-Object System.Windows.Threading.DispatcherTimer
    $pinTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $pinTimer.Add_Tick($pin)
    $pinTimer.Start()

    # ---- Wallpaper tint ----
    $TintLighten = 0.45   # 0 = pure wallpaper color, 1 = white
    $TimeAlpha   = 0x8C
    $DateAlpha   = 0x80
    Add-Type -AssemblyName System.Drawing
    $script:wpStamp = $null

    function Get-WallpaperFile {
        $f = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\TranscodedWallpaper'
        if (-not (Test-Path $f)) { $f = (Get-ItemProperty 'HKCU:\Control Panel\Desktop').WallPaper }
        $f
    }

    function Get-Tint($file) {
        $ms = New-Object IO.MemoryStream(,[IO.File]::ReadAllBytes($file))
        $src = [Drawing.Bitmap]::FromStream($ms)
        $bmp = New-Object Drawing.Bitmap 32,32
        $g = [Drawing.Graphics]::FromImage($bmp); $g.DrawImage($src,0,0,32,32); $g.Dispose()
        $src.Dispose(); $ms.Dispose()
        $r = 0.0; $gr = 0.0; $b = 0.0; $w = 0.0
        for ($x = 0; $x -lt 32; $x++) { for ($y = 0; $y -lt 32; $y++) {
            $c  = $bmp.GetPixel($x,$y)
            $wt = $c.GetSaturation() * $c.GetBrightness() + 0.001   # favor vivid pixels
            $r += $c.R * $wt; $gr += $c.G * $wt; $b += $c.B * $wt; $w += $wt
        } }
        $bmp.Dispose()
        $k = $TintLighten
        [Windows.Media.Color]::FromRgb(
            [byte](($r / $w) * (1 - $k) + 255 * $k),
            [byte](($gr / $w) * (1 - $k) + 255 * $k),
            [byte](($b / $w) * (1 - $k) + 255 * $k))
    }

    $applyTint = {
        try {
            $file  = Get-WallpaperFile
            $stamp = "$file|" + (Get-Item $file).LastWriteTimeUtc.Ticks
            if ($stamp -eq $script:wpStamp) { return }
            $script:wpStamp = $stamp
            $c = Get-Tint $file
            $clock.Foreground    = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb($TimeAlpha,$c.R,$c.G,$c.B))
            $dateLine.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb($DateAlpha,$c.R,$c.G,$c.B))
            $clock.Effect.Color    = $c
            $dateLine.Effect.Color = $c
            Log "Tint applied: $c"
        } catch { Log ("Tint error: " + $_) }
    }
    & $applyTint
    $tintTimer = New-Object System.Windows.Threading.DispatcherTimer
    $tintTimer.Interval = [TimeSpan]::FromSeconds(3)
    $tintTimer.Add_Tick($applyTint)
    $tintTimer.Start()

    # Top-right placement (WPF units, so DPI-safe)
    $window.Add_ContentRendered({
        $window.Left = [System.Windows.SystemParameters]::PrimaryScreenWidth - $window.ActualWidth - $MarginRight
        $window.Top  = $MarginTop
        Log "Shown at $($window.Left),$($window.Top) size $($window.ActualWidth)x$($window.ActualHeight)"
    })

    $window.Add_MouseLeftButtonDown({ $window.DragMove() })
    $window.Add_MouseRightButtonUp({ $window.Close() })

    $null = $window.ShowDialog()
}
catch {
    Log ("ERROR: " + ($_ | Out-String))
    Write-Host ($_ | Out-String) -ForegroundColor Yellow
    Read-Host 'Press Enter to close'
}