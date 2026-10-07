# VMHost · 构建 guest 侧 IActivityController 控制器（方案 2）
# 产物：vmhost_amctl.jar（内含 classes.dex，供 app_process CLASSPATH 使用）
$ErrorActionPreference = 'Stop'
$root = 'k:\youlongsx\vm\build-aosp-exp'
$jdk  = 'C:\Program Files\Java\jdk-17'
$sdk  = 'C:\Users\liu\AppData\Local\Android\Sdk'
$d8   = "$sdk\build-tools\34.0.0\d8.bat"
$ajar = "$sdk\platforms\android-35\android.jar"

$outCls = "$root\amctl\classes"
$outDex = "$root\amctl\dex"
Remove-Item -Recurse -Force $outCls, $outDex -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $outCls, $outDex | Out-Null

Write-Host '== javac =='
& "$jdk\bin\javac.exe" -nowarn -encoding UTF-8 -source 8 -target 8 -cp $ajar -d $outCls "$root\amctl\vmhost\AmController.java"
if ($LASTEXITCODE -ne 0) { throw "javac failed" }
Get-ChildItem -Recurse $outCls | Select-Object -ExpandProperty FullName

Write-Host '== d8 =='
& $d8 --min-api 30 --lib $ajar --output $outDex "$outCls\vmhost\AmController.class" "$outCls\vmhost\AmController`$Ctl.class" "$outCls\vmhost\AmController`$1.class"
if ($LASTEXITCODE -ne 0) { throw "d8 failed" }

Write-Host '== jar =='
Push-Location $outDex
& "$jdk\bin\jar.exe" cf "$root\vmhost_amctl.jar" classes.dex
Pop-Location
if ($LASTEXITCODE -ne 0) { throw "jar failed" }

Write-Host '== result =='
& "$jdk\bin\jar.exe" tf "$root\vmhost_amctl.jar"
Get-Item "$root\vmhost_amctl.jar" | Select-Object FullName, Length
