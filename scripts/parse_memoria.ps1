# Parser da MEMORIA DE CALCULO - MED01..MED03 (contrato 064/2025)
# Somente leitura nos CSVs de origem; saidas via WriteAllText UTF8 sem BOM.
param(
    [string[]]$Files = @('med01','med02','med03'),
    [string]$OutMain = 'historico_med01-03.csv',
    [string]$OutPend = 'pendencias_med01-03.csv'
)
$ErrorActionPreference = 'Stop'
$dir = 'C:/Users/meleo/AppData/Local/Temp/claude/C--Users-meleo--claude/0d52cde6-d1ea-4983-95d8-3d5164ad08fc/scratchpad/medicoes'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

function Fmt([double]$v) { return $v.ToString('0.####', $inv) }
function Clean([string]$s) { if ($null -eq $s) { return '' } return ($s -replace ';', ',').Trim() }

$codeRe   = '^(\d{2}\.\d{3}\.\d{4}-[A-Z](/[A-Z])?|\d{5})$'
$itemRe   = '^([A-Z]{1,2}(\.\d+)?|\d+(\.\d+)+|\d+)$'
$osRe     = '^O\.?S([^A-Za-z]|$)'
$tagRe    = '^MED\.?\s*\d+'
$parenRe  = '\(([^)]*)\)\s*$'
$opRe     = '^[Xx+\-]$'
$kwRe     = '^(LOCAL|COMPRIMENTO|LARGURA|ALTURA|ALT |EXTENS|ESPESSURA|PROFUNDIDADE|QUANTIDADE|ÁREA|AREA|VOLUME|TOTAL|DIST|PESO|UNIDADE|LADOS|M[EÊ]S|MESES|HORA|PER[IÍ]METRO)'
$unitRe   = '^[A-Z0-9ÍÃÇ][A-Z0-9ÍÃÇ /.%²³X]{0,9}$'

$allRows = New-Object System.Collections.Generic.List[string]
$allPend = New-Object System.Collections.Generic.List[string]
$statsOut = New-Object System.Collections.Generic.List[string]

foreach ($f in $Files) {
    $med = 'MED' + $f.Substring(3,2)
    $lines = Get-Content -LiteralPath (Join-Path $dir "${f}_memoria.csv") -Encoding UTF8

    $inBlock = $false
    $item = ''; $code = ''; $unitHdr = ''
    $rows = New-Object System.Collections.Generic.List[object]
    $escola = ''; $os = ''; $prior = $false
    $ops = @()

    $nBlocks = 0; $nEscolaBlk = 0; $nSemEscolaBlk = 0; $nOk = 0; $nRowsOut = 0

    for ($ln = 0; $ln -lt $lines.Count; $ln++) {
        $raw = $lines[$ln]
        $fld = $raw -split ';'
        for ($i = 0; $i -lt $fld.Count; $i++) { $fld[$i] = $fld[$i].Trim() }
        $f1 = if ($fld.Count -gt 1) { $fld[1] } else { '' }
        $f2 = if ($fld.Count -gt 2) { $fld[2] } else { '' }
        $f3 = if ($fld.Count -gt 3) { $fld[3] } else { '' }

        # inicio de bloco?
        if ($f1 -and $f1 -match $itemRe -and $f2 -match $codeRe) {
            if ($inBlock) {
                $allPend.Add(('{0};{1};{2};BLOCO_SEM_TOTAL;novo bloco comecou na linha {3} antes do TOTAL' -f $med, $item, $code, ($ln+1)))
            }
            $inBlock = $true
            $item = $f1; $code = $f2
            $unitHdr = ''
            for ($i = $fld.Count - 1; $i -ge 4; $i--) { if ($fld[$i]) { $unitHdr = $fld[$i]; break } }
            $rows.Clear(); $escola = ''; $os = ''; $prior = $false; $ops = @()
            continue
        }
        if (-not $inBlock) { continue }

        # linha de TOTAL do periodo -> fecha o bloco
        if ($raw -match 'TOTAL MEDIDO NO PERIODO') {
            $ti = -1
            for ($i = 0; $i -lt $fld.Count; $i++) { if ($fld[$i] -match 'TOTAL MEDIDO NO PERIODO') { $ti = $i; break } }
            $total = $null; $unitTot = ''
            for ($i = $ti + 1; $i -lt $fld.Count; $i++) {
                if ($fld[$i]) {
                    $v = 0.0
                    if ([double]::TryParse($fld[$i], [System.Globalization.NumberStyles]::Float, $inv, [ref]$v)) {
                        $total = $v
                        for ($j = $i + 1; $j -lt $fld.Count; $j++) { if ($fld[$j]) { $unitTot = $fld[$j]; break } }
                    }
                    break
                }
            }
            if ($null -eq $total) {
                $allPend.Add(('{0};{1};{2};TOTAL_ILEGIVEL;linha {3}: {4}' -f $med, $item, $code, ($ln+1), (Clean $raw)))
            } else {
                $u = if ($unitTot) { $unitTot } else { $unitHdr }
                $cur = @($rows | Where-Object { -not $_.prior })
                $sum = 0.0; foreach ($r in $cur) { $sum += $r.qty }
                $hasEscola = @($cur | Where-Object { $_.escola -ne '' -or $_.os -ne '' }).Count -gt 0
                if ($hasEscola) { $nEscolaBlk++ } else { $nSemEscolaBlk++ }
                if ([math]::Abs($sum - $total) -le 0.05) { $nOk++ }
                else {
                    $allPend.Add(('{0};{1};{2};SOMA_NAO_BATE;soma_linhas={3} total_periodo={4} (linha {5})' -f $med, $item, $code, (Fmt $sum), (Fmt $total), ($ln+1)))
                }
                if ($hasEscola) {
                    foreach ($r in $cur) {
                        if ($r.qty -eq 0 -and $r.expr -eq '') { continue }
                        $allRows.Add(('{0};{1};{2};{3};{4};{5};{6};{7}' -f $med, $item, $code, (Clean $u), (Clean $r.escola), (Clean $r.os), $r.expr, (Fmt $r.qty)))
                        $nRowsOut++
                    }
                } else {
                    $expr = ''
                    $nz = @($cur | Where-Object { $_.qty -ne 0 })
                    if ($nz.Count -eq 1) { $expr = $nz[0].expr }
                    $allRows.Add(('{0};{1};{2};{3};;;{4};{5}' -f $med, $item, $code, (Clean $u), $expr, (Fmt $total)))
                    $nRowsOut++
                }
                $nBlocks++
            }
            $inBlock = $false
            continue
        }

        # numericos nos campos a partir do indice 3
        $nums = @(); $numIdx = @()
        for ($i = 3; $i -lt $fld.Count; $i++) {
            if ($fld[$i]) {
                $v = 0.0
                if ([double]::TryParse($fld[$i], [System.Globalization.NumberStyles]::Float, $inv, [ref]$v)) {
                    $nums += $v; $numIdx += $i
                }
            }
        }

        # captura de operadores do cabecalho (linha sem numeros)
        if ($nums.Count -eq 0) {
            $o = @(); $hasEq = $false; $kwCount = 0
            for ($i = 3; $i -lt $fld.Count; $i++) {
                if ($fld[$i] -match $opRe) { $o += $fld[$i].ToLower() }
                if ($fld[$i] -eq '=') { $hasEq = $true }
            }
            for ($i = 2; $i -lt $fld.Count; $i++) { if ($fld[$i] -and $fld[$i] -match $kwRe) { $kwCount++ } }
            if ($o.Count -gt 0) { $ops = $o }
            # cabecalho de sub-tabela novo => fecha grupo de medicao anterior
            if ($f1 -eq '' -and ($f2 -eq '' -or $f2 -match $kwRe) -and ($o.Count -gt 0 -or $hasEq -or $kwCount -ge 2)) {
                $prior = $false; $os = ''
                if ($f2 -match $kwRe) { continue }
            }
        }

        # tag de medicao anterior no campo 2 (ex.: "MED. 01")
        if ($f1 -match $tagRe) {
            $prior = $true
            if ($f2) { $os = $f2; if ($f2 -match $osRe) { $escola = '' } }
            if ($nums.Count -eq 0) { continue }
        }
        elseif ($f2 -and $f2 -match $kwRe -and $nums.Count -eq 0) {
            continue   # rotulo de coluna no campo 3 (UNIDADE, LOCAL...), nao e escola
        }
        elseif ($f2) {
            if ($f2 -match $osRe) {
                $os = $f2; $escola = ''; $prior = $false
                if ($nums.Count -eq 0) { continue }
            } elseif ($f2 -match '^Referente') {
                $os = ($f2 -replace '\s+', ' '); $escola = ''
                if ($nums.Count -eq 0) { continue }
            } elseif ($f2.Length -gt 70) {
                continue   # anotacao longa, nao e escola
            } else {
                $esc = $f2; $osIn = ''
                if ($f2 -match $parenRe) {
                    $inner = $Matches[1].Trim()
                    if ($inner -match '^(O\.?S|\d+)') { $osIn = $inner; $esc = ($f2 -replace $parenRe, '').Trim() }
                }
                $escola = $esc
                if ($osIn) { $os = $osIn }
                if ($nums.Count -eq 0) { continue }
            }
        }

        if ($nums.Count -eq 0) { continue }

        # linha-recapitulacao (contem campo "=" e campos 2/3 vazios): nao e linha de dados
        if ($f2 -eq '' -and $f3 -eq '') {
            $hasEq = $false
            for ($i = 3; $i -lt $fld.Count; $i++) { if ($fld[$i] -eq '=') { $hasEq = $true; break } }
            if ($hasEq) { continue }
        }

        # subtotal? (um unico numero, campos 2/3/4 vazios, unidade logo apos, resto vazio)
        if ($nums.Count -eq 1 -and $f2 -eq '' -and $f3 -eq '') {
            $ni = $numIdx[0]
            $after = ''
            if ($ni + 1 -lt $fld.Count) { $after = $fld[$ni + 1] }
            $restEmpty = $true
            for ($i = 3; $i -lt $fld.Count; $i++) {
                if ($i -ne $ni -and $i -ne ($ni + 1) -and $fld[$i]) { $restEmpty = $false; break }
            }
            if ($after -and $after -match $unitRe -and $restEmpty) {
                $escola = ''; $os = ''; $prior = $false   # subtotal fecha o grupo
                continue
            }
        }

        # linha de dados
        $qty = $nums[$nums.Count - 1]
        $expr = ''
        if ($nums.Count -gt 1) {
            for ($i = 0; $i -lt $nums.Count - 1; $i++) {
                if ($i -gt 0) {
                    $op = 'x'
                    if (($i - 1) -lt $ops.Count -and $ops[$i - 1] -match '^[x+\-]$') { $op = $ops[$i - 1] }
                    $expr += ' ' + $op + ' '
                }
                $expr += (Fmt $nums[$i])
            }
        }
        $rows.Add(@{ escola = $escola; os = $os; expr = $expr; qty = $qty; prior = $prior })
    }
    if ($inBlock) {
        $allPend.Add(('{0};{1};{2};BLOCO_SEM_TOTAL;arquivo terminou sem TOTAL' -f $med, $item, $code))
    }
    $pct = if (($nBlocks) -gt 0) { [math]::Round(100.0 * $nOk / $nBlocks, 1) } else { 0 }
    $statsOut.Add(("{0}: linhas_extraidas={1} blocos={2} com_escola={3} sem_escola={4} soma_ok={5} ({6}%)" -f $med, $nRowsOut, $nBlocks, $nEscolaBlk, $nSemEscolaBlk, $nOk, $pct))
}

$hdr = 'medicao;item;codigo_emop;unid;escola;os_ref;expressao;quantidade'
$outMainTxt = $hdr + "`r`n" + ($allRows -join "`r`n") + "`r`n"
$hdrP = 'medicao;item;codigo_emop;problema;detalhe'
$outPendTxt = $hdrP + "`r`n"
if ($allPend.Count -gt 0) { $outPendTxt += ($allPend -join "`r`n") + "`r`n" }

$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $dir $OutMain), $outMainTxt, $enc)
[System.IO.File]::WriteAllText((Join-Path $dir $OutPend), $outPendTxt, $enc)
$statsOut | ForEach-Object { Write-Output $_ }
Write-Output ("total_linhas_saida={0} pendencias={1}" -f $allRows.Count, $allPend.Count)
