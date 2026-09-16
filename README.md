# OntoTrial – Clinical Trial Eligibility & Phenotyping Framework

An integrated, full-stack environment for structured clinical trial eligibility definition, cohort feasibility analysis, and longitudinal patient matching. The platform bridges unstructured clinical trial protocols and medical narrative reports with standardized ontologies and interoperable health data standards.

Originally centered on the Human Phenotype Ontology (HPO), OntoTrial now offers unified multi-ontology semantic extraction, normalization, and hierarchical querying across **HPO**, **ICD-10-GM**, **OPS**, **ATC** and **LOINC**

<img width="2033" height="1022" alt="Bildschirmfoto 2026-09-15 um 15 29 21" src="https://github.com/user-attachments/assets/421e4515-8eb7-4c70-9790-1d21a1f340d0" />
<img width="1860" height="1028" alt="OntoTrial Phenotype Tree Browser" src="https://github.com/user-attachments/assets/f7c86a01-2ce4-4fbc-83fa-633d0b4c1e6d" />
<img width="853" height="607" alt="grafik" src="https://github.com/user-attachments/assets/49591f73-51f6-4c49-b6ab-efd2b1a74083" />

---

## Multi-Ontology & Advanced Clinical Features

OntoTrial has evolved beyond phenotype-only extraction into a multi-terminology clinical intelligence engine:

| Domain | Ontology / Standard | Scope & Implementation |
| :--- | :--- | :--- |
| **Phenotypes & Symptoms** | **HPO** (*Human Phenotype Ontology*) | Recursive `isas` hierarchy traversal, synonym matching, xref lookup, and subsumption testing. |
| **Diagnoses & Conditions** | **ICD-10 / ICD-10-GM** | Formal diagnostic codes, German modification hierarchy, automated drug allergy mapping (`Z88.8` + ATC). |
| **Procedures & Surgeries** | **OPS** (*Operationen- und Prozedurenschlüssel*) | Surgical and diagnostic interventions, BfArM hierarchy with lateral body-site tracking. |
| **Medications & Substances** | **ATC** (*Anatomical Therapeutic Chemical*) | Active agents, ophthalmologic drops, anti-VEGF injections, dosage-pattern stripping, and WHO ATC mapping. |
| **Lab & Clinical Measurements** | **LOINC** | Quantitative assays (including clinical chemistry, hematology...), clinical scoring scales (including patient reported outcome measures), blood pressure, and most quantitiative ophthalmologic measurements (e.g. OCT segmentation, Hertel, tear film break up time) |
| **Anatomy & Laterality** | **SNOMED CT** | Laterality qualifiers (left/right/bilateral), ocular body structures (`SNOMED:18944008`, `8966001`, `40638003`). |
| **Dual Standards** | **FHIR R6 `Group` & GA4GH Phenopacket v2** | Output trial criteria as definitional/conceptual nested FHIR groups or patient charts as Phenopackets v2.0. |

---

## Architecture Overview

OntoTrial uses an asynchronous, decoupled architecture designed for high throughput, strict schema validation, and real-time frontend updates:

```mermaid
flowchart TD
    UI["<b>Cappuccino / Objective-J Web Frontend</b><br/><i>(CPRuleEditor, Multi-Ontology Tree Browser)</i>"]
    
    CORE["<b>OntoTrial Mojolicious Core</b><br/>• Dynamic Regex Database Intercepts<br/>• Ophthalmology Normalization Engine<br/>• Recursive Subsumption / Hierarchy Kernel<br/>• Minion Background Worker Queue"]

    DB[("<b>PostgreSQL 16+</b><br/>• Terms & Hierarchies (HPO, ICD10, OPS, ATC, LOINC)<br/>• Candidates & Phenopackets<br/>• Trials & Matches")]
    
    LLM["<b>LLM Inference Engine</b><br/>• vLLM / Ollama<br/>• JSON Schema Grammar Constraints<br/>• Clinical Reasoning Trace"]
    
    VEC["<b>Dense Vector Retrieval</b><br/>• Patchbay Stateless API<br/>• Concurrency-Throttled Queue"]

    UI <==>|REST API & WebSockets| CORE
    CORE <==>|Query & PubSub| DB
    CORE -->|Structured Extraction| LLM
    CORE -->|Ontology Vector Search| VEC
```

1. **Frontend (Objective-J / Cappuccino):**
   - Desktop-grade web GUI implementing a Cocoa-derived MVC architecture.
   - Dynamic `CPRuleEditor` for visual nesting of criteria (`all-of`, `any-of`, `neither-of`).
   - Multi-terminology tree navigator (`CPOutlineView`) for HPO, ICD-10, OPS, ATC, and LOINC.
   - Real-time updates via WebSocket subscriptions (`/BBB/socket`).

2. **Backend Engine (Mojolicious / Perl):**
   - High-performance asynchronous REST and WebSocket API.
   - Two-step LLM extraction pipeline: Clinical chunk atomization followed by target-domain dense vector mapping and deterministic database regex intercepts.
   - Asynchronous worker queue powered by **Mojo::Pg / Minion** for background document extraction.

---

## Key Modules & Capabilities

### 1. Dual-Standard Interoperability
- **HL7® FHIR® R6 `Group`:** Generates nested, definitional, and conceptual criteria blocks with `combinationMethod` (`all-of`, `any-of`, `neither-of`), `#subgroup-X` contained groups, UCUM-typed `valueQuantity`, and temporal constraints (`relativeTime`).
- **GA4GH Phenopacket v2.0.0:** Transforms free-text clinical discharge summaries into structured Phenopackets containing `phenotypicFeatures`, `measurements`, `diseases`, `procedures`, `medicalActions`, and patient metadata.

### 2. Ophthalmology & Clinical Measurement Engine
- **Visual Acuity (Visus) & Refraction Normalization:**
  - Extracts and standardizes decimal and Snellen visual acuity (e.g., `1/20`, `0.05`).
  - Converts low-vision qualitative descriptions to the Schulze-Bonsel standard (*Handbewegungen* = `0.005`, *Lichtschein* = `0.002`, *Fingerzählen* = `0.013`, *Amaurose/No LP* = `0.000`).
  - Differentiates uncorrected (`sc`), own-glasses (`eB`), and best-corrected (`cc`) visual acuity.
  - Parses spherical diopters, cylinder diopters, axis, and calculates spherical equivalents.
- **Tonometry & OCT Structural Biomarkers:**
  - Bilateral intraocular pressure (IOP/Tensio), central corneal thickness (Pachymetry/CCT), Hertel exophthalmometry, and corneal endothelial cell density (ECD).
  - Retinal nerve fiber layer (RNFL) thickness, Ganglion Cell Layer / Inner Plexiform Layer volume (GCL/IPL), and Bruch’s Membrane Opening (BMO) area.
- **Section & Anatomical Context Enrichment:**
  - Resolves ambiguous clinical jargon based on note section (e.g., distinguishing *retinal neovascularization* from *corneal neovascularization*, or *chorioretinal scar* from *corneal scar*).

### 3. Dual-Hypothesis Eye Matching Kernel
Clinical trials often define rules for a "study eye" while placing safety restrictions on the "fellow eye". OntoTrial evaluates each patient under dual hypotheses:
- **Hypothesis A:** Right eye (OD) is the Study Eye, Left eye (OS) is the Fellow Eye.
- **Hypothesis B:** Left eye (OS) is the Study Eye, Right eye (OD) is the Fellow Eye (using an on-the-fly mirrored Phenopacket).
- Determines whether a patient qualifies via OD, OS, or both.

### 4. Longitudinal Time-to-Eligibility & Kaplan-Meier Survival Data
- Evaluates sequential medical letters over time for a given patient pseudonym (PIZ).
- Identifies the exact encounter date when study criteria are first met.
- Generates censored survival-time records (`time_days`, `event`, `study_eye`, `baseline_date`, `event_date`) exported via JSON or directly downloadable as a CSV (`/BBB/trials/:id/time_to_eligibility.csv`) for analysis in R, Python, or SPSS.

### 5. Feasibility Cohort Chat Assistant
- An integrated natural language assistant that enables clinical researchers to query patient databases.
- Uses a tool-calling / ReAct loop (`lookup_ontology_code`, `execute_sql`) with automated hierarchical ontology queries (`is_subclass_of()`) to count eligible patients, verify inclusion/exclusion feasibility, and return patient pseudonym cohorts.

---

## Terminology Tree Endpoints

OntoTrial provides recursive tree and search endpoints for all supported terminologies:

| Ontology | Hierarchy Roots | Children Endpoint | Ancestor Path Search |
| :--- | :--- | :--- | :--- |
| **HPO** | `GET /BBB/hpo/roots` | `GET /BBB/hpo/children/:id` | `GET /BBB/hpo/search/:query` |
| **ICD-10** | `GET /BBB/icd10/roots` | `GET /BBB/icd10/children/:id` | `GET /BBB/icd10/search/:query` |
| **OPS** | `GET /BBB/ops/roots` | `GET /BBB/ops/children/:id` | `GET /BBB/ops/search/:query` |
| **ATC** | `GET /BBB/atc/roots` | `GET /BBB/atc/children/:id` | `GET /BBB/atc/search/:query` |
| **LOINC** | `GET /BBB/loinc/roots` | `GET /BBB/loinc/children/:id` | `GET /BBB/loinc/search/:query` |

---

## Prerequisites & Installation

### 1. System Requirements
- **Perl 5.26+**
- **PostgreSQL 14+** (with loaded schemas for HPO, ICD-10, OPS, ATC, and LOINC)
- **Local or Remote LLM Provider:**
  - OpenAI-compatible vLLM server (e.g., `gpt-oss-120b`), OR
  - Ollama instance (e.g., `gemma4:31b-mlx`)

### 2. Perl Dependencies
Install the required CPAN modules:
```bash
cpanm Mojolicious \
      Mojo::Pg \
      Minion \
      DateTime \
      Text::CSV \
      Apache::Session::File

3. Environment Configuration

Configure database and LLM endpoints via environment variables:

# Database
export MOJO_PG_URL="postgresql://postgres:postgres@localhost/hpo"

# LLM Backend (vLLM or Ollama)
export LLM_PROVIDER="vllm"                      # 'vllm' or 'ollama'
export VLLM_ENDPOINT="https://your-vllm-host/v1/chat/completions"
export VLLM_API_KEY="your-api-key"
export VLLM_MODEL="gpt-oss-120b"

# Optional: Ollama settings
# export LLM_PROVIDER="ollama"
# export OLLAMA_ENDPOINT="http://localhost:11434/api/chat"
# export OLLAMA_MODEL="gemma4:31b-mlx"

# Dense Vector Retrieval (Patchbay)
export PATCHBAY_URL="http://localhost:3036"

4. Running the Backend

Development Server:

perl backend.pl daemon -l http://*:4007

Production Daemon (Hypnotoad):

hypnotoad backend.pl

Background Minion Worker: To process asynchronous clinical letter ingestion
(/BBB/import_and_extract_letter):

perl backend.pl minion worker


API Summary (Key Endpoints)

  - POST /BBB/extract_fhir_inex_criteria – Extracts trial criteria and returns a
    FHIR R6 Group JSON.
  - POST /BBB/extract_phenopacket – Extracts an individualized patient
    Phenopacket v2 from clinical notes.
  - POST /BBB/import_and_extract_letter – Queues background medical letter
    ingestion and phenopacket creation via Minion.
  - POST /BBB/run_all_matches – Runs matching evaluation across trials and
    candidates.
  - POST /BBB/trials/:id/time_to_eligibility – Calculates longitudinal
    Kaplan-Meier eligibility intervals.
  - GET /BBB/trials/:id/time_to_eligibility.csv – Exports cohort
    time-to-eligibility tables as CSV.
  - POST /BBB/chat/query – Conversational feasibility assistant with SQL and
    ontology tool-calling.
  - POST /BBB/resolve_term – Standalone high-speed mapping endpoint for
    arbitrary clinical text phrases.
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

### Third-Party Data & Ontology Attributions
OntoTrial interfaces with open medical ontologies and terminologies that retain their respective copyright notices and terms of use:
- **HPO**: Human Phenotype Ontology (CC BY 4.0).
- **ICD-10 / OPS**: © Bundesinstitut für Arzneimittel und Medizinprodukte (BfArM).
- **ATC**: WHO Collaborating Centre for Drug Statistics Methodology.
- **LOINC**: © Regenstrief Institute, Inc.
- **SNOMED CT**: © International Health Terminology Standards Development Organisation (SNOMED International).
