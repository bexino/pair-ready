你是下一会话中的协作助手。请把下面内容视为当前项目的连续上下文，不要要求我重新讲述已经完成的部分。除非我明确改变目标，否则请保留这些设计决定、技术约束和安全要求。请用简体中文交流。

## 项目目标

我使用 Fedora 和 Windows 11 双系统，希望同一只蓝牙鼠标在两个系统之间切换时无需反复重新配对。

Windows 和 Fedora 使用同一个物理蓝牙适配器，因此两个系统需要共享 Windows 中已经生成的蓝牙配对密钥。最初考虑过开源项目 `one-pair`，但它的实际体验不符合我的需要：它主要读取 Windows 分区中的全部蓝牙密钥并批量导入，设备选择和名称识别不够直观，也不能让我先查看名称、类型再选择单个设备。

因此决定自己制作一个工具，分成两个阶段：

1. Windows 端：列出当前已配对设备，让用户选择一台并导出该设备的配对信息。
2. Fedora 端：以后再编写 Bash/BlueZ 导入脚本，读取 Windows 端生成的 TXT 文件，只导入用户选中的设备。

当前 Windows 端已经完成，Linux/Fedora 端尚未实现。

## 已确定的产品行为

Windows 工具使用 Windows PowerShell 5.1 和一个 `.cmd` 启动入口，不需要 Python、PsExec、第三方软件或额外安装。

终端界面采用编号选择，而不是方向键 TUI：

- 只显示当前已配对的蓝牙设备。
- 包括已配对但当前离线的设备。
- 不显示周围尚未配对的设备。
- 过滤蓝牙适配器、枚举器和服务子项目。
- 显示设备编号、名称、设备类型、传统蓝牙/BLE 协议、地址和真实连接状态。
- 设备类型来自 Windows 属性，例如鼠标、键盘、手机、耳机等；无法识别时显示“未知”。
- 连接状态来自 Windows 蓝牙设备接口的 `IsConnected` 属性；不能用设备管理器中的 `Status=OK` 推断“已连接”。
- 同一 Windows 设备的 BLE 和传统蓝牙记录按设备容器标识合并。
- 不能仅凭名称合并设备；同名但不同容器的设备必须保持独立。
- 输入 `R` 刷新，输入 `Q` 退出。
- 选中设备后才读取密钥。
- 如果同一设备在多个蓝牙适配器下有记录，继续显示适配器列表，要求用户选择一个。
- 文件名必须唯一，不覆盖已有文件。
- TXT 文件包含明文密钥，不能在聊天、普通日志或终端中打印密钥值。

## 已完成的 Windows 文件

工作区是：

```
C:\Users\honor\Documents\Codex\2026-09-06\fedora-windows11-one-pair-windows
```

主要文件：

- `C:\Users\honor\Documents\Codex\2026-09-06\fedora-windows11-one-pair-windows\outputs\BluetoothPairExport\BluetoothPairExport.ps1`
- `C:\Users\honor\Documents\Codex\2026-09-06\fedora-windows11-one-pair-windows\outputs\BluetoothPairExport\Start.cmd`
- `C:\Users\honor\Documents\Codex\2026-09-06\fedora-windows11-one-pair-windows\outputs\BluetoothPairExport\使用说明.md`
- `C:\Users\honor\Documents\Codex\2026-09-06\fedora-windows11-one-pair-windows\outputs\BluetoothPairExport\tests\SelfTest.ps1`
- `C:\Users\honor\Documents\Codex\2026-09-06\fedora-windows11-one-pair-windows\outputs\BluetoothPairExport-Windows.zip`

ZIP 包中包含启动脚本、PowerShell 主脚本、说明文档和模拟测试，不应包含真实导出文件或密钥。

Windows 端默认把用户导出的文件放在：

```
C:\Users\honor\Documents\Codex\2026-09-06\fedora-windows11-one-pair-windows\outputs\BluetoothPairExport\exports
```

当前工作区里有一份真实测试导出文件：

```
C:\Users\honor\Documents\Codex\2026-09-06\fedora-windows11-one-pair-windows\outputs\BluetoothPairExport\exports\Inphic ZHEN_7887117BC3D6_20260906-182018-988_0993fd6e.txt
```

这份文件含真实密钥，绝对不要在聊天中打开、复制、打印或上传。修改打包逻辑时也不要把 `exports` 文件夹加入发布 ZIP。

## Windows 端的实现细节

设备枚举使用 Windows 自带的 Windows Runtime：

- `BluetoothLEDevice.GetDeviceSelectorFromPairingState($true)`
- `BluetoothDevice.GetDeviceSelectorFromPairingState($true)`
- `DeviceInformation.FindAllAsync(...)`

读取到的关键属性包括：

- `System.Devices.Aep.DeviceAddress`
- `System.Devices.Aep.IsPaired`
- `System.Devices.Aep.IsConnected`
- `System.Devices.Aep.ContainerId`
- `System.ItemNameDisplay`

PowerShell 5.1 中 `DeviceInformation.Properties` 表现为 `System.__ComObject`，不能直接按字典索引。现有代码采用枚举键值对、复制到 PowerShell hashtable 后再读取。这一兼容处理不能随意删掉。

PnP 信息通过：

- `Get-PnpDevice -Class Bluetooth`
- `Get-PnpDeviceProperty`

只保留类似 `BTHLE\DEV_...` 或 `BTHENUM\DEV_...` 的设备节点，并读取设备类别、蓝牙地址、容器标识等属性。服务节点如“蓝牙 LE 通用属性服务”必须过滤掉。

当前测试机识别出的蓝牙控制器是 Intel Wireless Bluetooth。测试时列出的已配对设备为：

1. `Inphic ZHEN`
   - 类型：鼠标
   - 协议：BLE
   - 地址：`78:87:11:7B:C3:D6`
   - 状态：未连接
2. `华为畅享 80`
   - 类型：手机
   - 协议：BLE + Classic
   - BLE 地址：`43:38:B3:EB:7A:89`
   - Classic 地址：`34:4A:86:8E:38:C8`
   - 状态：未连接

这些地址只用于测试和说明，实际工具必须继续动态读取，不能硬编码。

## 提权和密钥读取方式

列表阶段不读取密钥，也不需要管理员权限。

选中设备后：

1. 启动 PowerShell 的 UAC 管理员进程。
2. 管理员进程创建一个一次性 SYSTEM 计划任务。
3. SYSTEM 任务从受限的临时工作目录运行同一脚本的 Worker 模式。
4. Worker 只读取选中设备地址对应的 Windows 注册表记录。
5. 读取当前生效的 `CurrentControlSet`。
6. 任务完成后停止并删除计划任务，删除临时工作目录。
7. 管理员进程把结果返回给普通用户进程。
8. 普通用户进程生成最终 TXT。

注册表读取必须是只读操作，不得：

- 修改注册表；
- 修改注册表权限；
- 修改 Windows 配对状态；
- 重启蓝牙；
- 安装 PsExec；
- 读取未选中的其他设备密钥；
- 把密钥作为命令行参数传递；
- 把密钥写入普通日志或聊天。

临时目录采用随机名称 `BluetoothPairExport-<guid>`，并设置受限 ACL。SYSTEM 任务使用唯一任务名，并设置执行时间限制。UAC 取消、权限不足、任务超时和清理失败都需要给出明确错误。

如果修改 Broker/Worker 逻辑，必须保留路径校验、重解析点检查、任务清理和失败清理逻辑。

## 支持的配对数据

传统蓝牙 BR/EDR：

- 注册表适配器键下，以设备 MAC 命名的 `REG_BINARY` 值作为 LinkKey。
- 主密钥必须是 16 字节，即 32 个十六进制字符。
- 导出记录的 `PrimaryKeyValueName` 是设备 MAC。

BLE：

- 设备子键中的 `LTK` 是主密钥，必须是 16 字节。
- 如果实际存在，也原样导出 `IRK`、`CSRK`、`ERand`、`EDIV`、`AddressType`、`AuthReq`、`KeyLength`、`CEntralIRKStatus` 等参数。
- `IRK` 和 `CSRK` 如果存在，必须是 16 字节。
- `ERand` 允许 Windows 原始 8 字节二进制或 QWORD 表示。
- `EDIV` 必须是有效的 16 位范围值。
- 密钥长度如果存在，必须在 7 到 16 之间。
- 缺少有效 `LTK` 时不得生成看似有效的文件。
- 缺失字段不填零、不伪造。

当前真实测试的 `Inphic ZHEN` 导出成功。文件中确认只有该鼠标的一条 BLE 记录，主 LTK 长度为 16 字节，并保留了实际存在的其他参数。不要在新会话中读取或展示该文件中的具体密钥。

## TXT 文件格式

TXT 使用 UTF-8 无 BOM、LF 换行，固定英文字段名，中文注释，格式版本为 `1`。

主要结构：

```
[Export]
Format=BluetoothPairExport
FormatVersion=1
ToolVersion=1.0.0
ExportedAtUtc=...
RecordCount=...

[Device]
Name="..."
Type="..."
ContainerId="..."
Categories=[...]

[Adapter]
Address=AA:BB:CC:DD:EE:FF
RegistrySource="..."

[Record1]
Protocol=BLE
DeviceAddress=AA:BB:CC:DD:EE:FF
AddressSource=WindowsPairedEndpointAndRegistryMatch
IdentityAddressConfirmed=false
AddressType=Unknown
WindowsEndpointId="..."
PnpInstanceIds=[...]
RegistrySource="..."
PrimaryKeyValueName="LTK"

[Record1.Registry]
LTK.Type=REG_BINARY
LTK.Encoding=hex-bytes
LTK.Value=...
```

实际文件可能还有：

- `[Adapter.Registry]`
- `[Record1.Registry]` 中的 `IRK`、`CSRK`、`ERand`、`EDIV`、`AuthReq`、`KeyLength` 等字段。

编码规则：

- `REG_BINARY`：`hex-bytes`，每两个十六进制字符表示一个字节，严格保留 Windows 原始字节顺序，不要整段倒序。
- `REG_DWORD` / `REG_QWORD`：`unsigned-decimal`，使用无符号十进制；解析 QWORD 时不能使用浮点数。
- `REG_SZ` / `REG_EXPAND_SZ`：`json-string`。
- `REG_MULTI_SZ`：`json-array`。
- 元数据字符串使用 JSON 引号和转义。
- Registry 值名使用 URI 百分号编码。
- `IdentityAddressConfirmed=false` 是保守标记，表示工具没有独立验证 BLE 身份地址，不要把它改成 true。
- `AddressType=RandomUnclassified` 不等于确认了静态随机地址。
- Windows 原始注册表值类型和内容必须保留，不能只输出“转换后的猜测值”。

## 已完成的验证

运行：

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\outputs\BluetoothPairExport\tests\SelfTest.ps1
```

共有 32 项模拟检查通过，覆盖：

- BLE 鼠标识别；
- 离线设备显示；
- 按容器合并 BLE 和 Classic；
- 同名不同设备不误合并；
- 未配对设备过滤；
- MAC 地址规范化；
- 编号输入校验；
- 中文名称和换行注入防护；
- UTF-8 输出；
- 重复导出不覆盖；
- 缺失或过短 LTK/LinkKey；
- 异常 IRK、EDIV、密钥长度；
- Classic LinkKey；
- DWORD/QWORD 无符号转换；
- 多适配器选择；
- 不读取未选中设备；
- 注册表权限失败；
- UAC 取消；
- SYSTEM 任务超时；
- 计划任务停止与注销；
- 临时目录清理；
- 路径包含和重解析点保护。

真实本机验证结果：

- `Inphic ZHEN` 正确显示为“鼠标 / BLE / 未连接”。
- `华为畅享 80` 的 BLE 与传统蓝牙记录正确合并。
- 真实导出只有鼠标的一条记录。
- 主密钥验证为 16 字节。
- 没有发现残留的 BluetoothPairExport 计划任务或临时工作目录。

目前没有在 Fedora 上验证导入，也没有验证 Linux 端连接成功。

## 蓝牙双系统的重要技术背景

传统蓝牙设备通常只为同一个主机蓝牙地址保存一套 LinkKey。双系统共用同一个蓝牙适配器 MAC 时，Windows 和 Fedora 如果分别配对，后一次配对可能覆盖设备侧密钥。因此：

- 用户的原始要求是先在 Windows 配对。
- Windows 端导出 Windows 当前密钥。
- Fedora 端以后导入同一密钥。
- 如果之后在 Fedora 重新配对，可能使 Windows 端密钥失效。
- 对传统蓝牙设备，通常应让 Windows 成为最后配对的一方，再把 Windows 密钥导入 Fedora。
- BLE 设备使用 LTK、IRK、CSRK、ERand、EDIV 等参数，不能只把 Classic 的 LinkKey 逻辑套上去。
- Linux 导入脚本必须先识别 Fedora 的 BlueZ 版本、适配器地址、设备目录结构和现有 `info` 文件格式，再决定字段映射。
- 不能假设所有 BLE 设备都只需要 LTK。
- 不能把 Windows 的地址类型、随机地址和身份地址关系简单猜测。

参考过的项目和资料：

- C6S/one-pair：`https://github.com/C6S/one-pair`
- LinkWinBT：`https://github.com/vvoland/linkwinbt`
- bt-keys-sync：`https://github.com/KeyofBlueS/bt-keys-sync`
- ArchWiki Bluetooth Dual Boot：`https://wiki.archlinux.org/title/Bluetooth#Dual_boot_pairing`

`one-pair` 当前版本其实支持 `--device <MAC>`，但它仍会遍历 Windows 密钥，并且交互上不能很好地显示设备名称和类型，所以本项目仍然采用自制工具。

`bt-keys-sync` 对 BLE 支持有限，不能直接作为本项目的 Fedora 方案。LinkWinBT 有交互选择功能，但本项目需要更明确的导出格式、单设备读取和后续 Linux 脚本兼容性。

## 下一阶段：Fedora/Linux 导入

下一步是在 Fedora 编写 Bash 工具，读取 Windows 端生成的 TXT。

开始前应先检查：

- Fedora 的 BlueZ 版本；
- `bluetoothctl` 是否可用；
- `/var/lib/bluetooth` 下的适配器地址；
- 目标设备当前目录；
- 现有 `info` 文件；
- 目标设备是 Classic、BLE 还是双协议；
- Fedora 当前是否已经配对过该设备；
- Windows TXT 中的 `RecordN` 和 `RecordN.Registry` 是否足够映射。

Linux 工具的目标应包括：

- 只导入用户选择的一个 TXT 设备；
- 解析固定格式并严格校验字段；
- 显示将要修改的适配器、设备地址和协议；
- 提供 `--dry-run`；
- 修改前备份已有 `info` 文件；
- 不接触其他设备目录；
- 处理 Classic LinkKey 和 BLE LTK/IRK/CSRK/ERand/EDIV；
- 在必要时提醒 Windows 最后配对和设备侧密钥覆盖问题；
- 修改后重启或刷新 BlueZ 的方式必须谨慎；
- 记录成功、缺失字段和不可兼容设备；
- 不把密钥打印到普通终端日志；
- 不声称“Windows 导出成功就等于 Fedora 已验证成功”。

Linux 脚本尚未开始实现。新会话中若我说“继续 Fedora 部分”，请先检查现有 Windows 文件和 TXT 格式，然后针对实际 Fedora 环境设计导入步骤，不要重新制作一个不同的 Windows 导出格式。

## 后续协作规则

收到这个记忆匣提示词后，请先确认你已经理解：

- Windows 端已经实现并验证；
- 当前真正未完成的是 Fedora/BlueZ 导入；
- 不能重新把任务带回“是否使用 one-pair”的讨论；
- 不要要求我重复提供已经写在这里的背景；
- 不要读取、打印或泄露真实导出文件里的密钥；
- 不要把本机测试设备地址硬编码进 Linux 工具；
- 如果需要 Fedora 信息，应通过只读检查发现；
- 如果修改代码，优先检查现有文件，而不是从零重写；
- 保持中文界面、单设备导入、可审计、可回滚和不批量读取的设计。