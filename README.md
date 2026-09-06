# Windows 蓝牙单设备导出工具

在 Windows 配对后，选择一台蓝牙设备，导出供后续 Linux 工具使用的配对信息。支持传统蓝牙和 BLE，无需额外安装软件。

## 开始使用

1. 将整个工具文件夹放在你可以写入的位置。若下载了 ZIP，先解压。
2. 在 Windows「设置 → 蓝牙和其他设备」中完成配对。
3. 双击 **Start.cmd**。
4. 输入设备编号并回车。在 Windows 的管理员授权提示中选择「是」。
5. 等待显示「已导出」。TXT 保存在工具旁的 **exports** 文件夹。

输入 `R` 刷新，`Q` 退出。离线但已配对的设备也会显示。同一设备的传统蓝牙和 BLE 记录会按 Windows 设备容器合并；同名但不同容器的设备不会强行合并。如果多个适配器下都保存了该设备的密钥，工具会继续让你选择适配器。

设备类型来自 Windows 属性，未知时显示「未知」。连接状态来自蓝牙设备接口，不使用设备管理器中的「正常」状态推断是否连接。运行列表通常需要十几秒。

## 文件与权限

- `Start.cmd`：双击启动入口。
- `BluetoothPairExport.ps1`：可查看的完整源代码，适用于 Windows 11 自带的 Windows PowerShell 5.1。
- `tests\SelfTest.ps1`：使用模拟数据进行测试，不读取真实配对密钥，也不创建真实计划任务。
- `exports\*.txt`：你选中的设备的真实配对信息。**这些文件含明文密钥，请妥善保存，不要公开上传。**

浏览列表不需要管理员权限，也不会读取密钥。选定设备后，工具通过管理员授权临时创建 SYSTEM 任务。该任务从受限的管理员工作目录运行，只读取所选设备的配对记录及必要的适配器身份信息，完成后删除任务和临时文件。

工具不会更改注册表、注册表权限或 Windows 配对状态，不会重启蓝牙，也不会安装 PsExec。启动器的执行策略参数仅用于本次 PowerShell 进程，不修改系统执行策略。

## 导出格式

TXT 为 UTF-8（无 BOM）、LF 换行的 INI 文本，格式版本为 `1`：

| 节 | 内容 |
|---|---|
| `[Export]` | 格式、工具版本、UTC 时间、配对记录数量 |
| `[Device]` | 名称、类别、设备容器标识 |
| `[Adapter]` | 所选蓝牙适配器地址和注册表来源 |
| `[Adapter.Registry]` | 实际存在且需要的适配器身份值，如 CentralIRK |
| `[Record1]` 等 | 协议、设备地址、地址来源、Windows 设备标识、原始值位置 |
| `[Record1.Registry]` 等 | 每个原始注册表值的 `.Type`、`.Encoding` 和 `.Value` |

解析规则：

- 名称和其他元数据字符串使用 JSON 引号、反斜杠转义；读取 INI 后应按 JSON 字符串解码。数组使用 JSON。
- 原始注册表值名使用 URI 百分号编码，大小写保留；空值名表示为 `%00`。Windows 值名匹配应忽略大小写。
- `REG_BINARY` 使用 `hex-bytes`：每字节两个十六进制字符，严格保留原始字节顺序。不要整段倒序。
- `REG_DWORD` / `REG_QWORD` 使用 `unsigned-decimal`：无符号十进制文本，64 位数应使用整数或字符串解析，避免浮点精度损失。
- 字符串采用 `json-string`，多字符串采用 `json-array`。导出不会展开注册表环境变量。
- 传统蓝牙的 `PrimaryKeyValueName` 指向适配器键下以设备 MAC 命名的 LinkKey。BLE 指向 `LTK`。
- 缺失参数不会自动填零。`AddressType=Unknown` 表示未获得对应参数，`RandomUnclassified` 不保证是静态随机地址。
- `IdentityAddressConfirmed=false` 是保守标记：地址匹配了 Windows 配对接口和密钥记录，但工具没有独立验证 BLE 身份地址。不会根据地址位模式猜测。

同一设备可以有多个协议记录，但一个 TXT 只对应一个选中的蓝牙适配器。BLE 中 Windows 实际保存的其他设备参数也会原样导出，例如 `AuthReq`、`KeyLength`、`CEntralIRKStatus`，供后续兼容分析。

## 常见情况

- **没有设备**：先在 Windows 设置中配对，然后刷新。工具不会主动扫描周围未配对设备。
- **取消管理员提示**：本次不导出，可以重新选择。
- **找不到匹配密钥**：可能配对记录已变化，或 Windows 保存的地址与可见地址不同。重新配对后重试；工具不会猜测另一个设备的密钥。
- **主密钥或参数异常**：不会生成看似有效的文件，会显示出错原因。
- **任务策略限制 / 读取超时**：当前账户或电脑策略可能禁止创建 SYSTEM 任务。工具会尝试清理并报告失败。
- **清理失败**：界面会报告需要检查的任务名和目录。异常断电或强制结束进程也可能留下以 `BluetoothPairExport-` 开头的临时项目；请根据实际路径检查，避免删除其他文件。
- **无法保存**：将工具放在可写文件夹，或用下面的参数指定输出目录。

## 可选命令

在工具文件夹中打开终端。下列命令明确使用 Windows PowerShell 5.1，而非 `pwsh`：

```powershell
# 只查看列表，不读取密钥、不提权
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\BluetoothPairExport.ps1 -Mode List

# 自定义保存目录，仍使用编号选择
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\BluetoothPairExport.ps1 -OutputDirectory "D:\BluetoothExports"

# 已知地址时直接选择该设备；仍会请求管理员权限
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\BluetoothPairExport.ps1 -DeviceAddress "78:87:11:7B:C3:D6"

# 使用模拟数据运行测试
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\SelfTest.ps1
```

内部的 `Broker`、`Worker` 模式由工具自动调用，不需要手动使用。

## 本次验证

2026-09-06，在本机 Windows PowerShell 5.1 验证：

- `Inphic ZHEN` 被识别为 **鼠标 / BLE**，离线时也能列出。
- 手机的 BLE 和传统蓝牙记录合并为一行，保留各自地址。
- 已真实导出鼠标，确认只有一条该鼠标的配对记录，LTK 为 16 字节。
- 真实读取后未发现工具残留的临时任务或工作目录。
- 32 项模拟检查通过，覆盖传统蓝牙、BLE、异常数据、同名设备、多个适配器、输入校验、取消提权、权限失败、超时及清理。

真实硬件验证目前覆盖这只 BLE 鼠标；传统蓝牙和多适配器提取使用模拟记录测试。Linux 导入脚本尚未实现，也尚未验证 Fedora 连接及双系统切换。

## 实现参考

- [微软：按配对状态枚举 BLE 设备](https://learn.microsoft.com/en-us/uwp/api/windows.devices.bluetooth.bluetoothledevice.getdeviceselectorfrompairingstate)
- [微软：蓝牙设备连接状态属性](https://learn.microsoft.com/en-us/windows/win32/properties/props-system-devices-aep-isconnected)
- [微软：SYSTEM 计划任务](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks-create)

Windows 蓝牙密钥注册表布局并非稳定的公开导出接口。工具保留原始类型与内容，无法确认的字段明确保留未知，后续 Linux 导入还需验证具体设备的对应关系。
