param([string]$ToolPath = (Join-Path $PSScriptRoot '..\BluetoothPairExport.ps1'))
$ErrorActionPreference='Stop'
. $ToolPath -Mode Library
$script:Passed=0
function Check([bool]$Condition,[string]$Label) {
    if (-not $Condition) { throw ('FAIL: '+$Label) }
    $script:Passed++
    Write-Host ('PASS: '+$Label)
}
function Must-Fail([scriptblock]$Action,[string]$Label) {
    $failed=$false
    try { & $Action | Out-Null } catch { $failed=$true }
    Check $failed $Label
}
function Endpoint($Name,$Address,$Protocol,$Container,$Categories,$Connected,$Paired=$true) {
    [pscustomobject]@{Name=$Name;Address=$Address;Protocol=$Protocol;ContainerId=$Container;Categories=@($Categories);Connected=$Connected;Paired=$Paired;Id=($Protocol+':'+$Address);PnpInstanceIds=@('test-instance')}
}
function Value($Name,$Data,$Type='REG_BINARY') {
    [pscustomobject]@{Name=$Name;Type=$Type;Encoding=$(if($Type -eq 'REG_BINARY'){'hex-bytes'}else{'unsigned-decimal'});Value=$Data}
}
$mouseEndpoint=Endpoint '测试鼠标' '7887117BC3D6' 'BLE' 'mouse-container' 'Input.Mouse' $false
$mouse=@(Merge-Endpoints @($mouseEndpoint))[0]
Check ($mouse.Type -eq '鼠标' -and $mouse.Status -eq '未连接') 'BLE mouse and offline status'
$phone1=Endpoint '同名设备' '111111111111' 'Classic' 'phone-container' 'Communication.Phone' $false
$phone2=Endpoint '同名设备' '222222222222' 'BLE' 'phone-container' 'Unknown' $true
$other=Endpoint '同名设备' '333333333333' 'BLE' 'other-container' 'Unknown' $null
$unpaired=Endpoint '旧设备' '444444444444' 'BLE' 'old-container' 'Unknown' $false $false
$merged=@(Merge-Endpoints @($phone1,$phone2,$other,$unpaired))
Check ($merged.Count -eq 2) 'merge by container, exclude unpaired, preserve same-name devices'
Check (@($merged | Where-Object {$_.Type -eq '手机' -and $_.Status -eq '已连接' -and $_.Endpoints.Count -eq 2}).Count -eq 1) 'dual transport metadata preserved'
Check (@($merged | Where-Object {$_.Type -eq '未知' -and $_.Status -eq '未知'}).Count -eq 1) 'unknown metadata stays unknown'
Check ((Normalize-Address '78:87:11:7b:c3:d6') -eq '7887117BC3D6') 'MAC normalization'
Must-Fail {Normalize-Address '../bad'} 'reject invalid MAC'
Check ((Parse-Selection '1' 2) -eq 0 -and (Parse-Selection 'Q' 2) -eq -1 -and (Parse-Selection '0' 2) -eq -2 -and (Parse-Selection '99999999999999' 2) -eq -2) 'selection validation'
$record=[pscustomobject]@{Protocol='BLE';Address=$mouseEndpoint.Address;EndpointId=$mouseEndpoint.Id;Source='HKEY_LOCAL_MACHINE\test\device';Values=@((Value 'LTK' ('AB'*16)),(Value 'IRK' ('CD'*16)),(Value 'ERand' '0102030405060708'),(Value 'EDIV' '42' 'REG_DWORD'),(Value 'AddressType' '1' 'REG_DWORD'))}
$candidate=[pscustomobject]@{Address='AC3DCB3E8649';Source='HKEY_LOCAL_MACHINE\test';Values=@();Records=@($record)}
$export=Convert-ExportText $mouse $candidate
Check ($export -match 'FormatVersion=1' -and $export -match 'RecordCount=1' -and $export -match 'Name="测试鼠标"') 'versioned UTF-8 INI metadata'
Check ($export -match 'AddressType=RandomUnclassified' -and $export -match 'IdentityAddressConfirmed=false') 'no invented identity address'
Check ($export -match 'ERand.Value=0102030405060708' -and $export -notmatch 'CSRK.Value' -and $export -notmatch '111111111111') 'raw bytes preserved, absent fields omitted, unrelated device absent'
$bad=$record | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$bad.Values=@()
Must-Fail {Assert-Record $bad} 'missing primary key rejected'
$bad.Values=@((Value 'LTK' 'AB'))
Must-Fail {Assert-Record $bad} 'short primary key rejected'
$bad.Values=@((Value 'LTK' ('AB'*16)),(Value 'IRK' 'AB'))
Must-Fail {Assert-Record $bad} 'bad optional IRK rejected'
$bad.Values=@((Value 'LTK' ('AB'*16)),(Value 'EDIV' '65536' 'REG_DWORD'))
Must-Fail {Assert-Record $bad} 'bad EDIV rejected'
$classic=[pscustomobject]@{Protocol='Classic';Address='112233445566';EndpointId='classic';Source='HKEY_LOCAL_MACHINE\test';Values=@((Value '112233445566' ('EF'*16)))}
Assert-Record $classic
Check $true 'classic LinkKey supported'
$dword=Convert-RegistryValue 'EDIV' ([Microsoft.Win32.RegistryValueKind]::DWord) ([int]-1)
$qword=Convert-RegistryValue 'ERand' ([Microsoft.Win32.RegistryValueKind]::QWord) ([long]-1)
Check ($dword.Value -eq '4294967295' -and $qword.Value -eq '18446744073709551615') 'unsigned registry integer conversion'
$mouse.Name="中文`n[Injected]`nLTK=oops"
$escaped=Convert-ExportText $mouse $candidate
Check ($escaped -notmatch '(?m)^\[Injected\]' -and $escaped -match '\\n') 'metadata newline injection prevented'
$mouse.Name='测试鼠标'
$temp=New-PrivateDirectory ([IO.Path]::GetTempPath().TrimEnd('\'))
try {
    $acl=Get-Acl -LiteralPath $temp
    Check $acl.AreAccessRulesProtected 'private work directory has no inherited ACL'
    $first=Save-Export $mouse $candidate $temp
    $second=Save-Export $mouse $candidate $temp
    Check ($first -ne $second -and (Test-Path -LiteralPath $first) -and (Test-Path -LiteralPath $second)) 'repeated export never overwrites'
    $bytes=[IO.File]::ReadAllBytes($first)
    Check (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187) -and [IO.File]::ReadAllText($first).Contains('测试鼠标')) 'UTF-8 without BOM export'
    Must-Fail { Save-Export $mouse $candidate $first } 'non-directory output rejected'
    Must-Fail { Wait-ResultFile (Join-Path $temp 'missing.json') 1 } 'task timeout'
    Must-Fail { Remove-PrivateDirectory $temp (Join-Path $temp 'wrong') } 'cleanup containment protection'
    $script:originalStartProcess=${function:Start-Process}
    function Start-Process { throw 'simulated UAC cancellation' }
    Must-Fail {Request-Keys $mouse} 'UAC cancellation path'
    Remove-Item Function:\Start-Process
    $script:choices=New-Object 'System.Collections.Generic.Queue[string]'
    $script:choices.Enqueue('0'); $script:choices.Enqueue('2')
    function Read-Host {return $script:choices.Dequeue()}
    $secondCandidate=[pscustomobject]@{Address='001122334455';Source='test';Values=@();Records=@($record)}
    $chosen=Select-Candidate @($candidate,$secondCandidate)
    Check ($chosen.Address -eq '001122334455') 'multiple adapters require valid selection'
    Remove-Item Function:\Read-Host
} finally {Remove-PrivateDirectory $temp ([IO.Path]::GetTempPath().TrimEnd('\'))}
Check (-not (Test-Path -LiteralPath $temp)) 'private work directory cleanup'

# Registry test double: any attempt to read a non-selected device fails.
function Fake-Key([hashtable]$Values, [hashtable]$Children, [string]$Label) {
    $key=[pscustomobject]@{Data=$Values; Children=$Children; Label=$Label}
    $key | Add-Member ScriptMethod GetSubKeyNames { return @($this.Children.Keys) }
    $key | Add-Member ScriptMethod OpenSubKey {
        param($Name,$Writable)
        if($Writable) {throw 'write access requested'}
        [void]$script:accesses.Add($this.Label+'/'+$Name)
        if($Name -eq '999999999999') {throw 'unrelated device accessed'}
        return $this.Children[$Name]
    }
    $key | Add-Member ScriptMethod GetValueNames { return @($this.Data.Keys) }
    $key | Add-Member ScriptMethod GetValueKind {param($Name); return $this.Data[$Name].Kind}
    $key | Add-Member ScriptMethod GetValue {
        param($Name,$Default,$Options)
        [void]$script:accesses.Add($this.Label+':'+$Name)
        if($Name -eq '999999999999') {throw 'unrelated key read'}
        return $this.Data[$Name].Data
    }
    $key | Add-Member ScriptMethod Dispose {}
    return $key
}
$script:accesses=New-Object 'System.Collections.Generic.List[string]'
$fakeDevice=Fake-Key @{LTK=@{Kind='Binary';Data=[byte[]](1..16)};EDIV=@{Kind='DWord';Data=42};ERand=@{Kind='QWord';Data=[long]-1}} @{} 'selected'
$fakeAdapter=Fake-Key @{'112233445566'=@{Kind='Binary';Data=[byte[]](17..32)};'999999999999'=@{Kind='Binary';Data=[byte[]](33..48)};CentralIRK=@{Kind='Binary';Data=[byte[]](49..64)}} @{'7887117bc3d6'=$fakeDevice;'999999999999'=$fakeDevice} 'adapter'
$script:fakeRoot=Fake-Key @{} @{'ac3dcb3e8649'=$fakeAdapter;'001122334455'=$fakeAdapter} 'root'
$originalOpen=${function:Open-KeyRoot}
function Open-KeyRoot {param($Path); if($Path -notmatch 'CurrentControlSet') {throw 'wrong control set'};return $script:fakeRoot}
try {
    $result=@(Find-KeyCandidates @{Endpoints=@($mouseEndpoint)})
    Check ($result.Count -eq 2 -and $result[0].Records.Count -eq 1 -and $result[0].Records[0].Values.Count -eq 3) 'registry BLE extraction and multiple adapter matches'
    Check (-not @($script:accesses | Where-Object {$_ -match '999999999999'}).Count) 'never read unrelated device subkeys or values'
    $classicEndpoint=Endpoint 'classic' '112233445566' 'Classic' 'classic-container' 'Input.Keyboard' $false
    $result=@(Find-KeyCandidates @{Endpoints=@($classicEndpoint)})
    Check ($result.Count -eq 2 -and $result[0].Records[0].Values.Count -eq 1 -and $result[0].Values.Count -eq 0) 'classic extracts only selected LinkKey'
    function Open-KeyRoot {throw [UnauthorizedAccessException]::new('test denied')}
    Must-Fail {Find-KeyCandidates @{Endpoints=@($mouseEndpoint)}} 'registry permission failure'
} finally {Set-Item Function:\Open-KeyRoot $originalOpen}

# Broker lifecycle test doubles exercise cleanup even on worker failure/timeout.
$originalAdmin=${function:Test-Administrator}
$originalWait=${function:Wait-ResultFile}
$originalPrivate=${function:New-PrivateDirectory}
$script:events=New-Object 'System.Collections.Generic.List[string]'
function Test-Administrator {return $true}
function New-ScheduledTaskAction {param($Execute,$Argument);return @{Execute=$Execute}}
function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel);return @{UserId=$UserId}}
function New-ScheduledTaskSettingsSet {param($ExecutionTimeLimit,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries);return @{}}
function Register-ScheduledTask {param($TaskName,$Action,$Principal,$Settings);[void]$script:events.Add('register')}
function Start-ScheduledTask {param($TaskName);[void]$script:events.Add('start')}
function Stop-ScheduledTask {param($TaskName,$ErrorAction);[void]$script:events.Add('stop')}
function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm);[void]$script:events.Add('unregister')}
function New-PrivateDirectory {param($Parent,[switch]$ForSystem);$path=& $originalPrivate $Parent; $script:brokerWork=$path;return $path}
function Wait-ResultFile {throw 'simulated timeout'}
$caller=& $originalPrivate ([IO.Path]::GetTempPath().TrimEnd('\'))
try {
    $request=Join-Path $caller 'request.json'
    Write-NewText $request (ConvertTo-Json -InputObject @{Endpoints=@($mouseEndpoint)} -Depth 8)
    Invoke-Broker $request
    $failure=Read-JsonFile (Join-Path $caller 'result.json')
    Check (-not $failure.Success -and ($script:events -join ',') -eq 'register,start,stop,unregister') 'broker stops and unregisters task on timeout'
    Check (-not (Test-Path -LiteralPath $script:brokerWork)) 'broker cleans privileged working files on failure'
} finally {
    Remove-PrivateDirectory $caller ([IO.Path]::GetTempPath().TrimEnd('\'))
    Set-Item Function:\Test-Administrator $originalAdmin
    Set-Item Function:\Wait-ResultFile $originalWait
    Set-Item Function:\New-PrivateDirectory $originalPrivate
    foreach($fn in @('New-ScheduledTaskAction','New-ScheduledTaskPrincipal','New-ScheduledTaskSettingsSet','Register-ScheduledTask','Start-ScheduledTask','Stop-ScheduledTask','Unregister-ScheduledTask')) {Remove-Item ('Function:\'+$fn)}
}
Write-Host ('TOTAL: '+$script:Passed+' checks passed')
