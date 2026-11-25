# 照片管理器 v2 - 评分与标记
# 星级(0-5) + 保留/淘汰，标记独立存于 _缓存\marks.json，重建索引不丢

param(
    [switch]$SelfTest,
    [switch]$FilterTest,
    [switch]$MarksTest,
    [switch]$NoAutoCheck,
    [switch]$GroupTest,
    [string]$DumpImage,
    [string]$Root = "$env:USERPROFILE\Pictures\照片库"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$LibPath    = Join-Path $PSScriptRoot 'PhotoLib.ps1'
$WorkerPath = Join-Path $PSScriptRoot 'PhotoIndexWorker.ps1'
$CacheDir   = Join-Path $Root '_缓存'
$IndexFile  = Join-Path $CacheDir 'index.json'
$MarksFile  = Join-Path $CacheDir 'marks.json'
$ThumbDir   = Join-Path $CacheDir 'thumbs'
$__lib = [scriptblock]::Create([IO.File]::ReadAllText($LibPath, [Text.Encoding]::UTF8))
. $__lib

$script:index = @()
$script:marks = @{}
$script:marksDirty = $false
$script:filtered = @()
$script:page = 0
$script:pageSize = 60
$script:selPos = -1
$script:selected = $null

# ---------------- 索引 ----------------
function Load-Index {
    if (-not (Test-Path -LiteralPath $IndexFile)) { return $false }
    try {
        $doc = ([IO.File]::ReadAllText($IndexFile, [Text.Encoding]::UTF8)) | ConvertFrom-Json
        $script:index = @($doc.items)
        return ($script:index.Count -gt 0)
    } catch { return $false }
}

function Save-Index {
    if ($script:index.Count -eq 0) { return }
    try {
        if (-not (Test-Path -LiteralPath $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
        $doc = [pscustomobject]@{ built=(Get-Date).ToString('s'); root=$Root; thumbSize=320; count=$script:index.Count; items=$script:index }
        [IO.File]::WriteAllText($IndexFile, ($doc | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

# ---------------- 标记(独立文件) ----------------
function Load-Marks {
    $script:marks = @{}
    if (-not (Test-Path -LiteralPath $MarksFile)) { return }
    try {
        $doc = ([IO.File]::ReadAllText($MarksFile, [Text.Encoding]::UTF8)) | ConvertFrom-Json
        foreach ($p in $doc.PSObject.Properties) {
            $script:marks[$p.Name] = @{ r = [int]$p.Value.r; f = [string]$p.Value.f }
        }
    } catch { }
}

function Save-Marks {
    if (-not $script:marksDirty) { return }
    try {
        if (-not (Test-Path -LiteralPath $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
        $obj = [ordered]@{}
        foreach ($k in $script:marks.Keys) {
            $v = $script:marks[$k]
            if ($v.r -eq 0 -and -not $v.f) { continue }
            $obj[$k] = [pscustomobject]@{ r = $v.r; f = $v.f }
        }
        [IO.File]::WriteAllText($MarksFile, ($obj | ConvertTo-Json -Depth 3 -Compress), (New-Object Text.UTF8Encoding($false)))
        $script:marksDirty = $false
    } catch { }
}

function Get-Mark($rel) {
    if ($script:marks.ContainsKey($rel)) { return $script:marks[$rel] }
    return @{ r = 0; f = '' }
}

function Set-Mark($rel, $rating, $flag) {
    $cur = Get-Mark $rel
    $r = if ($null -ne $rating) { [int]$rating } else { $cur.r }
    $f = if ($null -ne $flag) { [string]$flag } else { $cur.f }
    if ($r -eq 0 -and -not $f) { $script:marks.Remove($rel) } else { $script:marks[$rel] = @{ r = $r; f = $f } }
    $script:marksDirty = $true
}

# ---------------- RAW+JPG 合并 ----------------
$script:groups = @()
$script:splitRaw = $false

function Build-Groups {
    $map = [ordered]@{}
    foreach ($it in $script:index) {
        if ($script:splitRaw) {
            $key = 'F|' + $it.p.ToLower()
            $dir = Split-Path $it.p -Parent
            $base = [IO.Path]::GetFileNameWithoutExtension($it.n)
        } else {
            $dir = Split-Path $it.p -Parent
            if (-not $dir) { $dir = '' }
            $base = [IO.Path]::GetFileNameWithoutExtension($it.n)
            $key = 'G|' + ($dir + '|' + $base).ToLower()
        }
        if (-not $map.Contains($key)) {
            $map[$key] = [pscustomobject]@{ Key=$key; Dir=$dir; Base=$base; Members=(New-Object System.Collections.ArrayList) }
        }
        [void]$map[$key].Members.Add($it)
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($k in $map.Keys) {
        $g = $map[$k]
        $ms = @($g.Members)
        $primary = $ms | Where-Object { $_.n -match '(?i)\.(jpe?g|png|tif|tiff|bmp)$' } | Select-Object -First 1
        if (-not $primary) { $primary = $ms[0] }
        $out.Add([pscustomobject]@{
            Key = $g.Key; Dir = $g.Dir; Base = $g.Base; Members = $ms
            Primary = $primary; Name = $primary.n; Count = $ms.Count
        })
    }
    $script:groups = $out
}

function Get-GroupMark($grp) {
    $r = 0; $f = ''
    foreach ($m in $grp.Members) {
        $mk = Get-Mark $m.p
        if ($mk.r -gt $r) { $r = $mk.r }
        if (-not $f -and $mk.f) { $f = $mk.f }
    }
    return @{ r = $r; f = $f }
}

# ---------------- 自检 ----------------
if ($SelfTest) {
    Load-Index | Out-Null
    Build-Groups
    Load-Marks
    Write-Host ("SELFTEST: 索引 {0} 条, 标记 {1} 条" -f $script:index.Count, $script:marks.Count)
    $script:index | Group-Object { $_.c } | Sort-Object Count -Descending | ForEach-Object { Write-Host ("  {0,-16} {1,5}" -f $_.Name, $_.Count) }
    $rated = @($script:marks.Keys | Where-Object { $script:marks[$_].r -gt 0 }).Count
    $keep = @($script:marks.Keys | Where-Object { $script:marks[$_].f -eq 'keep' }).Count
    $rej  = @($script:marks.Keys | Where-Object { $script:marks[$_].f -eq 'reject' }).Count
    Write-Host ("  已评分 {0} · 保留 {1} · 淘汰 {2}" -f $rated, $keep, $rej)
    Build-Groups
    Write-Host ("  合并后条目: {0}（按 RAW+JPG 归组）" -f $script:groups.Count)
    exit 0
}

# ---------------- 界面 ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = '照片管理器'
$form.Size = New-Object System.Drawing.Size(1240, 860)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('微软雅黑', 9)
$form.KeyPreview = $true

$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = 'Top'; $panelTop.Height = 104

$mkLabel = { param($t,$x,$y,$w) $l=New-Object System.Windows.Forms.Label; $l.Text=$t; $l.Location=New-Object System.Drawing.Point($x,$y); $l.Size=New-Object System.Drawing.Size($w,20); $l }

$lbCam = & $mkLabel '相机' 10 12 34
$cmbCam = New-Object System.Windows.Forms.ComboBox
$cmbCam.Location = New-Object System.Drawing.Point(46, 8); $cmbCam.Size = New-Object System.Drawing.Size(150, 24); $cmbCam.DropDownStyle = 'DropDownList'

$lbYear = & $mkLabel '年' 208 12 20
$cmbYear = New-Object System.Windows.Forms.ComboBox
$cmbYear.Location = New-Object System.Drawing.Point(230, 8); $cmbYear.Size = New-Object System.Drawing.Size(90, 24); $cmbYear.DropDownStyle = 'DropDownList'

$lbMon = & $mkLabel '月' 330 12 20
$cmbMon = New-Object System.Windows.Forms.ComboBox
$cmbMon.Location = New-Object System.Drawing.Point(352, 8); $cmbMon.Size = New-Object System.Drawing.Size(80, 24); $cmbMon.DropDownStyle = 'DropDownList'

$lbKey = & $mkLabel '关键字' 444 12 48
$txtKey = New-Object System.Windows.Forms.TextBox
$txtKey.Location = New-Object System.Drawing.Point(494, 8); $txtKey.Size = New-Object System.Drawing.Size(170, 24)

$lbMark = & $mkLabel '标记' 676 12 34
$cmbMark = New-Object System.Windows.Forms.ComboBox
$cmbMark.Location = New-Object System.Drawing.Point(712, 8); $cmbMark.Size = New-Object System.Drawing.Size(130, 24); $cmbMark.DropDownStyle = 'DropDownList'
[void]$cmbMark.Items.AddRange(@('全部','未评分','≥3 星','≥4 星','保留','淘汰'))
$cmbMark.SelectedIndex = 0

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = '筛选'; $btnApply.Location = New-Object System.Drawing.Point(854, 7); $btnApply.Size = New-Object System.Drawing.Size(64, 26)
$btnReset = New-Object System.Windows.Forms.Button
$btnReset.Text = '重置'; $btnReset.Location = New-Object System.Drawing.Point(924, 7); $btnReset.Size = New-Object System.Drawing.Size(64, 26)
$btnRebuild = New-Object System.Windows.Forms.Button
$btnRebuild.Text = '更新索引'; $btnRebuild.Location = New-Object System.Drawing.Point(994, 7); $btnRebuild.Size = New-Object System.Drawing.Size(84, 26)
$btnFullRebuild = New-Object System.Windows.Forms.Button
$btnFullRebuild.Text = '完全重建'; $btnFullRebuild.Location = New-Object System.Drawing.Point(1084, 7); $btnFullRebuild.Size = New-Object System.Drawing.Size(80, 26)

# 评分/标记操作条
$grpMark = New-Object System.Windows.Forms.GroupBox
$grpMark.Text = '对选中项打分 / 标记（也可用键盘 1-5、X 淘汰、P 保留、U 清除）'
$grpMark.Location = New-Object System.Drawing.Point(10, 40); $grpMark.Size = New-Object System.Drawing.Size(1160, 58)

$script:starButtons = @()
for ($i = 1; $i -le 5; $i++) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = ('★' * $i)
    $b.Location = New-Object System.Drawing.Point((10 + ($i - 1) * 78), 20)
    $b.Size = New-Object System.Drawing.Size(74, 28)
    $b.Tag = $i
    $script:starButtons += $b
    $grpMark.Controls.Add($b)
}
$bStar0 = New-Object System.Windows.Forms.Button
$bStar0.Text = '清星'; $bStar0.Location = New-Object System.Drawing.Point(400, 20); $bStar0.Size = New-Object System.Drawing.Size(64, 28); $bStar0.Tag = 0
$grpMark.Controls.Add($bStar0)
$script:starButtons += $bStar0

$btnKeep = New-Object System.Windows.Forms.Button
$btnKeep.Text = '保留 (P)'; $btnKeep.Location = New-Object System.Drawing.Point(486, 20); $btnKeep.Size = New-Object System.Drawing.Size(84, 28)
$btnKeep.ForeColor = [System.Drawing.Color]::DarkGreen
$btnReject = New-Object System.Windows.Forms.Button
$btnReject.Text = '淘汰 (X)'; $btnReject.Location = New-Object System.Drawing.Point(578, 20); $btnReject.Size = New-Object System.Drawing.Size(84, 28)
$btnReject.ForeColor = [System.Drawing.Color]::DarkRed
$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = '清除 (U)'; $btnClear.Location = New-Object System.Drawing.Point(670, 20); $btnClear.Size = New-Object System.Drawing.Size(84, 28)
$btnDelRej = New-Object System.Windows.Forms.Button
$btnDelRej.Text = '删除全部淘汰项'; $btnDelRej.Location = New-Object System.Drawing.Point(960, 20); $btnDelRej.Size = New-Object System.Drawing.Size(180, 28)
$btnDelRej.ForeColor = [System.Drawing.Color]::DarkRed

$grpMark.Controls.AddRange(@($btnKeep,$btnReject,$btnClear,$btnDelRej))

$prog = New-Object System.Windows.Forms.ProgressBar
$prog.Location = New-Object System.Drawing.Point(10, 104); $prog.Size = New-Object System.Drawing.Size(1160, 12); $prog.Visible = $false

$panelTop.Controls.AddRange(@($lbCam,$cmbCam,$lbYear,$cmbYear,$lbMon,$cmbMon,$lbKey,$txtKey,$lbMark,$cmbMark,$btnApply,$btnReset,$btnRebuild,$btnFullRebuild,$grpMark,$prog))

$panelBottom = New-Object System.Windows.Forms.Panel
$panelBottom.Dock = 'Bottom'; $panelBottom.Height = 46

$lblPage = New-Object System.Windows.Forms.Label
$lblPage.Text = ''; $lblPage.Location = New-Object System.Drawing.Point(10, 14); $lblPage.Size = New-Object System.Drawing.Size(430, 20)

$btnPrev = New-Object System.Windows.Forms.Button
$btnPrev.Text = '上一页'; $btnPrev.Location = New-Object System.Drawing.Point(450, 8); $btnPrev.Size = New-Object System.Drawing.Size(80, 28)
$btnNext = New-Object System.Windows.Forms.Button
$btnNext.Text = '下一页'; $btnNext.Location = New-Object System.Drawing.Point(536, 8); $btnNext.Size = New-Object System.Drawing.Size(80, 28)
$btnOpenDir = New-Object System.Windows.Forms.Button
$btnOpenDir.Text = '打开所在文件夹'; $btnOpenDir.Location = New-Object System.Drawing.Point(660, 8); $btnOpenDir.Size = New-Object System.Drawing.Size(130, 28)
$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = '删除到回收站'; $btnDelete.Location = New-Object System.Drawing.Point(796, 8); $btnDelete.Size = New-Object System.Drawing.Size(120, 28)
$btnDelete.ForeColor = [System.Drawing.Color]::DarkRed

$chkSplit = New-Object System.Windows.Forms.CheckBox
$chkSplit.Text = '分开显示 RAW 与 JPG'; $chkSplit.Location = New-Object System.Drawing.Point(940, 12); $chkSplit.Size = New-Object System.Drawing.Size(190, 22)
$chkSplit.Checked = $false

$panelBottom.Controls.AddRange(@($lblPage,$btnPrev,$btnNext,$btnOpenDir,$btnDelete,$chkSplit))

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.SplitterDistance = 830

$listView = New-Object System.Windows.Forms.ListView
$listView.Dock = 'Fill'; $listView.View = 'LargeIcon'; $listView.MultiSelect = $true
$listView.HideSelection = $false
$listView.LargeImageList = New-Object System.Windows.Forms.ImageList
$listView.LargeImageList.ImageSize = New-Object System.Drawing.Size(150, 170)
$listView.LargeImageList.ColorDepth = 'Depth24Bit'
$listView.BackColor = [System.Drawing.Color]::FromArgb(250,250,250)

$panelRight = New-Object System.Windows.Forms.Panel
$panelRight.Dock = 'Fill'
$pic = New-Object System.Windows.Forms.PictureBox
$pic.Dock = 'Top'; $pic.Height = 420; $pic.SizeMode = 'Zoom'
$pic.BackColor = [System.Drawing.Color]::FromArgb(40,40,40)
$info = New-Object System.Windows.Forms.TextBox
$info.Dock = 'Fill'; $info.Multiline = $true; $info.ReadOnly = $true; $info.ScrollBars = 'Vertical'
$info.Font = New-Object System.Drawing.Font('Consolas', 9)
$panelRight.Controls.Add($pic); $panelRight.Controls.Add($info)
$split.Panel1.Controls.Add($listView); $split.Panel2.Controls.Add($panelRight)

$form.Controls.Add($split); $form.Controls.Add($panelTop); $form.Controls.Add($panelBottom)

# ---------------- 缩略图绘制(带星标与标记) ----------------
function Draw-Thumb([System.Drawing.Image]$src, [int]$rating, [string]$flag, [string]$tag) {
    $bmp = New-Object System.Drawing.Bitmap(150, 170)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(250,250,250))
    if ($src) {
        $maxW = 150; $maxH = 140
        $s = [Math]::Min($maxW / $src.Width, $maxH / $src.Height)
        $w = [int]($src.Width * $s); $h = [int]($src.Height * $s)
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.DrawImage($src, [int]((150 - $w)/2), [int]((140 - $h)/2), $w, $h)
    }
    # 底部信息条
    $g.FillRectangle([System.Drawing.Brushes]::White, 0, 140, 150, 30)
    $g.DrawLine([System.Drawing.Pens]::LightGray, 0, 140, 150, 140)
    $starText = ('★' * $rating) + ('☆' * (5 - $rating))
    $g.DrawString($starText, (New-Object System.Drawing.Font('微软雅黑', 8)), [System.Drawing.Brushes]::Goldenrod, 3, 144)
    if ($flag -eq 'keep') {
        $g.FillRectangle([System.Drawing.Brushes]::SeaGreen, 104, 144, 42, 20)
        $g.DrawString('保留', (New-Object System.Drawing.Font('微软雅黑', 7)), [System.Drawing.Brushes]::White, 107, 146)
    } elseif ($flag -eq 'reject') {
        $g.FillRectangle([System.Drawing.Brushes]::Firebrick, 104, 144, 42, 20)
        $g.DrawString('淘汰', (New-Object System.Drawing.Font('微软雅黑', 7)), [System.Drawing.Brushes]::White, 107, 146)
    }
    if ($tag) {
        $g.FillRectangle([System.Drawing.Brushes]::SteelBlue, 0, 0, 64, 18)
        $g.DrawString($tag, (New-Object System.Drawing.Font('Consolas', 7)), [System.Drawing.Brushes]::White, 3, 2)
    }
    $g.Dispose()
    return $bmp
}

function New-Placeholder([string]$text) {
    $bmp = New-Object System.Drawing.Bitmap(150, 170)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(230,230,230))
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment='Center'; $fmt.LineAlignment='Center'
    $g.DrawString($text, (New-Object System.Drawing.Font('微软雅黑', 10)), [System.Drawing.Brushes]::Gray,
        (New-Object System.Drawing.RectangleF(0,0,150,170)), $fmt)
    $g.Dispose()
    return $bmp
}

# ---------------- 筛选与渲染 ----------------

function Update-FilterOptions {
    $cams = @($script:index | ForEach-Object { $_.c } | Sort-Object -Unique)
    $cmbCam.Items.Clear(); [void]$cmbCam.Items.Add('全部相机'); foreach ($c in $cams) { [void]$cmbCam.Items.Add($c) }; $cmbCam.SelectedIndex = 0

    $years = @($script:index | ForEach-Object { $_.d.Substring(0,4) } | Sort-Object -Unique)
    $cmbYear.Items.Clear(); [void]$cmbYear.Items.Add('全部'); foreach ($y in $years) { [void]$cmbYear.Items.Add($y) }; $cmbYear.SelectedIndex = 0

    $cmbMon.Items.Clear(); [void]$cmbMon.Items.Add('全部')
    for ($i = 1; $i -le 12; $i++) { [void]$cmbMon.Items.Add(('{0:D2}' -f $i)) }
    $cmbMon.SelectedIndex = 0
}

function Apply-Filter {
    if ($script:groups.Count -eq 0 -and $script:index.Count -gt 0) { Build-Groups }
    $cam = if ($cmbCam.SelectedIndex -gt 0) { [string]$cmbCam.SelectedItem } else { '' }
    $yr  = if ($cmbYear.SelectedIndex -gt 0) { [string]$cmbYear.SelectedItem } else { '' }
    $mo  = if ($cmbMon.SelectedIndex -gt 0) { [string]$cmbMon.SelectedItem } else { '' }
    $kw  = $txtKey.Text.Trim().ToLower()
    $mk  = if ($cmbMark.SelectedIndex -gt 0) { [string]$cmbMark.SelectedItem } else { '全部' }

    $script:filtered = @($script:groups | Where-Object {
        $p0 = $_.Primary
        if ($cam -ne '' -and $p0.c -ne $cam) { return $false }
        if ($yr -ne '' -and $p0.d.Substring(0,4) -ne $yr) { return $false }
        if ($mo -ne '' -and $p0.d.Substring(5,2) -ne $mo) { return $false }
        if ($kw -ne '') {
            $hit = $false
            foreach ($m in $_.Members) { if ($m.n.ToLower().Contains($kw)) { $hit = $true; break } }
            if (-not $hit) { return $false }
        }
        if ($mk -ne '全部') {
            $gm = Get-GroupMark $_
            switch ($mk) {
                '未评分' { if ($gm.r -gt 0) { return $false } }
                '≥3 星'  { if ($gm.r -lt 3) { return $false } }
                '≥4 星'  { if ($gm.r -lt 4) { return $false } }
                '保留'   { if ($gm.f -ne 'keep') { return $false } }
                '淘汰'   { if ($gm.f -ne 'reject') { return $false } }
            }
        }
        return $true
    })
    $script:page = 0
    $script:selPos = -1
    Render-Page
}

function Render-Page {
    $total = $script:filtered.Count
    $pages = [Math]::Max(1, [Math]::Ceiling($total / $script:pageSize))
    if ($script:page -ge $pages) { $script:page = $pages - 1 }
    if ($script:page -lt 0) { $script:page = 0 }
    $start = $script:page * $script:pageSize
    $slice = @()
    if ($total -gt 0) { $slice = @($script:filtered[$start..([Math]::Min($start + $script:pageSize - 1, $total - 1))]) }

    $listView.BeginUpdate()
    $listView.Items.Clear()
    $oldIl = $listView.LargeImageList
    $il = New-Object System.Windows.Forms.ImageList
    $il.ImageSize = New-Object System.Drawing.Size(150, 170)
    $il.ColorDepth = 'Depth24Bit'
    $listView.LargeImageList = $il

    $idx = 0
    foreach ($g in $slice) {
        $gm = Get-GroupMark $g
        $base = $null
        if ($g.Primary.t) {
            $tp = Join-Path $ThumbDir $g.Primary.t
            if (Test-Path -LiteralPath $tp) { try { $base = [System.Drawing.Image]::FromFile($tp) } catch { } }
        }
        $tag = ''
        if ($g.Count -gt 1) { $tag = 'RAW+JPG' }
        if ($null -eq $base) { $img = New-Placeholder $(if ($g.Primary.k -eq 'video') { 'VIDEO' } else { '无预览' }) }
        else { $img = Draw-Thumb $base $gm.r $gm.f $tag; $base.Dispose() }

        [void]$il.Images.Add($img)
        $label = if ($g.Count -gt 1) { $g.Base } else { $g.Name }
        $item = New-Object System.Windows.Forms.ListViewItem($label, $idx)
        $item.Tag = $g
        $item.ToolTipText = $(if ($g.Count -gt 1) { ($g.Members | ForEach-Object { $_.n }) -join ' + ' } else { $g.Primary.p })
        [void]$listView.Items.Add($item)
        $idx++
    }
    $listView.EndUpdate()
    if ($oldIl) { $oldIl.Dispose() }

    $lblPage.Text = ("第 {0}/{1} 页 · 共 {2} 项（全库 {3} 项 / {4} 个文件）" -f ($script:page + 1), $pages, $total, $script:groups.Count, $script:index.Count)
    $btnPrev.Enabled = ($script:page -gt 0)
    $btnNext.Enabled = ($script:page -lt ($pages - 1))
    $pic.Image = $null
    $info.Text = ''
    $script:selected = $null
}

function Show-Item($g) {
    $script:selected = $g
    $gm = Get-GroupMark $g
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("名称    : " + $g.Base)
    [void]$sb.AppendLine("相机    : " + $g.Primary.c)
    if ($g.Primary.md) { [void]$sb.AppendLine("机身    : " + $g.Primary.md) }
    [void]$sb.AppendLine("拍摄    : " + ([datetime]$g.Primary.d).ToString('yyyy-MM-dd HH:mm:ss'))
    [void]$sb.AppendLine("星级    : " + ('★' * $gm.r) + ('☆' * (5 - $gm.r)))
    $fl = switch ($gm.f) { 'keep' { '保留' } 'reject' { '淘汰' } default { '（未标记）' } }
    [void]$sb.AppendLine("标记    : " + $fl)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("文件（共 $($g.Count) 个）")
    foreach ($m in $g.Members) {
        [void]$sb.AppendLine(("  {0,-32} {1,8:N1} MB" -f $m.n, ($m.s / 1MB)))
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("目录")
    [void]$sb.AppendLine($g.Dir)

    $full = Join-Path $Root $g.Primary.p
    $preview = $null
    if (Test-PhotoDecodable $full) { $preview = $full }
    elseif ([IO.Path]::GetExtension($full).ToLower() -eq '.nef') {
        foreach ($e in @('.JPG','.jpg','.JPEG','.jpeg')) {
            $twin = [IO.Path]::ChangeExtension($full, $e)
            if (Test-Path -LiteralPath $twin) { $preview = $twin; break }
        }
        if (-not $preview) { $preview = $full }
    }
    $oldImg = $pic.Image
    $pic.Image = $null
    if ($oldImg) { $oldImg.Dispose() }
    if ($preview) {
        try {
            $fs = [IO.File]::OpenRead($preview)
            $pic.Image = [System.Drawing.Image]::FromStream($fs)
        } catch { $pic.Image = $null }
    }
}

# ---------------- 打分与标记动作 ----------------
function Apply-ToSelection([int]$rating, [string]$flag) {
    if ($listView.SelectedItems.Count -eq 0) { return }
    $n = 0
    foreach ($sel in @($listView.SelectedItems)) {
        $g = $sel.Tag
        foreach ($m in $g.Members) {
            if ($rating -ge 0) { Set-Mark $m.p $rating $null; $n++ }
            if ($flag) { Set-Mark $m.p $null $flag; $n++ }
        }
    }
    Save-Marks
    $keepPos = $script:selPos
    $oldPage = $script:page
    Render-Page
    $script:page = $oldPage
    Render-Page
    if ($keepPos -ge 0 -and $keepPos -lt $listView.Items.Count) {
        $listView.Items[$keepPos].Selected = $true
        $listView.Items[$keepPos].Focused = $true
        Show-Item $listView.Items[$keepPos].Tag
    }
    $rated = @($script:index | Where-Object { (Get-Mark $_.p).r -gt 0 }).Count
    $rej = @($script:index | Where-Object { (Get-Mark $_.p).f -eq 'reject' }).Count
    $kp  = @($script:index | Where-Object { (Get-Mark $_.p).f -eq 'keep' }).Count
    Write-Host ("已更新 {0} 个文件" -f $n)
    $lblPage.Text = $lblPage.Text + ("   已评分 {0} · 保留 {1} · 淘汰 {2}" -f $rated, $kp, $rej)
}

function Move-Selection([int]$delta) {
    $total = $script:filtered.Count
    if ($total -eq 0) { return }
    if ($script:selPos -lt 0) { $script:selPos = -1 }
    $newPos = $script:selPos + $delta
    if ($newPos -lt 0) { $newPos = 0 }
    if ($newPos -ge $total) { $newPos = $total - 1 }
    $script:selPos = $newPos
    $targetPage = [int][Math]::Floor($newPos / $script:pageSize)
    if ($targetPage -ne $script:page) { $script:page = $targetPage; Render-Page }
    $idxInPage = $newPos - ($script:page * $script:pageSize)
    if ($idxInPage -ge 0 -and $idxInPage -lt $listView.Items.Count) {
        $listView.SelectedItems.Clear()
        $li = $listView.Items[$idxInPage]
        $li.Selected = $true
        $li.Focused = $true
        $li.EnsureVisible()
        Show-Item $li.Tag
    }
}

# ---------------- 后台建索引 ----------------
$script:queue = $null; $script:ps = $null; $script:rs = $null; $script:cts = $null
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 200

function Start-IndexBuild {
    param([bool]$Incremental = $true, [bool]$Quiet = $false)
    if ($script:building) { return }
    $script:building = $true
    $script:quietBuild = $Quiet
    $btnRebuild.Enabled = $false
    $btnFullRebuild.Enabled = $false
    $prog.Visible = -not $Quiet; $prog.Value = 0
    $script:building = $true
    $script:buildSw = [Diagnostics.Stopwatch]::StartNew()
    $script:queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:cts = New-Object System.Threading.CancellationTokenSource
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState='STA'; $rs.ThreadOptions='ReuseThread'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddCommand($WorkerPath)
    [void]$ps.AddParameter('Out', $script:queue)
    [void]$ps.AddParameter('Token', $script:cts.Token)
    [void]$ps.AddParameter('Root', $Root)
    [void]$ps.AddParameter('Threads', 4)
    [void]$ps.AddParameter('LibPath', $LibPath)
    [void]$ps.AddParameter('Incremental', $Incremental)
    $script:ps = $ps; $script:rs = $rs
    [void]$ps.BeginInvoke()
    $script:timer.Start()
}

$script:timer.add_Tick({
    if ($null -eq $script:queue) { return }
    $m = $null
    while ($script:queue.TryDequeue([ref]$m)) {
        switch ($m.Type) {
            'stage' { if ($m.Total -gt 0) { $prog.Maximum=[int]$m.Total; $prog.Value=[Math]::Min([int]$m.Done,[int]$m.Total) }
                      $lblPage.Text = ("{0} {1}/{2}" -f $m.Stage, $m.Done, $m.Total) }
            'info'  { if ($script:quietBuild) { } else { $lblPage.Text = $m.Text } }
            'error' { $lblPage.Text = '索引失败: ' + $m.Text }
            'done'  {
                $script:timer.Stop(); $prog.Visible = $false
                try { if ($script:ps) { [void]$script:ps.Stop() } } catch { }
                try { if ($script:rs) { $script:rs.Close(); $script:rs.Dispose() } } catch { }
                $script:ps = $null; $script:rs = $null
                $btnRebuild.Enabled = $true
                $btnFullRebuild.Enabled = $true
                $script:building = $false
                $changed = ([int]$m.Added + [int]$m.Modified + [int]$m.Removed)
                if ($script:quietBuild) {
                    if ($changed -gt 0) {
                        Load-Index | Out-Null
    Build-Groups
                        Update-FilterOptions; Apply-Filter
                        $lblPage.Text = ("索引已自动更新：新增 {0} · 修改 {1} · 移除 {2}（共 {3} 项）" -f $m.Added, $m.Modified, $m.Removed, $m.Count)
                    } else {
                        $lblPage.Text = ("索引已是最新，共 {0} 项（检查用时 {1:N1} 秒）" -f $m.Count, $script:buildSw.Elapsed.TotalSeconds)
                    }
                } else {
                    Load-Index | Out-Null
    Build-Groups
                    Update-FilterOptions; Apply-Filter
                    $lblPage.Text = ("索引完成：共 {0} 项（复用 {1} · 新增 {2} · 修改 {3} · 移除 {4}）" -f $m.Count, $m.Reused, $m.Added, $m.Modified, $m.Removed)
                }
            }
        }
    }
})

# ---------------- 事件 ----------------
$btnApply.Add_Click({ Apply-Filter })
$txtKey.Add_KeyDown({ if ($_.KeyCode -eq 'Return') { Apply-Filter } })
$cmbMark.Add_SelectedIndexChanged({ Apply-Filter })
$btnReset.Add_Click({
    $cmbCam.SelectedIndex = 0; $cmbYear.SelectedIndex = 0; $cmbMon.SelectedIndex = 0; $cmbMark.SelectedIndex = 0
    $txtKey.Text = ''
    Apply-Filter
})
$btnPrev.Add_Click({ if ($script:page -gt 0) { $script:page--; Render-Page } })
$btnNext.Add_Click({ $script:page++; Render-Page })
$btnRebuild.Add_Click({ Start-IndexBuild $true })
$btnFullRebuild.Add_Click({ Start-IndexBuild $false })

foreach ($b in $script:starButtons) {
    $b.Add_Click({
        $r = [int]$this.Tag
        Apply-ToSelection $r ''
    })
}
$btnKeep.Add_Click({ Apply-ToSelection -1 'keep' })
$btnReject.Add_Click({ Apply-ToSelection -1 'reject' })
$btnClear.Add_Click({ Apply-ToSelection 0 '' })

$listView.Add_SelectedIndexChanged({
    if ($listView.SelectedItems.Count -gt 0) {
        $it = $listView.SelectedItems[0].Tag
        $script:selPos = $script:page * $script:pageSize + $listView.SelectedItems[0].Index
        Show-Item $it
    }
})
$listView.Add_DoubleClick({
    if ($listView.SelectedItems.Count -gt 0) {
        $it = $listView.SelectedItems[0].Tag
        $full = Join-Path $Root $it.p
        if (Test-Path -LiteralPath $full) { Start-Process $full }
    }
})

$chkSplit.Add_CheckedChanged({
    $script:splitRaw = $chkSplit.Checked
    Build-Groups
    Apply-Filter
})

$btnOpenDir.Add_Click({
    if ($script:selected) {
        $full = Join-Path $Root $script:selected.p
        if (Test-Path -LiteralPath $full) { Start-Process explorer.exe ('/select,"' + $full + '"') }
    }
})

$btnDelete.Add_Click({
    if ($listView.SelectedItems.Count -eq 0) { return }
    $groups = @($listView.SelectedItems | ForEach-Object { $_.Tag })
    $fileCount = 0
    foreach ($g in $groups) { $fileCount += $g.Count }
    if ([System.Windows.Forms.MessageBox]::Show(("选中的 {0} 张照片共 {1} 个文件（含 RAW/JPG），全部移到回收站？`n（可在回收站还原）" -f $groups.Count, $fileCount), '确认', 'YesNo', 'Warning') -ne 'Yes') { return }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $removed = New-Object System.Collections.Generic.List[string]
    $failed = 0
    foreach ($g in $groups) {
        foreach ($m in $g.Members) {
            $full = Join-Path $Root $m.p
            try {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($full, 'OnlyErrorDialogs', 'SendToRecycleBin')
                $removed.Add($m.p)
            } catch { $failed++ }
        }
    }
    if ($removed.Count -gt 0) {
        foreach ($rp in $removed) { $script:marks.Remove($rp) }
        $script:marksDirty = $true
        $script:index = @($script:index | Where-Object { $removed -notcontains $_.p })
        Save-Index; Save-Marks
        Build-Groups
        Apply-Filter
        $lblPage.Text = ("已移入回收站 {0} 个文件，失败 {1}" -f $removed.Count, $failed)
    }
})

$btnDelRej.Add_Click({
    $rejects = @($script:marks.Keys | Where-Object { $script:marks[$_].f -eq 'reject' })
    if ($rejects.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('没有标记为"淘汰"的照片。','提示'); return }
    if ([System.Windows.Forms.MessageBox]::Show(("把 {0} 个「淘汰」文件移到回收站？`n（可在回收站还原）" -f $rejects.Count), '确认', 'YesNo', 'Warning') -ne 'Yes') { return }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $ok = 0
    foreach ($rp in $rejects) {
        $full = Join-Path $Root $rp
        if (-not (Test-Path -LiteralPath $full)) { continue }
        try {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($full, 'OnlyErrorDialogs', 'SendToRecycleBin')
            $script:marks.Remove($rp); $ok++
        } catch { }
    }
    $script:index = @($script:index | Where-Object { $script:marks.ContainsKey($_.p) -or (Test-Path -LiteralPath (Join-Path $Root $_.p)) })
    $script:marksDirty = $true
    Save-Index; Save-Marks
    Apply-Filter
    [void][System.Windows.Forms.MessageBox]::Show("已移入回收站 $ok 个", '完成')
})

$form.Add_KeyDown({
    switch ($_.KeyCode) {
        'Left'      { Move-Selection -1; $_.SuppressKeyPress = $true }
        'Right'     { Move-Selection 1;  $_.SuppressKeyPress = $true }
        'D0'        { Apply-ToSelection 0 '' }
        'D1'        { Apply-ToSelection 1 '' }
        'D2'        { Apply-ToSelection 2 '' }
        'D3'        { Apply-ToSelection 3 '' }
        'D4'        { Apply-ToSelection 4 '' }
        'D5'        { Apply-ToSelection 5 '' }
        'X'         { Apply-ToSelection -1 'reject' }
        'P'         { Apply-ToSelection -1 'keep' }
        'U'         { Apply-ToSelection 0 '' }
        'PageDown'  { $script:page++; Render-Page }
        'PageUp'    { if ($script:page -gt 0) { $script:page--; Render-Page } }
    }
})

$form.Add_FormClosing({ Save-Marks })

# ---------------- 启动 ----------------
Load-Marks
if (Load-Index) {
    Update-FilterOptions
    Apply-Filter
    $tip = if ($NoAutoCheck) { '' } else { '，正在检查文件变化...' }
    $lblPage.Text = ("已载入 {0} 项 / {1} 个文件{2}" -f $script:groups.Count, $script:index.Count, $tip)
    if (-not $NoAutoCheck) {
        $form.Add_Shown({
            Start-Sleep -Milliseconds 400
            Start-IndexBuild $true $true
        })
    }
} else {
    $form.Add_Shown({ Start-IndexBuild $true $false })
}

if ($GroupTest) {
    Build-Groups
    $multi = @($script:groups | Where-Object { $_.Count -gt 1 })
    Write-Host ("GT 总条目 {0} · 多文件组 {1}" -f $script:groups.Count, $multi.Count)
    if ($multi.Count -gt 0) {
        $g = $multi[0]
        Write-Host ("GT 样例: {0}  成员 {1} 个: {2}" -f $g.Base, $g.Count, (($g.Members | ForEach-Object { $_.n }) -join ' + '))
        foreach ($m in $g.Members) { Set-Mark $m.p 4 $null }
        $gm = Get-GroupMark $g
        Write-Host ("GT 打分后聚合星级 = {0}（应为 4）" -f $gm.r)
        Save-Marks
        foreach ($m in $g.Members) { Set-Mark $m.p 0 '' }
        Save-Marks
        $gm2 = Get-GroupMark $g
        Write-Host ("GT 清除后聚合星级 = {0}（应为 0）" -f $gm2.r)
    }
    $script:splitRaw = $true; Build-Groups
    Write-Host ("GT 分开显示模式条目 = {0}" -f $script:groups.Count)
    exit 0
}

if ($FilterTest) {
    Update-FilterOptions; Apply-Filter
    Write-Host ("FT total=" + $script:index.Count + " marks=" + $script:marks.Count)
    $cmbCam.SelectedItem = '01-D7200'; Apply-Filter; Write-Host ("FT cam=01-D7200 -> " + $script:filtered.Count)
    $cmbCam.SelectedIndex = 0; $cmbYear.SelectedItem='2026'; Apply-Filter; Write-Host ("FT year=2026 -> " + $script:filtered.Count)
    $cmbYear.SelectedIndex = 0; $cmbMon.SelectedItem='06'; Apply-Filter; Write-Host ("FT mon=06 -> " + $script:filtered.Count)
    $cmbMon.SelectedIndex = 0; $txtKey.Text='DSC_54'; Apply-Filter; Write-Host ("FT key -> " + $script:filtered.Count)
    $txtKey.Text=''; $cmbMark.SelectedItem='未评分'; Apply-Filter; Write-Host ("FT unscored -> " + $script:filtered.Count)
    exit 0
}

if ($MarksTest) {
    Update-FilterOptions; Apply-Filter
    $m1 = $script:index[0].p; $m2 = $script:index[1].p
    Set-Mark $m1 4 'keep'
    Set-Mark $m2 0 'reject'
    Save-Marks
    Write-Host ("MT 写入: {0}=4/keep, {1}=reject" -f $m1, $m2)
    $script:marks = @{}
    Load-Marks
    $a = Get-Mark $m1; $b = Get-Mark $m2
    Write-Host ("MT 回读: r={0} f={1} | r={2} f={3}" -f $a.r, $a.f, $b.r, $b.f)
    Write-Host ("MT 标记总数: " + $script:marks.Count)
    # 复原
    Set-Mark $m1 0 ''
    Set-Mark $m2 0 ''
    Save-Marks
    exit 0
}

if ($DumpImage) {
    $form.Add_Shown({
        $script:dumpTimer = New-Object System.Windows.Forms.Timer
        $script:dumpTimer.Interval = 1500
        $script:dumpTimer.add_Tick({
            $script:dumpTimer.Stop()
            try {
                $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
                $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0,0,$form.Width,$form.Height)))
                $bmp.Save($DumpImage, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
                Write-Host 'IMAGE_SAVED'
            } catch { Write-Host ('IMAGE_FAIL: ' + $_.Exception.Message) }
            $form.Close()
        })
        $script:dumpTimer.Start()
    })
}

[void]$form.ShowDialog()