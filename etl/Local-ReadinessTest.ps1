<#
 Local Readiness Test (No SQL)
 - Reads Excel-exported CSVs from a Teams folder
 - Normalizes headers, computes readiness per PRD rules
 - Writes combined results CSV back to Teams folder

 Expected Inputs (CSV in Teams folder)
 - PMMO_PEGGING*.csv: pegging/backbone (RQMTOBJ_TOP -> REPOBJ)
 - ZMRPEXCEPTION*.csv: MRP exceptions (optional but recommended)
 - Exception_Weights.csv: optional weights {exception_code, weight, severity_level}
 - Risk_Thresholds.csv: optional thresholds with optional scoping {plant, mrp_controller, planning_group}
 - PlannerCapacity.csv: optional remaining hours by repobj {repobj, remaining_hours}

 Outputs
 - MasterTracker_Readiness_<RunDate>.csv

 Notes
 - No external modules required; PowerShell only
 - Uses sensible defaults if optional inputs are missing
#>

param(
  [Parameter(Mandatory=$true)] [string]$TeamsFolder,
  [string]$RunDate = (Get-Date -Format 'yyyy-MM-dd')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LatestCsv {
  param([string]$Folder,[string]$Pattern)
  $files = Get-ChildItem -Path $Folder -Filter $Pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
  if ($files -and $files.Count -gt 0) { return $files[0].FullName }
  return $null
}

function Normalize-Identifier { param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  ($Value -replace '/\d{3,4}$','').Trim()
}

function Get-Field { param([psobject]$Row,[string[]]$Candidates)
  foreach ($c in $Candidates) { if ($Row.PSObject.Properties.Name -contains $c) { return $Row.$c } }
  return $null
}

function To-NullableDecimal { param([object]$Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  try { return [decimal]$Value } catch { return $null }
}

function To-NullableDate { param([object]$Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  try { return [datetime]$Value } catch { return $null }
}

function Load-OptionalCsv { param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
  if (-not (Test-Path $Path)) { return @() }
  try { return (Import-Csv -Path $Path) } catch { return @() }
}

# Locate inputs
$pmmoPath = Get-LatestCsv -Folder $TeamsFolder -Pattern 'PMMO_PEGGING*.csv'
$zmrpPath = Get-LatestCsv -Folder $TeamsFolder -Pattern 'ZMRPEXCEPTION*.csv'
$weightsPath = Join-Path $TeamsFolder 'Exception_Weights.csv'
$thresholdsPath = Join-Path $TeamsFolder 'Risk_Thresholds.csv'
$capacityPath = Join-Path $TeamsFolder 'PlannerCapacity.csv'

if (-not $pmmoPath) { throw "PMMO_PEGGING CSV not found in $TeamsFolder" }
Write-Host "Using PMMO: $pmmoPath"
if ($zmrpPath) { Write-Host "Using ZMRPEXCEPTION: $zmrpPath" } else { Write-Warning 'ZMRPEXCEPTION CSV not found; exceptions will be treated as zero.' }

# Load optional configs
$weights = Load-OptionalCsv -Path $weightsPath
$thresholds = Load-OptionalCsv -Path $thresholdsPath
$capacity = Load-OptionalCsv -Path $capacityPath

# Default thresholds (used when no scoped row matches)
$defaultThreshold = [pscustomobject]@{
  capacity_hours_threshold = 40.0
  late_days_threshold      = 0
  severity_threshold_med   = 5.0
  severity_threshold_high  = 10.0
  planner_load_threshold   = 8.0
  alpha_exception_count    = 1.0
  beta_remaining_hours     = 0.10
}

function Resolve-Threshold {
  param([psobject]$Row)
  if (-not $thresholds -or $thresholds.Count -eq 0) { return $defaultThreshold }
  $candidates = $thresholds | Where-Object {
    ($_.plant -eq $Row.plant -or [string]::IsNullOrWhiteSpace($_.plant)) -and
    ($_.mrp_controller -eq $Row.mrp_controller -or [string]::IsNullOrWhiteSpace($_.mrp_controller)) -and
    ($_.planning_group -eq $Row.planning_group -or [string]::IsNullOrWhiteSpace($_.planning_group))
  }
  if (-not $candidates -or $candidates.Count -eq 0) { return $defaultThreshold }
  # Prefer most specific (non-null matches count)
  $ranked = $candidates | ForEach-Object {
    $score = 0
    if (-not [string]::IsNullOrWhiteSpace($_.plant)) { $score++ }
    if (-not [string]::IsNullOrWhiteSpace($_.mrp_controller)) { $score++ }
    if (-not [string]::IsNullOrWhiteSpace($_.planning_group)) { $score++ }
    [pscustomobject]@{ row = $_; score = $score }
  } | Sort-Object score -Descending
  return $ranked[0].row
}

function Get-Weight { param([string]$Code)
  if (-not $Code) { return 1.0 }
  $w = $weights | Where-Object { $_.exception_code -eq $Code }
  if ($w) { return (To-NullableDecimal $w[0].weight) ?? 1.0 }
  return 1.0
}

# Header candidates (adjust to match your Excel export headers)
$mapPeg = @{
  project_global_id        = @('pspnr_assgd','PSPNR_ASSGD','ProjectWBS','WBS')
  top_req_obj              = @('RQMTOBJ_TOP','TopReqObj','TOP_REQ_OBJ')
  repobj_nha               = @('REPOBJ_NHA','Parent','NextHigherAssembly')
  repobj                   = @('REPOBJ','SupplyObject','Supply_Obj','MRP_Element')
  material_number          = @('material_number','Material','MATNR')
  assgdqty                 = @('ASSGDQTY','AllocatedQty')
  xssqty                   = @('XSSQTY','ExcessQty')
  rqmt_date_utc            = @('RQMT_DATE','RequirementDate')
  repobj_date_utc          = @('REPOBJ_DATE','SupplyDate','CommitDate')
  planning_group           = @('PlanningGroup')
  plant                    = @('Plant','WERK')
  mrp_controller           = @('MRPController','DISPO')
}

$mapExc = @{
  repobj         = @('parsed_order_id','MRP_Element','MRPElement','REPOBJ')
  exception_code = @('exception_code','ExceptionCode','EXCCODE','Exception Code')
  raised_on_utc  = @('raised_on_utc','RaisedOnUtc','Raised On','RAISED_ON')
}

# Load PMMO
$pmmoRows = Import-Csv -Path $pmmoPath
if (-not $pmmoRows) { throw 'PMMO CSV is empty.' }

# Load exceptions (optional)
$excRows = @()
if ($zmrpPath) { $excRows = Import-Csv -Path $zmrpPath }

# Build exception aggregates by repobj
$excAgg = @{}
foreach ($er in $excRows) {
  $rep = Normalize-Identifier (Get-Field -Row $er -Candidates $mapExc.repobj)
  if (-not $rep) { continue }
  $code = (Get-Field -Row $er -Candidates $mapExc.exception_code)
  $w = Get-Weight -Code $code
  if (-not $excAgg.ContainsKey($rep)) {
    $excAgg[$rep] = [pscustomobject]@{ count = 0; score = 0.0 }
  }
  $excAgg[$rep].count += 1
  $excAgg[$rep].score += $w
}

# Capacity map by repobj (optional)
$capByRep = @{}
foreach ($cr in $capacity) {
  $r = Normalize-Identifier $cr.repobj
  if ($r) { $capByRep[$r] = To-NullableDecimal $cr.remaining_hours }
}

# Compute readiness per PMMO row
$out = foreach ($r in $pmmoRows) {
  $project = (Get-Field -Row $r -Candidates $mapPeg.project_global_id)
  $topreq  = Normalize-Identifier (Get-Field -Row $r -Candidates $mapPeg.top_req_obj)
  $repnha  = Normalize-Identifier (Get-Field -Row $r -Candidates $mapPeg.repobj_nha)
  $rep     = Normalize-Identifier (Get-Field -Row $r -Candidates $mapPeg.repobj)
  $mat     = (Get-Field -Row $r -Candidates $mapPeg.material_number)
  $assgd   = To-NullableDecimal (Get-Field -Row $r -Candidates $mapPeg.assgdqty)
  $xss     = To-NullableDecimal (Get-Field -Row $r -Candidates $mapPeg.xssqty)
  $rqmtDt  = To-NullableDate (Get-Field -Row $r -Candidates $mapPeg.rqmt_date_utc)
  $repoDt  = To-NullableDate (Get-Field -Row $r -Candidates $mapPeg.repobj_date_utc)
  $plant   = (Get-Field -Row $r -Candidates $mapPeg.plant)
  $mrp     = (Get-Field -Row $r -Candidates $mapPeg.mrp_controller)
  $pg      = (Get-Field -Row $r -Candidates $mapPeg.planning_group)

  $thr = Resolve-Threshold ([pscustomobject]@{ plant=$plant; mrp_controller=$mrp; planning_group=$pg })
  $exCount = 0; $exScore = 0.0
  if ($rep -and $excAgg.ContainsKey($rep)) {
    $exCount = $excAgg[$rep].count
    $exScore = $excAgg[$rep].score
  }
  $remHours = $null
  if ($rep -and $capByRep.ContainsKey($rep)) { $remHours = $capByRep[$rep] }

  $lateFlag = $false
  if ($rqmtDt -and $repoDt) {
    $days = [int]([TimeSpan]::FromTicks(($repoDt - $rqmtDt).Ticks).TotalDays)
    if ($days -gt [int]$thr.late_days_threshold) { $lateFlag = $true }
  }

  $capFlag = $false
  if ($remHours -ne $null -and $remHours -gt [decimal]$thr.capacity_hours_threshold) { $capFlag = $true }

  $plannerLoad = ($exCount * [decimal]$thr.alpha_exception_count) + ((($remHours -ne $null) ? $remHours : 0) * [decimal]$thr.beta_remaining_hours)

  $status = 'READY'
  if ([string]::IsNullOrWhiteSpace($rep) -or ($assgd -eq $null -or $assgd -eq 0)) {
    $status = 'MISSING'
  } elseif (-not $rqmtDt -and -not $repoDt -and $exScore -eq 0 -and $remHours -eq $null) {
    $status = 'UNKNOWN'
  } elseif ($lateFlag -or $exScore -ge [decimal]$thr.severity_threshold_high) {
    $status = 'LATE'
  } elseif ($capFlag -or $exScore -ge [decimal]$thr.severity_threshold_med -or $plannerLoad -ge [decimal]$thr.planner_load_threshold) {
    $status = 'AT_RISK'
  }

  [pscustomobject]@{
    tracker_unique_id           = [guid]::NewGuid()
    project_global_id           = $project
    top_req_obj                 = $topreq
    repobj_nha                  = $repnha
    repobj                      = $rep
    material_number             = $mat
    assgdqty                    = $assgd
    xssqty                      = $xss
    rqmt_date_utc               = if ($rqmtDt) { $rqmtDt.ToString('s') } else { $null }
    repobj_date_utc             = if ($repoDt) { $repoDt.ToString('s') } else { $null }
    late_supply_flag            = [int]$lateFlag
    capacity_risk_flag          = [int]$capFlag
    exception_severity_score    = [decimal]::Round([decimal]$exScore,2)
    planner_load_impact_score   = [decimal]::Round([decimal]$plannerLoad,2)
    material_readiness_status   = $status
    planning_group              = $pg
    plant                       = $plant
    mrp_controller              = $mrp
  }
}

$outPath = Join-Path $TeamsFolder ("MasterTracker_Readiness_{0}.csv" -f $RunDate)
$out | Export-Csv -Path $outPath -NoTypeInformation -Encoding UTF8
Write-Host "Wrote readiness results: $outPath"

