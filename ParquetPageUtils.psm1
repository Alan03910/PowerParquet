# ParquetPageUtils.psm1
# Utilidades opcionales para el cuerpo de una Data Page de Parquet (V1):
#   Write-DefinitionLevels : niveles de definición (RLE / bit-packing híbrido)
#   Get-Compress-Bytes     : comprime el cuerpo de la página (GZIP, codec = 2)
#   Join-ByteArrays        : concatena byte[] de forma eficiente
#
# Solo PowerShell 5.1+ estándar, sin Add-Type ni librerías externas.

# ---------------------------------------------------------------
# Privadas
# ---------------------------------------------------------------

function Add-UVarint {
    param([System.Collections.Generic.List[byte]]$Buf, [uint64]$Value)
    while ($Value -ge 0x80) {
        $Buf.Add([byte](($Value -band 0x7F) -bor 0x80))
        $Value = $Value -shr 7
    }
    $Buf.Add([byte]$Value)
}

# Run RLE: varint(longitud << 1) + valor en ceil(bitWidth/8) bytes little-endian
function Add-RleRun {
    param(
        [System.Collections.Generic.List[byte]]$Out,
        [int]$RunLength,
        [int]$Value,
        [int]$ValueBytes
    )
    Add-UVarint -Buf $Out -Value ([uint64]$RunLength -shl 1)
    for ($b = 0; $b -lt $ValueBytes; $b++) {
        $Out.Add([byte](($Value -shr (8 * $b)) -band 0xFF))
    }
}

# Run bit-packed: varint((grupos de 8 << 1) | 1) + valores empaquetados LSB primero.
# El último grupo se rellena con ceros (el lector corta por num_values).
function Add-BitPackedRun {
    param(
        [System.Collections.Generic.List[byte]]$Out,
        [System.Collections.Generic.List[int]]$Values,
        [int]$BitWidth
    )
    $groups = [int][math]::Ceiling($Values.Count / 8)
    Add-UVarint -Buf $Out -Value (([uint64]$groups -shl 1) -bor 1)

    $total = $groups * 8
    $acc   = [uint64]0
    $bits  = 0
    for ($k = 0; $k -lt $total; $k++) {
        $val = 0
        if ($k -lt $Values.Count) { $val = $Values[$k] }
        $acc  = $acc -bor ([uint64]$val -shl $bits)
        $bits += $BitWidth
        while ($bits -ge 8) {
            $Out.Add([byte]($acc -band 0xFF))
            $acc   = $acc -shr 8
            $bits -= 8
        }
    }
}

# ---------------------------------------------------------------
# Públicas
# ---------------------------------------------------------------

function Write-DefinitionLevels {
    <#
    .SYNOPSIS
        Codifica niveles de definición con el híbrido RLE/bit-packing de Parquet.
    .PARAMETER Levels
        Un nivel por fila: 0 = NULL, 1 = con valor (hasta MaxDefLevel).
    .PARAMETER MaxDefLevel
        Nivel máximo de la columna. Para columnas planas OPTIONAL es 1.
        Si es 0 (columna REQUIRED) no se escribe nada y devuelve un arreglo vacío.
    .PARAMETER NoLengthPrefix
        Omite el prefijo de longitud de 4 bytes (que SÍ requiere Data Page V1).
    .OUTPUTS
        [byte[]]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int[]]$Levels,
        [Parameter(Mandatory)][int]$MaxDefLevel,
        [switch]$NoLengthPrefix
    )

    if ($MaxDefLevel -le 0) { return , [byte[]]::new(0) }

    # bits necesarios para representar MaxDefLevel
    $bitWidth = 0
    $m = $MaxDefLevel
    while ($m -gt 0) { $bitWidth++; $m = $m -shr 1 }
    $valueBytes = ($bitWidth + 7) -shr 3

    $body    = [System.Collections.Generic.List[byte]]::new()
    $pending = [System.Collections.Generic.List[int]]::new()   # valores pendientes de bit-packing
    $n = $Levels.Length
    $i = 0

    while ($i -lt $n) {
        $v = $Levels[$i]
        if ($v -lt 0 -or $v -gt $MaxDefLevel) {
            throw "Nivel inválido en la posición ${i}: $v (permitido: 0..$MaxDefLevel)"
        }
        $j = $i + 1
        while ($j -lt $n -and $Levels[$j] -eq $v) { $j++ }
        $run = $j - $i
        $i   = $j

        # Un run bit-packed debe cerrar en múltiplos de 8 valores. Si el run actual es lo
        # bastante largo, "presta" los valores que faltan, cierra el bloque y usa RLE.
        $need = (8 - ($pending.Count % 8)) % 8
        if (($run - $need) -ge 8) {
            for ($k = 0; $k -lt $need; $k++) { $pending.Add($v) }
            if ($pending.Count -gt 0) {
                Add-BitPackedRun -Out $body -Values $pending -BitWidth $bitWidth
                $pending.Clear()
            }
            Add-RleRun -Out $body -RunLength ($run - $need) -Value $v -ValueBytes $valueBytes
        }
        else {
            for ($k = 0; $k -lt $run; $k++) { $pending.Add($v) }
        }
    }
    if ($pending.Count -gt 0) {
        Add-BitPackedRun -Out $body -Values $pending -BitWidth $bitWidth
    }

    $result = [System.Collections.Generic.List[byte]]::new()
    if (-not $NoLengthPrefix) {
        $result.AddRange([BitConverter]::GetBytes([int32]$body.Count))   # little-endian en Windows
    }
    $result.AddRange($body)

    , $result.ToArray()
}

function Get-Compress-Bytes {
    <#
    .SYNOPSIS
        Comprime el cuerpo de una página en GZIP (Parquet codec = 2), en memoria.
    .PARAMETER RawBytes
        Cuerpo de la página sin comprimir (niveles + valores ya concatenados).
    .PARAMETER Level
        Optimal (default), Fastest o NoCompression.
    .OUTPUTS
        [byte[]]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$RawBytes,
        [ValidateSet('Optimal', 'Fastest', 'NoCompression')][string]$Level = 'Optimal'
    )

    $ms = [System.IO.MemoryStream]::new()
    try {
        $gz = [System.IO.Compression.GZipStream]::new(
            $ms, [System.IO.Compression.CompressionLevel]$Level, $true)
        try     { $gz.Write($RawBytes, 0, $RawBytes.Length) }
        finally { $gz.Dispose() }      # el Dispose escribe el trailer gzip: va ANTES de ToArray()
        , $ms.ToArray()
    }
    finally { $ms.Dispose() }
}

function Join-ByteArrays {
    <#
    .SYNOPSIS
        Concatena varios byte[] en uno (mucho más rápido que $a + $b con arreglos grandes).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[][]]$Arrays)

    $total = 0
    foreach ($a in $Arrays) { if ($null -ne $a) { $total += $a.Length } }

    $result = [byte[]]::new($total)
    $pos = 0
    foreach ($a in $Arrays) {
        if ($null -eq $a -or $a.Length -eq 0) { continue }
        [Buffer]::BlockCopy($a, 0, $result, $pos, $a.Length)
        $pos += $a.Length
    }
    , $result
}

Export-ModuleMember -Function Write-DefinitionLevels, Get-Compress-Bytes, Join-ByteArrays
