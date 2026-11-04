#Requires -Version 5.1
<#
.SYNOPSIS
    下载联想（Lenovo）出厂校色文件（ICC Profile）。

.DESCRIPTION
    通过联想 supportapi 的公开查询接口，按「机器型号 + 序列号」取回该机器出厂时
    在产线测量的那套 ICC 校色文件（每个面板单独校准，因此逐台不同）。

    背景：X-Rite Color Assistant 在部分机器上会报「无法获取配置文件存档 URL」
    并且无法恢复配色。本脚本直接调用同一后端接口取回相同的文件。

.PARAMETER Model
    机器型号（MTM），例如 21J70007CD 或 21J7。

.PARAMETER Serial
    机器序列号（S/N），例如 PF4PRH50。

.PARAMETER OutputPath
    下载目录，默认 %USERPROFILE%\Downloads\LenovoColorProfile。

.PARAMETER Install
    下载后把 .icm 复制到系统颜色目录（C:\Windows\System32\spool\drivers\color）。
    需要管理员权限。

.PARAMETER ResetGamma
    把显卡 gamma ramp 重置为恒等（线性）。用于修复应用校色文件后出现的偏色。

.PARAMETER Force
    覆盖已存在的下载目录。

.EXAMPLE
    .\Get-LenovoColorProfile.ps1

.EXAMPLE
    .\Get-LenovoColorProfile.ps1 -Model 21J7 -Serial PF4PRH50 -Install

.NOTES
    仅用于获取你自己设备的官方校色文件。接口为联想未公开接口，可能随时变更。
#>
[CmdletBinding()]
param(
    [string]$Model,
    [string]$Serial,
    [string]$OutputPath = (Join-Path $env:USERPROFILE 'Downloads\LenovoColorProfile'),
    [switch]$Install,
    [switch]$ResetGamma,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ---------- 输出辅助 ----------
function Write-Step { param($m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn2{ param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err2 { param($m) Write-Host "[-] $m" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- gamma ramp 重置 ----------
function Reset-GammaRamp {
    if (-not ('GammaRamp' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class GammaRamp {
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")]  public static extern bool GetDeviceGammaRamp(IntPtr hdc, ushort[] ramp);
    [DllImport("gdi32.dll")]  public static extern bool SetDeviceGammaRamp(IntPtr hdc, ushort[] ramp);
}
'@
    }
    $hdc = [GammaRamp]::GetDC([IntPtr]::Zero)
    try {
        $ramp = New-Object 'ushort[]' 768
        for ($c = 0; $c -lt 3; $c++) {
            for ($i = 0; $i -lt 256; $i++) { $ramp[$c * 256 + $i] = [ushort]($i * 257) }
        }
        $ok = [GammaRamp]::SetDeviceGammaRamp($hdc, $ramp)
        if ($ok) { Write-Ok 'gamma ramp 已重置为恒等（中性）' }
        else     { Write-Err2 'gamma ramp 重置失败（可能被驱动拒绝）' }
    } finally {
        [void][GammaRamp]::ReleaseDC([IntPtr]::Zero, $hdc)
    }
}

if ($ResetGamma) {
    Write-Step '重置显卡 gamma ramp...'
    Reset-GammaRamp
    if (-not $Model -and -not $Serial) { return }
}

# ---------- 交互式输入 ----------
Write-Host ''
Write-Host '=============================================' -ForegroundColor White
Write-Host '  Lenovo 出厂校色文件下载工具' -ForegroundColor White
Write-Host '=============================================' -ForegroundColor White
Write-Host ''

if (-not $Model) {
    Write-Host '【机器型号 MTM】去哪里找：' -ForegroundColor Yellow
    Write-Host '  1) 机身底部贴纸，形如  TYPE 21J7-0007CD'
    Write-Host '  2) 开机按 F1 进 BIOS，Main 页的 Machine Type Model'
    Write-Host '  3) 命令行：wmic csproduct get name'
    Write-Host '  4) 命令行：Get-CimInstance Win32_ComputerSystem | Select-Object Model'
    Write-Host ''
    $Model = Read-Host '请输入机器型号（例如 21J70007CD，或只填前 4 位 21J7）'
}

if (-not $Serial) {
    Write-Host ''
    Write-Host '【机器序列号 S/N】去哪里找：' -ForegroundColor Yellow
    Write-Host '  1) 机身底部贴纸，标注 S/N 或 Serial Number'
    Write-Host '  2) 开机按 F1 进 BIOS，Main 页的 Serial Number'
    Write-Host '  3) 命令行：wmic bios get serialnumber'
    Write-Host '  4) 命令行：Get-CimInstance Win32_BIOS | Select-Object SerialNumber'
    Write-Host ''
    $Serial = Read-Host '请输入机器序列号（例如 PF4PRH50）'
}

$Model  = ($Model  -replace '\s', '').ToUpper()
$Serial = ($Serial -replace '\s', '').ToUpper()

if ([string]::IsNullOrWhiteSpace($Model) -or [string]::IsNullOrWhiteSpace($Serial)) {
    Write-Err2 '型号和序列号都不能为空。'; return
}

Write-Host ''
Write-Ok "型号 = $Model"
Write-Ok "序列号 = $Serial"
Write-Host ''

# ---------- 构造候选查询串 ----------
# 联想数据库里同一台机器可能注册了多种格式的键，逐个尝试。
$candidates = New-Object System.Collections.Generic.List[object]
if ($Model.Length -gt 4) {
    $candidates.Add([pscustomobject]@{ Key = "1S$($Model.Substring(0,4))$Serial"; Label = '1S + 机器类型(4位) + 序列号' })
    $candidates.Add([pscustomobject]@{ Key = "1S$Model$Serial";                    Label = '1S + 完整MTM + 序列号' })
} else {
    $candidates.Add([pscustomobject]@{ Key = "1S$Model$Serial";                    Label = '1S + 机器类型(4位) + 序列号' })
}
$candidates.Add([pscustomobject]@{ Key = $Serial;                                  Label = '纯序列号' })

$apiBase = 'https://supportapi.lenovo.com/ColorCalibration/GetFileBySn?sn='
$link = $null
$usedKey = $null

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 } catch {}

Write-Step '正在查询联想校色服务器...'
foreach ($c in $candidates) {
    $url = $apiBase + [Uri]::EscapeDataString($c.Key)
    try {
        $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 25 -UseBasicParsing -ErrorAction Stop
        $candidate = if ($resp -is [string]) { $resp } else { [string]$resp }
        if ($candidate -match '^https://') {
            $link = $candidate
            $usedKey = $c
            Write-Ok "查询成功（$($c.Label)）"
            break
        }
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 404) {
            Write-Host "    未命中：$($c.Label)" -ForegroundColor DarkGray
        } elseif ($code -eq 401 -or $code -eq 403) {
            Write-Warn2 "接口要求鉴权（HTTP $code），跳过"
        } else {
            Write-Host "    失败：$($c.Label) -> $($_.Exception.Message)" -ForegroundColor DarkGray
        }
    }
}

if (-not $link) {
    Write-Host ''
    Write-Err2 '所有查询串都未命中。可能原因：'
    Write-Host '    - 型号或序列号输入有误（注意区分 0 和 O）'
    Write-Host '    - 该机器出厂时没有校色数据（非 X-Rite 校色机型）'
    Write-Host '    - 联想数据库中该机器的记录格式特殊'
    Write-Host ''
    Write-Host '  小技巧：型号可以只填前 4 位再试一次，例如 21J7。'
    return
}

Write-Host ''
Write-Ok "临时下载链接已获取（查询键：$($usedKey.Key)）"
Write-Host "    $link" -ForegroundColor DarkGray

# ---------- 下载 ----------
if (Test-Path -LiteralPath $OutputPath) {
    if ($Force) { Remove-Item -LiteralPath $OutputPath -Recurse -Force }
    else {
        $OutputPath = Join-Path $OutputPath (Get-Date -Format 'yyyyMMdd_HHmmss')
    }
}
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

$zipPath = Join-Path $OutputPath ("ColorCalibration_$($usedKey.Key).zip")
Write-Step '正在下载...'
try {
    Invoke-WebRequest -Uri $link -OutFile $zipPath -TimeoutSec 180 -UseBasicParsing -ErrorAction Stop
} catch {
    Write-Err2 "下载失败：$($_.Exception.Message)"
    Write-Host '  链接有时效（约几分钟），请重新运行脚本。'
    return
}

$size = (Get-Item -LiteralPath $zipPath).Length
Write-Ok ("下载完成：{0} ({1:N0} 字节)" -f (Split-Path $zipPath -Leaf), $size)

# ---------- 解压与校验 ----------
Write-Step '解压并校验内容...'
$extractDir = Join-Path $OutputPath 'extracted'
try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force -ErrorAction Stop
} catch {
    Write-Err2 "解压失败：$($_.Exception.Message)"; return
}

$icms = @(Get-ChildItem -LiteralPath $extractDir -Filter '*.icm' -File -ErrorAction SilentlyContinue)
$panel = Join-Path $extractDir 'PanelInfo.xml'

Write-Host ''
Write-Host '包含的校色文件：' -ForegroundColor White
foreach ($f in $icms) {
    Write-Host ("    {0,-32} {1,8:N0} B" -f $f.Name, $f.Length)
}

if (-not $icms) {
    Write-Warn2 '压缩包里没有 .icm 文件，可能不是校色包。'
}

if (Test-Path -LiteralPath $panel) {
    Write-Host ''
    Write-Host 'PanelInfo.xml：' -ForegroundColor White
    Get-Content -LiteralPath $panel | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}

$panelId = if ($icms.Count -gt 0) {
    ($icms[0].BaseName -replace '^TPLCD_', '') -replace '_.*$', ''
} else { $null }
if ($panelId) {
    Write-Host ''
    Write-Ok "面板标识：$panelId"
    Write-Host "    请确认这与当前屏幕一致（不一致说明这台机器的校色包对应的是另一块面板）。" -ForegroundColor DarkGray
}

# ---------- 安装 ----------
if ($Install) {
    Write-Host ''
    Write-Step '安装到系统颜色目录...'
    if (-not (Test-Admin)) {
        Write-Err2 '需要管理员权限。请以管理员身份重新运行，或手动复制。'
        Write-Host "    源目录：$extractDir"
        Write-Host '    目标：C:\Windows\System32\spool\drivers\color'
        return
    }
    $colorDir = 'C:\Windows\System32\spool\drivers\color'
    foreach ($f in $icms) {
        $dst = Join-Path $colorDir $f.Name
        if ((Test-Path -LiteralPath $dst) -and -not $Force) {
            Write-Warn2 "已存在，跳过：$($f.Name)（加 -Force 覆盖）"
            continue
        }
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
        Write-Ok "已复制：$($f.Name)"
    }
    Write-Host ''
    Write-Warn2 '注意：Default / DICOM_Dim / DICOM_Office 这几个文件内嵌 vcgt（显卡 gamma 表）。'
    Write-Host '    应用后若出现「灰色变蓝」等偏色，运行：' -ForegroundColor DarkGray
    Write-Host '        .\Get-LenovoColorProfile.ps1 -ResetGamma' -ForegroundColor DarkGray
}

Write-Host ''
Write-Ok "完成。输出目录：$OutputPath"
Write-Host '    下次想换回中性色彩，可运行：.\Get-LenovoColorProfile.ps1 -ResetGamma' -ForegroundColor DarkGray
