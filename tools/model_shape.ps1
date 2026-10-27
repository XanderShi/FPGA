$ErrorActionPreference = 'Stop'

# Reference model for shape_recognizer.v.
# Reproduces the exact per-frame aggregation: bounding box, per-row run sum,
# fill ratio and the three threshold comparisons, on synthetic edge images.
#
# Run at 640x480 with the ROI scaled to match the 1280x720 480x360 defaults so
# the loop count stays small; the ratio math is resolution independent.

$W = 640; $H = 480
$RX0 = 200; $RX1 = 439      # central 480x360 ROI, scaled to 640x480
$RY0 = 120; $RY1 = 299

$RECT_Q  = 230
$CIRC_Q  = 168
$TRI_Q   = 96
$MIN_EDGE = 200

function Classify($ratio_q, $edge) {
  if ($edge -lt $MIN_EDGE) { return 'NONE(未识别)' }
  if ($ratio_q -ge $RECT_Q) { return 'RECT(矩形)' }
  if ($ratio_q -ge $CIRC_Q) { return 'CIRCLE(圆形)' }
  if ($ratio_q -ge $TRI_Q)  { return 'TRI(三角形)' }
  return 'NONE(未识别)'
}

# Cases: kind, geometry, stroke thickness in pixels
$cases = @()
foreach ($t in 1, 2, 3) {
  $cases += ,@{ n = "circle r=90 t=$t";  kind = 'circle'; cx = 320; cy = 210; r = 90;   th = $t }
  $cases += ,@{ n = "circle r=55 t=$t";  kind = 'circle'; cx = 320; cy = 210; r = 55;   th = $t }
  $cases += ,@{ n = "rect 200x140 t=$t"; kind = 'rect';   cx = 320; cy = 210; hw = 100; hh = 70; th = $t }
  $cases += ,@{ n = "rect 120x120 t=$t"; kind = 'rect';   cx = 320; cy = 210; hw = 60;  hh = 60; th = $t }
  $cases += ,@{ n = "tri 200x150 t=$t";  kind = 'tri';    cx = 320; cy = 210; hw = 100; hh = 75; th = $t }
}
# negative control: scattered noise, no coherent outline
$cases += ,@{ n = 'noise (no shape)'; kind = 'noise' }

Write-Output ("{0,-22} {1,10} {2,10} {3,8} {4,8}  {5}" -f 'case', 'edge', 'area', 'boxWxH', 'ratio_q', 'verdict')
Write-Output ('-' * 90)

foreach ($c in $cases) {
  $minx = 99999; $maxx = -1; $miny = 99999; $maxy = -1
  $edge = 0; $fill = 0
  $rng = New-Object System.Random 12345

  for ($y = $RY0; $y -le $RY1; $y++) {
    $first = -1; $last = -1
    for ($x = $RX0; $x -le $RX1; $x++) {
      $on = $false
      switch ($c.kind) {
        'circle' {
          $dx = $x - $c.cx; $dy = $y - $c.cy
          $d = [math]::Sqrt(($dx * $dx) + ($dy * $dy))
          if ([math]::Abs($d - $c.r) -lt $c.th) { $on = $true }
          # outer/inner boundary of a thick stroke
          if ($c.th -gt 1 -and $d -ge ($c.r - $c.th) -and $d -le ($c.r + $c.th)) { $on = $true }
        }
        'rect' {
          $ax = [math]::Abs($x - $c.cx); $ay = [math]::Abs($y - $c.cy)
          if ($ax -le $c.hw -and $ay -le $c.hh) {
            if (($c.hw - $ax) -lt $c.th -or ($c.hh - $ay) -lt $c.th) { $on = $true }
          }
        }
        'tri' {
          $top = $c.cy - $c.hh; $bot = $c.cy + $c.hh
          if ($y -ge $top -and $y -le $bot) {
            $frac = ($y - $top) / ($bot - $top)      # 0 at apex, 1 at base
            $lx = $c.cx - ($c.hw * $frac)
            $rx = $c.cx + ($c.hw * $frac)
            if ([math]::Abs($x - $lx) -lt $c.th -or [math]::Abs($x - $rx) -lt $c.th) { $on = $true }
            # base edge spans only the triangle, not the whole ROI row
            if ((($bot - $y) -lt $c.th) -and ($x -ge ($lx - $c.th)) -and ($x -le ($rx + $c.th))) { $on = $true }
          }
        }
        'noise' {
          if ($rng.Next(1000) -lt 3) { $on = $true }
        }
      }

      if ($on) {
        $edge++
        if ($first -lt 0) { $first = $x }
        $last = $x
        if ($x -lt $minx) { $minx = $x }
        if ($x -gt $maxx) { $maxx = $x }
        if ($y -lt $miny) { $miny = $y }
        if ($y -gt $maxy) { $maxy = $y }
      }
    }
    if ($first -ge 0) { $fill += ($last - $first + 1) }
  }

  if ($maxx -lt 0) {
    Write-Output ("{0,-22} {1,10} {2,10} {3,8} {4,8}  {5}" -f $c.n, $edge, $fill, '-', '-', 'NONE(未识别)')
    continue
  }

  $bw = $maxx - $minx + 1
  $bh = $maxy - $miny + 1
  $box = $bw * $bh
  $ratio_q = [int][math]::Floor(($fill * 256) / $box)
  $verdict = Classify $ratio_q $edge
  Write-Output ("{0,-22} {1,10} {2,10} {3,8} {4,8}  {5}" -f $c.n, $edge, $fill, "$bw x $bh", $ratio_q, $verdict)
}
