--
-- PostgreSQL database dump
--

-- Dumped from database version 17.4 (Postgres.app)
-- Dumped by pg_dump version 17.4 (Postgres.app)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

-- *not* creating schema, since initdb creates it


--
-- Name: fuzzystrmatch; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS fuzzystrmatch WITH SCHEMA public;


--
-- Name: EXTENSION fuzzystrmatch; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION fuzzystrmatch IS 'determine similarities and distance between strings';


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: minion_state; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.minion_state AS ENUM (
    'inactive',
    'active',
    'failed',
    'finished'
);


--
-- Name: all_childen_of(integer); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: commacat(text, text); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: is_atc_subclass(text, text); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: is_hpo_subclass(text, text); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: is_icd10_subclass(text, text); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: is_ops_subclass(text, text); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: is_subclass_of(text, text); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: minion_jobs_notify_workers(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.minion_jobs_notify_workers() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
  BEGIN
    IF new.delayed <= NOW() THEN
      NOTIFY "minion.job";
    END IF;
    RETURN NULL;
  END;
$$;


--
-- Name: minion_lock(text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.minion_lock(text, integer, integer) RETURNS boolean
    LANGUAGE plpgsql
    AS $_$
DECLARE
  new_expires TIMESTAMP WITH TIME ZONE = NOW() + (INTERVAL '1 second' * $2);
BEGIN
  lock TABLE minion_locks IN exclusive mode;
  DELETE FROM minion_locks WHERE expires < NOW();
  IF (SELECT COUNT(*) >= $3 FROM minion_locks WHERE NAME = $1) THEN
    RETURN false;
  END IF;
  IF new_expires > NOW() THEN
    INSERT INTO minion_locks (name, expires) VALUES ($1, new_expires);
  END IF;
  RETURN TRUE;
END;
$_$;


--
-- Name: stemmed_hpo_code(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.stemmed_hpo_code(input_string text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    modified_string TEXT;
BEGIN
    modified_string := input_string;  -- Start with the original string

    IF modified_string ~ '0011505|0007989|0007989|0040049|0007822|0030496' THEN -- retiales ödem
        modified_string := '0031527';
    END IF;
    IF modified_string ~ '0011532|0030628' THEN -- subretinal fluid
        modified_string := '0031526';
    END IF;

    IF modified_string ~ '0000518|0100018|0100019|0011141|0010924' THEN -- cat
        modified_string := '0011142';
    END IF;

    IF modified_string ~ '0001123' THEN -- scotoma
        modified_string := '0000575';
    END IF;

    IF modified_string ~ '0025562' THEN -- ac cells
        modified_string := '0025561';
    END IF;

    IF modified_string ~ '0025242' THEN -- hemorrhage
        modified_string := '0000573';
    END IF;

    IF modified_string ~ '0031609|0007722' THEN -- macular atrophy
        modified_string := '0007401';
    END IF;

    IF modified_string ~ '0010733|0010732' THEN -- nevus
        modified_string := '0003764';
    END IF;
	
	    IF modified_string ~ '0007401|0030329' THEN -- retinal atrophy
        modified_string := '0001105';
    END IF;

	    IF modified_string ~ '0025609' THEN -- blepharitis
        modified_string := '0000498';
    END IF;
	
	    IF modified_string ~ '0007677' THEN -- retinal degeneration
        modified_string := '0000546';
    END IF;

	    IF modified_string ~ '0007686' THEN -- pupillary function
        modified_string := '0001089';
    END IF;

	    IF modified_string ~ '0000509' THEN -- bindehautrötung
        modified_string := '0030953';
    END IF;
	
	    IF modified_string ~ '0025574|0025241' THEN -- retinal hemorrhage
        modified_string := '0025242';
    END IF;

	    IF modified_string ~ '0033705' THEN -- tear drainage
        modified_string := '0031881';
    END IF;
	
		    IF modified_string ~ '0007765|0011499|0030663|0000616' THEN -- ignore deep anterior chamber mydriasis
        modified_string := '';
	end if;
		    IF modified_string ~ '0003676|0003680|0031915' THEN -- ignore progressive et al
        modified_string := '';
    END IF;
	
		    IF modified_string ~ '0000587' THEN -- optic nerver / optic disc
        modified_string := '0012795';
    END IF;

		    IF modified_string ~ '0000648' THEN -- optic atrophy
        modified_string := '0012512';
    END IF;

		    IF modified_string ~ '0000315' THEN -- exophthalmus
        modified_string := '0000520';
    END IF;

	IF modified_string ~ '0009918' THEN -- korektopie
        modified_string := '0025309';
    END IF;
	IF modified_string ~ '0012805' THEN -- iridektomie
        modified_string := '0000525';
    END IF;
	IF modified_string ~ '0200071' THEN -- periphere degeneration
        modified_string := '0007769';
    END IF;
	
	IF modified_string ~ '0500046' THEN -- but vs. meibomdrüsensstau
        modified_string := '6000069';
    END IF;

	IF modified_string ~ '0031977' THEN -- CDR
        modified_string := '0031976';
    END IF;
	IF modified_string ~ '0030652' THEN -- floaters
        modified_string := '0100832';
    END IF;

	IF modified_string ~ '0001489' THEN -- vitreous detachment
        modified_string := '0004327';
    END IF;

	IF modified_string ~ '0001059' THEN -- pterygium
        modified_string := '0034363';
    END IF;

	IF modified_string ~ '0025582' THEN -- subretinal hemorrhage
        modified_string := '0025243';
    END IF;

	IF modified_string ~ '0040031' THEN -- hyperpigmentation
        modified_string := '0011509';
    END IF;

	IF modified_string ~ '0000315' THEN -- lid erythema
        modified_string := '0040323';
    END IF;
	IF modified_string ~ '0007677' THEN -- yellow lesion
        modified_string := '0030500';
    END IF;

	IF modified_string ~ '0001103' THEN -- mottling
        modified_string := '0007814';
    END IF;

	IF modified_string ~ '0040167' THEN -- papillom
        modified_string := '0000492';
    END IF;
	IF modified_string ~ '0011531' THEN -- vitritis 
        modified_string := '0004327';
    END IF;
	IF modified_string ~ '0100832' THEN -- floaters 
        modified_string := '0004327';
    END IF;
	
	IF modified_string ~ '0200065|0000546' THEN -- pflastersteine / retinal degeneration
        modified_string := '0007769';
    END IF;

    RETURN modified_string;  -- Return the (potentially) modified string
END;
$$;


--
-- Name: to_date_safe(text); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: textcat_all(text); Type: AGGREGATE; Schema: public; Owner: -
--

CREATE AGGREGATE public.textcat_all(text) (
    SFUNC = public.commacat,
    STYPE = text,
    INITCOND = ''
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: atc_terms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.atc_terms (
    id character varying(50) NOT NULL,
    label text NOT NULL,
    parent_id character varying(50),
    code_formatted character varying(50)
);


--
-- Name: candidates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.candidates (
    id integer NOT NULL,
    pseudonym character varying(100) NOT NULL,
    narrative_report text,
    phenopacket_json jsonb,
    reference_date date DEFAULT now(),
    doc_id character varying(64),
    tags text
);


--
-- Name: candidates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.candidates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: candidates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.candidates_id_seq OWNED BY public.candidates.id;


--
-- Name: filter_rules; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: filter_rules_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.filter_rules_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: filter_rules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.filter_rules_id_seq OWNED BY public.filter_rules.id;


--
-- Name: hpo_closure; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hpo_closure (
    idchild integer,
    idparent integer
);


--
-- Name: icd10_terms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.icd10_terms (
    id text NOT NULL,
    code_formatted text,
    label text,
    parent_id text,
    level integer NOT NULL,
    terminal boolean DEFAULT false NOT NULL
);


--
-- Name: isas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.isas (
    id integer NOT NULL,
    idchild integer,
    idparent integer
);


--
-- Name: isas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.isas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: isas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.isas_id_seq OWNED BY public.isas.id;


--
-- Name: llm_prompts; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: llm_prompts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.llm_prompts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: llm_prompts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.llm_prompts_id_seq OWNED BY public.llm_prompts.id;


--
-- Name: loinc_terms; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: mapping_rerank_cache; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: matches; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: matches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.matches_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: matches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.matches_id_seq OWNED BY public.matches.id;


--
-- Name: minion_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.minion_jobs (
    id bigint NOT NULL,
    args jsonb NOT NULL,
    attempts integer DEFAULT 1 NOT NULL,
    created timestamp with time zone DEFAULT now() NOT NULL,
    delayed timestamp with time zone NOT NULL,
    finished timestamp with time zone,
    notes jsonb DEFAULT '{}'::jsonb NOT NULL,
    parents bigint[] DEFAULT '{}'::bigint[] NOT NULL,
    priority integer NOT NULL,
    queue text DEFAULT 'default'::text NOT NULL,
    result jsonb,
    retried timestamp with time zone,
    retries integer DEFAULT 0 NOT NULL,
    started timestamp with time zone,
    state public.minion_state DEFAULT 'inactive'::public.minion_state NOT NULL,
    task text NOT NULL,
    worker bigint,
    expires timestamp with time zone,
    lax boolean DEFAULT false NOT NULL,
    CONSTRAINT minion_jobs_args_check CHECK ((jsonb_typeof(args) = 'array'::text)),
    CONSTRAINT minion_jobs_notes_check CHECK ((jsonb_typeof(notes) = 'object'::text))
);


--
-- Name: minion_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.minion_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: minion_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.minion_jobs_id_seq OWNED BY public.minion_jobs.id;


--
-- Name: minion_locks; Type: TABLE; Schema: public; Owner: -
--

CREATE UNLOGGED TABLE public.minion_locks (
    id bigint NOT NULL,
    name text NOT NULL,
    expires timestamp with time zone NOT NULL
);


--
-- Name: minion_locks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE UNLOGGED SEQUENCE public.minion_locks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: minion_locks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.minion_locks_id_seq OWNED BY public.minion_locks.id;


--
-- Name: minion_workers; Type: TABLE; Schema: public; Owner: -
--

CREATE UNLOGGED TABLE public.minion_workers (
    id bigint NOT NULL,
    host text NOT NULL,
    inbox jsonb DEFAULT '[]'::jsonb NOT NULL,
    notified timestamp with time zone DEFAULT now() NOT NULL,
    pid integer NOT NULL,
    started timestamp with time zone DEFAULT now() NOT NULL,
    status jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT minion_workers_inbox_check CHECK ((jsonb_typeof(inbox) = 'array'::text)),
    CONSTRAINT minion_workers_status_check CHECK ((jsonb_typeof(status) = 'object'::text))
);


--
-- Name: minion_workers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE UNLOGGED SEQUENCE public.minion_workers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: minion_workers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.minion_workers_id_seq OWNED BY public.minion_workers.id;


--
-- Name: mojo_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mojo_migrations (
    name text NOT NULL,
    version bigint NOT NULL,
    CONSTRAINT mojo_migrations_version_check CHECK ((version >= 0))
);


--
-- Name: ontology_intercepts; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: ontology_intercepts_backup_20260923b; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ontology_intercepts_backup_20260923b (
    id integer,
    domain character varying(20),
    pattern text,
    code character varying(50),
    label text,
    priority integer,
    active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    suppress boolean
);


--
-- Name: ontology_intercepts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ontology_intercepts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ontology_intercepts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ontology_intercepts_id_seq OWNED BY public.ontology_intercepts.id;


--
-- Name: ontology_intercepts_patchlog; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: ops_terms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ops_terms (
    id character varying(50) NOT NULL,
    label text NOT NULL,
    parent_id character varying(50),
    code_formatted character varying(50)
);


--
-- Name: patients; Type: VIEW; Schema: public; Owner: -
--

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


--
-- Name: synonyms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.synonyms (
    id integer NOT NULL,
    idterm integer,
    label text
);


--
-- Name: synonyms_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.synonyms_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: synonyms_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.synonyms_id_seq OWNED BY public.synonyms.id;


--
-- Name: terms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.terms (
    id integer NOT NULL,
    label text,
    definition text,
    comment text,
    subset text
);


--
-- Name: translation_cache; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: trials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trials (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    narrative_inex_criteria text,
    fhir_group_json jsonb
);


--
-- Name: trials_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.trials_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: trials_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.trials_id_seq OWNED BY public.trials.id;


--
-- Name: xrefs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.xrefs (
    id integer NOT NULL,
    idterm integer,
    label text
);


--
-- Name: xrefs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.xrefs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: xrefs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.xrefs_id_seq OWNED BY public.xrefs.id;


--
-- Name: candidates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.candidates ALTER COLUMN id SET DEFAULT nextval('public.candidates_id_seq'::regclass);


--
-- Name: filter_rules id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filter_rules ALTER COLUMN id SET DEFAULT nextval('public.filter_rules_id_seq'::regclass);


--
-- Name: isas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.isas ALTER COLUMN id SET DEFAULT nextval('public.isas_id_seq'::regclass);


--
-- Name: llm_prompts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_prompts ALTER COLUMN id SET DEFAULT nextval('public.llm_prompts_id_seq'::regclass);


--
-- Name: matches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.matches ALTER COLUMN id SET DEFAULT nextval('public.matches_id_seq'::regclass);


--
-- Name: minion_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.minion_jobs ALTER COLUMN id SET DEFAULT nextval('public.minion_jobs_id_seq'::regclass);


--
-- Name: minion_locks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.minion_locks ALTER COLUMN id SET DEFAULT nextval('public.minion_locks_id_seq'::regclass);


--
-- Name: minion_workers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.minion_workers ALTER COLUMN id SET DEFAULT nextval('public.minion_workers_id_seq'::regclass);


--
-- Name: ontology_intercepts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ontology_intercepts ALTER COLUMN id SET DEFAULT nextval('public.ontology_intercepts_id_seq'::regclass);


--
-- Name: synonyms id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.synonyms ALTER COLUMN id SET DEFAULT nextval('public.synonyms_id_seq'::regclass);


--
-- Name: trials id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trials ALTER COLUMN id SET DEFAULT nextval('public.trials_id_seq'::regclass);


--
-- Name: xrefs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.xrefs ALTER COLUMN id SET DEFAULT nextval('public.xrefs_id_seq'::regclass);


--
-- Name: atc_terms atc_terms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.atc_terms
    ADD CONSTRAINT atc_terms_pkey PRIMARY KEY (id);


--
-- Name: candidates candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.candidates
    ADD CONSTRAINT candidates_pkey PRIMARY KEY (id);


--
-- Name: filter_rules filter_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filter_rules
    ADD CONSTRAINT filter_rules_pkey PRIMARY KEY (id);


--
-- Name: icd10_terms icd10_terms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.icd10_terms
    ADD CONSTRAINT icd10_terms_pkey PRIMARY KEY (id);


--
-- Name: isas isas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.isas
    ADD CONSTRAINT isas_pkey PRIMARY KEY (id);


--
-- Name: llm_prompts llm_prompts_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_prompts
    ADD CONSTRAINT llm_prompts_name_key UNIQUE (name);


--
-- Name: llm_prompts llm_prompts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_prompts
    ADD CONSTRAINT llm_prompts_pkey PRIMARY KEY (id);


--
-- Name: loinc_terms loinc_terms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loinc_terms
    ADD CONSTRAINT loinc_terms_pkey PRIMARY KEY (id);


--
-- Name: matches matches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.matches
    ADD CONSTRAINT matches_pkey PRIMARY KEY (id);


--
-- Name: minion_jobs minion_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.minion_jobs
    ADD CONSTRAINT minion_jobs_pkey PRIMARY KEY (id);


--
-- Name: minion_locks minion_locks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.minion_locks
    ADD CONSTRAINT minion_locks_pkey PRIMARY KEY (id);


--
-- Name: minion_workers minion_workers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.minion_workers
    ADD CONSTRAINT minion_workers_pkey PRIMARY KEY (id);


--
-- Name: mojo_migrations mojo_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mojo_migrations
    ADD CONSTRAINT mojo_migrations_pkey PRIMARY KEY (name);


--
-- Name: ontology_intercepts ontology_intercepts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ontology_intercepts
    ADD CONSTRAINT ontology_intercepts_pkey PRIMARY KEY (id);


--
-- Name: ops_terms ops_terms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ops_terms
    ADD CONSTRAINT ops_terms_pkey PRIMARY KEY (id);


--
-- Name: synonyms synonyms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.synonyms
    ADD CONSTRAINT synonyms_pkey PRIMARY KEY (id);


--
-- Name: terms terms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms
    ADD CONSTRAINT terms_pkey PRIMARY KEY (id);


--
-- Name: translation_cache translation_cache_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_cache
    ADD CONSTRAINT translation_cache_pkey PRIMARY KEY (domain, target_language, source_text, prompt_hash);


--
-- Name: trials trials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trials
    ADD CONSTRAINT trials_pkey PRIMARY KEY (id);


--
-- Name: xrefs xrefs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.xrefs
    ADD CONSTRAINT xrefs_pkey PRIMARY KEY (id);


--
-- Name: atc_terms_lower_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX atc_terms_lower_id_idx ON public.atc_terms USING btree (lower((id)::text));


--
-- Name: icd_label_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX icd_label_trgm ON public.icd10_terms USING gin (label public.gin_trgm_ops);


--
-- Name: idx_atc_terms_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_atc_terms_parent ON public.atc_terms USING btree (parent_id);


--
-- Name: idx_candidates_doc_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_candidates_doc_id ON public.candidates USING btree (doc_id);


--
-- Name: idx_candidates_phenopacket; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_candidates_phenopacket ON public.candidates USING gin (phenopacket_json);


--
-- Name: idx_candidates_pseudonym; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_candidates_pseudonym ON public.candidates USING btree (pseudonym);


--
-- Name: idx_candidates_tags; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_candidates_tags ON public.candidates USING btree (tags);


--
-- Name: idx_candidates_tags_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_candidates_tags_trgm ON public.candidates USING gin (tags public.gin_trgm_ops);


--
-- Name: idx_filter_rules_cat_act; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_filter_rules_cat_act ON public.filter_rules USING btree (category, active, priority);


--
-- Name: idx_hpo_closure; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_hpo_closure ON public.hpo_closure USING btree (idchild, idparent);


--
-- Name: idx_icd10_terms_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_icd10_terms_parent_id ON public.icd10_terms USING btree (parent_id);


--
-- Name: idx_isas_child; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_isas_child ON public.isas USING btree (idchild);


--
-- Name: idx_isas_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_isas_parent ON public.isas USING btree (idparent);


--
-- Name: idx_llm_prompts_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_llm_prompts_name ON public.llm_prompts USING btree (name);


--
-- Name: idx_loinc_class; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_loinc_class ON public.loinc_terms USING btree (class_name);


--
-- Name: idx_loinc_label_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_loinc_label_trgm ON public.loinc_terms USING gin (label public.gin_trgm_ops);


--
-- Name: idx_loinc_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_loinc_parent ON public.loinc_terms USING btree (parent_id);


--
-- Name: idx_loinc_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_loinc_status ON public.loinc_terms USING btree (status);


--
-- Name: idx_matches_candidate_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_matches_candidate_id ON public.matches USING btree (candidate_id);


--
-- Name: idx_matches_trial_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_matches_trial_id ON public.matches USING btree (trial_id);


--
-- Name: idx_ontology_intercepts_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ontology_intercepts_lookup ON public.ontology_intercepts USING btree (domain, active, priority);


--
-- Name: idx_ops_terms_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ops_terms_parent ON public.ops_terms USING btree (parent_id);


--
-- Name: idx_trial_candidate_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_trial_candidate_uniqueness ON public.matches USING btree (trial_id, candidate_id);


--
-- Name: idx_trials_fhir_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trials_fhir_group ON public.trials USING gin (fhir_group_json);


--
-- Name: loinc_label_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX loinc_label_trgm ON public.loinc_terms USING gin (label public.gin_trgm_ops);


--
-- Name: mapping_rerank_cache_key_v2; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX mapping_rerank_cache_key_v2 ON public.mapping_rerank_cache USING btree (domain, query, candidate_ids, prompt_hash);


--
-- Name: minion_jobs_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX minion_jobs_expires_idx ON public.minion_jobs USING btree (expires);


--
-- Name: minion_jobs_finished_state_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX minion_jobs_finished_state_idx ON public.minion_jobs USING btree (finished, state);


--
-- Name: minion_jobs_notes_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX minion_jobs_notes_idx ON public.minion_jobs USING gin (notes);


--
-- Name: minion_jobs_parents_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX minion_jobs_parents_idx ON public.minion_jobs USING gin (parents);


--
-- Name: minion_jobs_state_priority_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX minion_jobs_state_priority_id_idx ON public.minion_jobs USING btree (state, priority DESC, id);


--
-- Name: minion_locks_name_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX minion_locks_name_expires_idx ON public.minion_locks USING btree (name, expires);


--
-- Name: ops_label_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ops_label_trgm ON public.ops_terms USING gin (label public.gin_trgm_ops);


--
-- Name: ops_terms_lower_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ops_terms_lower_id_idx ON public.ops_terms USING btree (lower((id)::text));


--
-- Name: syn_label_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX syn_label_trgm ON public.synonyms USING gin (label public.gin_trgm_ops);


--
-- Name: terms_label_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX terms_label_trgm ON public.terms USING gin (label public.gin_trgm_ops);


--
-- Name: translation_cache_curated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX translation_cache_curated_idx ON public.translation_cache USING btree (domain, target_language, source_text) WHERE curated;


--
-- Name: minion_jobs minion_jobs_notify_workers_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER minion_jobs_notify_workers_trigger AFTER INSERT OR UPDATE OF retries ON public.minion_jobs FOR EACH ROW EXECUTE FUNCTION public.minion_jobs_notify_workers();


--
-- Name: atc_terms atc_terms_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.atc_terms
    ADD CONSTRAINT atc_terms_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.atc_terms(id) ON DELETE SET NULL;


--
-- Name: icd10_terms icd10_terms_parent_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.icd10_terms
    ADD CONSTRAINT icd10_terms_parent_fkey FOREIGN KEY (parent_id) REFERENCES public.icd10_terms(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: matches matches_candidate_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.matches
    ADD CONSTRAINT matches_candidate_id_fkey FOREIGN KEY (candidate_id) REFERENCES public.candidates(id) ON DELETE CASCADE;


--
-- Name: matches matches_trial_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.matches
    ADD CONSTRAINT matches_trial_id_fkey FOREIGN KEY (trial_id) REFERENCES public.trials(id) ON DELETE CASCADE;


--
-- Name: ops_terms ops_terms_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ops_terms
    ADD CONSTRAINT ops_terms_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.ops_terms(id) ON DELETE SET NULL;


--
-- Name: synonyms synonyms_idterm_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.synonyms
    ADD CONSTRAINT synonyms_idterm_fkey FOREIGN KEY (idterm) REFERENCES public.terms(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: xrefs xrefs_idterm_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.xrefs
    ADD CONSTRAINT xrefs_idterm_fkey FOREIGN KEY (idterm) REFERENCES public.terms(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

