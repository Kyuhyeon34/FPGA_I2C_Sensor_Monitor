# Render actual XSim SDA/SCL edges as a clean three-panel scope image.
param(
    [string]$BuildDir = (Join-Path $PSScriptRoot 'build'),
    [string]$PngPath = (Join-Path $PSScriptRoot '..\assets\i2c_scope.png')
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$captures=@(Import-Csv -LiteralPath (Join-Path $BuildDir 'i2c_scope_captures.csv'))
$edges=@(Import-Csv -LiteralPath (Join-Path $BuildDir 'i2c_scope_edges.csv') |
    Where-Object { $_.scl -in @('0','1') -and $_.sda -in @('0','1') })
$bytes=@(Import-Csv -LiteralPath (Join-Path $BuildDir 'i2c_scope_bytes.csv'))
if($captures.Count -ne 3){throw 'Run the updated tb_i2c_scope first (three sensor captures).'}
$bitmap=[Drawing.Bitmap]::new(1500,1020)
$graphics=[Drawing.Graphics]::FromImage($bitmap)
$font=[Drawing.Font]::new('Consolas',13)
$titleFont=[Drawing.Font]::new('Consolas',18,[Drawing.FontStyle]::Bold)
$small=[Drawing.Font]::new('Consolas',11)
$white=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(225,235,250))
$muted=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(155,175,195))
$yellow=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(250,204,21))
$cyan=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(34,211,238))
$grid=[Drawing.Pen]::new([Drawing.Color]::FromArgb(32,46,65),1)
$clockPen=[Drawing.Pen]::new($yellow.Color,2)
$dataPen=[Drawing.Pen]::new($cyan.Color,2)
$box=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(24,47,69))
try {
    $graphics.Clear([Drawing.Color]::FromArgb(8,13,20))
    $graphics.DrawString('I2C SENSOR CAPTURES  |  SCL = 100 kHz',$titleFont,$white,24,16)
    $graphics.DrawString('Recorded digital bus edges; voltage labels are logic-level equivalents.',$small,$muted,26,48)
    $panel=0
    foreach($capture in $captures){
        $top=82+$panel*300
        $left=150.0; $width=1310.0
        $begin=[double]$capture.start_ns-5000
        $end=[double]$capture.end_ns+5000
        $span=$end-$begin
        $sensor=switch([int]$capture.sensor){
            1 { 'TEMPERATURE '+$capture.value+'.'+$capture.fraction+' C' }
            2 { 'HUMIDITY '+$capture.value+' %' }
            3 { 'DISTANCE '+$capture.value+' cm' }
        }
        $packet='84 A  '+$capture.register.ToUpper()+' A  Sr 85 A  '+$capture.byte0.ToUpper()+' A  '+$capture.byte1.ToUpper()+' N'
        $graphics.DrawString($sensor,$titleFont,$white,24,$top)
        $graphics.DrawString('S  '+$packet+'  P',$font,$muted,630,$top+3)
        foreach($division in 0..10){
            $x=[single]($left+$width*$division/10)
            $graphics.DrawLine($grid,$x,[single]($top+35),$x,[single]($top+214))
            $time=($begin+$span*$division/10-[double]$capture.start_ns)/1000
            $graphics.DrawString(('{0:0}' -f $time),$small,$muted,$x-12,[single]($top+214))
        }
        foreach($offset in @(50,90,140,180)){
            $graphics.DrawLine($grid,[single]$left,[single]($top+$offset),[single]($left+$width),[single]($top+$offset))
        }
        $graphics.DrawString('CH1 SCL',$font,$yellow,24,$top+52)
        $graphics.DrawString('CH2 SDA',$font,$cyan,24,$top+142)
        $graphics.DrawString('3.3V',$small,$muted,92,$top+40)
        $graphics.DrawString('0V',$small,$muted,110,$top+79)
        $graphics.DrawString('3.3V',$small,$muted,92,$top+130)
        $graphics.DrawString('0V',$small,$muted,110,$top+169)
        foreach($signal in @('scl','sda')){
            $high=if($signal -eq 'scl'){$top+50}else{$top+140}
            $low=$high+40
            $pen=if($signal -eq 'scl'){$clockPen}else{$dataPen}
            $level=1
            foreach($edge in $edges){if([double]$edge.time_ns -le $begin){$level=[int]$edge.$signal}else{break}}
            $xPrevious=$left
            foreach($edge in $edges){
                $time=[double]$edge.time_ns
                if($time -le $begin){continue}
                if($time -gt $end){break}
                $next=[int]$edge.$signal
                if($next -eq $level){continue}
                $x=$left+($time-$begin)*$width/$span
                $y=if($level){$high}else{$low}
                $yNext=if($next){$high}else{$low}
                $graphics.DrawLine($pen,[single]$xPrevious,[single]$y,[single]$x,[single]$y)
                $graphics.DrawLine($pen,[single]$x,[single]$y,[single]$x,[single]$yNext)
                $xPrevious=$x; $level=$next
            }
            $y=if($level){$high}else{$low}
            $graphics.DrawLine($pen,[single]$xPrevious,[single]$y,[single]($left+$width),[single]$y)
        }
        foreach($byte in @($bytes | Where-Object capture -eq $capture.capture)){
            $x=$left+([double]$byte.start_ns-$begin)*$width/$span
            $w=([double]$byte.end_ns-[double]$byte.start_ns)*$width/$span
            $ack=if($byte.ack -eq '1'){'ACK'}else{'NACK'}
            $label=$byte.phase+' '+$byte.hex.ToUpper()+' '+$ack
            $graphics.FillRectangle($box,[single]$x,[single]($top+244),[single]$w,27)
            $graphics.DrawString($label,$small,$white,[single]($x+5),[single]($top+249))
        }
        $panel++
    }
    $graphics.DrawString('A = ACK (SDA=0)   N = final Master NACK (SDA=1)   S = START   P = STOP   time: us',$small,$muted,25,995)
    $destination=[IO.Path]::GetFullPath($PngPath)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
    $bitmap.Save($destination,[Drawing.Imaging.ImageFormat]::Png)
    Write-Output "PASS: scope image: $destination"
} finally {
    foreach($resource in @($box,$grid,$clockPen,$dataPen,$white,$muted,$yellow,$cyan,$font,$titleFont,$small,$graphics,$bitmap)){$resource.Dispose()}
}
