#Requires -Version 5.1
<#
    Lenovo 出厂校色文件下载工具 - 图形界面版
    单文件、无依赖，Windows 10/11 + PowerShell 5.1 即可运行。
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

try {
    Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public class DpiHelper { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
    [void][DpiHelper]::SetProcessDPIAware()
} catch {}

$script:LogQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:State    = [hashtable]::Synchronized(@{ Done = $true; Ok = $false; OutDir = $null; Key = $null })
$script:Runner   = $null
$script:Handle   = $null
$script:Runspace = $null

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
$script:IsAdmin = Test-Admin

function Add-Log([string]$msg) {
    $script:LogQueue.Enqueue($msg)
}

# ======================= 后台工作脚本 =======================
$WorkerCode = @'
param($Model, $Serial, $OutDir, $Queue, $State)

function L([string]$m) { $Queue.Enqueue($m) }

try {
    $apiBase  = 'https://supportapi.lenovo.com/ColorCalibration/GetFileBySn?sn='
    $cands    = New-Object System.Collections.Generic.List[object]

    if ($Model.Length -gt 4) {
        $cands.Add([pscustomobject]@{ Key = "1S$($Model.Substring(0,4))$Serial"; Label = '1S + 类型(4位) + 序列号' })
        $cands.Add([pscustomobject]@{ Key = "1S$Model$Serial";                   Label = '1S + 完整MTM + 序列号' })
    } else {
        $cands.Add([pscustomobject]@{ Key = "1S$Model$Serial";                   Label = '1S + 类型(4位) + 序列号' })
    }
    $cands.Add([pscustomobject]@{ Key = $Serial;                                 Label = '纯序列号' })

    $link = $null
    $used = $null

    L '正在查询联想校色服务器...'
    L ''
    foreach ($c in $cands) {
        L ("尝试 [{0}]  {1}" -f $c.Label, $c.Key)
        $url = $apiBase + [Uri]::EscapeDataString($c.Key)
        try {
            $resp = Invoke-RestMethod -Uri $url -TimeoutSec 25 -UseBasicParsing -ErrorAction Stop
            $s = if ($resp -is [string]) { $resp } else { [string]$resp }
            if ($s -match '^https://') {
                $link = $s; $used = $c
                L '  -> 命中'
                break
            }
            L '  -> 返回内容异常'
        } catch {
            $code = $null
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -eq 404) { L '  -> 未命中 (404)' }
            elseif ($code -eq 401 -or $code -eq 403) { L "  -> 接口要求鉴权 (HTTP $code)" }
            else { L ("  -> 失败：{0}" -f $_.Exception.Message) }
        }
    }

    if (-not $link) {
        L ''
        L '所有查询串都未命中。'
        L '可能原因：型号/序列号有误，或该机出厂没有校色数据。'
        $State.Ok = $false
        return
    }

    L ''
    L ("下载地址已获取（查询键：{0}）" -f $used.Key)

    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    }
    $zip = Join-Path $OutDir ("ColorCalibration_{0}.zip" -f $used.Key)

    L '正在下载...'
    Invoke-WebRequest -Uri $link -OutFile $zip -TimeoutSec 180 -UseBasicParsing -ErrorAction Stop
    L ("下载完成，{0:N0} 字节" -f (Get-Item -LiteralPath $zip).Length)

    $ex = Join-Path $OutDir 'extracted'
    if (Test-Path -LiteralPath $ex) { Remove-Item -LiteralPath $ex -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force -ErrorAction Stop

    $icms = @(Get-ChildItem -LiteralPath $ex -Filter '*.icm' -File -ErrorAction SilentlyContinue)
    L ''
    L ("包含 {0} 个校色文件：" -f $icms.Count)
    foreach ($f in $icms) { L ("    {0,-30} {1,8:N0} B" -f $f.Name, $f.Length) }

    $pi = Join-Path $ex 'PanelInfo.xml'
    if (Test-Path -LiteralPath $pi) {
        L ''
        L 'PanelInfo.xml：'
        Get-Content -LiteralPath $pi | ForEach-Object { L ("    {0}" -f $_) }
    }

    if ($icms.Count -gt 0) {
        $panel = ($icms[0].BaseName -replace '^TPLCD_', '') -replace '_.*$', ''
        L ''
        L ("面板标识：{0}" -f $panel)
        L '请确认与当前屏幕一致（不一致说明该机器的校色包对应的是另一块面板）。'
    }

    $State.OutDir = $OutDir
    $State.Key    = $used.Key
    $State.Ok     = $true
}
catch {
    L ''
    L ("出错：{0}" -f $_.Exception.Message)
    if ($_.Exception.Message -match 'SSL|TLS|连接') {
        L '提示：若是 TLS 错误，确认系统时间正确、且未被代理软件拦截。'
    }
    $State.Ok = $false
}
finally {
    $State.Done = $true
}
'@

# ======================= 界面 =======================
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Lenovo 出厂校色文件工具'
$form.Size            = New-Object System.Drawing.Size(840, 720)
$form.StartPosition   = 'CenterScreen'
$form.MinimumSize     = New-Object System.Drawing.Size(720, 620)
$form.Font            = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.BackColor       = [System.Drawing.Color]::FromArgb(248, 248, 250)

$fontMono = New-Object System.Drawing.Font('Consolas', 9)

# --- 标题 ---
$lblTitle           = New-Object System.Windows.Forms.Label
$lblTitle.Text      = 'Lenovo 出厂校色文件下载'
$lblTitle.Font      = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.Location  = New-Object System.Drawing.Point(18, 14)
$lblTitle.AutoSize  = $true
$form.Controls.Add($lblTitle)

$lblSub           = New-Object System.Windows.Forms.Label
$lblSub.Text      = '按机器型号 + 序列号，取回本机出厂时的 ICC 校色文件'
$lblSub.Location  = New-Object System.Drawing.Point(20, 48)
$lblSub.AutoSize  = $true
$lblSub.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblSub)

# ---------- 自动布局：TableLayoutPanel 让列宽跟随文字，DPI/字体差异下也不会重叠 ----------
$form.Controls.Remove($lblTitle)
$form.Controls.Remove($lblSub)

$root            = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock       = 'Fill'
$root.ColumnCount = 1
$root.RowCount    = 5
$root.Padding     = New-Object System.Windows.Forms.Padding(18, 12, 18, 10)
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

$header               = New-Object System.Windows.Forms.FlowLayoutPanel
$header.FlowDirection = 'TopDown'
$header.AutoSize      = $true
$header.WrapContents  = $false
$header.Dock          = 'Fill'
$lblTitle.Margin      = New-Object System.Windows.Forms.Padding(0, 0, 0, 2)
$lblSub.Margin        = New-Object System.Windows.Forms.Padding(2, 0, 0, 6)
[void]$header.Controls.Add($lblTitle)
[void]$header.Controls.Add($lblSub)
[void]$root.Controls.Add($header, 0, 0)

# 三列：标签(自动) | 输入(填充) | 按钮(自动)
$tlp              = New-Object System.Windows.Forms.TableLayoutPanel
$tlp.AutoSize     = $true
$tlp.Dock         = 'Fill'
$tlp.ColumnCount  = 3
$tlp.RowCount     = 5
[void]$tlp.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$tlp.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$tlp.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
for ($r = 0; $r -lt 5; $r++) {
    [void]$tlp.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
}
[void]$root.Controls.Add($tlp, 0, 1)

# --- 型号 ---
$lblModel           = New-Object System.Windows.Forms.Label
$lblModel.Text      = '机器型号 (MTM)'
$lblModel.AutoSize  = $true
$lblModel.TextAlign = 'MiddleLeft'
$lblModel.Anchor    = 'Left'
$lblModel.Margin    = New-Object System.Windows.Forms.Padding(0, 8, 12, 0)

$txtModel        = New-Object System.Windows.Forms.TextBox
$txtModel.Dock   = 'Fill'
$txtModel.Margin = New-Object System.Windows.Forms.Padding(0, 6, 8, 0)

$btnDetectModel        = New-Object System.Windows.Forms.Button
$btnDetectModel.Text   = '自动检测'
$btnDetectModel.Size   = New-Object System.Drawing.Size(92, 28)
$btnDetectModel.Anchor = 'Left'
$btnDetectModel.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)

[void]$tlp.Controls.Add($lblModel, 0, 0)
[void]$tlp.Controls.Add($txtModel, 1, 0)
[void]$tlp.Controls.Add($btnDetectModel, 2, 0)

$lblModelHint           = New-Object System.Windows.Forms.Label
$lblModelHint.Text      = '机身底部贴纸 TYPE 后面；或 BIOS Main 页的 Machine Type Model'
$lblModelHint.AutoSize  = $true
$lblModelHint.ForeColor = [System.Drawing.Color]::Gray
$lblModelHint.Font      = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$lblModelHint.Margin    = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
[void]$tlp.Controls.Add($lblModelHint, 1, 1)
$tlp.SetColumnSpan($lblModelHint, 2)

# --- 序列号 ---
$lblSerial           = New-Object System.Windows.Forms.Label
$lblSerial.Text      = '机器序列号 (S/N)'
$lblSerial.AutoSize  = $true
$lblSerial.TextAlign = 'MiddleLeft'
$lblSerial.Anchor    = 'Left'
$lblSerial.Margin    = New-Object System.Windows.Forms.Padding(0, 8, 12, 0)

$txtSerial        = New-Object System.Windows.Forms.TextBox
$txtSerial.Dock   = 'Fill'
$txtSerial.Margin = New-Object System.Windows.Forms.Padding(0, 6, 8, 0)

$btnDetectSerial        = New-Object System.Windows.Forms.Button
$btnDetectSerial.Text   = '自动检测'
$btnDetectSerial.Size   = New-Object System.Drawing.Size(92, 28)
$btnDetectSerial.Anchor = 'Left'
$btnDetectSerial.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)

[void]$tlp.Controls.Add($lblSerial, 0, 2)
[void]$tlp.Controls.Add($txtSerial, 1, 2)
[void]$tlp.Controls.Add($btnDetectSerial, 2, 2)

$lblSerialHint           = New-Object System.Windows.Forms.Label
$lblSerialHint.Text      = '机身底部贴纸的 S/N；或 BIOS Main 页的 Serial Number'
$lblSerialHint.AutoSize  = $true
$lblSerialHint.ForeColor = [System.Drawing.Color]::Gray
$lblSerialHint.Font      = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$lblSerialHint.Margin    = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
[void]$tlp.Controls.Add($lblSerialHint, 1, 3)
$tlp.SetColumnSpan($lblSerialHint, 2)

# --- 输出目录 ---
$lblOut           = New-Object System.Windows.Forms.Label
$lblOut.Text      = '保存到'
$lblOut.AutoSize  = $true
$lblOut.TextAlign = 'MiddleLeft'
$lblOut.Anchor    = 'Left'
$lblOut.Margin    = New-Object System.Windows.Forms.Padding(0, 8, 12, 0)

$txtOut        = New-Object System.Windows.Forms.TextBox
$txtOut.Dock   = 'Fill'
$txtOut.Margin = New-Object System.Windows.Forms.Padding(0, 6, 8, 0)
$txtOut.Text   = (Join-Path $env:USERPROFILE 'Downloads\LenovoColorProfile')

$btnBrowse        = New-Object System.Windows.Forms.Button
$btnBrowse.Text   = '浏览...'
$btnBrowse.Size   = New-Object System.Drawing.Size(92, 28)
$btnBrowse.Anchor = 'Left'
$btnBrowse.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)

[void]$tlp.Controls.Add($lblOut, 0, 4)
[void]$tlp.Controls.Add($txtOut, 1, 4)
[void]$tlp.Controls.Add($btnBrowse, 2, 4)

# --- 按钮区 ---
$flow               = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.FlowDirection = 'LeftToRight'
$flow.AutoSize      = $true
$flow.Dock          = 'Fill'
$flow.WrapContents  = $false
$flow.Margin        = New-Object System.Windows.Forms.Padding(0, 12, 0, 8)

$btnStart            = New-Object System.Windows.Forms.Button
$btnStart.Text       = '开始下载'
$btnStart.Size       = New-Object System.Drawing.Size(120, 36)
$btnStart.BackColor  = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnStart.ForeColor  = [System.Drawing.Color]::White
$btnStart.FlatStyle  = 'Flat'
$btnStart.FlatAppearance.BorderSize = 0
$btnStart.Margin     = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)

$btnInstall          = New-Object System.Windows.Forms.Button
$btnInstall.Text     = '安装到系统'
$btnInstall.Size     = New-Object System.Drawing.Size(120, 36)
$btnInstall.Enabled  = $false
$btnInstall.Margin   = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)

$btnReset          = New-Object System.Windows.Forms.Button
$btnReset.Text     = '重置颜色'
$btnReset.Size     = New-Object System.Drawing.Size(120, 36)
$btnReset.Margin   = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)

$btnOpen          = New-Object System.Windows.Forms.Button
$btnOpen.Text     = '打开目录'
$btnOpen.Size     = New-Object System.Drawing.Size(110, 36)
$btnOpen.Enabled  = $false
$btnOpen.Margin   = New-Object System.Windows.Forms.Padding(0)

[void]$flow.Controls.Add($btnStart)
[void]$flow.Controls.Add($btnInstall)
[void]$flow.Controls.Add($btnReset)
[void]$flow.Controls.Add($btnOpen)
[void]$root.Controls.Add($flow, 0, 2)

# --- 日志 ---
$txtLog            = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline  = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly   = $true
$txtLog.Font       = $fontMono
$txtLog.BackColor  = [System.Drawing.Color]::White
$txtLog.Dock       = 'Fill'
$txtLog.Margin     = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
[void]$root.Controls.Add($txtLog, 0, 3)

# --- 状态栏 ---
$status              = New-Object System.Windows.Forms.TableLayoutPanel
$status.ColumnCount  = 2
$status.RowCount     = 1
$status.Dock         = 'Fill'
$status.AutoSize     = $true
[void]$status.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$status.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))

$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Text      = '就绪'
$lblStatus.AutoSize  = $false
$lblStatus.Dock      = 'Fill'
$lblStatus.TextAlign = 'MiddleLeft'
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray

$lblMode            = New-Object System.Windows.Forms.Label
$lblMode.Text       = if ($script:IsAdmin) { '管理员权限' } else { '普通权限' }
$lblMode.AutoSize   = $true
$lblMode.Anchor     = 'Right'
$lblMode.TextAlign  = 'MiddleRight'
$lblMode.ForeColor  = if ($script:IsAdmin) { [System.Drawing.Color]::Green } else { [System.Drawing.Color]::DimGray }

[void]$status.Controls.Add($lblStatus, 0, 0)
[void]$status.Controls.Add($lblMode, 1, 0)
[void]$root.Controls.Add($status, 0, 4)

$form.Controls.Add($root)

# ======================= 交互逻辑 =======================
function Set-Busy([bool]$busy) {
    $btnStart.Enabled   = -not $busy
    $btnReset.Enabled   = -not $busy
    $btnDetectModel.Enabled = -not $busy
    $btnDetectSerial.Enabled = -not $busy
    if ($busy) {
        $btnInstall.Enabled = $false
        $btnOpen.Enabled    = $false
    }
    $lblStatus.Text = if ($busy) { '处理中，请稍候...' } else { '就绪' }
}

$btnDetectModel.Add_Click({
    try {
        $m = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Model
        if ($m) { $txtModel.Text = $m.Trim().ToUpper() }
    } catch {
        try { $m = (Get-WmiObject -Class Win32_ComputerSystem).Model; if ($m) { $txtModel.Text = $m.Trim().ToUpper() } }
        catch { Add-Log '自动检测型号失败，请手动输入。' }
    }
})

$btnDetectSerial.Add_Click({
    try {
        $s = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
        if ($s) { $txtSerial.Text = $s.Trim().ToUpper() }
    } catch {
        try { $s = (Get-WmiObject -Class Win32_BIOS).SerialNumber; if ($s) { $txtSerial.Text = $s.Trim().ToUpper() } }
        catch { Add-Log '自动检测序列号失败，请手动输入。' }
    }
})

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择保存目录'
    if (Test-Path -LiteralPath $txtOut.Text) { $dlg.SelectedPath = $txtOut.Text }
    if ($dlg.ShowDialog() -eq 'OK') { $txtOut.Text = $dlg.SelectedPath }
})

$btnStart.Add_Click({
    if (-not $script:State.Done) { return }   # 上一次还在跑，忽略重复点击

    $model  = ($txtModel.Text  -replace '\s', '').ToUpper()
    $serial = ($txtSerial.Text -replace '\s', '').ToUpper()
    if (-not $model -or -not $serial) {
        [void][System.Windows.Forms.MessageBox]::Show('请先填写机器型号和序列号。', '提示', 'OK', 'Warning')
        return
    }

    $outDir = $txtOut.Text
    if (-not $outDir) { $outDir = Join-Path $env:USERPROFILE 'Downloads\LenovoColorProfile' }

    $txtLog.Clear()
    $script:State.Done   = $false
    $script:State.Ok     = $false
    $script:State.OutDir = $null
    $script:State.Key    = $null

    Set-Busy $true
    Add-Log ("型号 = {0}    序列号 = {1}" -f $model, $serial)
    Add-Log ''

    # 清理上一次运行时（重复下载必须做，否则 runspace 泄漏）
    if ($script:Runner) {
        try { $script:Runner.Stop() }    catch { }
        try { $script:Runner.Dispose() } catch { }
    }
    if ($script:Runspace) {
        try { $script:Runspace.Close() }   catch { }
        try { $script:Runspace.Dispose() } catch { }
    }
    $script:Runner   = $null
    $script:Handle   = $null
    $script:Runspace = $null

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $script:Runspace = $rs

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($WorkerCode).AddArgument($model).AddArgument($serial).AddArgument($outDir).AddArgument($script:LogQueue).AddArgument($script:State)
    $script:Runner = $ps
    $script:Handle = $ps.BeginInvoke()
})

$btnInstall.Add_Click({
    $dir = $script:State.OutDir
    if (-not $dir) {
        [void][System.Windows.Forms.MessageBox]::Show('请先完成一次下载。', '提示', 'OK', 'Warning')
        return
    }
    $ex = Join-Path $dir 'extracted'
    $files = @(Get-ChildItem -LiteralPath $ex -Filter '*.icm' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('下载目录里没有 .icm 文件。', '提示', 'OK', 'Warning')
        return
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("将把 {0} 个校色文件复制到系统颜色目录：`n`nC:\Windows\System32\spool\drivers\color`n`n" +
         "注意：Default / DICOM_Dim / DICOM_Office 内嵌 vcgt，应用后可能出现偏色，`n" +
         "可用「重置颜色」按钮恢复。`n`n继续吗？") -f $files.Count,
        '确认安装', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }

    $tmp = Join-Path $env:TEMP ('lenovo_color_install_{0}.ps1' -f [guid]::NewGuid().ToString('N'))
    $lines = @('$ErrorActionPreference = ''Stop''')
    foreach ($f in $files) {
        $lines += ("Copy-Item -LiteralPath '{0}' -Destination 'C:\Windows\System32\spool\drivers\color' -Force" -f $f.FullName)
    }
    $lines += 'Write-Host ""'
    $lines += 'Write-Host "安装完成。" -ForegroundColor Green'
    $lines += 'Write-Host "可打开「颜色管理」把对应配置文件设为默认，或重启 X-Rite Color Assistant。"'
    $lines += 'Write-Host ""'
    $lines += 'Write-Host "按任意键关闭..."'
    $lines += '$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")'
    Set-Content -LiteralPath $tmp -Value $lines -Encoding UTF8

    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmp) -ErrorAction Stop
        Add-Log ''
        Add-Log '已打开管理员窗口执行安装。'
    } catch {
        Add-Log ''
        Add-Log ("安装取消或失败：{0}" -f $_.Exception.Message)
    }
})

$btnReset.Add_Click({
    try {
        if (-not ('GammaRamp' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class GammaRamp {
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
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
            if ([GammaRamp]::SetDeviceGammaRamp($hdc, $ramp)) {
                Add-Log '已把显卡 gamma 重置为中性（线性）。'
            } else {
                Add-Log '重置失败：驱动拒绝了该操作。'
            }
        } finally {
            [void][GammaRamp]::ReleaseDC([IntPtr]::Zero, $hdc)
        }
    } catch {
        Add-Log ("重置出错：{0}" -f $_.Exception.Message)
    }
})

$btnOpen.Add_Click({
    if ($script:State.OutDir -and (Test-Path -LiteralPath $script:State.OutDir)) {
        Start-Process explorer.exe $script:State.OutDir
    }
})

# --- 轮询后台结果 ---
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
    try {
        $line  = $null
        $drain = 0
        while ($drain -lt 300 -and $script:LogQueue.TryDequeue([ref]$line)) {
            $txtLog.AppendText($line + "`r`n")
            $drain++
        }

        if ($script:State.Done -and $script:Runner) {
            try {
                if ($script:Handle) { [void]$script:Runner.EndInvoke($script:Handle) }
            } catch { }
            try { $script:Runner.Dispose() } catch { }
            if ($script:Runspace) {
                try { $script:Runspace.Close() }   catch { }
                try { $script:Runspace.Dispose() } catch { }
            }
            $script:Runner   = $null
            $script:Handle   = $null
            $script:Runspace = $null

            Set-Busy $false
            if ($script:State.Ok) {
                $btnInstall.Enabled  = $true
                $btnOpen.Enabled     = $true
                $lblStatus.Text      = ("完成 - 查询键 {0}" -f $script:State.Key)
                $lblStatus.ForeColor = [System.Drawing.Color]::Green
            } else {
                $lblStatus.Text      = '未成功，请查看日志'
                $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
            }
        }
    } catch {
        $txtLog.AppendText("[UI] 内部错误：" + $_.Exception.Message + "`r`n")
    }
})
$timer.Start()

$form.Add_Shown({
    Add-Log '提示：型号和序列号都可以点「自动检测」直接填入。'
    Add-Log '      若失败，可尝试只填型号前 4 位（如 21J7）。'
    Add-Log ''
})

$form.Add_FormClosing({
    $timer.Stop()
    if ($script:Runner) {
        try { $script:Runner.Stop() } catch { }
        try { $script:Runner.Dispose() } catch { }
    }
    if ($script:Runspace) {
        try { $script:Runspace.Close() } catch { }
        try { $script:Runspace.Dispose() } catch { }
    }
})

[void]$form.ShowDialog()
