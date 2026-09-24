# Parser da MEMORIA DE CALCULO - MED04/05/06 (contrato 064/2025 Educacao)
# Somente leitura nos CSVs de origem. Saida sem BOM.
param(
    [string[]]$Meds = @('med04','med05','med06'),
    [switch]$Debug1
)
$ErrorActionPreference = 'Stop'
$dir = 'C:/Users/meleo/AppData/Local/Temp/claude/C--Users-meleo--claude/0d52cde6-d1ea-4983-95d8-3d5164ad08fc/scratchpad/medicoes'
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$numRe = '^-?\d+(\.\d+)?$'
$codeRe = '^(\d{2}\.\d{3}\.\d{4}-[A-Z]|\d{5})$'
$hdrWords = @('UNIDADE','ESCOLA','LOCAL','QUANTIDADE','TOTAL','AREA','ÁREA','EXTENSÃO','COMPRIMENTO','LARGURA','ALTURA','ESPESSURA','PROFUNDIDADE','DISTÂNCIA','MESES','DESCRIÇÃO')

function IsNum([string]$s) { return ($s -match $numRe) }
function ToD([string]$s) { return [double]::Parse($s, $inv) }

$outRows = New-Object System.Collections.Generic.List[string]
$outRows.Add('medicao;item;codigo_emop;unid;escola;os_ref;expressao;quantidade')
$pend = New-Object System.Collections.Generic.List[string]
$pend.Add('medicao;item;codigo_emop;problema;detalhe')
$aux = New-Object System.Collections.Generic.List[string]
$aux.Add('medicao;item;codigo_emop;unid;descricao;total_periodo;tipo_bloco;soma_linhas;bateu')
$stats = @{}

foreach ($med in $Meds) {
    $medName = $med.ToUpper() -replace 'MED','MED'   # MED04 etc
    $file = Join-Path $dir "${med}_memoria.csv"
    $lines = Get-Content -LiteralPath $file -Encoding UTF8
    $st = [ordered]@{ linhas_extraidas=0; blocos=0; com_escola=0; sem_escola=0; bateu=0; nao_bateu=0 }

    # estado do bloco corrente
    $inBlock = $false
    $item=''; $code=''; $desc=''; $unit=''
    $curEsc=''; $curLoc=''; $hdrHasOS=$false
    $rows = @()   # cada: @{esc; os; loc; factors=[string[]]; result=string}

    $lineNo = 0
    foreach ($line in $lines) {
        $lineNo++
        $f = $line -split ';'
        for ($i=0; $i -lt $f.Count; $i++) { $f[$i] = $f[$i].Trim() }
        function fld($i) { if ($i -lt $f.Count) { return $f[$i] } else { return '' } }

        $f1 = if ($f.Count -gt 1) { $f[1] } else { '' }
        $f2 = if ($f.Count -gt 2) { $f[2] } else { '' }
        $f3 = if ($f.Count -gt 3) { $f[3] } else { '' }

        # inicio de bloco: campo item + codigo EMOP
        if ($f1 -ne '' -and $f2 -match $codeRe) {
            $inBlock = $true
            $item = $f1; $code = $f2
            $desc = if ($f.Count -gt 3) { $f[3] } else { '' }
            $unit = ''
            for ($i = $f.Count-1; $i -ge 4; $i--) { if ($f[$i] -ne '') { $unit = $f[$i]; break } }
            $curEsc=''; $curLoc=''; $hdrHasOS=$false
            $rows = @()
            continue
        }
        if (-not $inBlock) { continue }

        # fim de bloco: TOTAL MEDIDO NO PERIODO
        $tIdx = -1
        for ($i=0; $i -lt $f.Count; $i++) { if ($f[$i] -like '*TOTAL MEDIDO NO PERIODO*') { $tIdx = $i; break } }
        if ($tIdx -ge 0) {
            $totStr = ''
            for ($i=$tIdx+1; $i -lt $f.Count; $i++) { if ($f[$i] -ne '') { $totStr = $f[$i]; break } }
            $totVal = if (IsNum $totStr) { ToD $totStr } else { [double]::NaN }
            if (-not (IsNum $totStr)) {
                $pend.Add("$medName;$item;$code;total_ilegivel;linha $lineNo total='$totStr'")
            }
            $st.blocos++
            $isAdmin = ($item -like 'A.*') -or ($code -match '^\d{5}$')
            $hasEsc = $false
            foreach ($r in $rows) { if ($r.esc -ne '') { $hasEsc = $true; break } }

            if ($isAdmin -or -not $hasEsc) {
                # bloco sem escola: UMA linha, quantidade = total do periodo
                $st.sem_escola++
                $expr = ''
                if ($rows.Count -eq 1) {
                    $expr = ($rows[0].factors -join ' x ')
                    $rres = ToD $rows[0].result
                    if (-not [double]::IsNaN($totVal) -and [math]::Abs($rres - $totVal) -gt 0.05) {
                        # a unica linha nao e igual ao total; nao usar a expressao dela
                        $expr = ''
                    }
                }
                $outRows.Add("$medName;$item;$code;$unit;;;$expr;$totStr")
                $st.linhas_extraidas++
                $soma = $totVal
                $bat = 'S'
                $st.bateu++
                $aux.Add("$medName;$item;$code;$unit;$desc;$totStr;sem_escola;$totStr;$bat")
            }
            else {
                $st.com_escola++
                $soma = 0.0
                foreach ($r in $rows) { $soma += (ToD $r.result) }
                $ok = (-not [double]::IsNaN($totVal)) -and ([math]::Abs($soma - $totVal) -le 0.05)
                if ($ok) { $st.bateu++ } else {
                    $st.nao_bateu++
                    $somaR = [math]::Round($soma,5).ToString($inv)
                    $pend.Add("$medName;$item;$code;soma_nao_bate;soma_linhas=$somaR total_periodo=$totStr (linha $lineNo)")
                }
                foreach ($r in $rows) {
                    $expr = if ($r.factors.Count -gt 0) { $r.factors -join ' x ' } else { $r.result }
                    $outRows.Add("$medName;$item;$code;$unit;$($r.esc);$($r.os);$expr;$($r.result)")
                    $st.linhas_extraidas++
                }
                $bat = if ($ok) { 'S' } else { 'N' }
                $somaR2 = [math]::Round($soma,5).ToString($inv)
                $aux.Add("$medName;$item;$code;$unit;$desc;$totStr;com_escola;$somaR2;$bat")
            }
            $inBlock = $false
            continue
        }

        # dentro do bloco: classificar a linha
        if ($f1 -ne '') { continue }   # linha de secao dentro? nao ocorre; ignora
        $nums = @()   # pares idx,valor(string)
        $startIdx = 3
        for ($i=$startIdx; $i -lt $f.Count; $i++) { if ($f[$i] -ne '' -and (IsNum $f[$i])) { $nums += ,@($i, $f[$i]) } }

        $isHdr = $false
        if ($nums.Count -eq 0) {
            # cabecalho de sub-tabela?
            foreach ($x in $f) {
                if ($x -in @('X','=','+')) { $isHdr = $true; break }
                if ($hdrWords -contains $x.ToUpper()) { $isHdr = $true; break }
            }
            if ($isHdr) {
                foreach ($x in $f) { if ($x -match '^O\.?S\.?$') { $hdrHasOS = $true } }
                continue
            }
            # carry de escola/local sem numeros
            if ($f2 -ne '') { $curEsc = $f2; $curLoc = $f3 }
            elseif ($f3 -ne '') { $curLoc = $f3 }
            continue
        }

        # linha com numeros = linha de dados (ou subtotal/lixo)
        $hasText = $false
        if ($f2 -ne '' -and -not (IsNum $f2)) { $curEsc = $f2; $curLoc = ''; $hasText = $true }
        if ($f3 -ne '' -and -not (IsNum $f3)) { $curLoc = $f3; $hasText = $true }

        # coluna O.S (med06): campo 4 numerico logo apos nome da escola
        $osCol = ''
        if ($hdrHasOS -and $f3 -ne '' -and (IsNum $f3) -and $f2 -ne '') {
            $osCol = $f3
            $nums = @($nums | Where-Object { $_[0] -ne 3 })
        }

        if ($nums.Count -eq 0) { continue }

        # subtotal: sem texto e campo apos o ultimo numero = unidade do bloco
        $lastIdx = $nums[$nums.Count-1][0]
        $afterLast = if ($lastIdx+1 -lt $f.Count) { $f[$lastIdx+1] } else { '' }
        if (-not $hasText) {
            if ($afterLast -ne '' -and -not (IsNum $afterLast) -and ($afterLast.ToUpper() -eq $unit.ToUpper())) { continue }
            $allZero = $true
            foreach ($n in $nums) { if ((ToD $n[1]) -ne 0.0) { $allZero = $false; break } }
            if ($allZero) { continue }
        }

        $resStr = $nums[$nums.Count-1][1]
        $factors = @()
        for ($i=0; $i -lt $nums.Count-1; $i++) { $factors += $nums[$i][1] }

        # os_ref: coluna O.S > "O.S" no texto da escola/local > texto do campo 4 (local)
        $os = ''
        if ($osCol -ne '') { $os = $osCol }
        else {
            $m = [regex]::Match(($curEsc + ' ' + $curLoc), 'O\.?S\.?\s*[Nn]?[ºo°]?\s*([0-9][0-9\/\.\- ]*)')
            if ($m.Success) { $os = ('O.S ' + $m.Groups[1].Value.Trim()) }
            elseif ($curLoc -ne '') { $os = $curLoc }
        }
        $rows += ,@{ esc=$curEsc; os=$os; factors=$factors; result=$resStr }
    }

    $stats[$medName] = $st
}

# gravar saidas sem BOM
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $dir 'historico_med04-06.csv'), ($outRows -join "`r`n") + "`r`n", $enc)
[System.IO.File]::WriteAllText((Join-Path $dir 'pendencias_med04-06.csv'), ($pend -join "`r`n") + "`r`n", $enc)
[System.IO.File]::WriteAllText((Join-Path $dir 'itens_med04-06_aux.csv'), ($aux -join "`r`n") + "`r`n", $enc)

foreach ($k in ($stats.Keys | Sort-Object)) {
    $s = $stats[$k]
    $tot = $s.blocos
    $pct = if (($s.bateu + $s.nao_bateu) -gt 0) { [math]::Round(100.0*$s.bateu/($s.bateu+$s.nao_bateu),1) } else { 0 }
    Write-Output ("{0}: linhas={1} blocos={2} com_escola={3} sem_escola={4} bateu={5} nao_bateu={6} pct_bateu={7}%" -f $k,$s.linhas_extraidas,$tot,$s.com_escola,$s.sem_escola,$s.bateu,$s.nao_bateu,$pct)
}
Write-Output ("TOTAL linhas historico (sem cabecalho): " + ($outRows.Count-1))
Write-Output ("TOTAL pendencias: " + ($pend.Count-1))
