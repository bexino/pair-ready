#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Interactive','List','Broker','Worker','Library')][string]$Mode = 'Interactive',
    [string]$RequestPath,
    [string]$OutputDirectory,
    [string]$DeviceAddress
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:ToolVersion = '1.0.0'
$script:ThisScript = $PSCommandPath
$script:ToolRoot = $PSScriptRoot
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function Normalize-Address([string]$Address) {
    $value = $Address -replace '[:-]', ''
    if ($value -notmatch '^[0-9a-fA-F]{12}$') { throw '无效的蓝牙地址。' }
    return $value.ToUpperInvariant()
}
function Format-Address([string]$Address) {
    return ((Normalize-Address $Address) -replace '(..)(?!$)', '$1:')
}
function Get-Optional($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}
function Get-DeviceType([object[]]$Categories) {
    $joined = $Categories -join '|'
    switch -Regex ($joined) {
        'Input\.Mouse' { return '鼠标' }
        'Input\.Keyboard' { return '键盘' }
        'Communication\.Phone' { return '手机' }
        'Audio\.Head' { return '耳机' }
        'Audio' { return '音频设备' }
        'Input\.Gaming|Game' { return '游戏控制器' }
        'Computer' { return '电脑' }
        default { return '未知' }
    }
}
function Wait-WinRT($Operation, [Type]$ResultType) {
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 1 -and
        $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
    $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    if (-not $task.Wait(20000)) { throw '读取 Windows 设备列表超时，请重试。' }
    return $task.Result
}
function Merge-Endpoints([object[]]$Endpoints) {
    $groups = @{}
    foreach ($endpoint in $Endpoints) {
        if (-not $endpoint.Paired) { continue }
        $key = if ($endpoint.ContainerId -and $endpoint.ContainerId -ne [guid]::Empty.ToString()) {
            'container:' + $endpoint.ContainerId
        } else { $endpoint.Protocol + ':' + $endpoint.Address }
        if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object System.Collections.ArrayList }
        if (-not @($groups[$key] | Where-Object { $_.Id -eq $endpoint.Id }).Count) {
            [void]$groups[$key].Add($endpoint)
        }
    }
    foreach ($key in ($groups.Keys | Sort-Object)) {
        $members = @($groups[$key] | Sort-Object Protocol,Address)
        $names = @($members | Where-Object { $_.Name } | Select-Object -ExpandProperty Name -Unique)
        $categories = @($members | ForEach-Object { $_.Categories } | Where-Object { $_ } | Sort-Object -Unique)
        $status = '未知'
        if (@($members | Where-Object { $_.Connected -eq $true }).Count) { $status = '已连接' }
        elseif (-not @($members | Where-Object { $null -eq $_.Connected }).Count) { $status = '未连接' }
        [pscustomobject]@{
            Name = $(if ($names.Count) { $names[0] } else { '未知设备' })
            Type = Get-DeviceType $categories
            Categories = $categories
            ContainerId = $members[0].ContainerId
            Protocol = (($members | Select-Object -ExpandProperty Protocol -Unique) -join '+')
            Addresses = (($members | ForEach-Object { Format-Address $_.Address } | Select-Object -Unique) -join ', ')
            Status = $status
            Endpoints = $members
        }
    }
}
function Get-PairedDevices {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Devices.Enumeration.DeviceInformation,Windows.Devices.Enumeration,ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformationCollection,Windows.Devices.Enumeration,ContentType=WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.BluetoothLEDevice,Windows.Devices.Bluetooth,ContentType=WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.BluetoothDevice,Windows.Devices.Bluetooth,ContentType=WindowsRuntime]
    $pnp = @()
    try {
        $pnp = @(Get-PnpDevice -Class Bluetooth | Where-Object { $_.InstanceId -match '^BTH(LE|ENUM)\\DEV_' } | ForEach-Object {
            $node = $_
            $properties = @{}
            Get-PnpDeviceProperty -InstanceId $node.InstanceId -ErrorAction SilentlyContinue | ForEach-Object { $properties[$_.KeyName] = $_.Data }
            [pscustomobject]@{Id=$node.InstanceId; Address=$properties['DEVPKEY_Bluetooth_DeviceAddress']; ContainerId=[string]$properties['DEVPKEY_Device_ContainerId']; Categories=@($properties['DEVPKEY_DeviceContainer_Category'])}
        })
    } catch { Write-Warning '部分 PnP 属性不可用；设备类型可能显示为未知。' }
    $endpoints = @()
    foreach ($protocol in @('Classic','BLE')) {
        $selector = if ($protocol -eq 'BLE') {
            [Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelectorFromPairingState($true)
        } else { [Windows.Devices.Bluetooth.BluetoothDevice]::GetDeviceSelectorFromPairingState($true) }
        $properties = [string[]]@('System.Devices.Aep.DeviceAddress','System.Devices.Aep.IsConnected','System.Devices.Aep.IsPaired','System.Devices.Aep.ContainerId')
        $operation = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector, $properties, [Windows.Devices.Enumeration.DeviceInformationKind]::AssociationEndpoint)
        $devices = @(Wait-WinRT $operation ([Windows.Devices.Enumeration.DeviceInformationCollection]))
        foreach ($device in $devices) {
            if (-not $device.Pairing.IsPaired) { continue }
            # WinRT IMapView is exposed as __ComObject in Windows PowerShell.
            # Enumerating pairs works; directly indexing/casting the COM map does not.
            $deviceProperties = @{}
            foreach ($pair in $device.Properties) { $deviceProperties[$pair.Key] = $pair.Value }
            $address = Normalize-Address ([string]$deviceProperties['System.Devices.Aep.DeviceAddress'])
            $container = [string]$deviceProperties['System.Devices.Aep.ContainerId']
            $nodes = @($pnp | Where-Object {
                ($_.Address -and (Normalize-Address ([string]$_.Address)) -eq $address) -or
                ($container -and $container -ne [guid]::Empty.ToString() -and $_.ContainerId -eq $container)
            })
            $connected = $deviceProperties['System.Devices.Aep.IsConnected']
            if ($connected -isnot [bool]) { $connected = $null }
            $endpoints += [pscustomobject]@{
                Name=$device.Name; Id=$device.Id; Protocol=$protocol; Address=$address; ContainerId=$container
                Paired=$true; Connected=$connected; Categories=@($nodes | ForEach-Object { $_.Categories })
                PnpInstanceIds=@($nodes | Select-Object -ExpandProperty Id -Unique)
            }
        }
    }
    return @(Merge-Endpoints $endpoints | Sort-Object Name,Addresses)
}

# Work directories never inherit broad permissions. The SYSTEM worker runs only
# from the administrator-owned copy; it never executes the caller's working files.
function New-PrivateDirectory([string]$Parent, [switch]$ForSystem) {
    $path = Join-Path $Parent ('BluetoothPairExport-' + [guid]::NewGuid().ToString('N'))
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $sids = @('S-1-5-18','S-1-5-32-544')
    if (-not $ForSystem) { $sids += [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    foreach ($sid in ($sids | Select-Object -Unique)) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit, ObjectInherit','None','Allow')
        $security.AddAccessRule($rule)
    }
    $null = [System.IO.Directory]::CreateDirectory($path, $security)
    return $path
}
function Remove-PrivateDirectory([string]$Path, [string]$Parent) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $expectedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($full) -ne $expectedParent -or [IO.Path]::GetFileName($full) -notmatch '^BluetoothPairExport-[a-f0-9]{32}$') {
        throw '拒绝清理不符合工具工作目录规则的路径。'
    }
    if (Test-Path -LiteralPath $full) {
        Assert-NoReparse $full
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '工作路径不能包含符号链接或目录联接。' }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
function Write-NewText([string]$Path, [string]$Text) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = $script:Utf8.GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } finally { $stream.Dispose() }
}
function Read-JsonFile([string]$Path) {
    return ([IO.File]::ReadAllText($Path, $script:Utf8) | ConvertFrom-Json)
}
function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Convert-RegistryValue([string]$Name, [Microsoft.Win32.RegistryValueKind]$Kind, $Value) {
    switch ($Kind.ToString()) {
        'Binary' { $text = [BitConverter]::ToString([byte[]]$Value).Replace('-',''); $encoding='hex-bytes'; $type='REG_BINARY' }
        'DWord' { $text = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Value),0).ToString([Globalization.CultureInfo]::InvariantCulture); $encoding='unsigned-decimal'; $type='REG_DWORD' }
        'QWord' { $text = [BitConverter]::ToUInt64([BitConverter]::GetBytes([long]$Value),0).ToString([Globalization.CultureInfo]::InvariantCulture); $encoding='unsigned-decimal'; $type='REG_QWORD' }
        'String' { $text=[string]$Value; $encoding='json-string'; $type='REG_SZ' }
        'ExpandString' { $text=[string]$Value; $encoding='json-string'; $type='REG_EXPAND_SZ' }
        'MultiString' { $text=ConvertTo-Json -InputObject ([string[]]$Value) -Compress; $encoding='json-array'; $type='REG_MULTI_SZ' }
        default { throw '所选设备包含不支持的注册表数据类型。' }
    }
    [pscustomobject]@{Name=$Name; Type=$type; Encoding=$encoding; Value=$text}
}
function Read-RegistryValues($Key, [string[]]$OnlyNames) {
    $names = if ($null -ne $OnlyNames -and $OnlyNames.Count) { $OnlyNames } else { $Key.GetValueNames() }
    foreach ($name in $names) {
        if ($Key.GetValueNames() -notcontains $name) { continue }
        Convert-RegistryValue $name ($Key.GetValueKind($name)) ($Key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
    }
}
function Get-ValueEntry($Record, [string]$Name) {
    return @($Record.Values | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1
}
function Assert-Record($Record) {
    $mainName = if ($Record.Protocol -eq 'BLE') { 'LTK' } elseif ($Record.Protocol -eq 'Classic') { $Record.Address } else { throw '未知的配对协议。' }
    $main = Get-ValueEntry $Record $mainName
    if ($null -eq $main -or $main.Type -ne 'REG_BINARY' -or $main.Value -notmatch '^[0-9A-Fa-f]{32}$') {
        throw ('所选设备缺少有效的 16 字节主密钥（' + $Record.Protocol + '），未生成导出文件。')
    }
    if ($Record.Protocol -eq 'BLE') {
        foreach ($name in @('IRK','CSRK')) {
            $entry = Get-ValueEntry $Record $name
            if ($null -ne $entry -and ($entry.Type -ne 'REG_BINARY' -or $entry.Value -notmatch '^[0-9A-Fa-f]{32}$')) { throw ('BLE ' + $name + ' 长度或类型异常。') }
        }
        $rand = Get-ValueEntry $Record 'ERand'
        if ($null -ne $rand -and -not (($rand.Type -eq 'REG_BINARY' -and $rand.Value -match '^[0-9A-Fa-f]{16}$') -or ($rand.Type -eq 'REG_QWORD' -and $rand.Value -match '^\d+$'))) { throw 'BLE ERand 类型或长度异常。' }
        $ediv = Get-ValueEntry $Record 'EDIV'
        if ($null -ne $ediv -and ($ediv.Type -ne 'REG_DWORD' -or $ediv.Value -notmatch '^\d+$' -or [uint64]$ediv.Value -gt 65535)) { throw 'BLE EDIV 无效。' }
        foreach ($name in @('KeyLength','KeySize')) {
            $size = Get-ValueEntry $Record $name
            if ($null -ne $size -and ($size.Type -ne 'REG_DWORD' -or $size.Value -notmatch '^\d+$' -or [uint64]$size.Value -lt 7 -or [uint64]$size.Value -gt 16)) { throw 'BLE 密钥长度参数无效。' }
        }
    }
}
function Open-KeyRoot([string]$Path) {
    return [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($Path, $false)
}
function Find-KeyCandidates($Request) {
    $endpoints = @($Request.Endpoints)
    if (-not $endpoints.Count -or $endpoints.Count -gt 16) { throw '设备请求无效。' }
    foreach ($endpoint in $endpoints) {
        $null = Normalize-Address $endpoint.Address
        if ($endpoint.Protocol -notin @('BLE','Classic')) { throw '设备请求协议无效。' }
    }
    $basePath = 'SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys'
    $root = Open-KeyRoot $basePath
    if ($null -eq $root) { throw 'Windows 未保存可读取的蓝牙配对密钥。' }
    try {
        foreach ($adapterName in $root.GetSubKeyNames()) {
            if ($adapterName -notmatch '^[0-9a-fA-F]{12}$') { continue }
            $adapter = $root.OpenSubKey($adapterName, $false)
            try {
                $records = @()
                foreach ($endpoint in $endpoints) {
                    $address = (Normalize-Address $endpoint.Address).ToLowerInvariant()
                    if ($endpoint.Protocol -eq 'BLE') {
                        $deviceKey = $adapter.OpenSubKey($address, $false)
                        if ($null -eq $deviceKey) { continue }
                        try { $values = @(Read-RegistryValues $deviceKey) } finally { $deviceKey.Dispose() }
                        $source = 'HKEY_LOCAL_MACHINE\' + $basePath + '\' + $adapterName + '\' + $address
                    } else {
                        if ($adapter.GetValueNames() -notcontains $address) { continue }
                        $values = @(Read-RegistryValues $adapter @($address))
                        $source = 'HKEY_LOCAL_MACHINE\' + $basePath + '\' + $adapterName
                    }
                    $record = [pscustomobject]@{Protocol=$endpoint.Protocol; Address=$address.ToUpperInvariant(); EndpointId=$endpoint.Id; Source=$source; Values=$values}
                    Assert-Record $record
                    $records += $record
                }
                if ($records.Count) {
                    $adapterValues = @()
                    if (@($records | Where-Object { $_.Protocol -eq 'BLE' }).Count) { $adapterValues = @(Read-RegistryValues $adapter @('CentralIRK')) }
                    [pscustomobject]@{Address=$adapterName.ToUpperInvariant(); Source=('HKEY_LOCAL_MACHINE\' + $basePath + '\' + $adapterName); Values=$adapterValues; Records=$records}
                }
            } finally { if ($null -ne $adapter) { $adapter.Dispose() } }
        }
    } finally { $root.Dispose() }
}
function Invoke-Worker([string]$Path) {
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { throw '内部读取任务必须以 SYSTEM 身份运行。' }
    $resultPath = Join-Path ([IO.Path]::GetDirectoryName($Path)) 'worker-result.json'
    try {
        $request = Read-JsonFile $Path
        $candidates = @(Find-KeyCandidates $request)
        if (-not $candidates.Count) { throw '找不到与所选设备地址匹配的密钥。请在 Windows 重新配对该设备后重试；工具不会猜测或读取其他设备的密钥。' }
        $result = @{Success=$true; Candidates=$candidates}
    } catch {
        $result = @{Success=$false; Error=$_.Exception.Message}
    }
    Write-NewText $resultPath (ConvertTo-Json -InputObject $result -Depth 15)
}
function Wait-ResultFile([string]$Path, [int]$TimeoutSeconds = 60) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path -LiteralPath $Path) {
            try { return Read-JsonFile $Path } catch [System.IO.IOException] { }
        }
        Start-Sleep -Milliseconds 200
    }
    throw '读取密钥任务超时，未生成导出文件。'
}
function Invoke-Broker([string]$Path) {
    if (-not (Test-Administrator)) { throw '管理员权限不足。' }
    Assert-NoReparse $Path
    $callerDir = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if ([IO.Path]::GetFileName($callerDir) -notmatch '^BluetoothPairExport-[a-f0-9]{32}$' -or [IO.Path]::GetFileName($Path) -ne 'request.json') { throw '内部工作路径无效。' }
    $work = $null
    $taskName = 'BluetoothPairExport-' + [guid]::NewGuid().ToString('N')
    $registered = $false
    $result = $null
    try {
        $request = Read-JsonFile $Path
        $work = New-PrivateDirectory $env:ProgramData -ForSystem
        $workerScript = Join-Path $work 'worker.ps1'
        [IO.File]::Copy($script:ThisScript, $workerScript, $false)
        $workerRequest = Join-Path $work 'request.json'
        Write-NewText $workerRequest (ConvertTo-Json -InputObject $request -Depth 12)
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $workerScript + '" -Mode Worker -RequestPath "' + $workerRequest + '"'
        $action = New-ScheduledTaskAction -Execute $exe -Argument $arguments
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $null = Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings
        $registered = $true
        Start-ScheduledTask -TaskName $taskName
        $result = Wait-ResultFile (Join-Path $work 'worker-result.json') 65
    } catch {
        # Framework errors may include command text; no registry values are ever
        # passed as commands or emitted into PowerShell's output streams.
        $result = @{Success=$false; Error=$_.Exception.Message}
    } finally {
        $cleanupFailed = $false
        if ($registered) {
            try {
                Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            } catch { $cleanupFailed = $true }
        }
        if ($work) {
            try { Remove-PrivateDirectory $work $env:ProgramData } catch { $cleanupFailed = $true }
        }
        if ($cleanupFailed) { $result = @{Success=$false; Error=('临时任务或目录未能清理。请以管理员身份检查任务 ' + $taskName + ' 和目录 ' + $work + '。')} }
    }
    Assert-NoReparse $callerDir
    Write-NewText (Join-Path $callerDir 'result.json') (ConvertTo-Json -InputObject $result -Depth 15)
}
function Request-Keys($Device) {
    $parent = [IO.Path]::GetTempPath().TrimEnd('\')
    $work = New-PrivateDirectory $parent
    try {
        $requestPath = Join-Path $work 'request.json'
        Write-NewText $requestPath (ConvertTo-Json -InputObject @{Endpoints=@($Device.Endpoints | Select-Object Protocol,Address,Id)} -Depth 8)
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script:ThisScript + '" -Mode Broker -RequestPath "' + $requestPath + '"'
        try {
            $process = Start-Process -FilePath $exe -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
        } catch { throw '未取得管理员授权（可能已取消 UAC），未导出任何密钥。' }
        # Broker bounds its SYSTEM task to 65 seconds and cleans up before exit.
        $process.WaitForExit()
        if (-not (Test-Path -LiteralPath (Join-Path $work 'result.json'))) { throw '提权进程未返回结果；请检查管理员权限或系统任务策略。' }
        $result = Read-JsonFile (Join-Path $work 'result.json')
        if (-not $result.Success) { throw $result.Error }
        return @($result.Candidates)
    } finally { Remove-PrivateDirectory $work $parent }
}

function Convert-IniText([string]$Value) {
    # All metadata strings use JSON quoting inside INI values, including escapes
    # for newlines, quotes and backslashes. Keys and numeric values are unquoted.
    return (ConvertTo-Json -InputObject $Value -Compress)
}
function Add-RawSection($Lines, [string]$Section, [object[]]$Values) {
    [void]$Lines.Add('')
    [void]$Lines.Add('[' + $Section + ']')
    foreach ($entry in ($Values | Sort-Object Name)) {
        # Encode unusual registry value names reversibly; never allow INI injection.
        $key = [uri]::EscapeDataString([string]$entry.Name)
        if (-not $key) { $key = '%00' }
        [void]$Lines.Add($key + '.Type=' + $entry.Type)
        [void]$Lines.Add($key + '.Encoding=' + $entry.Encoding)
        $value = if ($entry.Encoding -eq 'json-string') { Convert-IniText $entry.Value } else { [string]$entry.Value }
        [void]$Lines.Add($key + '.Value=' + $value)
    }
}
function Convert-ExportText($Device, $Candidate) {
    if (-not @($Candidate.Records).Count) { throw '没有可导出的配对记录。' }
    foreach ($record in $Candidate.Records) { Assert-Record $record }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('; 蓝牙单设备配对导出。文件含配对密钥，请妥善保存，不要公开上传。')
    [void]$lines.Add('; 二进制保留 Windows 原始字节顺序；整数为无符号十进制。缺失字段表示未知或未保存。')
    [void]$lines.Add('; 元数据字符串使用 JSON 引号及转义；Registry 字段名使用 URI 百分号编码。')
    [void]$lines.Add('[Export]')
    [void]$lines.Add('Format=BluetoothPairExport')
    [void]$lines.Add('FormatVersion=1')
    [void]$lines.Add('ToolVersion=' + $script:ToolVersion)
    [void]$lines.Add('ExportedAtUtc=' + [DateTime]::UtcNow.ToString('o'))
    [void]$lines.Add('RecordCount=' + @($Candidate.Records).Count)
    [void]$lines.Add('')
    [void]$lines.Add('[Device]')
    foreach ($field in @('Name','Type','ContainerId')) { [void]$lines.Add($field + '=' + (Convert-IniText ([string]$Device.$field))) }
    [void]$lines.Add('Categories=' + (ConvertTo-Json -InputObject @($Device.Categories) -Compress))
    [void]$lines.Add('')
    [void]$lines.Add('[Adapter]')
    [void]$lines.Add('Address=' + (Format-Address $Candidate.Address))
    [void]$lines.Add('RegistrySource=' + (Convert-IniText $Candidate.Source))
    if (@($Candidate.Values).Count) { Add-RawSection $lines 'Adapter.Registry' @($Candidate.Values) }
    $index = 0
    foreach ($record in $Candidate.Records) {
        $index++
        $section = 'Record' + $index
        [void]$lines.Add('')
        [void]$lines.Add('[' + $section + ']')
        [void]$lines.Add('Protocol=' + $record.Protocol)
        [void]$lines.Add('DeviceAddress=' + (Format-Address $record.Address))
        [void]$lines.Add('AddressSource=WindowsPairedEndpointAndRegistryMatch')
        [void]$lines.Add('IdentityAddressConfirmed=false')
        $addressType = 'Unknown'
        if ($record.Protocol -eq 'Classic') { $addressType = 'Public' }
        else {
            $entry = Get-ValueEntry $record 'AddressType'
            if ($null -ne $entry -and $entry.Type -eq 'REG_DWORD') {
                if ($entry.Value -eq '0') { $addressType = 'Public' }
                elseif ($entry.Value -eq '1') { $addressType = 'RandomUnclassified' }
            }
        }
        [void]$lines.Add('AddressType=' + $addressType)
        [void]$lines.Add('WindowsEndpointId=' + (Convert-IniText $record.EndpointId))
        $endpoint = @($Device.Endpoints | Where-Object { $_.Id -eq $record.EndpointId }) | Select-Object -First 1
        [void]$lines.Add('PnpInstanceIds=' + (ConvertTo-Json -InputObject @($endpoint.PnpInstanceIds) -Compress))
        [void]$lines.Add('RegistrySource=' + (Convert-IniText $record.Source))
        $main = if ($record.Protocol -eq 'Classic') { $record.Address.ToLowerInvariant() } else { 'LTK' }
        [void]$lines.Add('PrimaryKeyValueName=' + (Convert-IniText $main))
        Add-RawSection $lines ($section + '.Registry') @($record.Values)
    }
    return ($lines -join "`n") + "`n"
}
function Save-Export($Device, $Candidate, [string]$Directory) {
    $text = Convert-ExportText $Device $Candidate
    $directoryPath = [IO.Path]::GetFullPath($Directory)
    $null = [IO.Directory]::CreateDirectory($directoryPath)
    $name = ($Device.Name -replace '[<>:"/\\|?*\x00-\x1f]', '_').Trim().TrimEnd('.')
    if (-not $name) { $name = 'Bluetooth' }
    if ($name.Length -gt 60) { $name = $name.Substring(0,60) }
    $address = Normalize-Address $Candidate.Records[0].Address
    $file = Join-Path $directoryPath ($name + '_' + $address + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.txt')
    try { Write-NewText $file $text }
    catch {
        # File name is generated internally; remove only this incomplete file.
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        throw '导出目录不可写或写入失败，未保留不完整文件。'
    }
    return $file
}
function Parse-Selection([string]$Text, [int]$Count) {
    if ($Text -match '^[qQ]$') { return -1 }
    $number = 0
    if ([int]::TryParse($Text, [ref]$number) -and $number -ge 1 -and $number -le $Count) { return ($number - 1) }
    return -2
}
function Select-Candidate([object[]]$Candidates) {
    if ($Candidates.Count -eq 1) { return $Candidates[0] }
    Write-Host '该设备在多个蓝牙适配器下有配对记录，请选择要导出的适配器：'
    for ($i=0; $i -lt $Candidates.Count; $i++) { Write-Host ('{0}. {1}  ({2} 条配对记录)' -f ($i+1),(Format-Address $Candidates[$i].Address),@($Candidates[$i].Records).Count) }
    while ($true) {
        $choice = Parse-Selection (Read-Host '适配器编号，Q 取消') $Candidates.Count
        if ($choice -eq -1) { return $null }
        if ($choice -ge 0) { return $Candidates[$choice] }
        Write-Host '请输入列表中的编号。' -ForegroundColor Yellow
    }
}
function Show-Devices([object[]]$Devices) {
    $rows = for ($i=0; $i -lt $Devices.Count; $i++) {
        [pscustomobject][ordered]@{'编号'=$i+1; '名称'=$Devices[$i].Name; '类型'=$Devices[$i].Type; '协议'=$Devices[$i].Protocol; '地址'=$Devices[$i].Addresses; '连接状态'=$Devices[$i].Status}
    }
    $rows | Format-Table -AutoSize -Wrap | Out-Host
}
function Start-Interactive {
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path $script:ToolRoot 'exports' }
    Write-Host 'Windows 蓝牙单设备导出工具' -ForegroundColor Cyan
    Write-Host '仅显示已配对设备（含离线）；选择设备后才读取其密钥。'
    while ($true) {
        $devices = @(Get-PairedDevices)
        if (-not $devices.Count) { Write-Host '没有找到已配对的蓝牙设备。请先在 Windows 设置中配对。'; return }
        Show-Devices $devices
        if ($DeviceAddress) {
            $wanted = Normalize-Address $DeviceAddress
            $matches = @($devices | Where-Object { @($_.Endpoints | Where-Object { $_.Address -eq $wanted }).Count })
            if ($matches.Count -ne 1) { throw '指定地址未唯一匹配一个已配对设备。' }
            $selected = $matches[0]
        } else {
            $inputText = Read-Host '输入设备编号导出，R 刷新，Q 退出'
            if ($inputText -match '^[rR]$') { continue }
            $choice = Parse-Selection $inputText $devices.Count
            if ($choice -eq -1) { return }
            if ($choice -lt 0) { Write-Host '请输入列表中的编号。' -ForegroundColor Yellow; continue }
            $selected = $devices[$choice]
        }
        Write-Host ('已选择：{0} | {1} | {2} | {3}' -f $selected.Name,$selected.Type,$selected.Protocol,$selected.Addresses) -ForegroundColor Cyan
        Write-Host '即将请求管理员权限，仅读取所选设备的配对记录。'
        try {
            $candidates = @(Request-Keys $selected)
            $candidate = Select-Candidate $candidates
            if ($null -ne $candidate) {
                $saved = Save-Export $selected $candidate $OutputDirectory
                Write-Host ('已导出：' + $saved) -ForegroundColor Green
                Write-Host '文件包含配对密钥，请不要公开分享。Linux 导入将在后续工具中完成。'
            }
        } catch {
            Write-Host ('未导出：' + $_.Exception.Message) -ForegroundColor Yellow
            if ($DeviceAddress) { throw }
        } finally { $candidates=$null; $candidate=$null }
        if ($DeviceAddress) { return }
        Write-Host ''
    }
}

if ($Mode -eq 'Library') { return }
try {
    switch ($Mode) {
        'List' { Show-Devices @(Get-PairedDevices) }
        'Worker' { Invoke-Worker $RequestPath }
        'Broker' { Invoke-Broker $RequestPath }
        'Interactive' { Start-Interactive }
    }
} catch {
    if ($Mode -notin @('Broker','Worker')) { Write-Host ('错误：' + $_.Exception.Message) -ForegroundColor Red }
    exit 1
}
