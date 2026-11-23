param([switch]$SelfTest)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
if (-not ('PhoneDeskBluetooth' -as [type])) {
    Add-Type -ReferencedAssemblies System.dll -TypeDefinition @'
using System;
using System.IO;
using System.IO.Ports;
using System.Threading;

public sealed class PhoneDeskBluetooth : IDisposable {
    readonly SerialPort port;
    volatile bool stopping;
    public volatile bool Connected;
    public volatile string Error;
    byte[] frame;
    public PhoneDeskBluetooth(string name) {
        port = new SerialPort(name,115200);
        port.ReadTimeout = 350;
        port.WriteTimeout = 350;
        new Thread(Read) { IsBackground = true }.Start();
    }
    public byte[] TakeFrame() { return Interlocked.Exchange(ref frame, null); }
    void Fill(byte[] buffer, DateTime deadline) {
        int offset = 0;
        while (offset < buffer.Length && !stopping) {
            if (DateTime.UtcNow > deadline) throw new TimeoutException("Bluetooth: телефон не отвечает.");
            try { offset += port.Read(buffer,offset,buffer.Length-offset); }
            catch (TimeoutException) {}
        }
        if (stopping) throw new IOException("Disconnected");
    }
    static int Word(byte[] bytes) {
        return (bytes[0]<<24)|(bytes[1]<<16)|(bytes[2]<<8)|bytes[3];
    }
    void Read() {
        try {
            port.Open();
            if (stopping) return;
            byte[] header = new byte[4];
            Fill(header,DateTime.UtcNow.AddSeconds(15));
            if (Word(header) != 0x50484431) throw new IOException("Выбранный порт не принадлежит «Точке связи».");
            Connected = true;
            while (!stopping) {
                Fill(header,DateTime.UtcNow.AddSeconds(30));
                int length = Word(header);
                if (length < 4 || length > 400000) throw new IOException("Bluetooth: неверный размер кадра.");
                byte[] data = new byte[length];
                Fill(data,DateTime.UtcNow.AddSeconds(10));
                if (data[0] != 255 || data[1] != 216) throw new IOException("Bluetooth: неверный кадр.");
                Interlocked.Exchange(ref frame,data);
            }
        } catch (Exception e) {
            if (!stopping) Error = e.Message;
        } finally {
            Connected = false;
            try { port.Dispose(); } catch (IOException) {}
        }
    }
    public static byte[] GesturePacket(int x1,int y1,int x2,int y2,int ms) {
        byte[] packet = new byte[11];
        packet[0] = 1;
        int[] values = {x1,y1,x2,y2,ms};
        for (int i=0; i<values.Length; i++) {
            packet[1+i*2]=(byte)(values[i]>>8);
            packet[2+i*2]=(byte)values[i];
        }
        return packet;
    }
    public void Gesture(int x1,int y1,int x2,int y2,int ms) {
        if (!Connected) return;
        byte[] data = GesturePacket(x1,y1,x2,y2,ms);
        try { port.Write(data,0,data.Length); }
        catch (Exception e) { if (!stopping) Error = e.Message; }
    }
    public void Dispose() {
        stopping = true;
        Connected = false;
        ThreadPool.QueueUserWorkItem(delegate { try { port.Dispose(); } catch (Exception) {} });
    }
}
'@
}
if ($SelfTest) {
    $packet=[PhoneDeskBluetooth]::GesturePacket(10000,0,5000,2500,100)
    if ([BitConverter]::ToString($packet) -ne '01-27-10-00-00-13-88-09-C4-00-64') { throw 'Gesture protocol check failed' }
    'Bluetooth viewer protocol check passed'
    return
}
[xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="Точка связи · Bluetooth" Width="860" Height="680" MinWidth="580" MinHeight="460"
 WindowStartupLocation="CenterScreen" Background="#101522" Foreground="#E9EFFC" FontFamily="Segoe UI" FontSize="14">
 <DockPanel Margin="20">
  <StackPanel DockPanel.Dock="Top">
   <TextBlock Text="Экран Android по Bluetooth" FontSize="25" Margin="0,0,0,12"/>
   <TextBlock TextWrapping="Wrap" Text="Запустите трансляцию на Android и выберите исходящий COM‑порт телефона." Margin="0,0,0,10"/>
   <WrapPanel Margin="0,0,0,12">
    <ComboBox x:Name="Port" Width="110" Margin="0,0,8,0" IsEditable="True" AutomationProperties.Name="COM-порт"/>
    <Button x:Name="Refresh" Content="Обновить порты" Padding="9,4" Margin="0,0,8,0"/>
    <Button x:Name="Connect" Content="Подключить" Padding="9,4" Margin="0,0,8,0"/>
    <Button x:Name="Disconnect" Content="Отключить" Padding="9,4"/>
   </WrapPanel>
  </StackPanel>
  <TextBlock DockPanel.Dock="Bottom" TextWrapping="Wrap" x:Name="Status" Margin="0,12,0,0" Text="Щелчок и перетаскивание работают после включения службы управления на Android."/>
  <Border Background="#080B11" Padding="12">
   <Image x:Name="Screen" Stretch="Uniform" Cursor="Cross"/>
  </Border>
 </DockPanel>
</Window>
'@
$reader=[Xml.XmlNodeReader]::new($markup)
try { $viewer=[Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
$portPicker=$viewer.FindName('Port')
$screen=$viewer.FindName('Screen')
$status=$viewer.FindName('Status')
$state=@{ Link=$null; Down=$null; Started=[DateTime]::MinValue }
function Update-Ports {
    $previous=$portPicker.Text
    $portPicker.ItemsSource=@([IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
    if ($previous) { $portPicker.Text=$previous }
    elseif ($portPicker.Items.Count -eq 1) { $portPicker.SelectedIndex=0 }
}
function Disconnect-Viewer {
    if ($state.Link) { $state.Link.Dispose(); $state.Link=$null }
    if ($screen.IsMouseCaptured) { $screen.ReleaseMouseCapture() }
    $state.Down=$null
    $screen.Source=$null
}
function Screen-Point($eventArgs) {
    if (-not $screen.Source -or -not $screen.ActualWidth -or -not $screen.ActualHeight) { return }
    $scale=[Math]::Min($screen.ActualWidth/$screen.Source.PixelWidth,$screen.ActualHeight/$screen.Source.PixelHeight)
    $width=$screen.Source.PixelWidth*$scale
    $height=$screen.Source.PixelHeight*$scale
    $position=$eventArgs.GetPosition($screen)
    $x=($position.X-($screen.ActualWidth-$width)/2)/$width
    $y=($position.Y-($screen.ActualHeight-$height)/2)/$height
    if ($x -lt 0 -or $x -gt 1 -or $y -lt 0 -or $y -gt 1) { return }
    @{ X=[int][Math]::Round(10000*$x); Y=[int][Math]::Round(10000*$y) }
}
$viewer.FindName('Refresh').Add_Click({ Update-Ports })
$viewer.FindName('Connect').Add_Click({
    $name=$portPicker.Text.Trim()
    if ($name -notmatch '^COM[1-9][0-9]{0,3}$') {
        $status.Text='Введите номер исходящего COM‑порта, например COM5.'
        return
    }
    Disconnect-Viewer
    $state.Link=[PhoneDeskBluetooth]::new($name.ToUpperInvariant())
    $status.Text='Подключаемся по Bluetooth…'
})
$viewer.FindName('Disconnect').Add_Click({ Disconnect-Viewer; $status.Text='Соединение закрыто.' })
$screen.Add_MouseLeftButtonDown({
    param($sender,$e)
    if (-not $state.Link -or -not $state.Link.Connected) { return }
    $state.Down=Screen-Point $e
    if ($state.Down) {
        $state.Started=[DateTime]::UtcNow
        $null=$screen.CaptureMouse()
    }
})
$screen.Add_MouseLeftButtonUp({
    param($sender,$e)
    $start=$state.Down
    $state.Down=$null
    if ($screen.IsMouseCaptured) { $screen.ReleaseMouseCapture() }
    if (-not $start -or -not $state.Link -or -not $state.Link.Connected) { return }
    $finish=Screen-Point $e
    if (-not $finish) { return }
    $elapsed=[int]([DateTime]::UtcNow-$state.Started).TotalMilliseconds
    $state.Link.Gesture($start.X,$start.Y,$finish.X,$finish.Y,[Math]::Max(30,[Math]::Min(1000,$elapsed)))
})
$timer=[Windows.Threading.DispatcherTimer]::new()
$timer.Interval=[TimeSpan]::FromMilliseconds(90)
$timer.Add_Tick({
    if (-not $state.Link) { return }
    $errorText=$state.Link.Error
    if ($errorText) { Disconnect-Viewer; $status.Text=$errorText; return }
    $bytes=$state.Link.TakeFrame()
    if (-not $bytes) { return }
    $stream=[IO.MemoryStream]::new($bytes)
    try {
        $bitmap=[Windows.Media.Imaging.BitmapImage]::new()
        $bitmap.BeginInit()
        $bitmap.CacheOption='OnLoad'
        $bitmap.StreamSource=$stream
        $bitmap.EndInit()
        $screen.Source=$bitmap
        $status.Text='Подключено по Bluetooth. Чтобы управлять экраном, включите службу управления на телефоне.'
    } catch { $status.Text='Не удалось открыть кадр Bluetooth.' }
    finally { $stream.Dispose() }
})
$viewer.Add_Closed({ $timer.Stop(); Disconnect-Viewer })
Update-Ports
$timer.Start()
$null=$viewer.ShowDialog()
