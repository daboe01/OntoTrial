# OntoTrial – Clinical Trial Eligibility & Phenotyping Framework

An integrated, full-stack environment for structured clinical trial eligibility definition, cohort feasibility analysis, longitudinal patient matching and patient-similarity analysis. OntoTrial turns unstructured trial protocols and medical narrative reports (primarily German ophthalmology letters) into standardized, ontology-coded data: **FHIR R6 `Group`** resources for trial criteria and **GA4GH Phenopackets v2** for patients.

Originally centered on the Human Phenotype Ontology (HPO), OntoTrial now offers unified multi-ontology extraction, normalization and hierarchical querying across **HPO**, **ICD-10-GM**, **OPS**, **ATC** and **LOINC**, with SNOMED CT laterality qualifiers.

> **Research prototype.** OntoTrial is not a medical device and must not be used for diagnostic or therapeutic decisions. Process patient data only in pseudonymized form and in accordance with your local data-protection and ethics requirements. Data leaving the institution should only be produced via the [anonymized export](#anonymized-export).

<img width="2033" height="1022" alt="OntoTrial Candidates view" src="https://github.com/user-attachments/assets/421e4515-8eb7-4c70-9790-1d21a1f340d0" />
<img width="1860" height="1028" alt="OntoTrial Phenotype Tree Browser" src="https://github.com/user-attachments/assets/f7c86a01-2ce4-4fbc-83fa-633d0b4c1e6d" />
<img width="853" height="607" alt="Matching trace" src="https://github.com/user-attachments/assets/49591f73-51f6-4c49-b6ab-efd2b1a74083" />
<img width="1239" height="1270" alt="Feasibility chat with generated SQL" src="https://github.com/user-attachments/assets/c8d2e960-a65b-45df-a8ed-7468cbedc81e" />
<img width="658" height="596" alt="Bildschirmfoto 2026-09-26 um 20 00 08" src="https://github.com/user-attachments/assets/0ecfba76-7beb-4ba5-9495-b7dad542d03e" />

---

## Contents

- [Feature overview](#feature-overview)
- [Architecture](#architecture)
- [Extraction and mapping pipeline](#extraction-and-mapping-pipeline)
- [Ophthalmology engine](#ophthalmology-engine)
- [Matching, time-to-eligibility and patient similarity](#matching-time-to-eligibility-and-patient-similarity)
- [Feasibility chat assistant](#feasibility-chat-assistant)
- [Anonymized export](#anonymized-export)
- [Installation](#installation)
- [Configuration](#configuration)
- [Keeping terminologies up to date](#keeping-terminologies-up-to-date)
- [API reference](#api-reference)
- [Database tables](#database-tables)
- [License and attributions](#license-and-attributions)

---

## Feature overview

| Domain | Ontology / Standard | Scope |
| :--- | :--- | :--- |
| **Phenotypes & symptoms** | **HPO** | Recursive `isas` hierarchy, synonym and xref lookup, subsumption testing, ancestor-based similarity. |
| **Diagnoses** | **ICD-10-GM** | German modification incl. Freiburg Alpha-ID suffix normalization, drug-allergy coding (`Z88.8` + ATC), allergen categories (insect venom, pollen, food, contact). |
| **Procedures** | **OPS** | BfArM hierarchy, lateral body-site tracking, direction guard (removal vs. insertion). |
| **Medications** | **ATC** | Active agents and trade names, eye drops, anti-VEGF/steroid IVOM auto-detection, dosage-pattern stripping. |
| **Measurements** | **LOINC** | Clinical chemistry, haematology, coagulation, thyroid, serology, blood pressure, BMI, PROMs (e.g. OSDI) and quantitative ophthalmic measurements. Supports local extension codes (`86290-4a`, `86301-9b`, …). |
| **Anatomy & laterality** | **SNOMED CT / HPO** | Right/left/both eyes (`SNOMED:18944008`, `8966001`, `40638003`; `HP:0012834/5/2`). |
| **Output standards** | **FHIR R6 `Group`**, **Phenopacket v2.0.0** | Nested definitional/conceptual criteria groups; patient phenopackets with features, measurements, diseases, procedures and medical actions. |

Highlights added in recent versions:

- **Multi-stage mapping quality control** – curated regex intercepts, LLM translation with cache, dense vector retrieval, LLM reranking of the top-k candidates in a "gray zone", lexical label gate and anatomy/scope guards (details [below](#extraction-and-mapping-pipeline)).
- **Database-driven configuration** – LLM prompts, intercept rules and filter rules live in PostgreSQL and are reloaded every 30 seconds without a restart.
- **Deep mode** – optional two-stage extraction with an unconstrained reasoning trace (pre-extraction table) followed by schema-constrained JSON sampling.
- **Anonymized export** – de-identified phenopackets for data sharing: no free text, ephemeral subject IDs, month truncation with patient-constant date shift, age top-coding and hierarchical generalization of rare codes (k ≥ 5).
- **Patient similarity** – eye-mirroring distance between phenopackets, nearest-neighbour search and greedy 1:n case-control matching with caliper.
- **Catalog maintenance** – `update_catalogs.pl` for inventory, versioned imports with backups and post-import checks.
- **Real-time progress** – every extraction step reports progress over the WebSocket channel.

---

## Architecture

```mermaid
flowchart TD
    UI["<b>Cappuccino / Objective-J Web Frontend</b><br/><i>CPRuleEditor, Multi-Ontology Tree Browser,<br/>Matching Trace, Time-to-Event, Cohort Chat</i>"]

    CORE["<b>OntoTrial Mojolicious Core</b><br/>• DB-driven prompts, intercepts & filter rules<br/>• Ophthalmology normalization engine<br/>• Mapping QC: rerank, label gate, scope guards<br/>• Subsumption / hierarchy kernel<br/>• Minion background worker queue"]

    DB[("<b>PostgreSQL</b><br/>• Terminologies (HPO, ICD-10-GM, OPS, ATC, LOINC)<br/>• Candidates, phenopackets, trials, matches<br/>• Prompts, intercepts, filter rules<br/>• Translation & rerank caches")]

    LLM["<b>LLM Inference</b><br/>• vLLM (OpenAI-compatible) or Ollama<br/>• JSON-schema constrained output<br/>• Reasoning trace, reranking, SQL agent"]

    VEC["<b>Dense Vector Retrieval</b><br/>• Patchbay stateless API<br/>• Concurrency-throttled queue"]

    UI <==>|REST API & WebSocket /BBB/socket| CORE
    CORE <==>|Queries & LISTEN/NOTIFY| DB
    CORE -->|Extraction, translation, reranking| LLM
    CORE -->|Ontology vector search| VEC
```

1. **Frontend (Objective-J / Cappuccino)** – desktop-grade web GUI with a Cocoa-style MVC architecture: `CPRuleEditor` for nested criteria (`all-of`, `any-of`, `neither-of`), `CPOutlineView` tree browsers for all five terminologies, visual phenopacket profile, matching trace, time-to-event export and the feasibility chat.
2. **Backend (Mojolicious / Perl)** – asynchronous REST and WebSocket API (`backend.pl`), Minion job queue for background letter extraction, PostgreSQL pub/sub for live updates.
3. **LLM provider** – any OpenAI-compatible vLLM server (e.g. `gpt-oss-120b`) or Ollama (e.g. `gemma4:31b-mlx`). Routing is automatic based on the selected model name.
4. **Patchbay** – stateless vector search per terminology; calls are serialized through an in-process queue.

---

## Extraction and mapping pipeline

### Step 1 – Atomization

The input text is cleaned (HTML, KIS macros), common abbreviations are expanded (RZA, AAION, NAION, PDR, NPDR) and the text is split into section-aware chunks. Ophthalmic section headers (`Visus R:`, `VAA L:`, `Fundus BA:` …) are recognized, laterality is injected as a directive, and right/left findings of the same examination are never split across chunks.

Each chunk is sent to the LLM with a strict JSON schema. Every extracted row carries:

`verbatim_text`, `canonical_term` (in document language), `event_date`, `is_exclusion`, `combination_method`, `disjunction_group_id`, `domain`, `laterality`, `anatomical_site`, `is_history`, `has_modifiers`, `demographic_type`, `demographic_value`.

After extraction, rows pass through:

- **Filter rules** from `filter_rules` (`safeguard_pathology`, `safeguard_procedure`, `normal_finding`, `uncodable_rule`). Demographics are never filtered.
- **Canonical-term grounding** – bare morphology nouns ("Narbe", "Ödem", "Infiltrat") are completed with the anatomical site ("Narbe der Hornhaut") or dropped; terms without any codable concept or dosage forms without an agent are removed.
- **Phenopacket-specific corrections** – suspected diagnoses ruled out on the same eye are dropped, domain corrections (e.g. motility restriction → HPO, "IOL in loco" → pseudophakia, conservative drop therapy never becomes an OPS code) and **dual coding** of named inflammations (`…itis`) as both HPO and ICD-10.

With `deep_mode`, a reasoning pass (`atomic_criteria_reasoning` prompt) first produces a clinical analysis and pre-extraction table, which is then fed together with the original text into the constrained extraction.

### Step 2 – Terminology mapping

```mermaid
flowchart LR
    T[Canonical term] --> I{DB intercept?}
    I -- suppress --> X[Row dropped]
    I -- hit --> OK[Code]
    I -- no --> TR[LLM translation<br/>+ translation_cache]
    TR --> V[Patchbay top-k]
    V --> G[Guards:<br/>valid ID, distance,<br/>scope, site, ocular prior,<br/>obsolete, unresolved]
    G --> S{sim ≥ accept<br/>and label covers query?}
    S -- yes --> OK
    S -- no --> R[LLM rerank<br/>exact / broader only<br/>+ mapping_rerank_cache]
    R --> OK
    R --> X
```

| Stage | What it does |
| :--- | :--- |
| **Intercepts** | Curated regex rules in `ontology_intercepts` (per domain, priority-ordered). Rules can map to a code or `suppress` a term entirely. Codes are validated against the terminology tables; rules with unknown or obsolete codes are ignored with a single warning. Labels always come from the ontology, not from the rule. |
| **Translation** | Terms are translated into the index language of the target domain (German for ICD-10/OPS/ATC, English for HPO/LOINC). The model may answer `-` for "no codable concept". Results are cached per prompt version; curated cache entries always win. |
| **Vector retrieval** | Patchbay prompts 51/52 (HPO/modifiers), 64 (ICD-10), 65 (OPS), 66 (ATC), 69 (LOINC). |
| **Guards** | Plausible ID format, domain-specific distance threshold, **scope guard** (ocular term ↔ non-ocular code and vice versa), **site guard** (LLM `anatomical_site` vs. code), **ocular prior** for OPS and ICD-10, obsolete/deprecated codes rejected, ICD-10/OPS codes must resolve in the terminology tables. |
| **ICD-10 specific** | History codes `Z85–Z87` blocked (the disease itself is coded, history is expressed via onset/`is_history`), observation codes only for history rows, trauma (`S`) and amputation (`Z89`) codes only with matching wording, drug allergies coded as `Z88.8` with ATC reference. |
| **Label gate** | A high similarity alone is not accepted: the canonical ontology label (or HPO synonym, ATC trade name) must lexically cover the query; otherwise the candidate goes to reranking. |
| **Reranking** | Top-k candidates plus their common parent node ("broader" candidate) are presented to the LLM with ontology label, parent term and index text. Only `exact` or `broader` relations are accepted. Deterministic ATC guards: `broader` only at class level, `exact` only with lexical match. Decisions are cached; parallel identical requests share one call. |

---

## Ophthalmology engine

- **Visual acuity** – decimal, Snellen and metre-chart fractions (`1/20`, `5/50`, `1/10 MTV`); low vision per Schulze-Bonsel (*Handbewegungen* 0.005, *Lichtschein* 0.002, *Fingerzählen* 0.013, *Nulla lux/Amaurose* 0.000); `idem`/`unverändert` resolved from the admission visus of the same eye; pinhole values isolated.
- **Correction status** – uncorrected (`sc`), own glasses (`eB`, `meB`), best corrected (`cc`, refraction, contact lens), each mapped to the eye-specific LOINC code.
- **Refraction** – sphere, cylinder, axis, spherical equivalent from bracket notation, skiascopy and autorefraction.
- **Bilateral measurements** – IOP (`Tensio 14/16`), Hertel exophthalmometry, BMO area, parsed into separate right/left measurements.
- **Structural and functional parameters** – CCT/pachymetry, endothelial cell density, RNFL, GCL/IPL volume, BMO area, cup-to-disc ratio, palpebral fissure, levator function, tear-film break-up time, visual-field mean defect.
- **Section context enrichment** – ambiguous findings are resolved by section (VAA vs. fundus/OCT): corneal vs. retinal neovascularization, corneal vs. chorioretinal scar, iris vs. choroidal nevus, ocular vs. genital herpes, symblepharon lysis vs. incisional hernia, over-correction after entropion/ectropion/ptosis surgery, and many more.

---

## Matching, time-to-eligibility and patient similarity

### Dual-hypothesis eye matching

Trials often define criteria for the study eye and safety rules for the fellow eye. Each patient is evaluated twice:

- **Hypothesis A:** right eye (OD) = study eye, left eye (OS) = fellow eye.
- **Hypothesis B:** left eye = study eye, using an on-the-fly mirrored phenopacket.

The result states whether the patient qualifies via OD, OS or both. Every criterion is written to a trace with status `inclusion_met`, `inclusion_missing`, `exclusion_clear` or `exclusion_violation`; explicitly negated findings count as evidence of absence. Temporal constraints (`relativeTime`) are evaluated against the procedure or medication date of the same group.

### Longitudinal time-to-eligibility

For each pseudonym (PIZ) all letters are evaluated in chronological order to find the first encounter at which the criteria are met. The output is a censored survival table (`time_days`, `event`, `study_eye`, `baseline_date`, `event_date`, `date_last_seen`, …) as JSON or CSV for R, Python or SPSS.

### Phenopacket distance and case-control matching

A weighted, interpretable distance between two phenopackets in the range 0–1:

| Block | Default weight | Method |
| :--- | :---: | :--- |
| Demographics | 0.15 | Age difference (scale 15 years), sex. |
| Diseases | 0.25 | Best-match average over the ICD-10 hierarchy depth. |
| Phenotypes | 0.20 | Best-match average with HPO ancestor-set (Jaccard) similarity. |
| Procedures | 0.15 | Best-match average over the OPS hierarchy. |
| Medications | 0.10 | Best-match average over the ATC levels. |
| Measurements | 0.15 | Latest value per parameter and eye, scaled difference (visual acuity in logMAR). |

Laterality mismatches are penalized, and the comparison is repeated with the second patient mirrored so that "right eye of A" can match "left eye of B". Missing blocks are ignored and reported as `coverage`. Weights, mirroring and exact matching on sex are configurable per request; `explain: true` returns the matched pairs.

On top of this, OntoTrial offers k-nearest-neighbour search and greedy 1:ratio case-control matching with optional caliper, with or without replacement.

---

## Anonymized export

`POST /BBB/export/anonymized_phenopackets` produces de-identified phenopackets for a cohort (selected by `tag` or `candidate_ids`), one per letter, following the project's data-protection impact assessment (DSFA) and technical anonymization concept. Nothing about the mapping between pseudonyms and export IDs is stored or logged.

| Filter | Implementation |
| :--- | :--- |
| **1 – No free text** | Each phenopacket is rebuilt from a whitelist. Only validated codes with their canonical label from the terminology tables are exported; LLM `canonical_term` labels, verbatim modifiers, free-text units and unresolvable or obsolete codes are dropped. Laterality is limited to a fixed set of HPO/SNOMED codes. |
| **2 – ID decoupling** | Random `subject-…` and `phenopacket-…` IDs from `/dev/urandom`, generated per export run. All letters of one patient share the subject ID within that run only; repeated exports cannot be linked. Output order is shuffled. |
| **3 – Date shift** | Dates are truncated to `YYYY-MM` and shifted by a patient-constant Δm ∈ {−3, −2, −1, +1, +2, +3} months, so intervals are preserved. Year-only dates stay as they are; unparsable dates (e.g. `PAST-UK-UK`) are removed. |
| **4 – Demographics & rare codes** | Age in full years, top-coded at 90 (`P90Y` = 90 or older). Rare codes are generalized along the hierarchy until every exported code is shared by at least k patients (ICD-10 down to 3 characters, OPS to 4, ATC to level 3, HPO via `isas`); rare LOINC assays are dropped. Negated findings are never generalized, only removed. |

Request body: `{ "tag": "...", "candidate_ids": [...], "k": 5 }`. `k` can only be raised above 5. If the selection contains fewer than k patients, the request is rejected with HTTP 422. The response contains the phenopackets plus counts of suppressed, generalized and dropped elements.

Limitations to keep in mind:

- k-anonymity is enforced per individual code, not for the combination of all codes and measurements in a phenopacket. Rich phenotypes can remain unique.
- The internal `candidates` table keeps pseudonyms, narrative reports and the raw phenopackets. For anyone with access to it, exported packets can be matched back via their content. Whether the export is anonymous for a recipient has to be assessed by data protection.
- Exported timestamps (`YYYY-MM`) and the top-level `procedures` array follow the anonymization concept, not the strict Phenopacket v2 schema.
- The endpoint, like the rest of the API, has no built-in authentication. Restrict access at the network or reverse-proxy level.

---

## Feasibility chat assistant

A natural-language assistant for cohort queries such as *"Patients with Sjögren syndrome, superficial punctate keratitis and OSDI > 23"*.

- Tool-calling loop (up to 8 steps) with `lookup_ontology_code` (uses the same mapping pipeline) and `execute_sql`.
- Generated SQL uses `is_subclass_of()` for hierarchical matching and ignores excluded findings.
- Only `SELECT`/`WITH` statements are executed; common path mistakes in the generated JSONB queries are corrected automatically.
- Returns patient count, pseudonym list and the editable SQL; the SQL can be re-run from the UI. Cohorts can be tagged for later matching or re-extraction.
- The system prompt is maintained in `llm_prompts` (`feasibility_chat_assistant`).

---

## Installation

### Requirements

- Perl 5.30 or newer
- PostgreSQL 14 or newer (16 recommended)
- An OpenAI-compatible vLLM server or an Ollama instance
- A Patchbay instance with vector indices for the five terminologies

### Perl dependencies

```bash
cpanm Mojolicious Mojo::Pg Minion DateTime Text::CSV Apache::Session::File
```

### Database

```bash
createdb hpo
psql hpo -f ontotrial_schema.sql
```

Then load the terminologies (see [Keeping terminologies up to date](#keeping-terminologies-up-to-date)) and insert the active prompts into `llm_prompts`:

| Prompt name | Used for |
| :--- | :--- |
| `atomic_criteria_extraction` | Step 1 extraction (placeholders `{{mode_context}}`, `{{filtration_rule}}`, `{{chunk_idx}}`, `{{total_chunks}}`) |
| `atomic_criteria_reasoning` | Deep-mode reasoning trace |
| `criterion_retrieval_translator` | Query translation (`{{domain}}`, `{{target_language}}`, `{{verbatim_text}}`) |
| `mapping_candidate_reranker` | Reranking (`{{domain}}`, `{{term}}`, `{{context}}`, `{{candidates}}`) |
| `feasibility_chat_assistant` | Cohort chat |

### Running

```bash
# Development server
perl backend.pl daemon -l http://*:4007

# Production (Hypnotoad, port 4007, 3 workers)
hypnotoad backend.pl

# Background worker for letter import and re-extraction
perl backend.pl minion worker
```

The frontend is served from `public/Frontend`.

---

## Configuration

### LLM and services

```bash
export LLM_PROVIDER="vllm"                  # 'vllm' or 'ollama'
export VLLM_ENDPOINT="https://your-vllm-host/v1/chat/completions"
export VLLM_API_KEY="your-api-key"
export VLLM_MODEL="gpt-oss-120b"

export OLLAMA_ENDPOINT="http://localhost:11434/api/chat"
export OLLAMA_MODEL="gemma4:31b-mlx"

export PATCHBAY_URL="http://localhost:3036"
```

Requests are routed to Ollama when `LLM_PROVIDER=ollama` or when the selected model name contains `-mlx` or `ollama`.

The PostgreSQL connection is currently set in `backend.pl` (`postgresql://postgres:postgres@localhost/hpo`, used for both `Mojo::Pg` and Minion).

### Mapping quality switches

| Variable | Default | Effect |
| :--- | :---: | :--- |
| `ONTOTRIAL_RERANK` | `1` | LLM reranking of top-k candidates |
| `ONTOTRIAL_RERANK_ACCEPT_SIM` | `0.985` | Similarity above which a label-covered hit is accepted without reranking |
| `ONTOTRIAL_RERANK_TOP_K` | `5` | Number of candidates shown to the reranker |
| `ONTOTRIAL_OCULAR_PRIOR` | `1` | Reject non-ocular codes for ocular terms unless nearly exact |
| `ONTOTRIAL_OCULAR_PRIOR_MIN_SIM` | `0.98` | Similarity that overrides the ocular prior |
| `ONTOTRIAL_ICD_OCULAR_PRIOR` | `1` | Apply the ocular prior to ICD-10 as well |
| `ONTOTRIAL_TRANSLATION_CACHE` | `1` | Cache LLM query translations |
| `ONTOTRIAL_LABEL_GATE_MIN_COVERAGE` | `0.67` | Share of query words that the ontology label must cover |
| `ONTOTRIAL_ICD_REQUIRE_RESOLVED` | `1` | ICD-10 code must exist in `icd10_terms` |
| `ONTOTRIAL_BLOCK_HISTORY_ZCODES` | `1` | Never assign `Z85–Z87` |
| `ONTOTRIAL_INTERCEPT_VALIDATE` | `1` | Ignore intercept rules with unknown or obsolete codes |
| `ONTOTRIAL_PARENT_CANDIDATE` | `1` | Add the common parent node as a "broader" rerank candidate |
| `ONTOTRIAL_GROUND_GENERIC` | `1` | Append the anatomical site to German terms without organ reference |

---

## Keeping terminologies up to date

`update_catalogs.pl` handles inventory, imports and checks. Every import creates a `<table>_bak_<timestamp>` backup and is logged in `catalog_versions`.

```bash
perl update_catalogs.pl inventory                          # table sizes, versions, ID formats
perl update_catalogs.pl hpo hp.obo --dry-run
perl update_catalogs.pl icd10 <claml.xml> --kodes <..._kodes.txt> --dry-run
perl update_catalogs.pl ops   <claml.xml> --kodes <..._kodes.txt> --dry-run
perl update_catalogs.pl atc   <file.csv> --version <year> --dry-run
perl update_catalogs.pl loinc-verify Loinc_<version>.zip   # checksum
perl update_catalogs.pl check backend.pl                   # codes used in the code base
perl update_catalogs.pl help                               # full guide incl. sources
```

Recommended order:

1. Run `inventory`, download the source files (HPO release, BfArM ICD-10-GM/OPS ClaML and metadata, BfArM ATC, LOINC).
2. Run each import with `--dry-run` first, then without.
3. Import LOINC via `/_import_loinc` (keeps local extension codes if configured as described in `update_catalogs.pl help`).
4. Restart Hypnotoad and the Minion worker.
5. Rebuild the Patchbay vector indices (prompts 51/52, 64, 65, 66, 69) **after** the table import.
6. Run `check`, correct affected trial criteria, re-extract candidates (`/BBB/candidates/recompute_by_tag`) and re-run matching.

---

## API reference

### Extraction

| Method | Endpoint | Description |
| :--- | :--- | :--- |
| POST | `/BBB/extract_fhir_inex_criteria` | Trial text → FHIR R6 `Group` (`medical_report`, `model`, `deep_mode`, `task_id`) |
| POST | `/BBB/extract_phenopacket` | Clinical text → Phenopacket v2 (`medical_report`, `candidate_id`, `reference_date`, `model`) |
| POST | `/BBB/extract_phenopacket_from_letter` | As above; accepts JSON or plain-text body, supports `deep_mode` |
| POST | `/BBB/import_and_extract_letter` | Store or update a letter (`pseudonym`, `doc_id`, `medical_report`, `reference_date`) and queue extraction in Minion |
| POST | `/BBB/candidates/recompute_by_tag` | Re-extract all candidates with a tag in the background |
| POST | `/BBB/resolve_term` | Map a single phrase (`domain`, `text`, `language`) to a code |

### Matching and analysis

| Method | Endpoint | Description |
| :--- | :--- | :--- |
| POST | `/BBB/run_all_matches` | Evaluate trials × candidates; optional `trial_id`, `candidate_id`, `tag` |
| GET | `/BBB/matches` | Match results with status |
| POST | `/BBB/trials/:id/time_to_eligibility` | Time-to-eligibility as JSON; optional list of pseudonyms |
| GET | `/BBB/trials/:id/time_to_eligibility.csv` | Same as CSV; optional `?piz=a,b,c` |
| POST | `/BBB/phenopacket_distance` | Distance between two candidates or phenopackets (`a`, `b`, `weights`, `mirror`, `exact`, `explain`) |
| POST | `/BBB/phenopacket_distance/nearest` | k nearest neighbours of a candidate (`candidate_id`, `k`, `caliper`, `tag`) |
| POST | `/BBB/export/anonymized_phenopackets` | De-identified phenopackets for a cohort (`tag` or `candidate_ids`, `k` ≥ 5) |
| POST | `/BBB/propensity_match` | Greedy case-control matching (`treated_ids`/`treated_tag`, `control_ids`/`control_tag`, `ratio`, `caliper`, `replace`) |

### Cohort chat and candidates

| Method | Endpoint | Description |
| :--- | :--- | :--- |
| POST | `/BBB/chat/query` | Stateless feasibility query; returns answer, SQL, pseudonyms |
| POST | `/BBB/chat/execute_sql` | Re-run (edited) cohort SQL |
| POST | `/BBB/candidates/batch_tag` | Add or replace a tag for a list of pseudonyms |
| GET | `/BBB/candidates/search/:query` | Search by pseudonym, tag or ID |

### Terminology browsing

| Ontology | Roots | Children | Search (with ancestor path) |
| :--- | :--- | :--- | :--- |
| HPO | `GET /BBB/hpo/roots` | `GET /BBB/hpo/children/:id` | `GET /BBB/hpo/search/:query` |
| ICD-10 | `GET /BBB/icd10/roots` | `GET /BBB/icd10/children/:id` | `GET /BBB/icd10/search/:query` |
| OPS | `GET /BBB/ops/roots` | `GET /BBB/ops/children/:id` | `GET /BBB/ops/search/:query` |
| ATC | `GET /BBB/atc/roots` | `GET /BBB/atc/children/:id` | `GET /BBB/atc/search/:query` |
| LOINC | `GET /BBB/loinc/roots` | `GET /BBB/loinc/children/:id` | `GET /BBB/loinc/search/:query` |

Additionally: `GET /BBB/hpo/synonyms/:id`, `GET /BBB/hpo/xrefs/:id`.

> **Security:** the API has no authentication and sends `Access-Control-Allow-Origin: *`. Generic table routes (`/BBB/:table`) and `/BBB/chat/execute_sql` can read narrative reports. Run the backend only in a protected network segment behind an authenticating reverse proxy.

### Live updates

`/BBB/socket` (WebSocket) delivers table changes and `TASK_PROGRESS` messages (`phase`, `progress`, `message`) for long-running extractions.

---

## Database tables

| Group | Tables |
| :--- | :--- |
| Terminologies | `terms`, `isas`, `synonyms`, `xrefs` (HPO), `icd10_terms`, `ops_terms`, `atc_terms`, `loinc_terms`, `catalog_versions` |
| Clinical data | `candidates` (letters, phenopackets, tags), `trials` (FHIR groups), `matches` (results and traces) |
| Configuration | `llm_prompts`, `ontology_intercepts`, `filter_rules` |
| Caches | `translation_cache`, `mapping_rerank_cache` |
| Queue | Minion tables |

The full schema is in `ontotrial_schema.sql`.

---

## License and attributions

This project is licensed under the MIT License – see [LICENSE](LICENSE).

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

OntoTrial interfaces with medical terminologies that retain their own copyright and terms of use. They are **not** included in this repository and must be obtained from their publishers:

- **HPO** – Human Phenotype Ontology (CC BY 4.0).
- **ICD-10-GM / OPS / ATC (German version)** – © Bundesinstitut für Arzneimittel und Medizinprodukte (BfArM).
- **ATC** – WHO Collaborating Centre for Drug Statistics Methodology.
- **LOINC** – © Regenstrief Institute, Inc., used under the LOINC license.
- **SNOMED CT** – © SNOMED International.
- **FHIR®** is a registered trademark of HL7. **GA4GH Phenopackets** – Global Alliance for Genomics and Health.
