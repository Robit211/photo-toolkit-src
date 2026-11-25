# 后台工作线程 v3：三段式
#   ① 并行扫描 EXIF（自研解析，不经 COM）
#   ② 单线程规划（判重、定路径，纯内存计算）
#   ③ 多线程并发复制
param(
    [Parameter(Mandatory=$true)][System.Collections.Concurrent.ConcurrentQueue[object]]$Out,
    [Parameter(Mandatory=$true)]$Token,
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$TargetRoot,
    [string]$Mode = 'Copy',
    [bool]$FastDedupe = $true,
    [bool]$UseExif = $true,
    [int]$Threads = 1,
    [Parameter(Mandatory=$true)][string]$CorePath
)

$ErrorActionPreference = 'Continue'
. $CorePath

function Send([hashtable]$m) { $Out.Enqueue($m) }

$cs = @'
using System;
using System.Collections;
using System.Collections.Concurrent;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class PhotoExif
{
    private static ushort U16(byte[] b, int o, bool le)
    { return le ? (ushort)(b[o] | (b[o+1] << 8)) : (ushort)((b[o] << 8) | b[o+1]); }

    private static uint U32(byte[] b, int o, bool le)
    {
        if (le) return (uint)(b[o] | (b[o+1] << 8) | (b[o+2] << 16) | (b[o+3] << 24));
        return (uint)((b[o] << 24) | (b[o+1] << 16) | (b[o+2] << 8) | b[o+3]);
    }

    private static byte[] ReadRange(FileStream fs, byte[] head, long offset, int len)
    {
        if (offset >= 0 && offset + len <= head.Length)
        {
            var r = new byte[len];
            Array.Copy(head, (int)offset, r, 0, len);
            return r;
        }
        if (offset < 0 || offset >= fs.Length) return null;
        if (len > 4096) len = 4096;
        if (offset + len > fs.Length) len = (int)(fs.Length - offset);
        if (len <= 0) return null;
        var buf = new byte[len];
        fs.Seek(offset, SeekOrigin.Begin);
        int got = 0;
        while (got < len) { int k = fs.Read(buf, got, len - got); if (k <= 0) break; got += k; }
        if (got < len) Array.Resize(ref buf, got);
        return buf;
    }

    public static string ReadOne(string path)
    {
        try
        {
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 8192, FileOptions.RandomAccess))
            {
                int headLen = (int)Math.Min(fs.Length, 65536);
                if (headLen < 8) return "";
                var head = new byte[headLen]; int got = 0;
                while (got < headLen) { int k = fs.Read(head, got, headLen - got); if (k <= 0) break; got += k; }

                long tiff = -1;
                if (head[0] == 0xFF && head[1] == 0xD8)
                {
                    int p = 2;
                    while (p + 4 < head.Length)
                    {
                        if (head[p] != 0xFF) { p++; continue; }
                        byte m = head[p+1];
                        if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) { p += 2; continue; }
                        int len = (head[p+2] << 8) | head[p+3];
                        if (m == 0xE1 && p + 10 < head.Length)
                        {
                            if (head[p+4] == 'E' && head[p+5] == 'x' && head[p+6] == 'i' && head[p+7] == 'f')
                            { tiff = p + 10; break; }
                        }
                        p += 2 + len;
                        if (len <= 0) break;
                    }
                }
                else tiff = 0;

                if (tiff < 0 || tiff + 8 > head.Length) return "";
                bool le = (head[tiff] == 'I' && head[tiff+1] == 'I');
                bool be = (head[tiff] == 'M' && head[tiff+1] == 'M');
                if (!le && !be) return "";

                uint ifd0 = U32(head, (int)tiff + 4, le);
                string model = "", date = "";
                long exifIfd = -1;

                Action<long> parseIfd = (long ifdOff) =>
                {
                    var b = ReadRange(fs, head, ifdOff, 2);
                    if (b == null || b.Length < 2) return;
                    int count = U16(b, 0, le);
                    if (count <= 0 || count > 1000) return;
                    var ent = ReadRange(fs, head, ifdOff + 2, count * 12);
                    if (ent == null) return;
                    for (int i = 0; i < count; i++)
                    {
                        int o = i * 12;
                        if (o + 12 > ent.Length) break;
                        int tag = U16(ent, o, le);
                        int type = U16(ent, o + 2, le);
                        uint cnt = U32(ent, o + 4, le);
                        if (tag == 0x8769 && exifIfd < 0) { exifIfd = U32(ent, o + 8, le); continue; }
                        if (tag != 0x0110 && tag != 0x9003 && tag != 0x9004) continue;
                        if (type != 2) continue;
                        int need = (int)cnt;
                        if (need <= 0 || need > 2048) continue;
                        byte[] val;
                        if (need <= 4)
                        {
                            val = new byte[need];
                            Array.Copy(ent, o + 8, val, 0, need);
                        }
                        else
                        {
                            uint voff = U32(ent, o + 8, le);
                            val = ReadRange(fs, head, tiff + voff, need);
                        }
                        if (val == null) continue;
                        string s = Encoding.ASCII.GetString(val).TrimEnd('\0', ' ');
                        if (tag == 0x0110) model = s;
                        else if (date == "" && s.Length >= 19)
                        {
                            try
                            {
                                int y = int.Parse(s.Substring(0, 4));
                                int mo = int.Parse(s.Substring(5, 2));
                                int d = int.Parse(s.Substring(8, 2));
                                int hh = int.Parse(s.Substring(11, 2));
                                int mi = int.Parse(s.Substring(14, 2));
                                int ss = int.Parse(s.Substring(17, 2));
                                if (y > 1900) date = new DateTime(y, mo, d, hh, mi, ss).ToString("yyyy-MM-ddTHH:mm:ss");
                            }
                            catch { }
                        }
                    }
                };

                parseIfd(tiff + ifd0);
                if (exifIfd > 0) parseIfd(tiff + exifIfd);
                return model + "\u001F" + date;
            }
        }
        catch { return ""; }
    }

    public static string[] Scan(string[] files, int degree, CancellationToken token, ConcurrentQueue<object> outQ, int total)
    {
        var res = new string[files.Length];
        int done = 0;
        var opts = new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, degree) };
        Parallel.For(0, files.Length, opts, i =>
        {
            if (token.IsCancellationRequested) return;
            res[i] = ReadOne(files[i]);
            int d = Interlocked.Increment(ref done);
            if (d % 50 == 0)
            {
                var p = new Hashtable();
                p["Type"] = "scanprogress"; p["Done"] = d; p["Total"] = total;
                outQ.Enqueue(p);
            }
        });
        return res;
    }
}

public static class PhotoBulk
{
    public static string Copy(string[] srcs, string[] dsts, int degree,
        ConcurrentQueue<object> outQ, int baseDone, int total, long baseBytes,
        CancellationToken token, string[] names, string[] cams)
    {
        int ok = 0, fail = 0;
        long bytes = 0;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var opts = new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, degree) };

        Parallel.For(0, srcs.Length, opts, i =>
        {
            if (token.IsCancellationRequested) return;
            try
            {
                File.Copy(srcs[i], dsts[i], false);
                long len = new FileInfo(dsts[i]).Length;
                Interlocked.Increment(ref ok);
                Interlocked.Add(ref bytes, len);
                var m = new Hashtable();
                m["Type"] = "log"; m["Level"] = "ok"; m["Status"] = "已归档";
                m["Name"] = names[i]; m["Target"] = dsts[i]; m["Detail"] = cams[i];
                outQ.Enqueue(m);
            }
            catch (Exception ex)
            {
                Interlocked.Increment(ref fail);
                var m = new Hashtable();
                m["Type"] = "log"; m["Level"] = "err"; m["Status"] = "失败";
                m["Name"] = names[i]; m["Target"] = dsts[i]; m["Detail"] = ex.Message;
                outQ.Enqueue(m);
            }
            int done = baseDone + ok + fail;
            if (done % 5 == 0)
            {
                var p = new Hashtable();
                p["Type"] = "progress"; p["Done"] = done; p["Total"] = total;
                long b = baseBytes + Interlocked.Read(ref bytes);
                p["Speed"] = (double)b / 1048576.0 / Math.Max(0.001, sw.Elapsed.TotalSeconds);
                p["Seconds"] = sw.Elapsed.TotalSeconds;
                outQ.Enqueue(p);
            }
        });

        return ok + "|" + fail + "|" + bytes;
    }
}
'@

try { Add-Type -TypeDefinition $cs -ErrorAction Stop } catch {
    Send @{ Type='fatal'; Text=('无法加载本地模块: ' + $_.Exception.Message) }
    Send @{ Type='done'; Stats=@{ 已归档=0; 已存在=0; 预演=0; 跳过=0; 失败=0 }; Seconds=0; Cancelled=$true }
    return
}

$SEP = [char]0x1F

try {
    $swAll = [Diagnostics.Stopwatch]::StartNew()
    $files = @(Get-PhotoMediaFiles -Source $Source -TargetRoot $TargetRoot)
    Send @{ Type='scan'; Total=$files.Count }
    if ($files.Count -eq 0) {
        Send @{ Type='done'; Stats=@{ 已归档=0; 已存在=0; 预演=0; 跳过=0; 失败=0 }; Seconds=0; Cancelled=$false }
        return
    }

    # ---------- ① 并行扫描 EXIF ----------
    $propMap = @{}
    if ($UseExif) {
        $paths = [string[]]@($files | ForEach-Object { $_.FullName })
        $scan = [PhotoExif]::Scan($paths, $Threads, $Token, $Out, $files.Count)
        for ($k = 0; $k -lt $scan.Length; $k++) {
            $s = $scan[$k]
            if ([string]::IsNullOrEmpty($s)) { continue }
            $parts = $s -split $SEP
            $model = $parts[0]
            $dt = $null
            if ($parts.Count -gt 1 -and $parts[1]) {
                $tmp = [datetime]::MinValue
                if ([datetime]::TryParse($parts[1], [ref]$tmp)) { $dt = $tmp }
            }
            if ($model -or $dt) { $propMap[$paths[$k]] = [pscustomobject]@{ Model=$model; DateTaken=$dt } }
        }
    }

    # ---------- ② 单线程规划 ----------
    $stats = @{ 已归档=0; 已存在=0; 预演=0; 跳过=0; 失败=0 }
    $jobs = New-Object System.Collections.Generic.List[object]
    $cancelled = $false
    $i = 0

    foreach ($f in $files) {
        if ($Token.IsCancellationRequested) { $cancelled = $true; break }
        $i++

        $kind = Test-PhotoMedia -File $f
        if (-not $kind.IsPhoto -and -not $kind.IsVideo) {
            $stats['跳过'] = $stats['跳过'] + 1
            Send @{ Type='log'; Level='skip'; Status='跳过'; Name=$f.Name; Target=''; Detail='非照片/视频' }
            continue
        }

        $pl = Resolve-PhotoPlacement -File $f -TargetRoot $TargetRoot -UseExif $false -Props $propMap[$f.FullName]
        $target = Join-Path $pl.Dir $f.Name

        if ($Mode -eq 'Preview') {
            $stats['预演'] = $stats['预演'] + 1
            Send @{ Type='log'; Level='info'; Status='预演'; Name=$f.Name; Target=$target; Detail=("相机 " + $pl.Camera + " · 日期 " + $pl.DateSource) }
            continue
        }

        if (Test-Path -LiteralPath $target) {
            if (Test-PhotoSame -Src $f.FullName -Dst $target -Fast $FastDedupe) {
                $stats['已存在'] = $stats['已存在'] + 1
                Send @{ Type='log'; Level='dim'; Status='已存在'; Name=$f.Name; Target=$target; Detail='内容相同，跳过' }
                continue
            }
            $bn = [IO.Path]::GetFileNameWithoutExtension($f.Name)
            $extO = $f.Extension
            $n = 1
            while (Test-Path -LiteralPath (Join-Path $pl.Dir ($bn + "_$n" + $extO))) { $n++ }
            $target = Join-Path $pl.Dir ($bn + "_$n" + $extO)
        }

        $jobs.Add([pscustomobject]@{ Src=$f.FullName; Dst=$target; Name=$f.Name; Cam=$pl.Camera })
    }

    $plannedSkipped = $stats['已存在'] + $stats['预演'] + $stats['跳过']

    if ($Mode -eq 'Preview' -or $jobs.Count -eq 0) {
        Send @{ Type='done'; Stats=$stats; Seconds=[math]::Round($swAll.Elapsed.TotalSeconds,1); Cancelled=$cancelled }
        return
    }

    # ---------- ③ 并发复制 ----------
    $dirs = @($jobs | ForEach-Object { Split-Path $_.Dst -Parent } | Sort-Object -Unique)
    foreach ($d in $dirs) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

    $srcs  = [string[]]@($jobs | ForEach-Object { $_.Src })
    $dsts  = [string[]]@($jobs | ForEach-Object { $_.Dst })
    $names = [string[]]@($jobs | ForEach-Object { $_.Name })
    $cams  = [string[]]@($jobs | ForEach-Object { $_.Cam })

    $res = [PhotoBulk]::Copy($srcs, $dsts, $Threads, $Out, $plannedSkipped, $files.Count, 0, $Token, $names, $cams)
    $parts = $res -split '\|'
    $stats['已归档'] = [int]$parts[0]
    $stats['失败']   = [int]$parts[1]

    if ($Mode -eq 'Move' -and -not $cancelled) {
        foreach ($j in $jobs) { try { Remove-Item -LiteralPath $j.Src -Force -ErrorAction Stop } catch { } }
    }

    Send @{ Type='done'; Stats=$stats; Seconds=[math]::Round($swAll.Elapsed.TotalSeconds,1); Cancelled=$cancelled }
} catch {
    Send @{ Type='fatal'; Text=($_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionScript) }
    Send @{ Type='done'; Stats=@{ 已归档=0; 已存在=0; 预演=0; 跳过=0; 失败=0 }; Seconds=0; Cancelled=$true }
}
