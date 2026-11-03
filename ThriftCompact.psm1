# ThriftCompact.psm1
# Serializa structs de Parquet (PageHeader, FileMetaData) con Thrift Compact Protocol.
# Solo PowerShell 5.1+ estándar: sin Add-Type, sin librerías externas.
#
# Uso:
#   Import-Module .\ThriftCompact.psm1
#   $pageHeaderBytes = Write-ThriftPageHeader   -Header   $pageHeaderData
#   $footerBytes     = Write-ThriftFileMetadata -Metadata $fileMetaData

# Tipos de campo del Compact Protocol
$script:CT = @{
    BoolTrue = 1; BoolFalse = 2; Byte = 3; I16 = 4; I32 = 5; I64 = 6
    Double = 7; Binary = 8; List = 9; Set = 10; Map = 11; Struct = 12
}

# ---------------------------------------------------------------
# Primitivas
# ---------------------------------------------------------------

# Varint sin signo (LEB128): 7 bits por byte, el bit alto indica "sigue"
function Add-Varint {
    param(
        [System.Collections.Generic.List[byte]]$Buf,
        [uint64]$Value
    )
    while ($Value -ge 0x80) {
        $Buf.Add([byte](($Value -band 0x7F) -bor 0x80))
        $Value = $Value -shr 7
    }
    $Buf.Add([byte]$Value)
}

# ZigZag: mapea signed -> unsigned (0,-1,1,-2 -> 0,1,2,3). Sirve igual para i16/i32/i64.
function ConvertTo-ZigZag {
    param([int64]$N)
    $z = ($N -shl 1) -bxor ($N -shr 63)
    [BitConverter]::ToUInt64([BitConverter]::GetBytes([int64]$z), 0)
}

function Add-ZigZagVarint {
    param(
        [System.Collections.Generic.List[byte]]$Buf,
        [int64]$N
    )
    Add-Varint -Buf $Buf -Value (ConvertTo-ZigZag -N $N)
}

# Header de campo: si el delta de id es 1..15 va en un solo byte (delta<<4 | tipo);
# si no, byte de tipo + id como zigzag varint.
function Add-FieldHeader {
    param(
        [System.Collections.Generic.List[byte]]$Buf,
        [hashtable]$Ctx,
        [int]$Id,
        [int]$Type
    )
    $delta = $Id - $Ctx.Last
    if ($delta -gt 0 -and $delta -le 15) {
        $Buf.Add([byte](($delta -shl 4) -bor $Type))
    }
    else {
        $Buf.Add([byte]$Type)
        Add-ZigZagVarint -Buf $Buf -N $Id
    }
    $Ctx.Last = $Id
}

# Header de lista: (size<<4 | tipoElemento) si size < 15; si no 0xF? + varint(size)
function Add-ListHeader {
    param(
        [System.Collections.Generic.List[byte]]$Buf,
        [int]$ElemType,
        [int]$Count
    )
    if ($Count -lt 15) {
        $Buf.Add([byte](($Count -shl 4) -bor $ElemType))
    }
    else {
        $Buf.Add([byte](0xF0 -bor $ElemType))
        Add-Varint -Buf $Buf -Value ([uint64]$Count)
    }
}

# Strings (también sirve para elementos de list<string>): varint(len) + bytes UTF-8
function Add-StringValue {
    param(
        [System.Collections.Generic.List[byte]]$Buf,
        [string]$Value
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    Add-Varint -Buf $Buf -Value ([uint64]$bytes.Length)
    $Buf.AddRange($bytes)
}

# Campos opcionales: si el valor es $null simplemente no se escriben
function Add-FieldI32 {
    param($Buf, [hashtable]$Ctx, [int]$Id, $Value)
    if ($null -eq $Value) { return }
    Add-FieldHeader -Buf $Buf -Ctx $Ctx -Id $Id -Type $script:CT.I32
    Add-ZigZagVarint -Buf $Buf -N ([int64]$Value)
}

function Add-FieldI64 {
    param($Buf, [hashtable]$Ctx, [int]$Id, $Value)
    if ($null -eq $Value) { return }
    Add-FieldHeader -Buf $Buf -Ctx $Ctx -Id $Id -Type $script:CT.I64
    Add-ZigZagVarint -Buf $Buf -N ([int64]$Value)
}

function Add-FieldString {
    param($Buf, [hashtable]$Ctx, [int]$Id, $Value)
    if ($null -eq $Value) { return }
    Add-FieldHeader -Buf $Buf -Ctx $Ctx -Id $Id -Type $script:CT.Binary
    Add-StringValue -Buf $Buf -Value ([string]$Value)
}

function Assert-Present {
    param($Value, [string]$Path)
    if ($null -eq $Value) { throw "Falta el campo requerido: $Path" }
}

# Fin de struct
function Add-StructStop {
    param($Buf)
    $Buf.Add([byte]0)
}

# ---------------------------------------------------------------
# Structs de Parquet (cada uno abre su propio contexto de field-id)
# ---------------------------------------------------------------

# DataPageHeader: 1 num_values, 2 encoding, 3 def_level_enc, 4 rep_level_enc
function Add-DataPageHeaderStruct {
    param($Buf, $H)
    Assert-Present $H.NumValues                'DataPageHeader.NumValues'
    Assert-Present $H.Encoding                 'DataPageHeader.Encoding'
    Assert-Present $H.DefinitionLevelEncoding  'DataPageHeader.DefinitionLevelEncoding'
    Assert-Present $H.RepetitionLevelEncoding  'DataPageHeader.RepetitionLevelEncoding'

    $ctx = @{ Last = 0 }
    Add-FieldI32 $Buf $ctx 1 $H.NumValues
    Add-FieldI32 $Buf $ctx 2 $H.Encoding
    Add-FieldI32 $Buf $ctx 3 $H.DefinitionLevelEncoding
    Add-FieldI32 $Buf $ctx 4 $H.RepetitionLevelEncoding
    Add-StructStop $Buf
}

# SchemaElement: 1 type, 2 type_length, 3 repetition_type, 4 name, 5 num_children, 6 converted_type
function Add-SchemaElementStruct {
    param($Buf, $E)
    Assert-Present $E.Name 'SchemaElement.Name'

    $rep = $E.Repetition
    if ($null -eq $rep) { $rep = $E.RepetitionType }

    $ctx = @{ Last = 0 }
    Add-FieldI32    $Buf $ctx 1 $E.Type            # $null en el nodo raíz -> se omite
    Add-FieldI32    $Buf $ctx 2 $E.TypeLength      # opcional (FIXED_LEN_BYTE_ARRAY)
    Add-FieldI32    $Buf $ctx 3 $rep               # $null en el nodo raíz -> se omite
    Add-FieldString $Buf $ctx 4 $E.Name
    # num_children solo si > 0: en las hojas se omite (así lo hacen los writers de referencia)
    if ($null -ne $E.NumChildren -and [int]$E.NumChildren -gt 0) {
        Add-FieldI32 $Buf $ctx 5 $E.NumChildren
    }
    Add-FieldI32    $Buf $ctx 6 $E.ConvertedType  # opcional (p.ej. 0 = UTF8 para strings)
    Add-StructStop  $Buf
}

# ColumnMetaData: 1 type, 2 encodings, 3 path_in_schema, 4 codec, 5 num_values,
#                 6 total_uncompressed_size, 7 total_compressed_size,
#                 9 data_page_offset, 11 dictionary_page_offset (opcional)
function Add-ColumnMetaDataStruct {
    param($Buf, $M)
    Assert-Present $M.Type                  'ColumnMetaData.Type'
    Assert-Present $M.Encodings             'ColumnMetaData.Encodings'
    Assert-Present $M.PathInSchema          'ColumnMetaData.PathInSchema'
    Assert-Present $M.Codec                 'ColumnMetaData.Codec'
    Assert-Present $M.NumValues             'ColumnMetaData.NumValues'
    Assert-Present $M.TotalUncompressedSize 'ColumnMetaData.TotalUncompressedSize'
    Assert-Present $M.TotalCompressedSize   'ColumnMetaData.TotalCompressedSize'
    Assert-Present $M.DataPageOffset        'ColumnMetaData.DataPageOffset'

    $ctx = @{ Last = 0 }
    Add-FieldI32 $Buf $ctx 1 $M.Type

    # 2: list<i32>
    $encodings = @($M.Encodings)
    Add-FieldHeader $Buf $ctx 2 $script:CT.List
    Add-ListHeader  $Buf $script:CT.I32 $encodings.Count
    foreach ($enc in $encodings) { Add-ZigZagVarint $Buf ([int64]$enc) }

    # 3: list<string>
    $path = @($M.PathInSchema)
    Add-FieldHeader $Buf $ctx 3 $script:CT.List
    Add-ListHeader  $Buf $script:CT.Binary $path.Count
    foreach ($p in $path) { Add-StringValue $Buf ([string]$p) }

    Add-FieldI32 $Buf $ctx 4 $M.Codec
    Add-FieldI64 $Buf $ctx 5 $M.NumValues
    Add-FieldI64 $Buf $ctx 6 $M.TotalUncompressedSize
    Add-FieldI64 $Buf $ctx 7 $M.TotalCompressedSize
    Add-FieldI64 $Buf $ctx 9 $M.DataPageOffset
    Add-FieldI64 $Buf $ctx 11 $M.DictionaryPageOffset   # opcional
    Add-StructStop $Buf
}

# ColumnChunk: 2 file_offset, 3 meta_data
function Add-ColumnChunkStruct {
    param($Buf, $C)
    Assert-Present $C.FileOffset 'ColumnChunk.FileOffset'
    Assert-Present $C.MetaData   'ColumnChunk.MetaData'

    $ctx = @{ Last = 0 }
    Add-FieldI64    $Buf $ctx 2 $C.FileOffset
    Add-FieldHeader $Buf $ctx 3 $script:CT.Struct
    Add-ColumnMetaDataStruct $Buf $C.MetaData
    Add-StructStop  $Buf
}

# RowGroup: 1 columns, 2 total_byte_size, 3 num_rows
function Add-RowGroupStruct {
    param($Buf, $R)
    Assert-Present $R.Columns       'RowGroup.Columns'
    Assert-Present $R.TotalByteSize 'RowGroup.TotalByteSize'
    Assert-Present $R.NumRows       'RowGroup.NumRows'

    $ctx = @{ Last = 0 }
    $cols = @($R.Columns)
    Add-FieldHeader $Buf $ctx 1 $script:CT.List
    Add-ListHeader  $Buf $script:CT.Struct $cols.Count
    foreach ($c in $cols) { Add-ColumnChunkStruct $Buf $c }

    Add-FieldI64   $Buf $ctx 2 $R.TotalByteSize
    Add-FieldI64   $Buf $ctx 3 $R.NumRows
    Add-StructStop $Buf
}

# ---------------------------------------------------------------
# API pública
# ---------------------------------------------------------------

function Write-ThriftPageHeader {
    <#
    .SYNOPSIS
        Serializa un PageHeader de Parquet (DATA_PAGE) a bytes Thrift Compact.
    .OUTPUTS
        [byte[]]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Header)

    Assert-Present $Header.Type                 'PageHeader.Type'
    Assert-Present $Header.UncompressedPageSize 'PageHeader.UncompressedPageSize'
    Assert-Present $Header.CompressedPageSize   'PageHeader.CompressedPageSize'
    Assert-Present $Header.DataPageHeader       'PageHeader.DataPageHeader'

    $buf = [System.Collections.Generic.List[byte]]::new()
    $ctx = @{ Last = 0 }

    Add-FieldI32 $buf $ctx 1 $Header.Type
    Add-FieldI32 $buf $ctx 2 $Header.UncompressedPageSize
    Add-FieldI32 $buf $ctx 3 $Header.CompressedPageSize
    Add-FieldI32 $buf $ctx 4 $Header.Crc                  # opcional
    Add-FieldHeader $buf $ctx 5 $script:CT.Struct
    Add-DataPageHeaderStruct $buf $Header.DataPageHeader
    Add-StructStop $buf

    , $buf.ToArray()   # la coma evita que PowerShell "desenrolle" el arreglo
}

function Write-ThriftFileMetadata {
    <#
    .SYNOPSIS
        Serializa el FileMetaData (footer) de Parquet a bytes Thrift Compact.
        Ojo: el archivo termina con [footer][longitud del footer: 4 bytes LE]["PAR1"];
        eso lo agregas tú al ensamblar el archivo.
    .OUTPUTS
        [byte[]]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Metadata)

    Assert-Present $Metadata.Version   'FileMetaData.Version'
    Assert-Present $Metadata.Schema    'FileMetaData.Schema'
    Assert-Present $Metadata.NumRows   'FileMetaData.NumRows'
    Assert-Present $Metadata.RowGroups 'FileMetaData.RowGroups'

    $buf = [System.Collections.Generic.List[byte]]::new()
    $ctx = @{ Last = 0 }

    # 1: version
    Add-FieldI32 $buf $ctx 1 $Metadata.Version

    # 2: schema (list<SchemaElement>)
    $schema = @($Metadata.Schema)
    Add-FieldHeader $buf $ctx 2 $script:CT.List
    Add-ListHeader  $buf $script:CT.Struct $schema.Count
    foreach ($el in $schema) { Add-SchemaElementStruct $buf $el }

    # 3: num_rows
    Add-FieldI64 $buf $ctx 3 $Metadata.NumRows

    # 4: row_groups (list<RowGroup>)
    $rgs = @($Metadata.RowGroups)
    Add-FieldHeader $buf $ctx 4 $script:CT.List
    Add-ListHeader  $buf $script:CT.Struct $rgs.Count
    foreach ($rg in $rgs) { Add-RowGroupStruct $buf $rg }

    # 6: created_by (opcional)
    Add-FieldString $buf $ctx 6 $Metadata.CreatedBy

    Add-StructStop $buf

    , $buf.ToArray()
}

Export-ModuleMember -Function Write-ThriftPageHeader, Write-ThriftFileMetadata
