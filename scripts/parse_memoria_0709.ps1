# Parser da MEMORIA DE CALCULO - MED07..MED09 (contrato 064/2025)
# Somente leitura nos CSVs de origem; saidas via WriteAllText UTF8 sem BOM.
param([string[]]$Meds = @('07','08','09'), [string]$OutSuffix = 'med07-09')

$dir = 'C:/Users/meleo/AppData/Local/Temp/claude/C--Users-meleo--claude/0d52cde6-d1ea-4983-95d8-3d5164ad08fc/scratchpad/medicoes'
$ci  = [System.Globalization.CultureInfo]::InvariantCulture

$codeRegex = '^(\d{2}\.\d{3}\.\d{4}-[A-Z](/[A-Z])?|\d{4,6})$'
$numRegex  = '^-?\d+(\.\d+)?$'
$vocab = @('ESCOLA','O.S','O.S.','OS','LOCAL','UNIDADE','QUANTIDADE','COMPRIMENTO','LARGURA','ALTURA','ESPESSURA','PROFUNDIDADE',([char]0xC1+'REA'),'AREA','VOLUME','TOTAL','EXTENS'+[char]0xC3+'O','EXTENSAO','DIST'+[char]0xC2+'NCIA','DISTANCIA','PESO ESPEC.','PESO','HORA/M'+[char]0xCA+'S','HORA/MES','MESES','DIAS','QTD DE VIAGENS','QTD','HORAS UTEIS NO M'+[char]0xCA+'S','HORA TRABALHADA','HORA EXTRA 100%','X','=','M2 X KM','M2XKM','M2','M3','UN','M','H','T','KM','T X KM','TOTAL M2')

function Is-Vocab([string]$s) { $script:vocab -contains $s.ToUpperInvariant().Trim() }
function Is-Num([string]$s)   { $s -match $script:numRegex }

$outRows  = New-Object System.Collections.Generic.List[string]
$pendRows = New-Object System.Collections.Generic.List[string]
$descRows = New-Object System.Collections.Generic.List[string]
$stats = @{}

foreach ($m in $Meds) {
  $med = "MED$m"
  $path = "$dir/med${m}_memoria.csv"
  $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)

  $st = [ordered]@{rows=0; blocks=0; comEscola=0; semEscola=0; ok=0; pend=0}

  # estado do bloco corrente
  $inBlock=$false; $item=''; $code=''; $unit=''; $desc=''
  $curEsc=''; $curOs=''
  $blockRows = New-Object System.Collections.Generic.List[object]  # @{esc;os;expr;qty}

  $finalize = {
    param($totalStr, $totalOk)
    $st.blocks++
    $hasEsc = $false
    foreach ($r in $blockRows) { if ($r.esc -ne '' -or $r.os -ne '') { $hasEsc = $true; break } }
    $sum = 0.0
    foreach ($r in $blockRows) { $sum += [double]::Parse($r.qty, $ci) }
    $total = if ($totalOk -and (Is-Num $totalStr)) { [double]::Parse($totalStr, $ci) } else { $null }

    if (-not $totalOk) {
      $pendRows.Add("$med;$item;$code;bloco_sem_total;linhas=$($blockRows.Count) soma=$($sum.ToString($ci))")
      $st.pend++
    }

    # bloco so com escola declarada e quantidade unica (sem linha de calculo normal)
    if ($blockRows.Count -eq 0 -and $curEsc -ne '' -and $total -ne $null -and [math]::Abs($total) -gt 0.05) {
      $blockRows.Add(@{esc=$curEsc; os=$curOs; expr=$totalStr; qty=$totalStr})
      $sum = $total
      $hasEsc = $true
    }

    if ($hasEsc) {
      $st.comEscola++
      foreach ($r in $blockRows) {
        $outRows.Add("$med;$item;$code;$unit;$($r.esc);$($r.os);$($r.expr);$($r.qty)")
        $st.rows++
      }
      if ($total -ne $null) {
        if ([math]::Abs($sum - $total) -le 0.05) { $st.ok++ }
        else {
          $pendRows.Add("$med;$item;$code;soma_linhas_diverge_do_total;soma=$($sum.ToString($ci)) total=$totalStr dif=$(($sum-$total).ToString('0.####',$ci))")
          $st.pend++
        }
      }
    } else {
      $st.semEscola++
      $expr = ''
      if ($blockRows.Count -eq 1) { $expr = $blockRows[0].expr }
      elseif ($blockRows.Count -gt 1) { $expr = ($blockRows | ForEach-Object { $_.qty }) -join ' + ' }
      $q = if ($total -ne $null) { $totalStr } else { $sum.ToString($ci) }
      $outRows.Add("$med;$item;$code;$unit;;;$expr;$q")
      $st.rows++
      if ($total -ne $null) {
        if ($blockRows.Count -eq 0) {
          if ([math]::Abs($total) -le 0.05) { $st.ok++ }
          else {
            $pendRows.Add("$med;$item;$code;total_sem_linhas_de_calculo;total=$totalStr")
            $st.pend++
          }
        } elseif ([math]::Abs($sum - $total) -le 0.05) { $st.ok++ }
        else {
          $pendRows.Add("$med;$item;$code;soma_linhas_diverge_do_total_sem_escola;soma=$($sum.ToString($ci)) total=$totalStr dif=$(($sum-$total).ToString('0.####',$ci))")
          $st.pend++
        }
      }
    }
    $blockRows.Clear()
  }

  foreach ($raw in $lines) {
    $f = $raw -split ';' | ForEach-Object { $_.Trim() }
    if ($f.Count -lt 4) { continue }

    # inicio de bloco: campo[1] = item, campo[2] = codigo EMOP
    if ($f[1] -ne '' -and $f[2] -match $codeRegex) {
      if ($inBlock) { & $finalize '' $false }
      $inBlock = $true
      $item = $f[1]; $code = $f[2]; $desc = $f[3]
      $unit = ''
      for ($i = $f.Count - 1; $i -ge 4; $i--) { if ($f[$i] -ne '') { $unit = $f[$i]; break } }
      $curEsc=''; $curOs=''
      $descRows.Add("$med;$item;$code;$unit;""$($desc -replace '"','''')""")
      continue
    }
    if (-not $inBlock) { continue }

    # linha TOTAL MEDIDO NO PERIODO
    $ti = -1
    for ($i=0; $i -lt $f.Count; $i++) { if ($f[$i] -like 'TOTAL MEDIDO NO PERIODO*') { $ti = $i; break } }
    if ($ti -ge 0) {
      $tv = ''
      for ($i=$ti+1; $i -lt $f.Count; $i++) { if ($f[$i] -ne '') { $tv = $f[$i]; break } }
      & $finalize $tv $true
      $inBlock = $false
      continue
    }

    $hasOp = $false
    foreach ($x in $f) { if ($x -eq 'X' -or $x -eq '=') { $hasOp = $true; break } }

    $e2 = $f[2]; $e3 = $f[3]
    $e2IsText = ($e2 -ne '' -and -not (Is-Num $e2) -and -not (Is-Vocab $e2))
    $e3IsText = ($e3 -ne '' -and -not (Is-Num $e3) -and -not (Is-Vocab $e3))

    # coleta de numeros (indices >= 2); campo[3] vira O.S. quando campo[2] tem texto
    $nums = New-Object System.Collections.Generic.List[string]
    for ($i=2; $i -lt $f.Count; $i++) {
      if ($i -eq 3 -and $e2IsText) { continue }  # campo 3 = O.S. da linha
      if (Is-Num $f[$i]) { $nums.Add($f[$i]) }
    }

    if ($nums.Count -eq 0) {
      if ($hasOp) {
        # cabecalho de sub-tabela; pode declarar escola/local nos campos 2/3
        if ($e2IsText) { $curEsc = $e2; $curOs = if ($e3 -ne '') { $e3 } else { '' } }
        elseif ($e3IsText) { $curOs = $e3 }
      } else {
        # linha de texto puro: escola curta no campo 2, ou local/os no campo 3
        if ($e2IsText -and $e2.Length -le 60) { $curEsc = $e2; if ($e3 -ne '') { $curOs = $e3 } }
        elseif ($e2 -eq '' -and $e3IsText) { $curOs = $e3 }
      }
      continue
    }

    # linha de dados
    if ($e2IsText) {
      $curEsc = $e2
      $curOs = if ($e3 -ne '') { $e3 } else { '' }
    } elseif ($e3IsText) {
      $curOs = $e3
    }

    # subtotal do bloco: um unico numero sem texto nos campos 2/3
    if ($nums.Count -eq 1 -and -not $e2IsText -and -not $e3IsText) { continue }

    # linha de consolidacao (soma acumulada x meses): primeiro numero = soma das linhas ja aceitas
    if (-not $e2IsText -and -not $e3IsText -and $blockRows.Count -gt 0) {
      $run = 0.0
      foreach ($r in $blockRows) { $run += [double]::Parse($r.qty, $ci) }
      if ($run -gt 0 -and [math]::Abs([double]::Parse($nums[0], $ci) - $run) -le 0.005) { continue }
    }

    $qty = $nums[$nums.Count-1]
    $factors = @()
    if ($nums.Count -gt 1) { $factors = $nums[0..($nums.Count-2)] }
    $expr = if ($factors.Count -gt 0) { $factors -join ' x ' } else { $qty }
    $blockRows.Add(@{esc=$curEsc; os=$curOs; expr=$expr; qty=$qty})
  }
  if ($inBlock) { & $finalize '' $false }

  $stats[$med] = $st
}

# gravacao (UTF-8 sem BOM)
$enc = New-Object System.Text.UTF8Encoding($false)
$nl = "`r`n"
$header = 'medicao;item;codigo_emop;unid;escola;os_ref;expressao;quantidade'
[System.IO.File]::WriteAllText("$dir/historico_$OutSuffix.csv", $header + $nl + ($outRows -join $nl) + $nl, $enc)
$pheader = 'medicao;item;codigo_emop;problema;detalhe'
[System.IO.File]::WriteAllText("$dir/pendencias_$OutSuffix.csv", $pheader + $nl + ($pendRows -join $nl) + $nl, $enc)
$dheader = 'medicao;item;codigo_emop;unid;descricao'
[System.IO.File]::WriteAllText("$dir/itens_descricoes_$OutSuffix.csv", $dheader + $nl + ($descRows -join $nl) + $nl, $enc)

foreach ($k in ($stats.Keys | Sort-Object)) {
  $s = $stats[$k]
  $tot = $s.comEscola + $s.semEscola
  $pct = if ($tot -gt 0) { [math]::Round(100.0 * $s.ok / $tot, 1) } else { 0 }
  Write-Output ("{0}: linhas={1} blocos={2} comEscola={3} semEscola={4} somaOK={5} ({6}%) pendencias={7}" -f $k, $s.rows, $s.blocks, $s.comEscola, $s.semEscola, $s.ok, $pct, $s.pend)
}
