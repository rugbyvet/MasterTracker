The following document constitutes the complete Product Requirements Document (PRD) for the MasterTracker application. This markdown file serves as the **single source of truth** for the AI co-pilot, a critical step for achieving **much better results** and ensuring the system design is consistent.

***

# Product Requirements Document: MasterTracker (Project PMMO Backbone)

## 1. Executive Summary and Project Goals

The MasterTracker application is an **internal-use only** tool designed to automate the current, time-intensive manual data extraction process from SAP T-Codes and SAC reports. The goal is to **build a unified PMMO-driven planner tool** (project focus, performance visibility, program mgmt feed) and establish an **integrated learning platform**.

### **Key Measurable Targets (Success Metrics):**

*   **Report prep time reduction:** **-80%**
*   **Exception noise reduction:** **-30%**
*   **SO surprises reduction:** **-50%**
*   **WIP accuracy target:** **90%**
*   **KPI Tree Structure:** COTD $\rightarrow$ Release Adherence $\rightarrow$ Material Readiness $\rightarrow$ Routing Accuracy $\rightarrow$ Capacity Discipline.

## 2. Constraints and Technical Environment

The solution must be developed using an AI co-pilot and must strictly adhere to the following limitations imposed by the work environment:

| Constraint Category | Requirement / Limitation | Source Support |
| :--- | :--- | :--- |
| **Execution Environment** | The application **cannot be executed locally**; the environment is **limited (GCC, no executables)**. | |
| **Sanctioned Tools** | Development must leverage: **PowerShell, CMD, MS Visual Studio, web AI** (for cloud/remote agent development), **CoPilot, and Power Automate**. | |
| **Data Acquisition** | **SAP GUI Scripting** must be used for all SAP T-Code reports [Conversation History]. CSR report must be acquired via **SAP SAC Export**. | [Conversation History, 275] |
| **Development Style** | Project must use **conversation-driven coding** principles. PRD must be the **single source of truth**. | |

## 3. Core Features (Minimum Viable Product - MVP)

| Feature | Description |
| :--- | :--- |
| **PMMO Material Status Tracker** | Must provide material status by project, using **PMMO as the backbone**. |
| **Filtering Capability** | Must allow **Planners and Program Management to filter** the tracker on their material status per project. The API must support filtering and sorting via query parameters in the back end. |
| **Integrated Learning Platform** | Must establish a platform for essential documentation: **SOPs, job aids, directives, and job expectations**. |
| **Data Traceability** | The structure must support linking records across data sets using **Global IDs** [Conversation History]. |

## 4. User Roles and Authorization (RBAC)

The system must implement **Role-Based Access Control (RBAC)** to manage security for internal use.

| User Role | Access Level / Permissions |
| :--- | :--- |
| **Executives/Leadership** | **Viewer/Read-Only Access** to performance visibility (KPI Tree) and final compiled metrics. |
| **Planners** | Access to Material Status Tracker, ability to **filter** and potentially update status (Editor/Contributor). |
| **Program Management**| Access to Material Status Tracker, ability to **filter** (Editor/Contributor). |

## 5. Data Architecture and Pipeline

The data preparation is structured into four sequential stages. **Stage 3 (Compiling)** defines the mandatory **Database Schema** required by the AI co-pilot.

### 5.1 Stage 1: Raw Data Acquisition (Via Scripting)

Data acquisition must adhere to the daily sequencing window via SAP GUI Scripting/SAC Export:

| Report / T-Code | Source | Acquisition Time (PT) | Acquisition Method |
| :--- | :--- | :--- | :--- |
| **PMMO\_PEGGING** | SAP T-Code | 02:00–02:30 | SAP GUI Scripting |
| **ZMRPEXCEPTION** | SAP T-Code | 02:30–02:45 | SAP GUI Scripting |
| **ZINVT** | SAP T-Code | 02:45–03:00 | SAP GUI Scripting |
| **COOIS** | SAP T-Code | 03:00–03:30 | SAP GUI Scripting |
| **ZOPEN** | SAP T-Code | 03:30–03:50 | SAP GUI Scripting |
| **CSR (SAC Export)** | SAP SAC | 03:50–04:10 | SAC Export |
| **MARC / MARA** | SAP T-Code | Weekly Run | SAP GUI Scripting |

**All daily datasets must be ready by 06:00 PT**.

### 5.2 Stage 2: Transformation and Parsing (Mandatory Logic)

*   **PMMO Backbone Construction:** All data must be integrated and standardized around the PMMO pegging structure (RQMTOBJ\_TOP $\rightarrow$ REPOBJ\_NHA $\rightarrow$ REPOBJ).
*   **ZMRPEXCEPTION Parsing:** **Specific parsing and cleanup logic must be applied to `ZMRPEXCEPTION` data** before it can be integrated. This includes normalizing mixed identifiers, stripping suffixes (e.g., `/0010`), and handling text-based quantities/dates. This logic must account for required fields such as exception type, severity, and age.

### 5.3 Stage 3: Compiling (Database Schema/Data Model)

This schema is the **single source of truth** that prevents the front end from "guessing" the back end, which would create a **"real hassle to solve"**.

| Table Name | Description | ID & Key Requirements |
| :--- | :--- | :--- |
| **Projects** | Master table for all Program/Project data (WBS). | **project\_unique\_id** (Unique ID, Primary Key) [Conversation History]. **pspnr\_assgd** (Global Key, links to PMMO). |
| **Material\_Status\_Tracker** | **Core Fact Table.** Row grain is the pegging relationship (Top Requirement $\rightarrow$ Supply Object). Must include calculated **Material Readiness Status**. | **tracker\_unique\_id** (Unique ID, Primary Key) [Conversation History]. **project\_global\_id** (Global Key, Foreign Key to Projects) [Conversation History]. **material\_number** (Global Key). **top\_req\_obj** (Global Key, `RQMTOBJ_TOP`). |
| **Raw\_Exceptions** | Stores parsed `ZMRPEXCEPTION` output (Stage 2). | **exception\_unique\_id** (Unique ID, Primary Key) [Conversation History]. **material\_number** (Global Key). **parsed\_order\_id** (Global Key, derived from MRP Element). |
| **Materials\_Master** | Material attributes (MARC/MARA data). | **material\_number** (Global Key, Primary Key). |

**Key Fields from PMMO Data Dictionary to be included in Schema:**

*   **RQMTOBJ\_TOP:** Top-level requirement object.
*   **REPOBJ\_NHA:** Immediate Parent/Next Higher Assembly.
*   **REPOBJ:** Supply object (PR/PO/WO/Stock).
*   **PSPNR\_ASSGD:** Assigned WBS element.
*   **ASSGDQTY / XSSQTY:** Allocated Quantity / Excess Quantity.
*   **CREATIONDATETIME / LASTCHANGEDATETIME:** Timestamps for version tracking.

### 5.4 Stage 4: Reporting (API Layer)

*   **API Design:** API must be designed for **simplicity** and **consistency** (using consistent naming and patterns).
*   **Performance:** Must use **pagination** if large datasets are retrieved. API must support **filtering** and **sorting** in the back end via query parameters to optimize performance.
*   **Real-time Potential:** Although HTTP is standard, consider the use of **WebSockets** for potential future real-time SO Change Alerts.

## 6. Future Enhancements (Roadmap)

The following are defined for later phases:

*   **PMMO Intelligence Tool (Pilot #2)**
*   **Material Transfer Workflow Digitization** (to replace manual signatures)
*   **Email Task Triage**
*   **Automated BOM/router validation**

***

## Conclusion for AI Co-Pilot

The requirements above provide the necessary **documentation** and **architecture** to begin development. Focus the initial build on automating the **SAP GUI Scripting** via PowerShell/CMD (Stage 1) and implementing the **Transformation/Compiling** logic (Stages 2 & 3) based on the mandatory **Database Schema** and **PMMO backbone**. By providing this PRD, you ensure the AI co-pilot will maximize efficiency and achieve the defined success metrics.