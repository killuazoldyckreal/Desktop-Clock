$AlwaysOnTop = $false

$ErrorActionPreference = 'Stop'
$Base = if ($PSScriptRoot) { $PSScriptRoot } else { $env:APPDATA }
$LogPath = Join-Path $Base 'Neon-Clock.log'
$SettingsPath = Join-Path $Base 'Neon-Clock.settings.json'
function Log($m) { Add-Content -LiteralPath $LogPath -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing, System.Windows.Forms
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

    # ================= Settings (defaults + load/save) =================
    $Defaults = [ordered]@{
        TimeFont    = 'Chakra Petch'
        DateFont    = 'Chakra Petch'
        TimeSize    = 130
        DateSize    = 26
        TimeOpacity = 55
        DateOpacity = 50
        ColorMode   = 'Auto'        # Auto | Default | Custom | Image
        CustomColor = '#A020F0'
        ImagePath   = ''
        TintLighten = 45
        Glow        = 60
        Use24h      = $true
        Right       = 60            # distance from right screen edge
        Top         = 30
    }
    $S = @{}
    foreach ($k in @($Defaults.Keys)) { $S[$k] = $Defaults[$k] }
    if (Test-Path -LiteralPath $SettingsPath) {
        try {
            $j = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { if ($Defaults.Contains($p.Name)) { $S[$p.Name] = $p.Value } }
        } catch { Log ("Settings load error: " + $_) }
    }
    if ($S.CustomColor -notmatch '^#[0-9A-Fa-f]{6}$') { $S.CustomColor = $Defaults.CustomColor }

    function Save-Settings {
        try { $S | ConvertTo-Json | Set-Content -LiteralPath $SettingsPath -Encoding UTF8 }
        catch { Log ("Settings save error: " + $_) }
    }
    $saveTimer = New-Object System.Windows.Threading.DispatcherTimer
    $saveTimer.Interval = [TimeSpan]::FromMilliseconds(700)
    $saveTimer.Add_Tick({ $saveTimer.Stop(); Save-Settings })
    function Request-Save { $saveTimer.Stop(); $saveTimer.Start() }

    function ConvertTo-WpfColor($hex) {
        $h = $hex.TrimStart('#')
        [Windows.Media.Color]::FromRgb([Convert]::ToByte($h.Substring(0,2),16), [Convert]::ToByte($h.Substring(2,2),16), [Convert]::ToByte($h.Substring(4,2),16))
    }

    # ================= Clock window =================
    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True"
        Background="Transparent" ShowInTaskbar="False" SizeToContent="WidthAndHeight">
  <StackPanel Margin="40,20,40,30">
    <TextBlock Name="Clock" Text="00:00" FontWeight="Black" TextAlignment="Center">
      <TextBlock.Effect>
        <DropShadowEffect Color="#FFFFFF" BlurRadius="25" ShadowDepth="0" Opacity="0.5"/>
      </TextBlock.Effect>
    </TextBlock>
    <TextBlock Name="DateLine" Text="" FontWeight="Bold" TextAlignment="Center" Margin="0,-8,0,0">
      <TextBlock.Effect>
        <DropShadowEffect Color="#FFFFFF" BlurRadius="10" ShadowDepth="0" Opacity="0.5"/>
      </TextBlock.Effect>
    </TextBlock>
  </StackPanel>
</Window>
'@
    $window   = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $clock    = $window.FindName('Clock')
    $dateLine = $window.FindName('DateLine')
    $window.Topmost = $AlwaysOnTop

    $hair = [string][char]0x200A
    $refresh = {
        $now = Get-Date
        $fmt = if ($S.Use24h) { 'HH:mm' } else { 'hh:mm' }
        $clock.Text = $now.ToString($fmt)
        $d = $now.ToString('ddd, dd MMM yyyy').ToUpperInvariant()
        $dateLine.Text = ($d.ToCharArray() -join $hair)   # letter-spacing
    }
    & $refresh
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick($refresh)
    $timer.Start()

    # ---- Keep the clock just above the desktop ----
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
        # TOOLWINDOW (no Alt+Tab) | NOACTIVATE
        [void][NeonNative]::SetWindowLong($h, -20, ($ex -bor 0x80 -bor 0x08000000))
    })
    $pinTimer = New-Object System.Windows.Threading.DispatcherTimer
    $pinTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $pinTimer.Add_Tick($pin)
    $pinTimer.Start()

    # ================= Wallpaper color =================
    $script:wpStamp = $null
    $script:rawAvg  = $null
    $script:imgPath = $null
    $script:imgBrush = $null
    $script:loading = $false
    $script:setWin  = $null

    function Get-WallpaperFile {
        $f = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\TranscodedWallpaper'
        if (-not (Test-Path $f)) { $f = (Get-ItemProperty 'HKCU:\Control Panel\Desktop').WallPaper }
        $f
    }

    function Get-WallpaperAvg($file) {
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
        @(($r / $w), ($gr / $w), ($b / $w))
    }

    function Get-ImageBrush($path) {
        try {
            if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
            if ($script:imgPath -ne $path) {
                $bi = New-Object Windows.Media.Imaging.BitmapImage
                $bi.BeginInit()
                $bi.CacheOption = 'OnLoad'
                $bi.UriSource = New-Object Uri $path
                $bi.EndInit()
                $bi.Freeze()
                $ib = New-Object Windows.Media.ImageBrush $bi
                $ib.Stretch = 'UniformToFill'
                $script:imgBrush = $ib
                $script:imgPath = $path
            }
            return $script:imgBrush
        } catch { Log ("Image load error: " + $_); return $null }
    }

    # ================= Apply all style settings to the clock =================
    function Apply-Style {
        try {
            $clock.FontFamily    = New-Object Windows.Media.FontFamily ("{0}, Bahnschrift, Segoe UI" -f $S.TimeFont)
            $dateLine.FontFamily = New-Object Windows.Media.FontFamily ("{0}, Bahnschrift, Segoe UI" -f $S.DateFont)
            $clock.FontSize      = [double]$S.TimeSize
            $dateLine.FontSize   = [double]$S.DateSize
            $clock.Opacity       = [double]$S.TimeOpacity / 100
            $dateLine.Opacity    = [double]$S.DateOpacity / 100

            $c = [Windows.Media.Color]::FromRgb(255,255,255)
            $brush = $null
            $glowOn = $true
            switch ($S.ColorMode) {
                'Auto' {
                    if ($script:rawAvg) {
                        $k = [double]$S.TintLighten / 100
                        $c = [Windows.Media.Color]::FromRgb(
                            [byte]($script:rawAvg[0] * (1 - $k) + 255 * $k),
                            [byte]($script:rawAvg[1] * (1 - $k) + 255 * $k),
                            [byte]($script:rawAvg[2] * (1 - $k) + 255 * $k))
                    }
                }
                'Custom' { if ($S.CustomColor -match '^#[0-9A-Fa-f]{6}$') { $c = ConvertTo-WpfColor $S.CustomColor } }
                'Image'  { $brush = Get-ImageBrush $S.ImagePath; if ($brush) { $glowOn = $false } }
            }
            if (-not $brush) { $brush = New-Object Windows.Media.SolidColorBrush $c }
            $g = if ($glowOn) { [double]$S.Glow / 100 } else { 0 }
            foreach ($t in @($clock, $dateLine)) {
                $t.Foreground     = $brush
                $t.Effect.Color   = $c
                $t.Effect.Opacity = $g
            }
        } catch { Log ("Apply-Style error: " + $_) }
    }

    $applyTint = {
        try {
            $file = Get-WallpaperFile
            if (-not $file -or -not (Test-Path -LiteralPath $file)) { return }
            $stamp = "$file|" + (Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks
            if ($stamp -eq $script:wpStamp) { return }
            $script:wpStamp = $stamp
            $script:rawAvg = Get-WallpaperAvg $file
            Log "Wallpaper color sampled"
            if ($S.ColorMode -eq 'Auto') { Apply-Style }
        } catch { Log ("Tint error: " + $_) }
    }
    & $applyTint
    Apply-Style
    $tintTimer = New-Object System.Windows.Threading.DispatcherTimer
    $tintTimer.Interval = [TimeSpan]::FromSeconds(3)
    $tintTimer.Add_Tick($applyTint)
    $tintTimer.Start()

    # ================= Settings window =================
    $SettingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Clock settings" Width="410" Height="700"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" Topmost="True" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style x:Key="Sec" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#8E8EA6"/>
      <Setter Property="Margin" Value="0,18,0,6"/>
    </Style>
    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#C9C9D8"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" Background="#2C2C3A" CornerRadius="8" Padding="13,7">
              <ContentPresenter HorizontalAlignment="Center" TextBlock.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#3A3A4D"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#8A55F0"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#2C2C3A"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#2C2C3A"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="Padding" Value="8,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="Background" Value="#2C2C3A"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBox">
            <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="2">
              <ScrollViewer Focusable="False" HorizontalScrollBarVisibility="Disabled"><ItemsPresenter/></ScrollViewer>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" Background="Transparent" CornerRadius="6" Margin="2,1">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#34344A"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#6B45B8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SbThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="th" Background="#4A4A62" CornerRadius="4" Margin="2,0"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="th" Property="Background" Value="#8A55F0"/>
              </Trigger>
              <Trigger Property="IsDragging" Value="True">
                <Setter TargetName="th" Property="Background" Value="#8A55F0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SbPage" TargetType="RepeatButton">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource SbPage}"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource SbPage}"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Style="{StaticResource SbThumb}"/>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Slider -->
    <Style x:Key="SlThumb" TargetType="Thumb">
      <Setter Property="Width" Value="16"/>
      <Setter Property="Height" Value="16"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="th" Background="White" CornerRadius="8" BorderBrush="#8A55F0" BorderThickness="2"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="th" Property="Background" Value="#E6D9FF"/>
              </Trigger>
              <Trigger Property="IsDragging" Value="True">
                <Setter TargetName="th" Property="Background" Value="#E6D9FF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SlFill" TargetType="RepeatButton">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Grid Background="Transparent">
              <Border Height="4" Background="#8A55F0" CornerRadius="2" VerticalAlignment="Center"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SlRest" TargetType="RepeatButton">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Grid Background="Transparent">
              <Border Height="4" Background="#3A3A4D" CornerRadius="2" VerticalAlignment="Center"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Slider">
      <Setter Property="Height" Value="22"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Style="{StaticResource SlFill}"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" Style="{StaticResource SlRest}"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Style="{StaticResource SlThumb}"/>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- CheckBox -->
    <Style TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="20" Height="20" CornerRadius="6"
                      Background="#2C2C3A" BorderBrush="#4A4A62" BorderThickness="1.5">
                <Path x:Name="tick" Data="M4,10 L8,14 L15,5" Stroke="White" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                      Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"
                                TextBlock.Foreground="{TemplateBinding Foreground}"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="box" Property="BorderBrush" Value="#8A55F0"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="#8A55F0"/>
                <Setter TargetName="box" Property="BorderBrush" Value="#8A55F0"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border CornerRadius="16" Background="#1B1B24" BorderBrush="#33334A" BorderThickness="1" Margin="14"
          TextElement.Foreground="#E8E8F2">
    <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="0" Opacity="0.6"/></Border.Effect>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid x:Name="Header" Grid.Row="0" Background="Transparent" Margin="22,16,12,6">
        <TextBlock Text="Clock settings" FontSize="18" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <Button x:Name="btnX" Style="{StaticResource Btn}" Background="Transparent" Padding="10,4"
                Content="&#x2715;" HorizontalAlignment="Right"/>
      </Grid>

      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="22,0,12,0">
        <StackPanel Margin="0,0,10,8">

          <TextBlock Style="{StaticResource Sec}" Text="EDITING" Margin="0,6,0,6"/>
          <WrapPanel>
            <RadioButton x:Name="rbTime" GroupName="target" Content="Time" IsChecked="True" Style="{StaticResource Seg}"/>
            <RadioButton x:Name="rbDate" GroupName="target" Content="Date &amp; day" Style="{StaticResource Seg}"/>
          </WrapPanel>

          <TextBlock Style="{StaticResource Sec}" Text="FONT" Margin="0,10,0,6"/>
          <TextBox x:Name="tbSearch" ToolTip="Search fonts"/>
          <ListBox x:Name="lbFonts" Height="130" Margin="0,6,0,0">
            <ListBox.ItemTemplate>
              <DataTemplate>
                <TextBlock Text="{Binding}" FontFamily="{Binding}" FontSize="15" Padding="8,3"/>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>

          <Grid Margin="0,14,0,0">
            <TextBlock Text="Size"/>
            <TextBlock x:Name="lblSize" HorizontalAlignment="Right" Foreground="#8E8EA6"/>
          </Grid>
          <Slider x:Name="slSize" Minimum="40" Maximum="300" IsMoveToPointEnabled="True" Margin="0,4,0,0"/>

          <Grid Margin="0,10,0,0">
            <TextBlock Text="Opacity"/>
            <TextBlock x:Name="lblOpacity" HorizontalAlignment="Right" Foreground="#8E8EA6"/>
          </Grid>
          <Slider x:Name="slOpacity" Minimum="5" Maximum="100" IsMoveToPointEnabled="True" Margin="0,4,0,0"/>

          <TextBlock Style="{StaticResource Sec}" Text="COLOR"/>
          <WrapPanel>
            <RadioButton x:Name="rbAuto" GroupName="mode" Content="Wallpaper" Style="{StaticResource Seg}"/>
            <RadioButton x:Name="rbDefault" GroupName="mode" Content="Default" Style="{StaticResource Seg}"/>
            <RadioButton x:Name="rbCustom" GroupName="mode" Content="Custom" Style="{StaticResource Seg}"/>
            <RadioButton x:Name="rbImage" GroupName="mode" Content="Image" Style="{StaticResource Seg}"/>
          </WrapPanel>

          <StackPanel x:Name="pnlAuto" Margin="0,6,0,0">
            <TextBlock Text="Tint follows your current wallpaper." Foreground="#8E8EA6"/>
            <Grid Margin="0,10,0,0">
              <TextBlock Text="Lightness"/>
              <TextBlock x:Name="lblLight" HorizontalAlignment="Right" Foreground="#8E8EA6"/>
            </Grid>
            <Slider x:Name="slLight" Minimum="0" Maximum="100" IsMoveToPointEnabled="True" Margin="0,4,0,0"/>
          </StackPanel>

          <StackPanel x:Name="pnlCustom" Margin="0,6,0,0">
            <WrapPanel x:Name="wpSwatches"/>
            <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
              <Border Width="34" Height="34" CornerRadius="8" Margin="0,0,8,0" BorderBrush="#44445A" BorderThickness="1">
                <Border x:Name="rectPrev" CornerRadius="7"/>
              </Border>
              <TextBox x:Name="tbHex" Width="110" MaxLength="7" VerticalContentAlignment="Center"/>
              <Button x:Name="btnPick" Style="{StaticResource Btn}" Content="Pick..." Margin="8,0,0,0"/>
            </StackPanel>
          </StackPanel>

          <StackPanel x:Name="pnlImage" Margin="0,6,0,0">
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnImage" Style="{StaticResource Btn}" Content="Choose image..."/>
              <TextBlock x:Name="lblImage" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#8E8EA6"
                         TextTrimming="CharacterEllipsis" MaxWidth="170"/>
            </StackPanel>
            <TextBlock Text="The image fills the text. Glow is off in this mode." Foreground="#8E8EA6" Margin="0,8,0,0" TextWrapping="Wrap"/>
          </StackPanel>

          <TextBlock Style="{StaticResource Sec}" Text="GLOW"/>
          <Grid>
            <TextBlock Text="Strength"/>
            <TextBlock x:Name="lblGlow" HorizontalAlignment="Right" Foreground="#8E8EA6"/>
          </Grid>
          <Slider x:Name="slGlow" Minimum="0" Maximum="100" IsMoveToPointEnabled="True" Margin="0,4,0,0"/>

          <CheckBox x:Name="cbHour" Content="24-hour time" Foreground="#E8E8F2" Margin="0,18,0,0"/>
        </StackPanel>
      </ScrollViewer>

      <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="22,10,22,18">
        <Button x:Name="btnReset" Style="{StaticResource Btn}" Content="Reset"/>
        <Button x:Name="btnQuit" Style="{StaticResource Btn}" Content="Quit clock" Background="#5A2A3A" Margin="8,0,0,0"/>
        <Button x:Name="btnDone" Style="{StaticResource Btn}" Content="Done" Background="#8A55F0" Margin="8,0,0,0"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

    $ui = @{}
    $uiNames = 'Header','btnX','rbTime','rbDate','tbSearch','lbFonts','slSize','lblSize','slOpacity','lblOpacity',
               'rbAuto','rbDefault','rbCustom','rbImage','pnlAuto','pnlCustom','pnlImage','slLight','lblLight',
               'wpSwatches','rectPrev','tbHex','btnPick','btnImage','lblImage','slGlow','lblGlow','cbHour',
               'btnReset','btnQuit','btnDone'

    $script:allFonts = @([Windows.Media.Fonts]::SystemFontFamilies | ForEach-Object { $_.Source } | Sort-Object)

    function Get-CurFont { if ($ui.rbTime.IsChecked) { $S.TimeFont } else { $S.DateFont } }

    function Fill-Fonts {
        $q = $ui.tbSearch.Text.Trim()
        $items = if ($q) { @($script:allFonts | Where-Object { $_.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) } else { @($script:allFonts) }
        $ui.lbFonts.ItemsSource = [string[]]$items
        $f = Get-CurFont
        if ($items -contains $f) {
            $ui.lbFonts.SelectedItem = $f
            $ui.lbFonts.UpdateLayout()
            $ui.lbFonts.ScrollIntoView($f)
        }
    }

    function Set-Labels {
        $ui.lblSize.Text    = "{0:N0} px" -f $ui.slSize.Value
        $ui.lblOpacity.Text = "{0:N0}%" -f $ui.slOpacity.Value
        $ui.lblLight.Text   = "{0:N0}%" -f $ui.slLight.Value
        $ui.lblGlow.Text    = "{0:N0}%" -f $ui.slGlow.Value
    }

    function Update-Panels {
        $ui.pnlAuto.Visibility   = if ($S.ColorMode -eq 'Auto')   { 'Visible' } else { 'Collapsed' }
        $ui.pnlCustom.Visibility = if ($S.ColorMode -eq 'Custom') { 'Visible' } else { 'Collapsed' }
        $ui.pnlImage.Visibility  = if ($S.ColorMode -eq 'Image')  { 'Visible' } else { 'Collapsed' }
    }

    function Load-UI {
        $script:loading = $true
        try {
            if ($ui.rbTime.IsChecked) {
                $ui.slSize.Minimum = 40; $ui.slSize.Maximum = 300
                $ui.slSize.Value = [double]$S.TimeSize; $ui.slOpacity.Value = [double]$S.TimeOpacity
            } else {
                $ui.slSize.Minimum = 10; $ui.slSize.Maximum = 90
                $ui.slSize.Value = [double]$S.DateSize; $ui.slOpacity.Value = [double]$S.DateOpacity
            }
            Fill-Fonts
            $m = [string]$S.ColorMode
            if ('Auto','Default','Custom','Image' -notcontains $m) { $m = 'Auto'; $S.ColorMode = $m }
            $ui["rb$m"].IsChecked = $true
            $ui.slLight.Value = [double]$S.TintLighten
            $ui.slGlow.Value  = [double]$S.Glow
            $ui.cbHour.IsChecked = [bool]$S.Use24h
            $ui.tbHex.Text = [string]$S.CustomColor
            $ui.rectPrev.Background = New-Object Windows.Media.SolidColorBrush (ConvertTo-WpfColor $S.CustomColor)
            $ui.lblImage.Text = if ($S.ImagePath) { Split-Path $S.ImagePath -Leaf } else { 'No image selected' }
            Set-Labels
            Update-Panels
        } finally { $script:loading = $false }
    }

    function Set-Mode($m) {
        $S.ColorMode = $m
        $script:loading = $true
        try {
            $ui["rb$m"].IsChecked = $true
            $ui.lblImage.Text = if ($S.ImagePath) { Split-Path $S.ImagePath -Leaf } else { 'No image selected' }
        } finally { $script:loading = $false }
        Update-Panels
        Apply-Style
        Request-Save
    }

    function Set-Custom($hex, [bool]$fromTextbox) {
        $S.CustomColor = $hex.ToUpper()
        $script:loading = $true
        try {
            if (-not $fromTextbox) { $ui.tbHex.Text = $S.CustomColor }
            $ui.rectPrev.Background = New-Object Windows.Media.SolidColorBrush (ConvertTo-WpfColor $S.CustomColor)
        } finally { $script:loading = $false }
        Set-Mode 'Custom'
    }

    function Show-Settings {
        if ($script:setWin -and $script:setWin.IsLoaded) { $script:setWin.Activate(); return }
        $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$SettingsXaml)))
        $script:setWin = $win
        $win.MaxHeight = [System.Windows.SystemParameters]::WorkArea.Height
        $ui.Clear()
        foreach ($n in $uiNames) { $ui[$n] = $win.FindName($n) }

        # swatches
        foreach ($hex in '#FFFFFF','#B000FF','#00E5FF','#FF2D95','#39FF14','#FFD60A','#FF5A36','#4C8DFF') {
            $b = New-Object Windows.Controls.Button
            $b.Style = $win.FindResource('Btn')
            $b.Width = 28; $b.Height = 28; $b.Padding = '0'
            $b.Margin = '0,0,8,8'
            $b.Tag = $hex
            $b.Background = New-Object Windows.Media.SolidColorBrush (ConvertTo-WpfColor $hex)
            $b.Add_Click({ param($sender, $e) Set-Custom $sender.Tag $false })
            [void]$ui.wpSwatches.Children.Add($b)
        }

        # header / buttons
        $ui.Header.Add_MouseLeftButtonDown({ $script:setWin.DragMove() })
        $ui.btnX.Add_Click({ $script:setWin.Close() })
        $ui.btnDone.Add_Click({ $script:setWin.Close() })
        $ui.btnQuit.Add_Click({ $script:setWin.Close(); $window.Close() })
        $ui.btnReset.Add_Click({
            foreach ($k in @($Defaults.Keys)) { if ($k -notin 'Right','Top') { $S[$k] = $Defaults[$k] } }
            $ui.tbSearch.Text = ''
            Load-UI; Apply-Style; & $refresh; Request-Save
        })
        $win.Add_Closed({ Save-Settings })

        # target switch (time / date)
        $ui.rbTime.Add_Checked({ if (-not $script:loading) { Load-UI } })
        $ui.rbDate.Add_Checked({ if (-not $script:loading) { Load-UI } })

        # fonts
        $ui.tbSearch.Add_TextChanged({
            if ($script:loading) { return }
            $script:loading = $true
            try { Fill-Fonts } finally { $script:loading = $false }
        })
        $ui.lbFonts.Add_SelectionChanged({
            if ($script:loading -or -not $ui.lbFonts.SelectedItem) { return }
            if ($ui.rbTime.IsChecked) { $S.TimeFont = [string]$ui.lbFonts.SelectedItem } else { $S.DateFont = [string]$ui.lbFonts.SelectedItem }
            Apply-Style; Request-Save
        })

        # sliders
        $ui.slSize.Add_ValueChanged({
            if ($script:loading) { return }
            $v = [int][math]::Round($ui.slSize.Value)
            if ($ui.rbTime.IsChecked) { $S.TimeSize = $v } else { $S.DateSize = $v }
            Set-Labels; Apply-Style; Request-Save
        })
        $ui.slOpacity.Add_ValueChanged({
            if ($script:loading) { return }
            $v = [int][math]::Round($ui.slOpacity.Value)
            if ($ui.rbTime.IsChecked) { $S.TimeOpacity = $v } else { $S.DateOpacity = $v }
            Set-Labels; Apply-Style; Request-Save
        })
        $ui.slLight.Add_ValueChanged({
            if ($script:loading) { return }
            $S.TintLighten = [int][math]::Round($ui.slLight.Value)
            Set-Labels; Apply-Style; Request-Save
        })
        $ui.slGlow.Add_ValueChanged({
            if ($script:loading) { return }
            $S.Glow = [int][math]::Round($ui.slGlow.Value)
            Set-Labels; Apply-Style; Request-Save
        })

        # color mode
        $ui.rbAuto.Add_Checked({ if (-not $script:loading) { Set-Mode 'Auto' } })
        $ui.rbDefault.Add_Checked({ if (-not $script:loading) { Set-Mode 'Default' } })
        $ui.rbCustom.Add_Checked({ if (-not $script:loading) { Set-Mode 'Custom' } })
        $ui.rbImage.Add_Checked({ if (-not $script:loading) { Set-Mode 'Image' } })

        $ui.tbHex.Add_TextChanged({
            if ($script:loading) { return }
            $t = $ui.tbHex.Text.Trim()
            if ($t -notmatch '^#') { $t = "#$t" }
            if ($t -match '^#[0-9A-Fa-f]{6}$') { Set-Custom $t $true }
        })
        $ui.btnPick.Add_Click({
            $script:setWin.Topmost = $false
            try {
                $dlg = New-Object System.Windows.Forms.ColorDialog
                $dlg.FullOpen = $true
                $cc = ConvertTo-WpfColor $S.CustomColor
                $dlg.Color = [System.Drawing.Color]::FromArgb($cc.R, $cc.G, $cc.B)
                if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    Set-Custom ('#{0:X2}{1:X2}{2:X2}' -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B) $false
                }
            } finally { $script:setWin.Topmost = $true }
        })
        $ui.btnImage.Add_Click({
            $script:setWin.Topmost = $false
            try {
                $dlg = New-Object Microsoft.Win32.OpenFileDialog
                $dlg.Filter = 'Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif|All files|*.*'
                if ($dlg.ShowDialog($script:setWin)) {
                    $S.ImagePath = $dlg.FileName
                    Set-Mode 'Image'
                }
            } finally { $script:setWin.Topmost = $true }
        })

        # 24h
        $ui.cbHour.Add_Click({ $S.Use24h = [bool]$ui.cbHour.IsChecked; & $refresh; Request-Save })

        Load-UI
        $win.Show()
        $win.Activate()
    }

    # ================= Window behavior =================
    $window.Add_SizeChanged({
        $window.Left = [System.Windows.SystemParameters]::PrimaryScreenWidth - $window.ActualWidth - [double]$S.Right
        $window.Top  = [double]$S.Top
    })
    $window.Add_ContentRendered({
        Log "Shown at $($window.Left),$($window.Top) size $($window.ActualWidth)x$($window.ActualHeight)"
    })
    $window.Add_MouseLeftButtonDown({
        $window.DragMove()
        $S.Right = [int][math]::Round([System.Windows.SystemParameters]::PrimaryScreenWidth - $window.Left - $window.ActualWidth)
        $S.Top   = [int][math]::Round($window.Top)
        Request-Save
    })
    $window.Add_MouseRightButtonUp({ Show-Settings })
    $window.Add_Closed({ if ($script:setWin) { try { $script:setWin.Close() } catch {} } })

    $ErrorActionPreference = 'Continue'
    $null = $window.ShowDialog()
    Save-Settings
}
catch {
    Log ("ERROR: " + ($_ | Out-String))
    Write-Host ($_ | Out-String) -ForegroundColor Yellow
    if (-not $env:NEON_HIDDEN) { Read-Host 'Press Enter to close' }
}
