# Consolidação do histórico de medições (MED01-09) - contrato 064/2025
$ErrorActionPreference = 'Stop'
$src = 'C:/Users/meleo/AppData/Local/Temp/claude/C--Users-meleo--claude/0d52cde6-d1ea-4983-95d8-3d5164ad08fc/scratchpad/medicoes'
$out = 'C:/Users/meleo/FPV-PROJETOS/MEDICAO-AUTOMATICA/data'
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Force $out | Out-Null }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$inv = [System.Globalization.CultureInfo]::InvariantCulture

function ToNum($s) {
    if ($null -eq $s -or $s -eq '') { return $null }
    $s = ($s -replace '\s','')
    $v = 0.0
    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, $inv, [ref]$v)) { return $v }
    # tentativa com vírgula decimal
    $s2 = $s -replace '\.','' -replace ',','.'
    if ([double]::TryParse($s2, [System.Globalization.NumberStyles]::Float, $inv, [ref]$v)) { return $v }
    return $null
}

# ---------- 1. Concatenar históricos e pendências ----------
$histFiles = @("$src/historico_med01-03.csv","$src/historico_med04-06.csv","$src/historico_med07-09.csv")
$header = 'medicao;item;codigo_emop;unid;escola;os_ref;expressao;quantidade'
$allRows = New-Object System.Collections.Generic.List[string]
foreach ($f in $histFiles) {
    $lines = [System.IO.File]::ReadAllLines($f)
    if ($lines[0] -ne $header) { Write-Output "AVISO: cabecalho diferente em $f -> $($lines[0])" }
    for ($i=1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ne '') { $allRows.Add($lines[$i]) }
    }
}
[System.IO.File]::WriteAllText("$out/HISTORICO-OS-MEDIDAS.csv", $header + "`r`n" + ($allRows -join "`r`n") + "`r`n", $utf8)
Write-Output ("HISTORICO: {0} linhas de dados" -f $allRows.Count)

$pendFiles = @("$src/pendencias_med01-03.csv","$src/pendencias_med04-06.csv","$src/pendencias_med07-09.csv")
$pendHeader = 'medicao;item;codigo_emop;problema;detalhe'
$pendRows = New-Object System.Collections.Generic.List[string]
foreach ($f in $pendFiles) {
    $lines = [System.IO.File]::ReadAllLines($f)
    for ($i=1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ne '') { $pendRows.Add($lines[$i]) }
    }
}
[System.IO.File]::WriteAllText("$out/HISTORICO-PENDENCIAS.csv", $pendHeader + "`r`n" + ($pendRows -join "`r`n") + "`r`n", $utf8)
Write-Output ("PENDENCIAS: {0} linhas" -f $pendRows.Count)

# ---------- Parse do histórico consolidado em objetos ----------
$hist = New-Object System.Collections.Generic.List[object]
foreach ($ln in $allRows) {
    $p = $ln -split ';'
    if ($p.Count -lt 8) { continue }
    # expressao pode conter ';'? assumimos 8 campos; se mais, junta o excedente na expressao
    $qty = ToNum $p[$p.Count-1]
    $expr = if ($p.Count -gt 8) { ($p[6..($p.Count-2)] -join ';') } else { $p[6] }
    $hist.Add([pscustomobject]@{
        medicao=$p[0]; item=$p[1]; codigo=$p[2]; unid=$p[3]; escola=$p[4]; os_ref=$p[5]; expressao=$expr; quantidade=$qty
    })
}

# ---------- 2. Validação cruzada MED03/06/09 vs itens ----------
$valReport = New-Object System.Collections.Generic.List[string]
$allDesvios = @{}
foreach ($mn in @('03','06','09')) {
    $med = "MED$mn"
    $itensFile = "$src/med${mn}_itens.csv"
    $lines = [System.IO.File]::ReadAllLines($itensFile)
    # oficial: campo 2 = codigo EMOP, campo 9 = realizado no periodo; dados a partir da linha 16 (1-indexado)
    $oficial = @{}
    for ($i=15; $i -lt $lines.Count; $i++) {
        $p = $lines[$i] -split ';'
        if ($p.Count -lt 9) { continue }
        $cod = $p[1].Trim()
        if ($cod -match '^\d{2}\.\d{3}\.\d{4}-[A-Z]$' -or $cod -match '^\d{5}$') {
            $v = ToNum $p[8]
            if ($null -eq $v) { $v = 0.0 }
            if ($oficial.ContainsKey($cod)) { $oficial[$cod] += $v } else { $oficial[$cod] = $v }
        }
    }
    # extraído
    $ext = @{}
    foreach ($r in $hist | Where-Object { $_.medicao -eq $med }) {
        if ($null -eq $r.quantidade) { continue }
        if ($ext.ContainsKey($r.codigo)) { $ext[$r.codigo] += $r.quantidade } else { $ext[$r.codigo] = $r.quantidade }
    }
    $comMov = @($oficial.GetEnumerator() | Where-Object { [math]::Abs($_.Value) -gt 1e-9 })
    $ok = 0
    foreach ($e in $comMov) {
        $x = if ($ext.ContainsKey($e.Key)) { $ext[$e.Key] } else { 0.0 }
        $dif = [math]::Abs($x - $e.Value)
        if ($dif -le 0.1) { $ok++ }
        else {
            $allDesvios["$med|$($e.Key)"] = [pscustomobject]@{ medicao=$med; codigo=$e.Key; oficial=$e.Value; extraido=$x; dif=$dif }
        }
    }
    $pct = if ($comMov.Count -gt 0) { [math]::Round(100.0*$ok/$comMov.Count,1) } else { 100 }
    $valReport.Add(("{0}: {1} itens oficiais com movimento; {2} batem (tol 0,1) = {3}%" -f $med, $comMov.Count, $ok, $pct))
}
$valReport | ForEach-Object { Write-Output $_ }
Write-Output '--- 10 piores desvios ---'
$allDesvios.Values | Sort-Object dif -Descending | Select-Object -First 10 | ForEach-Object {
    Write-Output ("{0};{1};oficial={2};extraido={3};dif={4}" -f $_.medicao, $_.codigo, $_.oficial.ToString($inv), $_.extraido.ToString($inv), [math]::Round($_.dif,4).ToString($inv))
}

# ---------- 3. JURISPRUDENCIA-EMOP.csv ----------
$groups = $hist | Group-Object codigo
$jur = foreach ($g in $groups) {
    $rows = $g.Group
    $unid = ($rows | Where-Object { $_.unid -ne '' } | Select-Object -First 1).unid
    $osList = @($rows | Where-Object { $_.os_ref -ne '' } | ForEach-Object { $_.os_ref } | Sort-Object -Unique)
    $escList = @($rows | Where-Object { $_.escola -ne '' } | ForEach-Object { $_.escola } | Sort-Object -Unique)
    $meds = @($rows | ForEach-Object { $_.medicao } | Sort-Object -Unique)
    # exemplos reais: preferir linhas com escola e expressao
    $exRows = @($rows | Where-Object { $_.escola -ne '' -and $_.expressao -ne '' } | Select-Object -First 2)
    if ($exRows.Count -lt 2) { $exRows = @($exRows) + @($rows | Where-Object { $_.escola -ne '' } | Select-Object -First 2) | Select-Object -Unique -First 2 }
    $exs = @()
    foreach ($er in $exRows) {
        $q = if ($null -ne $er.quantidade) { $er.quantidade.ToString($inv) } else { '' }
        $exs += ("{0} | {1} | {2} = {3}" -f $er.escola, $er.os_ref, $er.expressao, $q)
    }
    while ($exs.Count -lt 2) { $exs += '' }
    [pscustomobject]@{
        codigo_emop=$g.Name; unid=$unid; n_linhas=$rows.Count; n_os_distintas=$osList.Count; n_escolas_distintas=$escList.Count
        medicoes=($meds -join ','); ex1=$exs[0]; ex2=$exs[1]
    }
}
$jurLines = New-Object System.Collections.Generic.List[string]
$jurLines.Add('codigo_emop;unid;n_linhas;n_os_distintas;n_escolas_distintas;medicoes_em_que_aparece;exemplo1;exemplo2')
foreach ($j in ($jur | Sort-Object n_linhas -Descending)) {
    $jurLines.Add(("{0};{1};{2};{3};{4};{5};{6};{7}" -f $j.codigo_emop, $j.unid, $j.n_linhas, $j.n_os_distintas, $j.n_escolas_distintas, $j.medicoes, ($j.ex1 -replace ';',','), ($j.ex2 -replace ';',',')))
}
[System.IO.File]::WriteAllText("$out/JURISPRUDENCIA-EMOP.csv", ($jurLines -join "`r`n") + "`r`n", $utf8)
Write-Output ("JURISPRUDENCIA: {0} codigos EMOP" -f ($jurLines.Count-1))

# ---------- 4. Números finais ----------
$comOS = @($hist | Where-Object { $_.os_ref -ne '' })
$osDist = @($comOS | ForEach-Object { $_.os_ref } | Sort-Object -Unique)
$escDist = @($hist | Where-Object { $_.escola -ne '' } | ForEach-Object { $_.escola } | Sort-Object -Unique)
Write-Output '--- NUMEROS FINAIS ---'
Write-Output ("Total linhas historico: {0}" -f $hist.Count)
Write-Output ("Linhas com O.S identificada: {0}" -f $comOS.Count)
Write-Output ("O.S distintas: {0}" -f $osDist.Count)
Write-Output ("Escolas (grafias) distintas: {0}" -f $escDist.Count)
Write-Output ("Itens EMOP distintos: {0}" -f $groups.Count)
Write-Output '--- top 10 jurisprudencia ---'
$jur | Sort-Object n_linhas -Descending | Select-Object -First 10 | ForEach-Object { Write-Output ("{0} {1} n={2} os={3} esc={4}" -f $_.codigo_emop,$_.unid,$_.n_linhas,$_.n_os_distintas,$_.n_escolas_distintas) }
