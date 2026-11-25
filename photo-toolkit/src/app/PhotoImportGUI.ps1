# 照片自动归档 - 图形界面 v2
# 优化: 工作线程与界面分离(不再卡死)、缓存 Shell 目录对象、快速判重、实时速度与剩余时间

param([switch]$SmokeTest, [string]$AutoTestCard, [string]$AutoTestOut, [string]$DumpImage, [int]$AutoTestThreads = 0, [string]$TargetRoot = "$env:USERPROFILE\Pictures\照片库")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$CorePath   = Join-Path $PSScriptRoot 'PhotoCore.ps1'
$WorkerPath = Join-Path $PSScriptRoot 'PhotoWorker.ps1'
. $CorePath

$DefaultTarget = $TargetRoot
$fontUI  = New-Object System.Drawing.Font('微软雅黑', 9)
$fontLog = New-Object System.Drawing.Font('Consolas', 8.5)

# ---------------- 界面 ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = '照片自动归档工具'
$form.Size = New-Object System.Drawing.Size(720, 700)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = $fontUI

$grpPath = New-Object System.Windows.Forms.GroupBox
$grpPath.Text = '路径'
$grpPath.Location = New-Object System.Drawing.Point(12, 10)
$grpPath.Size = New-Object System.Drawing.Size(680, 104)

$lblSrc = New-Object System.Windows.Forms.Label
$lblSrc.Text = '照片来源'; $lblSrc.Location = New-Object System.Drawing.Point(14, 28); $lblSrc.Size = New-Object System.Drawing.Size(64, 20)
$txtSrc = New-Object System.Windows.Forms.TextBox
$txtSrc.Location = New-Object System.Drawing.Point(82, 25); $txtSrc.Size = New-Object System.Drawing.Size(496, 24)
$btnSrc = New-Object System.Windows.Forms.Button
$btnSrc.Text = '浏览...'; $btnSrc.Location = New-Object System.Drawing.Point(586, 24); $btnSrc.Size = New-Object System.Drawing.Size(74, 26)

$lblDst = New-Object System.Windows.Forms.Label
$lblDst.Text = '照片库'; $lblDst.Location = New-Object System.Drawing.Point(14, 66); $lblDst.Size = New-Object System.Drawing.Size(64, 20)
$txtDst = New-Object System.Windows.Forms.TextBox
$txtDst.Location = New-Object System.Drawing.Point(82, 63); $txtDst.Size = New-Object System.Drawing.Size(496, 24); $txtDst.Text = $DefaultTarget
$btnDst = New-Object System.Windows.Forms.Button
$btnDst.Text = '浏览...'; $btnDst.Location = New-Object System.Drawing.Point(586, 62); $btnDst.Size = New-Object System.Drawing.Size(74, 26)

$grpPath.Controls.AddRange(@($lblSrc, $txtSrc, $btnSrc, $lblDst, $txtDst, $btnDst))

$grpOpt = New-Object System.Windows.Forms.GroupBox
$grpOpt.Text = '选项'
$grpOpt.Location = New-Object System.Drawing.Point(12, 120)
$grpOpt.Size = New-Object System.Drawing.Size(680, 106)

$rdoCopy = New-Object System.Windows.Forms.RadioButton
$rdoCopy.Text = '复制（保留卡上文件）'; $rdoCopy.Location = New-Object System.Drawing.Point(14, 22); $rdoCopy.Size = New-Object System.Drawing.Size(170, 22); $rdoCopy.Checked = $true
$rdoMove = New-Object System.Windows.Forms.RadioButton
$rdoMove.Text = '移动（清空卡）'; $rdoMove.Location = New-Object System.Drawing.Point(190, 22); $rdoMove.Size = New-Object System.Drawing.Size(130, 22)
$chkPreview = New-Object System.Windows.Forms.CheckBox
$chkPreview.Text = '仅预演（不动文件）'; $chkPreview.Location = New-Object System.Drawing.Point(330, 21); $chkPreview.Size = New-Object System.Drawing.Size(160, 22); $chkPreview.Checked = $true

$chkFast = New-Object System.Windows.Forms.CheckBox
$chkFast.Text = '快速判重（按大小+修改时间判定，跳过 MD5 校验）'
$chkFast.Location = New-Object System.Drawing.Point(14, 52); $chkFast.Size = New-Object System.Drawing.Size(400, 22); $chkFast.Checked = $true

$chkExif = New-Object System.Windows.Forms.CheckBox
$chkExif.Text = '读取 EXIF 拍摄时间（更准，较慢）'
$chkExif.Location = New-Object System.Drawing.Point(340, 50); $chkExif.Size = New-Object System.Drawing.Size(240, 22); $chkExif.Checked = $true

$lblTip = New-Object System.Windows.Forms.Label
$lblTip.Text = '提示：关闭 EXIF 更快；这块 USB 机械盘单线程最快，一般保持「自动(1)」'
$lblTip.Location = New-Object System.Drawing.Point(14, 78); $lblTip.Size = New-Object System.Drawing.Size(650, 20)
$lblTip.ForeColor = [System.Drawing.Color]::DimGray

$grpOpt.Controls.AddRange(@($rdoCopy, $rdoMove, $chkPreview, $chkFast, $chkExif, $lblTip))

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = '开始导入'; $btnStart.Location = New-Object System.Drawing.Point(12, 238); $btnStart.Size = New-Object System.Drawing.Size(120, 34)
$btnStart.Font = New-Object System.Drawing.Font('微软雅黑', 9, [System.Drawing.FontStyle]::Bold)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = '取消'; $btnCancel.Location = New-Object System.Drawing.Point(142, 238); $btnCancel.Size = New-Object System.Drawing.Size(90, 34); $btnCancel.Enabled = $false

$btnWatch = New-Object System.Windows.Forms.Button
$btnWatch.Text = '开始监听'; $btnWatch.Location = New-Object System.Drawing.Point(242, 238); $btnWatch.Size = New-Object System.Drawing.Size(100, 34)
$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = '停止监听'; $btnStop.Location = New-Object System.Drawing.Point(352, 238); $btnStop.Size = New-Object System.Drawing.Size(100, 34); $btnStop.Enabled = $false

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = '打开照片库'; $btnOpen.Location = New-Object System.Drawing.Point(582, 238); $btnOpen.Size = New-Object System.Drawing.Size(110, 34)

$lblThr = New-Object System.Windows.Forms.Label
$lblThr.Text = '并发'; $lblThr.Location = New-Object System.Drawing.Point(458, 245); $lblThr.Size = New-Object System.Drawing.Size(36, 20)

$cmbThreads = New-Object System.Windows.Forms.ComboBox
$cmbThreads.Location = New-Object System.Drawing.Point(494, 241); $cmbThreads.Size = New-Object System.Drawing.Size(78, 24)
$cmbThreads.DropDownStyle = 'DropDownList'
[void]$cmbThreads.Items.AddRange(@('自动(1)','1','2','4','8','16'))
$cmbThreads.SelectedIndex = 0

$prog = New-Object System.Windows.Forms.ProgressBar
$prog.Location = New-Object System.Drawing.Point(12, 282); $prog.Size = New-Object System.Drawing.Size(680, 16); $prog.Minimum = 0; $prog.Maximum = 100

$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Location = New-Object System.Drawing.Point(12, 306); $txtLog.Size = New-Object System.Drawing.Size(680, 314)
$txtLog.ReadOnly = $true; $txtLog.WordWrap = $false; $txtLog.Font = $fontLog
$txtLog.BackColor = [System.Drawing.Color]::White
$txtLog.ForeColor = [System.Drawing.Color]::Black
$txtLog.ScrollBars = 'Vertical'

$status = New-Object System.Windows.Forms.Label
$status.Text = '就绪。默认勾选「仅预演」，确认无误后取消勾选再点开始导入。'
$status.Location = New-Object System.Drawing.Point(12, 628); $status.Size = New-Object System.Drawing.Size(680, 20)

$form.Controls.AddRange(@($grpPath, $grpOpt, $btnStart, $btnCancel, $btnWatch, $btnStop, $btnOpen, $lblThr, $cmbThreads, $prog, $txtLog, $status))

# ---------------- 状态 ----------------
$script:queue = $null
$script:ps = $null
$script:handle = $null
$script:rs = $null
$script:cts = $null
$script:drain = New-Object System.Windows.Forms.Timer
$script:drain.Interval = 150
$script:total = 0
$script:doneCount = 0
$script:logLines = 0
$script:logCap = 6000
$script:running = $false
$script:watchTimers = @{}

$Colors = @{
    ok   = [System.Drawing.Color]::DarkGreen
    info = [System.Drawing.Color]::DimGray
    dim  = [System.Drawing.Color]::Silver
    warn = [System.Drawing.Color]::DarkGoldenrod
    skip = [System.Drawing.Color]::DarkGoldenrod
    err  = [System.Drawing.Color]::Red
    sys  = [System.Drawing.Color]::SteelBlue
}

function Set-Status([string]$t) { $status.Text = $t }

function Test-Inputs {
    $src = $txtSrc.Text.Trim().Trim('"')
    $dst = $txtDst.Text.Trim().Trim('"')
    if (-not $src) { [void][System.Windows.Forms.MessageBox]::Show('请先选择照片来源。','提示'); return $null }
    if (-not (Test-Path -LiteralPath $src)) { [void][System.Windows.Forms.MessageBox]::Show("来源路径不存在：`n$src",'提示'); return $null }
    if (-not $dst) { [void][System.Windows.Forms.MessageBox]::Show('请指定照片库位置。','提示'); return $null }
    return @{ Src=$src; Dst=$dst }
}

function Set-Busy([bool]$busy) {
    $script:running = $busy
    $btnStart.Enabled = -not $busy
    $btnWatch.Enabled = -not $busy
    $btnCancel.Enabled = $busy
    $chkPreview.Enabled = -not $busy
    $chkFast.Enabled = -not $busy
    $chkExif.Enabled = -not $busy
    $cmbThreads.Enabled = -not $busy
    $rdoCopy.Enabled = -not $busy
    $rdoMove.Enabled = -not $busy
}

function Start-Worker([string]$src, [string]$dst, [string]$mode) {
    $script:queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:cts = New-Object System.Threading.CancellationTokenSource
    $script:total = 0; $script:doneCount = 0

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'          # Shell COM 需要 STA
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $script:rs = $rs

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddCommand($WorkerPath)
    [void]$ps.AddParameter('Out', $script:queue)
    [void]$ps.AddParameter('Token', $script:cts.Token)
    [void]$ps.AddParameter('Source', $src)
    [void]$ps.AddParameter('TargetRoot', $dst)
    [void]$ps.AddParameter('Mode', $mode)
    [void]$ps.AddParameter('FastDedupe', $chkFast.Checked)
    [void]$ps.AddParameter('UseExif', $chkExif.Checked)
    [void]$ps.AddParameter('Threads', (Get-Threads))
    [void]$ps.AddParameter('CorePath', $CorePath)
    $script:ps = $ps
    $script:handle = $ps.BeginInvoke()
    $script:drain.Start()
}

function Stop-Worker {
    if ($script:cts) { try { $script:cts.Cancel() } catch { } }
}

function Cleanup-Worker {
    if ($script:drain) { $script:drain.Stop() }
    try { if ($script:ps) { [void]$script:ps.Stop() } } catch { }
    try { if ($script:rs) { $script:rs.Close(); $script:rs.Dispose() } } catch { }
    $script:ps = $null; $script:rs = $null; $script:handle = $null
}

function Format-Eta([double]$sec) {
    if ($sec -lt 60) { return ('{0:N0} 秒' -f $sec) }
    $m = [math]::Floor($sec / 60); $s = $sec - $m * 60
    return ('{0:N0} 分 {1:N0} 秒' -f $m, $s)
}

# ---------------- 消息轮询 ----------------
$script:drain.add_Tick({
    if ($null -eq $script:queue) { return }
    $msgs = New-Object System.Collections.Generic.List[object]
    $m = $null
    while ($msgs.Count -lt 400 -and $script:queue.TryDequeue([ref]$m)) { $msgs.Add($m) }

    $groups = @{}   # level -> list of text
    foreach ($msg in $msgs) {
        switch ($msg.Type) {
            'scan' {
                $script:total = [int]$msg.Total
                $prog.Maximum = [math]::Max(1, $script:total); $prog.Value = 0
                $groups['sys'] = @($groups['sys']) + ("发现 {0} 个文件" -f $script:total)
            }
            'log' {
                $lvl = [string]$msg.Level
                $shown = [string]$msg.Target
                if ($shown -and $txtDst.Text -and $shown.StartsWith($txtDst.Text.Trim())) {
                    $shown = $shown.Substring($txtDst.Text.Trim().Length).TrimStart('\')
                }
                $line = ("{0,-4} {1}  ->  {2}   [{3}]" -f $msg.Status, $msg.Name, $shown, $msg.Detail)
                $groups[$lvl] = @($groups[$lvl]) + $line
            }
            'progress' {
                $script:doneCount = [int]$msg.Done
                $prog.Value = [math]::Min($script:doneCount, $prog.Maximum)
                $spd = [double]$msg.Speed
                $eta = ''
                if ($spd -gt 0 -and $script:doneCount -gt 0 -and $script:doneCount -lt $script:total) {
                    $per = 0.0
                    $pct = $script:doneCount / [math]::Max(1,$script:total)
                    if ($pct -gt 0) { $elapsed = $spd } 
                    $avg = 0.0
                    if ($msg.Seconds -gt 0) { $avg = $script:doneCount / [double]$msg.Seconds }
                    if ($avg -gt 0) { $eta = ' · 预计剩余 ' + (Format-Eta (($script:total - $script:doneCount) / $avg)) }
                }
                Set-Status (("处理中 {0}/{1} · {2:N1} MB/s{3}" -f $script:doneCount, $script:total, $spd, $eta))
            }
            'fatal' {
                $groups['err'] = @($groups['err']) + ('严重错误: ' + $msg.Text)
            }
            'done' {
                $st = $msg.Stats
                $groups['sys'] = @($groups['sys']) + ("完成，用时 {0} 秒" -f $msg.Seconds)
                $groups['sys'] = @($groups['sys']) + ("归档 {0} · 已存在 {1} · 预演 {2} · 跳过 {3} · 失败 {4}" -f $st['已归档'], $st['已存在'], $st['预演'], $st['跳过'], $st['失败'])
                if ($msg.Cancelled) { $groups['warn'] = @($groups['warn']) + '已被用户取消' }
                $script:finishing = $true
                $script:lastStats = $st
                $script:wasCancelled = [bool]$msg.Cancelled
                $script:lastSeconds = $msg.Seconds
            }
        }
    }

    # 批量写日志(按颜色分组, 避免逐行设置颜色拖慢界面)
    foreach ($lvl in @('sys','ok','info','dim','skip','warn','err')) {
        if (-not $groups.ContainsKey($lvl)) { continue }
        $texts = $groups[$lvl]
        if (-not $texts -or $texts.Count -eq 0) { continue }
        if ($script:logLines -lt $script:logCap) {
            $txtLog.SelectionStart = $txtLog.TextLength
            $txtLog.SelectionLength = 0
            $txtLog.SelectionColor = $Colors[$lvl]
            $txtLog.AppendText((($texts -join "`r`n") + "`r`n"))
            $script:logLines += $texts.Count
            if ($script:logLines -ge $script:logCap) {
                $txtLog.SelectionColor = [System.Drawing.Color]::Red
                $txtLog.AppendText("...(显示已达上限, 完整记录见 导入日志.csv)`r`n")
            }
            $txtLog.SelectionStart = $txtLog.TextLength
            $txtLog.ScrollToCaret()
        }
    }

    if ($script:finishing) {
        $script:finishing = $false
        $script:drain.Stop()
        $st = $script:lastStats
        $prog.Value = $prog.Maximum
        Set-Status ("完成，用时 {0} 秒。归档 {1} · 已存在 {2} · 预演 {3} · 失败 {4}" -f $script:lastSeconds, $st['已归档'], $st['已存在'], $st['预演'], $st['失败'])
        Cleanup-Worker
        Set-Busy $false
        if ($AutoTestCard) {
            Write-Host ("AUTOTEST_DONE seconds={0} archived={1} existed={2} failed={3}" -f $script:lastSeconds, $st['已归档'], $st['已存在'], $st['失败'])
            $form.Close()
            return
        }
        if ($script:wasCancelled) {
            [void][System.Windows.Forms.MessageBox]::Show('已取消。已处理的文件不会回退。','已取消')
        } elseif ($chkPreview.Checked -and $st['预演'] -gt 0) {
            [void][System.Windows.Forms.MessageBox]::Show("预演完成，没有改动任何文件。`n`n确认无误后，取消勾选「仅预演」，再点「开始导入」。",'预演完成')
        }
    }
})

# ---------------- 事件 ----------------
function Get-Threads {
    if ($cmbThreads.SelectedIndex -le 0) { return 1 }
    return [int]$cmbThreads.SelectedItem
}
$btnSrc.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择照片来源（存储卡根目录或 DCIM）'
    if ($dlg.ShowDialog() -eq 'OK') { $txtSrc.Text = $dlg.SelectedPath }
})

$btnDst.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择照片库位置'
    if ($dlg.ShowDialog() -eq 'OK') { $txtDst.Text = $dlg.SelectedPath }
})

$btnOpen.Add_Click({
    $d = $txtDst.Text.Trim().Trim('"')
    if (Test-Path -LiteralPath $d) { Start-Process explorer.exe $d }
})

$btnStart.Add_Click({
    if ($script:running) { return }
    $in = Test-Inputs
    if ($null -eq $in) { return }
    $mode = if ($chkPreview.Checked) { 'Preview' } elseif ($rdoMove.Checked) { 'Move' } else { 'Copy' }

    $txtLog.Clear(); $script:logLines = 0
    $txtLog.SelectionColor = $Colors['sys']
    $txtLog.AppendText(("来源: {0}`r`n照片库: {1}`r`n模式: {2}`r`n" -f $in.Src, $in.Dst, $(switch ($mode) { 'Preview' { '预演（不改动文件）' } 'Copy' { '复制' } 'Move' { '移动' } })))
    Set-Busy $true
    Set-Status '正在扫描...'
    Start-Worker $in.Src $in.Dst $mode
})

$btnCancel.Add_Click({
    if (-not $script:running) { return }
    $btnCancel.Enabled = $false
    Set-Status '正在取消...'
    Stop-Worker
})

$btnWatch.Add_Click({
    $in = Test-Inputs
    if ($null -eq $in) { return }
    Set-Busy $true
    $btnStart.Enabled = $false; $btnWatch.Enabled = $false; $btnStop.Enabled = $true; $btnCancel.Enabled = $false
    $chkPreview.Checked = $false; $chkPreview.Enabled = $false
    Set-Status '监听中：每 5 秒检查一次，新文件稳定后自动归档。'
    $txtLog.SelectionColor = $Colors['sys']
    $txtLog.AppendText(("`r`n开始监听: {0}`r`n" -f $in.Src))

    $script:watchSeen = @{}
    $wt = New-Object System.Windows.Forms.Timer
    $wt.Interval = 5000
    $wt.add_Tick({
        if ($script:watchBusy) { return }
        $script:watchBusy = $true
        try {
            $src = $txtSrc.Text.Trim().Trim('"'); $dst = $txtDst.Text.Trim().Trim('"')
            if (-not (Test-Path -LiteralPath $src)) { return }
            $mode = if ($rdoMove.Checked) { 'Move' } else { 'Copy' }
            foreach ($f in (Get-PhotoMediaFiles -Source $src -TargetRoot $dst)) {
                $k = $f.FullName
                $prev = $script:watchSeen[$k]
                if ($null -eq $prev) { $script:watchSeen[$k] = @{ Len = $f.Length; At = Get-Date }; continue }
                if ($prev.Len -ne $f.Length) { $script:watchSeen[$k] = @{ Len = $f.Length; At = Get-Date }; continue }
                if (((Get-Date) - $prev.At).TotalSeconds -lt 5) { continue }
                $r = Invoke-PhotoImport -File $f -TargetRoot $dst -Mode $mode -FastDedupe $chkFast.Checked -UseExif $chkExif.Checked
                $rel = $r.Target
                if ($rel -and $dst -and $rel.StartsWith($dst)) { $rel = $rel.Substring($dst.Length).TrimStart('\') }
                $lvl = if ($r.Status -eq '失败') { 'err' } elseif ($r.Status -eq '已存在') { 'dim' } else { 'ok' }
                $txtLog.SelectionColor = $Colors[$lvl]
                $txtLog.AppendText(("[{0}] {1}  ->  {2}   [{3}]`r`n" -f (Get-Date).ToString('HH:mm:ss'), $f.Name, $rel, $r.Status))
                $txtLog.SelectionStart = $txtLog.TextLength; $txtLog.ScrollToCaret()
                $script:watchSeen.Remove($k)
            }
        } finally { $script:watchBusy = $false }
    })
    $script:watchTimers['t'] = $wt
    $wt.Start()
})

$btnStop.Add_Click({
    if ($script:watchTimers.ContainsKey('t')) { $script:watchTimers['t'].Stop() }
    $script:watchTimers = @{}
    $chkPreview.Enabled = $true
    Set-Busy $false
    $btnStop.Enabled = $false
    Set-Status '监听已停止。'
    $txtLog.SelectionColor = $Colors['warn']
    $txtLog.AppendText("监听已停止。`r`n")
})

$form.Add_FormClosing({
    Stop-Worker
    foreach ($k in @($script:watchTimers.Keys)) { try { $script:watchTimers[$k].Stop() } catch { } }
})

# ---------------- 测试钩子 ----------------
if ($SmokeTest) {
    $form.Add_Shown({
        $script:smokeTimer = New-Object System.Windows.Forms.Timer
        $script:smokeTimer.Interval = 500
        $script:smokeTimer.add_Tick({ $script:smokeTimer.Stop(); Write-Host 'GUI_SMOKETEST_OK'; $form.Close() })
        $script:smokeTimer.Start()
    })
}

if ($AutoTestCard) {
    $form.Add_Shown({
        $txtSrc.Text = $AutoTestCard
        if ($AutoTestOut) { $txtDst.Text = $AutoTestOut }
        if ($AutoTestThreads -gt 0) { $cmbThreads.SelectedItem = [string]$AutoTestThreads }
        $chkPreview.Checked = $false
        $btnStart.PerformClick()
    })
}

if ($DumpImage) {
    $form.Add_Shown({
        $script:dumpTimer = New-Object System.Windows.Forms.Timer
        $script:dumpTimer.Interval = 800
        $script:dumpTimer.add_Tick({
            $script:dumpTimer.Stop()
            try {
                $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
                $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
                $bmp.Save($DumpImage, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
                Write-Host 'IMAGE_SAVED'
            } catch { Write-Host ('IMAGE_FAIL: ' + $_.Exception.Message) }
            $form.Close()
        })
        $script:dumpTimer.Start()
    })
}

[void]$form.ShowDialog()
