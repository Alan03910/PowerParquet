# CsvSchema.psm1
# Define el schema de un CSV (tipos de Parquet por columna) con una ventana interactiva,
# lo guarda como JSON y permite volver a leerlo.
#
# Funciones públicas:
#   New-CsvSchema                 : lee el CSV, muestra la ventana, guarda el JSON y devuelve el schema
#   Read-CsvSchema                : lee y valida un schema JSON
#   Get-CsvColumnNames            : solo los nombres de columna
#   Open-CsvReader / Read-CsvBatch / Close-CsvReader : lectura de CSV por lotes (la usa el orquestador)
#   ConvertTo-ParquetSchemaElements : schema -> lista de SchemaElement para Write-ThriftFileMetadata
#
# Uso en el orquestador:
#   if ($SchemaPath) { $schema = Read-CsvSchema -Path $SchemaPath }
#   else             { $schema = New-CsvSchema  -CsvPath $csv }
#   $schemaElements = ConvertTo-ParquetSchemaElements -Schema $schema
#
# IMPORTANTE: este archivo contiene acentos; debe guardarse como UTF-8 con BOM
# para que Windows PowerShell 5.1 lo lea bien.

# ---------------------------------------------------------------
# Catálogo de tipos
# ---------------------------------------------------------------
# Physical  : tipo físico de Parquet (0=BOOLEAN 1=INT32 2=INT64 4=FLOAT 5=DOUBLE 6=BYTE_ARRAY)
# Converted : ConvertedType de Parquet ($null = sin anotación)
# FormatKind: 'date' | 'time' | 'datetime' cuando la columna necesita formato de lectura

function New-SubtypeDef {
    param([string]$Id, [string]$Label, $Physical, $Converted = $null, [string]$FormatKind = '')
    [pscustomobject]@{
        Id = $Id; Label = $Label; Physical = $Physical; Converted = $Converted; FormatKind = $FormatKind
    }
}

$script:FormatPresets = @{
    date     = @('yyyy-MM-dd', 'dd/MM/yyyy', 'MM/dd/yyyy', 'yyyyMMdd', 'dd-MM-yyyy')
    time     = @('HH:mm:ss', 'HH:mm', 'HH:mm:ss.fff')
    datetime = @('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-ddTHH:mm:ss', 'dd/MM/yyyy HH:mm:ss',
                 'MM/dd/yyyy HH:mm:ss', 'dd/MM/yyyy HH:mm', 'yyyy-MM-dd HH:mm:ss.fff')
}

$script:Catalog = @(
    [pscustomobject]@{ Id = 'Entero'; Label = 'Entero'; Subtypes = @(
        New-SubtypeDef 'INT8'   'INT8 (-128 a 127)'                      1 15
        New-SubtypeDef 'INT16'  'INT16 (-32,768 a 32,767)'               1 16
        New-SubtypeDef 'INT32'  'INT32 (±2,147 millones)'                1
        New-SubtypeDef 'INT64'  'INT64 (enteros muy grandes)'            2
        New-SubtypeDef 'UINT8'  'UINT8 (0 a 255)'                        1 11
        New-SubtypeDef 'UINT16' 'UINT16 (0 a 65,535)'                    1 12
        New-SubtypeDef 'UINT32' 'UINT32 (0 a 4,294 millones)'            1 13
        New-SubtypeDef 'UINT64' 'UINT64 (positivos muy grandes)'         2 14
    ) }
    [pscustomobject]@{ Id = 'Decimal'; Label = 'Decimal'; Subtypes = @(
        New-SubtypeDef 'FLOAT'  'FLOAT (32 bits, ~7 dígitos)'            4
        New-SubtypeDef 'DOUBLE' 'DOUBLE (64 bits, ~15 dígitos)'          5
    ) }
    [pscustomobject]@{ Id = 'Fecha'; Label = 'Fecha'; Subtypes = @(
        New-SubtypeDef 'DATE'             'Fecha (día)'                  1 6  'date'
        New-SubtypeDef 'TIME_MILLIS'      'Hora (milisegundos)'          1 7  'time'
        New-SubtypeDef 'TIME_MICROS'      'Hora (microsegundos)'         2 8  'time'
        New-SubtypeDef 'TIMESTAMP_MILLIS' 'Fecha y hora (milisegundos)'  2 9  'datetime'
        New-SubtypeDef 'TIMESTAMP_MICROS' 'Fecha y hora (microsegundos)' 2 10 'datetime'
    ) }
    [pscustomobject]@{ Id = 'Texto'; Label = 'Texto'; Subtypes = @(
        New-SubtypeDef 'STRING' 'Texto (UTF-8)' 6 0
    ) }
    [pscustomobject]@{ Id = 'Categoria'; Label = 'Categoría'; Subtypes = @(
        New-SubtypeDef 'STRING_DICT' 'Texto con diccionario (UTF-8)' 6 0
    ) }
    [pscustomobject]@{ Id = 'Bool'; Label = 'Bool'; Subtypes = @(
        New-SubtypeDef 'BOOLEAN' 'Booleano (true/false)' 0
    ) }
)

function Get-TypeDefById {
    param([string]$Id)
    $script:Catalog | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
}

function Get-TypeDefByLabel {
    param([string]$Label)
    $script:Catalog | Where-Object { $_.Label -eq $Label } | Select-Object -First 1
}

function Get-SubtypeDef {
    param([string]$Type, [string]$Subtype)
    $t = Get-TypeDefById -Id $Type
    if (-not $t) { throw "Tipo desconocido: '$Type'" }
    $s = $t.Subtypes | Where-Object { $_.Id -eq $Subtype } | Select-Object -First 1
    if (-not $s) { throw "Subtipo desconocido '$Subtype' para el tipo '$Type'" }
    $s
}

# ---------------------------------------------------------------
# Lectura de CSV (cabecera + muestra)
# ---------------------------------------------------------------

# Ruta absoluta respetando la ubicación actual de PowerShell (las APIs de .NET no la respetan)
function Get-FullPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Path))
}

function Get-TextEncoding {
    param([string]$Name)
    switch ($Name) {
        'UTF8'        { [System.Text.UTF8Encoding]::new($false) }
        'Windows1252' { [System.Text.Encoding]::GetEncoding(1252) }
        'Latin1'      { [System.Text.Encoding]::GetEncoding(28591) }
        'Unicode'     { [System.Text.Encoding]::Unicode }
        'ASCII'       { [System.Text.Encoding]::ASCII }
        default       { throw "Encoding no soportado: $Name" }
    }
}

# Parte una línea CSV respetando comillas ("" dentro de comillas = comilla literal).
# Las comillas solo abren un campo si están al inicio del campo (así un apóstrofo
# dentro de un texto, como O'Neil, no se confunde con comilla simple).
# -Open recibe [ref] y devuelve $true si la línea terminó dentro de comillas.
function Split-CsvLine {
    param([string]$Line, [char]$Delimiter, [char]$Quote = '"', [ref]$Open)
    $fields   = [System.Collections.Generic.List[string]]::new()
    $sb       = [System.Text.StringBuilder]::new()
    $inQuotes = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($inQuotes) {
            if ($c -eq $Quote) {
                if (($i + 1) -lt $Line.Length -and $Line[$i + 1] -eq $Quote) { [void]$sb.Append($Quote); $i++ }
                else { $inQuotes = $false }
            }
            else { [void]$sb.Append($c) }
        }
        elseif ($c -eq $Quote -and $sb.Length -eq 0) { $inQuotes = $true }
        elseif ($c -eq $Delimiter) { $fields.Add($sb.ToString()); [void]$sb.Clear() }
        else { [void]$sb.Append($c) }
    }
    $fields.Add($sb.ToString())
    if ($null -ne $Open) { $Open.Value = $inQuotes }
    , $fields.ToArray()
}

# Lee un registro ya separado en campos (string[]). Devuelve $null al final del archivo
# y un arreglo vacío en líneas en blanco. Camino rápido (Split nativo) si la línea no
# tiene comillas; si una línea termina dentro de comillas, sigue leyendo líneas.
function Read-CsvFields {
    param($Reader, [char]$Delimiter, [char]$Quote, $Line = $null)
    if ($null -eq $Line) { $Line = $Reader.ReadLine() }
    if ($null -eq $Line) { return $null }
    if ($Line.Length -eq 0) { return , [string[]]::new(0) }
    if ($Line.IndexOf($Quote) -lt 0) { return , $Line.Split($Delimiter) }

    while ($true) {
        $open   = $false
        $fields = Split-CsvLine -Line $Line -Delimiter $Delimiter -Quote $Quote -Open ([ref]$open)
        if (-not $open) { return , $fields }
        $next = $Reader.ReadLine()
        if ($null -eq $next) { return , $fields }
        $Line += "`n" + $next
    }
}

function Resolve-Delimiter {
    param([string]$Delimiter, [string]$Line)
    if ($Delimiter -eq 'Auto') {
        $best = ','; $bestCount = 0
        foreach ($cand in @(',', ';', "`t", '|')) {
            $count = (Split-CsvLine -Line $Line -Delimiter ([char]$cand)).Count - 1
            if ($count -gt $bestCount) { $best = $cand; $bestCount = $count }
        }
        return [char]$best
    }
    if ($Delimiter -eq 'Tab' -or $Delimiter -eq '\t') { return [char]9 }
    if ($Delimiter.Length -ne 1) { throw "Delimiter debe ser un solo carácter, 'Tab' o 'Auto' (recibí '$Delimiter')" }
    [char]$Delimiter
}

# Nombres vacíos -> ColN; repetidos -> nombre_2, nombre_3 (Parquet exige nombres únicos)
function Get-UniqueColumnNames {
    param([string[]]$Names)
    $seen = @{}
    $out  = [string[]]::new($Names.Count)
    for ($k = 0; $k -lt $Names.Count; $k++) {
        $n = $Names[$k].Trim()
        if ([string]::IsNullOrWhiteSpace($n)) { $n = "Col$($k + 1)" }
        $base = $n; $c = 2
        while ($seen.ContainsKey($n)) { $n = "${base}_$c"; $c++ }
        $seen[$n] = $true
        $out[$k]  = $n
    }
    $out
}

function Open-CsvReader {
    <#
    .SYNOPSIS
        Abre un CSV para lectura por lotes y lee la cabecera.
    .PARAMETER HeaderRow
        Número de línea (desde 1) donde está el header. Las líneas anteriores se ignoran.
        0 = el archivo no tiene header (las columnas se llaman Col1, Col2, ...).
    .PARAMETER Quote
        'Double' (") o 'Single' (').
    .OUTPUTS
        Objeto con Reader, Delimiter, Quote, Columns y Pending. Cerrar con Close-CsvReader.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Delimiter = 'Auto',
        [ValidateSet('UTF8', 'Windows1252', 'Latin1', 'Unicode', 'ASCII')][string]$Encoding = 'UTF8',
        [ValidateRange(0, 1000000)][int]$HeaderRow = 1,
        [ValidateSet('Double', 'Single')][string]$Quote = 'Double'
    )

    $full = Get-FullPath $Path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "No existe el archivo: $full" }
    if ($Quote -eq 'Single') { $q = [char]"'" } else { $q = [char]'"' }

    $reader = [System.IO.StreamReader]::new($full, (Get-TextEncoding -Name $Encoding), $true)
    try {
        # líneas previas al header (títulos, notas, etc.)
        for ($k = 1; $k -lt $HeaderRow; $k++) {
            if ($null -eq $reader.ReadLine()) { throw "El archivo tiene menos de $HeaderRow líneas." }
        }
        $firstLine = $reader.ReadLine()
        while ($null -ne $firstLine -and $firstLine.Length -eq 0) { $firstLine = $reader.ReadLine() }
        if ($null -eq $firstLine) { throw "El archivo no tiene contenido a partir de la línea $([Math]::Max($HeaderRow, 1)): $full" }
        $firstLine = $firstLine.TrimStart([char]0xFEFF)

        $delim       = Resolve-Delimiter -Delimiter $Delimiter -Line $firstLine
        $firstFields = Read-CsvFields -Reader $reader -Delimiter $delim -Quote $q -Line $firstLine

        if ($HeaderRow -ge 1) {
            $columns = Get-UniqueColumnNames -Names $firstFields
            $pending = $null
        }
        else {
            $columns = [string[]](1..$firstFields.Count | ForEach-Object { "Col$_" })
            $pending = $firstFields           # sin header: la primera línea ya es un dato
        }
    }
    catch { $reader.Dispose(); throw }

    [pscustomobject]@{ Reader = $reader; Delimiter = $delim; Quote = $q; Columns = $columns; Pending = $pending }
}

function Read-CsvBatch {
    <#
    .SYNOPSIS
        Lee hasta MaxRows filas (cada una un string[]). Devuelve una lista vacía al llegar al final.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Csv, [int]$MaxRows = 100000)

    $rows = [System.Collections.Generic.List[string[]]]::new()
    if ($null -ne $Csv.Pending) { $rows.Add($Csv.Pending); $Csv.Pending = $null }
    while ($rows.Count -lt $MaxRows) {
        $f = Read-CsvFields -Reader $Csv.Reader -Delimiter $Csv.Delimiter -Quote $Csv.Quote
        if ($null -eq $f) { break }
        if ($f.Length -eq 0) { continue }
        $rows.Add($f)
    }
    , $rows
}

function Close-CsvReader {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Csv)
    $Csv.Reader.Dispose()
}

# ---------------------------------------------------------------
# Inferencia de tipo (solo para preseleccionar la ventana; el usuario manda)
# ---------------------------------------------------------------

function Test-AllParse {
    param([string[]]$Values, [string]$Format)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $dt  = [datetime]::MinValue
    foreach ($v in $Values) {
        if (-not [datetime]::TryParseExact($v, $Format, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
            return $false
        }
    }
    return $true
}

function Get-ColumnGuess {
    param([string[]]$Samples)

    $inv   = [System.Globalization.CultureInfo]::InvariantCulture
    $guess = @{ Type = 'Texto'; Subtype = 'STRING'; Format = $null; Nullable = $true; Sample = '' }
    $vals  = @($Samples | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    if ($vals.Count -eq 0) { return $guess }
    $guess.Sample = $vals[0]

    # Enteros. Los que empiezan con 0 ("00123") se dejan como texto: suelen ser códigos.
    if (@($vals | Where-Object { $_ -notmatch '^[+-]?\d+$' }).Count -eq 0) {
        if (@($vals | Where-Object { $_ -match '^[+-]?0\d' }).Count -eq 0) {
            $n = [int64]0
            $fitsInt64 = $true
            $fitsInt32 = $true
            foreach ($v in $vals) {
                if (-not [int64]::TryParse($v, [System.Globalization.NumberStyles]::Integer, $inv, [ref]$n)) {
                    $fitsInt64 = $false; break
                }
                if ($n -gt 2147483647 -or $n -lt -2147483648) { $fitsInt32 = $false }
            }
            if ($fitsInt64) {
                $guess.Type = 'Entero'
                if ($fitsInt32) { $guess.Subtype = 'INT32' } else { $guess.Subtype = 'INT64' }
            }
        }
        return $guess
    }

    # Decimales (punto como separador decimal)
    if (@($vals | Where-Object { $_ -notmatch '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$' }).Count -eq 0) {
        $guess.Type = 'Decimal'; $guess.Subtype = 'DOUBLE'
        return $guess
    }

    # Booleanos
    if (@($vals | Where-Object { $_ -notin @('true', 'false', 'verdadero', 'falso') }).Count -eq 0) {
        $guess.Type = 'Bool'; $guess.Subtype = 'BOOLEAN'
        return $guess
    }

    # Fechas / horas / fecha y hora: el primer formato que parsea todas las muestras
    $kinds = @(
        @{ Kind = 'datetime'; Subtype = 'TIMESTAMP_MILLIS' }
        @{ Kind = 'date';     Subtype = 'DATE' }
        @{ Kind = 'time';     Subtype = 'TIME_MILLIS' }
    )
    foreach ($k in $kinds) {
        foreach ($fmt in $script:FormatPresets[$k.Kind]) {
            if (Test-AllParse -Values $vals -Format $fmt) {
                $guess.Type = 'Fecha'; $guess.Subtype = $k.Subtype; $guess.Format = $fmt
                return $guess
            }
        }
    }

    # Pocas categorías distintas en bastantes filas -> Categoría
    $distinct = @($vals | Select-Object -Unique).Count
    if ($vals.Count -ge 30 -and $distinct -le 10) {
        $guess.Type = 'Categoria'; $guess.Subtype = 'STRING_DICT'
    }
    return $guess
}

# ---------------------------------------------------------------
# Ventana (WinForms)
# ---------------------------------------------------------------

function Update-SchemaRowFormats {
    param($Row, [string]$Format)
    $typeDef = Get-TypeDefByLabel -Label ([string]$Row.Type.SelectedItem)
    if ($null -eq $typeDef -or $Row.Subtype.SelectedIndex -lt 0) { return }
    $sub = @($typeDef.Subtypes)[$Row.Subtype.SelectedIndex]

    $Row.Format.Items.Clear()
    if ($sub.FormatKind) {
        $presets = $script:FormatPresets[$sub.FormatKind]
        foreach ($f in $presets) { [void]$Row.Format.Items.Add($f) }
        $Row.Format.Enabled = $true
        if ($Format) { $Row.Format.Text = $Format } else { $Row.Format.Text = $presets[0] }
    }
    else {
        $Row.Format.Enabled = $false
        $Row.Format.Text    = ''
    }
}

function Update-SchemaRowSubtypes {
    param($Row, [string]$SubtypeId, [string]$Format)
    $typeDef = Get-TypeDefByLabel -Label ([string]$Row.Type.SelectedItem)
    if ($null -eq $typeDef) { return }
    $subs = @($typeDef.Subtypes)

    $Row.Subtype.Items.Clear()
    foreach ($s in $subs) { [void]$Row.Subtype.Items.Add($s.Label) }

    $idx = 0
    if ($SubtypeId) {
        for ($k = 0; $k -lt $subs.Count; $k++) { if ($subs[$k].Id -eq $SubtypeId) { $idx = $k } }
    }
    $Row.Subtype.SelectedIndex = $idx
    Update-SchemaRowFormats -Row $Row -Format $Format
}

function Show-SchemaDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ColumnNames,
        [Parameter(Mandatory)]$Guesses,
        [string]$Title = 'Definir esquema del CSV'
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = [System.Windows.Forms.Form]::new()
    $form.Text          = $Title
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize    = [System.Drawing.Size]::new(960, 560)
    $form.MinimumSize   = [System.Drawing.Size]::new(700, 300)
    $form.TopMost       = $true

    # Encabezados
    $headers = @(
        @{ Text = 'Columna';      X = 12  }, @{ Text = 'Ejemplo';  X = 198 },
        @{ Text = 'Tipo';         X = 354 }, @{ Text = 'Subtipo';  X = 460 },
        @{ Text = 'Formato (fechas)'; X = 666 }, @{ Text = 'Acepta nulos'; X = 828 }
    )
    foreach ($h in $headers) {
        $lbl = [System.Windows.Forms.Label]::new()
        $lbl.Text = $h.Text
        $lbl.Font = [System.Drawing.Font]::new($form.Font, [System.Drawing.FontStyle]::Bold)
        $lbl.SetBounds($h.X, 10, 150, 20)
        $form.Controls.Add($lbl)
    }

    $panel = [System.Windows.Forms.Panel]::new()
    $panel.AutoScroll  = $true
    $panel.BorderStyle = 'FixedSingle'
    $panel.SetBounds(8, 34, 944, 466)
    $panel.Anchor = 'Top,Bottom,Left,Right'
    $form.Controls.Add($panel)

    # Handlers: no dependen de variables locales (solo de $sender.Tag y del módulo)
    $onTypeChanged    = { param($sender, $e) Update-SchemaRowSubtypes -Row $sender.Tag }
    $onSubtypeChanged = { param($sender, $e) Update-SchemaRowFormats  -Row $sender.Tag }

    $rows = [System.Collections.Generic.List[object]]::new()
    $y = 4
    for ($i = 0; $i -lt $ColumnNames.Count; $i++) {
        $g = @($Guesses)[$i]

        $lblName = [System.Windows.Forms.Label]::new()
        $lblName.Text = $ColumnNames[$i]
        $lblName.AutoEllipsis = $true
        $lblName.SetBounds(4, $y + 4, 180, 20)

        $lblSample = [System.Windows.Forms.Label]::new()
        $lblSample.Text = [string]$g.Sample
        $lblSample.AutoEllipsis = $true
        $lblSample.ForeColor = [System.Drawing.Color]::Gray
        $lblSample.SetBounds(190, $y + 4, 150, 20)

        $cbType = [System.Windows.Forms.ComboBox]::new()
        $cbType.DropDownStyle = 'DropDownList'
        $cbType.SetBounds(346, $y, 100, 24)

        $cbSub = [System.Windows.Forms.ComboBox]::new()
        $cbSub.DropDownStyle = 'DropDownList'
        $cbSub.SetBounds(452, $y, 200, 24)

        $cbFmt = [System.Windows.Forms.ComboBox]::new()
        $cbFmt.DropDownStyle = 'DropDown'
        $cbFmt.SetBounds(658, $y, 150, 24)

        $chk = [System.Windows.Forms.CheckBox]::new()
        $chk.Checked = [bool]$g.Nullable
        $chk.SetBounds(836, $y + 2, 24, 22)

        $row = @{ Name = $ColumnNames[$i]; Type = $cbType; Subtype = $cbSub; Format = $cbFmt; Nullable = $chk }
        $cbType.Tag = $row
        $cbSub.Tag  = $row

        foreach ($t in $script:Catalog) { [void]$cbType.Items.Add($t.Label) }
        $cbType.SelectedItem = (Get-TypeDefById -Id $g.Type).Label
        Update-SchemaRowSubtypes -Row $row -SubtypeId $g.Subtype -Format $g.Format

        # Los handlers se conectan DESPUÉS de la selección inicial
        $cbType.Add_SelectedIndexChanged($onTypeChanged)
        $cbSub.Add_SelectedIndexChanged($onSubtypeChanged)

        $panel.Controls.AddRange(@($lblName, $lblSample, $cbType, $cbSub, $cbFmt, $chk))
        $rows.Add($row)
        $y += 30
    }

    $btnOk = [System.Windows.Forms.Button]::new()
    $btnOk.Text = 'Aceptar'
    $btnOk.SetBounds(776, 514, 84, 30)
    $btnOk.Anchor = 'Bottom,Right'
    $btnOk.Tag = @{ Form = $form; Rows = $rows }
    $btnOk.Add_Click({
        param($sender, $e)
        $ctx = $sender.Tag
        foreach ($r in $ctx.Rows) {
            if ($r.Format.Enabled -and [string]::IsNullOrWhiteSpace($r.Format.Text)) {
                [void][System.Windows.Forms.MessageBox]::Show(
                    "Falta el formato de la columna '$($r.Name)'.", 'Formato requerido')
                return
            }
        }
        $ctx.Form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $ctx.Form.Close()
    })

    $btnCancel = [System.Windows.Forms.Button]::new()
    $btnCancel.Text = 'Cancelar'
    $btnCancel.SetBounds(868, 514, 84, 30)
    $btnCancel.Anchor = 'Bottom,Right'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $form.Controls.AddRange(@($btnOk, $btnCancel))
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        $form.Dispose()
        return $null
    }

    # Leer los valores ANTES de liberar los controles
    $cols = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $rows) {
        $typeDef = Get-TypeDefByLabel -Label ([string]$r.Type.SelectedItem)
        $sub     = @($typeDef.Subtypes)[$r.Subtype.SelectedIndex]
        $fmt     = $null
        if ($r.Format.Enabled) { $fmt = $r.Format.Text.Trim() }
        $cols.Add([ordered]@{
            Name     = $r.Name
            Type     = $typeDef.Id
            Subtype  = $sub.Id
            Nullable = [bool]$r.Nullable.Checked
            Format   = $fmt
        })
    }
    $form.Dispose()
    , $cols.ToArray()
}

# ---------------------------------------------------------------
# API pública
# ---------------------------------------------------------------

function Get-CsvColumnNames {
    <#
    .SYNOPSIS
        Devuelve los nombres de columna de un CSV (únicos y sin vacíos).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Delimiter = 'Auto',
        [ValidateSet('UTF8', 'Windows1252', 'Latin1', 'Unicode', 'ASCII')][string]$Encoding = 'UTF8',
        [int]$HeaderRow = 1,
        [ValidateSet('Double', 'Single')][string]$Quote = 'Double'
    )
    $csv = Open-CsvReader -Path $Path -Delimiter $Delimiter -Encoding $Encoding -HeaderRow $HeaderRow -Quote $Quote
    try { , $csv.Columns } finally { Close-CsvReader -Csv $csv }
}

function New-CsvSchema {
    <#
    .SYNOPSIS
        Lee un CSV, pregunta el tipo de cada columna en una ventana, guarda el schema
        como JSON y lo devuelve.
    .PARAMETER Delimiter
        'Auto' (default), ',', ';', '|' o 'Tab'.
    .PARAMETER HeaderRow
        Línea (desde 1) donde está el header; 0 = sin header (Col1, Col2, ...). Default 1.
    .PARAMETER NoHeader
        Atajo de -HeaderRow 0.
    .PARAMETER Quote
        'Double' (default) o 'Single'.
    .PARAMETER SchemaPath
        Dónde guardar el JSON. Default: <csv>.schema.json junto al CSV.
    .PARAMETER NoGui
        No abre la ventana: usa directamente los tipos inferidos de la muestra.
    .OUTPUTS
        El schema (objeto), o $null si se cancela la ventana.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CsvPath,
        [string]$Delimiter = 'Auto',
        [ValidateSet('UTF8', 'Windows1252', 'Latin1', 'Unicode', 'ASCII')][string]$Encoding = 'UTF8',
        [int]$HeaderRow = 1,
        [switch]$NoHeader,
        [ValidateSet('Double', 'Single')][string]$Quote = 'Double',
        [int]$SampleRows = 200,
        [string]$SchemaPath,
        [switch]$NoGui
    )

    if ($NoHeader) { $HeaderRow = 0 }
    $csvFull = Get-FullPath $CsvPath
    if (-not (Test-Path -LiteralPath $csvFull -PathType Leaf)) { throw "No existe el archivo: $csvFull" }
    if (-not $SchemaPath) { $SchemaPath = [System.IO.Path]::ChangeExtension($csvFull, 'schema.json') }
    $schemaFull = Get-FullPath $SchemaPath

    $csv = Open-CsvReader -Path $csvFull -Delimiter $Delimiter -Encoding $Encoding -HeaderRow $HeaderRow -Quote $Quote
    try     { $rows = Read-CsvBatch -Csv $csv -MaxRows $SampleRows }
    finally { Close-CsvReader -Csv $csv }
    $names = $csv.Columns

    $guesses = @(
        for ($c = 0; $c -lt $names.Count; $c++) {
            $vals = @(foreach ($row in $rows) { if ($c -lt $row.Length) { $row[$c] } else { '' } })
            Get-ColumnGuess -Samples $vals
        }
    )

    if ($NoGui) {
        $cols = @(
            for ($c = 0; $c -lt $names.Count; $c++) {
                $g = $guesses[$c]
                [ordered]@{ Name = $names[$c]; Type = $g.Type; Subtype = $g.Subtype; Nullable = $g.Nullable; Format = $g.Format }
            }
        )
    }
    else {
        $cols = Show-SchemaDialog -ColumnNames $names -Guesses $guesses -Title ("Esquema de " + [System.IO.Path]::GetFileName($csvFull))
        if ($null -eq $cols) { Write-Warning 'Definición de schema cancelada.'; return $null }
    }

    $schema = [ordered]@{
        SchemaVersion = 1
        Source        = [ordered]@{
            Delimiter = [string]$csv.Delimiter
            Encoding  = $Encoding
            HeaderRow = $HeaderRow
            Quote     = $Quote
        }
        Columns       = @($cols)
    }

    $json = $schema | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($schemaFull, $json, [System.Text.UTF8Encoding]::new($false))
    Write-Verbose "Schema guardado en $schemaFull"

    Read-CsvSchema -Path $schemaFull   # ida y vuelta: valida y devuelve la misma forma que al leer un JSON
}

function Read-CsvSchema {
    <#
    .SYNOPSIS
        Lee y valida un schema JSON generado por New-CsvSchema (o escrito a mano).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full = Get-FullPath $Path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "No existe el schema: $full" }

    $schema = [System.IO.File]::ReadAllText($full) | ConvertFrom-Json
    $cols   = @($schema.Columns)
    if ($cols.Count -eq 0 -or $null -eq $cols[0]) { throw "El schema no tiene columnas: $full" }

    $seen = @{}
    foreach ($c in $cols) {
        if ([string]::IsNullOrWhiteSpace($c.Name)) { throw 'Hay una columna sin Name en el schema.' }
        if ($seen.ContainsKey($c.Name)) { throw "Columna duplicada en el schema: '$($c.Name)'" }
        $seen[$c.Name] = $true

        $def = Get-SubtypeDef -Type $c.Type -Subtype $c.Subtype      # lanza si no existe
        if ($def.FormatKind -and [string]::IsNullOrWhiteSpace($c.Format)) {
            throw "La columna '$($c.Name)' ($($c.Subtype)) necesita un Format de lectura."
        }
        if ($null -eq $c.Nullable) { $c | Add-Member -NotePropertyName Nullable -NotePropertyValue $true -Force }
    }
    $schema
}

function ConvertTo-ParquetSchemaElements {
    <#
    .SYNOPSIS
        Convierte el schema en la lista de SchemaElement (raíz + una hoja por columna)
        que espera Write-ThriftFileMetadata en su campo Schema.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Schema)

    $cols     = @($Schema.Columns)
    $elements = [System.Collections.Generic.List[object]]::new()
    $elements.Add(@{ Name = 'schema'; Type = $null; Repetition = $null; NumChildren = $cols.Count })

    foreach ($c in $cols) {
        $def = Get-SubtypeDef -Type $c.Type -Subtype $c.Subtype
        $rep = 0                                   # 0 = REQUIRED
        if ($c.Nullable) { $rep = 1 }              # 1 = OPTIONAL
        $elements.Add(@{
            Name          = $c.Name
            Type          = $def.Physical
            Repetition    = $rep
            NumChildren   = 0
            ConvertedType = $def.Converted
        })
    }
    , $elements.ToArray()
}

Export-ModuleMember -Function New-CsvSchema, Read-CsvSchema, Get-CsvColumnNames, ConvertTo-ParquetSchemaElements,
    Open-CsvReader, Read-CsvBatch, Close-CsvReader
