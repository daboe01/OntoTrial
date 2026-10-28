-- OntoTrial Kernschema als Mojo::Pg-Migration
--
-- Wird beim Start von backend.pl automatisch eingespielt (Migration "ontotrial").
-- Bestehende Datenbanken, die das Schema schon haben, werden beim ersten Start
-- nur als Version 1 markiert, ohne dass etwas ausgeführt wird.
--
-- Schemaänderungen: neuen Abschnitt "-- 4 up" (und "-- 4 down") unten anfügen,
-- nie eine bereits ausgerollte Version nachträglich ändern.
--
-- Nicht enthalten: Minion-Tabellen (verwaltet Minion selbst), mojo_migrations,
-- Sicherungstabellen (*_backup_*, *_bak_*, fix_ref_*), Inhalte der Terminologien
-- (lädt update_catalogs.pl) und Konfigurationsdaten (Prompts, Intercepts, Filterregeln).
--
-- Stand: pg_dump --schema-only der Produktionsdatenbank vom 28.10.2026 (PostgreSQL 17.4)

-- 1 up
SET LOCAL check_function_bodies = false;

-- EXTENSION: fuzzystrmatch
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch WITH SCHEMA public;

-- EXTENSION: pg_trgm
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;

-- FUNCTION: all_childen_of(integer)
CREATE FUNCTION public.all_childen_of(integer) RETURNS TABLE(identity integer)
    LANGUAGE sql
    AS $_$
WITH RECURSIVE included_entities(idchild, idparent) AS (
    SELECT idchild, idparent FROM isas WHERE idchild = $1
  UNION ALL
    SELECT p.idchild, p.idparent
    FROM included_entities pr, isas p
    WHERE p.idparent = pr.idchild
  )
SELECT idchild 
FROM included_entities

$_$;

-- FUNCTION: commacat(text, text)
CREATE FUNCTION public.commacat(acc text, instr text) RETURNS text
    LANGUAGE plpgsql
    AS $$

  BEGIN
    IF acc IS NULL OR acc = '' THEN
      RETURN instr;
    ELSE
      RETURN acc || ', ' || instr;
    END IF;
  END;

$$;

-- FUNCTION: is_atc_subclass(text, text)
CREATE FUNCTION public.is_atc_subclass(child_text text, parent_text text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    c text;
    p text;
BEGIN
    IF child_text IS NULL OR parent_text IS NULL THEN
        RETURN false;
    END IF;

    c := upper(trim(regexp_replace(child_text, '^ATC:?', '', 'i')));
    p := upper(trim(regexp_replace(parent_text, '^ATC:?', '', 'i')));
    p := rtrim(p, '%.-* ');

    IF c = '' OR p = '' THEN
        RETURN false;
    END IF;

    RETURN (c = p OR c LIKE p || '%');
END;
$$;

-- FUNCTION: is_hpo_subclass(text, text)
CREATE FUNCTION public.is_hpo_subclass(child_text text, parent_text text) RETURNS boolean
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    c_id integer;
    p_id integer;
BEGIN
    IF child_text IS NULL OR parent_text IS NULL THEN
        RETURN false;
    END IF;

    c_id := NULLIF(regexp_replace(child_text, '\D', '', 'g'), '')::integer;
    p_id := NULLIF(regexp_replace(parent_text, '\D', '', 'g'), '')::integer;

    IF c_id IS NULL OR p_id IS NULL THEN
        RETURN false;
    END IF;

    IF c_id = p_id THEN
        RETURN true;
    END IF;

    RETURN EXISTS (
        SELECT 1 FROM public.hpo_closure
        WHERE idchild = c_id AND idparent = p_id
    );
END;
$$;

-- FUNCTION: is_icd10_subclass(text, text)
CREATE FUNCTION public.is_icd10_subclass(child_text text, parent_text text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    c text;
    p text;
BEGIN
    IF child_text IS NULL OR parent_text IS NULL THEN
        RETURN false;
    END IF;

    c := upper(trim(regexp_replace(child_text, '^ICD10:?', '', 'i')));
    p := upper(trim(regexp_replace(parent_text, '^ICD10:?', '', 'i')));
    p := rtrim(p, '%.-* ');

    IF c = '' OR p = '' THEN
        RETURN false;
    END IF;

    -- z. B. H16.2 / H162 matcht unter H16
    RETURN (replace(c, '.', '') LIKE replace(p, '.', '') || '%');
END;
$$;

-- FUNCTION: is_ops_subclass(text, text)
CREATE FUNCTION public.is_ops_subclass(child_text text, parent_text text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    c text;
    p text;
BEGIN
    IF child_text IS NULL OR parent_text IS NULL THEN
        RETURN false;
    END IF;

    c := upper(trim(regexp_replace(child_text, '^OPS:?', '', 'i')));
    p := upper(trim(regexp_replace(parent_text, '^OPS:?', '', 'i')));
    p := rtrim(p, '%.-* ');

    IF c = '' OR p = '' THEN
        RETURN false;
    END IF;

    -- z. B. 5-125.1 matcht unter 5-125 oder 5-125.1
    RETURN (replace(replace(c, '-', ''), '.', '') LIKE replace(replace(p, '-', ''), '.', '') || '%');
END;
$$;

-- FUNCTION: is_subclass_of(text, text)
CREATE FUNCTION public.is_subclass_of(child_code text, parent_code text) RETURNS boolean
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF child_code IS NULL OR parent_code IS NULL THEN
        RETURN false;
    END IF;

    child_code  := trim(child_code);
    parent_code := trim(parent_code);

    IF child_code = parent_code THEN
        RETURN true;
    END IF;

    IF child_code ~* '^HP:' OR parent_code ~* '^HP:' THEN
        RETURN is_hpo_subclass(child_code, parent_code);
    END IF;

    IF child_code ~* '^ICD10:' OR parent_code ~* '^ICD10:' THEN
        RETURN is_icd10_subclass(child_code, parent_code);
    END IF;

    IF child_code ~* '^OPS:' OR parent_code ~* '^OPS:' THEN
        RETURN is_ops_subclass(child_code, parent_code);
    END IF;

    IF child_code ~* '^ATC:' OR parent_code ~* '^ATC:' THEN
        RETURN is_atc_subclass(child_code, parent_code);
    END IF;

    RETURN child_code ILIKE parent_code;
END;
$$;

-- FUNCTION: to_date_safe(text)
CREATE FUNCTION public.to_date_safe(val text) RETURNS date
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
DECLARE
    clean_val text;
BEGIN
    IF val IS NULL THEN
        RETURN NULL;
    END IF;

    clean_val := trim(val);
    IF clean_val = '' OR clean_val = 'null' OR clean_val = 'none' THEN
        RETURN NULL;
    END IF;

    -- 1. ISO Full Date / Timestamp (e.g. '2024-05-12', '2024-05-12T08:30:00Z')
    IF clean_val ~ '^\d{4}-\d{2}-\d{2}' THEN
        BEGIN
            RETURN substring(clean_val from 1 for 10)::date;
        EXCEPTION WHEN others THEN
            -- fall through
        END;
    END IF;

    -- 2. German Date Format: DD.MM.YYYY
    IF clean_val ~ '^\d{1,2}\.\d{1,2}\.\d{4}' THEN
        BEGIN
            RETURN to_date(clean_val, 'DD.MM.YYYY');
        EXCEPTION WHEN others THEN
            -- fall through
        END;
    END IF;

    -- 3. Year & Month: YYYY-MM
    IF clean_val ~ '^\d{4}-\d{2}$' THEN
        BEGIN
            RETURN to_date(clean_val || '-01', 'YYYY-MM-DD');
        EXCEPTION WHEN others THEN
            -- fall through
        END;
    END IF;

    -- 4. Single Year: YYYY
    IF clean_val ~ '^\d{4}$' THEN
        BEGIN
            RETURN to_date(clean_val || '-01-01', 'YYYY-MM-DD');
        EXCEPTION WHEN others THEN
            -- fall through
        END;
    END IF;

    -- Generic fallback parser
    BEGIN
        RETURN clean_val::date;
    EXCEPTION WHEN others THEN
        RETURN NULL;
    END;
END;
$_$;

-- AGGREGATE: textcat_all(text)
CREATE AGGREGATE public.textcat_all(text) (
    SFUNC = public.commacat,
    STYPE = text,
    INITCOND = ''
);




-- TABLE: atc_terms
CREATE TABLE public.atc_terms (
    id character varying(50) NOT NULL,
    label text NOT NULL,
    parent_id character varying(50),
    code_formatted character varying(50)
);

-- TABLE: candidates
CREATE TABLE public.candidates (
    id integer NOT NULL,
    pseudonym character varying(100) NOT NULL,
    narrative_report text,
    phenopacket_json jsonb,
    reference_date date DEFAULT now(),
    doc_id character varying(64),
    tags text,
    doc_source text DEFAULT 'manual'::text,
    doc_hash text,
    extract_job_id bigint
);

-- SEQUENCE: candidates_id_seq
CREATE SEQUENCE public.candidates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- SEQUENCE OWNED BY: candidates_id_seq
ALTER SEQUENCE public.candidates_id_seq OWNED BY public.candidates.id;

-- TABLE: filter_rules
CREATE TABLE public.filter_rules (
    id integer NOT NULL,
    category character varying(50) NOT NULL,
    pattern text NOT NULL,
    action character varying(20) DEFAULT 'filter'::character varying NOT NULL,
    description text,
    priority integer DEFAULT 100,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);

-- SEQUENCE: filter_rules_id_seq
CREATE SEQUENCE public.filter_rules_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- SEQUENCE OWNED BY: filter_rules_id_seq
ALTER SEQUENCE public.filter_rules_id_seq OWNED BY public.filter_rules.id;

-- TABLE: hpo_closure
CREATE TABLE public.hpo_closure (
    idchild integer,
    idparent integer
);

-- TABLE: icd10_terms
CREATE TABLE public.icd10_terms (
    id text NOT NULL,
    code_formatted text,
    label text,
    parent_id text,
    level integer NOT NULL,
    terminal boolean DEFAULT false NOT NULL
);

-- TABLE: isas
CREATE TABLE public.isas (
    id integer NOT NULL,
    idchild integer,
    idparent integer
);

-- SEQUENCE: isas_id_seq
CREATE SEQUENCE public.isas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- SEQUENCE OWNED BY: isas_id_seq
ALTER SEQUENCE public.isas_id_seq OWNED BY public.isas.id;

-- TABLE: llm_prompts
CREATE TABLE public.llm_prompts (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    system_prompt text NOT NULL,
    user_template text,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);

-- SEQUENCE: llm_prompts_id_seq
CREATE SEQUENCE public.llm_prompts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- SEQUENCE OWNED BY: llm_prompts_id_seq
ALTER SEQUENCE public.llm_prompts_id_seq OWNED BY public.llm_prompts.id;

-- TABLE: loinc_terms
CREATE TABLE public.loinc_terms (
    id character varying(50) NOT NULL,
    label text NOT NULL,
    component character varying(255),
    property character varying(100),
    time_aspect character varying(100),
    system character varying(255),
    scale_type character varying(100),
    method_type character varying(255),
    class_name character varying(100),
    parent_id character varying(100),
    code_formatted character varying(50),
    status character varying(50) DEFAULT 'ACTIVE'::character varying,
    example_ucum_units character varying(100),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);

-- TABLE: mapping_rerank_cache
CREATE TABLE public.mapping_rerank_cache (
    domain character varying(20) NOT NULL,
    query text NOT NULL,
    candidate_ids text NOT NULL,
    chosen_id character varying(64),
    reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    prompt_hash text DEFAULT ''::text NOT NULL,
    relation text
);

-- TABLE: matches
CREATE TABLE public.matches (
    id integer NOT NULL,
    trial_id integer NOT NULL,
    candidate_id integer NOT NULL,
    eligible integer DEFAULT 0 NOT NULL,
    potentially_eligible integer DEFAULT 0 NOT NULL,
    criteria_matches text,
    summary text,
    "timestamp" timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);

-- SEQUENCE: matches_id_seq
CREATE SEQUENCE public.matches_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- SEQUENCE OWNED BY: matches_id_seq
ALTER SEQUENCE public.matches_id_seq OWNED BY public.matches.id;

-- TABLE: ontology_intercepts
CREATE TABLE public.ontology_intercepts (
    id integer NOT NULL,
    domain character varying(20) NOT NULL,
    pattern text NOT NULL,
    code character varying(50) NOT NULL,
    label text NOT NULL,
    priority integer DEFAULT 100,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    suppress boolean DEFAULT false NOT NULL
);

-- SEQUENCE: ontology_intercepts_id_seq
CREATE SEQUENCE public.ontology_intercepts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- SEQUENCE OWNED BY: ontology_intercepts_id_seq
ALTER SEQUENCE public.ontology_intercepts_id_seq OWNED BY public.ontology_intercepts.id;

-- TABLE: ontology_intercepts_patchlog
CREATE TABLE public.ontology_intercepts_patchlog (
    batch character varying(60) NOT NULL,
    intercept_id integer NOT NULL,
    domain character varying(20),
    pattern text,
    code character varying(64),
    beispiel text,
    hinweis text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    aktion character varying(20) DEFAULT 'insert'::character varying NOT NULL
);

-- TABLE: ops_terms
CREATE TABLE public.ops_terms (
    id character varying(50) NOT NULL,
    label text NOT NULL,
    parent_id character varying(50),
    code_formatted character varying(50)
);

-- VIEW: patients
CREATE VIEW public.patients AS
 SELECT pseudonym AS id,
    pseudonym,
    count(*) AS total_documents,
    max(reference_date) AS latest_date,
    jsonb_agg(phenopacket_json) AS all_phenopackets_json
   FROM public.candidates
  WHERE ((pseudonym IS NOT NULL) AND ((pseudonym)::text <> ''::text))
  GROUP BY pseudonym
  ORDER BY pseudonym;

-- TABLE: synonyms
CREATE TABLE public.synonyms (
    id integer NOT NULL,
    idterm integer,
    label text
);

-- SEQUENCE: synonyms_id_seq
CREATE SEQUENCE public.synonyms_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- SEQUENCE OWNED BY: synonyms_id_seq
ALTER SEQUENCE public.synonyms_id_seq OWNED BY public.synonyms.id;

-- TABLE: terms
CREATE TABLE public.terms (
    id integer NOT NULL,
    label text,
    definition text,
    comment text,
    subset text
);

-- TABLE: translation_cache
CREATE TABLE public.translation_cache (
    domain character varying(20) NOT NULL,
    target_language character varying(20) NOT NULL,
    source_text text NOT NULL,
    prompt_hash character varying(64) NOT NULL,
    query text NOT NULL,
    detected_language character varying(10),
    curated boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

-- TABLE: trials
CREATE TABLE public.trials (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    narrative_inex_criteria text,
    fhir_group_json jsonb
);

-- SEQUENCE: trials_id_seq
CREATE SEQUENCE public.trials_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- SEQUENCE OWNED BY: trials_id_seq
ALTER SEQUENCE public.trials_id_seq OWNED BY public.trials.id;

-- TABLE: xrefs
CREATE TABLE public.xrefs (
    id integer NOT NULL,
    idterm integer,
    label text
);

-- SEQUENCE: xrefs_id_seq
CREATE SEQUENCE public.xrefs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- SEQUENCE OWNED BY: xrefs_id_seq
ALTER SEQUENCE public.xrefs_id_seq OWNED BY public.xrefs.id;

-- DEFAULT: candidates id
ALTER TABLE ONLY public.candidates ALTER COLUMN id SET DEFAULT nextval('public.candidates_id_seq'::regclass);

-- DEFAULT: filter_rules id
ALTER TABLE ONLY public.filter_rules ALTER COLUMN id SET DEFAULT nextval('public.filter_rules_id_seq'::regclass);

-- DEFAULT: isas id
ALTER TABLE ONLY public.isas ALTER COLUMN id SET DEFAULT nextval('public.isas_id_seq'::regclass);

-- DEFAULT: llm_prompts id
ALTER TABLE ONLY public.llm_prompts ALTER COLUMN id SET DEFAULT nextval('public.llm_prompts_id_seq'::regclass);

-- DEFAULT: matches id
ALTER TABLE ONLY public.matches ALTER COLUMN id SET DEFAULT nextval('public.matches_id_seq'::regclass);

-- DEFAULT: ontology_intercepts id
ALTER TABLE ONLY public.ontology_intercepts ALTER COLUMN id SET DEFAULT nextval('public.ontology_intercepts_id_seq'::regclass);

-- DEFAULT: synonyms id
ALTER TABLE ONLY public.synonyms ALTER COLUMN id SET DEFAULT nextval('public.synonyms_id_seq'::regclass);

-- DEFAULT: trials id
ALTER TABLE ONLY public.trials ALTER COLUMN id SET DEFAULT nextval('public.trials_id_seq'::regclass);

-- DEFAULT: xrefs id
ALTER TABLE ONLY public.xrefs ALTER COLUMN id SET DEFAULT nextval('public.xrefs_id_seq'::regclass);

-- CONSTRAINT: atc_terms atc_terms_pkey
ALTER TABLE ONLY public.atc_terms
    ADD CONSTRAINT atc_terms_pkey PRIMARY KEY (id);

-- CONSTRAINT: candidates candidates_pkey
ALTER TABLE ONLY public.candidates
    ADD CONSTRAINT candidates_pkey PRIMARY KEY (id);

-- CONSTRAINT: filter_rules filter_rules_pkey
ALTER TABLE ONLY public.filter_rules
    ADD CONSTRAINT filter_rules_pkey PRIMARY KEY (id);

-- CONSTRAINT: icd10_terms icd10_terms_pkey
ALTER TABLE ONLY public.icd10_terms
    ADD CONSTRAINT icd10_terms_pkey PRIMARY KEY (id);

-- CONSTRAINT: isas isas_pkey
ALTER TABLE ONLY public.isas
    ADD CONSTRAINT isas_pkey PRIMARY KEY (id);

-- CONSTRAINT: llm_prompts llm_prompts_name_key
ALTER TABLE ONLY public.llm_prompts
    ADD CONSTRAINT llm_prompts_name_key UNIQUE (name);

-- CONSTRAINT: llm_prompts llm_prompts_pkey
ALTER TABLE ONLY public.llm_prompts
    ADD CONSTRAINT llm_prompts_pkey PRIMARY KEY (id);

-- CONSTRAINT: loinc_terms loinc_terms_pkey
ALTER TABLE ONLY public.loinc_terms
    ADD CONSTRAINT loinc_terms_pkey PRIMARY KEY (id);

-- CONSTRAINT: matches matches_pkey
ALTER TABLE ONLY public.matches
    ADD CONSTRAINT matches_pkey PRIMARY KEY (id);

-- CONSTRAINT: ontology_intercepts ontology_intercepts_pkey
ALTER TABLE ONLY public.ontology_intercepts
    ADD CONSTRAINT ontology_intercepts_pkey PRIMARY KEY (id);

-- CONSTRAINT: ops_terms ops_terms_pkey
ALTER TABLE ONLY public.ops_terms
    ADD CONSTRAINT ops_terms_pkey PRIMARY KEY (id);

-- CONSTRAINT: synonyms synonyms_pkey
ALTER TABLE ONLY public.synonyms
    ADD CONSTRAINT synonyms_pkey PRIMARY KEY (id);

-- CONSTRAINT: terms terms_pkey
ALTER TABLE ONLY public.terms
    ADD CONSTRAINT terms_pkey PRIMARY KEY (id);

-- CONSTRAINT: translation_cache translation_cache_pkey
ALTER TABLE ONLY public.translation_cache
    ADD CONSTRAINT translation_cache_pkey PRIMARY KEY (domain, target_language, source_text, prompt_hash);

-- CONSTRAINT: trials trials_pkey
ALTER TABLE ONLY public.trials
    ADD CONSTRAINT trials_pkey PRIMARY KEY (id);

-- CONSTRAINT: xrefs xrefs_pkey
ALTER TABLE ONLY public.xrefs
    ADD CONSTRAINT xrefs_pkey PRIMARY KEY (id);

-- INDEX: atc_terms_lower_id_idx
CREATE INDEX atc_terms_lower_id_idx ON public.atc_terms USING btree (lower((id)::text));

-- INDEX: candidates_piz_day_idx
CREATE INDEX candidates_piz_day_idx ON public.candidates USING btree (pseudonym, reference_date);

-- INDEX: candidates_piz_hash_idx
CREATE INDEX candidates_piz_hash_idx ON public.candidates USING btree (pseudonym, doc_hash);

-- INDEX: icd_label_trgm
CREATE INDEX icd_label_trgm ON public.icd10_terms USING gin (label public.gin_trgm_ops);

-- INDEX: idx_atc_terms_parent
CREATE INDEX idx_atc_terms_parent ON public.atc_terms USING btree (parent_id);

-- INDEX: idx_candidates_phenopacket
CREATE INDEX idx_candidates_phenopacket ON public.candidates USING gin (phenopacket_json);

-- INDEX: idx_candidates_pseudonym
CREATE INDEX idx_candidates_pseudonym ON public.candidates USING btree (pseudonym);

-- INDEX: idx_candidates_src_doc_id
CREATE UNIQUE INDEX idx_candidates_src_doc_id ON public.candidates USING btree (doc_source, doc_id) WHERE (doc_id IS NOT NULL);

-- INDEX: idx_candidates_tags
CREATE INDEX idx_candidates_tags ON public.candidates USING btree (tags);

-- INDEX: idx_candidates_tags_trgm
CREATE INDEX idx_candidates_tags_trgm ON public.candidates USING gin (tags public.gin_trgm_ops);

-- INDEX: idx_filter_rules_cat_act
CREATE INDEX idx_filter_rules_cat_act ON public.filter_rules USING btree (category, active, priority);

-- INDEX: idx_hpo_closure
CREATE UNIQUE INDEX idx_hpo_closure ON public.hpo_closure USING btree (idchild, idparent);

-- INDEX: idx_icd10_terms_parent_id
CREATE INDEX idx_icd10_terms_parent_id ON public.icd10_terms USING btree (parent_id);

-- INDEX: idx_isas_child
CREATE INDEX idx_isas_child ON public.isas USING btree (idchild);

-- INDEX: idx_isas_parent
CREATE INDEX idx_isas_parent ON public.isas USING btree (idparent);

-- INDEX: idx_llm_prompts_name
CREATE INDEX idx_llm_prompts_name ON public.llm_prompts USING btree (name);

-- INDEX: idx_loinc_class
CREATE INDEX idx_loinc_class ON public.loinc_terms USING btree (class_name);

-- INDEX: idx_loinc_label_trgm
CREATE INDEX idx_loinc_label_trgm ON public.loinc_terms USING gin (label public.gin_trgm_ops);

-- INDEX: idx_loinc_parent
CREATE INDEX idx_loinc_parent ON public.loinc_terms USING btree (parent_id);

-- INDEX: idx_loinc_status
CREATE INDEX idx_loinc_status ON public.loinc_terms USING btree (status);

-- INDEX: idx_matches_candidate_id
CREATE INDEX idx_matches_candidate_id ON public.matches USING btree (candidate_id);

-- INDEX: idx_matches_trial_id
CREATE INDEX idx_matches_trial_id ON public.matches USING btree (trial_id);

-- INDEX: idx_ontology_intercepts_lookup
CREATE INDEX idx_ontology_intercepts_lookup ON public.ontology_intercepts USING btree (domain, active, priority);

-- INDEX: idx_ops_terms_parent
CREATE INDEX idx_ops_terms_parent ON public.ops_terms USING btree (parent_id);

-- INDEX: idx_trial_candidate_uniqueness
CREATE UNIQUE INDEX idx_trial_candidate_uniqueness ON public.matches USING btree (trial_id, candidate_id);

-- INDEX: idx_trials_fhir_group
CREATE INDEX idx_trials_fhir_group ON public.trials USING gin (fhir_group_json);

-- INDEX: loinc_label_trgm
CREATE INDEX loinc_label_trgm ON public.loinc_terms USING gin (label public.gin_trgm_ops);

-- INDEX: mapping_rerank_cache_key_v2
CREATE UNIQUE INDEX mapping_rerank_cache_key_v2 ON public.mapping_rerank_cache USING btree (domain, query, candidate_ids, prompt_hash);

-- INDEX: ops_label_trgm
CREATE INDEX ops_label_trgm ON public.ops_terms USING gin (label public.gin_trgm_ops);

-- INDEX: ops_terms_lower_id_idx
CREATE INDEX ops_terms_lower_id_idx ON public.ops_terms USING btree (lower((id)::text));

-- INDEX: syn_label_trgm
CREATE INDEX syn_label_trgm ON public.synonyms USING gin (label public.gin_trgm_ops);

-- INDEX: terms_label_trgm
CREATE INDEX terms_label_trgm ON public.terms USING gin (label public.gin_trgm_ops);

-- INDEX: translation_cache_curated_idx
CREATE INDEX translation_cache_curated_idx ON public.translation_cache USING btree (domain, target_language, source_text) WHERE curated;

-- FK CONSTRAINT: atc_terms atc_terms_parent_id_fkey
ALTER TABLE ONLY public.atc_terms
    ADD CONSTRAINT atc_terms_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.atc_terms(id) ON DELETE SET NULL;

-- FK CONSTRAINT: icd10_terms icd10_terms_parent_fkey
ALTER TABLE ONLY public.icd10_terms
    ADD CONSTRAINT icd10_terms_parent_fkey FOREIGN KEY (parent_id) REFERENCES public.icd10_terms(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;

-- FK CONSTRAINT: matches matches_candidate_id_fkey
ALTER TABLE ONLY public.matches
    ADD CONSTRAINT matches_candidate_id_fkey FOREIGN KEY (candidate_id) REFERENCES public.candidates(id) ON DELETE CASCADE;

-- FK CONSTRAINT: matches matches_trial_id_fkey
ALTER TABLE ONLY public.matches
    ADD CONSTRAINT matches_trial_id_fkey FOREIGN KEY (trial_id) REFERENCES public.trials(id) ON DELETE CASCADE;

-- FK CONSTRAINT: ops_terms ops_terms_parent_id_fkey
ALTER TABLE ONLY public.ops_terms
    ADD CONSTRAINT ops_terms_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.ops_terms(id) ON DELETE SET NULL;

-- FK CONSTRAINT: synonyms synonyms_idterm_fkey
ALTER TABLE ONLY public.synonyms
    ADD CONSTRAINT synonyms_idterm_fkey FOREIGN KEY (idterm) REFERENCES public.terms(id) ON UPDATE CASCADE ON DELETE CASCADE;

-- FK CONSTRAINT: xrefs xrefs_idterm_fkey
ALTER TABLE ONLY public.xrefs
    ADD CONSTRAINT xrefs_idterm_fkey FOREIGN KEY (idterm) REFERENCES public.terms(id) ON UPDATE CASCADE ON DELETE CASCADE;


-- 1 down
DROP VIEW IF EXISTS public.patients;
DROP TABLE IF EXISTS public.matches, public.trials, public.candidates, public.translation_cache, public.mapping_rerank_cache,
    public.filter_rules, public.ontology_intercepts, public.ontology_intercepts_patchlog, public.llm_prompts,
    public.xrefs, public.synonyms, public.isas, public.hpo_closure, public.terms,
    public.atc_terms, public.icd10_terms, public.ops_terms, public.loinc_terms CASCADE;
DROP AGGREGATE IF EXISTS public.textcat_all(text);
DROP FUNCTION IF EXISTS public.is_subclass_of(text, text), public.is_hpo_subclass(text, text), public.is_icd10_subclass(text, text),
    public.is_ops_subclass(text, text), public.is_atc_subclass(text, text), public.all_childen_of(integer),
    public.commacat(text, text), public.to_date_safe(text);

-- 2 up
-- Validierung: Referenzdatensätze, Bewertungen, Regressionsläufe, KI-Judges.
-- Idempotent, weil Datenbanken diese Tabellen schon aus der früheren
-- Migration "ontotrial_validation" haben können; deren Eintrag wird entfernt.
CREATE TABLE IF NOT EXISTS validation_sets (
    id               serial PRIMARY KEY,
    name             text NOT NULL UNIQUE,
    purpose          text NOT NULL DEFAULT 'regression' CHECK (purpose IN ('regression', 'study')),
    params           jsonb NOT NULL DEFAULT '{}',
    locked           boolean NOT NULL DEFAULT true,
    frozen_at        timestamptz,
    frozen_by        text,
    baseline_run_id  int,
    reference_source text NOT NULL DEFAULT 'human',
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       text,
    notes            text
);
ALTER TABLE validation_sets ADD COLUMN IF NOT EXISTS reference_source text NOT NULL DEFAULT 'human';
CREATE TABLE IF NOT EXISTS validation_items (
    id              serial PRIMARY KEY,
    set_id          int NOT NULL REFERENCES validation_sets(id),
    position        int NOT NULL,
    candidate_id    int,
    pseudonym       text,
    doc_source      text,
    reference_date  text,
    stratum         text,
    narrative       text NOT NULL,
    narrative_md5   text NOT NULL,
    snapshot        jsonb NOT NULL,
    entries         jsonb NOT NULL,
    injected        jsonb,
    double_review   boolean NOT NULL DEFAULT false,
    reference       jsonb,
    UNIQUE (set_id, position)
);
CREATE TABLE IF NOT EXISTS validation_reviews (
    id          serial PRIMARY KEY,
    item_id     int NOT NULL REFERENCES validation_items(id),
    reviewer    text NOT NULL,
    entry_key   text NOT NULL,
    judgment    jsonb NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (item_id, reviewer, entry_key)
);
CREATE TABLE IF NOT EXISTS validation_runs (
    id           serial PRIMARY KEY,
    set_id       int NOT NULL REFERENCES validation_sets(id),
    mode         text NOT NULL CHECK (mode IN ('reextract', 'stored')),
    label        text,
    status       text NOT NULL DEFAULT 'queued',
    progress     int NOT NULL DEFAULT 0,
    fingerprint  jsonb,
    metrics      jsonb,
    comparison   jsonb,
    error        text,
    started_at   timestamptz NOT NULL DEFAULT now(),
    finished_at  timestamptz
);
CREATE TABLE IF NOT EXISTS validation_run_items (
    run_id      int NOT NULL REFERENCES validation_runs(id),
    item_id     int NOT NULL REFERENCES validation_items(id),
    phenopacket jsonb,
    result      jsonb,
    error       text,
    PRIMARY KEY (run_id, item_id)
);
CREATE TABLE IF NOT EXISTS validation_ai_reviews (
    id              serial PRIMARY KEY,
    item_id         int NOT NULL REFERENCES validation_items(id),
    model           text NOT NULL,
    prompt_version  text,
    judgments       jsonb,
    missing         jsonb,
    raw             jsonb,
    usage           jsonb,
    error           text,
    created_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE validation_ai_reviews DROP CONSTRAINT IF EXISTS validation_ai_reviews_item_id_key;
ALTER TABLE validation_ai_reviews DROP CONSTRAINT IF EXISTS validation_ai_reviews_item_model_key;
ALTER TABLE validation_ai_reviews ADD CONSTRAINT validation_ai_reviews_item_model_key UNIQUE (item_id, model);

CREATE OR REPLACE FUNCTION validation_set_guard() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.locked THEN
            RAISE EXCEPTION 'Validierungsdatensatz "%" ist gesperrt und kann nicht gelöscht werden', OLD.name;
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.frozen_at IS NOT NULL AND NEW.frozen_at IS NULL AND OLD.locked THEN
        RAISE EXCEPTION 'Referenz von "%" ist eingefroren; zum Auftauen zuerst entsperren', OLD.name;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION validation_item_guard() RETURNS trigger AS $$
DECLARE s validation_sets%ROWTYPE;
BEGIN
    SELECT * INTO s FROM validation_sets WHERE id = OLD.set_id;
    IF TG_OP = 'DELETE' THEN
        IF s.locked THEN
            RAISE EXCEPTION 'Validierungsdatensatz "%" ist gesperrt', s.name;
        END IF;
        RETURN OLD;
    END IF;
    IF NEW.narrative IS DISTINCT FROM OLD.narrative OR NEW.snapshot IS DISTINCT FROM OLD.snapshot
       OR NEW.entries IS DISTINCT FROM OLD.entries OR NEW.injected IS DISTINCT FROM OLD.injected
       OR NEW.set_id IS DISTINCT FROM OLD.set_id THEN
        RAISE EXCEPTION 'Brieftext und Extraktion eines Validierungsdatensatzes sind unveränderlich';
    END IF;
    IF s.frozen_at IS NOT NULL AND NEW.reference IS DISTINCT FROM OLD.reference THEN
        RAISE EXCEPTION 'Referenz von "%" ist eingefroren', s.name;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION validation_review_guard() RETURNS trigger AS $$
DECLARE s validation_sets%ROWTYPE; iid int;
BEGIN
    IF TG_OP = 'INSERT' THEN iid := NEW.item_id; ELSE iid := OLD.item_id; END IF;
    SELECT vs.* INTO s FROM validation_sets vs JOIN validation_items vi ON vi.set_id = vs.id WHERE vi.id = iid;
    IF s.frozen_at IS NOT NULL THEN
        RAISE EXCEPTION 'Bewertungen von "%" sind eingefroren', s.name;
    END IF;
    IF TG_OP = 'DELETE' THEN
        IF s.locked THEN
            RAISE EXCEPTION 'Bewertungen eines gesperrten Datensatzes können nicht gelöscht werden';
        END IF;
        RETURN OLD;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION validation_ai_guard() RETURNS trigger AS $$
DECLARE s validation_sets%ROWTYPE;
BEGIN
    SELECT vs.* INTO s FROM validation_sets vs JOIN validation_items vi ON vi.set_id = vs.id WHERE vi.id = OLD.item_id;
    IF s.locked THEN
        RAISE EXCEPTION 'KI-Bewertungen eines gesperrten Datensatzes können nicht gelöscht werden';
    END IF;
    RETURN OLD;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS validation_ai_guard ON validation_ai_reviews;
CREATE TRIGGER validation_ai_guard BEFORE DELETE ON validation_ai_reviews
    FOR EACH ROW EXECUTE FUNCTION validation_ai_guard();
DROP TRIGGER IF EXISTS validation_set_guard ON validation_sets;
CREATE TRIGGER validation_set_guard BEFORE UPDATE OR DELETE ON validation_sets
    FOR EACH ROW EXECUTE FUNCTION validation_set_guard();
DROP TRIGGER IF EXISTS validation_item_guard ON validation_items;
CREATE TRIGGER validation_item_guard BEFORE UPDATE OR DELETE ON validation_items
    FOR EACH ROW EXECUTE FUNCTION validation_item_guard();
DROP TRIGGER IF EXISTS validation_review_guard ON validation_reviews;
CREATE TRIGGER validation_review_guard BEFORE INSERT OR UPDATE OR DELETE ON validation_reviews
    FOR EACH ROW EXECUTE FUNCTION validation_review_guard();
DELETE FROM mojo_migrations WHERE name = 'ontotrial_validation';

-- 2 down
DROP TABLE IF EXISTS validation_ai_reviews, validation_run_items, validation_runs, validation_reviews, validation_items, validation_sets;
DROP FUNCTION IF EXISTS validation_set_guard(), validation_item_guard(), validation_review_guard(), validation_ai_guard();

-- 3 up
-- Fehlerhafte KI-Bewertungen (Verbindungsfehler, zurückgehaltene Briefe …) dürfen
-- auch in gesperrten Datensätzen gelöscht werden; gültige Bewertungen bleiben geschützt.
CREATE OR REPLACE FUNCTION validation_ai_guard() RETURNS trigger AS $$
DECLARE s validation_sets%ROWTYPE;
BEGIN
    SELECT vs.* INTO s FROM validation_sets vs JOIN validation_items vi ON vi.set_id = vs.id WHERE vi.id = OLD.item_id;
    IF s.locked AND OLD.error IS NULL THEN
        RAISE EXCEPTION 'KI-Bewertungen eines gesperrten Datensatzes können nicht gelöscht werden';
    END IF;
    RETURN OLD;
END $$ LANGUAGE plpgsql;

-- 3 down
CREATE OR REPLACE FUNCTION validation_ai_guard() RETURNS trigger AS $$
DECLARE s validation_sets%ROWTYPE;
BEGIN
    SELECT vs.* INTO s FROM validation_sets vs JOIN validation_items vi ON vi.set_id = vs.id WHERE vi.id = OLD.item_id;
    IF s.locked THEN
        RAISE EXCEPTION 'KI-Bewertungen eines gesperrten Datensatzes können nicht gelöscht werden';
    END IF;
    RETURN OLD;
END $$ LANGUAGE plpgsql;
