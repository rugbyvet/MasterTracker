<#
 MasterTracker ETL Orchestrator (Stages 1–3)
 Environment: PowerShell-only, SAP GUI Scripting, SQL Server

 Responsibilities
 - Stage 1: Acquire SAP T-Codes via GUI Scripting and CSR via SAC export
 - Stage 2: Transform & normalize (PMMO backbone, ZMRPEXCEPTION parse, metrics)
 - Stage 3: Compile to SQL Server schema and compute readiness

 Notes
 - Fill in SAP GUI scripting automation for your environment (connection, sessions, paths)
 - CSV staging folder: ./staging (created if missing)
 - Uses System.Data.SqlClient for portability (no external modules required)
#>

param(
  [string]$SqlConnectionString = "Server=YOUR_SQL_SERVER;Database=MasterTracker;Integrated Security=True;TrustServerCertificate=True;",
  [string]$StagingDir = "$PSScriptRoot/../staging",
  [string]$RunDate = (Get-Date -Format 'yyyy-MM-dd')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-StagingDir {
  param([string]$Path)
  if (-not (Test-Path -Path $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
}

function Get-SapReport {
  param(
    [Parameter(Mandatory)] [string]$TCode,
    [Parameter(Mandatory)] [string]$OutputCsv
  )
  # TODO: Implement SAP GUI scripting for $TCode to export to $OutputCsv
  # Placeholders:
  Write-Host "[SAP] Exporting $TCode to $OutputCsv"
  # Remove after implementation; create empty file to keep pipeline shape
  if (-not (Test-Path $OutputCsv)) { '' | Out-File -FilePath $OutputCsv -Encoding utf8 }
}

function Export-CsrFromSac {
  param([Parameter(Mandatory)] [string]$OutputCsv)
  # TODO: Automate SAC export for CSR report; save to $OutputCsv
  Write-Host "[SAC] Exporting CSR to $OutputCsv"
  if (-not (Test-Path $OutputCsv)) { '' | Out-File -FilePath $OutputCsv -Encoding utf8 }
}

function Normalize-Identifier {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
  # Strip typical suffix like '/0010'
  $v = $Value -replace '/\d{3,4}$',''
  $v
}

function Get-Field {
  param(
    [Parameter(Mandatory)] [psobject]$Row,
    [Parameter(Mandatory)] [string[]]$Candidates
  )
  foreach ($c in $Candidates) {
    if ($Row.PSObject.Properties.Name -contains $c) { return $Row.$c }
  }
  return $null
}

function To-NullableDecimal { param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  try { return [decimal]$Value } catch { return $null }
}

function To-NullableDateIso { param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  try { (Get-Date -Date $Value).ToString('s') } catch { return $null }
}

function Transform-ZmrpException {
  param(
    [Parameter(Mandatory)] [string]$InputCsv,
    [Parameter(Mandatory)] [string]$OutputCsv
  )
  # Example: passthrough with minimal normalization placeholder
  Write-Host "[XFORM] ZMRPEXCEPTION normalize -> $OutputCsv"
  $rows = Import-Csv -Path $InputCsv -ErrorAction SilentlyContinue
  if (-not $rows) { '' | Out-File -FilePath $OutputCsv; return }
  # Candidate source headers mapping (adjust to your export)
  $map = @{ 
    material_number = @('material_number','Material','MATNR')
    mrp_element     = @('mrp_element','MRP_Element','MRPElement','MRPEl')
    exception_code  = @('exception_code','ExceptionCode','EXCCODE','Exception Code')
    exception_type  = @('exception_type','ExceptionType','Exception Type')
    severity_level  = @('severity_level','Severity','SEVERITY')
    exception_text  = @('exception_text','ExceptionText','Exception Text')
    raised_on_utc   = @('raised_on_utc','RaisedOnUtc','Raised On','RAISED_ON')
    age_days        = @('age_days','AgeDays')
  }
  $out = foreach ($r in $rows) {
    [pscustomobject]@{
      material_number   = (Get-Field -Row $r -Candidates $map.material_number)
      parsed_order_id   = (Normalize-Identifier -Value (Get-Field -Row $r -Candidates $map.mrp_element))
      exception_code    = (Get-Field -Row $r -Candidates $map.exception_code)
      exception_type    = (Get-Field -Row $r -Candidates $map.exception_type)
      severity_level    = (Get-Field -Row $r -Candidates $map.severity_level)
      exception_text    = (Get-Field -Row $r -Candidates $map.exception_text)
      raised_on_utc     = (To-NullableDateIso (Get-Field -Row $r -Candidates $map.raised_on_utc))
      age_days          = (Get-Field -Row $r -Candidates $map.age_days)
    }
  }
  $out | Export-Csv -Path $OutputCsv -NoTypeInformation
}

function Transform-PmmoPeggingToMst {
  param(
    [Parameter(Mandatory)] [string]$InputCsv,
    [Parameter(Mandatory)] [string]$OutputCsv
  )
  Write-Host "[XFORM] PMMO_PEGGING -> Material_Status_Tracker shape -> $OutputCsv"
  $rows = Import-Csv -Path $InputCsv -ErrorAction SilentlyContinue
  if (-not $rows) { '' | Out-File -FilePath $OutputCsv; return }
  $map = @{
    project_global_id        = @('pspnr_assgd','PSPNR_ASSGD','ProjectWBS','WBS')
    top_req_obj              = @('RQMTOBJ_TOP','TopReqObj','TOP_REQ_OBJ')
    repobj_nha               = @('REPOBJ_NHA','Parent','NextHigherAssembly')
    repobj                   = @('REPOBJ','SupplyObject','Supply_Obj','MRP_Element')
    material_number          = @('material_number','Material','MATNR')
    assgdqty                 = @('ASSGDQTY','AllocatedQty')
    xssqty                   = @('XSSQTY','ExcessQty')
    creation_datetime_utc    = @('CREATIONDATETIME','CreationDateTime','CreatedOn')
    last_change_datetime_utc = @('LASTCHANGEDATETIME','LastChangeDateTime','ChangedOn')
    rqmt_date_utc            = @('RQMT_DATE','RequirementDate')
    repobj_date_utc          = @('REPOBJ_DATE','SupplyDate','CommitDate')
    planning_group           = @('PlanningGroup')
    plant                    = @('Plant','WERK')
    mrp_controller           = @('MRPController','DISPO')
  }
  $out = foreach ($r in $rows) {
    $repobjVal = Normalize-Identifier (Get-Field -Row $r -Candidates $map.repobj)
    [pscustomobject]@{
      project_global_id           = (Get-Field -Row $r -Candidates $map.project_global_id)
      top_req_obj                 = Normalize-Identifier (Get-Field -Row $r -Candidates $map.top_req_obj)
      repobj_nha                  = Normalize-Identifier (Get-Field -Row $r -Candidates $map.repobj_nha)
      repobj                      = $repobjVal
      pspnr_assgd                 = (Get-Field -Row $r -Candidates $map.project_global_id)
      material_number             = (Get-Field -Row $r -Candidates $map.material_number)
      assgdqty                    = (To-NullableDecimal (Get-Field -Row $r -Candidates $map.assgdqty))
      xssqty                      = (To-NullableDecimal (Get-Field -Row $r -Candidates $map.xssqty))
      creation_datetime_utc       = (To-NullableDateIso (Get-Field -Row $r -Candidates $map.creation_datetime_utc))
      last_change_datetime_utc    = (To-NullableDateIso (Get-Field -Row $r -Candidates $map.last_change_datetime_utc))
      rqmt_date_utc               = (To-NullableDateIso (Get-Field -Row $r -Candidates $map.rqmt_date_utc))
      repobj_date_utc             = (To-NullableDateIso (Get-Field -Row $r -Candidates $map.repobj_date_utc))
      remaining_hours             = $null
      late_supply_flag            = $null
      capacity_risk_flag          = $null
      exception_severity_score    = $null
      planner_load_impact_score   = $null
      material_readiness_status   = $null
      planning_group              = (Get-Field -Row $r -Candidates $map.planning_group)
      plant                       = (Get-Field -Row $r -Candidates $map.plant)
      mrp_controller              = (Get-Field -Row $r -Candidates $map.mrp_controller)
    }
  }
  $out | Export-Csv -Path $OutputCsv -NoTypeInformation
}

function Load-CsvToSql {
  param(
    [Parameter(Mandatory)] [string]$CsvPath,
    [Parameter(Mandatory)] [string]$TableName,
    [Parameter(Mandatory)] [string]$ConnectionString
  )
  if (-not (Test-Path $CsvPath)) { Write-Warning "Missing CSV $CsvPath"; return }
  Write-Host "[SQL] Bulk loading $CsvPath -> $TableName"
  $dt = New-Object System.Data.DataTable
  $csv = Import-Csv -Path $CsvPath
  if (-not $csv) { Write-Warning "Empty CSV $CsvPath"; return }
  # Build schema from headers
  $csv[0].psobject.Properties.Name | ForEach-Object { [void]$dt.Columns.Add($_) }
  foreach ($row in $csv) {
    $dr = $dt.NewRow()
    foreach ($col in $dt.Columns) { $dr[$col.ColumnName] = $row.($col.ColumnName) }
    [void]$dt.Rows.Add($dr)
  }
  $conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
  $conn.Open()
  try {
    $bulk = New-Object System.Data.SqlClient.SqlBulkCopy($conn)
    $bulk.DestinationTableName = $TableName
    $dt.Columns | ForEach-Object { [void]$bulk.ColumnMappings.Add($_.ColumnName, $_.ColumnName) }
    $bulk.WriteToServer($dt)
  } finally { $conn.Close() }
}

function Invoke-Sql {
  param(
    [Parameter(Mandatory)] [string]$ConnectionString,
    [Parameter(Mandatory)] [string]$Sql
  )
  $conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
  $cmd = $conn.CreateCommand()
  $cmd.CommandText = $Sql
  $cmd.CommandTimeout = 600
  $conn.Open()
  try { [void]$cmd.ExecuteNonQuery() } finally { $conn.Close() }
}

function Update-Readiness {
  param([string]$ConnectionString)
  Write-Host "[SQL] Computing readiness via sp_MST_UpdateReadiness"
  Invoke-Sql -ConnectionString $ConnectionString -Sql 'EXEC dbo.sp_MST_UpdateReadiness;'
}

# --- Orchestration ---
Ensure-StagingDir -Path $StagingDir

$paths = [pscustomobject]@{
  PMMO_PEGGING   = Join-Path $StagingDir "PMMO_PEGGING_$RunDate.csv"
  ZMRP_EXCEPTION = Join-Path $StagingDir "ZMRPEXCEPTION_$RunDate.csv"
  ZINVT          = Join-Path $StagingDir "ZINVT_$RunDate.csv"
  COOIS          = Join-Path $StagingDir "COOIS_$RunDate.csv"
  ZOPEN          = Join-Path $StagingDir "ZOPEN_$RunDate.csv"
  CSR            = Join-Path $StagingDir "CSR_$RunDate.csv"
  MARC_MARA      = Join-Path $StagingDir "MARC_MARA_$RunDate.csv"
  ZMRP_XFORM     = Join-Path $StagingDir "ZMRPEXCEPTION_XFORM_$RunDate.csv"
  MST_XFORM      = Join-Path $StagingDir "MST_FROM_PMMO_$RunDate.csv"
}

# Stage 1: Acquire (placeholders for SAP/SAC automation)
Get-SapReport -TCode 'PMMO_PEGGING'   -OutputCsv $paths.PMMO_PEGGING
Get-SapReport -TCode 'ZMRPEXCEPTION'  -OutputCsv $paths.ZMRP_EXCEPTION
Get-SapReport -TCode 'ZINVT'          -OutputCsv $paths.ZINVT
Get-SapReport -TCode 'COOIS'          -OutputCsv $paths.COOIS
Get-SapReport -TCode 'ZOPEN'          -OutputCsv $paths.ZOPEN
Export-CsrFromSac -OutputCsv $paths.CSR
# Weekly
# Get-SapReport -TCode 'MARC_MARA' -OutputCsv $paths.MARC_MARA

# Stage 2: Transform
Transform-ZmrpException -InputCsv $paths.ZMRP_EXCEPTION -OutputCsv $paths.ZMRP_XFORM
Transform-PmmoPeggingToMst -InputCsv $paths.PMMO_PEGGING -OutputCsv $paths.MST_XFORM
# TODO: Add computation for remaining_hours (capacity), late/capacity flags if you have external inputs

# Stage 3: Load & Compile
Load-CsvToSql -CsvPath $paths.ZMRP_XFORM -TableName 'dbo.Raw_Exceptions' -ConnectionString $SqlConnectionString
Load-CsvToSql -CsvPath $paths.MST_XFORM  -TableName 'dbo.Material_Status_Tracker' -ConnectionString $SqlConnectionString

# Compute readiness status
try {
  Update-Readiness -ConnectionString $SqlConnectionString
} catch {
  Write-Warning "Readiness update failed: $($_.Exception.Message)"
}

Write-Host "ETL pipeline completed (skeleton). Fill in SAP automation and mappings."
