# 照片管理 - 共享库：EXIF 解析 + 缩略图生成
# 缩略图优先提取 JPEG 内嵌 EXIF 缩略图(只读前 64KB)，失败才回退 WIC 全解码

if (-not ('PhotoExif' -as [type])) {
    $cs = @'
using System;
using System.Collections;
using System.Collections.Concurrent;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;

public static class PhotoExif
{
    internal static ushort U16(byte[] b, int o, bool le)
    { return le ? (ushort)(b[o] | (b[o+1] << 8)) : (ushort)((b[o] << 8) | b[o+1]); }

    internal static uint U32(byte[] b, int o, bool le)
    {
        if (le) return (uint)(b[o] | (b[o+1] << 8) | (b[o+2] << 16) | (b[o+3] << 24));
        return (uint)((b[o] << 24) | (b[o+1] << 16) | (b[o+2] << 8) | b[o+3]);
    }

    internal static byte[] ReadRange(FileStream fs, byte[] head, long offset, int len)
    {
        if (offset >= 0 && offset + len <= head.Length)
        {
            var r = new byte[len];
            Array.Copy(head, (int)offset, r, 0, len);
            return r;
        }
        if (offset < 0 || offset >= fs.Length) return null;
        if (len > 400000) return null;
        if (offset + len > fs.Length) len = (int)(fs.Length - offset);
        if (len <= 0) return null;
        var buf = new byte[len];
        fs.Seek(offset, SeekOrigin.Begin);
        int got = 0;
        while (got < len) { int k = fs.Read(buf, got, len - got); if (k <= 0) break; got += k; }
        if (got < len) Array.Resize(ref buf, got);
        return buf;
    }

    // 在文件头里定位 TIFF(EXIF) 起始偏移
    internal static long FindTiff(byte[] head)
    {
        if (head.Length < 4) return -1;
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
                        return p + 10;
                }
                if (len <= 0) return -1;
                p += 2 + len;
            }
            return -1;
        }
        return 0; // TIFF / NEF
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

                long tiff = FindTiff(head);
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
                        if (need <= 4) { val = new byte[need]; Array.Copy(ent, o + 8, val, 0, need); }
                        else { uint voff = U32(ent, o + 8, le); val = ReadRange(fs, head, tiff + voff, need); }
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
            if (d % 100 == 0)
            {
                var p = new Hashtable();
                p["Type"] = "stage"; p["Stage"] = "exif"; p["Done"] = d; p["Total"] = total;
                outQ.Enqueue(p);
            }
        });
        return res;
    }
}

public static class ThumbMaker
{
    // 从 JPEG/NEF 的 EXIF IFD1 里取出内嵌缩略图(通常 160x120)，只读文件头
    public static byte[] EmbeddedThumb(string path)
    {
        try
        {
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 8192, FileOptions.RandomAccess))
            {
                int headLen = (int)Math.Min(fs.Length, 131072);
                if (headLen < 32) return null;
                var head = new byte[headLen]; int got = 0;
                while (got < headLen) { int k = fs.Read(head, got, headLen - got); if (k <= 0) break; got += k; }

                long tiff = PhotoExif.FindTiff(head);
                if (tiff < 0 || tiff + 8 > head.Length) return null;
                bool le = (head[tiff] == 'I' && head[tiff+1] == 'I');
                if (!le && !(head[tiff] == 'M' && head[tiff+1] == 'M')) return null;

                uint ifd0 = PhotoExif.U32(head, (int)tiff + 4, le);
                var b0 = PhotoExif.ReadRange(fs, head, tiff + ifd0, 2);
                if (b0 == null || b0.Length < 2) return null;
                int n0 = PhotoExif.U16(b0, 0, le);
                var nextOff = PhotoExif.ReadRange(fs, head, tiff + ifd0 + 2 + n0 * 12, 4);
                if (nextOff == null || nextOff.Length < 4) return null;
                uint ifd1rel = PhotoExif.U32(nextOff, 0, le);
                if (ifd1rel == 0) return null;

                // 先试 SubIFD(NEF 常见: 0x014A 指向 PreviewIFD, 内含 0x0201/0x0202)
                var sub = TrySubIfdPreview(fs, head, tiff, ifd0, le);
                if (sub != null) return sub;

                var b1 = PhotoExif.ReadRange(fs, head, tiff + ifd1rel, 2);
                if (b1 == null || b1.Length < 2) return null;
                int n1 = PhotoExif.U16(b1, 0, le);
                if (n1 <= 0 || n1 > 200) return null;
                var ent = PhotoExif.ReadRange(fs, head, tiff + ifd1rel + 2, n1 * 12);
                if (ent == null) return null;

                long off = -1, len = -1;
                for (int i = 0; i < n1; i++)
                {
                    int o = i * 12;
                    if (o + 12 > ent.Length) break;
                    int tag = PhotoExif.U16(ent, o, le);
                    if (tag == 0x0201) off = PhotoExif.U32(ent, o + 8, le);
                    else if (tag == 0x0202) len = PhotoExif.U32(ent, o + 8, le);
                }
                if (off < 0 || len < 1000 || len > 200000) return null;

                var bytes = PhotoExif.ReadRange(fs, head, tiff + off, (int)len);
                if (bytes == null || bytes.Length < 1000) return null;
                if (bytes[0] != 0xFF || bytes[1] != 0xD8) return null;   // 不是 JPEG
                return bytes;
            }
        }
        catch { return null; }
    }

    // 解析 IFD0 的 0x014A(SubIFDs)，在子 IFD 里找 0x0201/0x0202 的 JPEG 预览
    private static byte[] TrySubIfdPreview(FileStream fs, byte[] head, long tiff, uint ifd0, bool le)
    {
        try
        {
            var b0 = PhotoExif.ReadRange(fs, head, tiff + ifd0, 2);
            if (b0 == null || b0.Length < 2) return null;
            int n0 = PhotoExif.U16(b0, 0, le);
            var ent = PhotoExif.ReadRange(fs, head, tiff + ifd0 + 2, n0 * 12);
            if (ent == null) return null;
            var subs = new System.Collections.Generic.List<uint>();
            for (int i = 0; i < n0; i++)
            {
                int o = i * 12;
                if (o + 12 > ent.Length) break;
                if (PhotoExif.U16(ent, o, le) != 0x014A) continue;
                int type = PhotoExif.U16(ent, o + 2, le);
                uint cnt = PhotoExif.U32(ent, o + 4, le);
                if (cnt <= 0 || cnt > 8) continue;
                if (type == 4 && cnt == 1) { subs.Add(PhotoExif.U32(ent, o + 8, le)); }
                else if (type == 4 && cnt > 1)
                {
                    uint arrOff = PhotoExif.U32(ent, o + 8, le);
                    var arr = PhotoExif.ReadRange(fs, head, tiff + arrOff, (int)cnt * 4);
                    if (arr == null) continue;
                    for (int k = 0; k < cnt; k++) subs.Add(PhotoExif.U32(arr, k * 4, le));
                }
            }
            foreach (var srel in subs)
            {
                if (srel == 0) continue;
                var b1 = PhotoExif.ReadRange(fs, head, tiff + srel, 2);
                if (b1 == null || b1.Length < 2) continue;
                int n1 = PhotoExif.U16(b1, 0, le);
                if (n1 <= 0 || n1 > 300) continue;
                var e1 = PhotoExif.ReadRange(fs, head, tiff + srel + 2, n1 * 12);
                if (e1 == null) continue;
                long off = -1, len = -1;
                for (int i = 0; i < n1; i++)
                {
                    int o = i * 12;
                    if (o + 12 > e1.Length) break;
                    int tag = PhotoExif.U16(e1, o, le);
                    if (tag == 0x0201) off = PhotoExif.U32(e1, o + 8, le);
                    else if (tag == 0x0202) len = PhotoExif.U32(e1, o + 8, le);
                }
                if (off < 0 || len < 1000 || len > 400000) continue;
                var bytes = PhotoExif.ReadRange(fs, head, tiff + off, (int)len);
                if (bytes != null && bytes.Length > 1000 && bytes[0] == 0xFF && bytes[1] == 0xD8) return bytes;
            }
            return null;
        }
        catch { return null; }
    }
    public static string Make(string src, string dst, int size)
    {
        try
        {
            var dir = Path.GetDirectoryName(dst);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);

            // ① 优先: 内嵌缩略图(极快)
            var emb = EmbeddedThumb(src);
            if (emb != null)
            {
                File.WriteAllBytes(dst, emb);
                return "OK-embedded";
            }

            // ② 回退: WIC 按目标尺寸解码
            var bi = new BitmapImage();
            bi.BeginInit();
            bi.UriSource = new Uri(src, UriKind.Absolute);
            bi.DecodePixelWidth = size;
            bi.CacheOption = BitmapCacheOption.OnLoad;
            bi.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            bi.EndInit();
            bi.Freeze();

            var enc = new JpegBitmapEncoder();
            enc.QualityLevel = 82;
            enc.Frames.Add(BitmapFrame.Create(bi));
            using (var fs = new FileStream(dst, FileMode.Create, FileAccess.Write, FileShare.None))
                enc.Save(fs);
            return "OK-wic";
        }
        catch (Exception ex) { return "ERR:" + ex.Message; }
    }

    public static string Build(string[] srcs, string[] dsts, int size, int degree,
        CancellationToken token, ConcurrentQueue<object> outQ, int total)
    {
        int ok = 0, fail = 0, done = 0;
        var opts = new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, degree) };
        Parallel.For(0, srcs.Length, opts, i =>
        {
            if (token.IsCancellationRequested) return;
            string r = Make(srcs[i], dsts[i], size);
            if (r.StartsWith("OK")) Interlocked.Increment(ref ok); else Interlocked.Increment(ref fail);
            int d = Interlocked.Increment(ref done);
            if (d % 100 == 0)
            {
                var p = new Hashtable();
                p["Type"] = "stage"; p["Stage"] = "thumb"; p["Done"] = d; p["Total"] = total;
                outQ.Enqueue(p);
            }
        });
        return ok + "|" + fail;
    }
}
'@
    Add-Type -TypeDefinition $cs -ReferencedAssemblies 'System.Drawing','PresentationCore','WindowsBase','System.Xaml' -ErrorAction Stop
}

function Test-PhotoDecodable([string]$path) {
    $e = [IO.Path]::GetExtension($path).ToLower()
    return ($e -in @('.jpg','.jpeg','.png','.tif','.tiff','.bmp'))
}
