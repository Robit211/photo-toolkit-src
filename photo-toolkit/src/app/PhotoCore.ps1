# 照片归档核心逻辑 v3
# 相比 v1: 缓存 Shell 目录对象(212ms -> 8ms/文件)、快速判重(免 MD5)、File.Copy 代替 Copy-Item

$script:PhotoCfg = @{
    PhotoExt   = @('.jpg','.jpeg','.nef','.tif','.tiff','.heic','.dng','.cr2','.arw','.png','.bmp')
    VideoExt   = @('.mov','.mp4','.avi','.m4v','.mts','.mkv')
    UnknownCam = '09-未识别相机'
    BadDateDir = '99-日期异常'
    DateFloor  = [datetime]'2001-01-01'
    CamRules   = @(
        [pscustomobject]@{ Folder='01-D7200'; Model='d7200';                    PathTag='d7200';        MinNum=3000; MaxNum=9999 }
        [pscustomobject]@{ Folder='02-Z62';   Model='z\s*6_2|z6_2|z\s*6ii|z6ii'; PathTag='nz6|z62|z6_2'; MinNum=1;    MaxNum=2999 }
    )
}

$script:ShellApp = $null
$script:FolderCache = @{}
$script:FolderOrder = New-Object System.Collections.Generic.List[string]
$script:FolderCacheMax = 24

function Get-ShellApp {
    if ($null -eq $script:ShellApp) {
        try { $script:ShellApp = New-Object -ComObject Shell.Application } catch { }
    }
    return $script:ShellApp
}

function Reset-PhotoCache {
    $script:FolderCache = @{}
    $script:FolderOrder.Clear()
}

# 缓存 Shell 的 Folder 对象 —— 这是 212ms -> 8ms 的关键
function Get-FolderObj {
    param([string]$Dir)
    $key = $Dir.ToLower()
    if ($script:FolderCache.ContainsKey($key)) { return $script:FolderCache[$key] }
    $sh = Get-ShellApp
    if ($null -eq $sh) { return $null }
    $obj = $null
    try { $obj = $sh.Namespace($Dir) } catch { }
    if ($null -ne $obj) {
        $script:FolderCache[$key] = $obj
        $script:FolderOrder.Add($key)
        while ($script:FolderOrder.Count -gt $script:FolderCacheMax) {
            $old = $script:FolderOrder[0]
            $script:FolderOrder.RemoveAt(0)
            $script:FolderCache.Remove($old)
        }
    }
    return $obj
}

function Test-PhotoMedia {
    param([System.IO.FileInfo]$File)
    $e = $File.Extension.ToLower()
    return [pscustomobject]@{
        IsPhoto = ($script:PhotoCfg.PhotoExt -contains $e)
        IsVideo = ($script:PhotoCfg.VideoExt -contains $e)
    }
}

function Get-PhotoMediaProps {
    param([string]$Path)
    $res = [pscustomobject]@{ DateTaken = $null; Model = '' }
    try {
        $folder = Get-FolderObj (Split-Path $Path -Parent)
        if ($null -eq $folder) { return $res }
        $item = $folder.ParseName((Split-Path $Path -Leaf))
        if ($null -eq $item) { return $res }
        $m = $folder.GetDetailsOf($item, 30)
        if ($m) { $res.Model = ([string]$m).Trim() }
        $d = $folder.GetDetailsOf($item, 12)
        if ($d) {
            $clean = (([string]$d) -replace '[^\d/\-\s:]','').Trim()
            $dt = [datetime]::MinValue
            foreach ($fmt in @('yyyy/M/d H:mm','yyyy/M/d H:mm:ss','yyyy-M-d H:mm','yyyy/M/d','yyyy-MM-dd HH:mm')) {
                if ([datetime]::TryParseExact($clean, $fmt, [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$dt)) {
                    $res.DateTaken = $dt; break
                }
            }
        }
    } catch { }
    return $res
}

function Resolve-PhotoCamera {
    param([System.IO.FileInfo]$File, [string]$Model)
    $m = ([string]$Model).ToLower()
    if ($m) {
        foreach ($r in $script:PhotoCfg.CamRules) { if ($m -match $r.Model) { return $r.Folder } }
    }
    $dirNames = @()
    $cur = $File.Directory
    for ($i = 0; $i -lt 3 -and $cur; $i++) { $dirNames += $cur.Name.ToLower(); $cur = $cur.Parent }
    foreach ($r in $script:PhotoCfg.CamRules) {
        foreach ($d in $dirNames) { if ($d -match $r.PathTag) { return $r.Folder } }
    }
    if ($File.BaseName -match '(\d{4,})$') {
        $n = [int]$Matches[1]
        foreach ($r in $script:PhotoCfg.CamRules) { if ($n -ge $r.MinNum -and $n -le $r.MaxNum) { return $r.Folder } }
    }
    return $script:PhotoCfg.UnknownCam
}

function Resolve-PhotoPlacement {
    param([System.IO.FileInfo]$File, [string]$TargetRoot, [bool]$UseExif = $true, $Props = $null)
    $kind = Test-PhotoMedia -File $File

    # 先走零成本路径(目录名/编号)，只有在 UseExif 时才读 EXIF 覆盖
    $cam  = Resolve-PhotoCamera -File $File -Model ''
    $date = $File.LastWriteTime
    $src  = '文件时间'
    if ($null -ne $Props) {
        if ($Props.Model) { $cam = Resolve-PhotoCamera -File $File -Model $Props.Model }
        if ($null -ne $Props.DateTaken) { $date = $Props.DateTaken; $src = 'EXIF' }
    } elseif ($UseExif) {
        $props = Get-PhotoMediaProps -Path $File.FullName
        if ($props.Model) { $cam = Resolve-PhotoCamera -File $File -Model $props.Model }
        if ($null -ne $props.DateTaken) { $date = $props.DateTaken; $src = 'EXIF' }
    }

    if ($date -lt $script:PhotoCfg.DateFloor) {
        $dir = Join-Path $TargetRoot $script:PhotoCfg.BadDateDir
    } elseif ($kind.IsVideo) {
        $dir = Join-Path $TargetRoot (Join-Path $cam '视频')
    } else {
        $dir = Join-Path $TargetRoot (Join-Path $cam (Join-Path $date.ToString('yyyy') $date.ToString('yyyy-MM')))
    }
    return [pscustomobject]@{
        Dir = $dir; Camera = $cam; Date = $date; DateSource = $src; IsVideo = $kind.IsVideo
    }
}

# 快速判重: 大小不同 -> 不同; 快速模式且修改时间一致 -> 视为相同(免哈希); 否则比 MD5
function Test-PhotoSame {
    param([string]$Src, [string]$Dst, [bool]$Fast = $true)
    try {
        $a = [IO.FileInfo]::new($Src)
        $b = [IO.FileInfo]::new($Dst)
        if ($a.Length -ne $b.Length) { return $false }
        if ($Fast) {
            if ([math]::Abs(($a.LastWriteTimeUtc - $b.LastWriteTimeUtc).TotalSeconds) -le 2) { return $true }
        }
        $h1 = (Get-FileHash -LiteralPath $Src -Algorithm MD5).Hash
        $h2 = (Get-FileHash -LiteralPath $Dst -Algorithm MD5).Hash
        return ($h1 -eq $h2)
    } catch { return $false }
}

function Invoke-PhotoImport {
    param(
        [System.IO.FileInfo]$File,
        [string]$TargetRoot,
        [ValidateSet('Copy','Move','Preview')][string]$Mode = 'Copy',
        [bool]$FastDedupe = $true,
        [bool]$UseExif = $true,
        $Props = $null
    )
    $kind = Test-PhotoMedia -File $File
    if (-not $kind.IsPhoto -and -not $kind.IsVideo) {
        return [pscustomobject]@{ Status='跳过'; Target=''; Detail='非照片/视频' }
    }

    $pl = Resolve-PhotoPlacement -File $File -TargetRoot $TargetRoot -UseExif $UseExif -Props $Props
    $target = Join-Path $pl.Dir $File.Name

    if ($Mode -eq 'Preview') {
        return [pscustomobject]@{ Status='预演'; Target=$target; Detail=("相机 " + $pl.Camera + " · 日期 " + $pl.DateSource) }
    }

    if (-not (Test-Path -LiteralPath $pl.Dir)) { New-Item -ItemType Directory -Path $pl.Dir -Force | Out-Null }

    if (Test-Path -LiteralPath $target) {
        if (Test-PhotoSame -Src $File.FullName -Dst $target -Fast $FastDedupe) {
            return [pscustomobject]@{ Status='已存在'; Target=$target; Detail='内容相同，跳过' }
        }
        $bn = [IO.Path]::GetFileNameWithoutExtension($File.Name)
        $extO = $File.Extension
        $i = 1
        while (Test-Path -LiteralPath (Join-Path $pl.Dir ($bn + "_$i" + $extO))) { $i++ }
        $target = Join-Path $pl.Dir ($bn + "_$i" + $extO)
    }

    try {
        if ($Mode -eq 'Move') { [IO.File]::Move($File.FullName, $target) }
        else { [IO.File]::Copy($File.FullName, $target, $false) }
        return [pscustomobject]@{ Status='已归档'; Target=$target; Detail=$pl.Camera }
    } catch {
        return [pscustomobject]@{ Status='失败'; Target=$target; Detail=$_.Exception.Message }
    }
}

function Get-PhotoMediaFiles {
    param([string]$Source, [string]$TargetRoot)
    Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike '*\_工具\*' -and
            ($TargetRoot -eq '' -or $_.FullName -notlike ($TargetRoot.TrimEnd('\') + '\*'))
        }
}
