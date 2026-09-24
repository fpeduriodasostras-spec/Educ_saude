$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$dir = 'C:\Users\meleo\AppData\Local\Temp\claude\C--Users-meleo--claude\0d52cde6-d1ea-4983-95d8-3d5164ad08fc\scratchpad\medicoes'

function P([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  return [double]::Parse($s.Trim(), $inv)
}

# itens[key] = hashtable com dados; ordem preservada pela MED09 (e apendice p/ chaves so em meds antigas)
$itens = [ordered]@{}
$vazios = New-Object System.Collections.ArrayList

for ($m = 1; $m -le 9; $m++) {
  $f = Join-Path $dir ("med0{0}_itens.csv" -f $m)
  $lines = Get-Content -Path $f -Encoding UTF8
  for ($i = 15; $i -lt $lines.Count; $i++) {
    $c = $lines[$i] -split ';'
    if ($c.Count -lt 15) { continue }
    $cod = $c[1].Trim(); $desc = $c[2].Trim()
    if ($cod -eq '' -or $desc -eq '') { continue }   # secao, vazias, totais
    $key = "$cod|$desc"
    if (-not $itens.Contains($key)) {
      $itens[$key] = @{
        item=''; cod=$cod; desc=$desc; unid=''; qtd=$null; preco=$null
        per = @(0,0,0,0,0,0,0,0,0,0)  # indice 1..9
        acumAnt9 = $null; medPresente = @()
      }
    }
    $it = $itens[$key]
    # item/unid/qtd/preco: sempre sobrescreve -> fica o da medicao mais recente (MED09 quando existe)
    if ($c[0].Trim() -ne '') { $it.item = $c[0].Trim() }
    if ($c[3].Trim() -ne '') { $it.unid = $c[3].Trim() }
    $q = P $c[4]; if ($q -ne $null) { $it.qtd = $q }
    $pb = P $c[6]; if ($pb -ne $null) { $it.preco = $pb }
    $per = P $c[8]
    if ($per -eq $null) { $per = 0 }
    $it.per[$m] = $per
    $it.medPresente += $m
    if ($m -eq 9) { $it.acumAnt9 = P $c[10] }
    if ($c[8].Trim() -eq '' ) { [void]$vazios.Add("MED0${m}: $cod ($($it.item)) periodo vazio -> tratado como 0") }
  }
}

# ---- gera SALDO-POR-ITEM.csv ----
$out = New-Object System.Collections.Generic.List[string]
$out.Add('item;codigo_emop;descricao;unid;qtd_contratada;med01;med02;med03;med04;med05;med06;med07;med08;med09;acumulado;saldo;pct_consumido')
function N($v) { if ($v -eq $null) { return '' } return $v.ToString('0.####', $inv) }
foreach ($it in $itens.Values) {
  $acum = 0; for ($m=1;$m -le 9;$m++){ $acum += $it.per[$m] }
  $it.acum = [math]::Round($acum, 4)
  if ($it.qtd -ne $null) { $it.saldo = [math]::Round($it.qtd - $acum, 4) } else { $it.saldo = $null }
  if ($it.qtd -ne $null -and $it.qtd -ne 0) { $it.pct = [math]::Round($acum / $it.qtd, 4) } else { $it.pct = $null }
  $desc2 = $it.desc -replace ';', ','
  $row = @($it.item, $it.cod, $desc2, $it.unid, (N $it.qtd))
  for ($m=1;$m -le 9;$m++){ $row += (N $it.per[$m]) }
  $row += (N $it.acum); $row += (N $it.saldo); $row += (N $it.pct)
  $out.Add(($row -join ';'))
}
$outPath = Join-Path $dir 'SALDO-POR-ITEM.csv'
[System.IO.File]::WriteAllLines($outPath, $out, (New-Object System.Text.UTF8Encoding($true)))
Write-Output ("ARQUIVO GERADO: $outPath  ITENS: " + $itens.Count)

# ---- validacao da cadeia: acumAnt9 vs soma med01..08 ----
Write-Output "`n=== VALIDACAO CADEIA (MED09 acum.anterior vs soma MED01..08) ==="
$divs = 0
foreach ($it in $itens.Values) {
  $s8 = 0; for ($m=1;$m -le 8;$m++){ $s8 += $it.per[$m] }
  $s8 = [math]::Round($s8,4)
  if ($it.acumAnt9 -ne $null) {
    $d = [math]::Round($it.acumAnt9 - $s8, 3)
    if ([math]::Abs($d) -gt 0.01) {
      $divs++
      if ($divs -le 40) { Write-Output ("DIVERGE: {0} ({1}) soma01-08={2} acumAnt09={3} dif={4}" -f $it.cod, $it.item, (N $s8), (N $it.acumAnt9), (N $d)) }
    }
  } elseif (($s8 -ne 0)) {
    Write-Output ("SEM ACUM NA MED09 (item sumiu): {0} soma01-08={1}" -f $it.cod, (N $s8))
  }
}
Write-Output "TOTAL DIVERGENTES: $divs de $($itens.Count)"

# checagem dirigida de 5 itens com movimento
Write-Output "`n=== 5 ITENS CONFERIDOS ==="
$check = @('20069','20155','19.004.0001-C','17.018.0031-A','20030')
foreach ($cod in $check) {
  $it = $itens.Values | Where-Object { $_.cod -eq $cod } | Select-Object -First 1
  if ($it -eq $null) { Write-Output "nao achei $cod"; continue }
  $s8 = 0; for ($m=1;$m -le 8;$m++){ $s8 += $it.per[$m] }
  Write-Output ("{0} ({1}): soma01-08={2} | acumAnt MED09={3} | ok={4}" -f $it.cod, $it.item, (N ([math]::Round($s8,4))), (N $it.acumAnt9), ([math]::Abs($it.acumAnt9 - $s8) -le 0.01))
}

# ---- numeros-chave ----
Write-Output "`n=== NUMEROS-CHAVE ==="
$comQtd = @($itens.Values | Where-Object { $_.qtd -ne $null })
$esgot = @($comQtd | Where-Object { $_.saldo -le 0 -and $_.acum -gt 0 })
$acima80 = @($comQtd | Where-Object { $_.pct -ne $null -and $_.pct -ge 0.8 -and $_.saldo -gt 0 })
Write-Output ("ITENS ESGOTADOS (saldo<=0): " + $esgot.Count)
foreach ($it in ($esgot | Sort-Object {$_.pct} -Descending)) { Write-Output ("  {0} ({1}) [{2}] pct={3} saldo={4} {5} | {6}" -f $it.cod,$it.item,$it.unid,(N $it.pct),(N $it.saldo),$it.unid,($it.desc.Substring(0,[math]::Min(70,$it.desc.Length)))) }
Write-Output ("`nITENS ENTRE 80% E 100%: " + $acima80.Count)
foreach ($it in ($acima80 | Sort-Object {$_.pct} -Descending)) { Write-Output ("  {0} ({1}) [{2}] pct={3} saldo={4} | {5}" -f $it.cod,$it.item,$it.unid,(N $it.pct),(N $it.saldo),($it.desc.Substring(0,[math]::Min(70,$it.desc.Length)))) }

# saldos em R$
foreach ($it in $itens.Values) {
  if ($it.saldo -ne $null -and $it.preco -ne $null) { $it.saldoRS = [math]::Round($it.saldo * $it.preco, 2) } else { $it.saldoRS = $null }
}
$top10 = $itens.Values | Where-Object { $_.saldoRS -ne $null } | Sort-Object {$_.saldoRS} -Descending | Select-Object -First 10
Write-Output "`nTOP 10 MAIORES SALDOS EM R$ :"
foreach ($it in $top10) { Write-Output ("  {0} ({1}) saldoQtd={2} {3} x R$ {4} = R$ {5} | {6}" -f $it.cod,$it.item,(N $it.saldo),$it.unid,(N $it.preco),$it.saldoRS.ToString('N2',$inv),($it.desc.Substring(0,[math]::Min(60,$it.desc.Length)))) }

$saldoTotal = ($itens.Values | Where-Object { $_.saldoRS -ne $null } | ForEach-Object { $_.saldoRS } | Measure-Object -Sum).Sum
$saldoPos = ($itens.Values | Where-Object { $_.saldoRS -ne $null -and $_.saldoRS -gt 0 } | ForEach-Object { $_.saldoRS } | Measure-Object -Sum).Sum
$saldoNeg = ($itens.Values | Where-Object { $_.saldoRS -ne $null -and $_.saldoRS -lt 0 } | ForEach-Object { $_.saldoRS } | Measure-Object -Sum).Sum
$contratado = ($itens.Values | Where-Object { $_.qtd -ne $null -and $_.preco -ne $null } | ForEach-Object { $_.qtd * $_.preco } | Measure-Object -Sum).Sum
Write-Output ("`nVALOR CONTRATADO (soma qtd x preco BDI): R$ " + ([math]::Round($contratado,2)).ToString('N2',$inv))
Write-Output ("SALDO TOTAL LIQUIDO (base soma periodos): R$ " + ([math]::Round($saldoTotal,2)).ToString('N2',$inv))
Write-Output ("  saldo positivo: R$ " + ([math]::Round($saldoPos,2)).ToString('N2',$inv) + "  |  estouros (negativo): R$ " + ([math]::Round($saldoNeg,2)).ToString('N2',$inv))

# ---- base OFICIAL: acumulado da MED09 (acum anterior + periodo 09), que ja embute as glosas retroativas ----
$out2 = New-Object System.Collections.Generic.List[string]
$out2.Add('item;codigo_emop;descricao;unid;qtd_contratada;acum_soma_periodos;acum_oficial_med09;diferenca;saldo_oficial;pct_oficial;preco_bdi;saldo_oficial_rs')
$totOf = 0.0; $totOfPos = 0.0; $totOfNeg = 0.0; $esgOf = 0; $a80Of = 0
foreach ($it in $itens.Values) {
  if ($it.acumAnt9 -ne $null) { $it.acumOf = [math]::Round($it.acumAnt9 + $it.per[9], 4) } else { $it.acumOf = $null }
  if ($it.acumOf -ne $null -and $it.qtd -ne $null) {
    $it.saldoOf = [math]::Round($it.qtd - $it.acumOf, 4)
    $it.pctOf = if ($it.qtd -ne 0) { [math]::Round($it.acumOf / $it.qtd, 4) } else { $null }
  } else { $it.saldoOf = $null; $it.pctOf = $null }
  if ($it.saldoOf -ne $null -and $it.preco -ne $null) {
    $srs = [math]::Round($it.saldoOf * $it.preco, 2)
    $totOf += $srs; if ($srs -gt 0) { $totOfPos += $srs } else { $totOfNeg += $srs }
  } else { $srs = $null }
  if ($it.saldoOf -ne $null -and $it.saldoOf -le 0 -and $it.acumOf -gt 0) { $esgOf++ }
  if ($it.pctOf -ne $null -and $it.pctOf -ge 0.8 -and $it.saldoOf -gt 0) { $a80Of++ }
  $dif = if ($it.acumOf -ne $null) { [math]::Round($it.acum - $it.acumOf, 4) } else { $null }
  $desc2 = $it.desc -replace ';', ','
  $out2.Add((@($it.item,$it.cod,$desc2,$it.unid,(N $it.qtd),(N $it.acum),(N $it.acumOf),(N $dif),(N $it.saldoOf),(N $it.pctOf),(N $it.preco),$(if($srs -ne $null){$srs.ToString('0.##',$inv)}else{''})) -join ';'))
}
$out2Path = Join-Path $dir 'SALDO-POR-ITEM-OFICIAL-MED09.csv'
[System.IO.File]::WriteAllLines($out2Path, $out2, (New-Object System.Text.UTF8Encoding($true)))
Write-Output ("`nARQUIVO GERADO: $out2Path")
Write-Output ("BASE OFICIAL MED09 -> SALDO TOTAL LIQUIDO: R$ " + ([math]::Round($totOf,2)).ToString('N2',$inv) + " | positivo: R$ " + ([math]::Round($totOfPos,2)).ToString('N2',$inv) + " | estouros: R$ " + ([math]::Round($totOfNeg,2)).ToString('N2',$inv))
Write-Output ("BASE OFICIAL MED09 -> esgotados: $esgOf | entre 80% e 100%: $a80Of")
$top10of = $itens.Values | Where-Object { $_.saldoOf -ne $null -and $_.preco -ne $null } | Sort-Object { $_.saldoOf * $_.preco } -Descending | Select-Object -First 10
Write-Output "TOP 10 SALDOS EM R$ (base oficial MED09):"
foreach ($it in $top10of) { $v=[math]::Round($it.saldoOf*$it.preco,2); Write-Output ("  {0} ({1}) saldo={2} {3} = R$ {4} | {5}" -f $it.cod,$it.item,(N $it.saldoOf),$it.unid,$v.ToString('N2',$inv),($it.desc.Substring(0,[math]::Min(60,$it.desc.Length)))) }
Write-Output "MAO DE OBRA POR HORA (base oficial MED09):"
foreach ($it in ($itens.Values | Where-Object { $_.unid -eq 'H' -and $_.desc -match 'MAO' } | Sort-Object {$_.pctOf} -Descending)) {
  Write-Output ("  {0} ({1}) pctOf={2} acumOf={3} saldoOf={4} H | {5}" -f $it.cod,$it.item,(N $it.pctOf),(N $it.acumOf),(N $it.saldoOf),($it.desc.Substring(0,[math]::Min(55,$it.desc.Length)))) }
$pin = $itens.Values | Where-Object { $_.cod -eq '17.018.0031-A' } | Select-Object -First 1
Write-Output ("PINTURA oficial: acumOf={0} saldoOf={1} pctOf={2} saldoOfRS={3}" -f (N $pin.acumOf),(N $pin.saldoOf),(N $pin.pctOf),([math]::Round($pin.saldoOf*$pin.preco,2)).ToString('N2',$inv))

# mao de obra por hora
Write-Output "`n=== MAO DE OBRA POR HORA (UNID=H, descricao MAO) ==="
foreach ($it in ($itens.Values | Where-Object { $_.unid -eq 'H' -and $_.desc -match 'MAO' } | Sort-Object {$_.pct} -Descending)) {
  Write-Output ("  {0} ({1}) pct={2} acum={3} saldo={4} H saldoRS={5} | {6}" -f $it.cod,$it.item,(N $it.pct),(N $it.acum),(N $it.saldo),$(if($it.saldoRS -ne $null){$it.saldoRS.ToString('N2',$inv)}else{''}),($it.desc.Substring(0,[math]::Min(55,$it.desc.Length)))) }

# pintura
Write-Output "`n=== PINTURA 17.018.0031-A ==="
$pin = $itens.Values | Where-Object { $_.cod -eq '17.018.0031-A' } | Select-Object -First 1
Write-Output ("qtd={0} acum={1} saldo={2} pct={3} saldoRS={4}" -f (N $pin.qtd),(N $pin.acum),(N $pin.saldo),(N $pin.pct),$pin.saldoRS.ToString('N2',$inv))
$per = for ($m=1;$m -le 9;$m++){ "med0${m}=" + (N $pin.per[$m]) }
Write-Output ($per -join ' ')

# celulas vazias tratadas como 0 (so listar contagem)
Write-Output ("`nCELULAS DE PERIODO VAZIAS (tratadas como 0): " + $vazios.Count)

# itens sem qtd contratada
Write-Output "`nITENS SEM QTD CONTRATADA (extracontratuais):"
foreach ($it in ($itens.Values | Where-Object { $_.qtd -eq $null })) { Write-Output ("  {0} ({1}) acum={2} meds={3} | {4}" -f $it.cod,$it.item,(N $it.acum),($it.medPresente -join ','),($it.desc.Substring(0,[math]::Min(60,$it.desc.Length)))) }
