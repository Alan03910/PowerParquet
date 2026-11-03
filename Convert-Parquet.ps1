<#
.SYNOPSIS
    Convierte un CSV a Parquet (y, más adelante, Parquet a CSV) en PowerShell puro.

.DESCRIPTION
    CSV -> Parquet:
      * Sin -SchemaPath (o si el JSON no existe) abre la ventana para definir tipos y guarda el JSON.
      * Con -SchemaPath existente lee el JSON y convierte directo, sin ventana.
      * Escribe row groups de -RowGroupRows filas y páginas de -PageRows filas por columna.
      * Columnas Nullable: niveles de definición RLE/bit-packing (si la página no trae nulos
        usa un atajo de un solo run, sin recorrer los niveles).
      * Comprime las páginas con GZIP (codec 2) solo si el archivo supera -CompressThreshold filas (se decide con el primer row group). Con -Compression Always/Never se fuerza.
    Parquet -> CSV: todavía no implementado.
    Módulos requeridos en la misma carpeta: ThriftCompact.psm1, ParquetPageUtils.psm1, CsvSchema.psm1

.PARAMETER Path
    Archivo a convertir (.csv). Un .parquet dará error por ahora.
.PARAMETER SchemaPath
    JSON con el schema. Si no existe, se crea con la ventana en esa ruta.
.PARAMETER OutputPath
    Carpeta (termina en \ o ya existe) o ruta completa del archivo resultante.
    Default: junto al archivo de entrada, con extensión .parquet.
.PARAMETER Delimiter
    'Auto', ',', ';', '|' o 'Tab'. Si se omite se usa el del JSON, o 'Auto'.
.PARAMETER Encoding
    UTF8, Windows1252, Latin1, Unicode o ASCII. Si se omite se usa el del JSON, o UTF8.
.PARAMETER HeaderRow
    Línea (desde 1) donde está el header; 0 = sin header. Si se omite: JSON, o 1.
.PARAMETER Quote
    'Double' (") o 'Single' ('). Si se omite: JSON, o Double.
.PARAMETER NullValues
    Textos que se consideran nulo. Default: la cadena vacía.
.PARAMETER Force
    Sobrescribe el archivo de salida si ya existe.

.EXAMPLE
    .\Convert-Parquet.ps1 ventas.csv
.EXAMPLE
    .\Convert-Parquet.ps1 ventas.csv -SchemaPath ventas.schema.json -OutputPath D:\salida\
.EXAMPLE
    .\Convert-Parquet.ps1 datos.csv -Delimiter ';' -Encoding Windows1252 -HeaderRow 3 -Quote Single -NullValues '','NA'
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Path,
    [string]$SchemaPath,
    [string]$OutputPath,
    [string]$Delimiter,
    [ValidateSet('UTF8', 'Windows1252', 'Latin1', 'Unicode', 'ASCII')][string]$Encoding,
    [ValidateRange(0, 1000000)][int]$HeaderRow,
    [ValidateSet('Double', 'Single')][string]$Quote,
    [string[]]$NullValues = @(''),
    [ValidateRange(1, 2147483647)][int]$PageRows = 10000,
    [ValidateRange(1, 2147483647)][int]$RowGroupRows = 100000,
    [ValidateRange(0, 2147483647)][int]$CompressThreshold = 10000,
    [ValidateSet('Auto', 'Always', 'Never')][string]$Compression = 'Auto',
    [ValidateSet('Optimal', 'Fastest', 'NoCompression')][string]$CompressionLevel = 'Optimal',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Módulos
foreach ($m in 'ThriftCompact', 'ParquetPageUtils', 'CsvSchema') {
    $modPath = Join-Path $PSScriptRoot "$m.psm1"
    if (-not (Test-Path -LiteralPath $modPath)) { throw "Falta el módulo: $modPath" }
    Import-Module $modPath -Force
}

# Constantes
$script:Epoch = [datetime]::new(1970, 1, 1)

# Rangos de los enteros que se parsean como int64 (UINT64 se parsea aparte)
$script:IntRanges = @{
    INT8   = @([int64]-128, [int64]127)
    INT16  = @([int64]-32768, [int64]32767)
    INT32  = @([int64]-2147483648, [int64]2147483647)
    INT64  = @([int64]::MinValue, [int64]::MaxValue)
    UINT8  = @([int64]0, [int64]255)
    UINT16 = @([int64]0, [int64]65535)
    UINT32 = @([int64]0, [int64]4294967295)
}
$script:TrueSet  = [System.Collections.Generic.HashSet[string]]::new([string[]]@('true', 'verdadero', '1', 'yes', 'si', 'sí', 'y', 't'))
$script:FalseSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@('false', 'falso', '0', 'no', 'n', 'f'))

# Utilidades
function Resolve-FullPath {
    param([string]$P)
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($P)
}

function Resolve-OutputPath {
    param([string]$InputFull, [string]$OutputPath, [string]$Extension)
    $name  = [System.IO.Path]::GetFileNameWithoutExtension($InputFull) + $Extension
    if (-not $OutputPath) { return (Join-Path ([System.IO.Path]::GetDirectoryName($InputFull)) $name) }
    $full  = Resolve-FullPath $OutputPath
    $isDir = (Test-Path -LiteralPath $full -PathType Container) -or $OutputPath.EndsWith('\') -or $OutputPath.EndsWith('/')
    if ($isDir) { return (Join-Path $full $name) }
    if (-not [System.IO.Path]::GetExtension($full)) { $full += $Extension }
    $full
}

function New-ColumnError {
    param($Col, [int64]$Row, [string]$Msg)
    "Columna '$($Col.Name)' [$($Col.Subtype)], fila de datos $($Row + 1): $Msg"
}

# Niveles de definición de una página SIN nulos: un solo run RLE (valor 1) con prefijo de longitud.
# Equivale a Write-DefinitionLevels pero sin recorrer los niveles.
function New-AllPresentLevels {
    param([int]$Count)
    $body = [System.Collections.Generic.List[byte]]::new()
    $v    = [uint64]$Count -shl 1
    while ($v -ge 0x80) { $body.Add([byte](($v -band 0x7F) -bor 0x80)); $v = $v -shr 7 }
    $body.Add([byte]$v)
    $body.Add([byte]1)
    $out  = [System.Collections.Generic.List[byte]]::new()
    $out.AddRange([BitConverter]::GetBytes([int32]$body.Count))
    $out.AddRange($body)
    , $out.ToArray()
}

# Codificación PLAIN de una página de una columna
function ConvertTo-ColumnPage {
    param($Col, [string[]]$Cells, $NullSet, [int64]$FirstRow)

    $n        = $Cells.Length
    $nullable = [bool]$Col.Nullable
    $sub      = [string]$Col.Subtype
    $levels   = [int[]]::new($n)
    $nulls    = 0
    $inv      = [System.Globalization.CultureInfo]::InvariantCulture
    $ms       = [System.IO.MemoryStream]::new()
    $bw       = [System.IO.BinaryWriter]::new($ms)

    if ($sub -eq 'STRING' -or $sub -eq 'STRING_DICT') {
        $utf8 = [System.Text.Encoding]::UTF8
        for ($i = 0; $i -lt $n; $i++) {
            $s = $Cells[$i]
            if ($NullSet.Contains($s)) {
                if (-not $nullable) { throw (New-ColumnError $Col ($FirstRow + $i) 'valor nulo en una columna marcada como no nula.') }
                $nulls++
                continue
            }
            $b = $utf8.GetBytes($s)
            $bw.Write([int32]$b.Length)
            $bw.Write([byte[]]$b)
            $levels[$i] = 1
        }
    }
    elseif ($script:IntRanges.ContainsKey($sub)) {
        $min  = $script:IntRanges[$sub][0]
        $max  = $script:IntRanges[$sub][1]
        $kind = 'i32'
        if ($sub -eq 'UINT32') { $kind = 'u32' } elseif ($sub -eq 'INT64') { $kind = 'i64' }
        $style = [System.Globalization.NumberStyles]::Integer
        $v = [int64]0
        for ($i = 0; $i -lt $n; $i++) {
            $s = $Cells[$i].Trim()
            if ($NullSet.Contains($s)) {
                if (-not $nullable) { throw (New-ColumnError $Col ($FirstRow + $i) 'valor nulo en una columna marcada como no nula.') }
                $nulls++
                continue
            }
            if ((-not [int64]::TryParse($s, $style, $inv, [ref]$v)) -or ($v -lt $min) -or ($v -gt $max)) {
                throw (New-ColumnError $Col ($FirstRow + $i) "no es un entero válido para $s")
            }
            if ($kind -eq 'u32') { 
                $bw.Write([uint32]$v) 
            } elseif ($kind -eq 'i64') {
                $bw.Write([int64]$v) 
            } else {
                $bw.Write([int32]$v)
            }
            $levels[$i] = 1
        }
    } elseif ($sub -eq 'UINT64') {
        $style = [System.Globalization.NumberStyles]::Integer
        $u = [uint64]0
        for ($i = 0; $i -lt $n; $i++) {
            $s = $Cells[$i].Trim()
            if ($NullSet.Contains($s)) {
                if (-not $nullable) { throw (New-ColumnError $Col ($FirstRow + $i) 'valor nulo en una columna marcada como no nula.') }
                $nulls++
                continue
            }
            if (-not [uint64]::TryParse($s, $style, $inv, [ref]$u)) {
                throw (New-ColumnError $Col ($FirstRow + $i) "no es un entero válido para UINT64: '$s'")
            }
            $bw.Write([uint64]$u)
            $levels[$i] = 1
        }
    }
    elseif ($sub -eq 'FLOAT' -or $sub -eq 'DOUBLE') {
        $isFloat = ($sub -eq 'FLOAT')
        $style = [System.Globalization.NumberStyles]::Float
        $d = [double]0
        for ($i = 0; $i -lt $n; $i++) {
            $s = $Cells[$i].Trim()
            if ($NullSet.Contains($s)) {
                if (-not $nullable) { throw (New-ColumnError $Col ($FirstRow + $i) 'valor nulo en una columna marcada como no nula.') }
                $nulls++
                continue
            }
            if (-not [double]::TryParse($s, $style, $inv, [ref]$d)) {
                throw (New-ColumnError $Col ($FirstRow + $i) "no es un número decimal válido (separador decimal: punto): '$s'")
            }
            if ($isFloat) { $bw.Write([single]$d) } else { $bw.Write([double]$d) }
            $levels[$i] = 1
        }
    }
    elseif ($sub -eq 'BOOLEAN') {
        $cur = 0
        $bit = 0
        for ($i = 0; $i -lt $n; $i++) {
            $s = $Cells[$i].Trim()
            if ($NullSet.Contains($s)) {
                if (-not $nullable) { throw (New-ColumnError $Col ($FirstRow + $i) 'valor nulo en una columna marcada como no nula.') }
                $nulls++
                continue
            }
            $key = $s.ToLowerInvariant()
            if ($script:TrueSet.Contains($key)) { $cur = $cur -bor (1 -shl $bit) }
            elseif (-not $script:FalseSet.Contains($key)) {
                throw (New-ColumnError $Col ($FirstRow + $i) "no es un booleano reconocido (true/false, verdadero/falso, 1/0, si/no): '$s'")
            }
            $bit++
            if ($bit -eq 8) { $bw.Write([byte]$cur); $cur = 0; $bit = 0 }
            $levels[$i] = 1
        }
        if ($bit -gt 0) { $bw.Write([byte]$cur) }
    }
    elseif ($sub -in 'DATE', 'TIME_MILLIS', 'TIME_MICROS', 'TIMESTAMP_MILLIS', 'TIMESTAMP_MICROS') {
        $fmt   = [string]$Col.Format
        $none  = [System.Globalization.DateTimeStyles]::None
        $epoch = $script:Epoch
        $epochTicks = $epoch.Ticks
        $dt = [datetime]::MinValue
        for ($i = 0; $i -lt $n; $i++) {
            $s = $Cells[$i].Trim()
            if ($NullSet.Contains($s)) {
                if (-not $nullable) { throw (New-ColumnError $Col ($FirstRow + $i) 'valor nulo en una columna marcada como no nula.') }
                $nulls++
                continue
            }
            if (-not [datetime]::TryParseExact($s, $fmt, $inv, $none, [ref]$dt)) {
                throw (New-ColumnError $Col ($FirstRow + $i) "'$s' no coincide con el formato '$fmt'")
            }
            if ($sub -eq 'DATE') {
                $days = ($dt.Date - $epoch).Days
                $bw.Write([int32]$days)
            }
            elseif ($sub -eq 'TIME_MILLIS') {
                $tod = $dt.TimeOfDay
                $bw.Write([int32][math]::Floor($tod.TotalMilliseconds))
            }
            elseif ($sub -eq 'TIME_MICROS') {
                $t = $dt.TimeOfDay.Ticks
                $bw.Write([int64](($t - ($t % 10)) / 10))
            }
            elseif ($sub -eq 'TIMESTAMP_MILLIS') {
                $t = $dt.Ticks - $epochTicks
                $bw.Write([int64](($t - ($t % 10000)) / 10000))
            }
            else {   # TIMESTAMP_MICROS
                $t = $dt.Ticks - $epochTicks
                $bw.Write([int64](($t - ($t % 10)) / 10))
            }
            $levels[$i] = 1
        }
    }
    else {
        throw "Subtipo no soportado por el escritor: '$sub' (columna '$($Col.Name)')"
    }

    $bw.Flush()
    $values = $ms.ToArray()
    $bw.Dispose()

    if ($nullable) {
        if ($nulls -eq 0) { $lv = New-AllPresentLevels -Count $n }                           # sin nulos: atajo
        else              { $lv = Write-DefinitionLevels -Levels $levels -MaxDefLevel 1 }    # con nulos: RLE híbrido
        $body = Join-ByteArrays -Arrays $lv, $values
    }
    else {
        $body = $values
    }
    @{ Body = $body; NumValues = $n; Nulls = $nulls }
}

# Column chunk = páginas contiguas de una columna dentro de un row group
function Write-ColumnChunk {
    param($Fs, $Col, $Batch, [int64]$FirstRow, [bool]$Compress, [string]$Level, [int]$PageRows, $NullSet)

    $rowsInGroup = $Batch.Count
    $chunkStart  = $Fs.Position
    $uncTotal    = [int64]0
    $compTotal   = [int64]0
    $idx         = [int]$Col.Index

    for ($start = 0; $start -lt $rowsInGroup; $start += $PageRows) {
        $cnt   = [Math]::Min($PageRows, $rowsInGroup - $start)
        $cells = [string[]]::new($cnt)
        for ($j = 0; $j -lt $cnt; $j++) {
            $row = $Batch[$start + $j]
            if ($idx -lt $row.Length) { $cells[$j] = $row[$idx] } else { $cells[$j] = '' }
        }

        $page = ConvertTo-ColumnPage -Col $Col -Cells $cells -NullSet $NullSet -FirstRow ($FirstRow + $start)
        $raw  = $page.Body
        if ($Compress) { $payload = Get-Compress-Bytes -RawBytes $raw -Level $Level } else { $payload = $raw }

        $header = Write-ThriftPageHeader -Header @{
            Type                 = 0
            UncompressedPageSize = $raw.Length
            CompressedPageSize   = $payload.Length
            DataPageHeader       = @{
                NumValues               = $cnt
                Encoding                = 0      # PLAIN
                DefinitionLevelEncoding = 3      # RLE
                RepetitionLevelEncoding = 3      # RLE
            }
        }
        $Fs.Write($header, 0, $header.Length)
        $Fs.Write($payload, 0, $payload.Length)
        $uncTotal  += $header.Length + $raw.Length
        $compTotal += $header.Length + $payload.Length
    }

    if ($Col.Nullable) { $encodings = @(0, 3) } else { $encodings = @(0) }
    if ($Compress)     { $codec = 2 } else { $codec = 0 }       # 2 = GZIP

    @{
        FileOffset = $chunkStart
        MetaData   = @{
            Type                  = $Col.Physical
            Encodings             = $encodings
            PathInSchema          = @($Col.Name)
            Codec                 = $codec
            NumValues             = $rowsInGroup
            TotalUncompressedSize = $uncTotal
            TotalCompressedSize   = $compTotal
            DataPageOffset        = $chunkStart
        }
    }
}

# Programa principal
$inFull = Resolve-FullPath $Path
if (-not (Test-Path -LiteralPath $inFull -PathType Leaf)) { throw "No existe el archivo: $inFull" }
$ext = [System.IO.Path]::GetExtension($inFull).ToLowerInvariant()

if ($ext -eq '.parquet') {
    throw 'Parquet -> CSV todavía no está implementado (el -SchemaPath se ignora para Parquet). Por ahora solo CSV -> Parquet.'
}
if ($ext -notin '.csv', '.tsv', '.txt') {
    throw "Extensión no soportada: '$ext'. Usa .csv (a Parquet) o .parquet (a CSV, pendiente)."
}

$outFull = Resolve-OutputPath -InputFull $inFull -OutputPath $OutputPath -Extension '.parquet'
if ((Test-Path -LiteralPath $outFull) -and -not $Force) { throw "Ya existe: $outFull (usa -Force para sobrescribir)." }
$outDir = [System.IO.Path]::GetDirectoryName($outFull)
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# --- Schema: leer el JSON, o definirlo en la ventana ---
if ($SchemaPath -and (Test-Path -LiteralPath (Resolve-FullPath $SchemaPath) -PathType Leaf)) {
    $schema = Read-CsvSchema -Path $SchemaPath
}
else {
    $newArgs = @{ CsvPath = $inFull }
    foreach ($k in 'Delimiter', 'Encoding', 'HeaderRow', 'Quote') {
        if ($PSBoundParameters.ContainsKey($k)) { $newArgs[$k] = $PSBoundParameters[$k] }
    }
    if ($SchemaPath) { $newArgs['SchemaPath'] = $SchemaPath }
    $schema = New-CsvSchema @newArgs
    if ($null -eq $schema) { Write-Warning 'Conversión cancelada.'; return }
}

# --- Opciones de lectura: parámetro explícito > JSON > default ---
$src = $schema.Source
if     ($PSBoundParameters.ContainsKey('Delimiter')) { $optDelim = $Delimiter }
elseif ($src -and $src.Delimiter)                    { $optDelim = [string]$src.Delimiter }
else                                                 { $optDelim = 'Auto' }

if     ($PSBoundParameters.ContainsKey('Encoding'))  { $optEnc   = $Encoding }
elseif ($src -and $src.Encoding)                     { $optEnc   = [string]$src.Encoding }
else                                                 { $optEnc   = 'UTF8' }

if     ($PSBoundParameters.ContainsKey('HeaderRow')) { $optHdr   = $HeaderRow }
elseif ($src -and $null -ne $src.HeaderRow)          { $optHdr   = [int]$src.HeaderRow }
elseif ($src -and $null -ne $src.HasHeader)          { $optHdr   = [int][bool]$src.HasHeader }   # JSON antiguo
else                                                 { $optHdr   = 1 }

if     ($PSBoundParameters.ContainsKey('Quote'))     { $optQuote = $Quote }
elseif ($src -and $src.Quote)                        { $optQuote = [string]$src.Quote }
else                                                 { $optQuote = 'Double' }

$nullSet  = [System.Collections.Generic.HashSet[string]]::new([string[]]$NullValues)
$elements = ConvertTo-ParquetSchemaElements -Schema $schema     # raíz + una hoja por columna
$magic    = [System.Text.Encoding]::ASCII.GetBytes('PAR1')
$inLength = (Get-Item -LiteralPath $inFull).Length
$sw       = [System.Diagnostics.Stopwatch]::StartNew()

$csv = $null; $fs = $null; $tmp = $null
try {
    $csv = Open-CsvReader -Path $inFull -Delimiter $optDelim -Encoding $optEnc -HeaderRow $optHdr -Quote $optQuote

    # Columnas del schema -> posición en el CSV (por nombre)
    $headerIndex = @{}
    for ($i = 0; $i -lt $csv.Columns.Count; $i++) { $headerIndex[$csv.Columns[$i]] = $i }
    $schemaCols = @($schema.Columns)
    $missing = @($schemaCols | Where-Object { -not $headerIndex.ContainsKey($_.Name) } | ForEach-Object { $_.Name })
    if ($missing.Count -gt 0) {
        throw ("El CSV no tiene estas columnas del schema: " + ($missing -join ', ') +
               ". Columnas del CSV: " + ($csv.Columns -join ', '))
    }
    $plans = @(
        for ($i = 0; $i -lt $schemaCols.Count; $i++) {
            $c = $schemaCols[$i]
            @{
                Name     = [string]$c.Name
                Index    = $headerIndex[$c.Name]
                Subtype  = [string]$c.Subtype
                Format   = [string]$c.Format
                Nullable = [bool]$c.Nullable
                Physical = $elements[$i + 1].Type
            }
        }
    )

    $tmp = $outFull + '.tmp'
    $fs  = [System.IO.FileStream]::new($tmp, 'Create', 'Write', 'None', 1048576)
    $fs.Write($magic, 0, 4)

    $compress  = $null
    $totalRows = [int64]0
    $rowGroups = [System.Collections.Generic.List[object]]::new()

    while ($true) {
        $batch = Read-CsvBatch -Csv $csv -MaxRows $RowGroupRows
        if ($batch.Count -eq 0) { break }

        # ¿Comprimir? Se decide una vez, con el primer row group (el codec es por columna y
        # debe ser consistente en todo el archivo): más de $CompressThreshold filas => sí.
        if ($null -eq $compress) {
            if     ($Compression -eq 'Always') { $compress = $true }
            elseif ($Compression -eq 'Never')  { $compress = $false }
            else   { $compress = (($batch.Count -gt $CompressThreshold) -or ($batch.Count -ge $RowGroupRows)) }
            Write-Verbose "Compresión GZIP: $compress"
        }

        $chunks = [System.Collections.Generic.List[object]]::new()
        $groupUncompressed = [int64]0
        foreach ($col in $plans) {
            $chunk = Write-ColumnChunk -Fs $fs -Col $col -Batch $batch -FirstRow $totalRows `
                        -Compress $compress -Level $CompressionLevel -PageRows $PageRows -NullSet $nullSet
            $chunks.Add($chunk)
            $groupUncompressed += $chunk.MetaData.TotalUncompressedSize
        }
        $rowGroups.Add(@{ Columns = $chunks.ToArray(); TotalByteSize = $groupUncompressed; NumRows = $batch.Count })
        $totalRows += $batch.Count
        $batch = $null

        $pct = [Math]::Min(99, [int](100 * $csv.Reader.BaseStream.Position / [Math]::Max($inLength, 1)))
        Write-Progress -Activity 'CSV -> Parquet' -Status ('{0:N0} filas' -f $totalRows) -PercentComplete $pct
    }
    Write-Progress -Activity 'CSV -> Parquet' -Completed
    if ($totalRows -eq 0) { Write-Warning 'El CSV no tiene filas de datos; se genera un Parquet vacío.' }

    # Footer: FileMetaData (Thrift) + longitud (4 bytes LE) + "PAR1"
    $footer = Write-ThriftFileMetadata -Metadata @{
        Version   = 1
        Schema    = $elements
        NumRows   = $totalRows
        RowGroups = $rowGroups.ToArray()
        CreatedBy = 'ParquetPS (PowerShell)'
    }
    $fs.Write($footer, 0, $footer.Length)
    $lenBytes = [BitConverter]::GetBytes([int32]$footer.Length)
    $fs.Write($lenBytes, 0, 4)
    $fs.Write($magic, 0, 4)
    $fs.Dispose()
    $fs = $null

    Move-Item -LiteralPath $tmp -Destination $outFull -Force
    $tmp = $null

    [pscustomobject]@{
        Output     = $outFull
        Rows       = $totalRows
        Columns    = $plans.Count
        RowGroups  = $rowGroups.Count
        Compressed = [bool]$compress
        InputMB    = [Math]::Round($inLength / 1MB, 2)
        OutputMB   = [Math]::Round((Get-Item -LiteralPath $outFull).Length / 1MB, 2)
        Seconds    = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}
catch {
    if ($fs) { $fs.Dispose(); $fs = $null }
    if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    throw
}
finally {
    if ($csv) { Close-CsvReader -Csv $csv }
}
