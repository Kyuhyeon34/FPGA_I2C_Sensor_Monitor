param([string]$VivadoBin = 'C:\Xilinx\Vivado\2020.2\bin')
$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
    Copy-Item -LiteralPath (Join-Path $projectDir 'assets\slowpoke-frames.hex') -Destination $buildDir -Force
    $rtl = Join-Path $projectDir 'src'
    $sim = Join-Path $projectDir 'sim'
    $files = @(Get-ChildItem -LiteralPath $rtl -Filter '*.v' | ForEach-Object FullName)
    $files += @(Get-ChildItem -LiteralPath $sim -Filter '*.sv' | ForEach-Object FullName)
    $files += @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'reference_slave') -Filter '*.v' | ForEach-Object FullName)
    & (Join-Path $VivadoBin 'xvlog.bat') --sv @files
    if ($LASTEXITCODE) { throw 'xvlog failed' }
    foreach ($test in @('tb_i2c_master', 'tb_top', 'tb_oled', 'tb_top_polling', 'tb_top_polling_fast')) {
        & (Join-Path $VivadoBin 'xelab.bat') "work.$test" -s "${test}_sim"
        if ($LASTEXITCODE) { throw "xelab failed: $test" }
        # XSim can return exit code zero after $fatal. Check its output too.
        $result = & (Join-Path $VivadoBin 'xsim.bat') "${test}_sim" -runall 2>&1
        $result | ForEach-Object { Write-Output $_ }
        if ($LASTEXITCODE -or ($result -match 'Fatal:|ERROR:') -or
            !($result -match "PASS: .*${test}")) {
            throw "Simulation failed: $test"
        }
    }
} finally { Pop-Location }
