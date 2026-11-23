param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'QRCoder.dll')
$engine = Join-Path $PSScriptRoot 'engine'
$adb = Join-Path $engine 'adb.exe'
$scrcpy = Join-Path $engine 'scrcpy.exe'
$env:ADB = $adb
$settingsPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PhoneDesk\settings.json'
$script:preferences = @{
    Phones = @{}; Favorites = @{}; Device = ''; Joystick = $null
    ClipboardBox = $true; FullscreenBox = $false; GameModeBox = $false; GamepadBox = $false
}
if (-not $SelfTest -and [IO.File]::Exists($settingsPath)) {
    try {
        $saved = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
        foreach ($key in @('Phones','Favorites')) {
            foreach ($item in $saved.$key.PSObject.Properties) { $script:preferences[$key][$item.Name] = $item.Value }
        }
        foreach ($key in @('Device','Joystick','ClipboardBox','FullscreenBox','GameModeBox','GamepadBox')) {
            if ($saved.PSObject.Properties[$key]) { $script:preferences[$key] = $saved.$key }
        }
    } catch { }
}

function Save-Preferences {
    if ($SelfTest) { return }
    try {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($settingsPath))
        $temp = $settingsPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($temp, ($script:preferences | ConvertTo-Json -Depth 5))
        if ([IO.File]::Exists($settingsPath)) { [IO.File]::Replace($temp,$settingsPath,$null) }
        else { [IO.File]::Move($temp,$settingsPath) }
    } catch { Set-Status 'Не удалось сохранить настройки.' }
    finally { if ($temp -and [IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Read-Window([string]$name) {
    [xml]$layout = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $name))
    $reader = [Xml.XmlNodeReader]::new($layout)
    try { [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
}

$window = Read-Window 'MainWindow.xaml'
$ui = @{}
foreach ($name in ('DevicePicker,DeviceTitle,DeviceDetails,HomePage,AppsPage,FilesPage,PhotosPage,SettingsPage,ScreenButton,ShotButton,AppSearch,FavoritesOnly,LoadAppsButton,AppList,OpenAppButton,FavoriteButton,FileList,FolderText,ParentButton,ListFilesButton,UploadButton,DownloadButton,PhotoList,Preview,ListPhotosButton,SavePhotoButton,ClipboardBox,FullscreenBox,GameModeBox,GamepadBox,JoystickButton,Status,PairButton,RefreshButton,HomeNav,AppsNav,FilesNav,PhotosNav,SettingsNav,AppsQuick,FilesQuick,PhotosQuick' -split ',')) {
    $ui[$name] = $window.FindName($name)
    if (-not $ui[$name]) { throw "Missing control: $name" }
}
function Set-Status([string]$message) { $ui.Status.Text = $message }
function Quote-Argument([string]$value) {
    '"' + ([regex]::Replace([regex]::Replace($value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')) + '"'
}
function Quote-Android([string]$value) {
    "'" + $value.Replace("'", "'\''") + "'"
}
function Start-Command($exe, [string[]]$arguments, [switch]$Binary, [switch]$InputStream) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $exe
    $info.Arguments = (($arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $info.WorkingDirectory = $engine
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $InputStream.IsPresent
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::Start($info)
    $buffer = $null
    $output = if ($Binary) {
        $buffer = [IO.MemoryStream]::new()
        $process.StandardOutput.BaseStream.CopyToAsync($buffer)
    } else { $process.StandardOutput.ReadToEndAsync() }
    @{ Process=$process; Output=$output; Error=$process.StandardError.ReadToEndAsync(); Buffer=$buffer }
}
function Read-Result($job) {
    $output = $job.Output.GetAwaiter().GetResult()
    $errorText = $job.Error.GetAwaiter().GetResult()
    if ($job.Process.ExitCode -ne 0) { throw "$errorText $output".Trim() }
    $output
}
function Close-Command($job) {
    if (-not $job) { return }
    if (-not $job.Process.HasExited) { $job.Process.Kill() }
    if ($job.Buffer -and $job.Output.IsCompleted) { $job.Buffer.Dispose() }
    $job.Process.Dispose()
}

$script:job = $null
$script:scan = $null
$script:mirror = $null
$script:previewJob = $null
$script:catalog = @()
$script:phonesSignature = ''
$script:changingPhones = $false
$script:folder = '/sdcard'
$script:nextScan = [DateTime]::MinValue
$script:activePage = 'Home'
$script:lastBattery = ''
$script:stick = $null
$script:touch = $null

function Active-Phone {
    $phone = $ui.DevicePicker.SelectedItem
    if ($phone.State -eq 'device') { $phone }
}
function Update-Buttons {
    $enabled = ($null -ne (Active-Phone)) -and ($null -eq $script:job)
    foreach ($key in @('ScreenButton','ShotButton','LoadAppsButton','ListFilesButton','UploadButton','ListPhotosButton')) {
        $ui[$key].IsEnabled = $enabled
    }
    $ui.ParentButton.IsEnabled = $enabled -and $script:folder -ne '/sdcard'
    $ui.OpenAppButton.IsEnabled = $ui.FavoriteButton.IsEnabled = $enabled -and $null -ne $ui.AppList.SelectedItem
    $ui.DownloadButton.IsEnabled = $enabled -and ($null -ne $ui.FileList.SelectedItem) -and (-not $ui.FileList.SelectedItem.Directory)
    $ui.SavePhotoButton.IsEnabled = $enabled -and $null -ne $ui.PhotoList.SelectedItem
    $ui.JoystickButton.Content = if ($script:stick) { 'Выключить экранный джойстик WASD' } else { 'Настроить экранный джойстик WASD' }
}
function Read-Apps([string]$output) {
    $pattern = '(?m)^[ \t]+[-*][ \t]+(?<name>[^\r\n]+?)(?:[ \t]{2,}|\r?\n[ \t]+)(?<package>[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)[ \t]*\r?$'
    foreach ($match in [regex]::Matches($output,$pattern)) {
        $name = $match.Groups['name'].Value.Trim()
        $package = $match.Groups['package'].Value
        [pscustomobject]@{ Name=$name; Package=$package; Label="$name   ·   $package" }
    }
}
function Filter-Apps {
    $query = $ui.AppSearch.Text.Trim()
    $pkg = $ui.AppList.SelectedItem.Package
    $items = @($script:catalog | Where-Object {
        $_.Label.IndexOf($query,[StringComparison]::CurrentCultureIgnoreCase) -ge 0 -and
        (-not $ui.FavoritesOnly.IsChecked -or $script:preferences.Favorites.ContainsKey($_.Package))
    } | Sort-Object @{Expression={- [int]$script:preferences.Favorites.ContainsKey($_.Package)}},Name)
    $ui.AppList.ItemsSource = $items
    $ui.AppList.SelectedItem = $items | Where-Object Package -eq $pkg | Select-Object -First 1
    Update-Buttons
}
function Update-Phone {
    if ($script:changingPhones) { return }
    $phone = $ui.DevicePicker.SelectedItem
    $script:folder = '/sdcard'
    $script:catalog = @()
    $ui.FileList.ItemsSource = $null
    $ui.PhotoList.ItemsSource = $null
    $ui.Preview.Source = $null
    $ui.FolderText.Text = $script:folder
    Filter-Apps
    $ui.DeviceTitle.Text = if ($phone) { $phone.Name } else { 'Подключите Android' }
    $ui.DeviceDetails.Text = if ($phone) { $phone.Label } else { 'Откройте QR-код и отсканируйте его в меню беспроводной отладки Android.' }
    if ($phone.State -eq 'device' -and $script:preferences.Device -ne $phone.Serial) {
        $script:preferences.Device = $phone.Serial
        Save-Preferences
    }
    Update-Buttons
}
function Show-Phones([string]$output) {
    $result = [Collections.Generic.List[object]]::new()
    $seen = @{}
    $changed = $false
    foreach ($line in ($output -split '\r?\n')) {
        if ($line -notmatch '^([A-Za-z0-9._:%\[\]-]+)[ \t]+(device|unauthorized|offline)(?:[ \t]+(.*))?$') { continue }
        $serial,$state,$details = $Matches[1],$Matches[2],$Matches[3]
        $name = if ($details -match '\bmodel:(\S+)') { $Matches[1].Replace('_',' ') }
            elseif ($script:preferences.Phones.ContainsKey($serial)) { $script:preferences.Phones[$serial] }
            else { 'Android' }
        $label = switch ($state) {
            'device' { "$name  ·  подключён" }
            'unauthorized' { "$name  ·  подтвердите доступ" }
            default { "$name  ·  не в сети" }
        }
        $result.Add([pscustomobject]@{ Serial=$serial; Name=$name; State=$state; Label=$label })
        $seen[$serial] = $true
        if ($state -eq 'device' -and $script:preferences.Phones[$serial] -ne $name) {
            $script:preferences.Phones[$serial] = $name
            $changed = $true
        }
    }
    foreach ($serial in ($script:preferences.Phones.Keys | Sort-Object)) {
        if ($seen.ContainsKey($serial)) { continue }
        $name = $script:preferences.Phones[$serial]
        $result.Add([pscustomobject]@{ Serial=$serial; Name=$name; State='offline'; Label="$name  ·  не в сети" })
    }
    $signature = ($result | ForEach-Object { "$($_.Serial):$($_.State):$($_.Name)" }) -join '|'
    if ($signature -ne $script:phonesSignature) {
        $previous = $ui.DevicePicker.SelectedItem
        $requested = if ($previous) { $previous.Serial } else { $script:preferences.Device }
        $choice = $result | Where-Object { $_.State -eq 'device' -and $_.Serial -eq $requested } | Select-Object -First 1
        if (-not $choice) { $choice = $result | Where-Object State -eq 'device' | Select-Object -First 1 }
        if (-not $choice) { $choice = $result | Where-Object Serial -eq $requested | Select-Object -First 1 }
        if (-not $choice) { $choice = $result | Select-Object -First 1 }
        $script:changingPhones = $true
        try {
            $ui.DevicePicker.ItemsSource = $result.ToArray()
            $ui.DevicePicker.SelectedItem = $choice
        } finally { $script:changingPhones = $false }
        $script:phonesSignature = $signature
        if ($previous.Serial -ne $choice.Serial -or $previous.State -ne $choice.State -or $previous.Name -ne $choice.Name) { Update-Phone }
    }
    if ($changed) { Save-Preferences }
}

function Open-Job($exe,[string[]]$arguments,[string]$message,[scriptblock]$done,$data,[switch]$Binary) {
    if ($script:job) { return }
    try {
        $script:job = Start-Command $exe $arguments -Binary:$Binary
        $script:job.Done = $done
        $script:job.Data = $data
        $script:job.Serial = (Active-Phone).Serial
        $script:job.Deadline = [DateTime]::UtcNow.AddSeconds(120)
        Set-Status $message
    } catch { Set-Status $_.Exception.Message }
    Update-Buttons
}

function Read-Bitmap([byte[]]$data) {
    $stream = [IO.MemoryStream]::new($data)
    try {
        $image = [Windows.Media.Imaging.BitmapImage]::new()
        $image.BeginInit()
        $image.CacheOption = 'OnLoad'
        $image.DecodePixelWidth = 720
        $image.StreamSource = $stream
        $image.EndInit()
        $image.Freeze()
        $image
    } finally { $stream.Dispose() }
}
function Read-AppList {
    $phone = Active-Phone
    if (-not $phone) { return }
    Open-Job $scrcpy @("--serial=$($phone.Serial)",'--list-apps') 'Получаем список приложений…' {
        param($result,$output)
        $script:catalog = @(Read-Apps $output | Sort-Object Package -Unique)
        Filter-Apps
        Set-Status "Приложений в списке: $($script:catalog.Count)."
    }
}
function Open-Android([string]$package) {
    $phone = Active-Phone
    if (-not $phone) { return }
    if ($script:mirror -and -not $script:mirror.Process.HasExited) {
        if ($script:mirror.Serial -ne $phone.Serial) { Set-Status 'Сначала закройте окно предыдущего телефона.'; return }
        if ($package) {
            $command = 'am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p ' + (Quote-Android $package)
            Open-Job $adb @('-s',$phone.Serial,'shell',$command) 'Запускаем приложение…' {
                param($result,$output)
                if ($output -match 'Error:') { throw $output }
                Set-Status 'Приложение открыто в окне Android.'
            }
        } else { Set-Status 'Окно Android уже открыто.' }
        return
    }
    if ($script:mirror) { Close-Command $script:mirror; $script:mirror = $null }
    $options = @("--serial=$($phone.Serial)",'--window-title=Точка связи | Android')
    if (-not $ui.ClipboardBox.IsChecked) { $options += '--no-clipboard-autosync' }
    if ($ui.FullscreenBox.IsChecked) { $options += '--fullscreen' }
    if ($ui.GamepadBox.IsChecked) { $options += '--gamepad=uhid' }
    if ($ui.GameModeBox.IsChecked) { $options += '--keyboard=uhid','--max-fps=60','--max-size=1280' }
    if ($package) { $options += "--start-app=$package" }
    try {
        $script:mirror = Start-Command $scrcpy $options
        $script:mirror.Serial = $phone.Serial
        Set-Status 'Открываем экран. При необходимости разблокируйте телефон.'
    } catch { Set-Status $_.Exception.Message }
}
function Read-Folder([string]$path) {
    $phone = Active-Phone
    if (-not $phone) { return }
    Open-Job $adb @('-s',$phone.Serial,'shell',('ls -1p ' + (Quote-Android ($path+'/')))) 'Читаем папку телефона…' {
        param($result,$output)
        $path = [string]$result.Data
        $items = foreach ($line in ($output -split '\r?\n')) {
            $name = $line.TrimEnd('/')
            if (-not $name -or $name -in @('.','..') -or $name.Contains('/')) { continue }
            $directory = $line.EndsWith('/')
            [pscustomobject]@{
                Name=$name; Path="$path/$name"; Directory=$directory
                Label=if ($directory) { "Папка   $name" } else { $name }
            }
        }
        $script:folder = $path
        $ui.FolderText.Text = $path
        $ui.FileList.ItemsSource = @($items | Sort-Object @{Expression={- [int]$_.Directory}},Name)
        Set-Status 'Папка открыта.'
    } $path
}
function Save-PhoneFile($file) {
    $phone = Active-Phone
    if (-not $phone -or -not $file -or $file.Directory) { return }
    $picker = [Microsoft.Win32.SaveFileDialog]::new()
    $picker.FileName = $file.Name -replace '[<>:"/\\|?*]','_'
    if ($picker.ShowDialog($window) -ne $true) { return }
    $temporary = $picker.FileName + '.' + [guid]::NewGuid().ToString('N') + '.part'
    Open-Job $adb @('-s',$phone.Serial,'pull',$file.Path,$temporary) 'Копируем файл на ноутбук…' {
        param($result,$output)
        if ([IO.File]::Exists($result.Data.Destination)) { [IO.File]::Replace($result.Data.Temp,$result.Data.Destination,$null) }
        else { [IO.File]::Move($result.Data.Temp,$result.Data.Destination) }
        Set-Status 'Файл сохранён.'
    } @{ Destination=$picker.FileName; Temp=$temporary }
}
function Read-Photos {
    $phone = Active-Phone
    if (-not $phone) { return }
    $command = 'for dir in /sdcard/DCIM /sdcard/Pictures; do if [ -d "$dir" ]; then find "$dir" -type f -print; fi; done'
    Open-Job $adb @('-s',$phone.Serial,'shell',$command) 'Ищем фотографии…' {
        param($result,$output)
        $photos = foreach ($line in ($output -split '\r?\n')) {
            if ($line -notmatch '^/sdcard/(?:DCIM|Pictures)/.+\.(?:jpe?g|png|bmp)$') { continue }
            $name = $line.Substring($line.LastIndexOf('/')+1)
            [pscustomobject]@{ Name=$name; Path=$line; Label=$name; Directory=$false }
        }
        $ui.PhotoList.ItemsSource = @($photos | Sort-Object Name -Descending)
        Set-Status "Найдено фото и снимков: $($ui.PhotoList.Items.Count)."
    }
}
function Show-Photo {
    if ($script:previewJob) { Close-Command $script:previewJob; $script:previewJob = $null }
    $ui.Preview.Source = $null
    $phone = Active-Phone
    $photo = $ui.PhotoList.SelectedItem
    if (-not $phone -or -not $photo) { return }
    try {
        $command = 'file=' + (Quote-Android $photo.Path) + '; size=$(wc -c < "$file") && [ "$size" -le 31457280 ] && cat "$file"'
        $script:previewJob = Start-Command $adb @('-s',$phone.Serial,'exec-out',$command) -Binary
        $script:previewJob.Deadline = [DateTime]::UtcNow.AddSeconds(30)
    } catch { Set-Status 'Предпросмотр недоступен.' }
}
function Take-Screenshot {
    $phone = Active-Phone
    if (-not $phone) { return }
    $picker = [Microsoft.Win32.SaveFileDialog]::new()
    $picker.FileName = 'Android-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png'
    $picker.Filter = 'PNG (*.png)|*.png'
    if ($picker.ShowDialog($window) -ne $true) { return }
    Open-Job $adb @('-s',$phone.Serial,'exec-out','screencap','-p') 'Сохраняем снимок экрана…' {
        param($result,$output)
        $bytes = $result.Buffer.ToArray()
        if ($bytes.Length -lt 24 -or [BitConverter]::ToString($bytes,0,8) -ne '89-50-4E-47-0D-0A-1A-0A') {
            throw 'Телефон не вернул снимок PNG.'
        }
        [IO.File]::WriteAllBytes($result.Data,$bytes)
        Set-Status 'Снимок экрана сохранён.'
    } $picker.FileName -Binary
}

function New-Dialog([string]$title,[double]$width,[double]$height) {
    $dialog = [Windows.Window]::new()
    $dialog.Title = $title
    $dialog.Owner = $window
    $dialog.Width = $width
    $dialog.Height = $height
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.ResizeMode = 'NoResize'
    $panel = [Windows.Controls.StackPanel]::new()
    $panel.Margin = [Windows.Thickness]::new(24)
    $dialog.Content = $panel
    $dialog
}
function Add-Text($parent,[string]$text,[double]$size=14) {
    $control = [Windows.Controls.TextBlock]::new()
    $control.Text = $text
    $control.FontSize = $size
    $control.TextWrapping = 'Wrap'
    $control.Margin = [Windows.Thickness]::new(0,0,0,8)
    $null = $parent.Children.Add($control)
    $control
}
function Add-Field($parent,[double]$width,[string]$tip) {
    $field = [Windows.Controls.TextBox]::new()
    $field.Width = $width
    $field.ToolTip = $tip
    $field.Padding = [Windows.Thickness]::new(6)
    $field.Margin = [Windows.Thickness]::new(0,0,8,5)
    $null = $parent.Children.Add($field)
    $field
}
function Add-DialogButton($parent,[string]$title) {
    $button = [Windows.Controls.Button]::new()
    $button.Content = $title
    $button.Padding = [Windows.Thickness]::new(9,4,9,4)
    $button.Margin = [Windows.Thickness]::new(0,0,0,5)
    $null = $parent.Children.Add($button)
    $button
}
function New-QrImage([string]$service,[string]$password) {
    $generator = [QRCoder.QRCodeGenerator]::new()
    try {
        $data = $generator.CreateQrCode("WIFI:T:ADB;S:$service;P:$password;;",[QRCoder.QRCodeGenerator+ECCLevel]::M)
        try {
            $qr = [QRCoder.PngByteQRCode]::new($data)
            try { Read-Bitmap ($qr.GetGraphic(7)) } finally { $qr.Dispose() }
        } finally { $data.Dispose() }
    } finally { $generator.Dispose() }
}
function Find-PairingAddress([string]$output,[string]$service) {
    $pattern = '(?m)^' + [regex]::Escape($service) + '[ \t]+_adb-tls-pairing\._tcp\.?(?:\.local\.?)?[ \t]+(\d{1,3}(?:\.\d{1,3}){3}:[1-9]\d{0,4})[ \t]*\r?$'
    $match = [regex]::Match($output,$pattern)
    if ($match.Success) { $match.Groups[1].Value }
}
function Test-Address([string]$value) { $value -match '^(?:\d{1,3}(?:\.\d{1,3}){3}|\[[0-9A-Fa-f:%]+\]):[1-9]\d{0,4}$' }
function Open-Pairing {
    $dialog = New-Dialog 'Подключить телефон' 560 635
    $panel = $dialog.Content
    $null = Add-Text $panel 'Подключение по QR' 25
    $null = Add-Text $panel 'Android 11 и новее. Подключите устройства к одной сети Wi-Fi. На телефоне откройте «Параметры разработчика → Беспроводная отладка → Сопряжение с помощью QR-кода».'
    $service = 'studio-' + [guid]::NewGuid().ToString('N').Substring(0,10)
    $password = [guid]::NewGuid().ToString('N').Substring(0,16)
    $image = [Windows.Controls.Image]::new()
    $image.Width = $image.Height = 210
    $image.Source = New-QrImage $service $password
    $null = $panel.Children.Add($image)
    $feedback = Add-Text $panel 'Ожидание сканирования…'
    $feedback.MinHeight = 45
    $null = Add-Text $panel 'Ручное сопряжение: IP:порт и шестизначный код из окна сопряжения'
    $pairRow = [Windows.Controls.StackPanel]::new()
    $pairRow.Orientation = 'Horizontal'
    $null = $panel.Children.Add($pairRow)
    $pairAddress = Add-Field $pairRow 165 'IP:порт для сопряжения'
    $code = Add-Field $pairRow 80 'Код'
    $code.MaxLength = 6
    $pairButton = Add-DialogButton $pairRow 'Сопрячь'
    $null = Add-Text $panel 'После сопряжения: IP:порт с основного экрана беспроводной отладки'
    $connectRow = [Windows.Controls.StackPanel]::new()
    $connectRow.Orientation = 'Horizontal'
    $null = $panel.Children.Add($connectRow)
    $address = Add-Field $connectRow 165 'IP:порт для подключения'
    $connectButton = Add-DialogButton $connectRow 'Подключить'
    $pairState = @{ Job=$null; Phase='discover'; Limit=[DateTime]::UtcNow.AddMinutes(2); HostIp='' }
    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(600)
    $pairButton.Add_Click({
        $target = $pairAddress.Text.Trim()
        $pin = $code.Text.Trim()
        if (-not (Test-Address $target) -or $pin -notmatch '^[0-9]{6}$') {
            $feedback.Text = 'Введите IP:порт и код из окна сопряжения.'
            return
        }
        Close-Command $pairState.Job
        $pairState.Job = Start-Command $adb @('pair',$target,$pin)
        $pairState.Phase = 'manual'
        $pairState.Limit = [DateTime]::UtcNow.AddSeconds(20)
        $feedback.Text = 'Подтверждаем сопряжение…'
        $timer.Start()
    })
    $connectButton.Add_Click({
        $target = $address.Text.Trim()
        if (-not (Test-Address $target)) { $feedback.Text = 'Введите IP:порт с основного экрана беспроводной отладки.'; return }
        Close-Command $pairState.Job
        $pairState.Job = Start-Command $adb @('connect',$target)
        $pairState.Phase = 'connect'
        $pairState.Limit = [DateTime]::UtcNow.AddSeconds(15)
        $feedback.Text = 'Подключаем телефон…'
        $timer.Start()
    })
    $timer.Add_Tick({
        try {
            if ([DateTime]::UtcNow -gt $pairState.Limit) {
                $timer.Stop()
                Close-Command $pairState.Job
                $pairState.Job = $null
                $feedback.Text = if ($pairState.Phase -eq 'discover') { 'Срок действия QR истёк. Откройте новый код или введите код вручную.' }
                    else { 'Телефон не ответил вовремя. Проверьте адрес или повторите сопряжение.' }
                return
            }
            if ($pairState.Job) {
                if (-not $pairState.Job.Process.HasExited) { return }
                $output = Read-Result $pairState.Job
                Close-Command $pairState.Job
                $pairState.Job = $null
                switch ($pairState.Phase) {
                    'discover' {
                        $target = Find-PairingAddress $output $service
                        if ($target) {
                            $pairState.HostIp = $target.Split(':')[0]
                            $pairState.Job = Start-Command $adb @('pair',$target,$password)
                            $pairState.Phase = 'pair'
                            $feedback.Text = 'Телефон найден. Подтверждаем сопряжение…'
                            return
                        }
                    }
                    'pair' {
                        if ($output -notmatch 'Successfully paired') { throw 'Android не подтвердил сопряжение.' }
                        $pairState.Phase = 'endpoint'
                        $pairState.Limit = [DateTime]::UtcNow.AddSeconds(12)
                        $feedback.Text = 'Телефон сопряжён. Подключаемся…'
                    }
                    'endpoint' {
                        $match = [regex]::Match($output,'(?m)^\S+[ \t]+_adb-tls-connect\._tcp\.?(?:\.local\.?)?[ \t]+(' + [regex]::Escape($pairState.HostIp) + ':[1-9]\d{0,4})(?:\s|$)')
                        if ($match.Success) {
                            $pairState.Job = Start-Command $adb @('connect',$match.Groups[1].Value)
                            $pairState.Phase = 'connect'
                            return
                        }
                    }
                    'manual' {
                        if ($output -notmatch 'Successfully paired') { throw 'Android не подтвердил сопряжение.' }
                        $timer.Stop()
                        $feedback.Text = 'Телефон сопряжён. Теперь подключитесь по адресу с основного экрана отладки.'
                        return
                    }
                    'connect' {
                        if ($output -notmatch '(?im)^(?:already )?connected to ') { throw $output }
                        $dialog.DialogResult = $true
                        return
                    }
                }
            }
            $pairState.Job = Start-Command $adb @('mdns','services')
        } catch {
            $timer.Stop()
            Close-Command $pairState.Job
            $pairState.Job = $null
            $feedback.Text = 'Ошибка подключения. ' + $_.Exception.Message
        }
    })
    try {
        $timer.Start()
        $null = $dialog.ShowDialog()
    } finally {
        $timer.Stop()
        Close-Command $pairState.Job
    }
    $script:nextScan = [DateTime]::MinValue
}

function Move-Stick([int]$dx,[int]$dy) {
    if (-not $script:stick) { return }
    $config = $script:preferences.Joystick
    $commands = @()
    if (-not $dx -and -not $dy) {
        if (-not $script:touch) { return }
        $commands += "input motionevent UP $($script:touch.X) $($script:touch.Y)"
        $script:touch = $null
    } else {
        $length = [math]::Sqrt($dx*$dx+$dy*$dy)
        $x = $config.X + [int][math]::Round($config.Radius*$dx/$length)
        $y = $config.Y + [int][math]::Round($config.Radius*$dy/$length)
        if ($script:touch -and $script:touch.X -eq $x -and $script:touch.Y -eq $y) { return }
        if (-not $script:touch) { $commands += "input motionevent DOWN $($config.X) $($config.Y)" }
        $commands += "input motionevent MOVE $x $y"
        $script:touch = @{X=$x;Y=$y}
    }
    $script:stick.Process.StandardInput.WriteLine(($commands -join '; '))
}
function Stop-Stick {
    $stickTimer.Stop()
    if ($script:stick) {
        $process = $script:stick.Process
        try {
            if (-not $process.HasExited) { Move-Stick 0 0; $process.StandardInput.Close() }
        } catch {}
        finally { $process.Dispose(); $script:stick = $null }
    }
    $script:touch = $null
    Update-Buttons
}
function Open-Stick {
    if ($script:stick) { Stop-Stick; Set-Status 'Экранный джойстик выключен.'; return }
    if (-not $script:mirror -or $script:mirror.Process.HasExited) { Set-Status 'Сначала откройте игру в окне Android.'; return }
    $dialog = New-Dialog 'Экранный джойстик WASD' 500 320
    $panel = $dialog.Content
    $null = Add-Text $panel 'Сделайте снимок игры и укажите центр экранного джойстика и его радиус в пикселях. Отсчёт идёт от верхнего левого угла.'
    $fields = @{}
    $names = [ordered]@{ X='Центр X'; Y='Центр Y'; Radius='Радиус' }
    foreach ($key in $names.Keys) {
        $row = [Windows.Controls.StackPanel]::new()
        $row.Orientation = 'Horizontal'
        $null = $panel.Children.Add($row)
        $label = Add-Text $row $names[$key]
        $label.Width = 135
        $fields[$key] = Add-Field $row 135 $names[$key]
        if ($script:preferences.Joystick) { $fields[$key].Text = [string]$script:preferences.Joystick.$key }
    }
    if (-not $fields.Radius.Text) { $fields.Radius.Text = '50' }
    $button = Add-DialogButton $panel 'Включить WASD'
    $hint = Add-Text $panel ''
    $button.Add_Click({
        $x=$y=$radius=0
        if (-not [int]::TryParse($fields.X.Text,[ref]$x) -or -not [int]::TryParse($fields.Y.Text,[ref]$y) -or
            -not [int]::TryParse($fields.Radius.Text,[ref]$radius) -or $radius -lt 1 -or $x -lt $radius -or $y -lt $radius -or $x -gt 16000 -or $y -gt 16000) {
            $hint.Text = 'Введите корректные координаты и радиус.'
            return
        }
        $script:preferences.Joystick = @{X=$x;Y=$y;Radius=$radius}
        $dialog.DialogResult = $true
    })
    if ($dialog.ShowDialog() -ne $true -or -not $script:mirror -or $script:mirror.Process.HasExited) { return }
    if (-not ('PhoneDeskKeys' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PhoneDeskKeys {
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    public static bool Active(int id) {
        uint owner;
        return GetWindowThreadProcessId(GetForegroundWindow(), out owner) != 0 && owner == (uint)id;
    }
    public static int Down(int key) { return (GetAsyncKeyState(key) & 0x8000) == 0 ? 0 : 1; }
}
'@
    }
    $script:stick = Start-Command $adb @('-s',$script:mirror.Serial,'shell','-T') -InputStream
    $stickTimer.Start()
    Save-Preferences
    Update-Buttons
    Set-Status 'WASD включены. Перейдите в окно игры.'
}
$stickTimer = [Windows.Threading.DispatcherTimer]::new()
$stickTimer.Interval = [TimeSpan]::FromMilliseconds(30)
$stickTimer.Add_Tick({
    try {
        if ($script:stick.Process.HasExited) { throw 'Телефон отключился.' }
        if ($script:mirror -and -not $script:mirror.Process.HasExited -and [PhoneDeskKeys]::Active($script:mirror.Process.Id) -and
            -not ([PhoneDeskKeys]::Down(0x11) -or [PhoneDeskKeys]::Down(0x12) -or [PhoneDeskKeys]::Down(0x5B) -or [PhoneDeskKeys]::Down(0x5C))) {
            Move-Stick ([PhoneDeskKeys]::Down(0x44)-[PhoneDeskKeys]::Down(0x41)) ([PhoneDeskKeys]::Down(0x53)-[PhoneDeskKeys]::Down(0x57))
        } else { Move-Stick 0 0 }
    } catch { Stop-Stick; Set-Status ('Экранный джойстик остановлен. ' + $_.Exception.Message) }
})

function Show-Page([string]$page) {
    $script:activePage = $page
    foreach ($key in @('Home','Apps','Files','Photos','Settings')) {
        $ui[$key+'Page'].Visibility = if ($key -eq $page) { 'Visible' } else { 'Collapsed' }
        $ui[$key+'Nav'].Background = if ($key -eq $page) { [Windows.Media.BrushConverter]::new().ConvertFromString('#2B3851') }
            else { [Windows.Media.Brushes]::Transparent }
    }
    if ($page -eq 'Apps' -and -not $script:catalog.Count) { Read-AppList }
    if ($page -eq 'Files' -and $null -eq $ui.FileList.ItemsSource) { Read-Folder $script:folder }
}

$ui.PairButton.Add_Click({ try { Open-Pairing } catch { Set-Status $_.Exception.Message } })
$ui.RefreshButton.Add_Click({
    $script:nextScan = [DateTime]::MinValue
    Set-Status 'Проверяем подключение…'
})
$ui.DevicePicker.Add_SelectionChanged({ Update-Phone })
$ui.ScreenButton.Add_Click({ Open-Android '' })
$ui.ShotButton.Add_Click({ Take-Screenshot })
$ui.AppSearch.Add_TextChanged({ Filter-Apps })
$ui.FavoritesOnly.Add_Checked({ Filter-Apps })
$ui.FavoritesOnly.Add_Unchecked({ Filter-Apps })
$ui.LoadAppsButton.Add_Click({ Read-AppList })
$ui.AppList.Add_SelectionChanged({ Update-Buttons })
$ui.OpenAppButton.Add_Click({ if ($ui.AppList.SelectedItem) { Open-Android $ui.AppList.SelectedItem.Package } })
$ui.AppList.Add_MouseDoubleClick({
    param($sender,$event)
    if ([Windows.Controls.ItemsControl]::ContainerFromElement($sender,$event.OriginalSource) -is [Windows.Controls.ListBoxItem] -and $ui.AppList.SelectedItem) {
        Open-Android $ui.AppList.SelectedItem.Package
    }
})
$ui.FavoriteButton.Add_Click({
    $app = $ui.AppList.SelectedItem
    if (-not $app) { return }
    if ($script:preferences.Favorites.ContainsKey($app.Package)) {
        $script:preferences.Favorites.Remove($app.Package)
        Set-Status 'Приложение убрано из избранного.'
    } else {
        $script:preferences.Favorites[$app.Package] = $true
        Set-Status 'Приложение добавлено в избранное.'
    }
    Save-Preferences
    Filter-Apps
})
$ui.ListFilesButton.Add_Click({ Read-Folder $script:folder })
$ui.ParentButton.Add_Click({
    if ($script:folder -ne '/sdcard') { Read-Folder ($script:folder.Substring(0,$script:folder.LastIndexOf('/'))) }
})
$ui.FileList.Add_SelectionChanged({ Update-Buttons })
$ui.FileList.Add_MouseDoubleClick({
    param($sender,$event)
    if ([Windows.Controls.ItemsControl]::ContainerFromElement($sender,$event.OriginalSource) -isnot [Windows.Controls.ListBoxItem]) { return }
    $entry = $ui.FileList.SelectedItem
    if ($entry.Directory) { Read-Folder $entry.Path } else { Save-PhoneFile $entry }
})
$ui.DownloadButton.Add_Click({ Save-PhoneFile $ui.FileList.SelectedItem })
$ui.UploadButton.Add_Click({
    $phone = Active-Phone
    if (-not $phone) { return }
    $picker = [Microsoft.Win32.OpenFileDialog]::new()
    if ($picker.ShowDialog($window) -ne $true) { return }
    $target = $script:folder + '/'
    Open-Job $adb @('-s',$phone.Serial,'push',$picker.FileName,$target) 'Отправляем файл…' {
        param($result,$output)
        Set-Status "Файл отправлен в $($result.Data)"
        Read-Folder $script:folder
    } $target
})
$ui.ListPhotosButton.Add_Click({ Read-Photos })
$ui.PhotoList.Add_SelectionChanged({ Update-Buttons; Show-Photo })
$ui.SavePhotoButton.Add_Click({ Save-PhoneFile $ui.PhotoList.SelectedItem })
$ui.JoystickButton.Add_Click({ try { Open-Stick } catch { Set-Status $_.Exception.Message } })
foreach ($key in @('ClipboardBox','FullscreenBox','GameModeBox','GamepadBox')) {
    $ui[$key].IsChecked = [bool]$script:preferences[$key]
    $ui[$key].Add_Click({
        param($sender,$event)
        $script:preferences[$sender.Name] = $sender.IsChecked
        Save-Preferences
    })
}
foreach ($key in @('HomeNav','AppsNav','FilesNav','PhotosNav','SettingsNav','AppsQuick','FilesQuick','PhotosQuick')) {
    $ui[$key].Add_Click({ param($sender,$event) Show-Page $sender.Tag })
}
$scanTimer = [Windows.Threading.DispatcherTimer]::new()
$scanTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$scanTimer.Add_Tick({
    try {
        if ($script:scan -and ($script:scan.Process.HasExited -or [DateTime]::UtcNow -gt $script:scan.Deadline)) {
            $scan = $script:scan
            $script:scan = $null
            try {
                if ($scan.Process.HasExited) {
                    $output = Read-Result $scan
                    if ($scan.Serial) {
                        if ((Active-Phone).Serial -eq $scan.Serial -and $output -match '(?m)^\s*level:\s*(\d+)') {
                            $ui.DeviceDetails.Text = "Подключён   ·   Заряд $($Matches[1])%"
                        }
                    } else {
                        Show-Phones $output
                        if ($ui.Status.Text -in @('Проверяем подключение…','Поиск телефона…')) {
                            if (Active-Phone) { Set-Status 'Телефон подключён.' }
                            else { Set-Status 'Телефон не в сети. Откройте «Подключить телефон».' }
                        }
                        $phone = Active-Phone
                        if ($phone) {
                            $script:scan = Start-Command $adb @('-s',$phone.Serial,'shell','dumpsys battery')
                            $script:scan.Serial = $phone.Serial
                            $script:scan.Deadline = [DateTime]::UtcNow.AddSeconds(8)
                        }
                    }
                }
            } finally { Close-Command $scan }
        }
        if (-not $script:scan -and [DateTime]::UtcNow -ge $script:nextScan) {
            $script:nextScan = [DateTime]::UtcNow.AddSeconds(5)
            $script:scan = Start-Command $adb @('devices','-l')
            $script:scan.Deadline = [DateTime]::UtcNow.AddSeconds(8)
        }
        if ($script:job -and ($script:job.Process.HasExited -or [DateTime]::UtcNow -gt $script:job.Deadline)) {
            $job = $script:job
            $script:job = $null
            try {
                if (-not $job.Process.HasExited) { throw 'Телефон не ответил вовремя.' }
                $output = Read-Result $job
                if ($job.Serial -eq (Active-Phone).Serial) { & $job.Done $job $output }
            } finally {
                Close-Command $job
                if ($job.Data -is [hashtable] -and $job.Data.Temp -and [IO.File]::Exists($job.Data.Temp)) {
                    [IO.File]::Delete($job.Data.Temp)
                }
                Update-Buttons
            }
        }
        if ($script:previewJob -and ($script:previewJob.Process.HasExited -or [DateTime]::UtcNow -gt $script:previewJob.Deadline)) {
            $job = $script:previewJob
            $script:previewJob = $null
            try {
                if (-not $job.Process.HasExited) { throw 'Телефон не ответил вовремя.' }
                $null = Read-Result $job
                $ui.Preview.Source = Read-Bitmap ($job.Buffer.ToArray())
            } catch { Set-Status 'Предпросмотр недоступен. Можно скачать исходный файл.' }
            finally { Close-Command $job }
        }
        if ($script:mirror -and $script:mirror.Process.HasExited) {
            $mirror = $script:mirror
            $script:mirror = $null
            Stop-Stick
            try { $null = Read-Result $mirror; Set-Status 'Окно Android закрыто.' }
            catch { Set-Status ('Окно Android завершилось с ошибкой. ' + $_.Exception.Message) }
            finally { Close-Command $mirror }
        }
    } catch { Set-Status ('Действие не выполнено. ' + $_.Exception.Message) }
})
$window.Add_Closed({
    $scanTimer.Stop()
    Stop-Stick
    Close-Command $script:scan
    Close-Command $script:previewJob
    if ($script:job) {
        Close-Command $script:job
        if ($script:job.Data -is [hashtable] -and $script:job.Data.Temp -and [IO.File]::Exists($script:job.Data.Temp)) {
            [IO.File]::Delete($script:job.Data.Temp)
        }
    }
    if ($script:mirror) {
        if (-not $script:mirror.Process.HasExited) { $null = $script:mirror.Process.CloseMainWindow() }
        $script:mirror.Process.Dispose()
    }
})
Show-Page 'Home'
Update-Buttons
if ($SelfTest) {
    if ($ui.ScreenButton.IsEnabled) { throw 'Empty device state test failed' }
    $app = @(Read-Apps " - Камера              com.android.camera")[0]
    if ($app.Name -ne 'Камера' -or $app.Package -ne 'com.android.camera') { throw 'App list test failed' }
    if ((New-QrImage 'studio-example123' 'sample-password').PixelWidth -lt 100) { throw 'QR test failed' }
    if ((Find-PairingAddress "studio-example123 _adb-tls-pairing._tcp. 192.168.1.10:1234" 'studio-example123') -ne '192.168.1.10:1234') { throw 'Network discovery test failed' }
    $process = Start-Command $adb @('devices','-l')
    if (-not $process.Process.WaitForExit(10000)) { Close-Command $process; throw 'ADB test timed out' }
    $result = Read-Result $process
    Close-Command $process
    if ($result -notmatch 'List of devices attached') { throw 'ADB response test failed' }
    Show-Phones 'emulator-5554 device model:Demo_Phone'
    if (-not $ui.ScreenButton.IsEnabled -or $ui.DevicePicker.SelectedItem.Name -ne 'Demo Phone') { throw 'Phone selection test failed' }
    $writer = [IO.StringWriter]::new()
    $script:preferences.Joystick = @{X=100;Y=200;Radius=50}
    $script:stick = @{Process=@{StandardInput=$writer}}
    Move-Stick 1 0
    Move-Stick 0 0
    if ($writer.ToString() -notmatch 'DOWN 100 200; input motionevent MOVE 150 200\r?\ninput motionevent UP 150 200') {
        throw 'Joystick sequence test failed'
    }
    $writer.Dispose()
    $script:stick = $null
    'Desktop, QR, ADB, and joystick tests passed'
    exit
}
$scanTimer.Start()
$null = $window.ShowDialog()
