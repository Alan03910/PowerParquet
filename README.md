## PowerParquet v1

### Introducción y Uso

Este es un script de Powershell que sigue el Formato [Apache Parquet](https://github.com/apache/parquet-format) para ayudar a guardar datos de CSV en un formato comprimido y esquemado. Se planea generar una utilidad para convertir archivos parquet en archivos CSV.

Como ejemplo de uso, imaginemos que tenemos el archivo *ventas.csv*, el cual queremos convertir a un archivo Parquet:

> .\Convert-Parquet.ps1 "C:\Ruta\A\ventas.csv"

Este código generará una ventana para que el usuario defina el esquema para la *escritura* del archivo CSV, y entregará dos archivos: *ventas.schema.json* y *ventas.parquet*, en el mismo directorio de ventas.csv

Alternativamente, si queremos modificar el sitio de guardado del resultado, podemos indicar una carpeta con *-OutputPath* y podemos cargar la configuración guardada de *ventas.schema.json* con *-SchemaPath*:

> .\Convert-Parquet.ps1 ventas.csv -SchemaPath ventas.schema.json -OutputPath D:\salida\

Finalmente, si el archivo CSV fue guardado en un formato particular de delimitciones, codificación, espacios en blanco arriba de los datos, o tiene un formato particular para los valores nulos, es posible leerlo usando *-Delimiter*, *-Encodign*, *-HeaderRow*, *-Quote*, y *-NullValues*.

> .\Convert-Parquet.ps1 datos.csv -Delimiter ';' -Encoding Windows1252 -HeaderRow 3 -Quote Single -NullValues '','NA'

### Una breve introducción a los módulos:
- **Convert-Parquet.ps1**: módulo principal, responsable de escuchar el prompt del usuario, determinar el schema a usar para los datos, inferir el esquema, determinar la necesidad de RLE/compresión, convertir los datos al formato requerido en páginas, y finalmente, escribir el parquet.
- **CsvSChema.psm1**: es un módulo encargado de generar una ventana para que el usuario determine los tipos de dato en el archivo. Permite generar el JSON para el guardado del Schema de guardado en parquet, el Schema para la lectura del CSV, y una utilidad para leer un JSON generado previamente por el usuario.
- **ThriftCompact.psm1** es el módulo responsable para escribir el [Thrift Compact Protocol](github.com/apache/thrift/blob/master/doc/specs/thrift-compact-protocol.md) necesario en los Encabezados de Página (Page Headers) y Metadatos de Archivo (File Metadata).
- **ParquetPageUtils.psm1** tiene las funciones necesarias para manejar RLE (el manejo de valores nulos) y compresión.