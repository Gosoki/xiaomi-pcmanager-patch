<#
.SYNOPSIS
    解除小米电脑管家 6.0 控制中心的机型白名单（字幕转录、AI 降噪等）。

.DESCRIPTION
    6.0 控制中心用 DeviceModelConfig.Is*Supported(model) 判断机型是否支持某功能，
    非小米机型一律返回 false。本脚本把这些方法的 IL 改为恒返回 true。
    原版备份为同目录 XiaomiPCManager.dll.bak，可随时还原。

.EXAMPLE
    .\unlock.ps1                  # 打补丁（默认）
    .\unlock.ps1 -Action Status   # 查看状态
    .\unlock.ps1 -Action Restore  # 还原原版
#>
param(
    [ValidateSet('Patch', 'Restore', 'Status')]
    [string]$Action = 'Patch',
    # 直接指定 XiaomiPCManager.dll，默认从注册表自动探测
    [string]$Path,
    # 内部使用：标记为提权后重新启动的实例
    [switch]$Relaunched
)

$ErrorActionPreference = 'Stop'
$TypeName = 'DeviceModelConfig'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;

public class XmMethod {
    public string Name;
    public int CodeOffset;
    public int CodeSize;
    public bool Patched;
    public string Skip;
}

// 最小化 ECMA-335 元数据解析：只读到 MethodDef 表为止
public static class XmDll {
    static byte[] d;
    static int[] secVa, secSize, secRaw;
    static int strHeap, blobHeap;

    static int U16(int o) { return d[o] | (d[o + 1] << 8); }
    static int I32(int o) { return BitConverter.ToInt32(d, o); }

    static int Rva2Off(int rva) {
        for (int i = 0; i < secVa.Length; i++)
            if (rva >= secVa[i] && rva < secVa[i] + secSize[i]) return rva - secVa[i] + secRaw[i];
        throw new Exception("RVA 0x" + rva.ToString("X") + " not in any section");
    }

    static string Str(int idx) {
        int s = strHeap + idx, e = s;
        while (d[e] != 0) e++;
        return Encoding.UTF8.GetString(d, s, e - s);
    }

    static byte[] Blob(int idx) {
        int o = blobHeap + idx, len, b = d[o];
        if ((b & 0x80) == 0) { len = b; o += 1; }
        else if ((b & 0xC0) == 0x80) { len = ((b & 0x3F) << 8) | d[o + 1]; o += 2; }
        else { len = ((b & 0x1F) << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3]; o += 4; }
        byte[] r = new byte[len];
        Array.Copy(d, o, r, 0, len);
        return r;
    }

    public static byte[] PatchedCode(int size) {
        byte[] c = new byte[size];          // nop * (size-2)
        c[size - 2] = 0x17;                 // ldc.i4.1
        c[size - 1] = 0x2A;                 // ret（必须在最后，否则 JIT 报 InvalidProgramException）
        return c;
    }

    public static List<XmMethod> Scan(byte[] data, string typeName) {
        d = data;
        int pe = I32(0x3C);
        int nSec = U16(pe + 6), optSize = U16(pe + 20), opt = pe + 24;
        int dirs = opt + (U16(opt) == 0x20B ? 112 : 96);
        secVa = new int[nSec]; secSize = new int[nSec]; secRaw = new int[nSec];
        for (int i = 0; i < nSec; i++) {
            int s = opt + optSize + i * 40;
            secSize[i] = Math.Max(I32(s + 8), I32(s + 16)); secVa[i] = I32(s + 12); secRaw[i] = I32(s + 20);
        }
        int cliRva = I32(dirs + 14 * 8);
        if (cliRva == 0) throw new Exception("not a .NET assembly");
        int cli = Rva2Off(cliRva);
        if ((I32(cli + 16) & 1) == 0) throw new Exception("not IL-only");
        if (I32(cli + 64) != 0) throw new Exception("ReadyToRun image, IL patch would not take effect");
        int md = Rva2Off(I32(cli + 8));
        int p = md + 16 + I32(md + 12) + 2;
        int nStreams = U16(p); p += 2;
        int tbl = -1;
        for (int i = 0; i < nStreams; i++) {
            int off = I32(p), e = p + 8;
            while (d[e] != 0) e++;
            string name = Encoding.ASCII.GetString(d, p + 8, e - p - 8);
            if (name == "#~") tbl = md + off;
            else if (name == "#Strings") strHeap = md + off;
            else if (name == "#Blob") blobHeap = md + off;
            else if (name == "#-") throw new Exception("uncompressed metadata not supported");
            p = (e + 4) & ~3;
        }
        int heap = d[tbl + 6];
        long valid = BitConverter.ToInt64(d, tbl + 8);
        int[] rows = new int[64];
        p = tbl + 24;
        for (int i = 0; i < 64; i++) if (((valid >> i) & 1) != 0) { rows[i] = I32(p); p += 4; }
        if ((heap & 0x40) != 0) p += 4;
        if (rows[3] != 0 || rows[5] != 0) throw new Exception("FieldPtr/MethodPtr tables not supported");

        int sStr = (heap & 1) != 0 ? 4 : 2, sGuid = (heap & 2) != 0 ? 4 : 2, sBlob = (heap & 4) != 0 ? 4 : 2;
        Func<int, int> simple = t => rows[t] > 0xFFFF ? 4 : 2;
        Func<int[], int, int> coded = (ts, bits) => {
            int max = 0; foreach (int t in ts) max = Math.Max(max, rows[t]);
            return max < (1 << (16 - bits)) ? 2 : 4;
        };
        int sTdor = coded(new[] { 0x02, 0x01, 0x1B }, 2);
        int[] size = new int[7];
        size[0] = 2 + sStr + sGuid * 3;                                       // Module
        size[1] = coded(new[] { 0x00, 0x1A, 0x23, 0x01 }, 2) + sStr * 2;       // TypeRef
        size[2] = 4 + sStr * 2 + sTdor + simple(4) + simple(6);               // TypeDef
        size[4] = 2 + sStr + sBlob;                                           // Field
        size[6] = 8 + sStr + sBlob + simple(8);                               // MethodDef
        int typeDefStart = p + rows[0] * size[0] + rows[1] * size[1];
        int methodDefStart = typeDefStart + rows[2] * size[2] + rows[4] * size[4];
        Func<int, int, int> idx = (o, n) => n == 2 ? U16(o) : I32(o);

        int mFirst = -1, mEnd = -1;
        for (int i = 0; i < rows[2]; i++) {
            int r = typeDefStart + i * size[2];
            if (Str(idx(r + 4, sStr)) != typeName) continue;
            if (mFirst != -1) throw new Exception("multiple types named " + typeName);
            int mlOff = 4 + sStr * 2 + sTdor + simple(4);
            mFirst = idx(r + mlOff, simple(6));
            mEnd = i + 1 < rows[2] ? idx(r + size[2] + mlOff, simple(6)) : rows[6] + 1;
        }
        if (mFirst == -1) throw new Exception("type " + typeName + " not found");

        List<XmMethod> list = new List<XmMethod>();
        for (int m = mFirst; m < mEnd; m++) {
            int r = methodDefStart + (m - 1) * size[6];
            string name = Str(idx(r + 8, sStr));
            if (!name.StartsWith("Is") || !name.EndsWith("Supported")) continue;
            XmMethod x = new XmMethod();
            x.Name = name;
            list.Add(x);
            byte[] sig = Blob(idx(r + 8 + sStr, sBlob));
            // static bool X(string)
            if ((U16(r + 6) & 0x10) == 0 || sig.Length != 4 || sig[0] != 0 || sig[1] != 1 || sig[2] != 0x02 || sig[3] != 0x0E) {
                x.Skip = "signature is not static bool(string)"; continue;
            }
            int body = Rva2Off(I32(r));
            int h = d[body];
            if ((h & 3) == 2) { x.CodeSize = h >> 2; x.CodeOffset = body + 1; }
            else if ((h & 3) == 3) {
                int flags = U16(body);
                if ((flags & 0x8) != 0) { x.Skip = "method has exception handlers"; continue; }
                x.CodeSize = I32(body + 4); x.CodeOffset = body + ((flags >> 12) & 0xF) * 4;
            } else { x.Skip = "unknown method header"; continue; }
            if (x.CodeSize < 2 || d[x.CodeOffset + x.CodeSize - 1] != 0x2A) { x.Skip = "unexpected method body"; continue; }
            byte[] pc = PatchedCode(x.CodeSize);
            x.Patched = true;
            for (int k = 0; k < pc.Length; k++) if (d[x.CodeOffset + k] != pc[k]) { x.Patched = false; break; }
        }
        return list;
    }
}
'@

function Resolve-Dll {
    if ($Path) { return (Resolve-Path -LiteralPath $Path).Path }
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\XiaomiPCManager'
    $uninst = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).UninstallString
    if ($uninst) {
        $dll = Join-Path (Split-Path $uninst.Trim('"')) 'XiaomiPCManager.dll'
        if (Test-Path -LiteralPath $dll) { return $dll }
    }
    $root = Join-Path $env:ProgramFiles 'MI\XiaomiPCManager'
    $found = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'XiaomiPCManager.dll') } |
        Sort-Object { [version]$_.Name } -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($found) { return Join-Path $found.FullName 'XiaomiPCManager.dll' }
    throw '找不到小米电脑管家安装目录，请用 -Path 指定 XiaomiPCManager.dll'
}

function Test-Writable([string]$dir) {
    $probe = Join-Path $dir ".unlock-probe-$PID"
    try { [IO.File]::WriteAllText($probe, ''); Remove-Item -LiteralPath $probe; return $true } catch { return $false }
}

function Show-Status([string]$dll) {
    Write-Host "目标: $dll"
    Write-Host "版本: $(Split-Path (Split-Path $dll) -Leaf)"
    $methods = [XmDll]::Scan([IO.File]::ReadAllBytes($dll), $TypeName)
    foreach ($m in $methods) {
        $state = if ($m.Skip) { "跳过（$($m.Skip)）" } elseif ($m.Patched) { '已解锁' } else { '原版' }
        Write-Host ('  {0,-40} {1}' -f $m.Name, $state)
    }
    Write-Host "备份: $(if (Test-Path -LiteralPath "$dll.bak") { "$dll.bak" } else { '无' })"
    return $methods
}

# 关掉正在使用该 DLL 的管家主程序，返回是否需要事后重启
function Stop-Manager([string]$dll) {
    $exe = Join-Path (Split-Path $dll) 'XiaomiPCManager.exe'
    $procs = @(Get-Process XiaomiPCManager -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
    if ($procs) {
        Write-Host '关闭小米电脑管家...'
        $procs | Stop-Process -Force
        $procs | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    }
    return [bool]$procs
}

function Start-Manager([string]$dll) {
    # 经 explorer 启动，避免管家继承管理员权限
    Start-Process explorer.exe -ArgumentList "`"$(Join-Path (Split-Path $dll) 'XiaomiPCManager.exe')`""
    Write-Host '已重新启动小米电脑管家'
}

# 进程退出后文件句柄释放有延迟，重试写入
function Write-WithRetry([string]$dll, [byte[]]$bytes) {
    for ($i = 1; ; $i++) {
        try { [IO.File]::WriteAllBytes($dll, $bytes); return }
        catch { if ($i -ge 15) { throw }; Start-Sleep -Seconds 1 }
    }
}

$dll = Resolve-Dll

if ($Action -ne 'Status' -and -not (Test-Writable (Split-Path $dll))) {
    Write-Host '需要管理员权限，正在请求提权...'
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
        '-Action', $Action, '-Path', "`"$dll`"", '-Relaunched')
    return
}

try {
    $methods = Show-Status $dll
    switch ($Action) {
        'Patch' {
            $todo = @($methods | Where-Object { -not $_.Skip -and -not $_.Patched })
            if (-not $todo) { Write-Host '无需修改。'; break }
            $bak = "$dll.bak"
            if (-not (Test-Path -LiteralPath $bak)) {
                if ($methods | Where-Object Patched) {
                    Write-Warning '当前文件已被部分修改且无备份，将不创建备份（还原需重装管家）'
                } else {
                    Copy-Item -LiteralPath $dll -Destination $bak
                    Write-Host "已备份原版到 $bak"
                }
            }
            $bytes = [IO.File]::ReadAllBytes($dll)
            foreach ($m in $todo) {
                [Array]::Copy([XmDll]::PatchedCode($m.CodeSize), 0, $bytes, $m.CodeOffset, $m.CodeSize)
            }
            $restart = Stop-Manager $dll
            Write-WithRetry $dll $bytes
            $left = @([XmDll]::Scan([IO.File]::ReadAllBytes($dll), $TypeName) | Where-Object { -not $_.Skip -and -not $_.Patched })
            if ($left) { throw "校验失败：$($left.Name -join ', ') 未生效" }
            Write-Host "已解锁 $($todo.Count) 项：$($todo.Name -join ', ')" -ForegroundColor Green
            if ($restart) { Start-Manager $dll }
        }
        'Restore' {
            $bak = "$dll.bak"
            if (-not (Test-Path -LiteralPath $bak)) { throw '没有找到备份，重新安装小米电脑管家即可恢复原版' }
            $restart = Stop-Manager $dll
            Write-WithRetry $dll ([IO.File]::ReadAllBytes($bak))
            Remove-Item -LiteralPath $bak
            Write-Host '已还原原版并删除备份' -ForegroundColor Green
            if ($restart) { Start-Manager $dll }
        }
    }
} catch {
    Write-Host "失败: $($_.Exception.Message)" -ForegroundColor Red
    if (-not $Relaunched) { exit 1 }
} finally {
    if ($Relaunched) { Read-Host '按回车键退出' | Out-Null }
}
