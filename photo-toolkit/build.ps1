# 照片工具 - 构建脚本
# 用法: 右键"使用 PowerShell 运行"，或:
#   powershell -ExecutionPolicy Bypass -File .\build.ps1
#
# 产物: dist\照片工具\  和  dist\照片工具.zip

[CmdletBinding()]
param(
    [string]$OutputDir = '',
    [switch]$NoZip
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot 在部分环境(如 param 默认值)可能为空，做一次兜底
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutputDir) { $OutputDir = Join-Path $root 'dist' }
$dist = Join-Path $OutputDir '照片工具'
$app  = Join-Path $dist 'app'

Write-Host "== 照片工具 构建 ==" -ForegroundColor Cyan
Write-Host "输出目录: $dist"

# 清理
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Path $app -Force | Out-Null

# 1) 复制程序脚本(统一转 UTF-8 BOM，PowerShell 5.1 才能正确读中文)
Write-Host "`n[1/4] 复制脚本..." -ForegroundColor Yellow
$scripts = @(
    'PhotoImportGUI.ps1', 'PhotoCore.ps1', 'PhotoWorker.ps1',
    'PhotoManagerGUI.ps1', 'PhotoIndexWorker.ps1', 'PhotoLib.ps1'
)
foreach ($n in $scripts) {
    $srcFile = Join-Path $root ('src\app\' + $n)
    if (-not (Test-Path $srcFile)) { throw "缺少脚本: $srcFile" }
    $text = [IO.File]::ReadAllText($srcFile, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $app $n), $text, (New-Object Text.UTF8Encoding($true)))
    Write-Host "  + app\$n"
}

# 2) 编译启动器
Write-Host "`n[2/4] 编译启动器..." -ForegroundColor Yellow
$cs = Join-Path $root 'src\launcher\Launcher.cs'
if (-not (Test-Path $cs)) { throw "缺少启动器源码: $cs" }
$code = [IO.File]::ReadAllText($cs, [Text.Encoding]::UTF8)
$exe = Join-Path $dist '照片工具.exe'
Add-Type -TypeDefinition $code -OutputAssembly $exe -OutputType WindowsApplication `
    -ReferencedAssemblies 'System.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll'
Write-Host ("  + 照片工具.exe ({0:N0} KB)" -f ((Get-Item $exe).Length / 1KB))

# 3) 复制说明与默认配置
Write-Host "`n[3/4] 写入说明与配置..." -ForegroundColor Yellow
$readme = Join-Path $root 'docs\使用说明.txt'
if (Test-Path $readme) {
    $t = [IO.File]::ReadAllText($readme, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $dist '使用说明.txt'), $t, (New-Object Text.UTF8Encoding($true)))
    Write-Host "  + 使用说明.txt"
}

$defaultRoot = Join-Path ([Environment]::GetFolderPath('MyPictures')) '照片库'
$cfg = "; 照片工具配置`r`n; 照片库根目录（导入目标 + 浏览根目录）`r`nphotoRoot=$defaultRoot`r`n"
[IO.File]::WriteAllText((Join-Path $dist 'config.ini'), $cfg, (New-Object Text.UTF8Encoding($false)))
Write-Host "  + config.ini  (photoRoot=$defaultRoot)"

# 4) 打包
if (-not $NoZip) {
    Write-Host "`n[4/4] 打包 zip..." -ForegroundColor Yellow
    $zip = Join-Path $OutputDir '照片工具.zip'
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path $dist -DestinationPath $zip -CompressionLevel Optimal
    Write-Host ("  + 照片工具.zip ({0:N0} KB)" -f ((Get-Item $zip).Length / 1KB))
} else {
    Write-Host "`n[4/4] 跳过打包" -ForegroundColor Yellow
}

Write-Host "`n完成。双击 dist\照片工具\照片工具.exe 即可运行。" -ForegroundColor Green
