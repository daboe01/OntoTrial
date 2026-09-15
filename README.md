# Clinical Trial Eligibility Framework & HPO Browser

An integrated, full-stack environment designed for structured clinical trial eligibility definition. The platform connects a visual logical rules editor with semantic phenotype extraction powered by Large Language Models (LLMs) and the Human Phenotype Ontology (HPO).

This system bridges the gap between unstructured clinical study protocol narratives and the structured, codifiable FHIR R6 `Group` resource standards.

<img width="1445" height="769" alt="Bildschirmfoto 2026-06-28 um 17 57 05" src="https://github.com/user-attachments/assets/f52f1a51-61a7-4db2-a20e-e386bac4595a" />

---

## Architecture Overview

The application is built upon a decoupled full-stack architecture:

1. **Frontend (Cappuccino / Objective-J):** 
   - Uses a Cocoa-derived MVC pattern running directly in the browser.
   - Features a visual nesting `CPRuleEditor` to display and modify logical operators (`all-of`, `any-of`) and exclusion criteria.
   - Includes a recursive `CPOutlineView` tree component to browse the HPO hierarchy.

2. **Backend (Mojolicious / Perl):**
   - High-throughput asynchronous REST API managing local PostgreSQL-backed HPO database lookups.
   - Handles structured clinical extraction tasks by routing chunks of text to deep learning LLM endpoints using JSON schema constraints.
   - Features defensive logical post-processing to ensure exclusion subgroups are structured cleanly before mapping to the UI.

---

## Key Features

- **FHIR R6 Group Alignment:** Generates definitional and conceptual nested group representations complying with FHIR R6 standards.
- **Hierarchical Phenotypic Extraction:** Uses system-guided LLM pipelines to parse protocol synopses into nested logical blocks.
- **Automatic HPO Semantic Mapping:** Resolves extracted clinical descriptors to standardized HPO identifiers (e.g., `HP:0000118`) via backend mapping services.
- **Robust Logical Validation:** Protects nested exclusion structures from losing their hierarchical boundaries when logical combination methods are changed.
- **Dynamic HPO Tree Browser:** Asynchronously loads down-tree child classes, cross-references (xrefs), and associated standard synonyms.

---

## Repository Structure

- `AppController.j` – The core frontend application delegate, view controllers, and rule editors written in Objective-J.
- `backend.pl` – The Mojolicious backend microservice managing NLP pipelines, HPO search database queries, and concept mapping.

---

## Prerequisites & Installation

### Backend Setup

The backend service requires Perl 5 (version 5.20+ recommended) and a PostgreSQL database containing loaded HPO datasets.

1. **Install Perl Dependencies:**
   ```bash
   cpanm Mojolicious
      ```
2. **Running the Service:**
   You can run the Mojolicious development server directly:
   ```bash
   perl app.pl daemon -l http://*:3026
   ```
