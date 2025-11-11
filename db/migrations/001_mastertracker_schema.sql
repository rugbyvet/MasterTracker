-- MasterTracker Schema Initialization (SQL Server)
-- Run on SQL Server 2016 SP1+ (supports CREATE OR ALTER)
-- Creates core tables, indexes, seeds, and readiness procedure.

SET NOCOUNT ON;
GO

/* 1) Projects */
IF OBJECT_ID(N'dbo.Projects', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.Projects (
    project_unique_id   uniqueidentifier NOT NULL CONSTRAINT DF_Projects_project_unique_id DEFAULT NEWSEQUENTIALID(),
    pspnr_assgd         nvarchar(50)     NOT NULL, -- PMMO WBS global key
    project_name        nvarchar(200)    NULL,
    program_name        nvarchar(200)    NULL,
    is_active           bit              NOT NULL CONSTRAINT DF_Projects_is_active DEFAULT (1),
    ingested_at_utc     datetime2(3)     NOT NULL CONSTRAINT DF_Projects_ingested_at_utc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Projects PRIMARY KEY CLUSTERED (project_unique_id),
    CONSTRAINT UQ_Projects_pspnr_assgd UNIQUE (pspnr_assgd)
  );
END
GO

/* 2) Materials_Master */
IF OBJECT_ID(N'dbo.Materials_Master', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.Materials_Master (
    material_number         nvarchar(40)   NOT NULL,   -- SAP material number
    material_description    nvarchar(200)  NULL,
    material_group          nvarchar(40)   NULL,
    base_uom                nvarchar(9)    NULL,
    plant                   nvarchar(10)   NULL,
    mrp_type                nvarchar(10)   NULL,
    mrp_controller          nvarchar(10)   NULL,
    procurement_type        nvarchar(10)   NULL,
    ingested_at_utc         datetime2(3)   NOT NULL CONSTRAINT DF_Materials_Master_ingested_at_utc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Materials_Master PRIMARY KEY CLUSTERED (material_number)
  );
END
GO

/* 3) Material_Readiness_Status_Lookup */
IF OBJECT_ID(N'dbo.Material_Readiness_Status_Lookup', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.Material_Readiness_Status_Lookup (
    material_readiness_status nvarchar(16) NOT NULL PRIMARY KEY, -- READY/AT_RISK/LATE/MISSING/UNKNOWN
    precedence                tinyint      NOT NULL
  );
END
GO

/* 4) Raw_Exceptions */
IF OBJECT_ID(N'dbo.Raw_Exceptions', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.Raw_Exceptions (
    exception_unique_id   uniqueidentifier NOT NULL CONSTRAINT DF_Raw_Exceptions_exception_unique_id DEFAULT NEWSEQUENTIALID(),
    material_number       nvarchar(40)     NOT NULL,
    parsed_order_id       nvarchar(64)     NULL,
    exception_type        nvarchar(64)     NULL,
    exception_code        nvarchar(32)     NULL,
    severity_level        tinyint          NULL,
    exception_text        nvarchar(4000)   NULL,
    raised_on_utc         datetime2(3)     NULL,
    age_days              int              NULL,
    source_row_hash       varbinary(32)    NULL,
    ingested_at_utc       datetime2(3)     NOT NULL CONSTRAINT DF_Raw_Exceptions_ingested_at_utc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Raw_Exceptions PRIMARY KEY CLUSTERED (exception_unique_id),
    CONSTRAINT FK_Raw_Exceptions_Materials FOREIGN KEY (material_number) REFERENCES dbo.Materials_Master(material_number)
  );
END
GO

/* 5) Material_Status_Tracker */
IF OBJECT_ID(N'dbo.Material_Status_Tracker', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.Material_Status_Tracker (
    tracker_unique_id           uniqueidentifier NOT NULL CONSTRAINT DF_MST_tracker_unique_id DEFAULT NEWSEQUENTIALID(),

    project_global_id           nvarchar(50)     NOT NULL,   -- FK to Projects.pspnr_assgd
    top_req_obj                 nvarchar(50)     NOT NULL,   -- RQMTOBJ_TOP
    repobj_nha                  nvarchar(50)     NULL,       -- REPOBJ_NHA
    repobj                      nvarchar(50)     NULL,       -- REPOBJ (nullable => MISSING)
    pspnr_assgd                 nvarchar(50)     NULL,       -- optional lineage copy
    material_number             nvarchar(40)     NOT NULL,   -- FK to Materials_Master

    assgdqty                    decimal(18,3)    NULL,
    xssqty                      decimal(18,3)    NULL,
    creation_datetime_utc       datetime2(3)     NULL,
    last_change_datetime_utc    datetime2(3)     NULL,

    -- Readiness drivers
    rqmt_date_utc               datetime2(3)     NULL,
    repobj_date_utc             datetime2(3)     NULL,
    remaining_hours             decimal(18,2)    NULL,
    late_supply_flag            bit              NULL,
    capacity_risk_flag          bit              NULL,
    exception_severity_score    decimal(10,2)    NULL,
    planner_load_impact_score   decimal(10,2)    NULL,

    -- Resulting status (FK to lookup)
    material_readiness_status   nvarchar(16)     NULL,

    -- Context
    planning_group              nvarchar(64)     NULL,
    plant                       nvarchar(10)     NULL,
    mrp_controller              nvarchar(10)     NULL,
    source_system               nvarchar(32)     NULL,
    source_row_hash             varbinary(32)    NULL,
    ingested_at_utc             datetime2(3)     NOT NULL CONSTRAINT DF_MST_ingested_at_utc DEFAULT SYSUTCDATETIME(),

    CONSTRAINT PK_Material_Status_Tracker PRIMARY KEY CLUSTERED (tracker_unique_id),
    CONSTRAINT FK_MST_Projects_Global FOREIGN KEY (project_global_id) REFERENCES dbo.Projects(pspnr_assgd),
    CONSTRAINT FK_MST_Materials       FOREIGN KEY (material_number)   REFERENCES dbo.Materials_Master(material_number),
    CONSTRAINT FK_MST_Status          FOREIGN KEY (material_readiness_status) REFERENCES dbo.Material_Readiness_Status_Lookup(material_readiness_status)
  );
END
GO

/* 6) Risk_Thresholds */
IF OBJECT_ID(N'dbo.Risk_Thresholds', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.Risk_Thresholds (
    risk_config_id              int IDENTITY(1,1) PRIMARY KEY,
    plant                       nvarchar(10)   NULL,
    mrp_controller              nvarchar(10)   NULL,
    planning_group              nvarchar(64)   NULL,
    capacity_hours_threshold    decimal(18,2)  NOT NULL,
    late_days_threshold         int            NOT NULL,
    severity_threshold_med      decimal(10,2)  NOT NULL,
    severity_threshold_high     decimal(10,2)  NOT NULL,
    planner_load_threshold      decimal(10,2)  NOT NULL,
    alpha_exception_count       decimal(10,4)  NOT NULL DEFAULT (1.0),
    beta_remaining_hours        decimal(10,4)  NOT NULL DEFAULT (0.10),
    is_default                  bit            NOT NULL DEFAULT (0)
  );
END
GO

/* 7) Exception_Weights */
IF OBJECT_ID(N'dbo.Exception_Weights', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.Exception_Weights (
    exception_code              nvarchar(32)   NOT NULL PRIMARY KEY,
    weight                      decimal(10,2)  NOT NULL,
    severity_level              tinyint        NULL
  );
END
GO

/* Indexes */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Materials_Master_desc' AND object_id = OBJECT_ID('dbo.Materials_Master'))
  CREATE NONCLUSTERED INDEX IX_Materials_Master_desc ON dbo.Materials_Master (material_description);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Raw_Exceptions_material' AND object_id = OBJECT_ID('dbo.Raw_Exceptions'))
  CREATE NONCLUSTERED INDEX IX_Raw_Exceptions_material ON dbo.Raw_Exceptions (material_number);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Raw_Exceptions_parsed' AND object_id = OBJECT_ID('dbo.Raw_Exceptions'))
  CREATE NONCLUSTERED INDEX IX_Raw_Exceptions_parsed ON dbo.Raw_Exceptions (parsed_order_id) INCLUDE (exception_code, severity_level, raised_on_utc);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Raw_Exceptions_severity' AND object_id = OBJECT_ID('dbo.Raw_Exceptions'))
  CREATE NONCLUSTERED INDEX IX_Raw_Exceptions_severity ON dbo.Raw_Exceptions (severity_level, raised_on_utc DESC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MST_project_status' AND object_id = OBJECT_ID('dbo.Material_Status_Tracker'))
  CREATE NONCLUSTERED INDEX IX_MST_project_status ON dbo.Material_Status_Tracker (project_global_id, material_readiness_status);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MST_material' AND object_id = OBJECT_ID('dbo.Material_Status_Tracker'))
  CREATE NONCLUSTERED INDEX IX_MST_material ON dbo.Material_Status_Tracker (material_number);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MST_topreq' AND object_id = OBJECT_ID('dbo.Material_Status_Tracker'))
  CREATE NONCLUSTERED INDEX IX_MST_topreq ON dbo.Material_Status_Tracker (top_req_obj);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MST_repo' AND object_id = OBJECT_ID('dbo.Material_Status_Tracker'))
  CREATE NONCLUSTERED INDEX IX_MST_repo ON dbo.Material_Status_Tracker (repobj);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MST_dates' AND object_id = OBJECT_ID('dbo.Material_Status_Tracker'))
  CREATE NONCLUSTERED INDEX IX_MST_dates ON dbo.Material_Status_Tracker (last_change_datetime_utc DESC) INCLUDE (material_readiness_status, project_global_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MST_flags_status' AND object_id = OBJECT_ID('dbo.Material_Status_Tracker'))
  CREATE NONCLUSTERED INDEX IX_MST_flags_status ON dbo.Material_Status_Tracker (material_readiness_status, late_supply_flag, capacity_risk_flag) INCLUDE (project_global_id, material_number, repobj_date_utc, rqmt_date_utc);
GO

/* API View */
CREATE OR ALTER VIEW dbo.v_Material_Status_Tracker AS
SELECT
    mst.tracker_unique_id,
    p.project_unique_id,
    mst.project_global_id,
    p.project_name,
    p.program_name,
    mst.material_number,
    mm.material_description,
    mst.top_req_obj,
    mst.repobj_nha,
    mst.repobj,
    mst.assgdqty,
    mst.xssqty,
    mst.creation_datetime_utc,
    mst.last_change_datetime_utc,
    mst.material_readiness_status,
    mst.planning_group,
    mst.plant,
    mst.mrp_controller,
    mst.rqmt_date_utc,
    mst.repobj_date_utc,
    mst.late_supply_flag,
    mst.capacity_risk_flag,
    mst.exception_severity_score,
    mst.planner_load_impact_score,
    mst.ingested_at_utc
FROM dbo.Material_Status_Tracker mst
JOIN dbo.Projects p
  ON p.pspnr_assgd = mst.project_global_id
LEFT JOIN dbo.Materials_Master mm
  ON mm.material_number = mst.material_number;
GO

/* Readiness Update Procedure */
CREATE OR ALTER PROCEDURE dbo.sp_MST_UpdateReadiness
AS
BEGIN
  SET NOCOUNT ON;

  ;WITH ex AS (
    SELECT
      mst.tracker_unique_id,
      SUM(COALESCE(w.weight, 1.0)) AS severity_score,
      COUNT(*)                      AS exception_count
    FROM dbo.Material_Status_Tracker mst
    JOIN dbo.Raw_Exceptions re
      ON re.parsed_order_id = mst.repobj
    LEFT JOIN dbo.Exception_Weights w
      ON w.exception_code = re.exception_code
    WHERE mst.repobj IS NOT NULL
    GROUP BY mst.tracker_unique_id
  ),
  cfg AS (
    SELECT
      mst.tracker_unique_id,
      COALESCE(rt.capacity_hours_threshold, rtd.capacity_hours_threshold) AS capacity_hours_threshold,
      COALESCE(rt.late_days_threshold,      rtd.late_days_threshold)      AS late_days_threshold,
      COALESCE(rt.severity_threshold_med,   rtd.severity_threshold_med)   AS severity_threshold_med,
      COALESCE(rt.severity_threshold_high,  rtd.severity_threshold_high)  AS severity_threshold_high,
      COALESCE(rt.planner_load_threshold,   rtd.planner_load_threshold)   AS planner_load_threshold,
      COALESCE(rt.alpha_exception_count,    rtd.alpha_exception_count)    AS alpha_exception_count,
      COALESCE(rt.beta_remaining_hours,     rtd.beta_remaining_hours)     AS beta_remaining_hours
    FROM dbo.Material_Status_Tracker mst
    OUTER APPLY (
      SELECT TOP (1) *
      FROM dbo.Risk_Thresholds t
      WHERE (t.plant = mst.plant OR t.plant IS NULL)
        AND (t.mrp_controller = mst.mrp_controller OR t.mrp_controller IS NULL)
        AND (t.planning_group = mst.planning_group OR t.planning_group IS NULL)
      ORDER BY
        CASE WHEN t.plant IS NOT NULL THEN 1 ELSE 0 END +
        CASE WHEN t.mrp_controller IS NOT NULL THEN 1 ELSE 0 END +
        CASE WHEN t.planning_group IS NOT NULL THEN 1 ELSE 0 END DESC
    ) rt
    CROSS APPLY (
      SELECT TOP (1) *
      FROM dbo.Risk_Thresholds d
      WHERE d.is_default = 1
      ORDER BY d.risk_config_id
    ) rtd
  )
  UPDATE mst
  SET
    mst.exception_severity_score   = COALESCE(ex.severity_score, 0),
    mst.planner_load_impact_score  = COALESCE(ex.exception_count, 0) * cfg.alpha_exception_count
                                     + COALESCE(mst.remaining_hours, 0) * cfg.beta_remaining_hours,
    mst.late_supply_flag           = CASE
                                       WHEN mst.repobj_date_utc IS NOT NULL
                                         AND mst.rqmt_date_utc IS NOT NULL
                                         AND DATEDIFF(DAY, mst.rqmt_date_utc, mst.repobj_date_utc) > cfg.late_days_threshold
                                       THEN 1 ELSE 0 END,
    mst.capacity_risk_flag         = CASE
                                       WHEN mst.remaining_hours IS NOT NULL
                                         AND cfg.capacity_hours_threshold IS NOT NULL
                                         AND mst.remaining_hours > cfg.capacity_hours_threshold
                                       THEN 1 ELSE 0 END,
    mst.material_readiness_status  =
      CASE
        WHEN mst.repobj IS NULL OR COALESCE(mst.assgdqty,0) = 0
          THEN N'MISSING'
        WHEN mst.rqmt_date_utc IS NULL AND mst.repobj_date_utc IS NULL
             AND COALESCE(ex.severity_score, 0) = 0
             AND mst.remaining_hours IS NULL
          THEN N'UNKNOWN'
        WHEN (mst.late_supply_flag = 1)
          OR (COALESCE(ex.severity_score,0) >= cfg.severity_threshold_high)
          THEN N'LATE'
        WHEN (mst.capacity_risk_flag = 1)
          OR (COALESCE(ex.severity_score,0) >= cfg.severity_threshold_med)
          OR (COALESCE(ex.exception_count,0) * cfg.alpha_exception_count
            + COALESCE(mst.remaining_hours,0) * cfg.beta_remaining_hours) >= cfg.planner_load_threshold
          THEN N'AT_RISK'
        ELSE N'READY'
      END
  FROM dbo.Material_Status_Tracker mst
  LEFT JOIN ex  ON ex.tracker_unique_id = mst.tracker_unique_id
  JOIN cfg      ON cfg.tracker_unique_id = mst.tracker_unique_id;
END;
GO

/* Seed Status Domain */
MERGE dbo.Material_Readiness_Status_Lookup AS t
USING (VALUES
  (N'UNKNOWN', 0),
  (N'READY',   1),
  (N'AT_RISK', 2),
  (N'LATE',    3),
  (N'MISSING', 4)
) AS s(status, precedence)
ON t.material_readiness_status = s.status
WHEN NOT MATCHED THEN INSERT (material_readiness_status, precedence) VALUES (s.status, s.precedence);
GO

/* Seed Default Thresholds (if none default exists) */
IF NOT EXISTS (SELECT 1 FROM dbo.Risk_Thresholds WHERE is_default = 1)
BEGIN
  INSERT INTO dbo.Risk_Thresholds
    (is_default, capacity_hours_threshold, late_days_threshold,
     severity_threshold_med, severity_threshold_high, planner_load_threshold,
     alpha_exception_count, beta_remaining_hours)
  VALUES
    (1, 40.0, 0, 5.0, 10.0, 8.0, 1.0, 0.10);
END
GO

/* Seed Example Exception Weights (replace with actual SAP codes) */
MERGE dbo.Exception_Weights AS t
USING (VALUES
  (N'EXC_MINOR', 1.0, 1),
  (N'EXC_MED',   3.0, 2),
  (N'EXC_HIGH',  6.0, 3)
) AS s(code, weight, sev)
ON t.exception_code = s.code
WHEN NOT MATCHED THEN INSERT (exception_code, weight, severity_level) VALUES (s.code, s.weight, s.sev);
GO

