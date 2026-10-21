# MC 服务器一键配置
# 流程：
#   1. 直接使用根目录的 Plain Craft Launcher 2.exe，不下载 PCL。
#   2. 把整合包复制为 PCL 同级目录的 modpack.zip，启动 PCL 并自动安装
#      （PCL 启动时会自动检测 modpack.zip，安装成功后自行删除；整合包已自带 1.20.1 全部文件）。
#   3. 默认选中整合包版本，并把服务器写入 servers.dat（游戏内「多人游戏」列表）。
#   4. 自动填好离线昵称，再用键盘回车启动 PCL 进入游戏。
#
# 说明：PCL 没有命令行安装接口，但它自带「modpack.zip 自动安装」入口，
#       见 PCL 源码 PageLaunch/PageLaunchLeft.xaml.vb，等价于把压缩包拖入窗口。

$ErrorActionPreference = 'Stop'
# 脚本放在 scripts 子目录，根目录以 PCL 所在位置为准
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root        = $ScriptDir
if (-not (Test-Path -LiteralPath (Join-Path $Root 'Plain Craft Launcher 2.exe'))) {
    $Parent = Split-Path -Parent $Root
    if (Test-Path -LiteralPath (Join-Path $Parent 'Plain Craft Launcher 2.exe')) { $Root = $Parent }
}
$PclExe      = Join-Path $Root 'Plain Craft Launcher 2.exe'
$McDir       = Join-Path $Root '.minecraft'
$Version     = '1.20.1'

# 整合包与服务器配置
$InstanceName   = '香草纪元：食旅纪行'
$ServerAddress  = ''
$ServerName     = '香草纪元服务器'
$PlayerName     = 'MCPlayer'
$PackRoot       = Join-Path $Root 'config'
$ModpackDst     = Join-Path $Root 'modpack.zip'
$ServerJsonPath = Join-Path $Root 'server.json'
# server.json 与整合包放在同一个文件夹里
if (-not (Test-Path -LiteralPath $ServerJsonPath)) {
    $FoundJson = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'server.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($FoundJson) { $ServerJsonPath = $FoundJson.FullName }
}

function Write-Info { param($Message) Write-Host "[MC] $Message" -ForegroundColor Cyan }
function Write-Warn { param($Message) Write-Host "[提示] $Message" -ForegroundColor Yellow }
function Write-Err  { param($Message) Write-Host "[错误] $Message" -ForegroundColor Red }

function Write-Step {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Green
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    try { $Host.UI.RawUI.WindowTitle = "MC 服务器一键配置 - $Title" } catch { }
}

function Get-PclProcess {
    Get-Process -Name 'Plain Craft Launcher 2' -ErrorAction SilentlyContinue
}

function Close-Pcl {
    $Running = @(Get-PclProcess)
    if ($Running.Count -eq 0) { return }
    foreach ($Proc in $Running) {
        $Proc.CloseMainWindow() | Out-Null
    }
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not @(Get-PclProcess).Count) { return }
    }
    foreach ($Proc in @(Get-PclProcess)) {
        $Proc.Kill()
        $Proc.WaitForExit(3000) | Out-Null
    }
}

# 通过键盘向 PCL 发送回车（PCL 主界面的启动按钮默认获得焦点，回车即启动游戏）
$Win32Source = @'
using System;
using System.Runtime.InteropServices;
public class PclKeys {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public int type; public KEYBDINPUT ki; public int pad1; public int pad2; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public int dwFlags; public int time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    public static void Enter() {
        INPUT[] a = new INPUT[2];
        a[0].type = 1; a[0].ki.wVk = 0x0D;
        a[1].type = 1; a[1].ki.wVk = 0x0D; a[1].ki.dwFlags = 2;
        SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
try { Add-Type -TypeDefinition $Win32Source -ErrorAction Stop } catch { }

$PclLogPath = Join-Path $Root 'PCL\Log1.txt'
function Read-PclLogAppend {
    param([ref]$Offset)
    if (-not (Test-Path -LiteralPath $PclLogPath)) { return '' }
    $Text = ''
    try {
        $Fs = [IO.File]::Open($PclLogPath, 'Open', 'Read', 'ReadWrite')
        # PCL 启动时会轮转日志（Log1 变 Log2，新建 Log1），长度变小时从 0 重新读
        if ($Offset.Value -gt $Fs.Length) { $Offset.Value = [long]0 }
        if ($Fs.Length -gt $Offset.Value) {
            $Fs.Position = $Offset.Value
            $Reader = New-Object IO.StreamReader($Fs)
            $Text = $Reader.ReadToEnd()
            $Offset.Value = $Fs.Position
            $Reader.Close()
        }
        $Fs.Close()
    }
    catch { }
    return $Text
}

# 把服务器写入 servers.dat（未压缩 NBT），即游戏内「多人游戏」列表
# 返回 created / added / updated / exists / rebuilt
# 说明：必须完整解析已有列表，否则同名地址无法更新显示名称
$NbtSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class ServersNbt {
    const byte TEnd = 0, TByte = 1, TShort = 2, TInt = 3, TLong = 4, TFloat = 5,
               TDouble = 6, TByteArray = 7, TString = 8, TList = 9, TCompound = 10,
               TIntArray = 11, TLongArray = 12;

    // NBT 全部是大端序，BinaryReader/Writer 默认小端，必须手工转换
    static int BE16(BinaryReader r) { byte[] b = r.ReadBytes(2); return (b[0] << 8) | b[1]; }
    static int BE32(BinaryReader r) { byte[] b = r.ReadBytes(4); return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]; }
    static void W16(BinaryWriter w, int v) { w.Write((byte)(v >> 8)); w.Write((byte)v); }
    static void W32(BinaryWriter w, int v) { w.Write((byte)(v >> 24)); w.Write((byte)(v >> 16)); w.Write((byte)(v >> 8)); w.Write((byte)v); }

    static void Skip(BinaryReader r, byte t) {
        switch (t) {
            case TEnd: break;
            case TByte: r.ReadByte(); break;
            case TShort: BE16(r); break;
            case TInt: BE32(r); break;
            case TLong: r.ReadBytes(8); break;
            case TFloat: r.ReadSingle(); break;
            case TDouble: r.ReadDouble(); break;
            case TByteArray: { int n = BE32(r); r.ReadBytes(n); break; }
            case TString: { int n = BE16(r); r.ReadBytes(n); break; }
            case TList: {
                byte et = r.ReadByte();
                int n = BE32(r);
                for (int i = 0; i < n; i++) Skip(r, et);
                break;
            }
            case TCompound: {
                while (true) {
                    byte ct = r.ReadByte();
                    if (ct == TEnd) break;
                    int nameLen = BE16(r);
                    r.ReadBytes(nameLen);
                    Skip(r, ct);
                }
                break;
            }
            case TIntArray: { int n = BE32(r); r.ReadBytes(n * 4); break; }
            case TLongArray: { int n = BE32(r); r.ReadBytes(n * 8); break; }
            default: throw new Exception("未知 NBT 标签类型：" + t);
        }
    }

    static string ReadStr(BinaryReader r) {
        int n = BE16(r);
        return Encoding.UTF8.GetString(r.ReadBytes(n));
    }

    // 在 [start,end) 的 Compound 里读取指定字符串字段
    static string Field(MemoryStream ms, int start, int end, string key) {
        ms.Position = start;
        BinaryReader r = new BinaryReader(ms);
        string found = null;
        while (ms.Position < end) {
            byte t = r.ReadByte();
            if (t == TEnd) break;
            string name = ReadStr(r);
            if (t == TString && name == key) found = ReadStr(r);
            else Skip(r, t);
        }
        return found;
    }

    static byte[] Encode(string name, string ip) {
        MemoryStream ms = new MemoryStream();
        BinaryWriter w = new BinaryWriter(ms);
        w.Write(TByte); W16(w, 6); w.Write(Encoding.UTF8.GetBytes("hidden")); w.Write((byte)0);
        w.Write(TString); W16(w, 2); w.Write(Encoding.UTF8.GetBytes("ip"));
        byte[] b = Encoding.UTF8.GetBytes(ip); W16(w, b.Length); w.Write(b);
        w.Write(TString); W16(w, 4); w.Write(Encoding.UTF8.GetBytes("name"));
        b = Encoding.UTF8.GetBytes(name); W16(w, b.Length); w.Write(b);
        w.Write(TByte); W16(w, 14); w.Write(Encoding.UTF8.GetBytes("acceptTextures")); w.Write((byte)1);
        w.Write(TEnd);
        w.Flush();
        byte[] data = ms.ToArray();
        w.Close(); ms.Close();
        return data;
    }

    static void Save(string path, List<byte[]> entries) {
        MemoryStream ms = new MemoryStream();
        BinaryWriter w = new BinaryWriter(ms);
        w.Write(TCompound); W16(w, 0);
        w.Write(TList); W16(w, 7); w.Write(Encoding.UTF8.GetBytes("servers"));
        w.Write(TCompound); W32(w, entries.Count);
        foreach (byte[] e in entries) w.Write(e);
        w.Write(TEnd);
        w.Flush();
        File.WriteAllBytes(path, ms.ToArray());
        w.Close(); ms.Close();
    }

    public static string Upsert(string path, string name, string ip) {
        byte[] entry = Encode(name, ip);
        if (!File.Exists(path)) {
            Save(path, new List<byte[]> { entry });
            return "created";
        }
        byte[] raw = File.ReadAllBytes(path);
        List<byte[]> entries = new List<byte[]>();
        int match = -1;
        bool sameName = false;
        try {
            MemoryStream ms = new MemoryStream(raw);
            BinaryReader r = new BinaryReader(ms);
            byte root = r.ReadByte();
            BE16(r);
            if (root != TCompound) throw new Exception("根标签不是 Compound");
            while (true) {
                byte t = r.ReadByte();
                if (t == TEnd) break;
                string tag = ReadStr(r);
                if (t == TList && tag == "servers") {
                    byte et = r.ReadByte();
                    int n = BE32(r);
                    if (et != TCompound) throw new Exception("servers 列表元素不是 Compound");
                    List<int> starts = new List<int>();
                    for (int i = 0; i < n; i++) { starts.Add((int)ms.Position); Skip(r, TCompound); }
                    int after = (int)ms.Position;
                    for (int i = 0; i < n; i++) {
                        int s = starts[i];
                        int e = (i + 1 < n) ? starts[i + 1] : after;
                        byte[] body = new byte[e - s];
                        Array.Copy(raw, s, body, 0, body.Length);
                        string eip = Field(ms, s, e, "ip");
                        if (eip != null && eip.Trim() == ip.Trim()) {
                            if (match < 0) {
                                match = entries.Count;
                                string ename = Field(ms, s, e, "name");
                                sameName = ename != null && ename.Trim() == name.Trim();
                            }
                        }
                        entries.Add(body);
                    }
                    break;
                }
                Skip(r, t);
            }
        }
        catch {
            Save(path, new List<byte[]> { entry });
            return "rebuilt";
        }
        if (match >= 0) {
            if (sameName) return "exists";
            entries[match] = entry;
            Save(path, entries);
            return "updated";
        }
        entries.Add(entry);
        Save(path, entries);
        return "added";
    }
}
'@
try { Add-Type -TypeDefinition $NbtSource -ErrorAction Stop } catch { Write-Warn "servers.dat 写入组件加载失败：$($_.Exception.Message)" }

function Write-ServersDat {
    param([string]$Path, [string]$Name, [string]$Ip)
    $ParentDir = Split-Path -Parent $Path
    if ($ParentDir -and -not (Test-Path -LiteralPath $ParentDir)) {
        New-Item -ItemType Directory -Path $ParentDir -Force | Out-Null
    }
    return [ServersNbt]::Upsert($Path, $Name, $Ip)
}

# 首次运行时 PCL 没有玩家名导致无法启动，通过 UI Automation 填入离线玩家名
function Set-PclPlayerName {
    param([int]$PclPid, [string]$Name)
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    }
    catch { return $false }
    $RootEl = [System.Windows.Automation.AutomationElement]::RootElement
    $Cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $PclPid)
    $Win = $RootEl.FindFirst([System.Windows.Automation.TreeScope]::Children, $Cond)
    if (-not $Win) { return $false }
    $EditCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'PART_EditableTextBox')
    $Edit = $Win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $EditCond)
    if (-not $Edit) { return $false }
    $Pattern = $null
    if (-not $Edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$Pattern)) { return $false }
    $Pattern.SetValue($Name)
    return $true
}

if (-not (Test-Path -LiteralPath $PclExe)) {
    Write-Err '未找到 Plain Craft Launcher 2.exe，请把它放在脚本同目录。'
    exit 1
}

# 读取 server.json
if (Test-Path -LiteralPath $ServerJsonPath) {
    try {
        $ServerConfig = Get-Content -Raw -Encoding UTF8 -LiteralPath $ServerJsonPath | ConvertFrom-Json
        if ($ServerConfig.minecraft.instanceName) { $InstanceName = [string]$ServerConfig.minecraft.instanceName }
        if ($ServerConfig.minecraft.serverName) { $ServerName = [string]$ServerConfig.minecraft.serverName }
        if ($ServerConfig.minecraft.playerName) { $PlayerName = [string]$ServerConfig.minecraft.playerName }
        if ($ServerConfig.minecraft.serverAddress) { $ServerAddress = [string]$ServerConfig.minecraft.serverAddress }
        elseif ($ServerConfig.minecraft.serverHost) {
            $ServerAddress = '{0}:{1}' -f $ServerConfig.minecraft.serverHost, $ServerConfig.minecraft.serverPort
        }
    }
    catch {
        Write-Warn "server.json 解析失败，使用默认值：$($_.Exception.Message)"
    }
}
else {
    Write-Warn '未找到 server.json，将跳过自动进服配置。'
}

# ---------------------------------------------------------------- 1. 整合包安装
Write-Step '步骤 1/3：安装整合包（PCL 自动安装）'
$InstanceDir  = Join-Path $McDir "versions\$InstanceName"
$InstanceJson = Join-Path $InstanceDir "$InstanceName.json"

function Find-ModpackZip {
    if (-not (Test-Path -LiteralPath $PackRoot)) { return $null }
    $All = @(Get-ChildItem -LiteralPath $PackRoot -Recurse -File -Filter '*.zip' -ErrorAction SilentlyContinue)
    $WithMcef = $All | Where-Object { $_.Name -like '*MCEF*' } | Select-Object -First 1
    if ($WithMcef) { return $WithMcef }
    return ($All | Select-Object -First 1)
}

if (Test-Path -LiteralPath $InstanceJson) {
    Write-Info "整合包已安装，跳过：$InstanceDir"
}
else {
    $Zip = Find-ModpackZip
    if (-not $Zip) {
        Write-Err "未找到整合包 zip，请确认目录存在：$PackRoot"
        exit 1
    }

    Write-Info "正在准备整合包：$($Zip.Name)"
    if (@(Get-PclProcess).Count -gt 0) {
        Write-Info '关闭正在运行的 PCL（整合包只在 PCL 启动时自动安装）...'
        Close-Pcl
    }

    # PCL 安装前会校验 versions 下是否已存在同名文件夹，若存在且无版本 JSON，
    # 会弹出「输入版本名称」对话框等待人工输入，从而卡住自动安装，因此先清理残留。
    if ((Test-Path -LiteralPath $InstanceDir) -and -not (Test-Path -LiteralPath $InstanceJson)) {
        Write-Info "清理上次残留的版本目录：$InstanceDir"
        Remove-Item -LiteralPath $InstanceDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ((Test-Path -LiteralPath $ModpackDst) -and ((Get-Item -LiteralPath $ModpackDst).Length -ne $Zip.Length)) {
        Remove-Item -LiteralPath $ModpackDst -Force
    }
    if (-not (Test-Path -LiteralPath $ModpackDst)) {
        Copy-Item -LiteralPath $Zip.FullName -Destination $ModpackDst
    }
    Write-Info "已生成 $ModpackDst（$([math]::Round($Zip.Length / 1MB, 1)) MB）"

    Write-Info '正在启动 PCL，PCL 将自动安装整合包（会自动下载 Forge 与全部模组，请勿关闭窗口）...'
    Start-Process -FilePath $PclExe -WorkingDirectory $Root | Out-Null

    $Deadline = (Get-Date).AddMinutes(90)
    $Installed = $false
    # 记录日志当前位置，用于识别 PCL 是否弹出了需要人工输入的对话框
    $LogOffset = if (Test-Path -LiteralPath $PclLogPath) { [long](Get-Item -LiteralPath $PclLogPath).Length } else { [long]0 }
    $DialogWarned = $false
    while ((Get-Date) -lt $Deadline) {
        Start-Sleep -Seconds 5
        # 版本 JSON 在安装刚开始时就会生成，不能作为完成标志；
        # PCL 只在安装成功后才删除 modpack.zip，并记录「自动安装整合包成功」
        $NewLog = Read-PclLogAppend ([ref]$LogOffset)
        if ($NewLog -match '自动安装整合包成功' -or -not (Test-Path -LiteralPath $ModpackDst)) {
            $Installed = $true
            break
        }
        if (-not $DialogWarned -and $NewLog -match '输入弹窗：输入版本名称') {
            $DialogWarned = $true
            Write-Warn 'PCL 正在等待「输入版本名称」：请在 PCL 窗口里输入任意名称并点确定，安装会继续。'
        }
        if (-not @(Get-PclProcess).Count) {
            throw 'PCL 已退出，整合包安装未完成。请重新运行本脚本（已下载的文件会保留）。'
        }

        $FileCount = 0
        $TotalMb = 0
        if (Test-Path -LiteralPath $InstanceDir) {
            $Files = @(Get-ChildItem -LiteralPath $InstanceDir -Recurse -File -ErrorAction SilentlyContinue)
            $FileCount = $Files.Count
            if ($FileCount -gt 0) { $TotalMb = [math]::Round((($Files | Measure-Object -Property Length -Sum).Sum / 1MB), 1) }
        }
        Write-Info "安装进度：已写入 $FileCount 个文件（$TotalMb MB），modpack.zip 仍在处理中..."
    }

    if (-not $Installed) {
        throw '整合包安装超时（90 分钟）。请检查网络后重新运行本脚本，已下载的文件会保留。'
    }

    # PCL 安装成功后会删除 modpack.zip；若版本名与预期不同则自动识别
    if (-not (Test-Path -LiteralPath $InstanceJson)) {
        $Found = @(Get-ChildItem (Join-Path $McDir 'versions') -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -notin @($Version) -and (Test-Path -LiteralPath (Join-Path $_.FullName ($_.Name + '.json'))) } |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if ($Found.Count -gt 0) {
            $InstanceName = $Found[0].Name
            $InstanceDir  = $Found[0].FullName
            $InstanceJson = Join-Path $InstanceDir "$InstanceName.json"
        }
    }

    Write-Info "整合包安装完成：$InstanceDir"
}

# ---------------------------------------------------------------- 2. 保存服务器
Write-Step '步骤 2/3：保存服务器到「多人游戏」列表'

# PCL 运行时会缓存版本设置，必须先关闭再写文件，否则本次启动不会生效
if (@(Get-PclProcess).Count -gt 0) {
    Write-Info '关闭 PCL 以写入配置...'
    Close-Pcl
}

$GlobalIni = Join-Path $McDir 'PCL.ini'
$Existing = if (Test-Path -LiteralPath $GlobalIni) { Get-Content -Encoding UTF8 -LiteralPath $GlobalIni } else { @() }
$Lines = @($Existing | Where-Object { $_ -notmatch '^\s*Version\s*[:=]' })
$Lines += "Version:$InstanceName"
[IO.File]::WriteAllLines($GlobalIni, $Lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Info "已默认选中版本：$InstanceName"

# 移除旧版写入的自动进服参数，改为只在「多人游戏」列表里保存服务器
$SetupIni = Join-Path $InstanceDir 'PCL\Setup.ini'
if (Test-Path -LiteralPath $SetupIni) {
    $Existing = Get-Content -Encoding UTF8 -LiteralPath $SetupIni
    $Lines = @($Existing | Where-Object { $_ -notmatch '^\s*VersionServerEnter\s*[:=]' })
    [IO.File]::WriteAllLines($SetupIni, $Lines, (New-Object System.Text.UTF8Encoding($false)))
}

if ($ServerAddress) {
    # 整合包默认开启版本隔离，游戏目录是 versions\<实例名>；根目录也写一份以防隔离被关闭
    $DatPaths = @((Join-Path $InstanceDir 'servers.dat'), (Join-Path $McDir 'servers.dat'))
    foreach ($Dat in $DatPaths) {
        switch (Write-ServersDat -Path $Dat -Name $ServerName -Ip $ServerAddress) {
            'created' { Write-Info "已保存服务器：$ServerName → $ServerAddress" }
            'added'   { Write-Info "已追加服务器：$ServerName → $ServerAddress" }
            'updated' { Write-Info "已更新服务器名称：$ServerName → $ServerAddress" }
            'rebuilt' { Write-Warn "servers.dat 原文件无法解析，已重建：$ServerName → $ServerAddress" }
            'exists'  { Write-Info "服务器已存在，跳过：$ServerName（$ServerAddress）" }
        }
    }
}
else {
    Write-Warn '未配置服务器地址，跳过保存服务器。'
}

# ---------------------------------------------------------------- 3. 启动游戏
Write-Step '步骤 3/3：启动游戏'

# 重启后 PCL 才会读到刚写入的版本设置
$LogOffset = if (Test-Path -LiteralPath $PclLogPath) { [long](Get-Item -LiteralPath $PclLogPath).Length } else { [long]0 }
Write-Info '正在启动 PCL...'
Start-Process -FilePath $PclExe -WorkingDirectory $Root | Out-Null

$Hwnd = [IntPtr]::Zero
$Ready = $false
$Deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $Deadline) {
    Start-Sleep -Milliseconds 800
    $Proc = Get-PclProcess | Select-Object -First 1
    if ($Proc -and $Proc.MainWindowHandle -ne [IntPtr]::Zero) { $Hwnd = $Proc.MainWindowHandle }
    $NewLog = Read-PclLogAppend ([ref]$LogOffset)
    if ($NewLog -match '启动按钮：无 Minecraft 版本') {
        throw 'PCL 未识别到可用的 Minecraft 版本，请在 PCL 中确认版本列表。'
    }
    if ($Hwnd -ne [IntPtr]::Zero -and $NewLog -match '启动按钮：') {
        $Ready = $true
        break
    }
}
if (-not $Ready) {
    throw 'PCL 启动页加载超时，请在 PCL 窗口中手动点击「启动游戏」。'
}

Write-Info '正在向 PCL 发送回车键，尝试启动游戏...'
[PclKeys]::ShowWindow($Hwnd, 9) | Out-Null
[PclKeys]::SetForegroundWindow($Hwnd) | Out-Null
Start-Sleep -Milliseconds 1200

# 全新环境里 PCL 没有玩家名，点启动会被「玩家名不能为空！」拦截，先自动填好昵称
$HasName = $false
try {
    $Saved = [string](Get-ItemProperty -Path 'HKCU:\Software\PCL' -Name 'LoginLegacyName' -ErrorAction Stop).LoginLegacyName
    $HasName = -not [string]::IsNullOrWhiteSpace($Saved)
}
catch { $HasName = $false }
if (-not $HasName -and $PlayerName) {
    $Proc = Get-PclProcess | Select-Object -First 1
    for ($i = 0; $i -lt 8; $i++) {
        if (Set-PclPlayerName -PclPid $Proc.Id -Name $PlayerName) {
            Write-Info "已自动设置游戏昵称：$PlayerName"
            break
        }
        Start-Sleep -Milliseconds 700
    }
    Start-Sleep -Milliseconds 400
}

[PclKeys]::Enter()

# 等待游戏启动
$Started = $false
$LaunchLog = ''
$Deadline = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt $Deadline) {
    Start-Sleep -Seconds 2
    $NewLog = Read-PclLogAppend ([ref]$LogOffset)
    if ($NewLog) { $LaunchLog += $NewLog }
    if ($LaunchLog -match '启动成功') { $Started = $true; break }
    if ($LaunchLog -match '启动失败|发生错误') { break }
}

if ($Started) {
    if ($ServerAddress) {
        Write-Info "游戏已启动，服务器已保存在「多人游戏」列表：$ServerName（$ServerAddress）"
    }
    else {
        Write-Info '游戏已启动。'
    }
}
else {
    Write-Warn '未检测到游戏启动成功，请在 PCL 窗口中手动点击「启动游戏」。'
}

Write-Info '全部步骤结束，本窗口可以关闭。'
