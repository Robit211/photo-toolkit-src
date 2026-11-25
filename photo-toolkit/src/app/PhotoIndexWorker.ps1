# 索引工作线程 v4：增量模式
# 依据 (相对路径 + 大小 + 修改时间) 判断文件是否变化，未变化直接复用旧条目，不重读 EXIF
param(
    [Parameter(Mandatory=$true)][System.Collections.Concurrent.ConcurrentQueue[object]]$Out,
    [Parameter(Mandatory=$true)]$Token,
    [Parameter(Mandatory=$true)][string]$Root,
    [int]$Threads = 4,
    [int]$ThumbSize = 320,
    [bool]$Incremental = $true,
    [Parameter(Mandatory=$true)][string]$LibPath
)

$ErrorActionPreference = 'Continue'
$__lib = [scriptblock]::Create([IO.File]::ReadAllText($LibPath, [Text.Encoding]::UTF8))
. $__lib

$CacheDir  = Join-Path $Root '_缓存'
$ThumbDir  = Join-Path $CacheDir 'thumbs'
$IndexFile = Join-Path $CacheDir 'index.json'

function Send([hashtable]$m) { $Out.Enqueue($m) }

try {
    if (-not (Test-Path -LiteralPath $ThumbDir)) { New-Item -ItemType Directory -Path $ThumbDir -Force | Out-Null }

    $photoExt = @('.jpg','.jpeg','.png','.tif','.tiff','.bmp','.nef','.dng','.cr2','.arw','.heic')
    $videoExt = @('.mov','.mp4','.avi','.m4v','.mts','.mkv')

    # ---- 旧索引(增量模式) ----
    $old = @{}
    if ($Incremental -and (Test-Path -LiteralPath $IndexFile)) {
        try {
            $doc = ([IO.File]::ReadAllText($IndexFile, [Text.Encoding]::UTF8)) | ConvertFrom-Json
            foreach ($it in $doc.items) { $old[$it.p] = $it }
            Send @{ Type='info'; Text=("载入旧索引 {0} 条" -f $old.Count) }
        } catch { Send @{ Type='info'; Text='旧索引读取失败，改为全量' } }
    } elseif (-not $Incremental) {
        Send @{ Type='info'; Text='完全重建模式（忽略旧索引）' }
    }

    # ---- 扫描当前文件 ----
    $all = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike '*\_工具\*' -and $_.FullName -notlike '*\_缓存\*' -and
            (($photoExt -contains $_.Extension.ToLower()) -or ($videoExt -contains $_.Extension.ToLower()))
        })
    Send @{ Type='stage'; Stage='scan'; Done=1; Total=1 }
    Send @{ Type='info'; Text=("当前 {0} 个媒体文件" -f $all.Count) }

    # ---- 差异判定 ----
    $reuse = New-Object System.Collections.Generic.List[object]
    $needExif = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($f in $all) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
        $seen[$rel] = $true
        $ms = $f.LastWriteTime.ToString('s')
        $hit = $null
        if ($old.ContainsKey($rel)) { $hit = $old[$rel] }
        if ($null -ne $hit -and [long]$hit.s -eq $f.Length -and [string]$hit.m -eq $ms) {
            $reuse.Add([pscustomobject]@{ File=$f; Rel=$rel; Old=$hit })
        } else {
            $needExif.Add([pscustomobject]@{ File=$f; Rel=$rel; IsNew=(-not $old.ContainsKey($rel)) })
        }
    }
    $removed = @($old.Keys | Where-Object { -not $seen.ContainsKey($_) })
    $newCount = @($needExif | Where-Object { $_.IsNew }).Count
    $modCount = $needExif.Count - $newCount
    Send @{ Type='info'; Text=("复用 {0} · 新增 {1} · 修改 {2} · 移除 {3}" -f $reuse.Count, $newCount, $modCount, $removed.Count) }

    # ---- 只对新增/修改的文件读 EXIF ----
    $exifMap = @{}
    if ($needExif.Count -gt 0) {
        $paths = [string[]]@($needExif | ForEach-Object { $_.File.FullName })
        $scan = [PhotoExif]::Scan($paths, $Threads, $Token, $Out, $needExif.Count)
        $SEP = [char]0x1F
        for ($i = 0; $i -lt $scan.Length; $i++) {
            $s = $scan[$i]
            if ([string]::IsNullOrEmpty($s)) { continue }
            $p = $s -split $SEP
            $dt = $null
            if ($p.Count -gt 1 -and $p[1]) { $tmp=[datetime]::MinValue; if ([datetime]::TryParse($p[1],[ref]$tmp)) { $dt = $tmp } }
            if ($p[0] -or $dt) { $exifMap[$paths[$i]] = @{ Model=$p[0]; Date=$dt } }
        }
    }
    if ($Token.IsCancellationRequested) { Send @{ Type='cancelled' }; return }

    # ---- 组装条目 ----
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($rItem in $reuse) { $items.Add($rItem.Old) }

    $thumbSrc = New-Object System.Collections.Generic.List[string]
    $thumbDst = New-Object System.Collections.Generic.List[string]

    foreach ($nItem in $needExif) {
        $f = $nItem.File
        $rel = $nItem.Rel
        $seg = $rel -split '\\'
        $cam = if ($seg.Count -gt 1) { $seg[0] } else { '（根目录）' }

        $dt = $null; $model = ''
        if ($exifMap.ContainsKey($f.FullName)) { $dt = $exifMap[$f.FullName].Date; $model = $exifMap[$f.FullName].Model }
        if ($null -eq $dt) { $dt = $f.LastWriteTime }

        $ext = $f.Extension.ToLower()
        $isVideo = ($videoExt -contains $ext)

        $tSrc = $null
        if (Test-PhotoDecodable $f.FullName) { $tSrc = $f.FullName }
        elseif ($ext -eq '.nef') {
            foreach ($e in @('.JPG','.jpg','.JPEG','.jpeg')) {
                $twin = [IO.Path]::ChangeExtension($f.FullName, $e)
                if (Test-Path -LiteralPath $twin) { $tSrc = $twin; break }
            }
            if (-not $tSrc) { $tSrc = $f.FullName }
        }

        $thumbName = ''
        if ($tSrc) {
            $key = $tSrc.Substring($Root.Length).TrimStart('\').ToLower()
            $md5 = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($key))).Replace('-','').ToLower()
            $thumbName = $md5 + '.jpg'
            $dstFull = Join-Path $ThumbDir $thumbName
            $need = $true
            if (Test-Path -LiteralPath $dstFull) {
                if ((Get-Item -LiteralPath $dstFull).LastWriteTime -ge (Get-Item -LiteralPath $tSrc).LastWriteTime) { $need = $false }
            }
            if ($need) { $thumbSrc.Add($tSrc); $thumbDst.Add($dstFull) }
        }

        $items.Add([pscustomobject]@{
            p = $rel; n = $f.Name; s = $f.Length; m = $f.LastWriteTime.ToString('s')
            c = $cam; d = $dt.ToString('s'); md = $model; t = $thumbName
            k = $(if ($isVideo) { 'video' } else { 'photo' })
        })
    }

    # ---- 只生成缺失的缩略图 ----
    if ($thumbSrc.Count -gt 0) {
        Send @{ Type='info'; Text=("生成 {0} 张缩略图..." -f $thumbSrc.Count) }
        $r = [ThumbMaker]::Build([string[]]$thumbSrc.ToArray(), [string[]]$thumbDst.ToArray(), $ThumbSize, $Threads, $Token, $Out, $thumbSrc.Count)
        $parts = $r -split '\|'
        Send @{ Type='info'; Text=("缩略图 成功 {0} 失败 {1}" -f $parts[0], $parts[1]) }
    } else {
        Send @{ Type='info'; Text='缩略图无需更新' }
    }

    if ($Token.IsCancellationRequested) { Send @{ Type='cancelled' }; return }

    # ---- 清理被移除文件留下的缩略图 ----
    if ($removed.Count -gt 0) {
        $gone = 0
        foreach ($rp in $removed) {
            $o = $old[$rp]
            if ($o.t) {
                $tp = Join-Path $ThumbDir $o.t
                # 只有当没有别的条目还在用这张缩略图时才删
                $stillUsed = $false
                foreach ($it in $items) { if ($it.t -eq $o.t) { $stillUsed = $true; break } }
                if (-not $stillUsed -and (Test-Path -LiteralPath $tp)) { Remove-Item -LiteralPath $tp -Force -ErrorAction SilentlyContinue; $gone++ }
            }
        }
        if ($gone -gt 0) { Send @{ Type='info'; Text=("清理孤立缩略图 {0} 张" -f $gone) } }
    }

    # ---- 写索引 ----
    $doc = [pscustomobject]@{
        built = (Get-Date).ToString('s'); root = $Root; thumbSize = $ThumbSize
        count = $items.Count; reused = $reuse.Count; added = $newCount; modified = $modCount; removedCount = $removed.Count
        items = $items
    }
    [IO.File]::WriteAllText($IndexFile, ($doc | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
    # ---- 清理任何未被索引引用的孤立缩略图 ----
    try {
        $usedThumbs = @{}
        foreach ($it in $items) { if ($it.t) { $usedThumbs[$it.t] = $true } }
        $onDisk = @(Get-ChildItem -LiteralPath $ThumbDir -File -ErrorAction SilentlyContinue)
        $orphans = @($onDisk | Where-Object { -not $usedThumbs.ContainsKey($_.Name) })
        if ($orphans.Count -gt 0) {
            $freed = 0L
            foreach ($o in $orphans) { $freed += $o.Length; Remove-Item -LiteralPath $o.FullName -Force -ErrorAction SilentlyContinue }
            Send @{ Type='info'; Text=("清理孤立缩略图 {0} 张，释放 {1:N1} MB" -f $orphans.Count, ($freed/1MB)) }
        }
    } catch { }

    Send @{ Type='done'; Count = $items.Count; Reused = $reuse.Count; Added = $newCount; Modified = $modCount; Removed = $removed.Count }
} catch {
    Send @{ Type='error'; Text = ($_.Exception.Message + ' @ line ' + $_.InvocationInfo.ScriptLineNumber) }
}
