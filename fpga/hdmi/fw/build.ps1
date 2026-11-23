$ErrorActionPreference='Continue'
Set-Location C:\dev\xcap\hdmi
if(!(Test-Path bspx)){ tar.exe -xzf bspx.tgz }
$gcc='C:\AMDDesignTools\2026.2\gnu\microblaze\nt\bin\mb-gcc.exe'
$size='C:\AMDDesignTools\2026.2\gnu\microblaze\nt\bin\mb-size.exe'
$obj='C:\dev\xcap\hdmi\obj'; New-Item -ItemType Directory -Force $obj | Out-Null
$cf='-c','-Os','-std=gnu11','-ffunction-sections','-fdata-sections','-mlittle-endian','-mcpu=v11.0','-mno-xl-soft-mul','-mno-xl-soft-div','-mxl-barrel-shift','-mxl-pattern-compare','-Wno-implicit-function-declaration','-Wno-int-conversion','-Wno-incompatible-pointer-types','-Ifw','-Ibspx/include','-D__MICROBLAZE__'
$src=Get-ChildItem -Path bspx -File -Recurse | Where-Object { ($_.Extension -ceq '.c' -or $_.Extension -ceq '.S') -and $_.Name -notlike '._*' -and $_.FullName -notmatch '\\(profile|clocking|common|intr|microblaze)\\' -and $_.FullName -notmatch 'generic_v|\\_exit\.c|xil_test|_selftest\.c|cpu_v2|\\outbyte\.c' }
$src=@($src)+@(Get-ChildItem fw\main.c,fw\tx.c,fw\dp159.c,fw\idt_8t49n24x.c,fw\iic_safe.c,fw\logring.c)
$fail=0; $objs=@()
foreach($f in $src){ $o="$obj\$($f.Directory.Parent.Name)_$($f.Name).o"; $inc="-I$($f.DirectoryName)"; & $gcc @cf $inc $f.FullName -o $o 2> "$o.log"; if($LASTEXITCODE){ $fail++; "FAIL $($f.Name)"; Get-Content "$o.log" | Select-String 'error' | Select-Object -First 4 | ForEach-Object Line } else { $objs+=$o } }
"compiled $($objs.Count) failed $fail"
$rsp="$obj\link.rsp"; ($objs | ForEach-Object { $_ -replace '\\','/' }) -join "`n" | Set-Content -Encoding ascii $rsp
& $gcc '-mlittle-endian' '-mcpu=v11.0' '-mno-xl-soft-mul' '-mno-xl-soft-div' '-mxl-barrel-shift' '-mxl-pattern-compare' '-nodefaultlibs' '-Wl,--gc-sections' '-Wl,-T,fw/lscript.ld' "@$rsp" '-Wl,--start-group,-lc,-lgloss,-lgcc,--end-group' -o hdmi_fw.elf 2> link.log; Get-Content link.log | Select-Object -First 25
& $size hdmi_fw.elf
