[README.md](https://github.com/user-attachments/files/34264546/README.md)
# Lenovo 出厂校色文件下载工具

按「机器型号 + 序列号」取回联想出厂校色文件（ICC Profile）的 PowerShell 脚本。

用于解决 **X-Rite Color Assistant 报「无法获取配置文件存档 URL」、无法恢复配色** 的问题。

<img width="407" height="350" alt="image" src="https://github.com/user-attachments/assets/f8a40c3e-a101-4121-bd98-7446f17e5a69" />

---

## 背景

不少联想机型（ThinkPad / 拯救者 / YOGA 等）出厂时会对**每一块屏幕单独做色彩校准**，把结果打包成一套 `.icm` 文件，绑定到该机的序列号。这些文件不随驱动发布，只存在联想服务器上。

`X-Rite Color Assistant` 负责把它们取回来并安装。但这款软件的恢复流程经常失败：

- 弹窗「没有为显示器自定义的 ICC 配置文件，X-Rite Color Assistant 无法工作」然后退出
- 日志里留下 `Failed to obtain profile archive URL.`
- 联想社区从 2020 年就有人报，至今仍时有人遇到

---


## 两种使用方式

### 方式一：图形界面（推荐，给不想碰命令行的人）

双击 **`Start.cmd`** 即可打开窗口，不需要任何安装。

界面里能做的事：

| 按钮 | 作用 |
|---|---|
| **自动检测**（型号 / 序列号旁边） | 直接从系统读出来，不用去翻贴纸 |
| **开始下载** | 自动尝试多种查询键，命中后下载并校验 |
| **安装到系统** | 把 `.icm` 复制到系统颜色目录（会弹 UAC） |
| **重置颜色** | 把显卡 gamma 重置为中性，修「灰色变蓝」 |
| **打开目录** | 打开下载好的文件夹 |

窗口底部会显示当前是「管理员权限」还是「普通权限」——安装那一步需要管理员。

> 如果双击 `Start.cmd` 没反应，右键 → 以管理员身份运行再试。

### 方式二：命令行

### 交互式

```powershell
.\Get-LenovoColorProfile.ps1
```

脚本会提示你输入型号和序列号，并说明去哪里找。

### 带参数

```powershell
.\Get-LenovoColorProfile.ps1 -Model 主机型号 -Serial 序列号
```

### 下载后直接安装

```powershell
# 需要管理员权限
.\Get-LenovoColorProfile.ps1 -Model 主机型号 -Serial 序列号 -Install
```

### 修复偏色

```powershell
.\Get-LenovoColorProfile.ps1 -ResetGamma
```

### 参数一览

| 参数 | 说明 |
|---|---|
| `-Model` | 机器型号（MTM），可填完整 10 位或只填前 4 位 |
| `-Serial` | 机器序列号 |
| `-OutputPath` | 下载目录，默认 `%USERPROFILE%\Downloads\LenovoColorProfile` |
| `-Install` | 复制 `.icm` 到系统颜色目录（需管理员） |
| `-ResetGamma` | 把显卡 gamma ramp 重置为恒等 |
| `-Force` | 覆盖已存在的输出目录 / 已安装的同名文件 |

---

## 型号和序列号去哪里找

### 机器型号（MTM）

1. **机身底部贴纸**
2. **BIOS** —— 开机按 `F1`（ThinkPad）或 `F2`（部分机型），Main 页的 `Machine Type Model`
3. **命令行**
   ```powershell
   wmic csproduct get name
   # 或
   Get-CimInstance Win32_ComputerSystem | Select-Object Model
   ```

### 序列号（S/N）

1. **机身底部贴纸** —— 标注 `S/N` 或 `Serial Number`
2. **BIOS** —— Main 页的 `Serial Number`
3. **命令行**
   ```powershell
   wmic bios get serialnumber
   # 或
   Get-CimInstance Win32_BIOS | Select-Object SerialNumber
   ```

> 输入时注意区分 `0`（数字零）和 `O`（字母），以及 `1` 和 `I`。脚本会自动转大写并去掉空格。

---


## 安装与使用

### 手动安装

1. 把 `.icm` 复制到 `C:\Windows\System32\spool\drivers\color`（需管理员）
2. 右键桌面 → 显示设置 → 高级显示 → 显示适配器属性 → **颜色管理** → 设备选显示器 → **添加** → 选择对应的 `.icm` → **设为默认**

### 用 X-Rite Color Assistant

把文件放进去之后，XCA 就能识别到了（它按 `TPLCD_<面板ID>_<名称>.icm` 匹配文件名），不会再弹「无法恢复」的窗。

---

## 常见问题

| 现象 | 原因 / 解决 |
|---|---|
| 三种格式都 404 | 型号或序列号有误；或该机出厂没有校色数据（不是 X-Rite 机型） |
| HTTP 401 / 403 | 接口错误，正常不会出现 |
| 下载失败 | 临时链接约 3 分钟后过期，重新运行脚本即可 |
| `Invoke-RestMethod` 报 TLS 错误 | 系统过旧。脚本已尝试启用 TLS 1.2 |
| 装完 XCA 还是认不出 | 文件名必须是 `TPLCD_<面板ID>_<名称>.icm`；确认面板 ID 与当前屏幕一致 |
| 装完颜色很怪 | 面板 ID 不匹配（比如换过屏），或遇到 vcgt 问题 |

---

## 兼容性

- 目前仅在ThinkPad T14p Gen1上验证可行

---

## 免责声明

- 本脚本只用于**获取你自己设备的官方校色文件**。
- 仅供学习交流使用
- 下载到的文件来自联想服务器，本脚本不对其内容做任何保证。
- 修改系统颜色目录前建议先备份。

---

## License

MIT
