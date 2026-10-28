#!/usr/bin/env perl

# OntoTrial Backend - Step-by-Step Extraction & Deduplicated Disjunctive Assembly Engine
# Copyright 2026 Daniel Böhringer

# + FHIR Eye Normalization (Study Eye -> Right Eye, Fellow Eye -> Left Eye)
# TODO: support orphacodes

use utf8;
# Optionale .env neben backend.pl laden (Bare-Metal-Betrieb).
# Bereits gesetzte Umgebungsvariablen (z. B. aus docker compose) haben Vorrang.
BEGIN {
    require File::Basename;
    require File::Spec;
    my $f = File::Spec->catfile(File::Basename::dirname(File::Spec->rel2abs(__FILE__)), '.env');
    if (open my $fh, '<:encoding(UTF-8)', $f) {
        while (my $l = <$fh>) {
            next if $l =~ /^\s*(?:#|$)/;
            next unless $l =~ /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/;
            my ($k, $v) = ($1, $2);
            $v =~ s/^(['"])(.*)\1$/$2/;
            $ENV{$k} //= $v;
        }
    }
}

use Mojolicious::Lite;
use Mojo::Pg;
use Data::Dumper;
use Mojo::UserAgent;
use Mojo::URL;
use Encode qw(decode_utf8 is_utf8 encode decode);
use Mojo::JSON qw(decode_json encode_json from_json to_json);
use POSIX qw(strftime);
use DateTime;
use Time::HiRes qw(gettimeofday tv_interval);
use Digest::MD5 qw(md5_hex);
use List::Util ();
use Carp ();

# Diagnosekontext für den Minion-Watchdog (welches Item, welches Muster)
our $DIAG_CTX = '';

no warnings 'uninitialized';
no warnings 'experimental::vlb'; # Unterdrückt die Lookbehind-Warnung global

# =========================================================
# DATABASE TABLE NAME RESOLVER HELPER
# =========================================================
sub resolve_table_name {
    my ($table_raw) = @_;
    return 'public.terms'       if $table_raw =~ /^hpo$/i;
    return 'public.loinc_terms' if $table_raw =~ /^loinc$/i;
    return 'public.atc_terms'   if $table_raw =~ /^atc$/i;
    return 'public.ops_terms'   if $table_raw =~ /^ops$/i;
    return 'public.icd10_terms' if $table_raw =~ /^icd10?$/i;
    return $table_raw;
}

# =========================================================
# DATABASE CONNECTION (Mojo::Pg)
# =========================================================
# PATCH 2026-10-14: Verbindungen über das Environment konfigurierbar
#   ONTOTRIAL_PG         Hauptdatenbank (Ontologien, Kandidaten, Caches)
#                        Default: postgresql://postgres:postgres@localhost/hpo
#   ONTOTRIAL_MINION_PG  vollständige Verbindung für die Minion-Queue (hat Vorrang)
#   ONTOTRIAL_MINION_DB  nur der Datenbankname für Minion; Host, Port, Benutzer,
#                        Passwort und Optionen kommen aus ONTOTRIAL_PG
# Ohne Angaben teilen sich Hauptdatenbank und Minion wie bisher dieselbe Datenbank.
my $pg_dsn = (defined $ENV{ONTOTRIAL_PG} && length $ENV{ONTOTRIAL_PG})
    ? $ENV{ONTOTRIAL_PG}
    : 'postgresql://postgres:postgres@localhost/hpo';

my $minion_dsn = $ENV{ONTOTRIAL_MINION_PG};
unless (defined $minion_dsn && length $minion_dsn) {
    my $name = $ENV{ONTOTRIAL_MINION_DB};
    if (defined $name && length $name) {
        die "Ungültiger Datenbankname in ONTOTRIAL_MINION_DB: '$name'\n"
            unless $name =~ /^[A-Za-z0-9_\-]{1,63}$/;
        $minion_dsn = Mojo::URL->new($pg_dsn)->path("/$name")->to_unsafe_string;
    } else {
        $minion_dsn = $pg_dsn;
    }
}

helper pg => sub {
    state $pg = Mojo::Pg->new($pg_dsn)
};


plugin Minion => {Pg => $minion_dsn};

# Kernschema als Mojo::Pg-Migration (migrations/ontotrial.sql). Eine leere
# Datenbank bekommt das vollständige Schema; eine bestehende Datenbank, die
# das Schema schon hat, wird beim ersten Start nur als Version 1 markiert.
# Spätere Schemaänderungen kommen als "-- 2 up" usw. in die Datei.
{
    my $file = app->home->child('migrations', 'ontotrial.sql');
    if (-e $file) {
        eval {
            my $db  = app->pg->db;
            my $mig = app->pg->migrations->name('ontotrial')->from_file("$file");
            $db->query(q{CREATE TABLE IF NOT EXISTS mojo_migrations (name text PRIMARY KEY, version bigint NOT NULL CHECK (version >= 0))});
            if ($mig->active == 0 && $db->query(q{SELECT to_regclass('public.candidates') IS NOT NULL AS x})->hash->{x}) {
                $db->query(q{INSERT INTO mojo_migrations (name, version) VALUES ('ontotrial', 1) ON CONFLICT (name) DO NOTHING});
                app->log->info('[SCHEMA] Bestehende Datenbank als Kernschema Version 1 übernommen.');
            }
            my $before = $mig->active;
            $mig->migrate;
            app->log->info('[SCHEMA] Kernschema von Version ' . $before . ' auf ' . $mig->active . ' gebracht.') if $mig->active != $before;
            1;
        } or app->log->error("[SCHEMA] Migration des Kernschemas fehlgeschlagen: $@");
    } else {
        app->log->warn("[SCHEMA] $file fehlt; das Kernschema wird nicht automatisch angelegt.");
    }
}
# to_string lässt Benutzer und Passwort weg
app->log->info(sprintf('[CONFIG] Hauptdatenbank: %s | Minion: %s',
    Mojo::URL->new($pg_dsn)->to_string, Mojo::URL->new($minion_dsn)->to_string));
# Jobs erst nach 30 Tagen im Zustand "inactive" als hängend markieren
# (Standard: 2 Tage, reicht bei großem Rückstand nicht)
app->minion->stuck_after(60 * 60 * 24 * 30);

# Turn browser cache off
hook after_dispatch => sub {
    my $tx = shift;
    my $e  = Mojo::Date->new(time - 100);
    $tx->res->headers->header(Expires => $e);
    $tx->res->headers->header('X-ARGOS-Routing' => '3026');
};

# Global CORS Configuration
app->hook(before_dispatch => sub {
    my $c = shift;
    $c->res->headers->header('Access-Control-Allow-Origin'  => '*');
    $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, OPTIONS');
    $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, Authorization');
    if ($c->req->method eq 'OPTIONS') {
        $c->render(text => '', status => 204);
        return;
    }
});

# =========================================================
# GLOBAL CONFIGURATION & LLM SETTINGS
# =========================================================
my $api_key      = $ENV{VLLM_API_KEY}   // '';
my $endpoint     = $ENV{VLLM_ENDPOINT}  // 'https://inference-api.aipier.kn.uniklinik-freiburg.de/v1/chat/completions';
my $model        = $ENV{VLLM_MODEL}     // 'gpt-oss-120b';

# Configuration for Local Testing / LLM Provider Selection
my $llm_provider = $ENV{LLM_PROVIDER}   // 'vllm'; # Options: 'vllm' or 'ollama'
my $ollama_model = $ENV{OLLAMA_MODEL}   // 'gemma4:31b-mlx';

my $patchbay_url = $ENV{PATCHBAY_URL}   // 'http://localhost:3036';
# ---------------------------------------------------------
# MAPPING-QUALITÄT: Reranking, okulärer Prior, Übersetzungscache
# ---------------------------------------------------------
my $rerank_enabled       = $ENV{ONTOTRIAL_RERANK}                // 1;
my $rerank_accept_sim    = $ENV{ONTOTRIAL_RERANK_ACCEPT_SIM}     // 0.985; # ab hier ohne Rückfrage übernehmen
my $rerank_top_k         = $ENV{ONTOTRIAL_RERANK_TOP_K}          // 5;
my $ocular_prior_enabled = $ENV{ONTOTRIAL_OCULAR_PRIOR}          // 1;     # Korpus ist ophthalmologisch
my $ocular_prior_min_sim = $ENV{ONTOTRIAL_OCULAR_PRIOR_MIN_SIM}  // 0.98;
my $translation_cache_on = $ENV{ONTOTRIAL_TRANSLATION_CACHE}     // 1;
# PATCH 2026-09-24: Label-Gate und ICD-Auflösungspflicht
my $label_gate_min_cov   = $ENV{ONTOTRIAL_LABEL_GATE_MIN_COVERAGE} // 0.67;  # Anteil gedeckter Query-Wörter
my $icd_require_resolved = $ENV{ONTOTRIAL_ICD_REQUIRE_RESOLVED}    // 1;     # ICD-Code muss in icd10_terms stehen
# PATCH 2026-09-25: Grauzone, okulärer ICD-Prior, Intercept-Validierung, Elternknoten
my $rerank_gray_floor    = { hpo => 0.08, ops => 0.08, loinc => 0.08, atc => 0.07, icd10 => 0.07 }; # max. Distanz, wenn gerankt wird
my $icd_ocular_prior     = $ENV{ONTOTRIAL_ICD_OCULAR_PRIOR}         // 1;
my $block_history_zcodes = $ENV{ONTOTRIAL_BLOCK_HISTORY_ZCODES}     // 1;     # Z85–Z87 nie vergeben
my $intercept_validate   = $ENV{ONTOTRIAL_INTERCEPT_VALIDATE}       // 1;     # Intercepts mit unbekanntem Code ignorieren
my $parent_candidate_on  = $ENV{ONTOTRIAL_PARENT_CANDIDATE}         // 1;     # Elternknoten als Rerank-Kandidat
my $ground_generic       = $ENV{ONTOTRIAL_GROUND_GENERIC}           // 1;     # Organ an Begriffe ohne okuläres Signal anhängen

our $PIPELINE_CREATOR = 'OntoTrial2-DisjunctiveDeduplicatedStepEngine';
our $PIPELINE_VERSION = '2026-10-14';


# Concurrency throttling configuration for Patchbay
my $max_patchbay_concurrency = 1;
my $active_patchbay_calls    = 0;
my @patchbay_queue;

# PATCH 2026-10-14: Patchbay-Prompt-IDs aus dem Environment, Fallback wie bisher
#   ONTOTRIAL_PROMPT_ID_HPO           (51)
#   ONTOTRIAL_PROMPT_ID_HPO_MODIFIER  (52)
#   ONTOTRIAL_PROMPT_ID_ICD10         (64)
#   ONTOTRIAL_PROMPT_ID_OPS           (65)
#   ONTOTRIAL_PROMPT_ID_ATC           (66)
#   ONTOTRIAL_PROMPT_ID_LOINC         (69)
sub _env_prompt_id {
    my ($var, $default) = @_;
    my $v = $ENV{$var};
    return $default unless defined $v && length $v;
    die "Ungültige Prompt-ID in $var: '$v' (ganze Zahl erwartet)\n" unless $v =~ /^\s*(\d+)\s*$/;
    return $1 + 0;
}

use constant {
    LLM_HPO_RETRIEVAL_PROMPT_ID          => _env_prompt_id('ONTOTRIAL_PROMPT_ID_HPO',          51),
    LLM_HPO_MODIFIER_RETRIEVAL_PROMPT_ID => _env_prompt_id('ONTOTRIAL_PROMPT_ID_HPO_MODIFIER', 52),
    LLM_ICD10_RETRIEVAL_PROMPT_ID        => _env_prompt_id('ONTOTRIAL_PROMPT_ID_ICD10',        64),
    LLM_OPS_RETRIEVAL_PROMPT_ID          => _env_prompt_id('ONTOTRIAL_PROMPT_ID_OPS',          65),
    LLM_ATC_RETRIEVAL_PROMPT_ID          => _env_prompt_id('ONTOTRIAL_PROMPT_ID_ATC',          66),
    LLM_LOINC_RETRIEVAL_PROMPT_ID        => _env_prompt_id('ONTOTRIAL_PROMPT_ID_LOINC',        69),
};

app->log->info(sprintf('[CONFIG] Patchbay %s, Prompt-IDs: HPO %d, HPO-Modifier %d, ICD10 %d, OPS %d, ATC %d, LOINC %d',
    $patchbay_url, LLM_HPO_RETRIEVAL_PROMPT_ID, LLM_HPO_MODIFIER_RETRIEVAL_PROMPT_ID, LLM_ICD10_RETRIEVAL_PROMPT_ID,
    LLM_OPS_RETRIEVAL_PROMPT_ID, LLM_ATC_RETRIEVAL_PROMPT_ID, LLM_LOINC_RETRIEVAL_PROMPT_ID));

# Initialize Mojo::UserAgent
my $ua = Mojo::UserAgent->new(request_timeout => 0, inactivity_timeout => 0, connect_timeout => 0);
$ua->max_connections(0);

my $ua_fast = Mojo::UserAgent->new(
    request_timeout    => 120,
    inactivity_timeout => 120,
    connect_timeout    => 10
);
$ua_fast->max_connections(10);

# =========================================================
# STEP 1: ATOMIC EXTRACTION SCHEMA WITH DOCUMENT LANGUAGE DETECTION
# =========================================================
my $atomic_criteria_schema = {
    type => 'object',
    properties => {
        document_language => {
            type => 'string',
            enum => ['de', 'en', 'other'],
            description => 'ISO language code of the input document: "de" for German, "en" for English.'
        },
        criteria => {
            type => 'array',
            items => {
                type => 'object',
                properties => {
                    verbatim_text => {
                        type => 'string',
                        description => 'The exact verbatim criterion sentence or statement copied directly from text. CRITICAL: For visual acuity (Visus), copy the ENTIRE line including all refraction parentheses, spherical/cylinder/axis parameters, and glasses/eB/cc/sc values intact. Retain scores, thresholds, and scale names together.'
                    },
                    canonical_term => {
                        type => 'string',
                        description => 'Clean, concise 1-5 word medical search term in the SAME LANGUAGE as the document (German for German documents, e.g. "Netzhautablösung", "Arterielle Hypertonie", "Venenastverschluss"; English ONLY for English documents). Never translate German diagnoses to English!'
                    },
                    event_date => {
                        type => 'string',
                        description => 'Exact date, month/year, or temporal string attached to this procedure, diagnosis, or medication in text (e.g. "14.08.2017", "02.02.2017", "06/2013", "ED 2010", "11.11.2019"). Set STRICTLY to empty string "" if no date is mentioned in text.'
                    },
                    is_exclusion => {
                        type => 'boolean',
                        description => 'true if this is an exclusion requirement or absent/denied condition; false if an inclusion requirement or active/present finding.'
                    },
                    combination_method => {
                        type => 'string',
                        enum => ['all-of', 'any-of', 'neither-of'],
                        description => 'Set to "any-of" for disjunctive choices (OR). Set to "neither-of" for exclusions. Default is "all-of".'
                    },
                    disjunction_group_id => {
                        type => 'string',
                        description => 'Group identifier string for OR/disjunctive choices (e.g. "disj_1", "symptom_or_group"). CRITICAL: Items that are alternative OR choices MUST share the SAME matching non-empty string! Set STRICTLY to empty string "" ONLY if standalone mandatory criterion.'
                    },
                    domain => {
                        type => 'string',
                        enum => ['icd10', 'hpo', 'ops', 'atc', 'loinc', 'demographic'],
                        description => 'Primary medical ontology domain: icd10 (formal diagnoses/diseases), hpo (symptoms/signs/phenotypes), ops (surgeries), atc (medications/drops), loinc (measurements/scores/visus/tensio), demographic (age/sex).'
                    },
                    laterality => {
                        type => 'string',
                        enum => ['right', 'left', 'bilateral', 'none'],
                        description => 'Anatomical laterality: "right" for RA/OD/study eye; "left" for LA/OS/fellow eye; "bilateral" for BA/OU/both eyes; "none" if non-lateralized.'
                    },
                    has_modifiers => {
                        type => 'boolean',
                        description => 'true if the criterion includes severity, temporal lookback, or quantitative threshold modifiers.'
                    },
                    demographic_type => {
                        type => 'string',
                        enum => ['age', 'sex', 'temporal', 'quantity', 'none']
                    },
                    anatomical_site => {
                        type => 'string',
                        enum => [qw(eyelid conjunctiva cornea sclera anterior_chamber iris lens vitreous retina macula choroid optic_disc orbit lacrimal visual_field ocular_motility ocular_other systemic none)],
                        description => 'Anatomische Struktur des Befundes. "systemic" für extraokuläre Erkrankungen, Labor und Allgemeinmedikation; "none" nur für Demografie.'
                    },
                    is_history => {
                        type => 'boolean',
                        description => 'true für Vorgeschichte, Z.n., abgeschlossene Ereignisse; false für aktuelle Befunde, laufende Therapie und aktuelle Messwerte.'
                    },
                    demographic_value => {
                        type => 'string',
                        description => 'Raw numerical threshold or constraint value (e.g., ">= 18", "< 3 mm", "FEMALE", "MALE_OR_FEMALE", "<= 180 days")'
                    }
                },
                required => ['verbatim_text', 'canonical_term', 'event_date', 'is_exclusion', 'combination_method', 'disjunction_group_id', 'domain', 'laterality', 'has_modifiers', 'demographic_type', 'demographic_value', 'anatomical_site', 'is_history'],
                additionalProperties => \0
            }
        }
    },
    required => ['document_language', 'criteria'],
    additionalProperties => \0
};

sub to_bool {
    my ($val) = @_;
    return 0 unless defined $val;
    if (ref $val eq 'SCALAR') { return $$val ? 1 : 0; }
    if ($val =~ /^(false|0|no|off)$/i) { return 0; }
    if ($val =~ /^(true|1|yes|on)$/i)  { return 1; }
    return $val ? 1 : 0;
}

# =========================================================
# WEBSOCKET & PUBSUB LOGIC
# =========================================================
websocket '/BBB/socket' => sub {
    my $self = shift;
    $self->inactivity_timeout(3600);

    my $cb = $self->pg->pubsub->listen(fireside_updates => sub {
        my ($pubsub, $payload) = @_;
        $self->send({json => decode_json($payload)});
    });

    $self->on(finish => sub {
        my $c = shift;
        $self->pg->pubsub->unlisten(fireside_updates => $cb);
    });
};

helper notify_change => sub {
    my ($self, $table, $pk, $type, $data) = @_;

    my $payload = {
        table => $table,
        pk    => $pk,
        type  => $type,
        data  => $data
    };

    my $json_str = encode_json($payload);

    if (length($json_str) > 7500) {
        $payload = {
            table     => $table,
            pk        => $pk,
            type      => $type,
            truncated => Mojo::JSON->true,
            data      => { id => $pk }
        };
        $json_str = encode_json($payload);
    }

    $self->pg->pubsub->notify(fireside_updates => $json_str);
};

helper notify_task_progress => sub {
    my ($self, $task_id, $phase, $progress, $message) = @_;
    return unless $task_id;

    my $payload = {
        type      => 'TASK_PROGRESS',
        task_id   => $task_id,
        phase     => $phase,
        progress  => $progress,
        message   => $message
    };

    $self->pg->pubsub->notify(fireside_updates => encode_json($payload));
};

# ---------------------------------------------------------
# Phenopacket am Kandidaten speichern (per candidate_id, nie per
# GUI-Selektion) und alle Clients per Fireside-Live-Sync informieren.
# Kleine Payloads merged Fireside direkt, große (> 7.500 Zeichen,
# "truncated") lädt es per GET /BBB/candidates/id/<id> nach.
# ---------------------------------------------------------
helper store_phenopacket => sub {
    my ($self, $candidate_id, $pp, $narrative) = @_;
    return 0 unless defined $candidate_id && $candidate_id =~ /^\d+$/;

    my %set = (phenopacket_json => (ref $pp ? to_json($pp) : $pp));
    $set{narrative_report} = $narrative if defined $narrative;

    my $rows = $self->pg->db->update('candidates', \%set, { id => $candidate_id })->rows;
    die "Kandidat $candidate_id existiert nicht\n" unless $rows;

    eval { $self->notify_change('candidates', $candidate_id + 0, 'UPDATE', \%set); 1 }
        or $self->app->log->warn("[PHENOPACKET NOTIFY] Kandidat $candidate_id: $@");
    return $rows;
};

# =========================================================
# PATCHBAY CONCURRENCY THROTTLING QUEUE HELPERS
# =========================================================
helper enqueue_patchbay_call => sub {
    my ($self, $code_ref, $term) = @_;
    my $deferred = Mojo::Promise->new;

    push @patchbay_queue, {
        code    => $code_ref,
        promise => $deferred,
        term    => $term // 'unknown'
    };

    $self->process_patchbay_queue();
    return $deferred;
};

helper process_patchbay_queue => sub {
    my ($self) = @_;

    while ($active_patchbay_calls < $max_patchbay_concurrency && @patchbay_queue) {
        my $item = shift @patchbay_queue;
        my $term = $item->{term};
        $active_patchbay_calls++;

        my $promise = eval { $item->{code}->() };
        if ($@ || !$promise || !$promise->can('then')) {
            my $err = $@ // "Executed code did not return a valid promise object.";
            $self->app->log->error("[QUEUE EXCEPTION] Synchronous failure for '$term': $err");

            $item->{promise}->reject($err);
            $active_patchbay_calls--;
            Mojo::IOLoop->next_tick(sub { $self->process_patchbay_queue() });
            next;
        }

        $promise->then(sub {
            my @res = @_;
            $item->{promise}->resolve(@res);
        })->catch(sub {
            my @err = @_;
            $item->{promise}->reject(@err);
        })->finally(sub {
            $active_patchbay_calls--;
            Mojo::IOLoop->next_tick(sub { $self->process_patchbay_queue() });
        });
    }
};

# =========================================================
# ENHANCED JSON PARSER & CLEANER
# =========================================================
sub clean_and_parse_json {
    my ($raw_content) = @_;
    return undef unless defined $raw_content && length $raw_content;

    # Strip conversational text, reasoning tags, and duplicate markdown backticks
    $raw_content =~ s/<think>.*?<\/think>//gs;
    $raw_content =~ s/^\s*json\s*//gi;
    $raw_content =~ s/```(?:json)?//gi;
    $raw_content =~ s/```//g;

    # Strip double array brackets caused by nested markdown artifacts
    $raw_content =~ s/^\s*\[\s*\[/\[/s;
    $raw_content =~ s/\]\s*\]\s*$/\]/s;

    $raw_content =~ s/^\s+|\s+$//g;

    # from_json handles Perl character strings natively
    my $data = eval { from_json($raw_content) };
    if (!defined $data) {
        $data = eval { decode_json(encode('UTF-8', $raw_content)) };
    }
    return $data if defined $data;

    # Fallback array extraction
    if ($raw_content =~ /(\[\s*\{.*\}\s*\])/s) {
        my $inner_arr = $1;
        $data = eval { from_json($inner_arr) } // eval { decode_json(encode('UTF-8', $inner_arr)) };
        return $data if defined $data;
    }

    # Fallback object extraction
    if ($raw_content =~ /(\{\s*".*"\s*:.*\})/s) {
        my $inner_obj = $1;
        $data = eval { from_json($inner_obj) } // eval { decode_json(encode('UTF-8', $inner_obj)) };
        return $data if defined $data;
    }

    return undef;
}

# =========================================================================
# OPHTHALMOLOGY VISUS & REFRACTION EXTRACTION & LOINC MAPPING ENGINE
# =========================================================================

our $VISUS_TOKEN_REGEX = qr/\b(?:0[\.,]\d{1,3}|1[\.,]0{1,2}|1[\.,]\d{1,2})\b|\b1\/\d{1,2}\b|hell[- ]dunkel|\banophthalm\w*|\baugenprothe\w*|\bhdbw\b|\bhbw\b|\bamauros\w*|\bhand(?:bewegung(?:en)?)?\b|\bfz\b|\bfingerz(?:ä|ae)hlen\b|\bn\.?\s*l\.?\b|\bnulla(?:\s*lux)?\b|\blux\b|\blsw\b|\blsp\b|\bls\b|\blichtschein\b/i;

our $QUALIFIER_REGEX   = qr/mit Kontaktlinse|meb|eigene brille,\s*AR|eigene brille,?|bn|eb|ohne Korrek\w+|von|[cs][\.\s]*c[\.\s]*|[cs]\.?c\.?\/[sc][\.:]?c\.?|mit [KVC]L|(?:AR-Werte|AR[\s:=]*|Autoref[\w\.]+\s+[+LBochblend\. c]*)|mit eigener brille|m\.?e\.?B(?:\.)?|mit|[sc]{2,3}\.{0,1}|[cs]\.c\.?|e\.b\.?|[KC]onta[kc]tlinse|mit [KC]onta[kc]tlinse|mit lochblende|[+]{0,1}LB|[+]{0,1}SL|stp(?:\.)?|Gl\.b\.n\.|[VKC]L|Ausgleichsglas|Plusopti\w*\s*|metervisus|tafel\w*|\bMV\b|\bMTV\b|versalbt/i;

sub prune_visus_val {
    my ($visus) = @_;
    return undef unless defined $visus && length($visus);
    $visus =~ s/,/./g;

    # Präverbale / qualitative Befunde dürfen KEINEN Dezimalwert bekommen:
    return undef if $visus =~ /\b(?:folgt|fixiert|kaum|unsicher|zentral|reagiert|abwehr)\b/i;

    # 1. Schulze-Bonsel et al. Low-Vision Standard
    return 0.005 if $visus =~ /\b(?:hdbw|hbw|hand(?:bewegungen?)?)\b/i;
    return 0.002 if $visus =~ /\b(?:lsw|lp|lsp|ls|hell[- ]dunkel|licht(?:schein|scheinprojektion)?)\b/i;
    return 0.013 if $visus =~ /\b(?:fz|finger(?:zählen)?)\b/i;
    return 0.000 if $visus =~ /\b(?:nulla(?:\s*lux)?|nl|keine\s*lp|no\s*lp|nlp|amauro\w+|proth\w+|anop\w+)\b/i;

    # 2. Metervisus / Snellen-Bruchzahlen (z. B. 1/35, 5/50, 20/20, 6/6)
    if ($visus =~ /(\d+(?:\.\d+)?)\s*\/\s*(\d+(?:\.\d+)?)/) {
        my ($num, $den) = ($1, $2);
        if ($den > 0) {
            my $val = sprintf("%.3f", $num / $den) + 0.0;
            return ($val <= 1.6) ? $val : undef; # Werte > 1.6 verwerfen
        }
        return undef;
    }

    # 3. Standard-Dezimalzahl
    $visus =~ s/[^\d\.]//g;
    return undef if $visus eq '';
    my $val = $visus + 0.0;

    # Maximaler physiologischer Visus-Grenzwert (<= 1.6)
    return ($val <= 1.6) ? $val : undef;
}

sub prune_refraction_number {
    my ($number) = @_;
    return undef unless defined $number && length($number);
    return 0.0 if $number =~ /^plan(?:o)?$/i;

    $number =~ s/,/./g;
    $number =~ s/[^\d\.\+\-]//g;
    return undef if $number eq '' || $number eq '+' || $number eq '-';

    return sprintf("%.2f", $number) + 0.0;
}

# -------------------------------------------------------------------------
# PREPROCESSOR: Zeichenbereinigung & Gerätepräfix-Trennung
# -------------------------------------------------------------------------
sub preprocess_ophthalmic_text {
    my ($str) = @_;
    return '' unless defined $str;

    $str =~ s/\\302\\260/°/g;
    $str =~ s/--+/-/g;
    $str =~ s/\(\s+/(/g;
    $str =~ s/\s+\)/)/g;
    $str =~ s/(\d+)\s+°/$1°/g;
    $str =~ s/[;\.\s,]*G(?:l)?\.b\.n\.//ig;
    $str =~ s/exzentrisch|suchend|fraglic\w+//ig;
    $str =~ s/\bL\.?B\.?\b/mit Lochblende/ig;

    # 1. ZUERST Brüche vor sc/cc/eB als Ganzes schützen: "1/20 sc" -> "sc 1/20"
    $str =~ s/\b(\d+\s*\/\s*\d+)\s*(sc|cc|eB)\b/$2 $1/gi;

    # 2. ERST DANACH normale Dezimalzahlen trennen (mit negativem Lookbehind gegen Bruchstriche!):
    # Verhindert, dass aus "1/20 sc" ein "1/sc 20" wird!
    $str =~ s/(?<!\/)\b(\d+(?:[.,]\d+)?)\s*(sc|cc|eB)\b/$2 $1/gi;

    # Trennt Geräte- & Korrekturpräfixe direkt vor Zahlen: "AR0,1" -> "AR 0,1", "cc1,0" -> "cc 1,0"
    $str =~ s/\b(AR|cc|sc|eB|m\.?e\.?B|LA|RA|OS|OD)\s*[:=]?\s*(\d)/$1 $2/gi;

    return $str;
}

# =========================================================================
# OPHTHALMOLOGY VISUS & REFRACTION EXTRACTION MIT STRATEGISCHEN LOGS
# =========================================================================
sub extract_visus_and_refraction {
    my ($raw_text, $context_full_report) = @_;
    return undef unless defined $raw_text && length($raw_text);

    my $input = $raw_text;
    $input = preprocess_ophthalmic_text($input);
    # PATCH 2026-10-02: historische Klammern ZUERST entfernen, bevor die Datums-
    # präfixe wegfallen. Sonst bleiben ungeschlossene Klammern übrig.
    $input =~ s/\b(?:0?[1-9]|1[0-2])[\/\.](?:19|20)?\d{2}\s*[:=]\s*(?:0[\.,]\d+|1[\.,]\d+|[1-6]\/\d+)\b//gi;
    $input =~ s/\bBrillenpass.*$//gi;
    $input =~ s/\(\s*(?:(?:0?[1-9]|1[0-2])[\/\.](?:19|20)\d{2}|(?:19|20)\d{2}|am\b|im\b|in\s+(?:19|20)\d{2}|zuletzt|früher|vorvisus|vor\s+\d+|brillenpass).*?\)//gi;
    # Ungeschlossene historische Klammer bis Zeilenende ("(05/2025: eB: nur FZ ...")
    $input =~ s/\(\s*(?:0?[1-9]|1[0-2])[\/\.](?:19|20)?\d{2}\b[^)]*$//;

    # 1. Führende Datums-/Visit-Präfixe entfernen
    $input =~ s/^\s*(?:(?:0?[1-9]|1[0-2])[\/\.](?:\d{2}|\d{4})|\d{1,2}\.\d{1,2}\.\d{2,4})\s*[:=]\s*//gi;
    $input =~ s/\b(?:0?[1-9]|1[0-2])[\/\.](?:\d{2}|\d{4})\s*[:=]\s*//gi;

    # 2. "idem" / "unverändert" auflösen (mit Stop vor Partnerauge und Folgefeldern)
    if ($input =~ /\b(?:idem|unver[äa]ndert|gleichbleibend)\b/i && $input !~ /(?:$VISUS_TOKEN_REGEX)/i) {
        if (defined $context_full_report && length($context_full_report)) {
            my $is_left  = ($raw_text =~ /\b(?:L\b|LA\b|OS\b|links?|left)\b/i) ? 1 : 0;
            
            # Stoppt garantiert vor dem nächsten Auge (L bzw. R), vor Tensio oder Zeilenumbruch:
            my $target_regex = $is_left
                ? qr/(?:aufnahmevisus|visus)\s*(?:LA|L|OS|links?)\s*[:=]?\s*([^;\n\r]+?)(?=\s*(?:(?:aufnahme)?visus|tensio|vaa|fundus|\n|\r|$))/i
                : qr/(?:aufnahmevisus|visus)\s*(?:RA|R|OD|rechts?)\s*[:=]?\s*([^;\n\r]+?)(?=\s*(?:(?:aufnahme)?visus|tensio|vaa|fundus|\n|\r|$))/i;

            if ($context_full_report =~ $target_regex) {
                my $prev = $1;
                $prev =~ s/^\s*(?:(?:0?[1-9]|1[0-2])[\/\.](?:\d{2}|\d{4})|\d{1,2}\.\d{1,2}\.\d{2,4})\s*[:=]\s*//gi;
                return extract_visus_and_refraction($prev, undef);
            }
        }
        return undef;
    }

    # Metertafelvisus (z. B. "1/10 MTV" -> 0.1) direkt unterstützen
    if ($input =~ /\b(\d+)\s*\/\s*(\d+)\s*(?:mtv|mv|tafel)\b/i) {
        my ($z, $n) = ($1, $2);
        if ($n > 0) {
            my $v = sprintf("%.3f", $z / $n) + 0.0;
            return {
                visus_value       => $v,
                is_best_corrected => 0,
                is_own_glasses    => 0,
                sphere            => undef
            };
        }
    }

    # (Historische Klammern werden jetzt direkt nach preprocess entfernt)

    # Spezialfall: Visus-Bruch + Sphäre direkt notiert (z. B. "1/15 + 8 dpt")
    if ($input =~ /\b([1-6]\/\d{1,2})\s*([+-]\s*\d+(?:[\.,]\d+)?)\s*(?:dpt|diop)?\b/i) {
        my ($snellen_str, $sph_str) = ($1, $2);
        my $v = prune_visus_val($snellen_str);
        my $s = prune_refraction_number($sph_str);

        if (defined $v && defined $s) {
            return {
                visus_value          => $v,
                eb_value             => undef,
                is_best_corrected    => 1,
                is_own_glasses       => 0,
                sphere               => $s,
                cylinder             => 0.0,
                axis                 => undef,
                spherical_equivalent => $s,
            };
        }
    }

    # SCHRITT 1: Refraktionswerte aus Klammern extrahieren
    my ($sph, $cyl, $axis, $sph_eq) = (undef, undef, undef, undef);
    my $refr_regex = qr/\(\s*(?:AR[\s:=]*)?([+-]?\d+(?:[\.,]\d+)?|plan(?:o)?)\s*[\/;]\s*([+-]?\d+(?:[\.,]\d+)?)\s*(?:[\/;]\s*(?:(?:bei|achse|a|x)\s*)?(\d{1,3})(?:°|\s*grad)?)?\s*\)/i;

    if ($input =~ $refr_regex) {
        my ($raw_sph, $raw_cyl, $raw_axis) = ($1, $2, $3);
        $sph  = prune_refraction_number($raw_sph);
        $cyl  = prune_refraction_number($raw_cyl);
        $axis = (defined $raw_axis && length($raw_axis)) ? ($raw_axis + 0) : undef;
    }

    if (defined $sph) {
        my $c = $cyl // 0.0;
        $sph_eq = sprintf("%.3f", $sph + (0.5 * $c)) + 0.0;
    }

    # Spezialfall: C-Skiaskopie / Skiaskopie / Refraktion ohne Klammern
    if (!defined $sph && $input =~ /\b(?:c[- ]?skiaskop\w*|skiaskop\w*|skia|refraktion|brille|sph[äa]re|sph)\b.*?([+-]?\s*\d+(?:[\.,]\d+)?)\s*(?:dpt|diop|sph)?(?:\s*[\/;]?\s*([+-]?\s*\d+(?:[\.,]\d+)?)\s*(?:cyl)?)?(?:\s*(?:achse|bei|x|a)?\s*(\d{1,3})°?)?/i) {
        my $raw_val = $1;
        if (defined $raw_val && length($raw_val)) {
            $sph  = prune_refraction_number($raw_val);
            $cyl  = defined $2 ? prune_refraction_number($2) : 0.0;
            $axis = (defined $3 && length($3)) ? ($3 + 0) : undef;
            if (defined $sph) {
                my $c = $cyl // 0.0;
                $sph_eq = sprintf("%.3f", $sph + (0.5 * $c)) + 0.0;
            }
        }
    }

    # SCHRITT 2: Visuswerte scannen
    my $clean_for_visus = $input;
    # PATCH 2026-10-02: innerste Klammern wiederholt entfernen (linear, keine
    # Rekursion), danach Reste ungeschlossener Klammern bis Zeilenende.
    1 while $clean_for_visus =~ s/\([^()]*\)//g;
    1 while $clean_for_visus =~ s/\([^()]*$//;
    $clean_for_visus =~ tr/()//d;

    # Lochblendenvisus (LB) vorab isolieren, damit er den Hauptvisus nicht als Maximum verfälscht:
    # PATCH 2026-10-14: Wert auch nach "LB" ("0,9 mit LB") und Werte > 1,0 ("LB 1,25")
    my $lb_visus = undef;
    my $lb_val_re = qr/0[\.,]\d+|1[\.,]\d{1,2}|[1-6]\/\d{1,2}/;
    if ($clean_for_visus =~ /\b(?:mit\s+)?(?:LB|Lochblende)\s*[:=]?\s*($lb_val_re)/i) {
        $lb_visus = prune_visus_val($1);
        $clean_for_visus =~ s/\b(?:mit\s+)?(?:LB|Lochblende)\s*[:=]?\s*(?:$lb_val_re)//gi;
    } elsif ($clean_for_visus =~ /(?<![\d.,\/])($lb_val_re)\s*(?:mit\s+)*(?:LB|Lochblende)\b/i) {
        $lb_visus = prune_visus_val($1);
        $clean_for_visus =~ s/(?<![\d.,\/])(?:$lb_val_re)\s*(?:mit\s+)*(?:LB|Lochblende)\b//gi;
    }

    my @candidate_values;

    while ($clean_for_visus =~ /\b([1-6])\s*\/\s*(\d{1,3})\b/g) {
        my ($num, $den) = ($1, $2);
        if ($den > 0) {
            my $val = sprintf("%.3f", $num / $den) + 0.0;
            push @candidate_values, $val if $val <= 1.6;
        }
    }

    while ($clean_for_visus =~ /($VISUS_TOKEN_REGEX)/gi) {
        my $token = $1;
        next if $token =~ /\b(?:n\.?m\.?|nicht\s*messbar)\b/i;
        my $v = prune_visus_val($token);
        push @candidate_values, $v if defined $v;
    }

    if (!@candidate_values) {
        if    ($clean_for_visus =~ /\b(?:fz|fingerzählen|finger\s*zählen)\b/i)            { push @candidate_values, 0.013; }
        elsif ($clean_for_visus =~ /\b(?:hbw|hdbw|handbewegung(?:en)?)\b/i)               { push @candidate_values, 0.005; }
        elsif ($clean_for_visus =~ /\b(?:lsp|lsw|ls|hell[- ]dunkel|licht(?:schein)?)\b/i) { push @candidate_values, 0.002; }
        elsif ($clean_for_visus =~ /\b(?:nulla\s*lux|nlp|n\.?\s*l\.?|keine\s*lp)\b/i)     { push @candidate_values, 0.000; }
    }

    my $max_visus = undef;
    if (@candidate_values) {
        my @sorted = sort { $b <=> $a } @candidate_values;
        $max_visus = $sorted[0];
    }

    # PATCH 2026-10-14: reiner Lochblendenvisus ist ebenfalls ein Ergebnis
    return undef unless defined $max_visus || defined $sph || defined $lb_visus;

    # Korrekturstatus sauber differenzieren
    my $is_own_glasses  = ($clean_for_visus =~ /\b(?:eB|m\.?e\.?B|eigene\s+brille)\b/i) ? 1 : 0;
    my $is_contact_lens = ($raw_text =~ /\b(?:KL|formstabile\s+KL|kontaktlinse|mit\s+kontaktlinse|mit\s+[kvc]l)\b/i) ? 1 : 0;
    my $is_corrected    = 0;

    # Kontaktlinse oder Refraktion gilt immer als korrigierter Visus (cc)
    if (defined $sph || $clean_for_visus =~ /\b(?:cc|mit\s+korrektur|mit\s+kontaktlinse|mit\s+[kvc]l)\b/i || $is_contact_lens) {
        $is_corrected = 1; # Bestkorrigiert mit Refraktion / Gläsern / Kontaktlinse
    } elsif ($clean_for_visus =~ /\bsc\b|\bohne\s+korrektur\b/i && !$is_own_glasses && !$is_contact_lens) {
        $is_corrected = 0; # Unkorrigiert
    }

    my $eb_visus = undef;
    if ($raw_text =~ /\b(?:eB|m\.?e\.?B|eigene\s+brille)\s*[:=]?\s*(0[\.,]\d+|1[\.,]0)/i) {
        $eb_visus = prune_visus_val($1);
    } elsif ($is_own_glasses && defined $max_visus) {
        $eb_visus = $max_visus;
    }
    
    return {
        visus_value          => $max_visus,
        eb_value             => $eb_visus,
        lb_value             => $lb_visus,
        is_best_corrected    => $is_corrected,
        is_own_glasses       => $is_own_glasses,
        sphere               => $sph,
        cylinder             => $cyl,
        axis                 => $axis,
        spherical_equivalent => $sph_eq,
        is_contact_lens => $is_contact_lens
    };
}


# =========================================================================
# OPHTHALMOLOGY LOINC MEASUREMENT BUILDER
# PATCH 2026-10-12: Codes kommen aus ontology_intercepts (domain 'loinc',
# pattern exakt '^<schlüssel>$', z. B. '^refraction axis right eye$').
# Die bisher fest eingetragenen Refraktionscodes waren falsch
# (65898-9 = Eye fields photographed, 65891-4 = Cylinder axis Right eye
# als "Sphäre links", 65895-5 = Cylinder axis Left eye als "Zylinder links").
# Fallbacks unten sind gegen loinc_terms geprüft. Sphäre und Zylinder
# haben bewusst KEINEN Fallback: ohne Intercept entfällt die Messung.
# =========================================================================
our %OPHTH_LOINC_FALLBACK = (
    'refraction axis right eye'                 => ['LOINC:79844-7', 'Right eye Axis--WO cycloplegia by Subjective refraction'],
    'refraction axis left eye'                  => ['LOINC:79845-4', 'Left eye Axis--WO cycloplegia by Subjective refraction'],
    'refraction spherical equivalent right eye' => ['LOINC:95327-3', 'Right corrective lens Spherical equivalent Calculated'],
    'refraction spherical equivalent left eye'  => ['LOINC:95328-1', 'Left corrective lens Spherical equivalent Calculated'],
);
our %OPHTH_LOINC_WARNED;

# PATCH 2026-10-14: erwartete Einheit und Wertebereich je Assay.
# Ein Messwert außerhalb dieser Grenzen ist fast immer ein Parserfehler
# (z. B. Monat aus "10/23: 699 Zellen/mm²" als Wert "10 score").
# require: Assay ohne quantitativen Wert ebenfalls verwerfen.
our %LOINC_PLAUSIBLE = (
    'LOINC:100076-9' => { unit => '{cells}/mm2', min => 200, max => 4500, require => 1 },  # Endothel rechts
    'LOINC:100077-7' => { unit => '{cells}/mm2', min => 200, max => 4500, require => 1 },  # Endothel links
    'LOINC:79887-6'  => { unit => 'um',          min => 250, max => 900,  require => 1 },  # Pachymetrie links
    'LOINC:79888-4'  => { unit => 'um',          min => 250, max => 900,  require => 1 },  # Pachymetrie rechts
    # PATCH 2026-10-22: lokale Analogcodes Katarakt-OP
    'LOINC:95327-A'  => { unit => 'diopter',     min => -15, max => 10,   require => 1 },  # Zielrefraktion rechts
    'LOINC:95328-A'  => { unit => 'diopter',     min => -15, max => 10,   require => 1 },  # Zielrefraktion links
    'LOINC:64817-A'  => { unit => '%.s',         min => 0,   max => 300,  require => 1 },  # Phako-Zeitleistungswert rechts
    'LOINC:64818-A'  => { unit => '%.s',         min => 0,   max => 300,  require => 1 },  # Phako-Zeitleistungswert links
    'LOINC:64819-A'  => { unit => 'diopter',     min => -10, max => 40,   require => 1 },  # IOL-Stärke rechts
    'LOINC:64820-A'  => { unit => 'diopter',     min => -10, max => 40,   require => 1 },  # IOL-Stärke links
);

sub loinc_value_plausible {
    my ($id, $q) = @_;
    my $r = $LOINC_PLAUSIBLE{$id // ''} or return 1;
    return ($r->{require} ? 0 : 1) unless ref $q eq 'HASH' && defined $q->{value};
    return 0 if $r->{unit} && ($q->{unit} // '') ne $r->{unit};
    return 0 if $q->{value} < $r->{min} || $q->{value} > $r->{max};
    return 1;
}

sub build_ophthalmic_loinc_measurements {
    my ($parsed_ref, $laterality, $ref_date, $resolve) = @_;
    return () unless ref $parsed_ref eq 'HASH';

    my $lat = lc($laterality // 'none');
    my $is_left  = ($lat eq 'left'  || $lat eq 'os' || $lat eq 'la');
    my $is_right = ($lat eq 'right' || $lat eq 'od' || $lat eq 'ra');

    my $lat_obj = $is_left  ? { id => "HP:0012835", label => "Left" }
                : $is_right ? { id => "HP:0012834", label => "Right" }
                : undef;

    # Refraktion ohne Seitenangabe wurde schon bisher dem rechten Auge zugeordnet
    my $rside  = $is_left ? 'left eye' : 'right eye';
    my $vside  = $is_left ? ' left eye' : $is_right ? ' right eye' : '';
    my $vlabel = $is_left ? ' Left eye' : $is_right ? ' Right eye' : '';

    my $resolve_code = sub {
        my ($key, $fb_id, $fb_label) = @_;
        my $hit = $resolve ? eval { $resolve->($key) } : undef;
        return ($hit->{id}, $hit->{label} // $fb_label) if ref $hit eq 'HASH' && $hit->{id};
        if (!$fb_id && (my $fb = $OPHTH_LOINC_FALLBACK{$key})) { ($fb_id, $fb_label) = @$fb; }
        return ($fb_id, $fb_label) if $fb_id;
        warn "[OPHTH LOINC] Kein Intercept für '$key' – Messung entfällt.\n" unless $OPHTH_LOINC_WARNED{$key}++;
        return;
    };

    my @measurements;
    my $add = sub {
        my (%a) = @_;
        my ($id, $label) = $resolve_code->($a{key}, $a{fb_id}, $a{fb_label});
        return unless $id;
        my @mods = ({ id => "LP7753-9", label => "Measurement: = $a{value} $a{mod_unit}" }, @{ $a{extra} // [] });
        push @mods, $lat_obj if $lat_obj;
        push @measurements, {
            assay => { id => $id, label => $label },
            value => { quantity => { comparator => '=', value => $a{value}, unit => { label => $a{unit} } } },
            modifiers => \@mods,
            ($ref_date ? (timeOfCollection => { timestamp => $ref_date }) : ())
        };
    };

    # 1. Visus mit eigener Brille (eB)
    if (defined $parsed_ref->{eb_value}) {
        $add->(key => "visual acuity own glasses$vside", fb_id => "LOINC:28637-7",
               fb_label => "Visual acuity with own glasses$vlabel",
               value => $parsed_ref->{eb_value}, unit => "decimal", mod_unit => "decimal",
               extra => [{ id => "LP7753-9", label => "with own glasses (eB)" }]);
    }

    # 2. Bestkorrigierter (cc) bzw. unkorrigierter (sc) Visus
    if (defined $parsed_ref->{visus_value} && (!$parsed_ref->{is_own_glasses} || defined $parsed_ref->{sphere})) {
        my $bc   = $parsed_ref->{is_best_corrected} ? 1 : 0;
        my $kind = $bc ? 'best corrected' : 'uncorrected';
        my $fb   = $bc
            ? ($is_left ? "LOINC:65897-1" : $is_right ? "LOINC:65893-0" : "LOINC:28637-7")
            : ($is_left ? "LOINC:98498-9" : $is_right ? "LOINC:98499-7" : "LOINC:28637-7");
        $add->(key => "visual acuity $kind$vside", fb_id => $fb, fb_label => "Visual acuity $kind$vlabel",
               value => $parsed_ref->{visus_value}, unit => "decimal", mod_unit => "decimal");
    }

    # PATCH 2026-10-14: Lochblendenvisus (LB). Ohne eigenen Intercept
    # ('^visual acuity pinhole right eye$' usw.) als bestkorrigierter Visus
    # geführt, erkennbar am Modifier "with pinhole (LB)".
    if (defined $parsed_ref->{lb_value}) {
        my $fb = $is_left ? "LOINC:65897-1" : $is_right ? "LOINC:65893-0" : "LOINC:28637-7";
        $add->(key => "visual acuity pinhole$vside", fb_id => $fb, fb_label => "Visual acuity best corrected$vlabel",
               value => $parsed_ref->{lb_value}, unit => "decimal", mod_unit => "decimal",
               extra => [{ id => "LP7753-9", label => "with pinhole (LB)" }]);
    }

    # 3. Sphäre, Zylinder, Achse, sphärisches Äquivalent
    $add->(key => "refraction sphere $rside", value => $parsed_ref->{sphere},
           unit => "diopter", mod_unit => "[diop]") if defined $parsed_ref->{sphere};
    $add->(key => "refraction cylinder $rside", value => $parsed_ref->{cylinder},
           unit => "diopter", mod_unit => "[diop]") if defined $parsed_ref->{cylinder};
    $add->(key => "refraction axis $rside", value => $parsed_ref->{axis},
           unit => "deg", mod_unit => "deg") if defined $parsed_ref->{axis};
    $add->(key => "refraction spherical equivalent $rside", value => $parsed_ref->{spherical_equivalent},
           unit => "diopter", mod_unit => "[diop]") if defined $parsed_ref->{spherical_equivalent};

    return @measurements;
}

# Liefert zu einem Schlüssel den Intercept mit exakt '^<schlüssel>$'.
# Breitere LOINC-Intercepts (z. B. /visus/) werden bewusst ignoriert.
helper ophthalmic_loinc_resolver => sub {
    my ($self) = @_;
    return sub {
        my ($key) = @_;
        my $want = '^' . $key . '$';
        my ($r) = grep { !$_->{suppress} && ($_->{pattern} // '') eq $want }
                  @{ $self->get_domain_intercepts('loinc') };
        return $r ? { id => $r->{code}, label => $r->{label} } : undef;
    };
};

# =========================================================================
# PATCH 2026-10-22: KATARAKT-OP-PARAMETER AUS OPERATIONSBERICHTEN
# Zielrefraktion und Phako-Zeitleistungswert (CDE, Einheit %·s). LOINC hat
# für beide keine Codes, daher lokale Analogcodes je Auge, analog zum
# sphärischen Äquivalent (95327-3 rechts / 95328-1 links):
#   LOINC:95327-A / LOINC:95328-A  Zielrefraktion rechts / links  (diopter)
#   LOINC:64817-A / LOINC:64818-A  Phako-Zeitleistungswert r / l  (%.s)
#   LOINC:64819-A / LOINC:64820-A  IOL-Stärke rechts / links      (diopter),
#                                  Modell als Modifier "IOL model: …"
# LOINC kennt keine Codes für Zielrefraktion, CDE oder implantierte IOL-Stärke
# (nur DICOM: Target Refraction (0022,1037), IOL Power (0022,1090)).
# Die Werte werden deterministisch aus dem ganzen Dokument gelesen. Aus den
# LLM-Items wird die Angabe herausgeschnitten, sonst landet die Zielrefraktion
# über extract_visus_and_refraction als Sphäre/SÄ der gemessenen Refraktion.
# Labels bewusst ohne "spherical equivalent" (_ppd_refraction_group).
# =========================================================================
our %CATARACT_OP_LOINC = (
    target_refraction => {
        R        => ['LOINC:95327-A', 'Right eye Target refraction, planned postoperative (local code)'],
        L        => ['LOINC:95328-A', 'Left eye Target refraction, planned postoperative (local code)'],
        unit     => 'diopter',
        mod_unit => '[diop]',
    },
    phaco_cde => {
        R        => ['LOINC:64817-A', 'Right eye Phacoemulsification cumulative dissipated energy (local code)'],
        L        => ['LOINC:64818-A', 'Left eye Phacoemulsification cumulative dissipated energy (local code)'],
        unit     => '%.s',
        mod_unit => '%.s',
    },
    iol_power => {
        R        => ['LOINC:64819-A', 'Right eye Intraocular lens power, implanted (local code)'],
        L        => ['LOINC:64820-A', 'Left eye Intraocular lens power, implanted (local code)'],
        unit     => 'diopter',
        mod_unit => '[diop]',
    },
);

our $CAT_SIDE_TOK = qr/RA|LA|OD|OS|rechts|links/i;

# Zielrefraktion: Schlüsselwort, optional (Formel), optional Seite, dann Wert.
# Zwischen Schlüssel und Wert sind nur wenige feste Füllwörter erlaubt, damit
# "Zielrefraktion erreicht, Refraktion -0,5" NICHT als Ziel -0,5 gelesen wird.
our $TR_VAL = qr{
    (?: [+\-]?\s?\d{1,2}(?:[.,]\d{1,3})?(?![\d.,]*\s*(?:mm|µm|um|%))
      | emmetrop\w* | plan[ou]?\b
      | (?:±|\+\s*/?\s*-|\$?\\pm\$?)\s*\$?0(?:[.,]0+)?\$?(?!\s*[.,]?\d) )
    (?:\s*(?:dptr?\.?|dioptrien|diopters?|D\b|sph\b\.?))?
}xi;

our $TARGET_REFR_RE = qr{
    \b(?:ziel[- ]?refr(?:aktion)?\.?|angestrebte\s+(?:post(?:operative)?\s+)?refraktion|refraktionsziel
       |target\s+refraction|target\s*(?=[:=])
       |ziel\b(?=\s*(?:[:=]|±|\+\s*/?\s*-|\$?\\pm|[+\-]?\s?\d)))
    \s*(?:\([^()\n]{0,40}\)\s*)?
    (?:($CAT_SIDE_TOK)\b\.?\s*)?
    (?:[:=]\s*)?
    (?:(?:von|ca\.?|etwa|geplant|angestrebt|bei)\s*)?
    (?:[:=]\s*)?
    ($TR_VAL)
}xi;

# Zweiter Wert in derselben Angabe: "Zielrefraktion RA -0,5 / LA -2,5"
our $TARGET_REFR_NEXT_RE = qr{\G\s*[/;,]\s*($CAT_SIDE_TOK)\b\.?\s*(?:[:=]\s*)?($TR_VAL)}xi;

# Phako-Zeitleistungswert / CDE: Zahl ohne Doppelpunkt (0:42 ist eine Zeit)
our $PHACO_CDE_RE = qr{
    \b(?:(?:phako|phaco)[- ]?)?(?:zeit[- ]?leistungs[- ]?wert|cde|cumulative\s+dissipated\s+energy)\b
    \s*(?:\([^()\n]{0,30}\)\s*)?
    (?:($CAT_SIDE_TOK)\b\s*)?
    (?:[:=]\s*)?
    (?:ca\.?\s*)?
    (\d{1,3}(?:[.,]\d{1,3})?)(?![\d.,]*\s*(?::\d|mm|µm|um|dpt|ml\b|min\b))
    (?:\s*(?:%\s*[x*·.\-]?\s*s(?:ek|ec)?\b\.?|%s\b))?
}xi;

# IOL-Stärke. Ein Wert zählt nur mit Einheit D/dpt ODER mit Vorzeichen und
# Nachkommastelle ("+21,0" wie in "CT Asphina 409M. +21,0"), damit "409M"
# (Modell) oder "IOL mit Injektor" nicht als Stärke gelesen werden.
our $IOL_POWER_VAL = qr{
    ( [+\-]?\s?\d{1,2}(?:[.,]\d{1,2})?(?=\s*(?:dptr?\.?|D)\b)
    | [+\-]\s?\d{1,2}[.,]\d{1,2}(?![\d.,]|\s*(?:mm|µm|um|%|cyl|zyl)) )
    (?:\s*(?:dptr?\.?|D)\b)?
}xi;
# (a) mit Schlüsselwort: "Implantierte IOL: CT Asphina 409M +19,5D", "HKL-Stärke 21,0 dpt"
our $IOL_LABELED_RE = qr{
    \b(?:implantierte?n?\s+)?(?:IOL|HKL|hinterkammerlinse|intraokularlinse|kunstlinse)
    (?:[- ]?st[äa]rke)?\b
    \s*(?:($CAT_SIDE_TOK)\b\s*)?
    (?:[:=]\s*)?
    ([A-Za-z][^\n:;,()]{0,40}?)??\s*
    (?<![\w.,])$IOL_POWER_VAL
}xi;
# (b) ohne Schlüsselwort, nur bekannte Modellnamen: "CT Asphina 409M +21,5D"
our $IOL_MODEL_RE = qr{
    \b((?:(?:CT\s*)?Asphina|CT\s*Lucia|AT\s*(?:LISA|Torbi|Elana)|Tecnis|Eyhance|Synergy|Symfony|AcrySof|SN60WF|SA60AT
       |Clareon|Vivity|PanOptix|enVista|Envista|Vivinex|iSert|Hoya|RayOne|Akreos|Lentis|Precizon|ZCB00|MX60|Bi[- ]?Flex
       |Artis|Podeye|Podfa|LuxSmart|LuxGood|Isopure|Sensar)\b
    [^\n:;,()]{0,30}?)\s*
    (?<![\w.,])$IOL_POWER_VAL
}xi;

our $PHACO_CONTEXT_RE = qr/\b(?:phako|phaco|katarakt|kataract|cataract|hkl|iol|hinterkammerlinse|kunstlinse|linsenkern)\w*/i;

sub _cat_side {
    my $s = shift // '';
    return 'R' if $s =~ /^(?:R|RA|OD|rechts?|rechte[ns]?|right)$/i;
    return 'L' if $s =~ /^(?:L|LA|OS|links?|linke[ns]?|left)$/i;
    return undef;
}

sub _cat_line_side {
    my $l = shift // '';
    my $r = $l =~ /\b(?:RA|OD|rechts|rechte[ns]?\s+auge)\b/i ? 1 : 0;
    my $s = $l =~ /\b(?:LA|OS|links|linke[ns]?\s+auge)\b/i   ? 1 : 0;
    return $r && !$s ? 'R' : $s && !$r ? 'L' : undef;
}

# Operiertes Auge aus dem Dokument; bei widersprüchlichen Angaben undef
sub _cat_doc_side {
    my $t = shift // '';
    if ($t =~ /\b(?:operierte[ns]?\s+auge|op[- ]?auge|op[- ]?seite|seite|auge|lokalisation)\s*[:=]\s*($CAT_SIDE_TOK)\b/i) {
        return _cat_side($1);
    }
    my %sides;
    while ($t =~ /$PHACO_CONTEXT_RE[^\n]{0,60}?\b($CAT_SIDE_TOK)\b/g) { my $s = _cat_side($1); $sides{$s}++ if $s; }
    while ($t =~ /\b(RA|LA|OD|OS)\b[^\n]{0,40}?$PHACO_CONTEXT_RE/g)  { my $s = _cat_side($1); $sides{$s}++ if $s; }
    while ($t =~ /\b(?:am|des|das)\s+(rechte|linke)n?\s+auge/gi)      { my $s = _cat_side($1); $sides{$s}++ if $s; }
    my @s = keys %sides;
    return @s == 1 ? $s[0] : undef;
}

# Datum der Operation ("OP-Datum: 1.7.2026"), sonst Briefdatum, sonst undef
sub _cat_doc_date {
    my ($t, $ref) = @_;
    return undef unless defined $t;
    my $iso = sub {
        my ($d, $m, $y) = @_;
        $y += ($y < 70 ? 2000 : 1900) if $y < 100;
        return undef unless $d >= 1 && $d <= 31 && $m >= 1 && $m <= 12;
        return sprintf('%04d-%02d-%02d', $y, $m, $d);
    };
    # (eigener Parser: extract_event_date maskiert Datumsangaben wie "1.7.2026")
    if ($t =~ /\b(?:OP[- ]?Datum|Operationsdatum|Datum\s+der\s+Operation|operiert\s+am)\s*:?\s*([0-3]?\d)\.\s?([01]?\d)\.\s?(\d{4}|\d{2})\b/i) {
        return $iso->($1, $2, $3);
    }
    # Briefdatum im Kopf: "Freiburg, den 1.7.2026"
    if (substr($t, 0, 3000) =~ /,\s*den\s+([0-3]?\d)\.\s?([01]?\d)\.\s?(\d{4})\b/) {
        return $iso->($1, $2, $3);
    }
    return undef;
}

sub _cat_value {
    my ($kind, $raw) = @_;
    return undef unless defined $raw;
    return 0 if $kind eq 'target_refraction' && $raw =~ /^\s*(?:emmetrop|plan|±|\+\s*\/?\s*-|\$?\\pm)/i;
    return undef unless $raw =~ /^\s*([+\-]?)\s?(\d+(?:[.,]\d+)?)/;
    (my $v = "$1$2") =~ s/,/./;
    return $v + 0;
}

sub _cat_normalize {
    my $t = shift // '';
    $t =~ s/[\x{2212}\x{2013}\x{2011}]/-/g;
    $t =~ s/[\x{a0}\x{202f}]/ /g;
    return $t;
}

# Liefert ({ kind, value, side ('R'/'L'/undef), raw }, ...)
# %o: fallback_side ('R'/'L'), doc_text (für die Seitenbestimmung), ctx (Phako-Kontext erzwingen)
sub extract_cataract_op_parameters {
    my ($text, %o) = @_;
    return () unless defined $text && length $text;
    my $t = _cat_normalize($text);
    my $ctx = $o{ctx} || $t =~ $PHACO_CONTEXT_RE;

    my ($doc_side, $doc_done);
    my (@out, %first);
    for my $line (split /\r?\n/, $t) {
        my @hits;
        while ($line =~ /$TARGET_REFR_RE/g) {
            push @hits, ['target_refraction', $1, $2, $&];
            while ($line =~ /$TARGET_REFR_NEXT_RE/gc) { push @hits, ['target_refraction', $1, $2, $&]; }
        }
        if ($ctx) {
            while ($line =~ /$PHACO_CDE_RE/g) { push @hits, ['phaco_cde', $1, $2, $&]; }
        }
        my $iol_n = 0;
        while ($line =~ /$IOL_LABELED_RE/g) { $iol_n++; push @hits, ['iol_power', $1, $3, $&, $2]; }
        if (!$iol_n && $ctx) {
            while ($line =~ /$IOL_MODEL_RE/g) { push @hits, ['iol_power', undef, $2, $&, $1]; }
        }
        for my $h (@hits) {
            my ($kind, $stok, $raw, $match, $model) = @$h;
            my $val = _cat_value($kind, $raw);
            next unless defined $val;
            my $side = _cat_side($stok) // _cat_line_side($line);
            unless ($side) {
                unless ($doc_done++) { $doc_side = _cat_doc_side(defined $o{doc_text} ? _cat_normalize($o{doc_text}) : $t); }
                $side = $doc_side // $o{fallback_side};
            }
            my $key = $kind . '|' . ($side // '-');
            if (exists $first{$key}) {
                warn "[CATARACT OP] Weiterer Wert für $key ignoriert: '$match'\n";
                next;
            }
            $first{$key} = 1;
            $model = undef if defined $model && $model !~ /\p{L}/;
            $model =~ s/^\s+|[\s.]+$//g if defined $model;
            push @out, { kind => $kind, value => $val, side => $side, raw => $match,
                         (defined $model && length $model ? (model => $model) : ()) };
        }
    }
    return @out;
}

# Schneidet Zielrefraktion/CDE/IOL-Stärke aus einem Text heraus (für LLM-Items)
sub strip_cataract_op_parameters {
    my ($text, $ctx) = @_;
    my $t = _cat_normalize($text // '');
    $t =~ s/$TARGET_REFR_RE(?:\s*[\/;,]\s*$CAT_SIDE_TOK\b\.?\s*(?:[:=]\s*)?$TR_VAL)*/ /g;
    my $c = $ctx || $t =~ $PHACO_CONTEXT_RE;
    $t =~ s/$PHACO_CDE_RE/ /g if $c;
    my $n = ($t =~ s/$IOL_LABELED_RE/ /g);
    $t =~ s/$IOL_MODEL_RE/ /g if !$n && $c;
    return $t;
}

sub build_cataract_op_measurements {
    my ($params, $ref_date) = @_;
    my @m;
    for my $p (@{ $params // [] }) {
        my $def = $CATARACT_OP_LOINC{ $p->{kind} } or next;
        unless ($p->{side} && $def->{ $p->{side} }) {
            warn "[CATARACT OP] Keine Seitenangabe für '$p->{raw}' – Messung entfällt.\n";
            next;
        }
        my ($id, $label) = @{ $def->{ $p->{side} } };
        my $q = { comparator => '=', value => $p->{value}, unit => $def->{unit} };
        unless (loinc_value_plausible($id, $q)) {
            warn "[CATARACT OP] Unplausibler Wert '$p->{raw}' -> $id verworfen.\n";
            next;
        }
        push @m, {
            assay     => { id => $id, label => $label },
            value     => { quantity => { comparator => '=', value => $p->{value}, unit => { label => $def->{unit} } } },
            modifiers => [
                { id => 'LP7753-9', label => "Measurement: = $p->{value} $def->{mod_unit}" },
                ($p->{model} ? { id => 'LP7753-9', label => "IOL model: $p->{model}" } : ()),
                ($p->{side} eq 'L' ? { id => 'HP:0012835', label => 'Left' } : { id => 'HP:0012834', label => 'Right' }),
            ],
            ($ref_date ? (timeOfCollection => { timestamp => $ref_date }) : ()),
        };
    }
    return @m;
}

# =========================================================================
# PATCH 2026-10-23: ENDOTAMPONADE (Silikonöl / Gas / Luft)
# LOINC kennt keine Tamponade-Codes; OPS 5-158.x1..x5 unterscheidet nur
# Luft / andere Gase / Silikonöl, ohne Gasart, Konzentration und Viskosität,
# und deckt DMEK nicht ab. Daher lokale Analogcodes je Auge und Ort:
#   LOINC:64821-A / 64822-A  Glaskörperraum (Vitrektomie)     rechts / links
#   LOINC:64823-A / 64824-A  Vorderkammer (DMEK, DSAEK, Rebubbling) r / l
# Wert: value.ontologyClass NCIT:C25250 mit normiertem Label, z. B.
#   "Silicone oil 5000 cSt", "Heavy silicone oil", "SF6 20%", "C3F8 14%", "Air".
# Bei mehreren Angaben ("gegen Luft und dann gegen 5000er Silikonöl") gilt die
# letzte im Text; Silikonölentfernung zählt nicht als Tamponade.
# =========================================================================
our %TAMPONADE_LOINC = (
    vitreous => {
        R => ['LOINC:64821-A', 'Right eye Vitreous cavity endotamponade (local code)'],
        L => ['LOINC:64822-A', 'Left eye Vitreous cavity endotamponade (local code)'],
    },
    anterior => {
        R => ['LOINC:64823-A', 'Right eye Anterior chamber tamponade (local code)'],
        L => ['LOINC:64824-A', 'Left eye Anterior chamber tamponade (local code)'],
    },
);

# Normierte Werte; auch Whitelist für die Anonymisierung
our $TAMPONADE_LABEL_RE = qr/^(?:Air|Heavy silicone oil|Silicone oil(?: \d{3,4} cSt)?|(?:SF6|C2F6|C3F8)(?: \d{1,2}(?:\.\d)?%)?)$/;

# Fundstellen (Reihenfolge im Text zählt)
our $TAMP_OIL_RE = qr{
    (?<heavy> densiron\w* (?:\s*68)? | oxane\s*hd | schwere[sn]?\s+silikon[- ]?öl\w* | heavy\s+silicone\s+oil )
  | (?: (?<visc1>\d{3,4}) \s* (?:er|cs|cst|mpas)? \s* [- ]? (?:silikon[- ]?|silicon[- ]?)?öl\w* )
  | (?: (?:siluron|oxane)\s*(?<visc2>\d{3,4}) )
  | (?: (?<oilw> (?:silikon|silicon)[- ]?(?:öl|oil)\w* ) (?: \s*\(?\s*(?<visc3>\d{3,4}) \s* (?:er|cs|cst|mpas)? \)? )? )
}xi;
our $TAMP_GAS_RE = qr{
    (?: (?<pct1>\d{1,2}(?:[.,]\d)?) \s* (?:%|prozent) \s* (?:-?ige[sn]?\s+)? )?
    \b(?<gas> SF\s?6 | C\s?2\s?F\s?6 | C\s?3\s?F\s?8 | schwefelhexafluorid | hexafluorethan | perfluorethan | perfluorpropan | octafluorpropan )
    (?: [- ]?gas\w* )?
    (?: \s*\(?\s* (?:in\s+)? (?<pct2>\d{1,2}(?:[.,]\d)?) \s* (?:%|prozent) )?
}xi;
our $TAMP_AIR_RE = qr{
    \b(?: luft(?:tamponade|endotamponade|füllung|blase|eingabe)?\b | luft-?\w*(?:füllung|tamponade|austausch) | fluid[- ]air )
}xi;
# "Luft" zählt nur mit Tamponade-Kontext im selben Satz
our $TAMP_AIR_CTX_RE = qr/\b(?:gegen|austausch\w*|exchange|f[üu]ll\w*|gef[üu]llt|tamponade|endotamponade|blase|eingabe|eingegeben|injiz\w*|vorderkammer|VK)\b|tamponade|füllung/i;
# Silikonöl wird entfernt, nicht eingebracht
our $TAMP_REMOVAL_RE = qr/(?:entfern|ablass|abgelassen|abgesaugt|ausgelassen|ausgewaschen|herausgespült|removal|removed)\w*/i;
our $TAMP_NEG_RE     = qr/\b(?:keine|ohne)\s+(?:\w+\s+)?(?:endo)?tamponade|\bBSS[- ]?(?:tamponade|füllung)/i;
our $TAMP_AC_RE      = qr/\b(?:vorderkammer\w*|VK|DMEK|DSAEK|DSEK|PDEK|rebubbling|re-bubbling|transplantat\w*|descemet\w*|lamelle)\b/i;
our $TAMP_VIT_RE     = qr/\b(?:vitrektomie\w*|PPV|pars[- ]plana|glask[öo]rper\w*|netzhaut\w*|retina\w*|intraokular\w*)\b/i;
our $TAMP_TOKEN_RE   = qr/silikon[- ]?öl|silicone?\s+oil|\b\d{3,4}\s*er\s+öl\b|densiron|oxane|siluron|\bSF\s?6\b|\bC\s?[23]\s?F\s?[68]\b|schwefelhexafluorid|perfluorpropan|perfluorethan|hexafluorethan/i;

# Operiertes Auge: wie bei der Katarakt-OP, zusätzlich Diagnose-/Eingriffszeilen
# ("Diagnose: Endophthalmitis RA", "PPV LA", "DMEK rechts"); widersprüchlich -> undef
sub _tamp_doc_side {
    my $t = shift // '';
    my $s = _cat_doc_side($t);
    return $s if $s;
    my %sides;
    while ($t =~ /\b(?:diagnose\w*|eingriff\w*|operation\w*|PPV|vitrektomie\w*|DMEK|DSAEK|DSEK|keratoplastik\w*|rebubbling|re-bubbling)\b[^\n]{0,80}?\b($CAT_SIDE_TOK)\b/gi) {
        my $x = _cat_side($1); $sides{$x}++ if $x;
    }
    my @s = keys %sides;
    return @s == 1 ? $s[0] : undef;
}

sub _tamp_label {
    my ($kind, $x) = @_;
    if ($kind eq 'oil') {
        return 'Heavy silicone oil' if $x->{heavy};
        my $v = $x->{visc};
        return (defined $v && $v >= 500 && $v <= 6000) ? "Silicone oil $v cSt" : 'Silicone oil';
    }
    if ($kind eq 'gas') {
        (my $g = uc($x->{gas} // '')) =~ s/\s+//g;
        $g = 'SF6'  if $g =~ /SCHWEFEL/;
        $g = 'C2F6' if $g =~ /HEXAFLUORETHAN|PERFLUORETHAN/;
        $g = 'C3F8' if $g =~ /PERFLUORPROPAN|OCTAFLUORPROPAN/;
        return undef unless $g =~ /^(?:SF6|C2F6|C3F8)$/;
        my $p = $x->{pct};
        if (defined $p) { $p =~ s/,/./; $p += 0; }
        return (defined $p && $p > 0 && $p <= 100) ? "$g $p%" : $g;
    }
    return 'Air';
}

# Liefert ({ site => 'vitreous'|'anterior', side, label, raw }, ...) – je Ort und Seite die letzte Angabe
sub extract_endotamponade {
    my ($text, %o) = @_;
    return () unless defined $text && length $text;
    my $t = _cat_normalize($text);
    my $t_lines = $t;
    $t =~ s/(\p{L})-\r?\n(\p{Ll})/$1$2/g;        # Silbentrennung am Zeilenende (OCR)
    $t =~ s/\s*\r?\n\s*/ /g;
    my $doc_ac  = $t =~ /\b(?:DMEK|DSAEK|DSEK|PDEK|keratoplastik\w*|rebubbling|re-bubbling)\b/i ? 1 : 0;
    my $doc_vit = $t =~ /\b(?:vitrektomie\w*|PPV|pars[- ]plana)\b/i ? 1 : 0;
    return () unless $doc_ac || $doc_vit || $o{ctx};

    my ($doc_side, $doc_done);
    my (%last, @order);
    for my $s (split /(?<=[.;!])\s+(?=[\p{Lu}\d(])/, $t) {
        next if $s =~ $TAMP_NEG_RE;
        my @hits;
        while ($s =~ /$TAMP_OIL_RE/g) {
            my %x = (heavy => $+{heavy}, visc => $+{visc1} // $+{visc2} // $+{visc3}, word => $+{oilw} // '');
            my ($pre, $m, $post) = ($`, $&, $');
            next if $x{word} =~ $TAMP_REMOVAL_RE || $m =~ $TAMP_REMOVAL_RE
                 || substr($post, 0, 25) =~ /^\W{0,3}(?:\w+\s+){0,2}$TAMP_REMOVAL_RE/
                 || substr($pre, -40) =~ /$TAMP_REMOVAL_RE\w*\s+(?:\w+\s+){0,3}$/;
            # "1000er Öl" ohne "Silikon" nur mit Tamponade-/Austausch-Kontext
            next if !$x{heavy} && !length $x{word} && $m !~ /silikon|silicon/i && $s !~ /gegen|austausch|tamponade|füllung|entscheidung|eingabe/i;
            push @hits, [pos($s), 'oil', \%x, $m];
        }
        while ($s =~ /$TAMP_GAS_RE/g) {
            my %x = (gas => $+{gas}, pct => $+{pct2} // $+{pct1});
            push @hits, [pos($s), 'gas', \%x, $&];
        }
        if ($s =~ $TAMP_AIR_CTX_RE) {
            while ($s =~ /$TAMP_AIR_RE/g) { push @hits, [pos($s), 'air', {}, $&]; }
        }
        next unless @hits;
        my $site = $s =~ $TAMP_AC_RE ? 'anterior'
                 : $s =~ $TAMP_VIT_RE ? 'vitreous'
                 : ($doc_ac && !$doc_vit) ? 'anterior'
                 : ($doc_vit && !$doc_ac) ? 'vitreous'
                 : ($o{site} // undef);
        unless ($site) {
            warn "[TAMPONADE] Ort unklar (Vorderkammer/Glaskörper) in '$s' – übersprungen.\n";
            next;
        }
        my $side = _cat_line_side($s);
        unless ($side) {
            unless ($doc_done++) { $doc_side = _tamp_doc_side(defined $o{doc_text} ? _cat_normalize($o{doc_text}) : $t_lines); }
            $side = $doc_side // $o{fallback_side};
        }
        for my $h (sort { $a->[0] <=> $b->[0] } @hits) {
            my $label = _tamp_label($h->[1], $h->[2]) // next;
            my $key = $site . '|' . ($side // '-');
            push @order, $key unless exists $last{$key};
            $last{$key} = { site => $site, side => $side, label => $label, raw => $h->[3] };
        }
    }
    return map { $last{$_} } @order;
}

sub build_endotamponade_measurements {
    my ($items, $ref_date) = @_;
    my @m;
    for my $p (@{ $items // [] }) {
        my $def = $TAMPONADE_LOINC{ $p->{site} } or next;
        unless ($p->{side} && $def->{ $p->{side} }) {
            warn "[TAMPONADE] Keine Seitenangabe für '$p->{raw}' – Messung entfällt.\n";
            next;
        }
        next unless $p->{label} =~ $TAMPONADE_LABEL_RE;
        my ($id, $label) = @{ $def->{ $p->{side} } };
        push @m, {
            assay     => { id => $id, label => $label },
            value     => { ontologyClass => { id => 'NCIT:C25250', label => $p->{label} } },
            modifiers => [
                { id => 'LP7753-9', label => "Endotamponade: $p->{label}" },
                ($p->{side} eq 'L' ? { id => 'HP:0012835', label => 'Left' } : { id => 'HP:0012834', label => 'Right' }),
            ],
            ($ref_date ? (timeOfCollection => { timestamp => $ref_date }) : ()),
        };
    }
    return @m;
}

# =========================================================================
# MESSWERT-MASKIERUNG: Zahlen mit Vergleichsoperator oder Einheit sind keine Jahre
# ("Endothelzelldichte >2001 Z/qmm" darf weder Datum noch Jahr 2001 werden)
# =========================================================================
our $MEASUREMENT_UNIT_REGEX = qr{
    (?:Z(?:ellen)?|cells?)\s*(?:/|pro)\s*(?:q?mm²?|mm\^?2|quadratmillimeter)
  | /\s*(?:q?mm²?|mm\^?2|µl|ul|dl|ml|min)\b
  | mm\s*hg\b | torr\b | µm | μm | um\b(?!\s+\p{Ll}) | mm[²³23]?\b | cm\b | dpt\b | dptr\b
  | % | mg\b | µg\b | ug\b | ng\b | pg\b | g/l\b | mmol | µmol | umol | nmol | u/l\b
  | tsd\b | mio\b | fl\b | sek\b | db\b
}xi;
our $MEASUREMENT_KEY_REGEX = qr/\b(?:endothel\w*|ecd|ezd|zelldichte|zellzahl|pachymetrie|cct|hornhautdicke|rnfl)\b/i;

sub mask_measurement_numbers {
    my ($t) = @_;
    return '' unless defined $t;
    $t =~ s{(?:[<>≤≥]=?|~)\s*\d+(?:[.,]\d+)?}{ }g;                                  # ">2001", "≥ 1500"
    $t =~ s{(?<![\d.,/])\b\d+(?:[.,]\d+)?\s*(?=$MEASUREMENT_UNIT_REGEX)}{ }g;       # "2050 Zellen/mm²", "520 µm"
    $t =~ s{$MEASUREMENT_KEY_REGEX\s*[:=]?\s*(?:ca\.?\s*)?\d+(?:[.,]\d+)?}{ }g;     # "ECD 2050", "Pachymetrie 2010"
    return $t;
}

# =========================================================================
# QUANTITATIVE CONSTRAINT PARSER (OPHTHALMIC, LABORATORY & CLINICAL METRICS)
# =========================================================================
sub parse_quantitative_constraint {
    my ($text) = @_;
    return undef unless defined $text && $text ne '';
    return undef if $text =~ /\b(?:n\.?\s*m\.?|nicht\s*messbar|nicht\s*beurteilbar|fehlgeschlagen)\b/i;

    # 1. Unicode, Formatierung & deutsches Dezimalkomma normalisieren
    $text =~ s/mm\s*hg/mmHg/gi;
    $text =~ s/torr/mmHg/gi;
    $text =~ s/\x{202f}/ /g;
    $text =~ s/\x{a0}/ /g;
    $text =~ s/≥/>=/g;
    $text =~ s/≤/<=/g;
    $text =~ s/‑/-/g;
    $text =~ s/\\mu\\text\{m\}/um/gi;
    $text =~ s/\\mu m/um/gi;
    $text =~ s/μm/um/gi;
    $text =~ s/µm/um/gi;
    $text =~ s/mm\^2|mm²/mm2/gi;
    $text =~ s/mm\^3|mm³|mm\?/mm3/gi;
    $text =~ s/(\d+),(\d+)/$1.$2/g;
    $text =~ s/cm\s*h2o/cmH2O/gi;
    $text =~ s/cm\s*wasser/cmH2O/gi;
    # Spannweiten wie "586-1187 Zellen/mm²" normalisieren (unteren Wert nehmen)
    $text =~ s/(\d+)\s*[-–]\s*\d+\s*(zellen|cells)/$1 $2/gi;
    
    # Bilateral Ophthalmic Pressure Intercept
    if ($text =~ /\b(?:tmax|tensio|iop|augendruck)\s*[:=]?\s*(\d{1,2})\s*[\/;]\s*(\d{1,2})\s*(?:mmhg)?\b/i) {
        my ($p_right, $p_left) = ($1 + 0, $2 + 0);
        if ($p_right >= 5 && $p_right <= 80 && $p_left >= 5 && $p_left <= 80) {
            return {
                is_bilateral_pressure => 1,
                right_iop             => $p_right,
                left_iop              => $p_left,
                unit                  => 'mmHg',
                comparator            => '='
            };
        }
    }
    # 2. Qualitative Marker (HLA-B27, Serologie, Antikörper etc.) abfangen
    if ($text =~ /\b(?:hla[- ]?b\s*\d+|cd\d+|il[- ]?\d+|covid[- ]?19|ana|anca|anti[- ]?\w+)\b/i &&
        $text =~ /\b(?:positiv|negativ|pos\.?|neg\.?|reaktiv|nicht\s*reaktiv|normal|pathologisch|befundfrei|positive|negative)\b/i) {
        return undef;
    }
    
    if ($text =~ /\bbmi\s*[:=]?\s*(\d{1,2}[\.,]\d)/i) {
        my $bmi_val = $1; $bmi_val =~ s/,/./;
        return {
            comparator => '=',
            value      => $bmi_val + 0,
            unit       => 'kg/m2',
            is_bmi     => 1
        };
    }

    # 3. Visus & Refraktion Intercept
    if ($text =~ /\b(?:visus|sehschärfe|visual\s*acuity|aufnahmevisus|entlassvisus|sc\b|cc\b|hbw\b|lsp\b|lsw\b|nulla\s*lux|handbewegung|fingerzählen|lochblende|lb\b)\b/i) {
        my $parsed_eye = extract_visus_and_refraction($text);
        # PATCH 2026-10-14: reiner Lochblendenvisus ("mit LB 1,0") ebenfalls dezimal
        my $vv = $parsed_eye ? ($parsed_eye->{visus_value} // $parsed_eye->{lb_value}) : undef;
        if (defined $vv) {
            my $comp = '=';
            $comp = '>=' if $text =~ /(?:at least|mindestens|≥|>|or better|besser)/i;
            $comp = '<=' if $text =~ /(?:at most|maximal|≤|<|or worse|schlechter)/i;

            return {
                comparator => $comp,
                value      => $vv,
                unit       => 'decimal',
                formatted  => "$comp $vv decimal"
            };
        }
    }

    # 4. Spezifischer Intercept für Ganglienzellvolumen / OCT Schichtdicken/-volumina
    if ($text =~ /\b(?:ganglienzell\w*|gcl|gc-ipl|rfl)\b.*?(?:\d+[\.,]\d+\s*mm\s*[:=]?\s*)?([+-]?\d+(?:\.\d+)?)\s*(mm[³3]|mm\^3|µm|um|nl)/i) {
        my $val  = $1; $val =~ s/,/./g;
        my $unit = $2;
        $unit = 'mm3' if $unit =~ /mm[³3]|mm\^3/i;
        $unit = 'um'  if $unit =~ /µm|um/i;
        return {
            comparator => '=',
            value      => $val + 0,
            unit       => $unit,
            formatted  => "= $val $unit"
        };
    }

    # 5. Blutdruck-Intercept (ZWINGEND mit explizitem Signalwort rr/blutdruck/bp)
    if ($text =~ /\b(?:rr|blutdruck|bp)\s*[:=]?\s*(\d{2,3})\s*[\/;]\s*(\d{2,3})\s*(?:mmhg)?\b/i) {
        my ($sys, $dia) = ($1 + 0, $2 + 0);
        if ($sys >= 50 && $sys <= 260 && $dia >= 30 && $dia <= 160) {
            return {
                is_blood_pressure => 1,
                systolic          => $sys,
                diastolic         => $dia,
                unit              => 'mmHg',
                comparator        => '='
            };
        }
    }

    # Bilateraler Hertel / Exophthalmometrie Intercept
    if ($text =~ /\b(?:exophthalmometr\w*|hertel)\s*[:=]?\s*(?:RA\s*)?(\d{1,2})\s*(?:mm)?\s*[\/,;]\s*(?:LA\s*)?(\d{1,2})\s*(?:mm)?/i) {
        my ($h_right, $h_left) = ($1 + 0, $2 + 0);
        if ($h_right >= 8 && $h_right <= 35 && $h_left >= 8 && $h_left <= 35) {
            return {
                is_bilateral_hertel => 1,
                right_hertel        => $h_right,
                left_hertel         => $h_left,
                unit                => 'mm',
                comparator          => '='
            };
        }
    }

    # -------------------------------------------------------------
    # BMO-Area / Bruch's Membrane Opening Fläche (bilateral & unilateral)
    # -------------------------------------------------------------
    # 1. Bilateraler BMO-Area Intercept (z. B. "BMO-Area: 1,49/1,83 mm²")
    if ($text =~ /\b(?:bmo[- ]?(?:area|fl[äa\?]che)?|fl[äa\?]che)\s*[:=]?\s*(\d+(?:[\.,]\d+)?)\s*[\/;]\s*(\d+(?:[\.,]\d+)?)\s*(?:mm[²23]|mm\^?[23]|mm\?)?\b/i) {
        my ($bmo_r, $bmo_l) = ($1, $2); # ERST String zuweisen, KEIN vorzeitiges '+ 0.0'!
        $bmo_r =~ s/,/./;
        $bmo_l =~ s/,/./;
        return {
            is_bilateral_bmo => 1,
            right_bmo        => $bmo_r + 0.0,
            left_bmo         => $bmo_l + 0.0,
            unit             => 'mm2',
            comparator       => '='
        };
    }

    # 2. Unilateraler BMO-Area Intercept (z. B. "bmo-oct R: BMO-Area 1,91 mm²")
    if ($text =~ /\b(?:bmo[- ]?(?:area|fl[äa\?]che)?|bmo[- ]?oct.*?area)\s*[:=]?\s*([+-]?\d+(?:[\.,]\d+)?)\s*(?:mm[²23]|mm\^?[23]|mm\?)?/i) {
        my $val = $1;
        $val =~ s/,/./;
        return {
            comparator => '=',
            value      => $val + 0.0,
            unit       => 'mm2',
            formatted  => "= $val mm2"
        };
    }

    # PATCH 2026-10-14: Endothelzelldichte direkt am Einheitenmuster erkennen,
    # unabhängig von vorangestellten Datumsangaben ("10/23: 699 Zellen/mm²")
    if ($text =~ /([<>]=?)?\s*(?<![\d.,\/])(\d{3,4})\s*(?:zellen|z|cells)\s*(?:\/|pro)\s*(?:qmm|mm2|quadratmillimeter)\b/i) {
        my ($cmp, $v) = ($1 // '=', $2 + 0);
        return {
            comparator => $cmp,
            value      => $v,
            unit       => '{cells}/mm2',
            formatted  => "$cmp $v {cells}/mm2"
        };
    }

    # 6. Clinical Rating Scale / Instrument Name extraction
    my $scale_name = undef;
    if ($text =~ /\b(VAS|VBR-?10|NEI(?:-VFQ)?|Foster|SUN|Oxford|OSDI|SPEED|McMonnies|Efron|Jenvis|ETDRS|Snellen|LogMAR|CDR|Hertel)\b/i) {
        my $raw_scale = $1;
        if    ($raw_scale =~ /^vas$/i)     { $scale_name = 'VAS'; }
        elsif ($raw_scale =~ /^vbr-?10$/i) { $scale_name = 'VBR-10'; }
        elsif ($raw_scale =~ /^nei/i)      { $scale_name = 'NEI'; }
        elsif ($raw_scale =~ /^foster$/i)  { $scale_name = 'Foster'; }
        elsif ($raw_scale =~ /^sun$/i)     { $scale_name = 'SUN'; }
        elsif ($raw_scale =~ /^oxford$/i)  { $scale_name = 'Oxford'; }
        elsif ($raw_scale =~ /^osdi$/i)    { $scale_name = 'OSDI'; }
        elsif ($raw_scale =~ /^speed$/i)   { $scale_name = 'SPEED'; }
        elsif ($raw_scale =~ /^logmar$/i)  { $scale_name = 'LogMAR'; }
        elsif ($raw_scale =~ /^cdr$/i)     { $scale_name = 'CDR'; }
        elsif ($raw_scale =~ /^hertel$/i)  { $scale_name = 'Hertel'; }
        else                               { $scale_name = uc($raw_scale); }
    }

    my $clean_text = $text;
    $clean_text =~ s/\(.*?\)//g;

    # -------------------------------------------------------------
    # Datumsangaben (z. B. "01/2023", "14.08.2023", "stabil zu 2023")
    # maskieren/entfernen, damit Tage/Monate nicht als Messwert "1" geparst werden!
    # -------------------------------------------------------------
    # PATCH 2026-10-14: Visit-Präfix mit zweistelligem Jahr ("10/23: 699 Zellen/mm²", "05/24: Astigmatismus ...")
    $clean_text =~ s/(?:^|(?<=[\s;,]))(?:0?[1-9]|1[0-2])\/(?:19|20)?\d{2}\s*[:=]/ /g;
    $clean_text =~ s/\b(?:stabil\s+zu|progredient\s+zu|befund\s+vom?|stand|vom?|zuletzt|am)\s+(?:0?[1-9]|1[0-2])[\/\.](?:19|20)?\d{2}\b/ /gi;
    $clean_text =~ s/\b(?:0?[1-9]|[12]\d|3[01])\.(?:0?[1-9]|1[0-2])\.(?:19|20)\d{2}\b/ /g; # DD.MM.YYYY
    $clean_text =~ s/\b(?:0?[1-9]|1[0-2])\/(?:19|20)\d{2}\b/ /g;                           # MM/YYYY
    unless ($clean_text =~ $MEASUREMENT_KEY_REGEX) {
        $clean_text =~ s/(?<![<>=≥≤~\d])(?<![<>=]\s)\b(?:19|20)\d{2}\b(?!\s*$MEASUREMENT_UNIT_REGEX)/ /g;
    }
    # Reines Datum / rein qualitativer Text übrig geblieben? -> Kein quantitativer Messwert
        if ($clean_text !~ /\d/) {
            return undef;
        }
    # Akronyme mit Zahlen maskieren, um Fehlmatches zu verhindern
    $clean_text =~ s/\b(?:löslicher\s+)?interleukin[- ]?(?:rezeptor[- ]?)?\d+\b/__INTERLEUKIN__/gi;
    $clean_text =~ s/\b(?:s?il[- ]?2[- ]?r|il[- ]?\d+)\b/__INTERLEUKIN__/gi;
    $clean_text =~ s/\b(?:hb[- ]?a\s*1\s*c|hba1c|a1c)\b/__HBA1C__/gi;
    $clean_text =~ s/\b(?:hla[- ]?b\s*27|b27)\b/__HLAB27__/gi;
    $clean_text =~ s/\b(?:covid[- ]?19)\b/__COVID19__/gi;
    $clean_text =~ s/\b(?:cd[348]|cd\d+)\b/__CDMARKER__/gi;
    $clean_text =~ s/\b(?:f?t[34])\b/__THYROID__/gi;
    $clean_text =~ s/\b(?:b\s*12)\b/__VITAMINB12__/gi;
    $clean_text =~ s/\b(?:bp[- ]?180|bp[- ]?230)\b/__BPAUTOMARKER__/gi;
    $clean_text =~ s/\b(?:ckd[- ]?epi)\b/__CKDEPI__/gi;

    # 7. Vergleichsoperatoren und Einzel-Zahlenwerte extrahieren
    if ($clean_text =~ /(?:score|grading|grade|scale|level|value|result|staining|hyperemia|discomfort|washout|duration|period|prior|within|area|radius|visus|tensio|cdr|hertel|but|tbut|__HBA1C__|gfr|wert)?\s*[:=]?\s*([<>]=?|=)?\s*(?<![a-zA-Z0-9\-\/])([+-]?\d+(?:\.\d+)?)\s*([a-zA-Z%µ°\/\-\.\s\^23\*]*)/i) {
        my $raw_comp = $1;
        my $val      = $2 + 0;
        my $unit_raw = lc($3 // '');

        my $is_logmar = ($clean_text =~ /\blogmar\b/i || ($scale_name && $scale_name eq 'LogMAR')) ? 1 : 0;

        if (!$raw_comp) {
            if ($clean_text =~ /\b(?:or\s+better|better|improved)\b/i) {
                $raw_comp = $is_logmar ? '<=' : '>=';
            }
            elsif ($clean_text =~ /\b(?:or\s+worse|worse|deteriorated)\b/i) {
                $raw_comp = $is_logmar ? '>=' : '<=';
            }
            elsif ($clean_text =~ /(?:minimum|at least|at min|atleast|≥|>|longer|more than|at or above)/i) {
                $raw_comp = '>=';
            }
            elsif ($clean_text =~ /(?:maximum|at most|at max|atmost|≤|<|within|less than|washout|prior to|below)/i) {
                $raw_comp = '<=';
            }
            elsif ($clean_text =~ /\b(?:tensio|cdr|hertel|druck|ausgrabung|cup|disc|but|tbut|__HBA1C__|gfr)\b/i) {
                $raw_comp = '=';
            }
            else {
                $raw_comp = '=';
            }
        }

        my $comp = '=';
        if    ($raw_comp eq '>')  { $comp = '>'; }
        elsif ($raw_comp eq '>=') { $comp = '>='; }
        elsif ($raw_comp eq '<=') { $comp = '<='; }
        elsif ($raw_comp eq '<')  { $comp = '<'; }
        elsif ($raw_comp eq '=')  { $comp = '='; }

        my $unit = undef;

        # -------------------------------------------------------------
        # EINHEITEN-NORMALISIERUNG (LABOR, OPHTHALMOLOGIE, TEMPORAL)
        # -------------------------------------------------------------
        # Endotheldichte
        if ($unit_raw =~ /\b(?:zellen\s*(?:\/|\s*pro\s*)\s*(?:quadratmillimeter|mm2|mm²|mm\^2)|cells\s*\/\s*mm2|cells\s*\/\s*mm²|cells\/mm\^2)\b/i
            || $clean_text =~ /\b(?:endothel\w*|ecd|cell density)\b/i) {
            $unit = '{cells}/mm2';
        }
        # Prozent
        elsif ($unit_raw =~ /%|\b(?:percent|prozent|pct)\b/i || $clean_text =~ /%/) {
            $unit = '%';
        }
        elsif ($clean_text =~ /\b(?:bmi|body\s*mass\s*index)\b/i || $unit_raw =~ /kg\/m2|kg\/m²/i) {
            $unit = 'kg/m2';
        }
        # Intraokulardruck / Blutdruck
        elsif ($unit_raw =~ /\b(?:mmhg|icare|tonometrie|goldmann|applanation)\b/i
               || $clean_text =~ /\b(?:tensio|iop|augendruck|icare|tonometrie)\b/i) {
            $unit = 'mmHg';
        }
        # Mikroliter-Zellzahlen & Hämatologie (Tsd/µl, Mio/µl, fl, pg)
        elsif ($unit_raw =~ /\b(?:tsd\s*\/\s*(?:µl|ul)|tsd\b|k\s*\/\s*(?:µl|ul)|10\^3\s*\/\s*(?:µl|ul)|10\*3\s*\/\s*(?:µl|ul))\b/i) {
            $unit = 'tsd/µl';
        }
        elsif ($unit_raw =~ /\b(?:mio\s*\/\s*(?:µl|ul)|mio\b|m\s*\/\s*(?:µl|ul)|10\^6\s*\/\s*(?:µl|ul)|10\*6\s*\/\s*(?:µl|ul))\b/i) {
            $unit = 'Mio/µl';
        }
        elsif ($unit_raw =~ /\b(?:fl|femtoliter|femtolitres?)\b/i || $clean_text =~ /\bmcv\b/i) {
            $unit = 'fl';
        }
        elsif ($unit_raw =~ /\b(?:pg|pikogramm|picograms?)\b/i || $clean_text =~ /\bmch\b/i) {
            $unit = 'pg';
        }
        elsif ($unit_raw =~ /\bcmh2o\b/i || $clean_text =~ /\b(?:eröffnungsdruck|liquordruck|csf pressure)\b/i) {
            $unit = 'cmH2O';
        }
        # GFR / Filtrationsrate
        elsif ($unit_raw =~ /\bml\s*\/\s*min\b/i || $clean_text =~ /\b(?:gfr|ckd[- ]?epi)\b/i) {
            $unit = 'ml/min/1.73m2';
        }
        # Konzentrationen & Enzymaktivitäten
        elsif ($unit_raw =~ /\b(?:u\/l|u\/ml|iu\/l|iu\/ml|ie\/l|ie\/ml|ku\/l|ku\/ml)\b/i || $clean_text =~ /\b(?:ldh|got|gpt|ast|alt|ap|ggt|ace)\b/i) {
            $unit = 'U/l';
        }
        elsif ($unit_raw =~ /\b(?:mg\/dl|mg\/l|g\/dl|g\/l|µg\/dl|µg\/l|ug\/l|ug\/dl|mmol\/l|µmol\/l|umol\/l|nmol\/l|pg\/ml|ng\/ml)\b/i) {
            $unit = $unit_raw;
            $unit =~ s/^\s+|\s+$//g;
        }
        # Längen & Volumina
        elsif ($unit_raw =~ /\b(?:um|µm|micrometers?|microns?)\b/i || $clean_text =~ /\bpachymetrie\b/i) {
            $unit = 'um';
        }
        elsif ($unit_raw =~ /\b(?:mm3|mm\^3|mm³)\b/i || $clean_text =~ /\b(?:gzv|volumen|volume)\b/i) {
            $unit = 'mm3';
        }
        elsif ($unit_raw =~ /\b(?:mm2|mm\^2|mm²)\b/i)                              { $unit = 'mm2'; }
        elsif ($unit_raw =~ /\b(?:mm)\b/i)                                         { $unit = 'mm'; }
        elsif ($unit_raw =~ /\b(?:cm)\b/i)                                         { $unit = 'cm'; }
        elsif ($unit_raw =~ /\b(?:diopters?|dptr|dpt|d)\b/i && $clean_text !~ /\b(?:tage?|days?|history|ago|duration)\b/i) {
            $unit = 'diopter';
        }
        # Score- & Sehtest-Skalen
        elsif ($unit_raw =~ /\bletters?\b/i)                               { $unit = 'letters'; }
        elsif ($unit_raw =~ /\blogmar\b/i || $is_logmar)                   { $unit = 'logmar'; }
        elsif ($clean_text =~ /\bvisus\b|\bsc\b|\bcc\b/i)                  { $unit = 'decimal'; }
        elsif ($clean_text =~ /\bcdr\b|\bcup[- ]to[- ]disc\b/i)            { $unit = '{ratio}'; }

        # Zeit-Einheiten (Sekunden, Minuten, Stunden, Tage, Wochen, Monate, Jahre)
        elsif ($unit_raw =~ /^(?:s|sec|secs|seconds?|sek|sekunden?)$/i || $clean_text =~ /\b(?:but|tbut|aufbrechzeit)\b/i) {
            $unit = 's';
        }
        elsif ($unit_raw =~ /^(?:min|mins|minutes?|minuten?)$/i) {
            $unit = 'min';
        }
        elsif ($unit_raw =~ /\b(?:hrs?|hours?|stunden?|std)\b/i)                                      { $unit = 'h'; }
        elsif ($unit_raw =~ /\b(?:weeks?|wks?|wochen?)\b/i || $clean_text =~ /\b\d+\s*(?:weeks?|wks?|wochen?)\b/i) { $unit = 'wk'; }
        elsif ($unit_raw =~ /\b(?:months?|mos?|monate?n?)\b/i || $clean_text =~ /\b\d+\s*(?:months?|mos?|monate?n?)\b/i) { $unit = 'mo'; }
        elsif ($unit_raw =~ /\b(?:years?|yrs?|jahre?n?|j)\b/i || $clean_text =~ /\b\d+\s*(?:years?|yrs?|jahre?n?)\b/i) { $unit = 'a'; }
        elsif ($unit_raw =~ /\b(?:days?|tage?n?|d)\b/i || $clean_text =~ /\b\d+\s*(?:days?|tage?n?)\b/i) { $unit = 'd'; }
        # Ergänzung für Enzymaktivitäten und Hormon-/Tumormarker-Konzentrationen:
        elsif ($unit_raw =~ /\b(?:m?iu\/ml|m?iu\/l|m?u\/l|m?u\/ml|ie\/l|ie\/ml|ku\/l)\b/i) {
            $unit = $unit_raw;
            $unit =~ s/^\s+|\s+$//g;
        }
        elsif ($unit_raw =~ /\b(?:ng\/ml|pg\/ml|µg\/l|ug\/l|mg\/dl|g\/l|mmol\/l|µmol\/l)\b/i) {
            $unit = $unit_raw;
            $unit =~ s/^\s+|\s+$//g;
        }
        elsif ($unit_raw =~ /\b(?:db|dezibel|decibels?)\b/i || $clean_text =~ /\b(?:md|psd|ms|sensitivit[äa]t|defizit)\b/i) {
            $unit = 'dB';
        }
        # Fallback-Einheiten
        unless ($unit) {
            if ($clean_text =~ /\b__HBA1C__\b/i) {
                $unit = '%';
            } elsif ($clean_text =~ /\b(?:washout|duration|period|prior to|within|ago)\b/i) {
                $unit = 'd';
            } elsif ($scale_name) {
                $unit = "scale ($scale_name)";
            } else {
                $unit = 'score';
            }
        }

        return {
            comparator => $comp,
            value      => $val,
            unit       => $unit,
            formatted  => "$comp $val $unit"
        };
    }
    return undef;
}

helper format_hpo_id => sub {
    my ($self, $raw_id) = @_;
    $raw_id =~ s/\D//g;
    $raw_id = 118 unless $raw_id;
    return sprintf("HP:%07d", $raw_id);
};

helper format_icd10_id => sub {
    my ($self, $raw_id) = @_;
    return "ICD10:U99" unless defined $raw_id && length($raw_id);

    $raw_id =~ s/^\s+//;
    $raw_id =~ s/\s+$//;
    $raw_id =~ s/^icd(?:10)?[-:\s]*//i;

    # 1. Trailing .- oder . oder Sonderzeichen entfernen (z. B. "H46.-" -> "H46", "H47.2!" -> "H47.2")
    $raw_id =~ s/[\.\-\!\*\+\s]+$//;

    # 2. Deutsche Zusatzkennzeichen am Ende entfernen (z. B. "H47.2G", "E74.4V", "H46.0A", "H46Z")
    $raw_id =~ s/^([A-Z]\d{2}(?:\.\d{1,2})?)\s*[GVZARL]$/$1/i;

    # 3. Freiburger Alpha-ID Suffixe mit Trennzeichen (z. B. "E74.4.H0" -> "E74.4", "H46.B0" -> "H46", "H46-B0" -> "H46")
    # WICHTIG: Das Suffix MUSS mindestens einen Buchstaben enthalten ([A-Z]), damit reguläre
    # Subcodes wie "H52.1" oder "H18.6" NICHT fälschlich abgeschnitten werden!
    $raw_id =~ s/^([A-Z]\d{2}\.\d{1,2})[-_\.\s]+[A-Z][A-Z0-9]*$/$1/i;
    $raw_id =~ s/^([A-Z]\d{2})[-_\.\s]+[A-Z][A-Z0-9]*$/$1/i;

    # 4. Freiburger Alpha-ID Suffixe direkt angehängt (z. B. "E74.4H0" -> "E74.4", "H46B0" -> "H46")
    $raw_id =~ s/^([A-Z]\d{2}\.\d{1,2})[A-Z][A-Z0-9]+$/$1/i;
    $raw_id =~ s/^([A-Z]\d{2})[A-Z][A-Z0-9]+$/$1/i;

    # 5. Abschließenden Punkt oder Bindestrich bereinigen
    $raw_id =~ s/[\.\-]+$//;

    return "ICD10:" . uc($raw_id);
};

helper format_ops_id => sub {
    my ($self, $raw_id) = @_;
    return "OPS:9-999" unless $raw_id;
    $raw_id =~ s/^\s+//; $raw_id =~ s/\s+$//;
    if ($raw_id =~ /^ops:(.+)$/i) { return "OPS:" . uc($1); }
    if ($raw_id !~ /^ops/i) { return "OPS:" . uc($raw_id); }
    return uc($raw_id);
};

helper format_atc_id => sub {
    my ($self, $raw_id) = @_;
    return "ATC:V03AX" unless $raw_id;
    $raw_id =~ s/^\s+//; $raw_id =~ s/\s+$//;
    $raw_id =~ s/^ATC://i;

    # Entfernt ein fälschlicherweise vorangestelltes 'A',
    # wenn danach wieder ein Buchstabe + 2 Ziffern folgen (z.B. AS01LA05 -> S01LA05)
    if ($raw_id =~ /^A([A-Z]\d{2}.*)$/i) {
        $raw_id = $1;
    }

    return "ATC:" . uc($raw_id);
};

helper format_loinc_id => sub {
    my ($self, $raw_id) = @_;
    return "LOINC:21889-1" unless $raw_id;
    $raw_id =~ s/^\s+//; $raw_id =~ s/\s+$//;
    $raw_id =~ s/^loinc:\s*//i;

    # Lokale Erweiterungscodes tragen ein kleingeschriebenes Suffix
    # (86290-4a, 86290-4b, 86301-9a, 86301-9b). uc() würde daraus "4A"/"4B"
    # machen und den Lookup in loinc_terms brechen.
    if ($raw_id =~ /^(\d+-\d+)([a-zA-Z])$/) {
        return "LOINC:" . $1 . lc($2);
    }

    return "LOINC:" . uc($raw_id);
};

# =========================================================
# SIGNATURE-BASED CHARACTERISTIC DE-DUPLICATION ENGINE
# =========================================================
sub generate_characteristic_signature {
    my ($node) = @_;
    return '' unless ref $node eq 'HASH';

    my $ex   = to_bool($node->{exclude}) ? '1' : '0';
    my $comb = $node->{combinationMethod} // 'all-of';

    # 1. Codeable Concept Nodes (Phenotype, ICD10, OPS, ATC, LOINC)
    if (my $codings = $node->{valueCodeableConcept}{coding}) {
        if (ref $codings eq 'ARRAY' && @$codings) {
            my $c = $codings->[0];
            my $sys  = $c->{system} // '';
            my $code = $c->{code} // '';
            my $disp = lc($c->{display} // '');
            return "codeable|$ex|$comb|$sys|$code|$disp";
        }
    }

    # 2. Quantity & Demographic Constraint Nodes (Age, Sex, Measurements)
    if (my $q = $node->{valueQuantity}) {
        my $c_code = $node->{code}{coding}[0]{code} // '';
        my $comp   = $q->{comparator} // '';
        my $val    = $q->{value} // '';
        my $unit   = lc($q->{unit} // '');
        # Normalisierung für Jahre/Age Signaturen
        $unit = 'a' if $unit eq 'years' || $unit eq 'year';
        return "quantity|$ex|$comb|$c_code|$comp|$val|$unit";
    }

    # 3. Temporal Timeframe Constraint Nodes
    if (my $rel = $node->{relativeTime}) {
        my $c_code = $node->{code}{coding}[0]{code} // 'temporal-constraint';
        if (ref $rel eq 'ARRAY' && @$rel && $rel->[0]{offsetDuration}) {
            my $dur = $rel->[0]{offsetDuration};
            my $comp = $dur->{comparator} // '';
            my $val  = $dur->{value} // '';
            my $unit = lc($dur->{unit} // '');
            return "temporal|$ex|$comb|$c_code|$comp|$val|$unit";
        }
    }

    # 4. Group Subgroups
    if ($node->{resourceType} && $node->{resourceType} eq 'Group' && ref $node->{characteristic} eq 'ARRAY') {
        my @sub_sigs;
        foreach my $sub_char (@{$node->{characteristic}}) {
            my $s = generate_characteristic_signature($sub_char);
            push @sub_sigs, $s if $s;
        }
        return "subgroup|$ex|$comb|" . join('+', sort @sub_sigs);
    }

    # 5. Reference Nodes (#subgroup-X)
    if (my $ref = $node->{valueReference}{reference}) {
        return "reference|$ex|$comb|$ref";
    }

    return '';
}

# =========================================================
# ASYNCHRONOUS DENSE VECTOR QUERY TRANSLATOR & LANGUAGE DETECTOR
# =========================================================
# ---------------------------------------------------------
# GENERISCHER SCHEMA-GEBUNDENER LLM-AUFRUF (vLLM / Ollama)
# ---------------------------------------------------------
helper llm_json_call_async => sub {
    my ($self, $sys_prompt, $user_prompt, $schema, $schema_name, $client_model) = @_;
    my $cfg = resolve_llm_config($client_model);

    my $payload = $cfg->{is_ollama}
        ? {
            model    => $cfg->{model},
            messages => [ { role => 'system', content => $sys_prompt }, { role => 'user', content => $user_prompt } ],
            format   => $schema,
            stream   => Mojo::JSON->false,
            options  => { temperature => 0.0, repeat_penalty => 1.15, repeat_last_n => 512, num_predict => 512 },
          }
        : {
            model           => $cfg->{model},
            messages        => [ { role => 'system', content => $sys_prompt }, { role => 'user', content => $user_prompt } ],
            temperature     => 0.0,
            response_format => { type => 'json_schema', json_schema => { name => $schema_name, strict => \1, schema => $schema } },
          };

    return $ua_fast->post_p($cfg->{endpoint} => $cfg->{headers} => json => $payload)->then(sub {
        my $tx = shift;
        return undef unless $tx->result && $tx->result->is_success;
        my $raw = $cfg->{is_ollama}
            ? ($tx->result->json('/message/content') // '')
            : ($tx->result->json('/choices/0/message/content') // '');
        my $data = clean_and_parse_json($raw);
        return (ref $data eq 'HASH') ? $data : undef;
    })->catch(sub {
        my $err = shift;
        $self->app->log->warn("[LLM JSON CALL FAILED] $schema_name: $err");
        return undef;
    });
};

# =========================================================
# ASYNCHRONOUS DENSE VECTOR QUERY TRANSLATOR (MIT CACHE)
# Rückgabe: Suchbegriff | '__NONE__' (kein kodierbares Konzept) | Fallback
# =========================================================
helper normalize_criterion_for_retrieval_async => sub {
    my ($self, $verbatim_text, $domain, $client_model) = @_;
    my $fallback = clean_term_for_vector_mapping($verbatim_text);

    return Mojo::Promise->resolve($fallback) unless defined $verbatim_text && length($verbatim_text) > 1;

    $domain = lc($domain // 'generic');

    my %domain_target_lang = (
        icd10 => 'GERMAN',
        ops   => 'GERMAN',
        atc   => 'GERMAN',
        hpo   => 'ENGLISH',
        loinc => 'ENGLISH',
    );
    my $target_language = $domain_target_lang{$domain} // 'ENGLISH';

    my $prompt_record = $self->get_llm_prompt('criterion_retrieval_translator');
    unless ($prompt_record && $prompt_record->{system_prompt}) {
        $self->app->log->error("[PROMPT ERROR] Missing active 'criterion_retrieval_translator' in database.");
        return Mojo::Promise->resolve($fallback);
    }

    my $sys_prompt = $prompt_record->{system_prompt};
    $sys_prompt =~ s/\{\{target_language\}\}/$target_language/g;
    $sys_prompt =~ s/\{\{domain\}\}/$domain/g;

    my $user_prompt = $prompt_record->{user_template} // "Domain: {{domain}} | Target Ontology Language: {{target_language}}\nInput Phrase: \"{{verbatim_text}}\"";
    $user_prompt =~ s/\{\{target_language\}\}/$target_language/g;
    $user_prompt =~ s/\{\{domain\}\}/$domain/g;
    $user_prompt =~ s/\{\{verbatim_text\}\}/$verbatim_text/g;

    # Cache-Schlüssel hängt an der Prompt-Version: ändert sich der Prompt,
    # wird neu übersetzt. Kuratierte Einträge (curated = TRUE) gelten immer.
    my $prompt_hash = md5_hex(encode('UTF-8', ($prompt_record->{system_prompt} // '') . "\x{1}" . ($prompt_record->{user_template} // '')));

    if ($translation_cache_on) {
        my $row = eval {
            $self->pg->db->query(q{
                SELECT query FROM public.translation_cache
                 WHERE domain = ? AND target_language = ? AND source_text = ?
                   AND (prompt_hash = ? OR curated)
                 ORDER BY curated DESC LIMIT 1
            }, $domain, $target_language, $verbatim_text, $prompt_hash)->hash;
        };
        if ($row && defined $row->{query} && length $row->{query}) {
            return Mojo::Promise->resolve($row->{query} eq '-' ? '__NONE__' : $row->{query});
        }
    }

    my $translation_schema = {
        type => 'object',
        properties => {
            detected_language => {
                type => 'string',
                enum => ['en', 'de', 'other'],
                description => 'ISO 639-1 language code of the input text.'
            },
            query => {
                type => 'string',
                description => "The most specific concise search query in $target_language, or a single hyphen '-' if the input carries no codable clinical concept."
            }
        },
        required => ['detected_language', 'query'],
        additionalProperties => \0
    };

    return $self->llm_json_call_async($sys_prompt, $user_prompt, $translation_schema, 'query_language_translation', $client_model)->then(sub {
        my $data = shift;
        return $fallback unless ref $data eq 'HASH' && defined $data->{query};

        my $raw_q    = $data->{query};
        my $det_lang = lc($data->{detected_language} // 'unknown');
        $raw_q =~ s/<think>.*?<\/think>//gs;

        # Das "-"-Signal VOR dem Säubern prüfen, sonst wird es zu einem leeren
        # String und der Rohbegriff landet doch in der Vektorsuche.
        (my $probe = $raw_q) =~ s/["'`\s]//g;
        my $clean_query;
        if ($probe =~ /^[-\x{2013}\x{2014}]$/) {
            $clean_query = '-';
        } else {
            $clean_query = $raw_q;
            $clean_query =~ s/^\s*["'\`\:\-\>\#\*\.]+|["'\`\.]+\s*$//g;
            $clean_query =~ s/\s+/ /g;
            $clean_query =~ s/^\s+|\s+$//g;
            return $fallback unless length($clean_query) > 1;
        }

        if ($translation_cache_on) {
            eval {
                $self->pg->db->query(q{
                    INSERT INTO public.translation_cache
                           (domain, target_language, source_text, prompt_hash, query, detected_language)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (domain, target_language, source_text, prompt_hash) DO NOTHING
                }, $domain, $target_language, $verbatim_text, $prompt_hash, $clean_query, $det_lang);
            };
            $self->app->log->warn("[TRANSLATION CACHE WRITE FAILED] $@") if $@;
        }

        $self->app->log->info("[QUERY TRANSLATION] ($domain) Detected: '$det_lang' -> Target: '$target_language' | '$verbatim_text' -> '$clean_query'");
        return $clean_query eq '-' ? '__NONE__' : $clean_query;
    });
};
# =========================================================
# DYNAMIC DATABASE INTERCEPT ENGINE (WITH IN-MEMORY CACHE & UTF-8)
# =========================================================
helper get_domain_intercepts => sub {
    my ($self, $domain) = @_;
    state $cache = {};
    state $last_fetch = {};

    my $now = time;
    # Reload from DB every 30 seconds per domain
    if (!$last_fetch->{$domain} || ($now - $last_fetch->{$domain} > 30)) {
        eval {
            my $rows = $self->pg->db->query(
                "SELECT pattern, code, label, COALESCE(suppress, FALSE) AS suppress
                   FROM public.ontology_intercepts
                  WHERE domain = ? AND active = TRUE
                  ORDER BY priority ASC, id ASC",
                $domain
            )->hashes->to_array;
            # PATCH 2026-09-25: Regeln mit unbekanntem Code nicht verwenden
            $rows = $self->_validate_intercepts($domain, $rows // []);
            $cache->{$domain} = $rows;
            $last_fetch->{$domain} = $now;
        };
        if ($@) {
            $self->app->log->error("[INTERCEPT DB ERROR] Failed to load intercepts for domain '$domain': $@");
        }
    }
    return $cache->{$domain} // [];
};

helper check_database_intercept => sub {
    my ($self, $domain, $text, $context) = @_;
    return undef unless defined $text && length($text);

    my $intercepts = $self->get_domain_intercepts($domain);
    for my $rule (@$intercepts) {
        my $pattern = $rule->{pattern};
        next unless defined $pattern && length($pattern);

        # Safe UTF-8 aware regex evaluation against input text
        local $DIAG_CTX = "intercept $domain " . ($rule->{code} // '-') . " /$pattern/ ON: " . substr($text, 0, 200);
        my $matched = eval { $text =~ qr/$pattern/i };
        if ($@) {
            $self->app->log->warn("[INVALID REGEX IN DB] Domain: '$domain', Pattern: '$pattern' - $@");
            next;
        }
        next unless $matched;

        # Suppress-Regeln verwerfen den Begriff vollständig. Der Aufrufer
        # muss auf { suppress => 1 } prüfen und die Zeile fallen lassen,
        # OHNE auf den Vektor-Retrieval zurückzufallen.
        if ($rule->{suppress}) {
            $self->app->log->info("[INTERCEPT SUPPRESS] Domain '$domain': '$text' durch Regel '$rule->{code}' verworfen.");
            return { suppress => 1, id => undef, label => $rule->{label}, source => 'intercept' };
        }

        my $code = $rule->{code};

        # Auch kuratierte Regeln laufen durch den Scope-Guard. Der Kontext
        # (Verbatim-Text) liefert das Organ, das im kurzen Begriff fehlt:
        # "Schmerzen" + "Oberarm rechts" darf nicht zu Ocular pain werden.
        my $scope_text = (defined $context && length $context) ? "$text $context" : $text;
        if ($domain =~ /^(?:icd10|hpo|ops)$/ && $self->has_scope_conflict($domain, $code, $scope_text)) {
            $self->app->log->warn("[INTERCEPT SCOPE CONFLICT] Domain '$domain': '$text' -> $code widerspricht dem Kontext. Nächste Regel.");
            next;
        }

        # PATCH 2026-09-25: Richtungs-Guard. "Explantation/Entfernung/Bergung" darf nicht
        # auf einen Einführungs- oder Deckungscode fallen.
        if ($domain eq 'ops') {
            state $rm_term = qr/(?:entfern|explant|bergung|ablass|ausschneid|k[üu]rz|fadenzug|\bzug\b|abtrag)/i;
            state $rm_code = qr/(?:entfern|explant|revision|wechsel|l[öo]sung|exzision|destruktion|extraktion|abtragung|keratektomie|kapsulotomie|abrasio)/i;
            my $olabel = $self->get_canonical_ontology_label('ops', $code) // $rule->{label} // '';
            if ($text =~ $rm_term && $olabel !~ $rm_code) {
                $self->app->log->warn("[INTERCEPT DIRECTION CONFLICT] '$text' -> $code ($olabel): Entfernung auf Einführungscode. Nächste Regel.");
                next;
            }
        }

        # Label immer aus der Ontologie, nicht aus der Intercept-Tabelle.
        my $label = $rule->{label};
        if ($domain eq 'hpo' || $domain eq 'icd10') {
            (my $raw = $code // '') =~ s/^(?:HP|ICD10)://i;
            my $db_label = $self->get_canonical_ontology_label($domain, $raw);
            if (defined $db_label && length $db_label) {
                $label = $db_label;
            } else {
                $self->app->log->debug("[INTERCEPT CODE NOT IN ONTOLOGY] $domain $code ('$rule->{label}')");
            }
        }

        return { id => $code, label => $label, source => 'intercept', rule_label => $rule->{label} };
    }
    return undef;
};

# ===========================================
# ASYNCHRONOUS DENSE VECTOR MAPPING HELPERS
# ===========================================

sub enrich_term_with_section_context {
    my ($term, $local_context, $full_report) = @_;
    return '' unless defined $term && length($term);

    my $combined = lc(($local_context // '') . ' ' . $term);

    # ---------------------------------------------------------------------
    # 0. ECHTE ALLGEMEINCHIRURGISCHE & GASTROENTEROLOGISCHE EINGRIFFE SCHÜTZEN
    # (Verhindert, dass reale Darmeingriffe in Augenterme umgewandelt werden)
    # ---------------------------------------------------------------------
    if ($combined =~ /\bh[äa]moclip\b/i) {
        # Verhindert Hämofiltration/Dialyse-Drift und zielt auf endoskopische GI-Blutstillung
        return "Endoskopische Blutstillung Gastrointestinaltrakt Clip";
    }
    if ($combined =~ /\bkapselendoskop\w*\b/i) {
        # Echte Kapselendoskopie des Magen-Darm-Traktes explizit beibehalten
        return "Kapselendoskopie Dünndarm";
    }
    if ($combined =~ /\b(?:hemikolektomie|kolektomie|appendektomie|cholezystektomie|koloskopie|gastroskopie|ileostoma|laparotomie|laparoskopie)\b/i) {
        # Reale Darm- und Abdomeneingriffe unverändert durchlassen
        return $term;
    }

    # ---------------------------------------------------------------------
    # A. VORAB-ERKENNUNG: STAMMT DER BEGRIFF AUS VAA / BINDEHAUT / LID / WUNDE?
    # ---------------------------------------------------------------------
    my $is_vaa = 0;
    my $vaa_sections = qr/(?:vaa|vorderabschnitt|spaltlampe|hornhaut|cornea|bindehaut|conjunctiv\w*|lid|unterlid|oberlid|kanthus|tarsus|orbicularis|skler\w*|vorderkammer|wund\w*|naht|f[äa]den)/i;

    if ($combined =~ /\b$vaa_sections\b/i) {
        $is_vaa = 1;
    } elsif (defined $full_report && length($full_report)) {
        my $target = (defined $local_context && length($local_context) > 2) ? quotemeta($local_context) : quotemeta($term);
        if ($full_report =~ /(?:vaa|vorderabschnitt|spaltlampe|bindehaut|conjunctiv|lid|hornhaut|cornea)[^\n\r]*$target/i) {
            $is_vaa = 1;
        }
    }

    # ---------------------------------------------------------------------
    # B. VORAB-ERKENNUNG: STAMMT DER BEGRIFF AUS NETZHAUT / MAKULA / OCT / FAG?
    # ---------------------------------------------------------------------
    my $is_retina = 0;
    my $retina_sections = qr/(?:nh[- ]?oct|oct|fundus|makula|macula|retina|netzhaut|fovea|fag|fla|angio)/i;
    my $retina_context_words = qr/(?:fag|cotton[\s-]wool|fleckblutung\w*|uhr\b|netzhaut|retina|gef[äa][ßs]anomalie|drusen)/i;

    # Schutz: Wenn aus VAA/Lid, nicht zur Netzhaut machen, außer explizit genannt
    if (!$is_vaa || $combined =~ /\b(?:fundus|retina|netzhaut|makula|macula|fovea|oct|fag)\b/i) {
        if ($combined =~ /\b(?:nh[- ]?oct|oct|fundus|makula|macula|retina|netzhaut|fovea|fag|fla|angiograph\w*|pe[- ]?verklumpung|cotton[\s-]wool|fleckblutung\w*|pr[äa]retinal\w*|subretinal\w*|intraretinal\w*)\b/i) {
            $is_retina = 1;
        }
        elsif (defined $full_report && length($full_report)) {
            my $quoted = quotemeta($term);

            if ($full_report =~ /$retina_sections[^\n\r]*$quoted/i
                || $full_report =~ /[^.\n\r]*$retina_context_words[^.\n\r]*$quoted/i
                || $full_report =~ /$quoted[^.\n\r]*$retina_context_words/i) {
                $is_retina = 1;
            }
            else {
                my @test_words = grep { length($_) >= 4 && $_ !~ /^(?:kein|ohne|links|rechts|auge|grad|beidseits)$/i } split(/[^\p{L}\p{N}]+/, lc($local_context // ''));
                for my $w (@test_words) {
                    my $qw = quotemeta($w);
                    if ($full_report =~ /$retina_sections[^\n\r]*$qw/i
                        || $full_report =~ /[^.\n\r]*$retina_context_words[^.\n\r]*$qw/i
                        || $full_report =~ /$qw[^.\n\r]*$retina_context_words/i) {
                        $is_retina = 1;
                        last;
                    }
                }
            }
        }

        # Ophthalmo-Sicherheitsnetz für Neovaskularisationen
        if ($term =~ /\b(?:neovaskularisation|neovascularization|neovask)\b/i && $combined !~ /\b(?:cornea|hornhaut|limbus|pannus)\b/i) {
            $is_retina = 1;
        }
    }

    # Übergreifender Indikator für okulären Kontext:
    my $is_eye_context = ($is_vaa || $is_retina || $combined =~ /\b(?:auge|augen|bulbus|ra\b|la\b|od\b|os\b|ba\b|ou\b|ocul\w*|opht\w*|cataract|grauer\s+star|gr[üu]ner\s+star|glaukom)\b/i);

    # ---------------------------------------------------------------------
    # OKULÄRE NARBENLÖSUNG / ADHÄSIOLYSE (SCHUTZ VOR NARBENHERNIE 5-536)
    # ---------------------------------------------------------------------
    if ($term =~ /\b(?:narbenl[öo]sung\w*|l[öo]sung\s+von\s+narben|adh[äa]siolys\w*|strangl[öo]sung\w*|symblepharo(?:lyse|l[öo]sung)\w*)\b/i
            || $combined =~ /\b(?:narbenl[öo]sung\w*|symblepharonl[öo]sung\w*|symblepharolyse\w*)\b/i) {
        # 1. Bindehaut / Symblepharon (Fornix, Bindehaut, Bulbus)
        if ($combined =~ /\b(?:bindehaut|konjunktiv\w*|symblepharon|fornix|bulbus)\b/i) {
            return "Lösung von Adhäsionen der Konjunktiva Symblepharon"; # Zielt auf OPS:5-115.1
        }

        # 2. Augenlid / Kanthus (Lidnarben, Ektropium)
        if ($combined =~ /\b(?:lid|unterlid|oberlid|kanthus|tarsus|ektropi\w*|entropi\w*)\b/i) {
            return "Lösung von Verwachsungen der Augenlider";            # Zielt auf OPS:5-096.1
        }

        # 3. Iris / Vorderkammer (Synechien)
        if ($combined =~ /\b(?:iris|synechi\w*|vorderkammer|pupill\w*)\b/i) {
            return ($combined =~ /\bhintere\b/i)
                ? "Lösung hinterer Synechien"                            # Zielt auf OPS:5-137.1
                : "Lösung vorderer Synechien";                           # Zielt auf OPS:5-137.0
        }

        # 4. Standard-Fallback für Augenberichte (Bindehaut-Symblepharon ist am häufigsten)
        return "Lösung von Adhäsionen der Konjunktiva Symblepharon";     # OPS:5-115.1
    }
    # ---------------------------------------------------------------------
    # OKULÄRE HERPES- UND ZOSTER-INFEKTIONEN (SCHUTZ VOR GENITALHERPES A60)
    # ---------------------------------------------------------------------
    if ($term =~ /\b(?:herpes|herpetisch\w*|hsv|zoster)\b/i || $combined =~ /\b(?:herpes|herpetisch\w*)\b/i) {
        
        # 1. Zoster ophthalmicus (Gürtelrose am Auge)
        if ($term =~ /\bzoster\b/i || $combined =~ /\bzoster\b/i) {
            return "herpes zoster ophthalmicus"; # Mappt auf ICD10:B02.3 / HP:0032087
        }

        # 2. Hornhaut-Beteiligung (Keratitis herpetica / herpetisches Ulkus / Dendritica)
        if ($combined =~ /\b(?:hornhaut|cornea|ulkus|ulcus|keratit\w*|stroma|endothel|dendrit\w*|wund\w*)\b/i
            || $term =~ /\b(?:hornhaut|cornea|ulkus|ulcus|keratit\w*|dendrit\w*)\b/i) {
            return "herpetic keratitis";         # Mappt auf ICD10:B00.5 / HP:0012114
        }

        # 3. Uveitis / Netzhaut-Beteiligung (z. B. ARN - Akute Retinanekrose)
        if ($is_retina || $combined =~ /\b(?:retin\w*|netzhaut|uveit\w*|nekros\w*|arn)\b/i) {
            return "herpetic retinitis";         # Mappt auf ICD10:B00.5
        }

        # 4. Allgemeines Herpesrezidiv / Herpes am Auge (Standard-Fallback)
        return "ocular herpes simplex";          # Mappt auf ICD10:B00.5 / HP:0012114
    }

    # ---------------------------------------------------------------------
    # C. ANATOMISCHE SCHUTZANKER & DESAMBIGUIERUNG (CROSS-ORGAN DRIFT STOPPEN)
    # ---------------------------------------------------------------------
    # 1. Aderhaut (Auge) vs. Plexus choroideus (Gehirn)
    if ($term =~ /\bchoroid\w*\b/i && $term !~ /\bplexus\b/i) {
        $term =~ s/\bchoroid\w*\s+vessels\b/ocular choroidal vasculature/gi;
        $term =~ s/\bchoroid\w*\b/ocular choroid/gi;
    }

    # 2. Raumorientierung im Auge (Nasal/Temporal) -> Schützt vor "Nose" und "Temporal lobe"
    if ($term =~ /\b(?:nasal|nasale|nasaler|nasales)\b/i) {
        if ($is_retina || $combined =~ /\b(?:rnfl|oct|retina|fundus|papille|gesichtsfeld|gf|sehnerv)\b/i) {
            $term =~ s/\bnasal\b/ocular fundus nasal sector/gi;
        } elsif ($is_vaa || $combined =~ /\b(?:hornhaut|cornea|tr[äa]nen|limbus)\b/i) {
            $term =~ s/\bnasal\b/medial ocular/gi;
        }
    }
    if ($term =~ /\b(?:temporal|temporale|temporaler|temporales)\b/i) {
        if ($is_retina || $combined =~ /\b(?:rnfl|oct|retina|fundus|papille|gesichtsfeld|gf|sehnerv)\b/i) {
            $term =~ s/\btemporal\b/ocular fundus temporal sector/gi;
        }
    }

    # 3. Amnionmembran am Auge vs. Fruchtblase (Geburtshilfe)
    if (($term =~ /\bamnion\w*\b/i || $combined =~ /\bamnion\w*\b/i) && $is_eye_context) {
        return "corneal graft defect"; # Schützt vor vorzeitigem Blasensprung
    }

    # 4. Hornhautnaht/Fadenkanal vs. Spinalkanal
    if ($term =~ /\bfadenkanal\w*\b/i) {
        return "corneal suture track complication";
    }

    # 5. Lid-Talgdrüse vs. Speicheldrüse
    if ($term =~ /\b(?:talgretention\w*|talgzyste)\b/i && ($is_vaa || $combined =~ /\b(?:lid|unterlid|oberlid|auge)\b/i)) {
        return "eyelid sebaceous cyst";
    }

    # 6. Hornhautulkus vs. Magengeschwür
    if ($term =~ /^(?:ulcus|ulkus|ulcer)$/i && $is_eye_context) {
        return "corneal ulcer";
    }

    # 7. Synechien: Anterior vs. Posterior strikt trennen
    if ($term =~ /\b(?:vordere|anteriore)\s+synechie\w*\b/i) {
        return "anterior synechiae of the iris";
    }
    if ($term =~ /\b(?:hintere|posteriore)\s+synechie\w*\b/i) {
        return "posterior synechiae of the iris";
    }

    # 8. Pupillenweite: Miosis vs. Mydriasis
    if ($term =~ /\b(?:pupilleneng\w*|pupillenverengung\w*|mios[ei]s|eng(?:e|gestellte)?\s+pupille\w*)/i
        && $term !~ /\bmydria/i) {
        return "miosis";
    }
    if ($term =~ /\b(?:pupillenweit\w*|pupillenerweiterung\w*|mydriasis|weite\s+pupille\w*)/i) {
        return "mydriasis";
    }

    # 9. IOL am Ort / Pseudophakie (schützt vor Retinal Tubulation!)
    if ($term =~ /\b(?:iol\s+(?:am\s+ort|in\s+loco|im\s+ort|regelrecht)|pseudophakie)\b/i) {
        return "pseudophakia";
    }

    # 10. Subjektive Augensymptome (schützt vor Trichotillomanie und Rundrücken)
    if ($term =~ /\bziehen\b/i && $is_eye_context) {
        return "ocular discomfort";
    }
    if ($term =~ /\bstichgef[üu]hl\b/i && $is_eye_context) {
        return "eye pain";
    }

    # 11. MEHRDEUTIGE OPERATIONEN/EINGRIFFE NUR IM AUGEN-KONTEXT PRÄZISIEREN
    if ($is_eye_context) {
        if ($term =~ /\bkapsel[öo]ffnung\b/i || $term =~ /\bkapsulotom\w*\b/i) {
            return "Kapsulotomie der Augenlinse";
        }
        if ($term =~ /\b(?:intrakameral\w*|luftinjektion|re-bubbling|bubbling)\b/i) {
            return "Lufteingabe in die vordere Augenkammer";
        }
        if ($term =~ /\bdebridement\b/i && ($is_vaa || $combined =~ /\b(?:bindehaut|hornhaut|cornea|conjunctiv\w*)\b/i)) {
            return "Exzision von erkranktem Gewebe der Bindehaut";
        }
        if ($term =~ /\b(?:linsenentfernung|linsenabsaugung|aphakiebelassung)\b/i) {
            return "Extrakapsuläre Extraktion der Linse";
        }
        if ($term =~ /\bdiaphanoskop\w*\b/i) {
            return "Diaphanoskopie des Augapfels";
        }
        if ($term =~ /\bprothese\b/i && $combined !~ /\b(?:zahn|knie|h[üu]fte|bein|arm)\b/i) {
            return "Implantation einer Augenprothese";
        }
    }

    if ($is_retina && $term =~ /\b(?:kristallin\w*|crystalline)\b/i) {
        return "retinal refractile deposits";
    }
    if ($is_vaa && $term =~ /\b(?:kristallin\w*|crystalline)\b/i) {
        return "crystalline cataract"; # zielt auf HP:0000518
    }

    # ---------------------------------------------------------------------
    # 1. AUSWERTUNG: VORDERABSCHNITT / BINDEHAUT / LID / WUNDE (VAA)
    # ---------------------------------------------------------------------
    if ($is_vaa) {
        # -------------------------------------------------------------
        #  ÜBEREFFEKT (PTOSIS, EKTROPIUM, ENTROPIUM)
        # -------------------------------------------------------------
        if ($term =~ /\b[üu]bereffekt\b/i || $combined =~ /\b[üu]bereffekt\b/i) {
            # 1. Entropium-Kontext: Überkorrektur klappt das Lid nach außen -> Ektropium
            if ($combined =~ /\bentropi\w*\b/i
                || (defined $full_report && $full_report =~ /\bentropi\w*\b/i && $full_report !~ /\be[kx]tropi\w*\b/i)) {
                return "ectropion";
            }

            # 2. Ektropium-Kontext: Überkorrektur rollt das Lid nach innen -> Entropium
            if ($combined =~ /\be[kx]tropi\w*\b/i
                || (defined $full_report && $full_report =~ /\be[kx]tropi\w*\b/i && $full_report !~ /\bentropi\w*\b/i)) {
                return "entropion";
            }

            # 3. Ptosis- / Blepharoplastik- / Standard-Lid-Kontext: Überkorrektur überhebt das Lid -> Lidretraktion
            if ($combined =~ /\b(?:ptosis|blepharo\w*|levator\w*|oberlid|lid\w*)\b/i
                || (defined $full_report && $full_report =~ /\b(?:ptosis|blepharo\w*|levator\w*)\b/i)) {
                return "eyelid retraction";
            }

            # Fallback für Lid-VAA:
            return "eyelid retraction";
        }

        # Wundsekretion / Wundaustritt am Lid (schützt vor "Retinal exudate")
        if ($term =~ /\b(?:wundsekret\w*|sekret\w*|austritt|wundaustritt)\b/i) {
            return "eye discharge"; # Mappt deterministisch auf HP:0034427
        }

        # Schwellung / Ödem am Lid / Periorbital
        if ($term =~ /\b(?:lidschwellung|lid[öo]dem|periorbital\w*\s+schwellung)\b/i) {
            return "eyelid edema"; # Mappt auf HP:0100540
        }

        # Rötung am Lid / Periorbital
        if ($term =~ /\b(?:periorbital\w*\s+r[öo]tung|lidr[öo]tung|hautr[öo]tung)\b/i) {
            return "eyelid erythema"; # Mappt auf HP:0040323
        }

        # Krustenbildung / Wundverkrustung
        if ($term =~ /\b(?:kruste\w*|verkrust\w*)\b/i) {
            return "crusted cutaneous lesion"; # Mappt auf HP:0025550
        }

        # Blutungen im VAA / Lidbereich (schützt vor "Retinal hemorrhage")
        if ($term =~ /\b(?:temporal\w*\s+)?(?:h[äa]morrhag\w*|blutung\w*|hemorrhage|bleeding)\b/i) {
            if ($combined =~ /\b(?:lid|unterlid|oberlid|haut|subkutis|wunde)\b/i) {
                return "eyelid hematoma";
            }
            return "subconjunctival hemorrhage";
        }

        # Hornhautnarbe / Fremdkörpernarbe (schützt vor H31.0 Netzhautnarbe)
        if ($term =~ /\bfremdk(?:[öo]|oe|\?)rper[\s\-]*(?:narbe\w*|scar\w*)?\b/i
            || $combined =~ /\bfremdk(?:[öo]|oe|\?)rper[\s\-]*(?:narbe\w*|scar\w*)\b/i) {
            return "corneal foreign body scar";
        }
        if ($term =~ /\b(?:parazentrale\s+|zentrale\s+|alte\s+)?narbe\b/i && $term !~ /\b(?:retina|makula|aderhaut)\b/i) {
            return "corneal scar";
        }
        if ($term =~ /^(?:alte\s+|parazentrale\s+|zentrale\s+)?narbe$/i || $term =~ /^(?:corneal\s+scar|scar)$/i) {
            return "Hornhautnarbe"; # ICD-10 H17.9
        }
        if ($term =~ /\b(?:postentz[üu]ndliche?\s+)?fibros\w*\b/i || $term =~ /\bpost[\s-]*inflammatory\s*fibrosis\b/i) {
            return "corneal scar"; # HP:0000559 und ICD-10 H17.9
        }

        # Infiltrat im Hornhautbereich
        if ($term =~ /\binfiltrat\w*\b/i) {
            return "corneal infiltrate";
        }

        # Pigmentierungen im Lid-/VAA-Bereich schützen
        if ($term =~ /\b(?:lidpigment\w*|pigmentierung\s*am\s*unterlid)\b/i) {
            return "eyelid hyperpigmentation";
        }

        # Hornhautperforation
        if ($term =~ /\bdurchgreifend\w*\s*defekt\w*\b/i) {
            return "Corneal perforation"; # HP:0000558
        }

        # Fadengranulom
        if ($term =~ /\bfadengranulom\w*\b/i || $term =~ /\bsuture\s*granuloma\b/i) {
            if ($combined =~ /\b(?:hornhaut|cornea|transplantat)\b/i) {
                return "corneal suture granuloma";      # ICD-10 H18.8
            } elsif ($combined =~ /\b(?:lid|unterlid|oberlid)\b/i) {
                return "eyelid suture granuloma";       # ICD-10 H02.8
            } else {
                return "conjunctival suture granuloma"; # ICD-10 H11.8
            }
        }

        # Hornhaut-Transplantat Dehiszenz
        if ($term =~ /\b(?:dehiszenz|dehiscence|abhebung|teilabhebung|stufenbildung)\b/i) {
            return "corneal graft detachment";
        }

        # Keratitis superficialis punctata
        if ($term =~ /\b(?:unruhig\w*\s+hornhaut|unruhiges?\s+epithel|epithel\s+unruhig)\b/i) {
            return "superficial punctate keratitis"; # HP:0011859
        }

        # Hornhautfäden
        if ($term =~ /\b(?:hornhaut[- ]?f[äa]den|corneal\s+sutures?)\b/i || $combined =~ /\b(?:hornhaut[- ]?f[äa]den|corneal\s+sutures?)\b/i) {
            return "History of ocular surgery"; # HP:6001448
        }
        if ($combined =~ /\b(?:rectus|obliquus|augenmuskel|musculus|m\.\s*rectus)\b/i) {
            if ($term =~ /\b(?:verdickung|hypertrophi\w*|schwellung|ödem)\b/i) {
                return "extraocular muscle hypertrophy";
            }
        }

        if ($term =~ /\b(?:zirkulierende\s+)?zellen\b/i && $combined !~ /glask[öo]rper/i) {
            return "anterior chamber cells";
        }

        if ($term =~ /\b(?:rosthof\w*|rostring\w*|rostablagerung\w*|eisenrost\w*)\b/i
            || $combined =~ /\b(?:rosthof\w*|rostring\w*)\b/i) {
            return "corneal rust ring";
        }

        # Pigmentierter Bereich / Pigmentierung im Vorderabschnitt
        if ($term =~ /\b(?:pigmentiert\w*|hyperpigmentiert\w*|pigment\w*)\s*(?:bereich\w*|areal\w*|ver[äa]nderung\w*|fleck\w*|herd\w*|l[äa]sion\w*|zone\w*|stelle\w*)\b/i
            || $term =~ /\b(?:pigmentierung\w*|hyperpigmentierung\w*)\b/i) {
            
            # Iris
            if ($combined =~ /\b(?:iris|regenbogenhaut|stroma|pupill\w*)\b/i) {
                return "hyperpigmentation of the iris";
            }
            # Bindehaut
            if ($combined =~ /\b(?:bindehaut|konjunktiv\w*|limbus|skler\w*)\b/i) {
                return "conjunctival hyperpigmentation";
            }
            # Hornhaut / Endothel (z.B. pigmentierte Beschläge)
            if ($combined =~ /\b(?:endothel\w*|hornhaut|cornea|beschl[äa]g\w*)\b/i) {
                return "pigmented keratic precipitates";
            }
            # Lid
            if ($combined =~ /\b(?:lid|unterlid|oberlid|lidrand)\b/i) {
                return "eyelid hyperpigmentation";
            }
        }
    }

    # ---------------------------------------------------------------------
    # 2. AUSWERTUNG: NETZHAUT / MAKULA / OCT / FAG (RETINA)
    # ---------------------------------------------------------------------
    if ($is_retina) {
        # Makulaödem darf niemals durch erwähnte Gliose überschrieben werden
        if ($term =~ /\bmakula[öo]dem\b/i || $local_context =~ /^makula[öo]dem/i) {
            if ($term =~ /\btraktiv\b/i || $combined =~ /\btraktiv\b/i) {
                return "tractional macular edema";
            }
            return "macular edema";
        }
        # Gliose
        if ($combined =~ /\b(?:glios\w*|glial\s*scarring)\b/i) {
            if ($combined =~ /\b(?:traktion|traction|epiretinal|pucker|makula|macula|fovea)\b/i) {
                return "epiretinal membrane";
            }
            return "retinal gliosis";
        }

        # CNV
        if ($combined =~ /\b(?:cnv|chorioid\w*\s+neovask\w*|choroidal\s+neovasc\w*)\b/i) {
            return "choroidal neovascularization";
        }

        # Infiltrat
        if ($term =~ /\binfiltrat\w*\b/i) {
            if ($combined =~ /\b(?:hornhaut|cornea|transplantat|graft|pkp|kerat\w*|vaa|spaltlampe|stroma|endothel|epithel)\b/i
                || $term =~ /\b(?:hornhaut|cornea|transplantat)\b/i) {
                return "corneal infiltrate";
            }
            return "retinal infiltrate";
        }

        # Retinale Neovaskularisation
        if ($combined =~ /\b(?:retinale\s+neovask\w*|retinal\s+neovasc\w*|rnv)\b/i) {
            return "retinal neovascularization";
        }
        if ($term =~ /\b(?:neovaskularisation|neovascularization|neovask)\b/i && $term !~ /\bcornea\b/i) {
            return "retinal neovascularization";
        }
        if ($term =~ /\bproliferation\w*\b/i && $term !~ /\b(?:retin\w*|neovask|sea[\s-]*fan)\b/i) {
            return "retinal neovascularization";
        }

        # Narben (inkl. Narbenbildung)
        if ($term =~ /\b(?:zentrale\s+|alte\s+|pigmentierte\s+)?narb\w*\b/i && $combined !~ /\b(?:cornea|hornhaut|lid|bindehaut)\b/i) {
            return "chorioretinal macular scar";
        }
        if ($term =~ /^(?:scar|retinal\s+scar)$/i) {
            return "chorioretinale Narbe";
        }
        if ($term =~ /\b(?:postentz[üu]ndliche?\s+)?fibros\w*\b/i || $term =~ /\bpost[\s-]*inflammatory\s*fibrosis\b/i) {
            return "chorioretinal scar";
        }

        # Flüssigkeit & Ödem
        if ($term =~ /\b(?:subretinal\w*\s+fl[üu]ssigkeit|subretinal\s+fluid|srf)\b/i) {
            return "subretinal fluid";
        }
        if ($term =~ /\b(?:intraretinale\s+fl[üu]ssigkeit|fl[üu]ssigkeit|ödem)\b/i && $term !~ /\bcornea\b/i && $term !~ /\bsubretin/i) {
            return "retinal edema intraretinal fluid";
        }

        # Exsudate
        if ($term =~ /\b(?:effusion|exsudat\w*|exudat\w*)\b/i) {
            if ($combined =~ /\b(?:makula|macula|fovea|zentrum)\b/i) {
                return "macular exudate";
            }
            return "retinal exudate";
        }
        if ($term =~ /\b(?:kristallin\w*|crystalline)\b/i) {
            return "retinal refractile deposits";
        }

        # Papillenrandblutung
        if ($term =~ /\b(?:papillenrand|papillen|dis[ck]|optic\s*disc)\w*\s*(?:rand)?blutung\b/i
            || $combined =~ /\b(?:papillenrand|optic\s*disc\s*margin)\s*blutung\b/i) {
            return "optic disc hemorrhage";
        }

        # Blutungen im Netzhaut/Glaskörperbereich
        if ($term =~ /\b(?:glask[öo]rper|gk|vitre\w*)\s*blutung\b|\bvitreous\s+(?:hemorrhage|bleeding)\b/i) {
            return "vitreous hemorrhage";
        }
        if ($term =~ /\b(?:netzhaut|retina|fundus)\w*\s*blutung\b|\bretinal\s+(?:hemorrhage|bleeding)\b/i
            || ($term =~ /\b(?:blutung(?:en)?|bleeding|hemorrhage)\b/i && $term !~ /\bnachblutung\b/i)) {
            return "retinal hemorrhage";
        }

        # Mikroaneurysmen & RPE-Veränderungen
        if ($term =~ /\bmikroaneurysm\w*\b/i) {
            return "retinal microaneurysm";
        }
        if ($term =~ /\bauflockerung\b/i) {
            return "retinal pigment epithelium alteration";
        }

        # Atrophiekonus (Peripapilläre Atrophie)
        if ($term =~ /\batrophiekonus\b/i) {
            return "chorioretinal atrophy concentrated around the optic papilla";
        }

        # Chorioretinale Atrophie
        if ($term =~ /\b(?:temporal\w*|nasal\w*|periphere?|generalisierte?|diffuse?|generalized|diffuse)\s+(?:retinal\s+)?atroph\w*/i
            || $term =~ /\batrophieareal\w*\b/i
            || $term =~ /^(?:atrophie|atrophy)$/i) {
            return "chorioretinal atrophy";
        }

        # Foramen / Defekt
        if ($term =~ /\bdurchgreifend\w*\s*(?:defekt\w*|foramen)?\b/i || $combined =~ /\bfull[- ]?thickness\b/i) {
            if ($combined =~ /\b(?:peripher\w*|äquator\w*|foramen)\b/i && $combined !~ /\b(?:makula|fovea)\b/i) {
                return "Retinal hole";
            }
            return "Macular hole";
        }

        # Gefäßverschluss
        if ($term =~ /\b(?:gef[äa][ßs]verschluss|vascular\s*occlusion|verschluss)\b/i && $term !~ /\b(?:retin\w*|netzhaut|ast|zentral)\b/i) {
            return "retinal vascular occlusion";
        }

        if ($is_retina && $term =~ /\bnekros\w*\b/i) {
            return "retinal necrosis";
        }
        # Pigmentierter Bereich / Pigmentierung / RPE-Veränderungen in der Netzhaut
        if ($term =~ /\b(?:pigmentiert\w*|hyperpigmentiert\w*|pigment\w*)\s*(?:bereich\w*|areal\w*|ver[äa]nderung\w*|fleck\w*|herd\w*|l[äa]sion\w*|zone\w*|stelle\w*|rundherd\w*)\b/i
            || $term =~ /\b(?:pigmentierung\w*|pigmentverschiebung\w*|pigmentauflockerung\w*|hyperpigmentierung\w*)\b/i) {
            
            # Nävus-Kontext (flach, solitär, scharf begrenzt)
            if ($combined =~ /\b(?:n[äa]vus|nevus|flach|solit[äa]r|gutartig|prominenzfrei)\b/i) {
                return "choroidal nevus";
            }
            # Makula-Kontext
            if ($combined =~ /\b(?:makula|macula|fovea|zentrum|zentral)\b/i) {
                return "abnormal macular pigmentation";
            }
            # Allgemeine Netzhaut / Fundus
            return "abnormal retinal pigmentation";
        }
    }

    # ---------------------------------------------------------------------
    # 3. AUSWERTUNG: NÄVUS (LOKALISATIONSSPEZIFISCH)
    # ---------------------------------------------------------------------
    my $is_nevus = ($combined =~ /\b(?:n[äa]vus|nevi|nevus)\b/i) ? 1 : 0;

    if ($is_nevus) {
        if ($is_retina || $combined =~ /\b(?:mittelperipher|papillennah|hinterpol|peripher|fundus|retina|aderhaut|choroid)\b/i) {
            return "choroidal nevus";
        }
        if ($is_vaa) {
            if ($combined =~ /\b(?:iris|regenbogenhaut|pupill\w*|stroma)\b/i) {
                return "iris nevus";
            }
            if ($combined =~ /\b(?:lid|unterlid|oberlid|lidrand|lidkante|kanthus)\b/i) {
                return "eyelid melanocytic nevus";
            }
            if ($combined =~ /\b(?:bindehaut|konjunktiv\w*|limbus|skler\w*)\b/i) {
                return "conjunctival nevus";
            }
        }
    }

    # ---------------------------------------------------------------------
    # 4. AUSWERTUNG: VERKLEBUNGEN / SYNECHIEN
    # ---------------------------------------------------------------------
    if ($term =~ /\bverkleb\w*\b/i || $combined =~ /\bverkleb\w*\b/i) {
        if ($combined =~ /\b(?:iris|pupill\w*|hintere|vordere|linse|kapsel)\b/i) {
            return "iris synechiae";
        } elsif ($combined =~ /\b(?:symblepharon|fornix|bulbusbindehaut|tarsal)\b/i) {
            return "symblepharon";
        } else {
            return "eyelid crusting";
        }
    }

    # ---------------------------------------------------------------------
    # 5. AUSWERTUNG: GESICHTSFELD / PERIMETRIE
    # ---------------------------------------------------------------------
    if ($combined =~ /\b(?:gf\b|perimetr\w*|gesichtsfeld|bjerrum|octopus|humphrey)\b/i) {
        if ($term =~ /\b(?:nasal|inferior|superior|temporal|bogenskotom|skotom|ausfall|sensibilit[äa]tsminderung)\b/i) {
            if ($term =~ /\b(?:bjerrum|bogen)\b/i) {
                return "arcuate scotoma";
            }
            if ($term =~ /\bnasal\b/i) {
                return "nasal step visual field defect"; # HP:0012513
            }
            if ($term =~ /\bsensibilit[äa]tsminderung\b/i) {
                return "visual field loss";
            }
            if ($term =~ /\bperipher\w*\s*defekt\w*\b/i) {
                return "peripheral visual field loss";
            }
            return "visual field defect";
        }
    }
    if ($combined =~ /\b(?:gf\b|perimetr\w*|gesichtsfeld|octopus|humphrey)\b/i) {
        # Wenn im Gesamtbericht oder Kriterium Dermatochalasis / Ptosis vorherrscht und "oben" steht:
        if ($term =~ /\b(?:oben|superior)\b/i && ($combined =~ /\b(?:dermatochalasis|ptosis|oberlid)\b/i || (defined $full_report && $full_report =~ /dermatochalasis/i))) {
            return "constriction of peripheral visual field"; # Zielt auf HP:0030528 / HP:0001123 ab
        }
        if ($term =~ /\b(?:bjerrum|bogen)\b/i) {
            return "arcuate scotoma";
        }
        if ($term =~ /\bnasal\b/i) {
            return "nasal step visual field defect";
        }
        return "visual field defect"; # Fallback auf HP:0001123
    }
    # ---------------------------------------------------------------------
    # 6. AUSWERTUNG: OCT-SEKTOREN (T, TI, TS, N, NS, NI)
    # ---------------------------------------------------------------------
    if ($combined =~ /\b(?:oct|bmo|rnfl|gcl|ganglien\w*)\b/i) {
        if ($term =~ /\b(?:t|ti|ts|ns|ni|n)[\s\-_]?grenzwertig\b/i) {
            return "borderline retinal nerve fiber layer";
        }
        if ($term =~ /\b(?:t|ti|ts|ns|ni|n)[\s\-_]?verd[üu]nnt\b/i || $term =~ /\b(?:temporal|superior|inferior|nasal)verd[üu]nnung\b/i) {
            return "retinal thinning on OCT";
        }
    }

    return $term;
}
helper map_to_hpo_async => sub {
    my ($self, $term, $is_modifier, $doc_lang, $opts) = @_;
    $opts //= {};
    return Mojo::Promise->resolve(undef) unless defined $term && length($term);
    return Mojo::Promise->resolve(undef) if $term =~ /unknown/i;

    # 1. Check auf Originalbegriff
    if (my $hit = $self->check_database_intercept('hpo', $term, $opts->{context})) {
        return Mojo::Promise->resolve(undef) if $hit->{suppress};
        $self->app->log->info("[HPO DB INTERCEPT] '$term' -> $hit->{id} ($hit->{label})");
        return Mojo::Promise->resolve($hit);
    }

    $doc_lang = lc($doc_lang // 'de');

    my $p_query = ($doc_lang eq 'en')
        ? Mojo::Promise->resolve(clean_term_for_vector_mapping($term))
        : $self->normalize_criterion_for_retrieval_async($term, 'hpo');

    return $p_query->then(sub {
        my $clean_query = shift;
        if (!defined $clean_query || $clean_query eq '__NONE__') {
            $self->app->log->info("[HPO NO CONCEPT] '$term' enthält kein kodierbares Konzept.");
            return undef;
        }

        # 2. Check auf übersetzten / bereinigten Suchbegriff
        if (my $hit = $self->check_database_intercept('hpo', $clean_query, $opts->{context})) {
            return undef if $hit->{suppress};
            $self->app->log->info("[HPO DB INTERCEPT] '$clean_query' -> $hit->{id} ($hit->{label})");
            return $hit;
        }

        my $execute_call = sub {
            my $prompt_id = $is_modifier ? LLM_HPO_MODIFIER_RETRIEVAL_PROMPT_ID : LLM_HPO_RETRIEVAL_PROMPT_ID;
            my $url_retrieve = "$patchbay_url/LLM/run_stateless/" . $prompt_id;
            return $ua_fast->post_p(
                $url_retrieve => { 'Content-Type' => 'text/plain; charset=UTF-8', Accept => '*/*' } => encode('UTF-8', $clean_query)
            )->then(sub { return _decode_matches(shift) })
             ->catch(sub { my $e = shift; $self->app->log->warn("[HPO RETRIEVAL ERROR] '$clean_query': $e"); return []; });
        };

        # Reranking erst NACH der Patchbay-Queue, damit der Queue-Slot nicht
        # während des LLM-Aufrufs blockiert.
        return $self->enqueue_patchbay_call($execute_call, $clean_query)->then(sub {
            my $matches = shift;
            return $self->_select_vector_hit_async('hpo', $matches, $clean_query, $opts);
        })->catch(sub { return undef; });
    });
};

# =========================================================================
# VEKTOR-DISTANZ & SIMILARITY EXTRAKTOR (KOMPATIBEL MIT PATCHBAY 'similarity')
# =========================================================================
sub _extract_vector_dist_str {
    my ($match_obj) = @_;
    return "" unless ref $match_obj eq 'HASH';

    my $sim = $match_obj->{similarity} // $match_obj->{sim};
    my $dist = defined $sim
        ? (1.0 - $sim)
        : ($match_obj->{distance} // $match_obj->{dist} // $match_obj->{_distance} // $match_obj->{score});

    if (defined $dist && defined $sim) {
        return sprintf(" [dist: %.4f | sim: %.4f]", $dist + 0, $sim + 0);
    } elsif (defined $dist) {
        return sprintf(" [dist: %.4f]", $dist + 0);
    } elsif (defined $sim) {
        return sprintf(" [sim: %.4f]", $sim + 0);
    }
    return "";
}

# Okuläre Stämme OHNE abschließende Wortgrenze, damit deutsche Komposita
# ("Narbenentropiumoperation", "Oberlidentropium", "Pupillenengheit") matchen.
# Kurze oder mehrdeutige Stämme sind mit Wortgrenzen/Lookaheads abgesichert
# (tarsal vs. metatarsal, Keratitis vs. Keratose, Sklera vs. Sklerose,
#  Papille vs. Papillom, makulär vs. makulopapulös, tensio vs. Hypertension).
our $OCULAR_TERM_REGEX = qr{(?:
    \baug(?:e|en)|ocular|ophthalm|intraokul|intraocul|\bbulbus|
    hornhaut|kornea|cornea|kerat(?:it|opath|oplast|okon|ektas|omil|otom|ometr)|descemet|deszemet|
    hornhautendothel|endothelzell|endotheldystroph|limbus|limbal|
    bindehaut|konjunktiv|conjunctiv|pingue|pterygi|chemos[ie]|chemotisch|hyposphagm|
    (?:ober|unter|augen)lid|\blid(?:er|kante|rand|spalt|schwell|öd|hämat|schluss|haut|winkel|fehl|retrakt|tief|lamelle|ptos|rötung)|\blid\b|eyelid|palpebr|\btarsus|\btarsal|kanthus|canthus|
    entropi|ektropi|ectropi|blephar|chalazi|hordeol|symblephar|tarsorr|trichias|distichias|madaros|\bptos|dermatochalas|lagophth|sursoadduk|deorsumadduk|
    \biris|irid|pupill|\bpupil|synechi|rubeos|
    linse\b|linsen(?:trüb|lux|sublux|disloz|kern|kapsel|implant|einnäh|berg|touch|pigment|affekt)|kontaktlinse|sklerallinse|verbandslinse|sulcuslinse|intraokularlinse|
    \blens\b|katarakt|cataract|\biol\b|hinterkammerlinse|kapselsack|hinterkapsel|vorderkapsel|kapsulotom|nachstar|phako|aphak|pseudophak|
    netzhaut|retin|makul(?!opapul|opapill)|macul(?!opapul)|fove|drusen|
    aderhaut|chorioid|choroid|chorioretin|
    papille\b|papillen(?:rand|exkav|öd|schwell|blut|atroph|bläss|leck|angiom|drus)|sehnerv|optikus|opticus|optic\s*(?:disc|nerve)|rnfl|\bbmo\b|
    glaskörper|vitre|vitrekt|
    sklera|skleral|sklerit|episkler|scler(?:a\b|al\b|itis)|
    vorderkammer|anterior\s*chamber|kammerwinkel|trabek|zyklophoto|zyklokryo|ziliar|hyphäm|hypopyon|
    tränen|lacrimal|dakryo|kanalikul|
    \borbit|periorbit|exophthalm|enophthalm|
    \bvisus|sehschärfe|visual\s*acuity|gesichtsfeld|visual\s*field|skotom|scotoma|perimetr|
    glaukom|glaucoma|\btensio|augeninnendruck|intraocular\s*pressure|
    uveit|iridozykl|amotio|ablatio\s*retinae|endophthalm|
    sickerkissen|filterkissen|filtering\s*bleb|\bbleb|
    schiel|strabism|esotrop|exotrop|heterophor|nystagm|diplop|doppelbild|
    okulomot|oculomot|abduzens|abducens|trochlear|
    retinopex|kryopex|\bivom|intravitreal|subkonjunktival|parabulbär|retrobulbär
    )}xi;

# Extraokuläre Signalwörter, ebenfalls kompositafähig. Bewusst ohne "haut"
# (Hornhaut, Bindehaut, Netzhaut, Aderhaut) und ohne "nas" (nasal = Position).
our $EXTRAOCULAR_TERM_REGEX = qr{(?:
    aorta|aorten|aortal|carotis|karotis|femoral|
    zerebr|cerebr|intrakran|\bhirn(?!nerv)|gehirn|
    arterielle[rns]?\s+(?:hyperton|hypoton|verschluss)|blutdruck|
    magen|ventricul|gastr|duoden|darm|kolon|colon|rektum|append|galle|chole|
    leber|hepat|niere|nephr|renal|harnblase|blasenkarzinom|blasen-ca|blasenentleer|prostat|zystoskop|zystektom|
    lunge|pulmo|bronch|thorak|
    \bherz|kardi|koronar|myokard|schrittmacher|bypass|mitral|aortenklapp|trikuspid|vorhof|
    mamma|\bbrust|uterus|hyster|ovar|
    schilddr|struma|
    wirbel|knochen|gelenk|arthr|hüft|\bknie|menisk|
    unterschenkel|cruris|\bbein|oberarm|unterarm|\barm\b|schulter|\bhand\b|finger(?!print|abdruck)|\bfu[ßs]|zehe|
    zahn|zähne|kiefer|gaumen|zunge|wange|gesichtshälfte|schläfe|\bstirn\b|
    \bohr|mittelohr|mastoid|pauken|tonsill|
    hautkrebs|hautausschlag|hautläsion|dermat(?!ochalas)
    )}xi;

# Gehört ein Code zum okulären Bereich der jeweiligen Terminologie?
# undef = für diese Domäne nicht bewertbar (atc, loinc).
helper is_ocular_code => sub {
    my ($self, $domain, $code) = @_;
    return undef unless defined $code && length $code;
    if ($domain eq 'icd10') {
        my $c = uc($code); $c =~ s/^ICD10://;
        # L12 (Vernarbendes Pemphigoid / OCP) und L11/L13 als okuläre Manifestationen zulassen:
        return ($c =~ /^(?:H[0-5]\d|D31|C69|Q1[0-5]|Z96\.1|Z94\.7|T85\.2|T86\.83|B02\.3|B00\.5|S05|D09\.2|D22\.1|D23\.1|T26|T85\.3|B58\.0|A18\.5|E1[0-4]\.3|B30|T15|Z44\.2|C43\.1|C44\.1|L12)/) ? 1 : 0;
    }
    if ($domain eq 'hpo') {
        return ( $self->is_subclass_of($code, 'HP:0000478')  # Abnormality of the eye
              || $self->is_subclass_of($code, 'HP:0000315') ) ? 1 : 0;   # orbital region
    }
    if ($domain eq 'ops') {
        my $c = lc($code); $c =~ s/^ops://;
        return ($c =~ /^5-(?:0[89]|1[0-6])/      # Augenchirurgie inkl. Lid und Tränenwege
             || $c =~ /^1-2[0-4]/                # Augendiagnostik
             || $c =~ /^1-840/                   # Diagnostische Punktion Auge
             || $c =~ /^8-0(?:20|11)/            # Injektion Auge, Verbandlinse
             || $c =~ /^8-170/) ? 1 : 0;         # Spülung Tränenwege
    }
    return undef;
};

# Gibt 1 zurück, wenn Begriff und Code einander widersprechen.
helper has_scope_conflict => sub {
    my ($self, $domain, $code, $term) = @_;
    return 0 unless defined $code && length $code;
    return 0 unless defined $term && length $term;

    my $term_ocular      = ($term =~ $OCULAR_TERM_REGEX)      ? 1 : 0;
    my $term_extraocular = ($term =~ $EXTRAOCULAR_TERM_REGEX) ? 1 : 0;

    # Kein Signal oder beide Signale ("Aderhautmetastase bei Mammakarzinom")
    # -> nicht bewerten, durchlassen.
    return 0 unless $term_ocular || $term_extraocular;
    return 0 if $term_ocular && $term_extraocular;

    # PATCH 2026-09-25: Allergie-/Unverträglichkeits- und Migränecodes sind organunabhängig
    return 0 if $domain eq 'icd10' && $code =~ /^ICD10:(?:T78|T88|Z88|Z91|G43)/i;

    # PATCH 2026-09-25: Lidhaut ist Gesichtshaut – Haut-/Gesichtsbefunde am Lid sind kein Widerspruch
    if ($domain eq 'hpo' && $term_ocular) {
        state $eyelid_re = qr/(?:ober|unter|augen)lid|\blid(?:haut|rand|kante)?\b|eyelid|palpebr|kanthus|canthus/i;
        if ($term =~ $eyelid_re
            && ($self->is_subclass_of($code, 'HP:0000271') || $self->is_subclass_of($code, 'HP:0000951'))) {
            return 0;
        }
    }

    my $code_ocular = $self->is_ocular_code($domain, $code);
    return 0 unless defined $code_ocular;

    return 1 if $term_ocular      && !$code_ocular;   # Auge -> Fremdfach
    return 1 if $term_extraocular &&  $code_ocular;   # Fremdfach -> Auge
    return 0;
};

# Widerspruch zwischen dem vom LLM angegebenen anatomical_site und dem Code.
# Nur HPO und OPS: im ICD-10 liegen viele okuläre Manifestationen außerhalb
# von Kapitel VII (B02.3, C69, D31, T85.2, T86.83, S05, Q15 ...).
helper site_conflict => sub {
    my ($self, $domain, $code, $site, $sim) = @_;
    return '' unless defined $site && length $site && $site ne 'none';
    return '' unless $domain eq 'hpo' || $domain eq 'ops';
    my $oc = $self->is_ocular_code($domain, $code);
    return '' unless defined $oc;
    if ($site eq 'systemic') {
        return $oc ? 'systemischer Befund, okulärer Code' : '';
    }
    return '' if $oc;
    return '' if defined $sim && $sim >= $ocular_prior_min_sim;   # nahezu exakter Treffer
    return "okuläre Struktur '$site', nicht-okulärer Code";
};

# ---------------------------------------------------------
# PATCH 2026-09-25: Hilfsfunktionen für Intercept-Validierung,
# Reranking-Guards und Elternknoten-Kandidaten
# ---------------------------------------------------------

# Levenshtein-Distanz für kurze Strings (Handelsnamen, Tippfehler)
sub _lev {
    my ($s, $t) = @_;
    my @s = split //, $s;
    my @t = split //, $t;
    return scalar(@t) unless @s;
    return scalar(@s) unless @t;
    my @prev = (0 .. scalar(@t));
    for my $i (1 .. scalar(@s)) {
        my @cur = ($i);
        for my $j (1 .. scalar(@t)) {
            my $cost = ($s[$i - 1] eq $t[$j - 1]) ? 0 : 1;
            my $v = $prev[$j] + 1;
            $v = $cur[$j - 1] + 1      if $cur[$j - 1] + 1 < $v;
            $v = $prev[$j - 1] + $cost if $prev[$j - 1] + $cost < $v;
            push @cur, $v;
        }
        @prev = @cur;
    }
    return $prev[-1];
}

# Lexikalische Plausibilität eines ATC-Treffers: Wirkstoff oder Handelsname
# muss zum Begriff passen (Tippfehler bis 25 % toleriert).
helper atc_lexical_ok => sub {
    my ($self, $term, $hit) = @_;
    return 0 unless ref $hit eq 'HASH';
    my $q = _lex_norm($term);
    return 1 if length($q) < 4;    # Kürzel wie ASS, MTX: nicht lexikalisch prüfbar
    my @names;
    for my $s ($hit->{label}, $hit->{index_text}) {
        next unless defined $s && length $s;
        push @names, _lex_norm($s);
        push @names, map { _lex_norm($_) } grep { length($_) >= 4 } split /[^\p{L}]+/, $s;
    }
    for my $n (grep { length($_) >= 3 } @names) {
        return 1 if index($n, $q) >= 0;
        return 1 if length($n) >= 5 && index($q, $n) >= 0;
        my $max = length($q) > length($n) ? length($q) : length($n);
        return 1 if _lev($q, $n) / $max <= 0.25;
    }
    return 0;
};

# Intercepts, deren Code nicht in der Terminologie steht, werden ignoriert
# (einmalige Warnung pro Regel).
helper _validate_intercepts => sub {
    my ($self, $domain, $rows) = @_;
    return $rows unless $intercept_validate && ref $rows eq 'ARRAY';
    state %warned;
    my @ok;
    for my $r (@$rows) {
        if ($r->{suppress}) { push @ok, $r; next; }
        my $code   = $r->{code} // '';
        my $fmt_ok = ($code =~ /^(?:HP|ICD10|OPS|ATC|LOINC):\S+$/i) ? 1 : 0;
        my $label  = $fmt_ok ? eval { $self->get_canonical_ontology_label($domain, $code) } : undef;
        if (defined $label && length $label && $label !~ /^\s*(?:obsolete|deprecated)\b/i) {
            push @ok, $r;
            next;
        }
        my $why = !$fmt_ok ? 'ungültiges Format' : !defined $label ? 'nicht in der Terminologie' : 'veraltet';
        $self->app->log->warn("[INTERCEPT INVALID] Domain '$domain': '$code' ($r->{label}) $why – Regel ignoriert.")
            unless $warned{"$domain|$code|" . ($r->{pattern} // '')}++;
    }
    return \@ok;
};

# Gemeinsamer Elternknoten der Kandidaten (ICD/OPS) als zusätzlicher
# "broader"-Kandidat für den Reranker.
helper common_parent_candidate => sub {
    my ($self, $domain, $cands) = @_;
    return undef unless $parent_candidate_on;
    return undef unless $domain =~ /^(?:icd10|ops)$/ && ref $cands eq 'ARRAY' && @$cands > 1;
    my $table  = $domain eq 'icd10' ? 'public.icd10_terms' : 'public.ops_terms';
    my $prefix = $domain eq 'icd10' ? 'ICD10:' : 'OPS:';
    my (@chains, %count);
    for my $c (@$cands) {
        (my $id = $c->{id} // '') =~ s/^(?:ICD10|OPS)://i;
        next unless length $id;
        my $rows = eval {
            $self->pg->db->query(qq{
                WITH RECURSIVE up AS (
                    SELECT id, parent_id, label, 0 AS d FROM $table WHERE lower(id) = lower(?)
                    UNION ALL
                    SELECT p.id, p.parent_id, p.label, up.d + 1
                      FROM $table p JOIN up ON p.id = up.parent_id
                     WHERE up.d < 10
                )
                SELECT id, label FROM up ORDER BY d
            }, $id)->hashes->to_array;
        } // [];
        next unless @$rows;
        push @chains, $rows;
        my %seen;
        $count{ lc $_->{id} }++ for grep { !$seen{ lc $_->{id} }++ } @$rows;
    }
    return undef unless @chains > 1 && @chains == @$cands;
    my %cand_ids = map { lc(($_->{id} // '') =~ s/^(?:ICD10|OPS)://ir) => 1 } @$cands;
    for my $n (@{ $chains[0] }) {
        next unless ($count{ lc $n->{id} } // 0) == @chains;
        return undef if $cand_ids{ lc $n->{id} };                  # Oberbegriff ist schon Kandidat
        return undef unless is_plausible_code($domain, $n->{id});  # keine Kapitel/Bereiche
        return { id => $prefix . $n->{id}, label => $n->{label}, resolved => 1,
                 sim => 0, index_text => undef, is_parent => 1 };
    }
    return undef;
};

# Einheitliche Treffer-Auswertung für HPO/OPS/ATC/LOINC:
# Distanzschwelle + Scope-Guard + Label-Auflösung.
# Gibt undef zurück, wenn der Treffer verworfen wird.
# ---------------------------------------------------------
# Hilfsfunktionen für die Trefferauswertung
# ---------------------------------------------------------
sub _match_sim {
    my ($m) = @_;
    return undef unless ref $m eq 'HASH';
    my $s = $m->{similarity} // $m->{sim};
    return $s + 0 if defined $s;
    my $d = $m->{distance} // $m->{dist};
    return defined $d ? 1.0 - $d : undef;
}

sub _decode_matches {
    my ($tx) = @_;
    return [] unless $tx && $tx->result && $tx->result->is_success;
    my $body = $tx->result->body;
    my $m = eval { decode_json($body) } // eval { from_json(decode('UTF-8', $body)) } // [];
    return (ref $m eq 'ARRAY') ? $m : [];
}

# Enthält der Vektorindex an dieser Stelle überhaupt eine gültige ID?
# Früher wurde aus leeren/Freitext-Labels stillschweigend HP:0000118.
sub is_plausible_code {
    my ($domain, $raw) = @_;
    return 0 unless defined $raw && length $raw;
    my $c = $raw;
    $c =~ s/^(?:HP|ICD10|OPS|ATC|LOINC)://i;
    $c =~ s/^\s+|\s+$//g;
    if ($domain eq 'hpo') {
        (my $n = $c) =~ s/\D//g;
        return 0 unless length $n && $c =~ /^(?:HP:?)?\d+$/i;
        $n += 0;
        return ($n > 0 && $n != 118) ? 1 : 0;
    }
    return ($c =~ /^[A-Z]\d{2}(?:\.[0-9A-Z\-]{1,4})?$/i)                  ? 1 : 0 if $domain eq 'icd10';
    return ($c =~ /^\d-[0-9a-z]{2,3}(?:\.[0-9a-z]{1,3})?$/i)              ? 1 : 0 if $domain eq 'ops';
    return ($c =~ /^[A-Z]{1,2}\d{2}(?:[A-Z]{1,2}(?:\d{2})?)?$/i)          ? 1 : 0 if $domain eq 'atc';
    # PATCH 2026-10-22: lokale Analogcodes mit Buchstabe statt Prüfziffer (95327-A)
    return ($c =~ /^(?:\d{1,7}-(?:\d[a-z]?|[A-Z])|LP\d+-\d|CLASS-.+)$/i)  ? 1 : 0 if $domain eq 'loinc';
    return 1;
}

# Einheitliche Treffer-Auswertung für HPO/OPS/ATC/LOINC:
# gültige ID + Distanzschwelle + Scope-/Site-Guard + okulärer Prior + Label.
# $opts: quiet, context (Verbatim), site (anatomical_site)
helper _build_vector_res => sub {
    my ($self, $domain, $match, $term, $max_dist, $opts) = @_;
    $opts //= {};
    my $quiet = $opts->{quiet} ? 1 : 0;
    my $log   = $self->app->log;

    # Schwellen je Domäne. ATC ist tolerant (Handelsnamen), HPO/OPS streng.
    # PATCH 2026-09-25: Grauzone. Mit Reranking dürfen Kandidaten bis zur Floor-Distanz
    # durch; entschieden wird dann im Reranker statt per harter Schwelle.
    unless (defined $max_dist) {
        $max_dist = { hpo => 0.055, ops => 0.055, atc => 0.07, loinc => 0.06 }->{$domain} // 0.055;
        if ($rerank_enabled && !$opts->{no_rerank}) {
            my $g = $rerank_gray_floor->{$domain} // $max_dist;
            $max_dist = $g if $g > $max_dist;
        }
    }

    return undef unless $match && defined $match->{label};

    my $raw_code = $match->{label};
    $raw_code =~ s/^\s+|\s+$//g;
    my $dist_str = _extract_vector_dist_str($match);

    unless (is_plausible_code($domain, $raw_code)) {
        $log->warn("[\U$domain\E INVALID INDEX ID]$dist_str '$term' -> '$raw_code' ist keine gültige ID. Verworfen.") unless $quiet;
        return undef;
    }

    my $sim  = _match_sim($match);
    my $dist = defined $sim ? (1.0 - $sim) : 1.0;

    if ($dist > $max_dist) {
        $log->warn("[\U$domain\E SUPPRESSED]$dist_str '$term' -> $raw_code überschreitet Max-Distanz ($dist > $max_dist). Treffer verworfen.") unless $quiet;
        return undef;
    }

    my $fmt = { hpo => 'format_hpo_id', ops => 'format_ops_id',
                atc => 'format_atc_id', loinc => 'format_loinc_id' }->{$domain};
    my $matched_id = $self->$fmt($raw_code);

    if ($self->has_scope_conflict($domain, $matched_id, $term)
        || (defined $opts->{context} && $self->has_scope_conflict($domain, $matched_id, $opts->{context}))) {
        $log->warn("[\U$domain\E SCOPE CONFLICT]$dist_str '$term' -> $matched_id widerspricht der im Begriff genannten Anatomie. Treffer verworfen.") unless $quiet;
        return undef;
    }

    if (my $why = $self->site_conflict($domain, $matched_id, $opts->{site}, $sim)) {
        $log->warn("[\U$domain\E SITE CONFLICT]$dist_str '$term' -> $matched_id: $why. Treffer verworfen.") unless $quiet;
        return undef;
    }

    # Okulärer Prior für OPS: in Augenarztbriefen ist ein nicht-okulärer
    # Eingriff ohne extraokuläres Signalwort nur bei nahezu exaktem Treffer
    # glaubhaft (Schwenklappenplastik -> Herzklappe, Kryotherapie -> Hypothermie).
    if ($ocular_prior_enabled && $domain eq 'ops'
        && defined $sim && $sim < $ocular_prior_min_sim
        && ($opts->{site} // '') ne 'systemic'
        && $term !~ $EXTRAOCULAR_TERM_REGEX
        && !(defined $opts->{context} && $opts->{context} =~ $EXTRAOCULAR_TERM_REGEX)) {
        my $oc = $self->is_ocular_code($domain, $matched_id);
        if (defined $oc && !$oc) {
            $log->warn("[OPS OCULAR PRIOR]$dist_str '$term' -> $matched_id ist nicht-okulär, sim < $ocular_prior_min_sim, kein extraokuläres Signal. Treffer verworfen.") unless $quiet;
            return undef;
        }
    }

    my $db_label      = $self->get_canonical_ontology_label($domain, $raw_code);
    my $matched_label = $db_label // $match->{payload} // $term;

    # PATCH 2026-09-25: obsolete HPO-Terme und veraltete LOINC-Codes nie vergeben
    if (defined $db_label && $db_label =~ /^\s*(?:obsolete|deprecated)\b/i) {
        $log->warn("[\U$domain\E OBSOLETE]$dist_str '$term' -> $matched_id ($db_label) ist veraltet. Verworfen.") unless $quiet;
        return undef;
    }

    $log->info("[\U$domain\E RETRIEVAL]$dist_str '$term' -> $matched_id ($matched_label)") unless $quiet;
    return { id => $matched_id, label => $matched_label, resolved => (defined $db_label ? 1 : 0),
             sim => $sim, index_text => $match->{payload} };
};

# ---------------------------------------------------------
# LABEL-GATE (PATCH 2026-09-24)
# Ein hoher Similarity-Wert beweist nur, dass der Indexschlüssel zur Query
# passt, nicht dass der Code stimmt. Ohne Reranking wird ein Treffer nur
# übernommen, wenn die Query lexikalisch durch das kanonische Ontologie-Label
# (oder ein HPO-Synonym, bei ATC auch den Handelsnamen) gedeckt ist.
# ---------------------------------------------------------
our %LABEL_GATE_STOPWORDS = map { $_ => 1 } qw(
    sonstige sonstiger sonstiges sonstigen naher bezeichnet bezeichnete bezeichneter bezeichneten
    angabe durch nach eines einer einem oder ohne affektionen affektion krankheit krankheiten zustand
    abnormal abnormality morphology other unspecified with without left right links rechts beidseits
    auge augen eye eyes
);

sub _gate_tokens {
    my ($s) = @_;
    $s = lc($s // '');
    $s =~ tr/äöüß/aous/;
    my @t;
    for my $w (split /[^a-z0-9]+/, $s) {
        next if length($w) < 4;
        next if $LABEL_GATE_STOPWORDS{$w};
        $w =~ s/(?:es|en|er|s|e|n)$// if length($w) > 6;   # grobe Endungskappung
        push @t, $w;
    }
    return @t;
}

helper get_ontology_synonyms => sub {
    my ($self, $domain, $code) = @_;
    return [] unless $domain eq 'hpo' && defined $code;
    state %cache;
    (my $n = $code) =~ s/\D//g;
    return [] unless length $n;
    return $cache{$n} if exists $cache{$n};
    my $rows = eval {
        $self->pg->db->query('SELECT DISTINCT label FROM public.synonyms WHERE idterm = ?', int($n))
             ->arrays->map(sub { $_->[0] })->to_array;
    };
    return $cache{$n} = (ref $rows eq 'ARRAY' ? $rows : []);
};

helper label_matches => sub {
    my ($self, $domain, $term, $hit) = @_;
    return 0 unless ref $hit eq 'HASH' && defined $term && length $term;

    my @q = _gate_tokens($term);
    return 0 unless @q;

    my @labels = ($hit->{label});
    push @labels, $hit->{index_text} if $domain eq 'atc';          # Handelsnamen sind bei ATC legitim
    push @labels, @{ $self->get_ontology_synonyms($domain, $hit->{id}) };
    my @l = map { _gate_tokens($_) } grep { defined && length } @labels;
    return 0 unless @l;

    my $covered = 0;
    QT: for my $qt (@q) {
        for my $lt (@l) {
            if ($qt eq $lt
                || (length($lt) >= 5 && index($qt, $lt) >= 0)     # Kompositum enthält Labelwort
                || (length($qt) >= 5 && index($lt, $qt) >= 0)) {
                $covered++;
                next QT;
            }
        }
    }
    return ($covered / scalar(@q)) >= $label_gate_min_cov ? 1 : 0;
};

# Elternknoten für den Reranker (Kontext "Oberbegriff")
helper get_parent_label => sub {
    my ($self, $domain, $code) = @_;
    return undef unless defined $code && length $code;
    state %cache;
    my $key = "$domain|$code";
    return $cache{$key} if exists $cache{$key};

    my $res;
    eval {
        if ($domain eq 'hpo') {
            (my $n = $code) =~ s/\D//g;
            my $r = $self->pg->db->query(q{
                SELECT t.id, t.label FROM public.isas i JOIN public.terms t ON t.id = i.idparent
                 WHERE i.idchild = ? LIMIT 1
            }, int($n))->hash;
            $res = sprintf('HP:%07d %s', $r->{id}, $r->{label}) if $r;
        } else {
            my %tab = (icd10 => 'public.icd10_terms', ops => 'public.ops_terms',
                       atc   => 'public.atc_terms',   loinc => 'public.loinc_terms');
            if (my $t = $tab{$domain}) {
                (my $c = $code) =~ s/^(?:ICD10|OPS|ATC|LOINC)://i;
                my $r = $self->pg->db->query(
                    "SELECT p.id, p.label FROM $t c JOIN $t p ON p.id = c.parent_id WHERE lower(c.id) = lower(?) LIMIT 1",
                    $c)->hash;
                $res = "$r->{id} $r->{label}" if $r;
            }
        }
    };
    return $cache{$key} = $res;
};

# ---------------------------------------------------------
# TOP-K-AUSWAHL MIT LLM-RERANKING IN DER GRAUZONE
# Sehr sichere Treffer (sim >= $rerank_accept_sim) werden direkt übernommen,
# alles darunter entscheidet ein kurzer, schema-gebundener LLM-Aufruf unter
# den gültigen Top-k-Kandidaten (oder verwirft alle).
# ---------------------------------------------------------
helper _select_vector_hit_async => sub {
    my ($self, $domain, $matches, $term, $opts) = @_;
    $opts //= {};
    return Mojo::Promise->resolve(undef) unless ref $matches eq 'ARRAY' && @$matches;

    my $top = $self->_build_vector_res($domain, $matches->[0], $term, $opts->{max_dist}, $opts);
    return Mojo::Promise->resolve(undef) unless $top;

    my $sim = $top->{sim} // 0;
    return Mojo::Promise->resolve($top) if !$rerank_enabled || $opts->{no_rerank};

    # PATCH 2026-09-24: hoher Similarity-Wert allein reicht nicht mehr
    if ($sim >= $rerank_accept_sim) {
        return Mojo::Promise->resolve($top)
            if $top->{resolved} && $self->label_matches($domain, $term, $top);
        $self->app->log->info("[\U$domain\E LABEL GATE] '$term' -> $top->{id} ($top->{label}) sim $sim, aber Label deckt Query nicht. Reranking.");
    }

    my @cands = ($top);
    my $last  = ($#$matches < $rerank_top_k - 1) ? $#$matches : $rerank_top_k - 1;
    for my $i (1 .. $last) {
        my $r = $self->_build_vector_res($domain, $matches->[$i], $term, $opts->{max_dist}, { %$opts, quiet => 1 });
        next unless $r;
        next if grep { $_->{id} eq $r->{id} } @cands;
        push @cands, $r;
    }
    # PATCH 2026-09-25: gemeinsamer Elternknoten als broader-Kandidat, Flags für den Cache
    my $parent = $self->common_parent_candidate($domain, \@cands);
    push @cands, $parent if $parent;
    return $self->rerank_candidates_async($domain, $term, \@cands, $opts->{context}, $opts);
};

helper rerank_candidates_async => sub {
    my ($self, $domain, $term, $cands, $context, $flags) = @_;   # PATCH 2026-09-25: $flags (is_history, site)
    return Mojo::Promise->resolve(undef) unless ref $cands eq 'ARRAY' && @$cands;
    my $log = $self->app->log;

    my $prompt = $self->get_llm_prompt('mapping_candidate_reranker');
    unless ($prompt && $prompt->{system_prompt}) {
        # PATCH 2026-09-24: ohne Prompt nur noch lexikalisch gedeckte Top-1-Treffer übernehmen
        if ($self->label_matches($domain, $term, $cands->[0])) {
            $log->warn("[\U$domain\E RERANK WARN] Prompt 'mapping_candidate_reranker' fehlt – Top-1 ($cands->[0]{id}) per Label-Gate übernommen.");
            return Mojo::Promise->resolve($cands->[0]);
        }
        $log->warn("[\U$domain\E RERANK WARN] Prompt 'mapping_candidate_reranker' fehlt – '$term' ohne Label-Deckung verworfen.");
        return Mojo::Promise->resolve(undef);
    }

    # -------------------------------------------------------------
    # 1. KANDIDATENLISTE: Code | Ontologie-Label | Oberbegriff | Indextext
    #    Das Ontologie-Label kommt aus der Terminologietabelle, nicht aus dem
    #    Index-Payload. Der Indextext (z.B. Handelsname) steht nur zusätzlich da.
    # -------------------------------------------------------------
    my @lines;
    for my $i (0 .. $#$cands) {
        my $cd     = $cands->[$i];
        my $parent = $self->get_parent_label($domain, $cd->{id}) // '-';
        my $itext  = $cd->{index_text} // '-';
        $itext = '-' if lc($itext) eq lc($cd->{label} // '');
        push @lines, sprintf("%d: %s | %s | Oberbegriff: %s | Indextext: %s",
            $i, $cd->{id}, $cd->{label} // '-', $parent, $itext);
    }
    my $list = join("\n", @lines);

    my $cand_key    = join('|', map { $_->{id} } @$cands);
    # Cache-Schlüssel hängt an Prompt-Version UND an den gezeigten Labels:
    # ändert sich der Prompt oder die Ontologietabelle, wird neu entschieden.
    # PATCH 2026-09-25: Vorgeschichte und Struktur gehören zum Cache-Schlüssel,
    # sonst wird eine "Z.n."-Entscheidung auf aktuelle Befunde übertragen.
    my $flag_str = (ref $flags eq 'HASH')
        ? join(';', 'hist=' . ($flags->{is_history} ? 1 : 0), 'site=' . ($flags->{site} // ''))
        : '';
    my $prompt_hash = md5_hex(encode('UTF-8', join("\x{1}",
        $prompt->{system_prompt} // '', $prompt->{user_template} // '', $list, $flag_str)));

    # -------------------------------------------------------------
    # 2. CACHE-LOOKUP
    # -------------------------------------------------------------
    my $cached = eval {
        $self->pg->db->query(q{
            SELECT chosen_id, relation, reason FROM public.mapping_rerank_cache
             WHERE domain = ? AND query = ? AND candidate_ids = ? AND prompt_hash = ?
        }, $domain, $term, $cand_key, $prompt_hash)->hash;
    };
    if ($cached) {
        my $cid    = $cached->{chosen_id};
        my $rel    = $cached->{relation} // '?';
        my $reason = $cached->{reason} // 'Keine Begründung gespeichert';

        if (defined $cid && length $cid) {
            my ($hit) = grep { $_->{id} eq $cid } @$cands;
            if ($hit) {
                $log->info("[\U$domain\E RERANK CACHE HIT] '$term' -> $hit->{id} ($hit->{label}) [$rel]. Grund: $reason");
                return Mojo::Promise->resolve($hit);
            }
        } else {
            $log->warn("[\U$domain\E RERANK CACHE REJECT] '$term' -> keiner von [$cand_key] passt [$rel]. Grund: $reason");
            return Mojo::Promise->resolve(undef);
        }
    }

    # -------------------------------------------------------------
    # 3. IN-FLIGHT-DEDUPLIZIERUNG
    #    Parallele Anfragen mit identischem Schlüssel teilen sich ein Promise,
    #    statt mehrfach (und mit unterschiedlichem Ergebnis) zu ranken.
    # -------------------------------------------------------------
    state %inflight;
    my $flight_key = join("\x{1}", $domain, $term, $cand_key, $prompt_hash);
    return $inflight{$flight_key} if $inflight{$flight_key};

    my $ctx = (defined $context && length $context) ? $context : '-';
    $ctx =~ s/\s+/ /g;
    $ctx = substr($ctx, 0, 400);

    my $cand_overview = join(', ', map { "$_->{id} ($_->{label})" } @$cands);
    $log->info("[\U$domain\E RERANK EVAL] '$term' prüft " . scalar(@$cands) . " Kandidat(en): [$cand_overview]");

    my $user = $prompt->{user_template}
        // "Domäne: {{domain}}\nBegriff: \"{{term}}\"\nKontext: \"{{context}}\"\nKandidaten (Index: Code | Ontologie-Label | Oberbegriff | Indextext):\n{{candidates}}";
    $user =~ s/\{\{domain\}\}/$domain/g;
    $user =~ s/\{\{term\}\}/$term/g;
    $user =~ s/\{\{context\}\}/$ctx/g;
    $user =~ s/\{\{candidates\}\}/$list/g;

    # relation vor choice: das Modell soll zuerst die Beziehung bestimmen.
    my $schema = {
        type => 'object',
        properties => {
            relation => { type => 'string', enum => [qw(exact broader narrower related unrelated)],
                          description => 'Beziehung des Begriffs zum besten Kandidaten.' },
            choice   => { type => 'integer', description => 'Index des besten Kandidaten, -1 wenn keiner exact oder broader ist.' },
            reason   => { type => 'string',  description => 'Ein Satz, nur mit Angaben aus der Kandidatenliste.' },
        },
        required => ['relation', 'choice', 'reason'],
        additionalProperties => \0,
    };

    # -------------------------------------------------------------
    # 4. LLM-ENTSCHEIDUNG: nur exact|broader wird übernommen
    # -------------------------------------------------------------
    my $p = $self->llm_json_call_async($prompt->{system_prompt}, $user, $schema, 'mapping_rerank')->then(sub {
        my $d = shift;
        unless (ref $d eq 'HASH' && defined $d->{choice} && "$d->{choice}" =~ /^-?\d+$/) {
            # Kein blindes Top-1 mehr: nur bei lexikalischer Deckung übernehmen. Nicht cachen.
            if ($self->label_matches($domain, $term, $cands->[0])) {
                $log->warn("[\U$domain\E RERANK FAILED] '$term' kein valides JSON – Top-1 ($cands->[0]{id}) per Label-Gate übernommen.");
                return $cands->[0];
            }
            $log->warn("[\U$domain\E RERANK FAILED] '$term' kein valides JSON – verworfen.");
            return undef;
        }

        my $choice   = $d->{choice} + 0;
        my $relation = lc($d->{relation} // 'unrelated');
        my $reason   = $d->{reason} // '';
        my $picked   = ($choice >= 0 && $choice <= $#$cands) ? $cands->[$choice] : undef;
        my $chosen   = ($picked && $relation =~ /^(?:exact|broader)$/) ? $picked : undef;

        # PATCH 2026-09-25: deterministische ATC-Guards
        # - broader nur auf Klassenebene (< 7 Stellen), nie ein anderes Präparat
        # - exact nur mit lexikalischer Deckung (Wirkstoff oder Handelsname, Tippfehler toleriert)
        if ($chosen && $domain eq 'atc') {
            (my $ac = $chosen->{id}) =~ s/^ATC://i;
            if ($relation eq 'broader' && length($ac) >= 7) {
                $reason   = "[Guard] broader auf Präparatebene ($chosen->{id}) nicht zulässig. " . $reason;
                $relation = 'unrelated';
                $chosen   = undef;
            } elsif ($relation eq 'exact' && !$self->atc_lexical_ok($term, $chosen)) {
                $reason   = "[Guard] keine lexikalische Deckung zwischen '$term' und $chosen->{id}. " . $reason;
                $relation = 'related';
                $chosen   = undef;
            }
        }

        eval {
            $self->pg->db->query(q{
                INSERT INTO public.mapping_rerank_cache
                       (domain, query, candidate_ids, prompt_hash, chosen_id, relation, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (domain, query, candidate_ids, prompt_hash) DO NOTHING
            }, $domain, $term, $cand_key, $prompt_hash, ($chosen ? $chosen->{id} : undef), $relation, $reason);
        };
        $log->warn("[\U$domain\E RERANK CACHE WRITE FAILED] $@") if $@;

        if ($chosen) {
            $log->info("[\U$domain\E RERANK] '$term' -> $chosen->{id} ($chosen->{label}) [$relation] aus " . scalar(@$cands) . " Kandidaten. Begründung: $reason");
        } elsif ($picked) {
            $log->warn("[\U$domain\E RERANK REJECT] '$term' -> $picked->{id} ($picked->{label}) verworfen, Relation '$relation'. Begründung: $reason");
        } else {
            $log->warn("[\U$domain\E RERANK REJECT] '$term' -> alle verworfen [$cand_key]. Begründung: $reason");
        }
        return $chosen;
    });

    $inflight{$flight_key} = $p;
    $p->finally(sub { delete $inflight{$flight_key} });
    return $p;
};

# =========================================================================
# ICD-10 ASYNCHRONOUS MAPPING ENGINE MIT DB-INTERCEPT & ATC-ALLERGIE-FIX
# =========================================================================
# Allergene ohne konkrete Substanz: kein ATC-Lookup.
our $GENERIC_ALLERGEN_REGEX = qr/^(?:medikament\w*|arzneimittel\w*|augentropfen|tropfen|salbe|reaktion|allergische?\s*reaktion|unbekannt\w*|diverse\w*|mehrere\w*|alle\w*|substanz\w*)$/i;

# Normalisiert einen String für den lexikalischen Plausibilitätsvergleich.
sub _lex_norm {
    my $x = lc(shift // '');
    $x =~ tr/äöüß/aous/;
    $x =~ s/[^a-z]//g;
    return $x;
}

# Isoliert die Substanz aus "Arzneimittelallergie gegen Tilidin",
# "Unverträglichkeit von Dorzo-Augentropfen", "Allergie auf Amoxicillin, Cefaclor".
# Ohne führende Wortgrenze, damit Komposita ("...allergie", "...unverträglichkeit") greifen.
sub extract_allergy_substance {
    my ($t) = @_;
    return '' unless defined $t && length($t);
    my $s = $t;
    $s =~ s/[-_]/ /g;
    $s =~ s/^.*?(?:allergi\w*|unvertr(?:ä|a)glich\w*|intoleranz|überempfindlich\w*|anaphyla\w*)\s*(?:reaktion\s*)?(?:gegen(?:über)?|auf|von|nach|bei|g\/?g)?\s*:?\s*//i;
    # Mehrere Substanzen: die erste nehmen (die übrigen sollten eigene Zeilen sein)
    $s = (split /\s*(?:,|;|\/|\bund\b|\bsowie\b)\s*/i, $s)[0] // '';
    $s =~ s/\b(?:in\s+der\s+eigenanamnese|eigenanamnese|anamnestisch|bekannte?r?s?)\b/ /gi;
    $s =~ s/\b(?:i\.?\s*v\.?|oral|intravenös(?:e)?|therapie|gabe|behandlung|medikation|präparat|tabletten?|kapseln?|infusion)\b/ /gi;
    $s =~ s/[^\p{L}\p{N}\s]+//g;
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# =========================================================================
# ICD-10 ASYNCHRONOUS MAPPING ENGINE MIT DB-INTERCEPT & ATC-ALLERGIE-FIX
# $opts: context (Verbatim), site, is_history
# =========================================================================
helper map_to_icd10_async => sub {
    my ($self, $verbatim_term, $canonical_term, $doc_lang, $opts) = @_;

    # Fallback bei flexibler Parameterübergabe
    if (!defined $doc_lang && defined $canonical_term && $canonical_term =~ /^(?:de|en|other)$/i) {
        $doc_lang       = $canonical_term;
        $canonical_term = undef;
    }
    $doc_lang = lc($doc_lang // 'de');
    $opts //= {};

    return Mojo::Promise->resolve(undef) unless defined $verbatim_term && length($verbatim_term);

    # 1. Allergie-/Unverträglichkeits-Erkennung
    my $is_allergy = (($verbatim_term =~ /allerg|unvertr|intoler/i) ||
                      (defined $canonical_term && $canonical_term =~ /allerg|unvertr|intoler/i)) ? 1 : 0;

    my $primary_term  = ($is_allergy && defined $canonical_term && length($canonical_term) > 1)
                      ? $canonical_term
                      : $verbatim_term;
    my $fallback_term = ($primary_term eq $verbatim_term) ? $canonical_term : $verbatim_term;

    # --- HILFSFUNKTION: INTELLIGENTE ALLERGIE-TRENNUNG (ARZNEIMITTEL VS. ALLERGENE) ---
    my $apply_allergy_atc_override = sub {
        my ($res) = @_;
        return Mojo::Promise->resolve($res) unless $res && $res->{id};
        return Mojo::Promise->resolve($res) unless $is_allergy;

        my $t_check = lc("$verbatim_term " . ($canonical_term // ''));

        # Eine Krankheit hinter "Allergie gegen" ist ein Extraktionsfehler, kein Allergen.
        if ($t_check =~ /\b(?:gvhd|absto[ßs]ung|transplantat\w*|limbus\w*|ektropium|entropium|
            hornhaut|keratit\w*|glaukom|katarakt|amotio|uveiti\w*)/xi) {
            return Mojo::Promise->resolve($res);
        }

        # 1. Insekten- & Tiergifte (dürfen NIEMALS in ATC!)
        if ($t_check =~ /\b(?:biene|wespe|hornis|insekt|tierhaar|katze|hund|pferd|meerschwein)/i) {
            my $label = ($t_check =~ /biene/i)  ? 'Allergie gegen Bienengift'
                      : ($t_check =~ /wespe/i)  ? 'Allergie gegen Wespengift'
                      : 'Allergie gegen Tierhaare/Tiergifte';
            return Mojo::Promise->resolve({ id => 'ICD10:T63.4', label => $label });
        }

        # 2. Pollen / Inhalationsallergien
        if ($t_check =~ /\b(?:birke|gr[äa]ser|roggen|beifu[ßs]|pollen|heu(?:schnupfen)?|hausstaub|milbe|schimmel)/i) {
            return Mojo::Promise->resolve({ id => 'ICD10:J30.1', label => 'Allergische Rhinopathie durch Pollen/Inhalationsallergene' });
        }

        # 3. Nahrungsmittelallergien
        if ($t_check =~ /\b(?:haselnuss|n[üu]ss|soja|erdnuss|apfel|[äa]pfel|citrus|zitrus|zitrone|
            karotte|m[öo]hre|fisch|meeresfr[üu]cht|eiwei[ßs]|eigelb|h[üu]hnerei|
            weizen|gluten|laktose|lactose|fruktose|fructose|curry|ananas|kiwi|sellerie|senf|
            nahrungsmittel|lebensmittel|obst|gem[üu]se|gespritzte\s+fr[üu]chte)/xi) {
            return Mojo::Promise->resolve({ id => 'ICD10:T78.1', label => 'Sonstige unerwünschte Nebenwirkungen von Nahrungsmitteln' });
        }

        # 4. Kontaktallergien & Hilfsstoffe
        if ($t_check =~ /\b(?:pflaster|latex|nickel|perubalsam|duftstoff|konservier|kontakt|
            nahtmaterial|verbandmaterial|wollwachs|lanolin|chrom|kobalt|gummi)/xi) {
            return Mojo::Promise->resolve({ id => 'ICD10:L23.9', label => 'Allergische Kontaktdermatitis' });
        }

        # 5. NUR WENN ES SICH TATSÄCHLICH UM MEDIKAMENTE HANDELT -> ATC Lookup
        my $is_specific_code = ($res->{id} =~ /^ICD10:Z88\.0/i);
        my $is_unspecific    = (!$is_specific_code) && ($res->{id} =~ /^ICD10:(?:T88|T78|Z88)/i);
        return Mojo::Promise->resolve($res) unless $is_unspecific;

        my $substance = extract_allergy_substance($canonical_term);
        $substance = extract_allergy_substance($verbatim_term) unless length($substance) > 2;
        $substance = 'Salbutamol' if $substance =~ /^subtamol$/i;   # Typo-Korrektur

        return Mojo::Promise->resolve($res) unless length($substance) > 2;
        return Mojo::Promise->resolve($res) if $substance =~ $GENERIC_ALLERGEN_REGEX;

        my $klartext = (uc($substance) eq $substance) ? $substance : ucfirst(lc($substance));

        # Strengere Schwelle als bei Medikationslisten und kein Reranking: für
        # Allergene zählt nur ein eindeutiger Treffer.
        return $self->map_to_atc_async($substance, $doc_lang, { max_dist => 0.045, no_rerank => 1 })->then(sub {
            my $atc_hit = shift;

            # Lexikalische Plausibilität für Vektortreffer (Intercepts sind kuratiert):
            # verhindert "Tilidin -> Allergie-Augentropfen", "Phenyendiamin -> Phenindamin".
            if ($atc_hit && ($atc_hit->{source} // '') ne 'intercept') {
                my $a = _lex_norm($substance);
                my $b = _lex_norm($atc_hit->{label});
                my $n = length($a) < 5 ? length($a) : 5;
                my $ok = ($n >= 3 && index($b, substr($a, 0, $n)) >= 0)
                      || (length($b) >= 5 && index($a, substr($b, 0, 5)) >= 0);
                unless ($ok) {
                    $self->app->log->warn("[ICD10 DRUG ALLERGY] '$substance' -> $atc_hit->{id} ($atc_hit->{label}) lexikalisch unplausibel. Ohne ATC-Bezug.");
                    $atc_hit = undef;
                }
            }

            if ($atc_hit && $atc_hit->{id}) {
                $self->app->log->info("[ICD10 DRUG ALLERGY OVERRIDE] '$substance' -> ICD10:Z88.8 ($atc_hit->{id} ($klartext))");
                return { id => 'ICD10:Z88.8', label => "$atc_hit->{id} ($klartext)" };
            }
            return { id => 'ICD10:Z88.8', label => "Allergie gegen $klartext" };
        });
    };

    # 2. DB-Intercepts prüfen (mit ATC-Anreicherung bei Allergien)
    # PATCH 2026-09-24: kanonischer Begriff zuerst, Verbatim nur noch als letzte Stufe
    my %seen_cand;
    for my $cand (grep { defined && length && !$seen_cand{$_}++ } ($canonical_term, $primary_term, $verbatim_term)) {
        my $clean = lc(clean_term_for_vector_mapping($cand));

        if (my $hit = $self->check_database_intercept('icd10', $clean, $opts->{context})
                   || $self->check_database_intercept('icd10', $cand,  $opts->{context})) {
            return Mojo::Promise->resolve(undef) if $hit->{suppress};
            $self->app->log->info("[ICD10 DB INTERCEPT] '$cand' -> $hit->{id} ($hit->{label})");
            if (($hit->{rule_label} // $hit->{label} // '') =~ /pflaster|verband|latex|kontakt/i || $cand =~ /pflaster|latex/i) {
                return Mojo::Promise->resolve($hit);
            }
            return $apply_allergy_atc_override->($hit);
        }
    }

    # 3. Sprachnormalisierung & Patchbay-Aufruf vorbereiten
    my $normalize = sub {
        my ($t) = @_;
        return ($doc_lang eq 'de')
            ? Mojo::Promise->resolve(clean_term_for_vector_mapping($t))
            : $self->normalize_criterion_for_retrieval_async($t, 'icd10');
    };

    # Liefert jetzt die komplette Trefferliste (für Top-k-Reranking)
    my $fetch_matches = sub {
        my ($q) = @_;
        my $call = sub {
            my $url = "$patchbay_url/LLM/run_stateless/" . LLM_ICD10_RETRIEVAL_PROMPT_ID;
            return $ua_fast->post_p(
                $url => { 'Content-Type' => 'text/plain; charset=UTF-8', Accept => '*/*' } => Encode::encode('UTF-8', $q)
            )->then(sub { return _decode_matches(shift) })
             ->catch(sub { my $e = shift; $self->app->log->warn("[ICD10 RETRIEVAL ERROR] '$q': $e"); return []; });
        };
        return $self->enqueue_patchbay_call($call, $q);
    };

    my $finalize = sub {
        my ($matches, $q) = @_;
        return Mojo::Promise->resolve(undef) unless ref $matches eq 'ARRAY' && @$matches;
        my $top = $self->_build_icd10_res($matches->[0], $q, undef, $opts);
        return Mojo::Promise->resolve(undef) unless $top;
        my $sim = _match_sim($matches->[0]) // 0;
        return Mojo::Promise->resolve($top) if !$rerank_enabled;
        # PATCH 2026-09-24: Bypass nur mit Label-Deckung
        if ($sim >= $rerank_accept_sim) {
            return Mojo::Promise->resolve($top) if $self->label_matches('icd10', $q, $top);
            $self->app->log->info("[ICD10 LABEL GATE] '$q' -> $top->{id} ($top->{label}) sim $sim, aber Label deckt Query nicht. Reranking.");
        }

        my @c = ($top);
        my $last = ($#$matches < $rerank_top_k - 1) ? $#$matches : $rerank_top_k - 1;
        for my $i (1 .. $last) {
            my $r = $self->_build_icd10_res($matches->[$i], $q, undef, { %$opts, quiet => 1 });
            push @c, $r if $r && !grep { $_->{id} eq $r->{id} } @c;
        }
        # PATCH 2026-09-25: gemeinsamer Elternknoten als broader-Kandidat, Flags für den Cache
        my $parent = $self->common_parent_candidate('icd10', \@c);
        push @c, $parent if $parent;
        return $self->rerank_candidates_async('icd10', $q, \@c, $opts->{context}, $opts);
    };

    # 4. Vektorsuche mit Fallback und abschließender Allergie-Anreicherung
    return $normalize->($primary_term)->then(sub {
        my $clean_query = shift;
        if (!defined $clean_query || $clean_query eq '__NONE__') {
            $self->app->log->info("[ICD10 NO CONCEPT] '$primary_term' enthält keine Diagnose.");
            return undef;
        }

        return $fetch_matches->($clean_query)->then(sub {
            my $m1   = shift // [];
            my $top  = $m1->[0];
            my $sim  = $top ? (_match_sim($top) // 0) : 0;
            my $dist = 1.0 - $sim;

            my $fb_clean = defined $fallback_term ? clean_term_for_vector_mapping($fallback_term) : '';

            if ($dist > 0.035 && length($fb_clean) > 1 && lc($fb_clean) ne lc($clean_query)) {
                $self->app->log->info("[ICD10 FALLBACK TRIGGERED] Dist $dist > 0.035 für '$clean_query'. Prüfe Fallback: '$fb_clean'");
                return $fetch_matches->($fb_clean)->then(sub {
                    my $m2 = shift // [];
                    my $fb_sim = $m2->[0] ? (_match_sim($m2->[0]) // 0) : 0;
                    return $finalize->($m2, $fb_clean) if $m2->[0] && (!$top || $fb_sim > $sim);
                    return $finalize->($m1, $clean_query);
                });
            }
            return $finalize->($m1, $clean_query);
        });
    })->then(sub {
        my $res = shift;
        return $apply_allergy_atc_override->($res);
    })->catch(sub {
        my $e = shift;
        $self->app->log->warn("[ICD10 MAPPING ERROR] '$verbatim_term': $e");
        return undef;
    });
};

# -------------------------------------------------------------------------
# Helper zur Auswertung & harten Unterdrückung (Cut-off bei Distanz > xxxx)
# -------------------------------------------------------------------------
helper _build_icd10_res => sub {
    my ($self, $match, $term, $max_allowed_dist, $opts) = @_;
    $opts //= {};
    my $quiet = $opts->{quiet} ? 1 : 0;
    my $log   = $self->app->log;

    # PATCH 2026-09-25: Grauzone wie bei den anderen Domänen
    $max_allowed_dist //= ($rerank_enabled && !$opts->{no_rerank}) ? ($rerank_gray_floor->{icd10} // 0.05) : 0.05;

    return undef unless $match && defined $match->{label};

    my $raw_code = $match->{label};
    $raw_code =~ s/^\s+|\s+$//g;
    my $dist_str = _extract_vector_dist_str($match);

    unless (is_plausible_code('icd10', $raw_code)) {
        $log->warn("[ICD10 INVALID INDEX ID]$dist_str '$term' -> '$raw_code' ist kein ICD-10-Code. Verworfen.") unless $quiet;
        return undef;
    }

    my $sim  = _match_sim($match);
    my $dist = defined $sim ? (1.0 - $sim) : 1.0;

    # HARTE UNTERDRÜCKUNG: Wenn der Treffer über dem Schwellenwert liegt
    if ($dist > $max_allowed_dist) {
        $log->warn("[ICD10 SUPPRESSED]$dist_str '$term' -> $raw_code überschreitet Max-Distanz ($dist > $max_allowed_dist). Diagnose wird unterdrückt.") unless $quiet;
        return undef;
    }

    my $matched_id    = $self->format_icd10_id($raw_code);
    # PATCH 2026-09-24: mit dem normalisierten Code nachschlagen und Phantomcodes verwerfen
    my $db_label      = $self->get_canonical_ontology_label('icd10', $matched_id);
    if ($icd_require_resolved && !defined $db_label) {
        $log->warn("[ICD10 UNRESOLVED]$dist_str '$term' -> $matched_id nicht in icd10_terms. Verworfen.") unless $quiet;
        return undef;
    }
    my $matched_label = $db_label // $match->{payload} // $term;

    # --- SCOPE-GUARD (Begriff und Verbatim-Kontext) ---
    if ($self->has_scope_conflict('icd10', $matched_id, $term)
        || (defined $opts->{context} && $self->has_scope_conflict('icd10', $matched_id, $opts->{context}))) {
        $log->warn("[ICD10 SCOPE CONFLICT]$dist_str '$term' -> $matched_id widerspricht der im Begriff genannten Anatomie. Verworfen.") unless $quiet;
        return undef;
    }

    # --- ANAMNESE-/BEOBACHTUNGSCODES ---
    # Der Index enthält Routinekodierungen wie "Meningeom -> Z87.8",
    # "Sepsis -> Z03.8", "ANA -> Z01.7", "Traktion -> Z98.8". Nur zulassen,
    # wenn die Zeile tatsächlich Vorgeschichte ist.
    if (defined $opts->{is_history} && !$opts->{is_history}
        && $matched_id =~ /^ICD10:Z(?:0[0-4]|8[5-7]|98)/i
        && $term !~ /\b(?:z\.?\s*n\.?|zustand\s+nach|anamnes\w*|vorgeschichte|history)\b/i) {
        $log->warn("[ICD10 BLOCKED] Anamnese-/Beobachtungscode $matched_id für aktuellen Befund '$term' abgewiesen.") unless $quiet;
        return undef;
    }

    # --- ANAMNESE-SAMMELCODES (PATCH 2026-09-25) ---
    # Z85–Z87 verlieren die eigentliche Erkrankung; die Vorgeschichte wird über onset/is_history abgebildet.
    if ($block_history_zcodes && $matched_id =~ /^ICD10:Z8[5-7]/i) {
        $log->warn("[ICD10 BLOCKED] Anamnese-Sammelcode $matched_id für '$term' abgewiesen (Erkrankung selbst kodieren).") unless $quiet;
        return undef;
    }

    # --- OKULÄRER PRIOR FÜR ICD-10 (PATCH 2026-09-25) ---
    # Bei okulärer Struktur ist ein nicht-okulärer Code ohne extraokuläres Signal
    # nur bei nahezu exaktem Treffer glaubhaft (Shieldulcus -> Ulcus ventriculi, Pannus -> Phlegmone).
    if ($ocular_prior_enabled && $icd_ocular_prior
        && defined $sim && $sim < $ocular_prior_min_sim
        && ($opts->{site} // '') !~ /^(?:systemic|none|)$/
        && $term !~ $EXTRAOCULAR_TERM_REGEX
        && !(defined $opts->{context} && $opts->{context} =~ $EXTRAOCULAR_TERM_REGEX)) {
        my $oc = $self->is_ocular_code('icd10', $matched_id);
        if (defined $oc && !$oc) {
            $log->warn("[ICD10 OCULAR PRIOR]$dist_str '$term' -> $matched_id ist nicht-okulär bei Struktur '$opts->{site}'. Verworfen.") unless $quiet;
        return undef;
    }
    }

    # --- TRAUMA-FILTER (S-Codes) ---
    if ($matched_id =~ /^ICD10:S/i) {
        my $is_trauma_term = ($term =~ /(?:trauma\w*|unfall\w*|verletz\w*|fraktur\w*|\bfx\b|trümmer\w*|luxation\w*|perforat\w*|ruptur\w*|prolaps\w*|h[äa]matom\w*|monokel\w*|ri[ßs]s?\w*|wunde\w*|quetsch\w*|prell\w*|fremdkörper\w*|kontusion\w*|sturz\w*|schnitt\w*|verätzung\w*|verbrennung\w*|erosio)/i);
        unless ($is_trauma_term) {
            $log->warn("[ICD10 BLOCKED] Trauma-Code $matched_id für nichttraumatischen Begriff '$term' abgewiesen.") unless $quiet;
            return undef;
        }
    }

    # --- AMPUTATIONS-FILTER (Z89-Codes abfangen) ---
    if ($matched_id =~ /^ICD10:Z89/i) {
        unless ($term =~ /\b(?:amputation|verlust\s+(?:finger|hand|fu[ßs]|zehe|gliedma[ßs]))\b/i) {
            $log->warn("[ICD10 BLOCKED] Amputations-Code $matched_id für '$term' abgewiesen.") unless $quiet;
            return undef;
        }
    }

    $log->info("[ICD10 RETRIEVAL]$dist_str '$term' -> $matched_id ($matched_label)") unless $quiet;
    return { id => $matched_id, label => $matched_label, sim => $sim,
             resolved => (defined $db_label ? 1 : 0), index_text => $match->{payload} };
};

helper map_to_ops_async => sub {
    my ($self, $term, $doc_lang, $opts) = @_;
    $opts //= {};
    return Mojo::Promise->resolve(undef) unless defined $term && length($term);

    if (my $hit = $self->check_database_intercept('ops', $term, $opts->{context})) {
        return Mojo::Promise->resolve(undef) if $hit->{suppress};
        $self->app->log->info("[OPS DB INTERCEPT] '$term' -> $hit->{id} ($hit->{label})");
        return Mojo::Promise->resolve($hit);
    }

    $doc_lang = lc($doc_lang // 'de');

    # Target: GERMAN ('de'). If doc is already German ('de'), skip translation!
    my $p_query = ($doc_lang eq 'de')
        ? Mojo::Promise->resolve(clean_term_for_vector_mapping($term))
        : $self->normalize_criterion_for_retrieval_async($term, 'ops');

    return $p_query->then(sub {
        my $clean_query = shift;
        if (!defined $clean_query || $clean_query eq '__NONE__') {
            $self->app->log->info("[OPS NO CONCEPT] '$term' enthält kein kodierbares Konzept.");
            return undef;
        }

        my $execute_call = sub {
            my $url_retrieve = "$patchbay_url/LLM/run_stateless/" . LLM_OPS_RETRIEVAL_PROMPT_ID;
            return $ua_fast->post_p(
                $url_retrieve => { 'Content-Type' => 'text/plain; charset=UTF-8', Accept => '*/*' } => encode('UTF-8', $clean_query)
            )->then(sub { return _decode_matches(shift) })
             ->catch(sub { my $e = shift; $self->app->log->warn("[OPS RETRIEVAL ERROR] '$clean_query': $e"); return []; });
        };

        return $self->enqueue_patchbay_call($execute_call, $clean_query)->then(sub {
            my $matches = shift;
            return $self->_select_vector_hit_async('ops', $matches, $clean_query, $opts);
        })->then(sub {
            my $res = shift;
            return undef unless $res;
            # Ein OPS-Code, der sich nicht in ops_terms auflösen lässt, ist ein
            # Phantomkode ("5-156.9Y (Tropf, RA: Triamcinolon)") und wird verworfen.
            unless ($res->{resolved}) {
                $self->app->log->warn("[OPS UNRESOLVED] '$clean_query' -> $res->{id} nicht in ops_terms. Verworfen.");
                return undef;
            }
            return $res;
        })->catch(sub { return undef; });
    });
};

helper map_to_atc_async => sub {
    my ($self, $term, $doc_lang, $opts) = @_;
    $opts //= {};
    return Mojo::Promise->resolve(undef) unless defined $term && length($term);

    my $clean_term = clean_atc_term($term);

    if (my $hit = $self->check_database_intercept('atc', $term) || $self->check_database_intercept('atc', $clean_term)) {
        return Mojo::Promise->resolve(undef) if $hit->{suppress};
        $self->app->log->info("[ATC DB INTERCEPT] '$term' -> $hit->{id} ($hit->{label})");
        return Mojo::Promise->resolve($hit);
    }

    $doc_lang = lc($doc_lang // 'de');
    my $search_payload = uc $clean_term;

    my $p_query = ($doc_lang eq 'de')
        ? Mojo::Promise->resolve(clean_term_for_vector_mapping($search_payload))
        : $self->normalize_criterion_for_retrieval_async($search_payload, 'atc');

    return $p_query->then(sub {
        my $clean_query = shift;
        if (!defined $clean_query || $clean_query eq '__NONE__') {
            $self->app->log->info("[ATC NO CONCEPT] '$term' enthält keinen Wirkstoff.");
            return undef;
        }

        my $execute_call = sub {
            my $url_retrieve = "$patchbay_url/LLM/run_stateless/" . LLM_ATC_RETRIEVAL_PROMPT_ID;
            return $ua_fast->post_p(
                $url_retrieve => { 'Content-Type' => 'text/plain; charset=UTF-8', Accept => '*/*' } => encode('UTF-8', $clean_query)
            )->then(sub { return _decode_matches(shift) })
             ->catch(sub { my $e = shift; $self->app->log->warn("[ATC RETRIEVAL ERROR] '$clean_query': $e"); return []; });
        };

        # Kein V03AX-Sammelcode mehr: kein Treffer -> undef.
        return $self->enqueue_patchbay_call($execute_call, $clean_query)->then(sub {
            my $matches = shift;
            return $self->_select_vector_hit_async('atc', $matches, $clean_query, $opts);
        })->catch(sub { return undef; });
    });
};

# Baut die LOINC-Vektorquery aus dem (übersetzten) Analytnamen.
# Früher wurde prepare_loinc_search_term ein zweites Mal mit Rohtext + Übersetzung
# aufgerufen ("Leukozyten 6,27 Tsd/µl Leukozyten Leukocyte count", sim 0.90).
sub build_loinc_payload_query {
    my ($prepared_term, $distilled) = @_;
    $prepared_term //= '';
    $distilled     //= '';
    return $prepared_term if $prepared_term =~ /^LOINC:/i;

    my ($eye) = $prepared_term =~ /^\s*((?:left|right)\s+eye)\b/i;
    my $core  = length($distilled) > 1 ? $distilled : $prepared_term;
    $core =~ s/^\s*(?:left|right)\s+eye\s+//i;
    $core = strip_lab_values($core);

    my $with_eye = $eye ? "$eye $core" : $core;
    # Die feste Zuordnungslogik greift jetzt auch auf den englischen Analytnamen,
    # aber ohne Rohtext, Werte oder Einheiten.
    my $p = prepare_loinc_search_term($with_eye, $core);
    return $p if $p =~ /^(?:LOINC:)?\d+-[\dA-Z]/i;   # PATCH 2026-10-22: auch 95327-A
    return strip_lab_values($p);
}

helper map_to_loinc_async => sub {
    my ($self, $term, $doc_lang, $opts) = @_;
    $opts //= {};
    return Mojo::Promise->resolve(undef) unless defined $term && length($term);
    return Mojo::Promise->resolve(undef) if $term =~ /unknown/i;

    # SOFORT-EXIT: Wenn der Term bereits ein aufgelöster LOINC-Code ist
    if ($term =~ /^(LOINC:\d+-\w*)\s*(.*)$/i) {
        return Mojo::Promise->resolve({ id => $1, label => ($2 || $term) });
    }

    if (my $hit = $self->check_database_intercept('loinc', $term)) {
        return Mojo::Promise->resolve(undef) if $hit->{suppress};
        $self->app->log->info("[LOINC DB INTERCEPT] '$term' -> $hit->{id} ($hit->{label})");
        return Mojo::Promise->resolve($hit);
    }

    $doc_lang = lc($doc_lang // 'de');

    my $p_query = ($doc_lang eq 'en')
        ? Mojo::Promise->resolve(clean_term_for_vector_mapping($term))
        : $self->normalize_criterion_for_retrieval_async($term, 'loinc');

    return $p_query->then(sub {
        my $distilled_query = shift;
        if (!defined $distilled_query || $distilled_query eq '__NONE__') {
            $self->app->log->info("[LOINC NO CONCEPT] '$term' enthält keinen Messparameter.");
            return undef;
        }

        my $loinc_payload_query = build_loinc_payload_query($term, $distilled_query);

        if ($loinc_payload_query =~ /^(LOINC:\d+-\w*)\s*(.*)$/i) {
            return { id => $1, label => ($2 || $loinc_payload_query) };
        }
        if (my $hit = $self->check_database_intercept('loinc', $loinc_payload_query)) {
            return undef if $hit->{suppress};
            $self->app->log->info("[LOINC DB INTERCEPT] '$loinc_payload_query' -> $hit->{id} ($hit->{label})");
            return $hit;
        }

        my $execute_call = sub {
            my $url_retrieve = "$patchbay_url/LLM/run_stateless/" . LLM_LOINC_RETRIEVAL_PROMPT_ID;
            return $ua_fast->post_p(
                $url_retrieve => { 'Content-Type' => 'text/plain; charset=UTF-8', Accept => '*/*' } => encode('UTF-8', $loinc_payload_query)
            )->then(sub { return _decode_matches(shift) })
             ->catch(sub { my $e = shift; $self->app->log->warn("[LOINC RETRIEVAL ERROR] '$loinc_payload_query': $e"); return []; });
        };

        return $self->enqueue_patchbay_call($execute_call, $loinc_payload_query)->then(sub {
            my $matches = shift;
            return $self->_select_vector_hit_async('loinc', $matches, $loinc_payload_query, $opts);
        })->catch(sub { return undef; });
    });
};

sub clean_atc_term {
    my ($term) = @_;
    return '' unless defined $term;

    my $clean = $term;

    # 3. Indikationen und Begründungen ab "bei", "wegen", "wg.", "nach", "für" bis zum Ende abschneiden
    # Beispiel: "Eliquis 1-0-1 bei . Mitralklappen-OP" -> "Eliquis 1-0-1"
    $clean =~ s/\b(?:bei|wegen|wg\.?|f[üu]r|nach|aufgrund|unter|indikation(?:\s*:)?)\b.*$//gi;

    # 4. Deutsches Dosierungsschema entfernen (z. B. "1-0-1", "1-0-0-0", "1/2-0-1/2", "0-0-1", "1 - 0 - 1")
    $clean =~ s/\b\d+(?:[\/\.,]\d+)?\s*-\s*\d+(?:[\/\.,]\d+)?\s*-\s*\d+(?:[\/\.,]\d+)?(?:\s*-\s*\d+)?\b//g;

    # 1. Section & Category prefixes entfernen (z. B. "Blutverdünnung: ASS" -> "ASS")
    $clean =~ s/^\s*(?:blutverdünnung|antikoagulation|dauermedikation|medikation|augentropfen|therapie|allergien?|unverträglichkeit(?:en)?)\s*:\s*/ /gi;

    # 2. Inhalt in Klammern komplett entfernen
    $clean =~ s/\([^)]*\)//g;

    # 3. Anzahlen & Frequenzen entfernen (z. B. "7x", "11x", "2 x", "3-mal", "5xtgl")
    $clean =~ s/\b\d+\s*x(?:\s*tgl\.?)?\b//gi;
    $clean =~ s/\b\d+\s*(?:mal|dosen|injektionen|spritzen|applikationen|flaschen|packungen|stk|stück)\b//gi;

    # 4. Zeit- und Datums-Phrasen entfernen
    $clean =~ s/\b(?:zuletzt|seit|am|ab|bis)\s+\d{1,2}[\.\/]\d{1,2}[\.\/]\d{2,4}\b//gi;
    $clean =~ s/\b(?:zuletzt|seit|am|ab|bis)\s+\d{4}\b//gi;
    $clean =~ s/\b(?:zuletzt|seit)\b.*$//gi;
    $clean =~ s/\b\d{1,2}[\.\/]\d{1,2}[\.\/]\d{2,4}\b//g;
    $clean =~ s/\b\d{1,2}\/\d{2,4}\b//g;

    # 5. Führende/nachfolgende Sonderzeichen säubern
    $clean =~ s/^\s*[:\-\>\#\*\.]+//g;
    $clean =~ s/\s+/ /g;
    $clean =~ s/^\s+|\s+$//g;
    $clean =~ s/^z\.\s*n\.?//ig;

    # Darreichungsformen und Zusätze entfernen, die den Wirkstoff-Vektor verfälschen
    $clean =~ s/\b(?:augentropfen|augensalbe|augengel|tropfen|salbe|gel|at|as|edo|sine|ophtiole\w*)\b//gi;

    return length($clean) > 1 ? $clean : $term;
}


# =========================================================================
# UNIVERSELLES KLINISCHES & STUDIEN-CHUNKING (PHENOPACKET & FHIR SAFE)
# =========================================================================
sub split_into_clinical_section_chunks {
    my ($text, $target_chunk_chars) = @_;
    $target_chunk_chars //= 1100; # Optimale Zielgröße für ophthalmologische Kohärenz

    return () unless defined $text && length($text);

    # 0. SCHRITT: HTML-Tags, Entitäten und Whitespace-Noise bereinigen
    $text =~ s/<\/?[a-zA-Z][^>]*>/ /g;
    $text =~ s/&nbsp;/ /g;
    $text =~ s/&amp;/&/g;
    $text =~ s/\r//g;

    # 1. SCHRITT: Lateralitäts-Präfixe/-Suffixe (RA, LA, BA, OD, OS, OU, R, L, B)
    my $lat_pattern = qr/(?:\s+(?:[rlb]|ra|la|ba|od|os|ou|rechts?|links?|beidseits))/i;

    # 2. SCHRITT: Vollständiger ophthalmologischer & klinischer Header-Regex
    my $header_pattern = qr{(?:
        (?:inclusion(?:\s+criteria)?|einschluss(?:kriterien)?|key\s+inclusion)|
        (?:exclusion(?:\s+criteria)?|ausschluss(?:kriterien)?|key\s+exclusion)|
        (?:study\s+eye(?:\s+criteria)?|fellow\s+eye(?:\s+criteria)?|studienauge|partnerauge)|
        (?:general\s+criteria|allgemeine\s+kriterien|safety\s+criteria)|
        (?:diagnosen?|anamnese|ivom(?:[\s\-]anamnese)?|therapie|aktuelle\s+(?:ophthalmologische\s+)?therapie|lokaltherapie|medikation|dauermedikation|systemmedikation|blutverd[üu]nnung|vorgeschichte|allgemein(?:erkrankungen(?:\/medikation)?)?|allergien?)$lat_pattern?|
        (?:visus|refraktion|skiaskopie|brille|fernvisus|nahvisus|orthoptik|binokularsehen|motilit[äa]t|stereosehen|tensio|druck|tonometrie|icare|goldmann|pachymetrie|cct|pentacam|topographie|octopus(?:-gf)?|gf|gesichtsfeld|perimetrie|hertel|iol[\s\-]?master|biometrie|endothel(?:zell\w*)?|ecd|ezd)$lat_pattern?|
        (?:vaa|vorderabschnitt|spaltlampe|hornhaut|cornea|fundus|papille|makula|macula|nh[\s\-]oct|rnfl(?:[\s\-]oct)?|oct|bmo[\s\-]oct|gcl(?:[\s\-]oct)?|vaa[\s\-]oct|fag|fla|fl[\s\-]angio|angiograph\w*)$lat_pattern?|
        (?:lebensalter|geschlecht|alter|befund|prozeduren?|operationen?|orderheute|bemerkungen)
    )\s*[:=]}ix;

    # 3. SCHRITT: Zeilenumbrüche vor jedem erkannten Header sicherstellen
    $text =~ s/(?:^|(?<=[\n\r])|(?<=[.;]\s))($header_pattern)/\n$1/g;

    my @lines = split /\n/, $text;
    my @sections;
    my $current_section_header = "";
    my $current_section_body   = "";

    foreach my $line (@lines) {
        my $trimmed = $line;
        $trimmed =~ s/^\s+|\s+$//g;
        next unless length($trimmed);

        if ($trimmed =~ /^$header_pattern/i) {
            if (length($current_section_body)) {
                push @sections, {
                    header => $current_section_header,
                    text   => $current_section_body
                };
            }
            $current_section_header = ($trimmed =~ /^([^:=]+[:=])/)[0] // "Section:";
            $current_section_body   = $trimmed;
        } else {
            if (length($current_section_body)) {
                $current_section_body .= "\n" . $trimmed;
            } else {
                $current_section_body = $trimmed;
            }
        }
    }
    push @sections, { header => $current_section_header, text => $current_section_body } if length($current_section_body);

    # 4. SCHRITT: Lateralitäts-Kontext injizieren & Chunks mit Anti-Split bündeln
    my @chunks;
    my $current_chunk = "";

    foreach my $sec (@sections) {
        my $sec_header = $sec->{header};
        my $sec_text   = $sec->{text};

        # Header auf okuläre Lateralitäts-Kennzeichnung untersuchen
        my $header_lat = undef;
        if ($sec_header =~ /\b(?:L|LA|OS|links?)\b/i || $sec_header =~ /\s+[lL]\s*[:=]/) {
            $header_lat = "LEFT EYE (LA/OS)";
        } elsif ($sec_header =~ /\b(?:R|RA|OD|rechts?)\b/i || $sec_header =~ /\s+[rR]\s*[:=]/) {
            $header_lat = "RIGHT EYE (RA/OD)";
        } elsif ($sec_header =~ /\b(?:B|BA|OU|beidseits|bilateral)\b/i || $sec_header =~ /\s+[bB]\s*[:=]/) {
            $header_lat = "BILATERAL (BA/OU)";
        }

        # Wenn der Abschnitt ein spezifisches Auge betrifft, Kontext-Direktive voranstellen
        if ($header_lat) {
            $sec_text = "[ANATOMICAL LATERALITY FOR THIS ENTIRE SECTION: $header_lat]\n" . $sec_text;
        }

        # -----------------------------------------------------------------
        # OPHTHALMISCHE ANTI-SPLIT-REGEL:
        # Rechter und linker Befund derselben Untersuchung gehören ZWINGEND zusammen!
        # (Verhindert, dass Visus L von Visus R getrennt wird)
        # -----------------------------------------------------------------
        my $must_stay_together = 0;
        if ($current_chunk =~ /\b(visus|tensio|endothel|pachymetrie|pentacam|nh[\s\-]oct|vaa)\s*r\b/i &&
            $sec_header    =~ /\b(visus|tensio|endothel|pachymetrie|pentacam|nh[\s\-]oct|vaa)\s*l\b/i) {
            $must_stay_together = 1;
        }

        # Sektionen bis zur Zielgröße zusammenfassen
        if (!$must_stay_together && (length($current_chunk) + length($sec_text) + 2 > $target_chunk_chars) && length($current_chunk) > 0) {
            push @chunks, $current_chunk;
            $current_chunk = $sec_text;
        } else {
            $current_chunk .= ($current_chunk ne "" ? "\n\n" : "") . $sec_text;
        }
    }
    push @chunks, $current_chunk if length($current_chunk) > 0;

    return @chunks;
}

# =========================================================
# HELPER: CONVERT LLM LATERALITY TO VALID SNOMED BODY STRUCTURE
# =========================================================
helper get_laterality_snomed_object => sub {
    my $self = shift if ref $_[0];
    my ($lat_str, $text_context) = @_;

    # 1. Wenn die Lateraliät explizit 'none' oder nicht definiert ist -> Kein Code
    return undef unless defined $lat_str && $lat_str ne '' && lc($lat_str) ne 'none';

    # 2. Direkter Match aus der LLM-Analyse (Gültige SNOMED Body Structure IDs)
    my $l = lc($lat_str);
    if ($l eq 'right') {
        return { id => "SNOMED:18944008", label => "Right eye structure" };
    }
    elsif ($l eq 'left') {
        return { id => "SNOMED:8966001", label => "Left eye structure" };
    }
    elsif ($l eq 'bilateral') {
        # Zusätzlicher Sicherheits-Check: Systemische Erkrankungen herausfiltern
        if (defined $text_context && $text_context =~ /\b(?:crohn|mamma|karzinom|hypertens|hypertonie|thyreoiditis|hashimoto|diabetes|cholesterin|stent|bypass|prostata|asthma|copd)\b/i) {
            return undef; # Verhindert "Structure of both eyes" bei M. Crohn, Mamma-Ca etc.
        }
        return { id => "SNOMED:40638003", label => "Structure of both eyes" };
    }

    # 3. Textkontext-Fallback (falls LLM-Lateraliät unvollständig)
    if (defined $text_context && ref $text_context eq '' && $text_context ne '') {
        if ($text_context =~ /\b(?:RA|OD|VAA RA|Fundus RA|oculus dexter|rechtes? auge|rechte eye)\b/i) {
            return { id => "SNOMED:18944008", label => "Right eye structure" };
        }
        elsif ($text_context =~ /\b(?:LA|OS|VAA LA|Fundus LA|oculus sinister|linkes? auge|left eye)\b/i) {
            return { id => "SNOMED:8966001", label => "Left eye structure" };
        }
        elsif ($text_context =~ /\b(?:VAA BA|Fundus BA|Lidspaltenweite BA|Schirmer BA|Tensio BA|Augen BA)\b/i) {
            return { id => "SNOMED:40638003", label => "Structure of both eyes" };
        }
    }

    return undef;
};

helper get_laterality_hpo_object => sub {
    my $self = shift if ref $_[0];
    my ($lat_str, $text_context) = @_;

    # 1. Wenn die Lateraliät explizit 'none' oder nicht definiert ist -> Kein Code
    return undef unless defined $lat_str && $lat_str ne '' && lc($lat_str) ne 'none';

    # Kardiologische & vaskuläre Befunde dürfen NIEMALS eine Augenlateralität erhalten:
    if (defined $text_context && $text_context =~ /\b(?:ramus|marginalis|circumflexus|riv|rcx|rca|lad|stent|stenose|koronar|bypass|carotis|femoralis)\b/i) {
        return undef;
    }

    # 2. Direkter Match aus der LLM-Analyse (HPO Laterality Modifiers)
    my $l = lc($lat_str);
    if ($l eq 'right') {
        return { id => "HP:0012834", label => "Right" };
    }
    elsif ($l eq 'left') {
        return { id => "HP:0012835", label => "Left" };
    }
    elsif ($l eq 'bilateral') {
        # Zusätzlicher Sicherheits-Check: Systemische Erkrankungen herausfiltern
        if (defined $text_context && $text_context =~ /\b(?:crohn|mamma|karzinom|hypertens|hypertonie|thyreoiditis|hashimoto|diabetes|cholesterin|stent|bypass|prostata|asthma|copd)\b/i) {
            return undef; # Verhindert "Bilateral" bei M. Crohn, Mamma-Ca etc.
        }
        return { id => "HP:0012832", label => "Bilateral" };
    }

    # 3. Textkontext-Fallback (falls LLM-Lateraliät unvollständig)
    if (defined $text_context && ref $text_context eq '' && $text_context ne '') {
        if ($text_context =~ /\b(?:RA|OD|VAA RA|Fundus RA|oculus dexter|rechtes? auge|rechte eye)\b/i) {
            return { id => "HP:0012834", label => "Right" };
        }
        elsif ($text_context =~ /\b(?:LA|OS|VAA LA|Fundus LA|oculus sinister|linkes? auge|left eye)\b/i) {
            return { id => "HP:0012835", label => "Left" };
        }
        elsif ($text_context =~ /\b(?:VAA BA|Fundus BA|Lidspaltenweite BA|Schirmer BA|Tensio BA|Augen BA)\b/i) {
            return { id => "HP:0012832", label => "Bilateral" };
        }
    }

    return undef;
};

# =========================================================
# DYNAMIC DATABASE PROMPT & FILTER LOADERS WITH IN-MEMORY CACHE
# =========================================================
helper get_llm_prompt => sub {
    my ($self, $name) = @_;
    state $prompt_cache = {};
    state $last_fetch   = {};

    my $now = time;
    if (!$last_fetch->{$name} || ($now - $last_fetch->{$name} > 30)) {
        eval {
            my $row = $self->pg->db->query(
                "SELECT name, system_prompt, user_template FROM public.llm_prompts WHERE name = ? AND active = TRUE",
                $name
            )->hash;
            $prompt_cache->{$name} = $row;
            $last_fetch->{$name}   = $now;
        };
        if ($@) {
            $self->app->log->error("[PROMPT DB ERROR] Failed to load prompt '$name': $@");
        }
    }
    return $prompt_cache->{$name};
};

helper get_filter_rules => sub {
    my ($self) = @_;
    state $rules_cache = {};
    state $last_fetch  = 0;

    my $now = time;
    if (!$last_fetch || ($now - $last_fetch > 30)) {
        eval {
            my $rows = $self->pg->db->query(
                "SELECT category, pattern, action, priority FROM public.filter_rules WHERE active = TRUE ORDER BY priority ASC, id ASC"
            )->hashes->to_array;

            my %grouped;
            for my $r (@$rows) {
                push @{$grouped{$r->{category}}}, $r;
            }
            $rules_cache = \%grouped;
            $last_fetch  = $now;
        };
        if ($@) {
            $self->app->log->error("[FILTER RULES DB ERROR] Failed to load filter rules: $@");
        }
    }
    return $rules_cache // {};
};

# =========================================================
# DETERMINISTIC NORMAL FINDINGS & UNCODABLE RULES (DB-ONLY)
# =========================================================
helper is_normal_physiological_finding => sub {
    my ($self, $text) = @_;
    if (!ref($self) && defined($text) && !defined($_[2])) {
        $text = $self;
        $self = app();
    }
    return 0 unless defined $text && length($text);
    $text =~ s/^\s+|\s+$//g;

    my $rules = eval { $self->get_filter_rules() } // {};

    # 1. Safeguards: Dürfen NIEMALS gefiltert werden
    for my $cat ('safeguard_pathology', 'safeguard_procedure') {
        for my $rule (@{$rules->{$cat} // []}) {
            my $pat = $rule->{pattern};
            return 0 if eval { $text =~ qr/$pat/i };
        }
    }

    # 2. Normalbefunde: Werden gefiltert
    for my $rule (@{$rules->{normal_finding} // []}) {
        my $pat = $rule->{pattern};
        return 1 if eval { $text =~ qr/$pat/i };
    }

    return 0;
};

# =========================================================
# STEP 1: ATOMIC EXTRACTION WITH LANGUAGE DETECTION
# =========================================================
# =========================================================
# DETERMINISTISCHE VERANKERUNG KANONISCHER BEGRIFFE (Prompt-Regel 3.1)
# Nackte Morphologie-Nomen werden mit der vom LLM gelieferten Struktur
# ergänzt ("Narbe" + cornea -> "Narbe der Hornhaut") oder verworfen.
# =========================================================
our %SITE_GENITIVE = (
    eyelid => 'des Augenlides', conjunctiva => 'der Bindehaut', cornea => 'der Hornhaut',
    sclera => 'der Sklera', anterior_chamber => 'der Vorderkammer', iris => 'der Iris',
    lens => 'der Linse', vitreous => 'des Glaskörpers', retina => 'der Netzhaut',
    macula => 'der Makula', choroid => 'der Aderhaut', optic_disc => 'der Papille',
    orbit => 'der Orbita', lacrimal => 'der Tränenwege', visual_field => 'des Gesichtsfeldes',
    ocular_motility => 'der Augenmotilität', ocular_other => 'des Auges',
);

our $BARE_NOUN_REGEX = qr/^(?:ausdünnung|verdünnung|ansammlung|filtration|infiltrat(?:e|ion)?|transplantat|aneurysma|ulcus|ulkus|narben?|knoten|delle|falten?|ödem|oedem|pigment|zellen?|blutung(?:en)?|perforation|dehiszenz|degeneration|einziehung|implantat|stent|schleimauflagerung|kerbe|ring|konus|haze|reizung|reiz|defekte?|entzündung|aktivität|staining|foramen|foramina|aufhellung(?:en)?|verdichtung(?:en)?|atrophie|läsion(?:en)?|schwellung|zysten?|verkalkung|trübung(?:en)?|granulom(?:e)?|traktion|restflüssigkeit|flüssigkeit|exsudation|exsudat(?:e)?|leckage|glitzern|abschattung|verhärtung|neovaskularisation|membran|nekrose|ischämie|tortuosität|teleangiektasien?|avaskularität|rötung|schleim|restblut|beschläge?|ablagerung(?:en)?|spaltbildung)$/i;

our $NO_CONCEPT_REGEX = qr/^(?:befund|zustand|einblick|untersuchbarkeit|beurteilbarkeit|fehlmessung|messfehler|artefakt|duplikatur|befestigung|ansatz)$/i;

our $DOSAGE_FORM_REGEX = qr/^(?:salbe|augensalbe|tropfen|augentropfen|gel|augengel|at|as|edo|sine|creme|spray|tabletten?|kapseln?|spritze|infusion)$/i;

sub ground_canonical_term {
    my ($item, $log) = @_;
    my $domain = lc($item->{domain} // '');
    return 1 if $domain eq 'demographic';

    my $ct = $item->{canonical_term} // '';
    (my $core = $ct) =~ s/^\s+|\s+$//g;
    return 1 unless length $core;

    if ($domain eq 'atc' && $core =~ $DOSAGE_FORM_REGEX) {
        $log->info("[UNGROUNDED ROW DROPPED] Darreichungsform ohne Wirkstoff: '$ct'");
        return 0;
    }

    (my $probe = $core) =~ s/^(?:(?:alte[rsn]?|kleine[rsn]?|große[rsn]?|zentrale[rsn]?|periphere[rsn]?|multiple|diffuse[rsn]?|frische[rsn]?|einzelne|vereinzelte|dezente[rsn]?|milde[rsn]?)\s+)+//i;

    if ($probe =~ $NO_CONCEPT_REGEX) {
        $log->info("[UNGROUNDED ROW DROPPED] Kein kodierbares Konzept: '$ct'");
        return 0;
    }

    return 1 if $core =~ /^(?:blepharitis|konjunktivitis|keratitis|uveitis|skleritis|episkleritis|retinitis|chorioiditis|neuritis\s+nervi\s+optici)$/i;

    # Schutz vor isolierten Ätiologie-Fragmenten aus Differentialdiagnosen (z.B. "DD Nekrose", "DD entzündlich")
    if ($domain eq 'icd10' && $core =~ /^(?:nekrose|entzündlich|postradiogen|strahlenschaden)$/i) {
        my $site_chk = lc($item->{anatomical_site} // '');
        if ($site_chk =~ /^(?:systemic|none)$/) {
            $log->info("[ETIOLOGY FRAGMENT DROPPED] Isolierter Ätiologie-Begriff '$ct' ohne Organbezug verworfen.");
            return 0;
        }
    }
    unless ($probe =~ $BARE_NOUN_REGEX) {
        # PATCH 2026-09-25: generische Verankerung. Okuläre Struktur, aber kein okuläres
        # Signal im Begriff ("Pannus", "Shieldulcus", "Hypotonie") -> Organ anhängen.
        my $site_g = lc($item->{anatomical_site} // '');
        my $lang   = lc($item->{_doc_lang} // 'de');
        if ($ground_generic && $lang eq 'de' && $domain =~ /^(?:hpo|icd10)$/
            && (my $gen = $SITE_GENITIVE{$site_g})
            && $core !~ $OCULAR_TERM_REGEX
            && $core !~ $EXTRAOCULAR_TERM_REGEX
            && $core !~ /\b(?:des|der|am|an|im)\b/i) {
            $item->{canonical_term} = "$core $gen";
            $log->info("[CANONICAL GROUNDED] '$ct' -> '$item->{canonical_term}' (generisch, site=$site_g)");
        }
        return 1;
    }

    my $site = lc($item->{anatomical_site} // '');
    if (my $gen = $SITE_GENITIVE{$site}) {
        $item->{canonical_term} = "$core $gen";
        $log->info("[CANONICAL GROUNDED] '$ct' -> '$item->{canonical_term}'");
        return 1;
    }
    return 1 if $site eq 'systemic';   # systemische Befunde bleiben systemisch

    $log->info("[UNGROUNDED ROW DROPPED] '$ct' ohne anatomische Struktur (site='$site')");
    return 0;
}
helper extract_atomic_criteria_async => sub {
    my ($self, $text, $mode, $client_model, $deep_mode, $task_id) = @_;
    $mode //= 'fhir';
    $deep_mode = to_bool($deep_mode);

    my $mode_context     = "";
    my $filtration_rule  = "";

    # KIS-Scripting und Makros bereinigen
    $text =~ s/\bscripting\s*:.*?(?=\n\n|\Z)//is;
    $text =~ s/\bOrderHeute\([^)]*\);?//gi;
    $text =~ s/\b(?:Makro|Script|Template)\s*:\s*[^\n]+//gi;
    $text =~ s/<br\s*\/?>/\n/gi;
    $text =~ s/<\/(?:p|div|tr|li|h\d+)>/ \n/gi;
    $text =~ s/<[^>]+>/ /g;
    $text =~ s/&nbsp;/ /g;
    $text =~ s/&amp;/&/g;
    $text =~ s/<\/?[a-zA-Z][^>]*>/ /g;
    $text =~ s/([^\.\s])\s*\n(?=\s*\p{Lu})/$1. \n/g; # newline mit neuem absatz, ohne punkt->LLM fuegt das sonst zusammen.

    $text =~ s/\bRZA\b/Riesenzellarteriitis (RZA)/g;
    $text =~ s/\bAAION\b/Arteriitische anteriore ischämische Optikusneuropathie (AAION)/g;
    $text =~ s/\bNAION\b/Nicht-arteriitische anteriore ischämische Optikusneuropathie (NAION)/g;
    $text =~ s/\bPDR\b/Proliferative diabetische Retinopathie (PDR)/g;
    $text =~ s/\bNPDR\b/Nicht-proliferative diabetische Retinopathie (NPDR)/g;
    $text =~ s/\b[CZ]PK\b/Zyklophotokoagulation (ZPK)/g;

    if ($mode eq 'phenopacket') {
        $mode_context = qq|
    TASK CONTEXT: PATIENT MEDICAL RECORD EXTRACTION
    - Set 'is_exclusion': false for active, present clinical findings, confirmed diagnoses, performed procedures, or active medications.
    - Set 'is_exclusion': true for explicitly denied, ruled-out, or absent findings/diseases.|;
        $filtration_rule = 'SKIP NORMAL PHYSIOLOGICAL FINDINGS. Always extract Age and Sex into domain: "demographic" whenever present in the text. NEVER omit them!';
    } else {
        $mode_context = qq|
    TASK CONTEXT: CLINICAL TRIAL ELIGIBILITY CRITERIA EXTRACTION
    - Set 'is_exclusion': false for inclusion criteria.
    - Set 'is_exclusion': true for exclusion criteria.|;
        $filtration_rule = 'SKIP PROSPECTIVE / FUTURE CRITERIA / ADMINISTRATIVE NOISE.';
    }

    # 1. Haupt-Extraktions-Prompt aus der Datenbank laden
    my $prompt_record = $self->get_llm_prompt('atomic_criteria_extraction');
    unless ($prompt_record && $prompt_record->{system_prompt}) {
        $self->app->log->error("[PROMPT ERROR] Missing active 'atomic_criteria_extraction' in database.");
        return Mojo::Promise->reject("Database prompt 'atomic_criteria_extraction' not found.");
    }

    my $sys_instruction = $prompt_record->{system_prompt};
    $sys_instruction =~ s/\{\{mode_context\}\}/$mode_context/g;
    $sys_instruction =~ s/\{\{filtration_rule\}\}/$filtration_rule/g;
    my $user_template = $prompt_record->{user_template} // "Chunk {{chunk_idx}} of {{total_chunks}}: Extract criteria.";

    # 2. Tabellen-/Reasoning-Prompt aus der Datenbank laden (nur bei deep_mode)
    my ($reasoning_sys_prompt, $reasoning_user_template);
    if ($deep_mode) {
        my $reasoning_rec = $self->get_llm_prompt('atomic_criteria_reasoning');
        if ($reasoning_rec && $reasoning_rec->{system_prompt}) {
            $reasoning_sys_prompt = $reasoning_rec->{system_prompt};
            $reasoning_sys_prompt =~ s/\{\{mode_context\}\}/$mode_context/g;
            $reasoning_sys_prompt =~ s/\{\{filtration_rule\}\}/$filtration_rule/g;
            $reasoning_user_template = $reasoning_rec->{user_template} // $user_template;
        } else {
            $self->app->log->warn("[PROMPT WARN] 'atomic_criteria_reasoning' in DB nicht gefunden oder inaktiv.");
        }
    }

    my @chunks = split_into_clinical_section_chunks($text, 900);
    my $total_chunks = scalar(@chunks);
    my @chunk_promises;

    my $total_llm_calls = $total_chunks * ($deep_mode ? 2 : 1);
    my $completed_llm_calls = 0;

    $self->app->log->info("[STEP 1 ATOMIZATION] Text in $total_chunks Chunks ($total_llm_calls Calls, Deep Mode: " . ($deep_mode ? "ON" : "OFF") . ")");

    my $chunk_idx = 1;
    foreach my $current_chunk (@chunks) {
        my $c_num = $chunk_idx;
        $chunk_idx++;

        my $user_prompt = $user_template;
        $user_prompt =~ s/\{\{chunk_idx\}\}/$c_num/g;
        $user_prompt =~ s/\{\{total_chunks\}\}/$total_chunks/g;

        my $p_chunk;
        if ($deep_mode) {
            my $r_prompt = $reasoning_user_template // $user_template;
            $r_prompt =~ s/\{\{chunk_idx\}\}/$c_num/g;
            $r_prompt =~ s/\{\{total_chunks\}\}/$total_chunks/g;
            $r_prompt =~ s/\{\{chunk_text\}\}/$current_chunk/g;

            # Stufe 1A: Reines Denken / Markdown-Tabelle (Prompt komplett aus DB)
            $p_chunk = $self->generate_reasoning_trace_async(
                $current_chunk,
                $r_prompt,
                $client_model,
                $reasoning_sys_prompt
            )->then(sub {
                my $reasoning_trace = shift;
                $completed_llm_calls++;
                my $pct = int(5 + ($completed_llm_calls / $total_llm_calls) * 45);
                $self->notify_task_progress($task_id, 'llm1', $pct, "Reasoning Chunk $c_num/$total_chunks ($pct%)...");

                my $augmented_input = qq{ORIGINAL CLINICAL TEXT:
------------------------
$current_chunk

CLINICAL REASONING, RULES ALIGNMENT & PRE-EXTRACTION TABLE:
------------------------
$reasoning_trace
};

                # Stufe 1B: Grammar-Sampling (Original-Prompt aus DB + Originaltext + Voranalyse-Tabelle)
                return $self->extract_structured_data_async(
                    $augmented_input,
                    $atomic_criteria_schema,
                    $sys_instruction,
                    $user_prompt,
                    $client_model
                )->then(sub {
                    my $parsed_res = shift;
                    $completed_llm_calls++;
                    my $pct_sub = int(5 + ($completed_llm_calls / $total_llm_calls) * 45);
                    $self->notify_task_progress($task_id, 'llm1', $pct_sub, "Extraktion Chunk $c_num/$total_chunks ($pct_sub%)...");
                    return $parsed_res;
                });
            });
        } else {
            # Standard ohne Deep Mode: Direkter Grammar-Aufruf
            $p_chunk = $self->extract_structured_data_async(
                $current_chunk,
                $atomic_criteria_schema,
                $sys_instruction,
                $user_prompt,
                $client_model
            )->then(sub {
                my $parsed_res = shift;
                $completed_llm_calls++;
                my $pct = int(5 + ($completed_llm_calls / $total_llm_calls) * 45);
                $self->notify_task_progress($task_id, 'llm1', $pct, "Extraktion Chunk $c_num/$total_chunks ($pct%)...");
                return $parsed_res;
            });
        }

        push @chunk_promises, $p_chunk;
    }

    return Mojo::Promise->all(@chunk_promises)->then(sub {
        my @res_list = map { $_->[0] } @_;
        my @all_criteria;
        my $detected_lang = 'de';

        foreach my $res (@res_list) {
            my $crit_list = [];
            if (ref $res eq 'HASH') {
                $detected_lang = lc($res->{document_language}) if defined $res->{document_language} && $res->{document_language} =~ /^(de|en|other)$/i;
                $crit_list = $res->{criteria} // [];
            } elsif (ref $res eq 'ARRAY') {
                $crit_list = $res;
            }

            foreach my $item (@$crit_list) {
                next unless ref $item eq 'HASH';

                my $v = $item->{verbatim_text}
                     // $item->{matching_string}
                     // $item->{text}
                     // $item->{verbatim}
                     // '';

                $item->{verbatim_text} = $v;

                # DEMOGRAFIE-SCHUTZ: Alter und Geschlecht NIEMALS als unkodierbar verwerfen!
                my $is_demo = (
                    ($item->{domain} // '') eq 'demographic'
                    || ($item->{demographic_type} // '') =~ /^(?:age|sex)$/i
                    || $v =~ /\b(?:lebensalter|geschlecht)\b/i
                ) ? 1 : 0;

                unless ($is_demo) {
                    my $ct = $item->{canonical_term} // '';
                    if ((length($ct) && $self->is_uncodable_or_future_rule($ct))
                        || (length($v) && $self->is_uncodable_or_future_rule($v))) {
                        $self->app->log->info("[UNCODABLE / ADMINISTRATIVE RULE FILTERED] '$v' (Term: '$ct')");
                        next;
                    }

                    if ((length($ct) && $self->is_normal_physiological_finding($ct))
                        || (length($v) && $self->is_normal_physiological_finding($v))) {
                        $self->app->log->info("[NORMAL PHYSIOLOGICAL FINDING FILTERED] '$v'");
                        next;
                    }
                }
                if (defined $item->{disjunction_group_id} && $item->{disjunction_group_id} =~ /^(?:none|null|n\/?a|0|\s*)$/i) {
                    $item->{disjunction_group_id} = '';
                }

                # PATCH 2026-09-25: Dokumentsprache für die generische Verankerung
                $item->{_doc_lang} = (ref $res eq 'HASH') ? lc($res->{document_language} // 'de') : 'de';
                next unless ground_canonical_term($item, $self->app->log);

                push @all_criteria, $item;
            }
        }

        $self->app->log->info("[STEP 1 ATOMIZATION] Processed $total_chunks chunk(s). Language: '$detected_lang'. Extracted " . scalar(@all_criteria) . " atomic criteria rows.");
        return {
            language => $detected_lang,
            criteria => \@all_criteria
        };
    });
};

# =========================================================
# UNIVERSELLER DATUMS- & ZEIT-PARSER
# =========================================================
sub extract_event_date {
    my ($text, $ref_date_str) = @_;
    return undef unless defined $text && $text ne '';

    # Vergleichs- und Vorbefundsfloskeln maskieren
    my $clean_date_text = $text;
    $clean_date_text = mask_measurement_numbers($clean_date_text);
    $clean_date_text =~ s/\b(?:stabil\s+(?:zu|ggü\.?|gegenüber)|progredient\s+(?:zu|ggü\.?|gegenüber)|(?:im\s+)?vergleich\s+zu|vgl\.?\s*zu|kontrolle\s+zu|vorbefund(?:\s+vom)?)\s*(?:(?:0?[1-9]|1[0-2])[\/\.](?:19|20)?\d{2}|(?:19|20)\d{2})\b/ /gi;

    # PRIORITÄT: Deutsches Format DD.MM.YY (z. B. "05.09.26") ZUERST prüfen,
    # um zu verhindern, dass LLMs "05.09.26" fälschlich zu "2005-09-26" machen!
    if ($clean_date_text =~ /\b([0-3]?\d)\.([0-1]?\d)\.(\d{2})\b/) {
        my ($d, $m, $y) = ($1, $2, $3 + 0);
        my $full_year = ($y < 70) ? (2000 + $y) : (1900 + $y);
        return sprintf("%04d-%02d-%02d", $full_year, $m, $d);
    }

    # 0. Bereits ISO
    if ($clean_date_text =~ /\b((?:19|20)\d{2}-[0-1]\d-[0-3]\d)\b/) { return $1; }
    if ($clean_date_text =~ /\b((?:19|20)\d{2}-[0-1]\d)\b/)         { return $1; }

    # 1. Vollständiges deutsches Datum: DD.MM.YYYY
    if ($clean_date_text =~ /\b([0-3]?\d)\.([0-1]?\d)\.((?:19|20)\d{2})\b/) {
        return sprintf("%04d-%02d-%02d", $3, $2, $1);
    }

    # 2. Monat / Jahr (MM/YYYY)
    if ($clean_date_text =~ /\b(0?[1-9]|1[0-2])[\/\.]((?:19|20)\d{2})\b/) {
        return sprintf("%04d-%02d", $2, $1);
    }
    # 2b. Monat / zweistelliges Jahr (M/YY oder MM/YY), z.B. "8/21", "09/21", "10/13"
    if ($clean_date_text =~ /\b(0?[1-9]|1[0-2])\/(\d{2})\b/) {
        my ($m, $y) = ($1, $2 + 0);
        my $full_year = ($y < 70) ? (2000 + $y) : (1900 + $y);
        return sprintf("%04d-%02d", $full_year, $m);
    }
    # 3. Vierstelliges Einzeljahr (19xx oder 20xx)
    if ($clean_date_text =~ /\b((?:19|20)\d{2})\b/) {
        return sprintf("%04d", $1);
    }

    # 4. Relative Zeitangaben auflösen (z.B. "vor über 20 Jahre", "vor ca. 3 Monaten")
    if ($clean_date_text =~ /\b(?:vor|seit)\s+(?:über|mehr\s+als|knapp|ca\.?|etwa)?\s*(\d+)\s*(tage?n?|wochen?|monate?n?|jahre?n?|d|wk|mo|y)\b/i) {
        return calculate_absolute_date($ref_date_str, "$1 $2");
    }

    if ($clean_date_text =~ /\b(?:ED|EM|Erstdiagnose|Erstmanifestation)\s*:?\s*(0?[1-9]|1[0-2])[\/\.](\d{2})\b/i) {
        my ($m, $y) = ($1, $2 + 0);
        my $full_year = ($y < 70) ? (2000 + $y) : (1900 + $y);
        return sprintf("%04d-%02d", $full_year, $m);
    }
    if ($clean_date_text =~ /\b(?:ED|EM|Erstdiagnose|Erstmanifestation)\s*:?\s*((?:19|20)?\d{2})\b/i) {
        my $y = $1 + 0;
        $y = ($y < 70) ? (2000 + $y) : ($y < 100 ? 1900 + $y : $y);
        return sprintf("%04d", $y);
    }

    return undef;
}

# --- In calculate_absolute_date ergänzen: ---
sub calculate_absolute_date {
    my ($ref_date_str, $relative_text) = @_;
    return undef unless defined $relative_text && $relative_text ne '';

    $ref_date_str //= POSIX::strftime("%Y-%m-%d", localtime);
    my ($y, $m, $d) = $ref_date_str =~ /^(\d{4})-(\d{2})-(\d{2})/;
    unless ($y && $m && $d) {
        $ref_date_str = POSIX::strftime("%Y-%m-%d", localtime);
        ($y, $m, $d) = $ref_date_str =~ /^(\d{4})-(\d{2})-(\d{2})/;
    }

    my $dt = eval {
        DateTime->new(
            year  => int($y),
            month => int($m),
            day   => int($d)
        );
    };
    return $relative_text unless $dt;

    # Matcht nun auch "seit ca. 2 Jahren", "vor 3 Monaten", "2 wochen"
    if ($relative_text =~ /(\d+)\s*(?:ca\.?\s*)?(days?|tage?n?|weeks?|wochen?|months?|monate?n?|years?|jahre?n?|d|wk|mo|y)\b/i) {
        my $amount = int($1);
        my $unit   = lc($2);

        if    ($unit =~ /^(?:days?|tage?n?|d)$/)    { $dt->subtract(days   => $amount); }
        elsif ($unit =~ /^(?:weeks?|wochen?|wk)$/)  { $dt->subtract(weeks  => $amount); }
        elsif ($unit =~ /^(?:months?|monate?n?|mo)$/) { $dt->subtract(months => $amount); }
        elsif ($unit =~ /^(?:years?|jahre?n?|y)$/)   { $dt->subtract(years  => $amount); }

        # Wenn es sich um Jahre handelt, reicht oft das Jahr (YYYY)
        return ($unit =~ /^(?:years?|jahre?n?|y)$/) ? sprintf("%04d", $dt->year) : $dt->ymd;
    }

    return $relative_text;
}

# =========================================================
# CENTRALIZED LLM ROUTER & CONFIG RESOLVER
# =========================================================
sub resolve_llm_config {
    my ($client_model) = @_;

    # Zentrale Prüfung, ob der Request an Ollama geroutet werden soll
    my $is_ollama = (
        ($client_model && $client_model =~ /-mlx|ollama|muse-glimmer/i)
        || ($llm_provider eq 'ollama')
    ) ? 1 : 0;

    if ($is_ollama) {
        return {
            endpoint  => $ENV{OLLAMA_ENDPOINT} // 'http://10.210.21.203:11434/api/chat',
            model     => $client_model // $ollama_model,
            headers   => { 'Content-Type' => 'application/json' },
            is_ollama => 1,
        };
    }

    return {
        endpoint  => $endpoint,
        model     => $client_model // $model,
        headers   => { 'Authorization' => "Bearer $api_key", 'Content-Type' => 'application/json' },
        is_ollama => 0,
    };
}

# =========================================================
# UNCONSTRAINED CLINICAL REASONING / SCRATCHPAD CALL
# =========================================================
helper generate_reasoning_trace_async => sub {
    my ($self, $text, $clinical_task_instruction, $client_model, $system_prompt) = @_;

    my $llm_cfg           = resolve_llm_config($client_model);
    my $active_model      = $llm_cfg->{model};
    my $active_endpoint   = $llm_cfg->{endpoint};
    my $headers           = $llm_cfg->{headers};
    my $is_local_provider = $llm_cfg->{is_ollama};

    unless ($system_prompt) {
        my $prompt_record = $self->get_llm_prompt('atomic_criteria_reasoning');
        $system_prompt = $prompt_record ? $prompt_record->{system_prompt} : '';
    }

    my $user_content = qq{KLINISCHER BEFUND:\n------------------------\n$text\n------------------------\n$clinical_task_instruction\n\nErstelle nun Schritt für Schritt deine klinische Überlegung und gib die Markdown-Tabelle aus:};

    my $api_payload;

    if ($is_local_provider) {
        # Ollama: think => true
        $api_payload = {
            model    => $active_model,
            think    => Mojo::JSON->true,
            messages => [
                { role => 'system', content => $system_prompt },
                { role => 'user',   content => $user_content }
            ],
            stream   => Mojo::JSON->false,
            options  => {
                temperature => 0.2,
                num_predict => 4096,
                num_ctx     => 16384,
            }
        };
    } else {
        # vLLM / gpt-oss-120b / OpenAI-kompatible Server:
        $api_payload = {
            model            => $active_model,
            messages         => [
                { role => 'system', content => $system_prompt },
                { role => 'user',   content => $user_content }
            ],
            temperature      => 0.2,
            max_tokens       => 4096,          # Erhöhtes Budget für CoT + Tabelle
            reasoning_effort => 'medium',      # Für Modelle mit nativem Reasoning-Schalter
        };
    }

    return $ua->post_p($active_endpoint => $headers => json => $api_payload)->then(sub {
        my $tx = shift;
        if ($tx->result && $tx->result->is_success) {
            my $content = $is_local_provider
                ? ($tx->result->json('/message/content') // '')
                : ($tx->result->json('/choices/0/message/content') // '');

            # Fängt Reasoning-Content sowohl aus Ollama als auch aus vLLM/OpenAI ab:
            my $thinking = $is_local_provider
                ? ($tx->result->json('/message/thinking') // '')
                : ($tx->result->json('/choices/0/message/reasoning_content')
                   // $tx->result->json('/choices/0/message/reasoning')
                   // '');

            # Falls das Modell <think>...</think> direkt im Content ausgibt:
            if (!$thinking && $content =~ /<think>(.*?)<\/think>/s) {
                $thinking = $1;
                $content =~ s/<think>.*?<\/think>//s;
            }

            my $full_trace = "";
            $full_trace .= "=== MODEL INTERNAL THINKING ===\n$thinking\n\n" if length($thinking);
            $full_trace .= "=== CLINICAL RULES ALIGNMENT & EXTRACTION TABLE ===\n$content" if length($content);

            return $full_trace;
        }
        return "Keine Voranalyse verfügbar.";
    })->catch(sub {
        my $err = shift;
        $self->app->log->warn("[REASONING TRACE FAILED] $err");
        return "Voranalyse fehlgeschlagen: $err";
    });
};

# =========================================================
# STRUCTURED LLM CALLER HELPER (Ollama + vLLM Grammar Support)
# =========================================================
helper extract_structured_data_async => sub {
    my ($self, $text, $schema, $system_instruction, $user_prompt, $client_model) = @_;

    my $req_id          = sprintf("LLM-%06d", int(rand(899999)) + 100000);
    my $t0              = [Time::HiRes::gettimeofday()];

    my $llm_cfg           = resolve_llm_config($client_model);
    my $active_model      = $llm_cfg->{model};
    my $active_endpoint   = $llm_cfg->{endpoint};
    my $headers           = $llm_cfg->{headers};
    my $is_local_provider = $llm_cfg->{is_ollama};

    my $api_payload;

    if ($is_local_provider) {
            # Native Ollama /api/chat payload with GBNF grammar schema constraint
            $api_payload = {
                model    => $active_model,
                think    => Mojo::JSON->false,
                messages => [
                    { role => 'system', content => $system_instruction },
                    { role => 'user',   content => "INPUT CLINICAL TEXT:\n---\n$text\n---\nPrompt: $user_prompt" }
                ],
                format   => $schema,
                stream   => Mojo::JSON->false,
                options  => {
                    temperature    => 0.0,
                    repeat_penalty => 1.15,   # Critical for Gemma 4 repetition loops
                    repeat_last_n  => 512,
                    num_predict    => 4096,   # Hard token ceiling to prevent infinite loops
                    num_ctx        => 16384,
                }
            };
    } else {
        # OpenAI / vLLM /v1/chat/completions payload
        $api_payload = {
            model       => $active_model,
            messages    => [
                { role => 'system', content => $system_instruction },
                { role => 'user',   content => "INPUT CLINICAL TEXT:\n---\n$text\n---\nPrompt: $user_prompt" }
            ],
            temperature => 0.1,
            response_format => {
                type => 'json_schema',
                json_schema => {
                    name => "structured_extraction",
                    strict => \1,
                    schema => $schema,
                    presence_penalty => 0.0,
                }
            }
        };
    }

    my $sys_len   = length($system_instruction);
    my $user_len  = length($text);
    my $timestamp = POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime);

    $self->app->log->info("[$req_id] [OUTBOUND LLM REQUEST] Dispatching to $active_model at $active_endpoint (Input: ${user_len} chars, SysPrompt: ${sys_len} chars)");
    print "\n=== [$req_id] [OUTBOUND LLM REQUEST ($active_model)] ===\nTime: $timestamp\nEndpoint: $active_endpoint\nSystem Prompt length: $sys_len chars\nUser Input length: $user_len chars\n===============================================\n";

    return $ua->post_p($active_endpoint => $headers => json => $api_payload)->then(sub {
        my $tx_call = shift;
        my $elapsed = sprintf("%.3f", Time::HiRes::tv_interval($t0));

        if ($tx_call->result && $tx_call->result->is_success) {
            # Extract content from either Ollama native /api/chat or OpenAI /v1/chat/completions
            my $content = $is_local_provider
                ? ($tx_call->result->json('/message/content') // '')
                : ($tx_call->result->json('/choices/0/message/content') // $tx_call->result->body // '');

            my $res_len = length($content);

            $self->app->log->info("[$req_id] [INBOUND LLM RESPONSE] Success in ${elapsed}s (Payload: ${res_len} chars)");
            print "\n=== [$req_id] [INBOUND LLM RESPONSE ($active_model) - ${elapsed}s] ===\n$content\n================================================\n";

            my $parsed = clean_and_parse_json($content);
            unless (defined $parsed) {
                $self->app->log->warn("[$req_id] [JSON PARSE WARNING] LLM returned non-parsable content after ${elapsed}s");
            }
            return $parsed // {};
        } else {
            my $code     = $tx_call->result ? $tx_call->result->code : 'No Status Code';
            my $err      = $tx_call->error  ? $tx_call->error->{message}  : 'Unknown Error';
            my $raw_body = $tx_call->result ? substr($tx_call->result->body // '', 0, 500) : '';

            $self->app->log->error("[$req_id] [LLM REQUEST FAILURE] Failed after ${elapsed}s | Status: $code | Error: $err | Body snippet: $raw_body");
            print "\n=== [$req_id] [LLM REQUEST FAILURE - ${elapsed}s] ===\nStatus: $code\nError: $err\nSnippet: $raw_body\n=============================\n";
        }
        return {};
    })->catch(sub {
        my $err = shift;
        my $elapsed = sprintf("%.3f", Time::HiRes::tv_interval($t0));

        $self->app->log->error("[$req_id] [LLM REQUEST EXCEPTION / TIMEOUT] FAILED after ${elapsed}s | Reason: $err");
        print "\n=== [$req_id] [LLM REQUEST EXCEPTION / TIMEOUT - ${elapsed}s] ===\nReason: $err\n===============================\n";
        return {};
    });
};

# =========================================================
# DATABASE CANONICAL ONTOLOGY LABEL RESOLVER
# =========================================================
helper get_canonical_ontology_label => sub {
    my ($self, $domain, $code) = @_;
    return undef unless defined $code && length $code;

    my $clean_code = $code;
    my $table;

    if ($domain eq 'hpo') {
        $table = 'public.terms';
        $clean_code =~ s/\D//g; # Convert HP:0012804 or 12804 -> integer 12804
        $clean_code = int($clean_code) if length $clean_code;
    } elsif ($domain eq 'icd10') {
        $table = 'public.icd10_terms';
        $clean_code =~ s/^ICD10://i;
        $clean_code =~ s/^\s+|\s+$//g;
        (my $no_dot = $clean_code) =~ s/\.//g;
        
        my $row = $self->pg->db->query(
            "SELECT label FROM public.icd10_terms WHERE id = ? OR id = ? LIMIT 1",
            $clean_code, $no_dot
        )->hash;
        return $row->{label} if $row;
    } elsif ($domain eq 'ops') {
        $table = 'public.ops_terms';
        $clean_code =~ s/^OPS://i;
        $clean_code =~ s/^\s+|\s+$//g;
    } elsif ($domain eq 'atc') {
        $table = 'public.atc_terms';
        $clean_code =~ s/^ATC://i;
        $clean_code =~ s/^\s+|\s+$//g;
    } elsif ($domain eq 'loinc') {
        $table = 'public.loinc_terms';
        $clean_code =~ s/^LOINC://i;
        $clean_code =~ s/^\s+|\s+$//g;
    }

    return undef unless $table && length $clean_code;

    state $label_cache = {};
    my $cache_key = "$domain|$clean_code";
    return $label_cache->{$cache_key} if exists $label_cache->{$cache_key};

    # OPS-Codes liegen in ops_terms kleingeschrieben ("5-144.5a"), die
    # Vektorsuche liefert sie teils groß ("5-144.5A") -> case-insensitiv suchen.
    my $label = eval {
        my $row = ($domain eq 'ops' || $domain eq 'atc')
            ? $self->pg->db->query("SELECT label FROM $table WHERE lower(id) = lower(?) LIMIT 1", $clean_code)->hash
            : $self->pg->db->select($table, ['label'], { id => $clean_code })->hash;
        return $row->{label} if $row && defined $row->{label} && length $row->{label};
        return undef;
    };

    $label_cache->{$cache_key} = $label unless $@;
    return $label;
};

helper is_uncodable_or_future_rule => sub {
    my ($self, $text) = @_;
    if (!ref($self) && defined($text) && !defined($_[2])) {
        $text = $self;
        $self = app();
    }
    # Leerer Text darf NICHT als Filter-Hit (1) gewertet werden!
    return 0 unless defined $text && length($text);
    $text =~ s/^\s+|\s+$//g;
    return 0 unless length($text);

    my $rules = eval { $self->get_filter_rules() } // {};

    for my $rule (@{$rules->{uncodable_rule} // []}) {
        my $pat = $rule->{pattern};
        return 1 if eval { $text =~ qr/$pat/i };
    }

    return 0;
};

sub clean_term_for_vector_mapping {
    my ($term) = @_;
    return '' unless defined $term;

    my $clean = $term;

    # 1. Protect acronyms like BUT / TBUT
    $clean =~ s/\bBUT\b/__TBUT__/g;
    $clean =~ s/\bTBUT\b/__TBUT__/g;

    # 2. Alle Klammerzusätze entfernen
    $clean =~ s/\([^)]*\)//g;

    # 3. Administrative & Floskel-Zusätze entfernen
    $clean =~ s/\b(?:ED|anamnest\.?|in domo|aktuell|ohne bedarf für intervention|ohne intervention|kein bedarf|v\.?a\.?|z\.?n\.?)\b//gi;

    # 4. Strip protocol visit markers and administrative noise
    $clean =~ s/\b(?:at\s+)?visit\s*\d+\b.*$//gi;
    $clean =~ s/\b(?:screening|randomization|baseline|enrollment|visit\s*\d+)\b//gi;
    $clean =~ s/\b(?:subject|participant|patient)\s+(?:must\s+be|has|demonstrates)\b//gi;
    $clean =~ s/\b(?:history\s+of\s+using|prior\s+use\s+of|initiation\s+of|changes\s+to)\b//gi;
    $clean =~ s/\b(?:prior\s+to\s+study\s+start|immediately\s+prior\s+to)\b//gi;

    # Negationen entfernen
    $clean =~ s/\b(?:keine?|keines|keinen|ohne|ausschluss|frei von|no|denies|absence of|without|negative for)\b//gi;

    # 5. Strip parenthetical ranges while retaining instrument names
    $clean =~ s/\(\s*\d+\s*[‑\-]\s*\d+.*?\)//g;

    # 6. Strip numerical operators & numbers
    $clean =~ s/[<>]=?\s*\d+(?:\.\d+)?//g;
    $clean =~ s/≥\s*\d+(?:\.\d+)?//g;
    $clean =~ s/≤\s*\d+(?:\.\d+)?//g;

    # 7. Strip generic filler words (preserve scale names)
    $clean =~ s/\b(?:score|grading|grade|level|value|result)\b//gi;

    # Restore acronyms
    $clean =~ s/__TBUT__/Tear film break-up time/g;

    # 8. Strip leading/trailing punctuation and non-alphanumeric noise
    $clean =~ s/^[^\p{L}\p{N}]+//;
    $clean =~ s/[^\p{L}\p{N}]+$//;
    $clean =~ s/\s+/ /g;
    $clean =~ s/^\s+|\s+$//g;

    return length($clean) > 2 ? $clean : $term;
}

# =========================================================
# LOINC SEARCH TERM PREPARATION WITH OPHTHALMIC INTERCEPTS
# =========================================================
# Entfernt Messwerte, Einheiten, Ergebniswörter und doppelte Wörter aus einer
# Labor-/Messquery. Analytnamen mit Ziffern (HbA1c, fT4, B12, HLA-B27, IL-2)
# bleiben erhalten, weil sie mit einem Buchstaben beginnen.
sub strip_lab_values {
    my ($s) = @_;
    return '' unless defined $s;
    my $orig = $s;
    $s =~ s/\([^)]*\)//g;
    my $UNIT = qr{^(?:%|‰|[µu]?[mnp]?(?:g|mol|l|iu|u|e)(?:/\S+)?|m?iu/\S+|ie/\S+|tsd(?:/\S+)?|mio(?:/\S+)?|ml/\S+|mmhg|cmh2o|[µu]m|mm[²23]?|cm|s|sek|dpt|dptr|zellen/\S+|qm)$}i;
    my %RESULT = map { $_ => 1 } qw(positiv negativ pos neg normwertig niedrig erhöht hoch grenzwertig
                                    unauffällig nachweisbar ++ + - bei von ca ca. um aktuell aktueller letzter geschätzt titer);
    my @tok = grep { length } split /\s+/, $s;
    my (@out, %seen);
    for (my $i = 0; $i <= $#tok; $i++) {
        my $t  = $tok[$i];
        (my $lt = lc $t) =~ s/[,:;]+$//;
        # Zahl (auch "5,9%", "151mg/l", "1:800", "6,3-6,7") am Tokenanfang
        if ($lt =~ /^[<>=~]*[+-]?\d/) {
            my $is_value = ($lt =~ /[.,:%\/]/ || $lt =~ /^\D*\d{3,}/ || $lt =~ /\d[a-zµ%]/);
            my $next = $i < $#tok ? lc($tok[$i + 1]) : '';
            $is_value ||= ($next =~ $UNIT);
            next if $is_value;          # Messwert verwerfen
        }
        next if $lt =~ $UNIT;
        next if $RESULT{$lt};
        next if $seen{$lt}++;
        push @out, $t;
    }
    my $r = join ' ', @out;
    $r =~ s/[,:;]+$//;
    $r =~ s/^\s+|\s+$//g;
    return length($r) > 1 ? $r : $orig;
}

sub prepare_loinc_search_term {
    my ($raw_text, $clean_term, $item_laterality) = @_;
    $raw_text   //= '';
    $clean_term //= clean_term_for_vector_mapping($raw_text);

    # Kombinierter Kontext: Verbatim + Canonical Term gemeinsam prüfen
    my $combined_context = "$raw_text $clean_term";

    # Lateraliät aus Parameter oder Kontext bestimmen
    my $lat = lc($item_laterality // 'none');
    my $is_left  = ($lat eq 'left'  || $lat eq 'os' || $lat eq 'la');
    my $is_right = ($lat eq 'right' || $lat eq 'od' || $lat eq 'ra');

    if (!$is_left && !$is_right) {
        if ($combined_context =~ /\b(?:left|left eye|fellow eye|oculus sinister|os|la|links)\b/i
            || $combined_context =~ /\b(?:visus|tensio|but|tbut|rnfl|bmo|fl[äa]che)\s*l\b/i
            || $raw_text =~ /\bLA\b/i) {
            $is_left = 1;
        } elsif ($combined_context =~ /\b(?:right|right eye|study eye|oculus dexter|od|ra|rechts)\b/i
            || $combined_context =~ /\b(?:visus|tensio|but|tbut|rnfl|bmo|fl[äa]che)\s*r\b/i
            || $raw_text =~ /\bRA\b/i) {
            $is_right = 1;
        }
    }

    my $eye_prefix = $is_left ? 'Left eye' : ($is_right ? 'Right eye' : '');

    # -------------------------------------------------------------
    # 1. HERTEL EXOPHTHALMOMETRIE (SOFORT-INTERCEPT)
    # -------------------------------------------------------------
    if ($combined_context =~ /\b(?:hertel|exophthalmometr\w*)\b/i) {
        return $is_left
            ? "LOINC:28999-1 Left eye Exophthalmia Exophthalmometer.Hertel"
            : ($is_right ? "LOINC:28998-3 Right eye Exophthalmia Exophthalmometer.Hertel"
                         : "LOINC:28998-3 Right eye Exophthalmia Exophthalmometer.Hertel");
    }
    # -------------------------------------------------------------
    # 1b. GESICHTSFELD / PERIMETRIE MEAN DEFECT (MD)
    # -------------------------------------------------------------
    if ($combined_context =~ /\b(?:md|mean\s*defect|mean\s*deviation)\b/i
        && $combined_context =~ /\b(?:gf\b|gesichtsfeld|perimetr\w*|octopus|humphrey|statisches)\b/i) {
        return $is_left
            ? "LOINC:79802-5 Left eye Visual field Mean deviation"
            : ($is_right ? "LOINC:79803-3 Right eye Visual field Mean deviation"
                         : "LOINC:86295-3 Visual field mean defect");
    }

    # -------------------------------------------------------------
    # 1c. FIBRINOGEN (KOAGULATION)
    # -------------------------------------------------------------
    if ($combined_context =~ /\bfibrinogen\b/i) {
        return "LOINC:3255-7 Fibrinogen in Platelet poor plasma by Coagulation assay";
    }
    # -------------------------------------------------------------
    # 2. SEROLOGISCHE & SYSTEMISCHE LABORTESTS (KEIN EYE-PREFIX!)
    # -------------------------------------------------------------
    if ($combined_context =~ /\b(?:bp[- ]?180|basement membrane zone.*180)\b/i) {
        return "LOINC:45188-0 Basement membrane zone BP180 Ab in Serum";
    }
    if ($combined_context =~ /\b(?:bp[- ]?230|basement membrane zone.*230)\b/i) {
        return "LOINC:53843-9 Basement membrane zone BP230 IgG Ab in Serum";
    }
    if ($combined_context =~ /\bkreatinin\b/i && $combined_context !~ /\burin\b/i) {
        return "LOINC:2160-0 Creatinine in Serum or Plasma";
    }
    if ($combined_context =~ /\b(?:il[- ]?2[- ]?r|interleukin[- ]?2[- ]?rezeptor|sil[- ]?2[- ]?r)\b/i) {
        return "LOINC:9654-5 Interleukin 2 Receptor Soluble in Serum or Plasma";
    }
    if ($combined_context =~ /\b(?:desmoglein|dmsg\s*1|dmsg\s*3|ana|anca|crp|hba1c|ace|leukozyten|erythrozyten|thrombozyten|creatinin|gfr|tsh|ft3|ft4)\b/i) {
        # Nur der Analytname – ohne Messwert, Einheit, Ergebniswort und ohne
        # Verdopplung aus "$raw_text $clean_term".
        return strip_lab_values(length($clean_term) > 2 ? $clean_term : $raw_text);
    }
    # Liquordruck / Eröffnungsdruck (CSF / Intracranial pressure)
    if ($combined_context =~ /\b(?:liquordruck|er[öo]ffnungsdruck|e[öo]d|csf\s*pressure)\b/i) {
        return "LOINC:60956-0 Intracranial pressure (ICP)";
    }

    # -------------------------------------------------------------
    # 3. OKULÄRE STRUKTUR- & OCT-PARAMETER
    # -------------------------------------------------------------
    # Retinale Nervenfaserschichtdicke (RNFL)
    if ($combined_context =~ /\b(?:rnfl|nervenfaser\w*|global\s*rnfl)\b/i
        || $combined_context =~ /\b(?:rnfl\s*:)?\s*g\s*\d+\s*(?:µm|um)\b/i
        || $combined_context =~ /\bglobal rnfl thickness\b/i) {
        return $is_left
            ? "LOINC:86299-5 Left eye Retinal nerve fiber layer average thickness by OCT"
            : "LOINC:86300-1 Right eye Retinal nerve fiber layer average thickness by OCT";
    }

    # Bruch's Membrane Opening Fläche (BMO area)
    if ($combined_context =~ /\b(?:bmo[- ]?fl[äa]che|bmo[- ]?area|bruch\s*membrane)\b/i
        || ($combined_context =~ /\bfl[äa]che\s*\d+[\.,]\d+\s*mm[²23]/i && $combined_context !~ /\b(?:cornea|hornhaut|defekt)\b/i)) {
        return $is_left
            ? "LOINC:86290-4b Left eye Bruch membrane opening area by OCT"
            : "LOINC:86301-9b Right eye Bruch membrane opening area by OCT";
    }

    # Ganglienzellvolumen (GZV / GCL / GC-IPL)
    if ($combined_context =~ /\b(?:gzv|ganglienzell\w*|ganglion\s*cell|gcl|gc[- ]?ipl)\b/i) {
        return $is_left
            ? "LOINC:86290-4a Left eye Retinal ganglion cell and inner plexiform layer volume by OCT"
            : "LOINC:86301-9a Right eye Retinal ganglion cell and inner plexiform layer volume by OCT";
    }

    # Cup-to-Disc Ratio (CDR)
    if ($combined_context =~ /\b(?:cdr|cup[- ]to[- ]disc|excavation|papille.*cdr)\b/i) {
        return $is_left
            ? "LOINC:71484-0 Left optic nerve Cup-disc ratio by Ophthalmoscopy"
            : "LOINC:71485-7 Right optic nerve Cup-disc ratio by Ophthalmoscopy";
    }

    # Intraokulardruck (Tensio / IOP)
    if ($combined_context =~ /\b(?:tensio|iop|intraocular pressure|augendruck)\b/i) {
        return $is_left
            ? "LOINC:79893-4 Left eye Intraocular pressure"
            : ($is_right ? "LOINC:79892-6 Right eye Intraocular pressure" : "Intraocular pressure");
    }

    # Visual Acuity
    if ($combined_context =~ /\b(?:visus|visual acuity|sehschärfe|aufnahmevisus|entlassvisus)\b/i) {
        if ($combined_context =~ /\blogmar\b/i) {
            return "$eye_prefix Visual acuity logMAR";
        }
        if ($combined_context =~ /\b(?:cc|m\.?e\.?b|mit korrektur|brille|sph|cyl|[\+\-]\d+[\.,]\d+)\b/i) {
            return "$eye_prefix Visual acuity best corrected";
        }
        if ($combined_context =~ /\bsc\b|\bohne korrektur\b/i) {
            return "$eye_prefix Visual acuity uncorrected";
        }
        return "$eye_prefix Visual acuity";
    }

    # Tear film break-up time (BUT / TBUT)
    if ($combined_context =~ /\b(?:but|tbut|tränenfilmaufbrechzeit|tear\s*film\s*break[- ]up\s*time|break[- ]up\s*time)\b/i) {
        return "$eye_prefix Tear film break-up time";
    }

    # Hornhaut-Epitheldefekt
    if ($combined_context =~ /\b(?:corneal epithelial defect|epithelial defect|corneal defect|epitheldefekt|hornhautdefekt)\b/i) {
        return "$eye_prefix Corneal epithelial defect size";
    }

    # ZENTRALE HORNHAUTDICKE (PACHYMETRIE / CCT) VOR DER SPALTLAMPE ABFANGEN:
    if ($combined_context =~ /\b(?:pachymetrie|hornhautdicke|corneal thickness|cct)\b/i
        || ($combined_context =~ /\b\d{3}\s*(?:µm|um)\b/i && $combined_context !~ /\brnfl\b/i)) {
        return $is_left
            ? "LOINC:79887-6 Left cornea Central thickness"
            : ($is_right ? "LOINC:79888-4 Right cornea Central thickness" : "LOINC:79888-4 Corneal thickness");
    }
    if ($combined_context =~ /\b(?:pachymetrie|hornhautdicke|cct)\b/i
        || ($combined_context =~ /\b(?:cornea|hornhaut)?\s*(?:thickness|dicke)\b/i)
        || ($combined_context =~ /\b\d{3}\s*(?:µm|um)\b/i && $combined_context !~ /\brnfl|gcl|retina|makula/i)) {
        return $is_left
            ? "LOINC:79887-6 Left cornea Central thickness"
            : "LOINC:79888-4 Right cornea Central thickness";
    }
    # Spaltlampen-Biomikroskopie
    if ($combined_context =~ /\b(?:graft diameter|graft size|corneal diameter|slit lamp|biomicroscopy)\b/i) {
        return $is_left
            ? "79860-3 Study observation Left cornea Slit lamp biomicroscopy"
            : "79861-1 Study observation Right cornea Slit lamp biomicroscopy";
    }

    # Lidspaltenhöhe
    if ($combined_context =~ /\b(?:lidspalte\w*|palpebral\s*fissure(?:\s*opening)?\s*(?:height|width)?)\b/i) {
        return $is_left
            ? "LOINC:79856-1 Left palpebral fissure Opening height"
            : "LOINC:79855-3 Right palpebral fissure Opening height";
    }
    # Levatorfunktion (Eye can elevate above midline)
    if ($combined_context =~ /\b(?:levatorfunktion|levatorma[ßs]|levator\s*function)\b/i) {
        return $is_left
            ? "LOINC:79727-4 Eye.left Can elevate above midline"
            : "LOINC:79726-6 Eye.right Can elevate above midline";
    }
    # Endotheldichte (ECD / EZD)
    if ($combined_context =~ /\b(?:endothel\w*|cell density|ecd|endothelial cell density|zellen\s*(?:\/|\s*pro\s*)\s*(?:quadratmillimeter|mm2|mm²))\b/i) {
        return $is_left
            ? "LOINC:100077-7 Left cornea Endothelial cells counted"
            : "LOINC:100076-9 Right cornea Endothelial cells counted";
    }

    if ($combined_context =~ /\b(?:quick|quick-?wert|thromboplastinzeit)\b/i) {
        return "LOINC:5902-2 Prothrombin time in Blood by Coagulation assay";
    }
    if ($combined_context =~ /\b(?:aptt|ptt)\b/i) {
        return "LOINC:14979-9 aPTT in Platelet poor plasma";
    }
    if ($combined_context =~ /\b(?:bsg|blutsenkung|blutk[öo]rperchensenkung)\b/i) {
        return "LOINC:30341-2 Erythrocyte sedimentation rate by Westergren";
    }

    # Schilddrüsenwerte zwingend auf Serum/Plasma festlegen (verhindert DBS Trockenblut!)
    if ($combined_context =~ /\b(?:ft4|freies\s+t4|free\s+t4|free\s+thyroxine)\b/i) {
        return "LOINC:14920-3 Thyroxine (T4) free in Serum or Plasma";
    }
    if ($combined_context =~ /\b(?:ft3|freies\s+t3|free\s+t3|free\s+triiodothyronine)\b/i) {
        return "LOINC:14928-6 Triiodothyronine (T3) free in Serum or Plasma";
    }
    if ($combined_context =~ /\b(?:tsh|thyrotropin)\b/i && $combined_context !~ /\b(?:rezeptor|trak|rab)\b/i) {
        return "LOINC:3016-3 Thyrotropin in Serum or Plasma";
    }

    # Bereinigung redundanter Auge-Präfixe
    $clean_term =~ s/^\s*(?:right eye|left eye|study eye|fellow eye|both eyes)\s*//gi;
    $clean_term =~ s/\s*\b(?:in the right eye|in the left eye|in study eye|in fellow eye|in both eyes|in either eye)\b\s*//gi;

    if ($eye_prefix && $clean_term !~ /^$eye_prefix/i) {
        return "$eye_prefix $clean_term";
    }

    return $clean_term;
}

# =========================================================
# FHIR ELIGIBILITY EXTRACTION ENDPOINT
# =========================================================
post '/BBB/extract_fhir_inex_criteria' => sub {
    my $c = shift;
    $c->inactivity_timeout(3000);

    my $payload        = $c->req->json // {};
    my $text_content   = $payload->{medical_report} // $payload->{report} // '';
    my $selected_model = $payload->{model};
    my $deep_mode      = $payload->{deep_mode} // 0;
    my $task_id        = $payload->{task_id};

    unless ($text_content) {
        return $c->render(json => { error => "Missing 'medical_report' or 'report' payload parameter." }, status => 400);
    }

    $c->render_later;

    my $start_msg = to_bool($deep_mode)
        ? "Step 1: Deep Reasoning & Kriterien-Atomisierung..."
        : "Step 1: Kriterien-Atomisierung & Disjunktions-Erkennung...";
    $c->notify_task_progress($task_id, 'llm1', 5, $start_msg);

    $c->extract_atomic_criteria_async($text_content, 'fhir', $selected_model, $deep_mode, $task_id)->then(sub {
        my $step1_res = shift;

        my ($doc_lang, $atomic_criteria);
        if (ref $step1_res eq 'HASH') {
            $doc_lang        = $step1_res->{language} // 'de';
            $atomic_criteria = $step1_res->{criteria} // [];
        } else {
            $doc_lang        = 'de';
            $atomic_criteria = $step1_res // [];
        }

        unless (ref $atomic_criteria eq 'ARRAY' && @$atomic_criteria) {
            die "No criteria extracted from text during Step 1.";
        }

        $c->notify_task_progress($task_id, 'llm2', 50, "Step 2: Einzelkriterien-Parsing & Vector Mapping...");

        my @row_promises;
        foreach my $item (@$atomic_criteria) {
            my $v_text       = $item->{verbatim_text} // '';
            my $canon_term   = $item->{canonical_term};
            my $is_ex        = to_bool($item->{is_exclusion}) ? 1 : 0;
            my $comb_method  = $item->{combination_method} // ($is_ex ? 'neither-of' : 'all-of');

            my $disj_id      = $item->{disjunction_group_id} // '';
            $disj_id         = '' if $disj_id =~ /^(?:none|null|n\/?a|0|\s*)$/i;

            my $domain       = lc($item->{domain} // 'hpo');
            my $demo_type    = lc($item->{demographic_type} // 'none');
            my $demo_val     = $item->{demographic_value} // '';

            if ($c->is_uncodable_or_future_rule($v_text)) {
                $c->app->log->info("[PROSPECTIVE / ADMINISTRATIVE RULE FILTERED] '$v_text'");
                next;
            }

            my $wrap_res = sub {
                my ($char_node) = @_;
                return {
                    characteristic_node  => $char_node,
                    disjunction_group_id => $disj_id,
                    combination_method   => $comb_method,
                    is_exclusion         => $is_ex
                };
            };

            my $parsed_quant = parse_quantitative_constraint($v_text) // parse_quantitative_constraint($demo_val);

            if (!$parsed_quant && $v_text =~ /\b(?:fixation|abwehr|folgt|emmetrop|skiaskop)\b/i) {
                next;
            }

            my $make_quantity_node = sub {
                my ($q) = @_;
                my $unit_lc = lc($q->{unit} // '');

                my $is_temporal = ($unit_lc =~ /^(?:d|wk|mo|a)$/ && $v_text =~ /\b(?:prior|within|duration|washout|history|ago|last|past|screening)\b/i) ? 1 : 0;

                if ($is_temporal) {
                    return {
                        exclude => $is_ex ? \1 : \0,
                        combinationMethod => $comb_method,
                        code => { coding => [{ system => "http://loinc.org", code => "temporal-constraint", display => "Temporal Timeframe Constraint" }] },
                        relativeTime => [
                        {
                            contextCode => { coding => [{ system => "http://hl7.org/fhir/relative-time-context", code => "event", display => "Event" }] },
                            offsetDuration => {
                                value      => $q->{value},
                                comparator => $q->{comparator},
                                unit       => $q->{unit},
                                system     => "http://unitsofmeasure.org",
                                code       => ($q->{unit} eq 'wk' ? 'w' : ($q->{unit} eq 'mo' ? 'm' : $q->{unit}))
                            }
                        }
                        ]
                    };
                } else {
                    my $ucum_code = $q->{unit};
                    $ucum_code = "um"          if $q->{unit} eq 'um';
                    $ucum_code = "mm2"         if $q->{unit} eq 'mm2';
                    $ucum_code = "{cells}/mm2" if $q->{unit} =~ /cells/i || $q->{unit} eq '{cells}/mm2';
                    $ucum_code = "a"           if $q->{unit} eq 'years' || $q->{unit} eq 'a';

                    return {
                        exclude => $is_ex ? \1 : \0,
                        combinationMethod => $comb_method,
                        code => { coding => [{ system => "http://loinc.org", code => "LP7753-9", display => "Quantitative Measurement (Qn)" }] },
                        valueQuantity => {
                            comparator => $q->{comparator},
                            value      => $q->{value},
                            unit       => $q->{unit},
                            system     => "http://unitsofmeasure.org",
                            code       => $ucum_code
                        }
                    };
                }
            };

            my $pair_with_quantity = sub {
                my ($main_node) = @_;
                if ($parsed_quant) {
                    $main_node->{combinationMethod} = 'all-of';
                    my $quant_node = $make_quantity_node->($parsed_quant);
                    return {
                        resourceType      => 'Group',
                        combinationMethod => 'all-of',
                        exclude           => $is_ex ? \1 : \0,
                        characteristic    => [ $main_node, $quant_node ]
                    };
                }
                return $main_node;
            };

            my $clean_search_term = (defined $canon_term && length($canon_term) > 2)
                ? $canon_term
                : clean_term_for_vector_mapping($v_text);

            # --- Demographics Interceptor ---
            if ($domain eq 'demographic' || ($demo_type ne 'none' && $domain ne 'ops' && $domain ne 'atc' && $domain ne 'hpo' && $domain ne 'icd10' && $domain ne 'loinc')) {
                my $fhir_node = {
                    exclude => $is_ex ? \1 : \0,
                    combinationMethod => $comb_method
                };

                if ($demo_type eq 'age' || $v_text =~ /\b(?:age|aged|years? old|jahre?)\b/i) {
                    $fhir_node->{code} = { coding => [{ system => "http://loinc.org", code => "30525-0", display => "Age Constraint" }] };
                    my $comp = $parsed_quant ? $parsed_quant->{comparator} : '>=';
                    my $num  = $parsed_quant ? $parsed_quant->{value} : 18;
                    my $unit = $parsed_quant ? $parsed_quant->{unit} : 'a';
                    if (!$parsed_quant && $demo_val =~ /([<>]=?|=)\s*(\d+)/) { $comp = $1; $num = $2 + 0; }
                    $fhir_node->{valueQuantity} = {
                        comparator => $comp,
                        value      => $num,
                        unit       => ($unit eq 'a' || $unit =~ /year/i) ? "years" : $unit,
                        system     => "http://unitsofmeasure.org",
                        code       => "a"
                    };
                }
                elsif ($demo_type eq 'sex' || $v_text =~ /\b(?:male|female|sex|gender|geschlecht)\b/i) {
                    $fhir_node->{code} = { coding => [{ system => "http://loinc.org", code => "76689-9", display => "Sex Constraint" }] };
                    my $is_both = ($demo_val =~ /^MALE_OR_FEMALE$/i
                                || $demo_val =~ /\b(?:both|all|any|male or female|female or male|male\/female)\b/i
                                || $v_text   =~ /\b(?:male or female|female or male|male\/female|both sexes|any sex)\b/i
                                || ($v_text  =~ /\bmales?\b/i && $v_text =~ /\bfemales?\b/i));

                    my $is_female_only = !$is_both && ($demo_val =~ /^FEMALE$/i || ($v_text =~ /\bfemales?\b/i && $v_text !~ /\bmales?\b/i));
                    my $sex_val = $is_both ? 'MALE_OR_FEMALE' : ($is_female_only ? 'FEMALE' : 'MALE');
                    $fhir_node->{valueCodeableConcept} = { coding => [{ system => "http://loinc.org", code => $sex_val, display => $sex_val }] };
                }
                elsif ($parsed_quant) {
                    $fhir_node = $make_quantity_node->($parsed_quant);
                }
                push @row_promises, Mojo::Promise->resolve($wrap_res->($fhir_node));
                next;
            }

            # --- LOINC Assays ---
            if ($domain eq 'loinc') {
                my $is_visus_candidate = (
                    $canon_term =~ /\b(?:visual\s*acuity|visus|refraction|sphere|cylinder)\b/i
                    || $v_text =~ /\b(?:visus|sehschärfe|visual\s*acuity|aufnahmevisus|entlassvisus|sc\b|cc\b|hbw\b|lsp\b|lsw\b|nulla\s*lux)\b/i
                ) && ($v_text !~ /\b(?:osdi|vas|but|tbut|pachymetrie|k1|k2|kmax|astigmatismus)\b/i);

                if ($is_visus_candidate) {
                    my $parsed_eye = extract_visus_and_refraction($v_text);
                    if ($parsed_eye && (defined $parsed_eye->{visus_value} || defined $parsed_eye->{sphere})) {
                        my $loinc_id = $parsed_eye->{is_best_corrected} ? "LOINC:65893-0" : "LOINC:98499-7";
                        my $loinc_lbl = $parsed_eye->{is_best_corrected} ? "Visual acuity best corrected" : "Visual acuity uncorrected";

                        my $assay_node = {
                            exclude => $is_ex ? \1 : \0,
                            combinationMethod => $comb_method,
                            code => { coding => [{ system => "http://snomed.info/sct", code => "8116006", display => "Phänotypisches Merkmal" }] },
                            valueCodeableConcept => { coding => [{ system => "http://loinc.org", code => $loinc_id, display => $loinc_lbl, is_modifier => \0 }] }
                        };

                        if (defined $parsed_eye->{visus_value}) {
                            my $quant_node = {
                                exclude => $is_ex ? \1 : \0,
                                combinationMethod => $comb_method,
                                code => { coding => [{ system => "http://loinc.org", code => "LP7753-9", display => "Quantitative Measurement (Qn)" }] },
                                valueQuantity => {
                                    comparator => '=',
                                    value      => $parsed_eye->{visus_value},
                                    unit       => "decimal",
                                    system     => "http://unitsofmeasure.org",
                                    code       => "1"
                                }
                            };
                            push @row_promises, Mojo::Promise->resolve($wrap_res->({
                                resourceType      => 'Group',
                                combinationMethod => 'all-of',
                                exclude           => $is_ex ? \1 : \0,
                                characteristic    => [ $assay_node, $quant_node ]
                            }));
                        } else {
                            push @row_promises, Mojo::Promise->resolve($wrap_res->($assay_node));
                        }
                        next;
                    }
                }

                my $loinc_search_term = prepare_loinc_search_term($v_text, $clean_search_term);
                my $p_loinc = $c->map_to_loinc_async($loinc_search_term, $doc_lang, { context => $v_text });   # PATCH 2026-09-25
                my $p_hpo   = $c->map_to_hpo_async($clean_search_term, 0, $doc_lang);

                my $p_combined = Mojo::Promise->all($p_loinc, $p_hpo)->then(sub {
                    my ($loinc_res, $hpo_res) = @_;

                    my $mapped_loinc = $loinc_res->[0];
                    my $mapped_hpo   = $hpo_res->[0];

                    my $has_loinc = ($mapped_loinc && $mapped_loinc->{id}) ? 1 : 0;
                    my $has_hpo   = ($mapped_hpo && $mapped_hpo->{id} && $mapped_hpo->{id} ne 'HP:0000118') ? 1 : 0;

                    # Weder LOINC noch HPO lieferten einen gültigen Code -> Zeile verwerfen
                    return undef unless $has_loinc || $has_hpo;

                    # Fall 1: LOINC vorhanden (Basis-Knoten bauen, ggf. mit Menge/Quantity paaren)
                    my $paired_loinc_node = undef;
                    if ($has_loinc) {
                        my $assay_node = {
                            exclude           => $is_ex ? \1 : \0,
                            combinationMethod => $comb_method,
                            code              => { coding => [{ system => "http://snomed.info/sct", code => "8116006", display => "Phänotypisches Merkmal" }] },
                            valueCodeableConcept => { coding => [{ system => "http://loinc.org", code => $mapped_loinc->{id}, display => $mapped_loinc->{label} // $v_text, is_modifier => \0 }] }
                        };
                        $paired_loinc_node = $pair_with_quantity->($assay_node);
                    }

                    # Fall 2: HPO vorhanden
                    my $hpo_node = undef;
                    if ($has_hpo) {
                        $hpo_node = {
                            exclude           => $is_ex ? \1 : \0,
                            combinationMethod => $comb_method,
                            code              => { coding => [{ system => "http://snomed.info/sct", code => "8116006", display => "Phänotypisches Merkmal" }] },
                            valueCodeableConcept => { coding => [{ system => "http://purl.obolibrary.org/obo/hp.owl", code => $mapped_hpo->{id}, display => $mapped_hpo->{label} // $v_text, is_modifier => \0 }] }
                        };
                    }

                    # Beide vorhanden -> als Composite Group bündeln
                    if ($paired_loinc_node && $hpo_node) {
                        my $composite_group = {
                            resourceType      => 'Group',
                            combinationMethod => 'all-of',
                            exclude           => $is_ex ? \1 : \0,
                            characteristic    => [ $hpo_node, $paired_loinc_node ]
                        };
                        return $wrap_res->($composite_group);
                    }

                    # Nur LOINC vorhanden
                    return $wrap_res->($paired_loinc_node) if $paired_loinc_node;

                    # Nur HPO vorhanden (ggf. mit Quantity gepaart)
                    return $wrap_res->($pair_with_quantity->($hpo_node));
                });

                push @row_promises, $p_combined;
                next;
            }

            # --- ICD-10 Diagnoses ---
            if ($domain eq 'icd10') {
                # PATCH 2026-09-25: kanonischer Begriff und Kontext statt Sprach-Fallback
                my $p_icd = $c->map_to_icd10_async($clean_search_term, $canon_term, $doc_lang, {
                    context    => $v_text,
                    site       => $item->{anatomical_site},
                    is_history => to_bool($item->{is_history}),
                })->then(sub {
                    my $mapped = shift;

                    return undef unless $mapped && $mapped->{id};

                    my $node = {
                        exclude => $is_ex ? \1 : \0,
                        combinationMethod => $comb_method,
                        code => { coding => [{ system => "http://snomed.info/sct", code => "2931005", display => "Diagnose" }] },
                        valueCodeableConcept => { coding => [{ system => "http://hl7.org/fhir/sid/icd-10", code => $mapped->{id}, display => $mapped->{label} // $v_text, is_modifier => \0 }] }
                    };
                    return $wrap_res->($pair_with_quantity->($node));
                });
                push @row_promises, $p_icd;
                next;
            }

            # --- OPS Procedures ---
            if ($domain eq 'ops') {
                my $p_ops = $c->map_to_ops_async($clean_search_term, $doc_lang,
                    { context => $v_text, site => $item->{anatomical_site} })->then(sub {
                    my $mapped = shift;

                    return undef unless $mapped && $mapped->{id};

                    my $node = {
                        exclude => $is_ex ? \1 : \0,
                        combinationMethod => $comb_method,
                        code => { coding => [{ system => "http://snomed.info/sct", code => "71388002", display => "Prozedur (OPS)" }] },
                        valueCodeableConcept => { coding => [{ system => "http://fhir.de/CodeSystem/bfarm/ops", code => $mapped->{id}, display => $mapped->{label} // $v_text, is_modifier => \0 }] }
                    };
                    return $wrap_res->($pair_with_quantity->($node));
                });
                push @row_promises, $p_ops;
                next;
            }

            # --- ATC Medications ---
            if ($domain eq 'atc') {
                my $p_atc = $c->map_to_atc_async($clean_search_term, $doc_lang, { context => $v_text })->then(sub {   # PATCH 2026-09-25
                    my $mapped = shift;

                    return undef unless $mapped && $mapped->{id};

                    my $node = {
                        exclude => $is_ex ? \1 : \0,
                        combinationMethod => $comb_method,
                        code => { coding => [{ system => "http://snomed.info/sct", code => "410942007", display => "Medikament (ATC)" }] },
                        valueCodeableConcept => { coding => [{ system => "http://www.whocc.no/atc", code => $mapped->{id}, display => $mapped->{label} // $v_text, is_modifier => \0 }] }
                    };
                    return $wrap_res->($pair_with_quantity->($node));
                });
                push @row_promises, $p_atc;
                next;
            }

            # --- HPO Symptoms & Phenotypes (Default) ---
            my $enriched_term = enrich_term_with_section_context($clean_search_term, $v_text, $text_content);

            my $p_hpo = $c->map_to_hpo_async($enriched_term, 0, $doc_lang,
                { context => $v_text, site => $item->{anatomical_site} })->then(sub {
                my $mapped = shift;

                return undef unless $mapped && $mapped->{id};

                my $node = {
                    exclude => $is_ex ? \1 : \0,
                    combinationMethod => $comb_method,
                    code => { coding => [{ system => "http://snomed.info/sct", code => "8116006", display => "Phänotypisches Merkmal" }] },
                    valueCodeableConcept => { coding => [{ system => "http://purl.obolibrary.org/obo/hp.owl", code => $mapped->{id}, display => $mapped->{label} // $v_text, is_modifier => \0 }] }
                };
                return $wrap_res->($pair_with_quantity->($node));
            });
            push @row_promises, $p_hpo;
        }

        # PHASE 2 PROGRESS TRACKING: Jedes Mapping erhöht den Fortschrittsbalken (50% bis 92%)
        my $total_items = scalar(@row_promises) || 1;
        my $done_items  = 0;

        @row_promises = map {
            $_->then(sub {
                my $res = shift;
                $done_items++;
                my $pct = int(50 + ($done_items / $total_items) * 42);
                $c->notify_task_progress($task_id, 'dense_retrieval', $pct, "Mapping Kriterium $done_items/$total_items ($pct%)...");
                return $res;
            });
        } @row_promises;

        return Mojo::Promise->all(@row_promises)->then(sub {
            my @mapped_results = map { $_->[0] } @_;
            @mapped_results = grep { defined && ref $_ eq 'HASH' } @mapped_results;

            $c->notify_task_progress($task_id, 'assembly', 95, "Disjunktions-Gruppierung & FHIR Assemblierung...");

            my %disjunction_groups;
            my @flat_characteristics;

            for (my $i = 0; $i < @mapped_results; $i++) {
                my $res     = $mapped_results[$i];
                my $char    = $res->{characteristic_node};
                my $disj_id = $res->{disjunction_group_id} // '';
                my $is_ex   = $res->{is_exclusion} ? 1 : 0;

                $disj_id = '' if $disj_id =~ /^(?:none|null|n\/?a|0|\s*)$/i;

                if ($disj_id eq '') {
                    $char->{combinationMethod} = $is_ex ? 'neither-of' : 'all-of';
                    push @flat_characteristics, $char;
                    next;
                }

                my $scoped_group_id = ($is_ex ? "ex_" : "in_") . $disj_id;
                push @{$disjunction_groups{$scoped_group_id}}, $char;
            }

            my @contained_groups;
            my $subgroup_idx = 1;

            foreach my $group_key (sort keys %disjunction_groups) {
                my $members = $disjunction_groups{$group_key};
                next unless @$members;

                if (@$members == 1) {
                    my $single = $members->[0];
                    my $is_ex  = to_bool($single->{exclude}) ? 1 : 0;
                    $single->{combinationMethod} = $is_ex ? 'neither-of' : 'all-of';
                    push @flat_characteristics, $single;
                    next;
                }

                my $is_group_ex = to_bool($members->[0]{exclude}) ? 1 : 0;
                my $sg_id = "subgroup-" . $subgroup_idx++;

                foreach my $m (@$members) {
                    unless ($m->{resourceType} && $m->{resourceType} eq 'Group') {
                        $m->{combinationMethod} = $is_group_ex ? 'neither-of' : 'any-of';
                    }
                }

                my $sub_group_resource = {
                    resourceType      => "Group",
                    id                => $sg_id,
                    membership        => "conceptual",
                    type              => "person",
                    combinationMethod => $is_group_ex ? "all-of" : "any-of",
                    characteristic    => $members
                };
                push @contained_groups, $sub_group_resource;

                push @flat_characteristics, {
                    code => { text => $is_group_ex ? "Exclusion subgroup (All of)" : "Disjunctive subgroup (Any of)" },
                    valueReference => { reference => "#" . $sg_id },
                    exclude => $is_group_ex ? \1 : \0,
                    combinationMethod => $is_group_ex ? "all-of" : "any-of"
                };
            }

            my @normalized_flat_characteristics;
            foreach my $char (@flat_characteristics) {
                if (ref $char eq 'HASH' && $char->{resourceType} && $char->{resourceType} eq 'Group') {
                    my $sg_id = "subgroup-" . $subgroup_idx++;
                    my $is_group_ex = to_bool($char->{exclude}) ? 1 : 0;

                    $char->{id}         = $sg_id;
                    $char->{membership} = "conceptual";
                    $char->{type}       = "person";

                    push @contained_groups, $char;

                    push @normalized_flat_characteristics, {
                        code => { text => "Logical subgroup" },
                        valueReference => { reference => "#" . $sg_id },
                        exclude => $is_group_ex ? \1 : \0,
                        combinationMethod => $char->{combinationMethod} // "all-of"
                    };
                } else {
                    push @normalized_flat_characteristics, $char;
                }
            }
            @flat_characteristics = @normalized_flat_characteristics;

            my %seen_signatures;
            my @clean_characteristics;

            foreach my $char (@flat_characteristics) {
                next if (!exists $char->{code} && !exists $char->{valueQuantity} && !exists $char->{valueCodeableConcept} && !exists $char->{valueReference} && !exists $char->{characteristic} && !exists $char->{relativeTime});

                my $sig = generate_characteristic_signature($char);
                if ($sig) {
                    next if $seen_signatures{$sig};
                    $seen_signatures{$sig} = 1;
                }
                push @clean_characteristics, $char;
            }

            my $final_group = {
                resourceType      => "Group",
                id                => "eligibility-criteria",
                status            => "active",
                type              => "person",
                membership        => "definitional",
                combinationMethod => "all-of",
                exclude           => \0,
                characteristic    => \@clean_characteristics
            };

            if (@contained_groups) {
                $final_group->{contained} = \@contained_groups;
            }

            $c->notify_task_progress($task_id, 'finished', 100, "Abgeschlossen");

            if ($c->tx && !$c->tx->is_finished) {
                $c->render(json => $final_group);
            }
        });
    })->catch(sub {
        my $err = shift;
        $c->app->log->error("Error during Step-by-Step FHIR Group Generation: $err");
        $c->notify_task_progress($task_id, 'failed', 0, "Pipeline-Fehler");

        if ($c->tx && !$c->tx->is_finished) {
            $c->render(json => { error => "Pipeline failure", details => "$err" }, status => 500);
        }
    });
};

# =========================================================
# PHENOPACKET EXTRACTION PIPELINE IMPLEMENTATION (KORRIGIERT)
# =========================================================
helper generate_phenopacket_impl => sub {
    my ($self, $text_content, $selected_model, $candidate_id, $reference_date, $deep_mode, $task_id) = @_;
    $deep_mode = to_bool($deep_mode);

    if ($candidate_id && !$reference_date) {
        eval {
            my $row = $self->pg->db->select('candidates', ['reference_date'], { id => $candidate_id })->hash;
            $reference_date = $row->{reference_date} // $row->{date} if $row;
        };
    }
    $reference_date //= POSIX::strftime("%Y-%m-%d", localtime);
    # PATCH 2026-10-23: TT.MM.JJ normalisieren und als JJ.MM.TT vertauschte Briefdaten korrigieren
    $reference_date = normalize_reference_day($reference_date) // $reference_date;
    $reference_date = fix_swapped_reference_day($reference_date, $text_content);

    print STDERR "\n=======================================================\n";
    print STDERR ">>> [PHENOPACKET PIPELINE START] Candidate ID: " . ($candidate_id // 'none') . " | RefDate: $reference_date | Deep Mode: " . ($deep_mode ? "ON" : "OFF") . "\n";
    print STDERR "=======================================================\n";

    my $start_msg = $deep_mode
        ? "Step 1: Deep Reasoning & Kriterien-Atomisierung..."
        : "Step 1: Kriterien-Atomisierung...";
    $self->notify_task_progress($task_id, 'llm1', 5, $start_msg);

    return $self->extract_atomic_criteria_async($text_content, 'phenopacket', $selected_model, $deep_mode, $task_id)->then(sub {
        my $step1_res = shift;

        my ($doc_lang, $atomic_items);
        if (ref $step1_res eq 'HASH') {
            $doc_lang     = $step1_res->{language} // 'de';
            $atomic_items = $step1_res->{criteria} // [];
        } else {
            $doc_lang     = 'de';
            $atomic_items = $step1_res // [];
        }

        print STDERR ">>> [PHENOPACKET STEP 1 COMPLETED] Language: '$doc_lang' | Items count: " . scalar(@$atomic_items) . "\n";

        # -------------------------------------------------------------
        # Konfliktlösung (Ausschluss sticht Verdacht) - LATERAL & TEMPORAL GEBUNDEN
        # -------------------------------------------------------------
        my %excluded_by_eye;

        foreach my $it (@$atomic_items) {
            if (to_bool($it->{is_exclusion})) {
                my $lat     = lc($it->{laterality} // 'none');
                my $ev_date = $it->{event_date} // '';
                my $v_raw   = lc($it->{verbatim_text} // '');

                # Historische Befunde ("03/2026", "2025", "früher") dürfen NIEMALS
                # eine aktuelle Diagnose als Ausschluss überschreiben:
                next if length($ev_date) && $ev_date =~ /(?:19|20)\d{2}/;
                next if $v_raw =~ /\b(?:zuletzt|früher|vormonat|\d{1,2}\/\d{2,4})\b/;

                for my $raw ($it->{canonical_term}, $it->{verbatim_text}) {
                    next unless defined $raw && length($raw);
                    my $clean = lc(clean_term_for_vector_mapping($raw));
                    $clean =~ s/\b(?:kein[enms]?|ohne|hinweis|auf|nicht|frei|ausschluss|signifikant\w*)\b//gi;
                    $clean =~ s/^\s+|\s+$//g;

                    if (length($clean) > 3) {
                        $excluded_by_eye{$lat}{$clean} = 1;
                    }
                }
            }
        }

        @$atomic_items = grep {
            my $it = $_;
            my $v_clean = lc($it->{verbatim_text} // '');
            my $is_suspected = ($v_clean =~ /\b(?:v\.?\s*a\.?|verdacht|fraglich|ausschluss\s+von)\b/i);
            my $should_drop = 0;
            my $matched_reason = "";

            if ($is_suspected) {
                my $lat = lc($it->{laterality} // 'none');

                for my $cand ($it->{canonical_term}, $it->{verbatim_text}) {
                    next unless defined $cand && length($cand);
                    my $clean = lc(clean_term_for_vector_mapping($cand));
                    $clean =~ s/\b(?:v\.?\s*a\.?|verdacht|fraglich)\b//gi;
                    $clean =~ s/^\s+|\s+$//g;

                    # Nur droppen, wenn auf DEMSELBEN Auge (oder explizit bilateral) ausgeschlossen!
                    if ($excluded_by_eye{$lat}{$clean} || $excluded_by_eye{'bilateral'}{$clean}) {
                        $should_drop = 1;
                        $matched_reason = "Eye '$lat' Phrase '$clean'";
                        last;
                    }
                }
            }

            if ($should_drop) {
                $self->app->log->info("[SUSPECTED DIAGNOSIS REMOVED BY EXCLUSION] '$it->{verbatim_text}' matched exclusion ($matched_reason)");
                0;
            } else {
                1;
            }
        } @$atomic_items;
        
        my $cat_ctx = ($text_content =~ $PHACO_CONTEXT_RE) ? 1 : 0;   # PATCH 2026-10-22
        # -------------------------------------------------------------
        # Anatomie-Schutz & Syntaktische Fehlinterpretationen korrigieren
        # -------------------------------------------------------------
        foreach my $item (@$atomic_items) {
            my $v = lc($item->{verbatim_text} // '');
            my $c = lc($item->{canonical_term} // '');

            # 1. Anatomie-Fix: Retinale Befunde dürfen niemals Iris/Cornea/Lid sein
            if ($c =~ /\b(?:retin\w*|makula|macula|fovea|photorezept\w*|glios\w*|foramen|drusen)\b/i
                || $v =~ /\b(?:nh[- ]oct|oct|fundus|retina|intraretinal|subretinal)\b/i) {
                if (($item->{anatomical_site} // '') =~ /^(?:iris|cornea|lens|anterior_chamber|eyelid|ocular_other)$/) {
                    $item->{anatomical_site} = ($c =~ /\b(?:makula|macula|fovea)\b/i) ? 'macula' : 'retina';
                }
            }

            # 2. Syntaktischer Fix: "DD traktiv bei epiretinaler Gliose" ist ein Makulaödem, keine Amotio
            if ($c =~ /traktiv.*netzhautabl/i && $v =~ /\b(?:makula|gliose|traktiv)\b/i && $v !~ /\b(?:amotio|ablatio|ablösung)\b/i) {
                $item->{canonical_term} = 'Traktives Makulaödem';
                $item->{domain}         = 'hpo';
            }
        }
        
        # -------------------------------------------------------------
        # Domain-Korrektur & Administrative Filterung
        # -------------------------------------------------------------
        foreach my $item (@$atomic_items) {
            my $v = lc($item->{verbatim_text} // '');
            my $c = lc($item->{canonical_term} // '');

            if ($v =~ /\b(?:vesikel|bl[äa]schen|r[öo]tlich|effloreszenz|hautl[äa]sion|pustel|kruste|papel)\b/i) {
                $item->{domain} = 'hpo' if ($item->{domain} // '') eq 'icd10';
            }
            if ($v =~ /\b(?:blutkoagel|koagel|plaque|scleraplaque|membran|fl[üu]ssigkeit|tingiert|pigment)\b/i) {
                $item->{domain} = 'hpo' if ($item->{domain} // '') eq 'icd10';
            }
            if ($item->{domain} eq 'ops' && $v =~ /\btensiodekompensation\b/i) {
                $item->{domain} = 'icd10';
            }
            if ($v =~ /\b(?:aok|barmer|tk|kasse|abrechnung|fall|patient)\b/i && $v =~ /\bivom\b/i) {
                $item->{domain} = 'skip';
            }
            if ($v =~ /\b(?:augeninnendrucksenkung\s+mittels|acetazolamid[- ]gabe|antiglaukomatös|tensioprofil)\b/i) {
                if ($item->{domain} eq 'ops') {
                    # Verhindert, dass Acetazolamid als IVOM (OPS:5-156.9) kodiert wird!
                    $item->{domain} = 'skip';
                }
            }
            # Verhindert, dass konservative Tropftherapien unter der Überschrift "Operation" zu chirurgischen OPS-Codes werden:
            if (($item->{domain} // '') eq 'ops' && $v =~ /\b(?:tropftherapie|augentropfen|lokaltherapie|konservativ|benetzung|salbentherapie)\b/i) {
                $item->{domain} = 'skip';
            }
            # Konsil-Ausschlüsse (Endokarditis, Infektfokus) komplett ignorieren:
            if ($v =~ /\b(?:keinen?\s+h\.?a\.?\s+endokarditis|kein\s+eindeutiger\s+infekt[- ]fokus|kein\s+h\.?a\.?\s+infektfokus)\b/i) {
                $item->{domain} = 'skip';
            }
            if (($item->{domain} // '') eq 'ops' && $v =~ /\b(?:iol\s+in\s+loco|iridektomie\s+offen|hinterkapsel\s+eröffnet|transplantat\s+anliegend)\b/i) {
                $item->{domain} = 'skip';
            }
            # Abstoßung (immunologisch) und Transplantatversagen getrennt halten.
            # Beide fallen in ICD-10-GM auf T86.83, sind klinisch aber verschieden.
            # Der kanonische Begriff entscheidet vor dem Verbatim-Text, damit
            # "keine Abstoßung, primäres Transplantatversagen" richtig landet.
            unless (($item->{domain} // '') eq 'ops'
                    || $v =~ /\b(?:z\.?\s*n\.?|re[- ]?dmek|dmek|dsaek|pkp|keratoplastik)\b/i) {
                my $rej_re  = qr/(?:absto[ßs]ung|graft\s*rejection)/i;
                my $fail_re = qr/(?:transplantatversagen|graft\s*failure)/i;
                my $kind = $c =~ $rej_re  ? 'rejection'
                         : $c =~ $fail_re ? 'failure'
                         : $v =~ $rej_re  ? 'rejection'
                         : $v =~ $fail_re ? 'failure'
                         : '';
                if ($kind eq 'rejection') {
                    $item->{domain}         = 'icd10';
                    $item->{canonical_term} = 'Hornhauttransplantatabstoßung';
                } elsif ($kind eq 'failure') {
                    $item->{domain}         = 'icd10';
                    $item->{canonical_term} = ("$v $c" =~ /\bprim[äa]r/i)
                        ? 'Primäres Hornhauttransplantatversagen'
                        : 'Hornhauttransplantatversagen';
                }
            }
            if ($v =~ /\b(?:re[- ]?dmek|re[- ]?dsaek)\b/i || $c =~ /\bre[- ]?dmek\b/i) {
                $item->{domain}         = 'ops';
                $item->{canonical_term} = 'Re-DMEK';
            }
            if ($v =~ /\b(?:kein\s+)?versagen\b/i && $c =~ /^(?:versagen|failure)$/i) {
                $item->{domain}         = 'icd10';
                $item->{canonical_term} = 'Hornhauttransplantatversagen';
            }
            if ($v =~ /\b(?:dehiszenz|teilabhebung|stufenbildung|abhebung|graft\s*detachment)\b/i && $v =~ /\btransplantat\b/i
                || $c =~ /\b(?:dehiszenz|teilabhebung|stufenbildung|graft\s*detachment)\b/i) {
                $item->{domain}         = 'icd10';
                $item->{canonical_term} = 'Hornhauttransplantat-Dehiszenz';
            }
            # Spaltlampenbefund "IOL in loco" von OPS nach ICD-10 (Z96.1 Pseudophakie) umlenken:
            if ($v =~ /\biol\s+in\s+loco\b/i || $c =~ /\biol\s+in\s+loco\b/i) {
                $item->{domain}         = 'icd10';
                $item->{canonical_term} = 'Pseudophakie';
            }
            if ($item->{domain} eq 'loinc' && $v =~ /\b(?:prothese|augenprothese|enukleation|anophthalm\w*)\b/i) {
                $item->{domain} = 'skip';
            }
            # Atrophiekonus / myoper Konus / peripapilläre Atrophie ist ein HPO-Phänotyp, kein ICD-10!
            if ($item->{domain} eq 'icd10' && $v =~ /\b(?:atrophiekonus|myoper\s+konus|peripapill[äa]re\s+atrophie)\b/i) {
                $item->{domain} = 'hpo';
            }
            # Verhindert Extraktion von OPs, die nur reevaluiert/geplant wurden
            if ($item->{domain} eq 'ops' && $v =~ /\b(?:reevaluation|evaluation|planung|erwägung|geplant|option)\s+(?:einer?|zur?)\b/i) {
                $item->{domain} = 'skip';
            }
            if ($v =~ /\bhinterkapsel\s+(?:eröffnet|gefenstert)\b/i) {
                # Entweder als Zustand nach Kapsulotomie führen:
                $item->{canonical_term} = 'Zustand nach Kapsulotomie';
                $item->{domain} = 'icd10';
            }
            if ($v =~ /\bverbandslinse\w*\b/i) {
                $item->{domain} = 'skip'; # Verhindert absurde chirurgische OPS-Fehlzuordnungen
            }
            # Motilitäts- / Bewegungseinschränkungen gehören zu HPO, nicht ICD-10!
            if ($item->{domain} eq 'icd10' && $v =~ /\b(?:hebung|senkung|abduktion|adduktion|motilit[äa]t)\w*einschr[äa]nkung\b/i
                || $c =~ /\b(?:abduktions|hebungs|motilit[äa]t)\w*einschr[äa]nkung\b/i) {
                $item->{domain} = 'hpo';
            }

            # Lamina papyracea Destruktion / Orbitainvasion zu HPO umlenken
            if ($item->{domain} eq 'icd10' && $v =~ /\b(?:lamina\s+papyracea|destruktion|knochendestruktion|invasion.*orbita)\b/i) {
                $item->{domain} = 'hpo' if ($item->{domain} // '') eq 'icd10';
            }
            if ($v =~ /\b(?:bindehautinjektion|gefaessinjektion|injektion\s+der\s+bindehaut)\b/i && $v !~ /\b(?:ivom|injektion\s+von|intravitreal)\b/i) {
                $item->{domain} = 'hpo';
                $item->{canonical_term} = 'Conjunctival hyperemia';
            }
            if ($v =~ /\b(?:schl[äa]fe|stirn|gesicht|haut|periorbital)\b/i && $v =~ /\b(?:sensibilit[äa]t|taubheit|hyp[äa]sthesie)\b/i) {
                $item->{domain} = 'hpo';
                $item->{canonical_term} = 'Hypoesthesia';
            }
            if (($item->{domain} // '') eq 'atc' && $v =~ /\b(?:pollen|gr[äa]ser|hausstaub|tierhaar|milben|heuschnupfen)\b/i) {
                $item->{domain} = 'icd10';
            }

            # PATCH 2026-10-23: Silikonöl/SF6/C2F6/C3F8 sind Tamponaden, keine Medikamente
            # (sonst z. B. Dimeticon oder Ultraschall-Kontrastmittel); übernimmt der Dokumentscan.
            if (($item->{domain} // '') eq 'atc' && ($item->{verbatim_text} // '') =~ $TAMP_TOKEN_RE) {
                $self->app->log->info("[TAMPONADE] ATC-Item '$item->{verbatim_text}' übernimmt der Dokumentscan.");
                $item->{domain} = 'skip';
            }

            # PATCH 2026-10-22: Items, die nur aus Zielrefraktion/CDE/IOL-Stärke bestehen, übernimmt
            # der Dokumentscan (build_cataract_op_measurements); keine HPO/OPS-Fehlkodierung.
            if (($item->{domain} // '') ne 'loinc') {
                my $rest = strip_cataract_op_parameters($item->{verbatim_text}, $cat_ctx);
                if ($rest ne _cat_normalize($item->{verbatim_text} // '') && $rest !~ /\p{L}{4,}/) {
                    $self->app->log->info("[CATARACT OP] Item '$item->{verbatim_text}' ($item->{domain}) übernimmt der Dokumentscan.");
                    $item->{domain} = 'skip';
                }
            }

        }

        # Benannte Entzündungen (…itis) zusätzlich als Diagnose kodieren.
        # Die HPO-Zeile bleibt erhalten, damit phänotypbasierte Kriterien weiter greifen.
        my @dual_icd;
        for my $it (@$atomic_items) {
            next unless ($it->{domain} // '') eq 'hpo';
            my $c = $it->{canonical_term} // '';
            next unless $c =~ /itis\b/i;
            next if $c =~ /\bvitritis\b/i;          # Glaskörperzellen: Befund, keine Diagnose
            push @dual_icd, { %$it, domain => 'icd10' };
            $self->app->log->info("[DUAL CODING] '$c' zusätzlich als icd10");
        }
        push @$atomic_items, @dual_icd;

        @$atomic_items = grep { ($_->{domain} // '') ne 'skip' } @$atomic_items;

        my @feature_promises;
        my @measurement_promises;
        my @disease_promises;
        my @procedure_promises;
        my @medication_promises;

        # PATCH 2026-10-22: Zielrefraktion, Phako-Zeitleistungswert und IOL-Stärke aus dem ganzen Dokument
        my %cat_done;
        my $cat_date;
        {
            # Messdatum = OP-Datum aus dem Bericht, nicht das Verarbeitungsdatum
            $cat_date = _cat_doc_date($text_content, $reference_date);
            my @cat_params = extract_cataract_op_parameters($text_content);
            if (my @cat_meas = build_cataract_op_measurements(\@cat_params, $cat_date // $reference_date)) {
                $cat_done{ $_->{kind} } = 1 for grep { $_->{side} } @cat_params;
                $self->app->log->info('[CATARACT OP] Dokumentscan: ' . join(', ',
                    map { "$_->{assay}{id} = $_->{value}{quantity}{value}" } @cat_meas));
                push @measurement_promises, Mojo::Promise->resolve(\@cat_meas);
            }
            # PATCH 2026-10-23: Endotamponade (Silikonöl / Gas / Luft)
            if (my @tamp_meas = build_endotamponade_measurements([ extract_endotamponade($text_content) ],
                                                                 $cat_date // $reference_date)) {
                $self->app->log->info('[TAMPONADE] Dokumentscan: ' . join(', ',
                    map { "$_->{assay}{id} = $_->{value}{ontologyClass}{label}" } @tamp_meas));
                push @measurement_promises, Mojo::Promise->resolve(\@tamp_meas);
            }
        }

        my $detected_sex = 'UNKNOWN';
        my $detected_age_iso = undef;

        foreach my $item (@$atomic_items) {
            $DIAG_CTX = sprintf('item domain=%s | canon=%s | verbatim=%s',
                $item->{domain} // '', $item->{canonical_term} // '', $item->{verbatim_text} // '');
            my $v_text      = $item->{verbatim_text} // '';
            my $canon_term  = $item->{canonical_term} // '';
            my $event_date  = $item->{event_date} // '';
            my $domain      = lc($item->{domain} // 'hpo');
            my $demo_type   = lc($item->{demographic_type} // 'none');
            my $demo_val    = $item->{demographic_value} // '';
            my $is_ex       = to_bool($item->{is_exclusion});

            my $time_from_verb  = extract_event_date($v_text, $reference_date);
            my $time_from_event = extract_event_date($event_date, $reference_date);
            my $item_timestamp  = $time_from_event // $time_from_verb;

            # STUFE 1: Nur innerhalb derselben Klausel (begrenzt durch Komma, Semikolon oder Zeilenumbruch) nach Datum suchen:
            if (!$item_timestamp && length($v_text) > 3) {
                # Verhindert, dass Datumsangaben von Nachbar-Medikamenten über Kommata hinweg überspringen:
                if ($text_content =~ /(?:^|[\n\r,;])\s*([^,\n\r;]{0,100}\Q$v_text\E[^,\n\r;]{0,100})(?=[\n\r,;]|$)/i) {
                    my $surrounding_clause = $1;
                    $item_timestamp = extract_event_date($surrounding_clause, $reference_date);
                }
            }
            # STUFE 2: Pseudodatum-Fallback für alle historischen Einträge (is_history = true)
            # Verhindert, dass alte Diagnosen wie Endophthalmitis ohne Datum als "akut" fehlinterpretiert werden!
            if (!$item_timestamp && to_bool($item->{is_history})) {
                $item_timestamp = "PAST-UK-UK";
                $self->app->log->info("[HISTORICAL PSEUDODATE] '$canon_term' (is_history=1) erhält Pseudodatum $item_timestamp");
            }
            
            my $item_lat = lc($item->{laterality} // 'none');
            if ($item_lat eq 'none' || !$item_lat) {
                if ($v_text =~ /\b(?:RA|OD|rechts?|right|R\b|R:|diagnosen\s*R|fundus\s*R|vaa\s*R|visus\s*R|tensio\s*R|oct\s*R)\b/i) {
                    $item_lat = 'right';
                } elsif ($v_text !~ /(?:\/|pro\s*)l(?:iter)?\b/i && $v_text =~ /(?:\b(?:LA|OS|links?|left|diagnosen\s*L|fundus\s*L|vaa\s*L|visus\s*L|tensio\s*L|oct\s*L)\b|(?<!\/)\bL\s*:)/i) {
                    $item_lat = 'left';
                } elsif ($v_text =~ /\b(?:BA|OU|beidseits|beide|bilateral|B\b|B:|diagnosen\s*B)\b/i) {
                    $item_lat = 'bilateral';
                }
            }

            # --- DEMOGRAPHICS ---
            if ($domain eq 'demographic' || $demo_type eq 'sex' || $demo_type eq 'age'
                || $v_text =~ /\b(?:sex|gender|geschlecht|female|male|weiblich|männlich|age|aged|\d+\s*years? old)\b/i) {

                if ($demo_type eq 'sex' || $v_text =~ /\b(?:sex|gender|geschlecht|female|male|weiblich|männlich)\b/i) {
                    if ($demo_val =~ /female/i || $v_text =~ /\b(?:female|weiblich|frau)\b/i) {
                        $detected_sex = 'FEMALE';
                    } elsif ($demo_val =~ /male/i || $v_text =~ /\b(?:male|männlich|mann)\b/i) {
                        $detected_sex = 'MALE';
                    }
                }
                elsif ($demo_type eq 'age' || $v_text =~ /\b(?:age|aged|jahre?|years?)\b/i) {
                    next if $v_text =~ /\b(?:ssw|schwangerschaftswoche|gestation\w*)\b/i;
                    next if $demo_val =~ /\b(?:ssw|schwangerschaftswoche|gestation\w*)\b/i;

                    my $years = 0;
                    if ($v_text =~ /\blebensalter\s*:\s*(\d+)\b/i) { $years = $1; }
                    elsif ($demo_val =~ /^(\d+)(?:\s*years?|\s*jahre?)?$/i) { $years = $1; }
                    elsif ($v_text =~ /\b(\d+)\s*(?:years?|jahre?|y\.?o\.?)\b/i) { $years = $1; }

                    if ($years > 0) {
                        $detected_age_iso = sprintf("P%dY", $years);
                    }
                }
                next;
            }

            my $context_str = $v_text . " " . $canon_term;
            my $lat_code    = $self->get_laterality_hpo_object($item_lat, $context_str);

            next if $is_ex && ($domain eq 'ops' || $domain eq 'atc');

            # --- LOINC & MEASUREMENTS ---
            if ($domain eq 'loinc'
                || $canon_term =~ /\b(?:visus|visual\s*acuity|refraction|refraktion|skiaskop\w*|skia|tensio|iop|tonometrie|augendruck|blutdruck|bp|rr)\b/i
                || $v_text =~ /\b(?:refraktion|skiaskop\w*|c[- ]?skia\w*)\b/i) {

                # PATCH 2026-10-22: Zielrefraktion/CDE/IOL-Stärke nicht als gemessene Refraktion werten.
                # Fand der Dokumentscan keine Seite, Item-Lateralität als Fallback nutzen.
                # PATCH 2026-10-23: Tamponade-Angaben ("SF6 20%") nicht als Messwert parsen
                next if $v_text =~ $TAMP_TOKEN_RE
                     && $v_text !~ /\b(?:visus|tensio|iod|iop|refrakt\w*|sph|cyl|endothel\w*|pachy\w*)\b/i;

                # (kein Bare-Block: "next" muss die Item-Schleife treffen)
                my $cat_rest = strip_cataract_op_parameters($v_text, $cat_ctx);
                if ($cat_rest ne _cat_normalize($v_text)) {
                    my @cat_p = grep { !$cat_done{ $_->{kind} } }
                                extract_cataract_op_parameters($v_text, ctx => $cat_ctx,
                                    fallback_side => _cat_side($item_lat), doc_text => $text_content);
                    if (my @cat_m = build_cataract_op_measurements(\@cat_p,
                            $cat_date // ((($item_timestamp // '') =~ /^\d{4}-\d{2}-\d{2}$/) ? $item_timestamp : $reference_date))) {
                        $cat_done{ $_->{kind} } = 1 for grep { $_->{side} } @cat_p;
                        push @measurement_promises, Mojo::Promise->resolve(\@cat_m);
                    }
                    next unless $cat_rest =~ /\d/
                        && $cat_rest =~ /\b(?:visus|refraktion|refraction|tensio|iop|sph|cyl|skia\w*|endothel\w*|pachy\w*)/i;
                    $v_text = $cat_rest;
                    $canon_term = '' if $canon_term =~ /\b(?:target|ziel|cde|cumulative|zeitleistung|iol|intraocular\s+lens|linse|lens\s+power)/i;
                }

                my $is_visus_candidate = (
                    $canon_term =~ /\b(?:visual\s*acuity|visus|refraction|refraktion|skiaskop\w*|c[- ]?skia\w*|sphere|sphäre|cylinder|zylinder)\b/i
                    || $v_text =~ /\b(?:visus|sehschärfe|visual\s*acuity|aufnahmevisus|entlassvisus|refraktion|skiaskop\w*|c[- ]?skia\w*|sc\b|cc\b|hbw\b|lsp\b|lsw\b|nulla\s*lux|lochblende|lb\b)\b/i
                ) && ($v_text !~ /\b(?:osdi|vas|but|tbut|pachymetrie|k1|k2|kmax|astigmatismus|rr|blutdruck)\b/i);

                my $time_obs = $item_timestamp;
                # Bei aktuellem Visusbefund (auch mit "sc:", "cc:", "AR:") immer das Referenzdatum der Konsultation nutzen:
                if ($is_visus_candidate && $v_text =~ /^\s*visus\s*[rlb]?\s*:\s*(?:sc\s*[:=]?\s*|cc\s*[:=]?\s*|m\.?e\.?b\.?\s*[:=]?\s*)?[\d\.,]+/i) {
                    $time_obs = $reference_date;
                } else {
                    $time_obs //= $reference_date;
                }

                if ($is_visus_candidate) {
                    my $parsed_eye = extract_visus_and_refraction($v_text, $text_content);
                    if ($parsed_eye && (defined $parsed_eye->{visus_value} || defined $parsed_eye->{sphere}
                                        || defined $parsed_eye->{lb_value})) {   # PATCH 2026-10-14
                        my @eye_meas = build_ophthalmic_loinc_measurements($parsed_eye, $item_lat, $time_obs,
                                                                           $self->ophthalmic_loinc_resolver);
                        if (@eye_meas) {
                            push @measurement_promises, Mojo::Promise->resolve(\@eye_meas);
                            next;
                        }
                    }
                }

                my $parsed_quant = parse_quantitative_constraint($v_text) // parse_quantitative_constraint($demo_val);

                if ($parsed_quant && $parsed_quant->{is_bilateral_pressure}) {
                    my $m_ra = {
                        assay => { id => "LOINC:79892-6", label => "Right eye Intraocular pressure" },
                        value => { quantity => { comparator => '=', value => $parsed_quant->{right_iop}, unit => { label => "mmHg" } } },
                        modifiers => [
                            { id => "LP7753-9", label => "Measurement: = $parsed_quant->{right_iop} mmHg" },
                            { id => "HP:0012834", label => "Right" }
                        ],
                        ($time_obs ? (timeOfCollection => { timestamp => $time_obs }) : ())
                    };
                    my $m_la = {
                        assay => { id => "LOINC:79893-4", label => "Left eye Intraocular pressure" },
                        value => { quantity => { comparator => '=', value => $parsed_quant->{left_iop}, unit => { label => "mmHg" } } },
                        modifiers => [
                            { id => "LP7753-9", label => "Measurement: = $parsed_quant->{left_iop} mmHg" },
                            { id => "HP:0012835", label => "Left" }
                        ],
                        ($time_obs ? (timeOfCollection => { timestamp => $time_obs }) : ())
                    };
                    push @measurement_promises, Mojo::Promise->resolve([ $m_ra, $m_la ]);
                    next;
                }
                if ($parsed_quant && $parsed_quant->{is_bilateral_hertel}) {
                    my $m_ra = {
                        assay => { id => "LOINC:28998-3", label => "Right eye Exophthalmia Exophthalmometer.Hertel" },
                        value => { quantity => { comparator => '=', value => $parsed_quant->{right_hertel}, unit => { label => "mm" } } },
                        modifiers => [
                            { id => "LP7753-9", label => "Measurement: = $parsed_quant->{right_hertel} mm" },
                            { id => "HP:0012834", label => "Right" }
                        ],
                        ($time_obs ? (timeOfCollection => { timestamp => $time_obs }) : ())
                    };
                    my $m_la = {
                        assay => { id => "LOINC:28999-1", label => "Left eye Exophthalmia Exophthalmometer.Hertel" },
                        value => { quantity => { comparator => '=', value => $parsed_quant->{left_hertel}, unit => { label => "mm" } } },
                        modifiers => [
                            { id => "LP7753-9", label => "Measurement: = $parsed_quant->{left_hertel} mm" },
                            { id => "HP:0012835", label => "Left" }
                        ],
                        ($time_obs ? (timeOfCollection => { timestamp => $time_obs }) : ())
                    };
                    push @measurement_promises, Mojo::Promise->resolve([ $m_ra, $m_la ]);
                    next;
                }
                if ($parsed_quant && $parsed_quant->{is_bilateral_bmo}) {
                    my $m_ra = {
                        assay => { id => "LOINC:86301-9b", label => "Right eye Bruch membrane opening area by OCT" },
                        value => { quantity => { comparator => '=', value => $parsed_quant->{right_bmo}, unit => { label => "mm2" } } },
                        modifiers => [
                            { id => "LP7753-9", label => "Measurement: = $parsed_quant->{right_bmo} mm2" },
                            { id => "HP:0012834", label => "Right" }
                        ],
                        ($time_obs ? (timeOfCollection => { timestamp => $time_obs }) : ())
                    };
                    my $m_la = {
                        assay => { id => "LOINC:86290-4b", label => "Left eye Bruch membrane opening area by OCT" },
                        value => { quantity => { comparator => '=', value => $parsed_quant->{left_bmo}, unit => { label => "mm2" } } },
                        modifiers => [
                            { id => "LP7753-9", label => "Measurement: = $parsed_quant->{left_bmo} mm2" },
                            { id => "HP:0012835", label => "Left" }
                        ],
                        ($time_obs ? (timeOfCollection => { timestamp => $time_obs }) : ())
                    };
                    push @measurement_promises, Mojo::Promise->resolve([ $m_ra, $m_la ]);
                    next;
                }

                my $is_explicit_bp = ($parsed_quant && $parsed_quant->{is_blood_pressure})
                    || ($v_text =~ /\b(?:rr|blutdruck|bp|entgleisung)\b/i && $v_text =~ /\b(\d{2,3})\s*[\/;]\s*(\d{2,3})\b/)
                    || ($v_text =~ /^\s*(\d{2,3})\s*[\/;]\s*(\d{2,3})\s*(?:mmhg)?\s*$/i);

                if ($is_explicit_bp) {
                    my ($sys, $dia);
                    if ($parsed_quant && $parsed_quant->{is_blood_pressure}) {
                        $sys = $parsed_quant->{systolic};
                        $dia = $parsed_quant->{diastolic};
                    } elsif ($v_text =~ /\b(\d{2,3})\s*[\/;]\s*(\d{2,3})\b/) {
                        ($sys, $dia) = ($1 + 0, $2 + 0);
                    }

                    if ($sys && $dia && $sys > 30 && $dia > 20) {
                        my $meas_sys = {
                            assay => { id => "LOINC:8480-6", label => "Systolic blood pressure" },
                            value => { quantity => { comparator => '=', value => $sys, unit => { label => "mmHg" } } },
                            modifiers => [{ id => "LP7753-9", label => "Measurement: = $sys mmHg" }]
                        };
                        my $meas_dia = {
                            assay => { id => "LOINC:8462-4", label => "Diastolic blood pressure" },
                            value => { quantity => { comparator => '=', value => $dia, unit => { label => "mmHg" } } },
                            modifiers => [{ id => "LP7753-9", label => "Measurement: = $dia mmHg" }]
                        };
                        $meas_sys->{timeOfCollection} = { timestamp => $time_obs } if defined $time_obs;
                        $meas_dia->{timeOfCollection} = { timestamp => $time_obs } if defined $time_obs;

                        push @measurement_promises, Mojo::Promise->resolve([ $meas_sys, $meas_dia ]);
                        next;
                    }
                }

                my $loinc_search_term = prepare_loinc_search_term($v_text, $canon_term, $item_lat);

                my $p = $self->map_to_loinc_async($loinc_search_term, $doc_lang, { context => $v_text })->then(sub {   # PATCH 2026-09-25
                    my $mapped = shift;
                    return [] unless defined $mapped && defined $mapped->{id};

                    my $quant = parse_quantitative_constraint($v_text)
                             // parse_quantitative_constraint($demo_val);

                    # PATCH 2026-10-14: unplausible Messwerte verwerfen statt falsch zu speichern
                    unless (loinc_value_plausible($mapped->{id}, $quant)) {
                        $self->app->log->warn(sprintf("[LOINC IMPLAUSIBLE] '%s' -> %s: %s verworfen.",
                            $v_text, $mapped->{id},
                            (ref $quant eq 'HASH' && defined $quant->{value}) ? "$quant->{value} $quant->{unit}" : 'kein Messwert'));
                        return [];
                    }

                    my $meas_obj = {
                        assay => { id => $mapped->{id}, label => $mapped->{label} // $v_text },
                        modifiers => []
                    };

                    if (defined $quant && defined $quant->{value}) {
                        my $quant_fmt = "$quant->{comparator} $quant->{value} $quant->{unit}";
                        push @{$meas_obj->{modifiers}}, { id => "LP7753-9", label => "Measurement: $quant_fmt" };
                        $meas_obj->{value} = {
                            quantity => { comparator => $quant->{comparator}, value => $quant->{value}, unit => { label => $quant->{unit} } }
                        };
                    } else {
                        my $qual_label = ($v_text =~ /positiv|gezeigt|erkannt/i) ? "Positive / Detected" : "Examined";
                        $meas_obj->{value} = {
                            ontologyClass => { id => "NCIT:C25250", label => $qual_label }
                        };
                        push @{$meas_obj->{modifiers}}, { id => "LP7753-9", label => $v_text };
                    }

                    push @{$meas_obj->{modifiers}}, $lat_code if defined $lat_code;
                    $meas_obj->{timeOfCollection} = { timestamp => ($time_obs // $reference_date) };

                    return [ $meas_obj ];
                });

                push @measurement_promises, $p;
                next;
            }
            # --- ICD-10 DIAGNOSES ---
            elsif ($domain eq 'icd10') {
                my $context_str = $v_text . " " . ($canon_term // '');
                my $lat_code    = $self->get_laterality_hpo_object($item_lat, $context_str);

                my $search_icd = (defined $canon_term && length($canon_term) > 1) ? $canon_term : $v_text;
                # enrich liefert überwiegend englische HPO-Suchbegriffe. Für den deutschen
                # ICD-Index nur übernehmen, wenn ein kuratierter ICD-Intercept darauf greift.
                my $enriched_icd = enrich_term_with_section_context($search_icd, "$v_text $canon_term", $text_content);
                if (defined $enriched_icd && $enriched_icd ne $search_icd
                    && $self->check_database_intercept('icd10', $enriched_icd, $v_text)) {
                    $search_icd = $enriched_icd;
                }
                my $icd_opts = {
                    context    => $v_text,
                    site       => $item->{anatomical_site},
                    is_history => to_bool($item->{is_history}),
                };

                my $p = $self->map_to_icd10_async($search_icd, $canon_term, $doc_lang, $icd_opts)->then(sub {
                    my $mapped = shift;
                    return undef unless defined $mapped && defined $mapped->{id};

                    my $chosen_label;
                    # Bei Z88.8 mit ATC-Code Vorrang für das formatierte Label:
                    if ($mapped->{id} eq 'ICD10:Z88.8' && $mapped->{label} =~ /^ATC:/i) {
                        $chosen_label = $mapped->{label};
                    } elsif (defined $canon_term && length($canon_term) > 1) {
                        $chosen_label = $canon_term;
                    } elsif (defined $mapped->{label} && length($mapped->{label})) {
                        $chosen_label = $mapped->{label};
                    } else {
                        $chosen_label = $v_text;
                    }
                    $chosen_label =~ s/^\s+|\s+$//g;

                    my $disease_obj = {
                        term => {
                            id    => $mapped->{id},
                            label => $chosen_label
                        }
                    };
                    $disease_obj->{excluded}    = Mojo::JSON->true if $is_ex;
                    $disease_obj->{primarySite} = $lat_code if defined $lat_code;
                    $disease_obj->{onset}       = { timestamp => $item_timestamp } if defined $item_timestamp;

                    return $disease_obj;
                });
                push @disease_promises, $p;
            }
            # --- OPS PROCEDURES ---
            elsif ($domain eq 'ops') {
                my $search_proc = (defined $canon_term && length($canon_term) > 1) ? $canon_term : $v_text;

                if ($v_text =~ /\b(avastin|bevacizumab|lucentis|ranibizumab|eylea|aflibercept|vabysmo|faricimab|beovu|brolucizumab|ozurdex|dexamethason|vitreal[\s\-]*s|triamcinolon)\b/i) {
                    my $substance = $1;
                    my $p_atc_auto = $self->map_to_atc_async($substance, $doc_lang, { context => $v_text })->then(sub {   # PATCH 2026-09-25
                        my $mapped_atc = shift;
                        return undef unless $mapped_atc && $mapped_atc->{id};

                        my $chosen_med_label = (defined $canon_term && length($canon_term) > 1 && $canon_term =~ /$substance/i)
                            ? $canon_term
                            : ($mapped_atc->{label} // ucfirst($substance));

                        my $med_obj = { agent => { id => $mapped_atc->{id}, label => $chosen_med_label } };
                        $med_obj->{performedTime} = $item_timestamp if defined $item_timestamp;
                        $med_obj->{bodySite}      = $lat_code if defined $lat_code;
                        return $med_obj;
                    });
                    push @medication_promises, $p_atc_auto;
                }

                my $p = $self->map_to_ops_async($search_proc, $doc_lang,
                    { context => $v_text, site => $item->{anatomical_site} })->then(sub {
                    my $mapped = shift;
                    return undef unless $mapped && $mapped->{id};

                    my $chosen_label;
                    if (defined $canon_term && length($canon_term) > 1) {
                        $chosen_label = $canon_term;
                    } elsif (defined $mapped->{label} && length($mapped->{label})) {
                        $chosen_label = $mapped->{label};
                    } else {
                        $chosen_label = $v_text;
                    }
                    $chosen_label =~ s/^\s+|\s+$//g;

                    my $proc_obj = { code => { id => $mapped->{id}, label => $chosen_label } };
                    $proc_obj->{performedTime} = $item_timestamp if defined $item_timestamp;
                    $proc_obj->{bodySite}      = $lat_code if defined $lat_code;
                    return $proc_obj;
                });
                push @procedure_promises, $p;
            }
            # --- ATC MEDICATIONS ---
            elsif ($domain eq 'atc') {
                # PATCH 2026-09-24: kanonischen Begriff zuerst prüfen. Bei Kombinationszeilen
                # ("Vigamox, Kanamycin und Voriconazol") würde sonst die erste passende Regel
                # des Verbatim-Textes für jeden Wirkstoff der Zeile gelten.
                my $direct_hit;
                if (defined $canon_term && length($canon_term) > 1) {
                    $direct_hit = $self->check_database_intercept('atc', $canon_term);
                    $direct_hit //= $self->check_database_intercept('atc', $v_text)
                        unless $v_text =~ /,|;|\s\/\s|\w\/\p{L}|\b(?:und|sowie|bzw\.?|im\s+Wechsel|i\.\s*W\.)\b/i;
                } else {
                    $direct_hit = $self->check_database_intercept('atc', $v_text);
                }
                next if $direct_hit && $direct_hit->{suppress};

                if ($direct_hit) {
                    $self->app->log->info("[ATC DB INTERCEPT OVERRIDE] '" . ($canon_term // '') . " / $v_text' -> $direct_hit->{id} ($direct_hit->{label})");
                    my $med_obj = { agent => { id => $direct_hit->{id}, label => $direct_hit->{label} } };
                    $med_obj->{performedTime} = $item_timestamp if defined $item_timestamp;
                    $med_obj->{bodySite}      = $lat_code if defined $lat_code;
                    push @medication_promises, Mojo::Promise->resolve($med_obj);
                    next;
                }

                my $search_med = (defined $canon_term && length($canon_term) > 1) ? $canon_term : $v_text;
                my $p = $self->map_to_atc_async($search_med, $doc_lang, { context => $v_text })->then(sub {   # PATCH 2026-09-25
                    my $mapped = shift;
                    return undef unless $mapped && $mapped->{id};

                    my $chosen_label;
                    if (defined $canon_term && length($canon_term) > 1) {
                        $chosen_label = $canon_term;
                    } elsif (defined $mapped->{label} && length($mapped->{label})) {
                        $chosen_label = $mapped->{label};
                    } else {
                        $chosen_label = $v_text;
                    }
                    $chosen_label =~ s/^\s+|\s+$//g;

                    my $med_obj = { agent => { id => $mapped->{id}, label => $chosen_label } };
                    $med_obj->{performedTime} = $item_timestamp if defined $item_timestamp;
                    $med_obj->{bodySite}      = $lat_code if defined $lat_code;
                    return $med_obj;
                });
                push @medication_promises, $p;
            }
            # --- HPO PHENOTYPES ---
            else {
                # Intercepts nur auf den kanonischen Begriff. Der Verbatim-Text enthält oft
                # weitere Befunde ("keine Hautausschläge ... Sehverschlechterung") und dient
                # nur noch als Kontext für den Scope-Guard.
                my $direct_hit;
                if (defined $canon_term && length($canon_term) > 1) {
                    $direct_hit = $self->check_database_intercept('hpo', $canon_term, $v_text);
                } else {
                    $direct_hit = $self->check_database_intercept('hpo', $v_text);
                }
                next if $direct_hit && $direct_hit->{suppress};

                my $search_term = (defined $canon_term && length($canon_term) > 1) ? $canon_term : $v_text;
                $search_term = enrich_term_with_section_context($search_term, "$v_text $canon_term", $text_content);

                my $context_str = $v_text . " " . ($canon_term // '');
                my $lat_code    = $self->get_laterality_hpo_object($item_lat, $context_str);

                if ($direct_hit) {
                    $self->app->log->info("[HPO DB INTERCEPT OVERRIDE] '$canon_term / $v_text' -> $direct_hit->{id} ($direct_hit->{label})");
                    my @modifiers;
                    push @modifiers, $lat_code if defined $lat_code;
                    my $node = {
                        type      => { id => $direct_hit->{id}, label => $canon_term || $direct_hit->{label} },
                        modifiers => \@modifiers
                    };
                    $node->{excluded} = Mojo::JSON->true if $is_ex;
                    $node->{onset}    = { timestamp => $item_timestamp } if defined $item_timestamp;

                    push @feature_promises, Mojo::Promise->resolve($node);
                    next;
                }

                my $p = $self->map_to_hpo_async($search_term, 0, $doc_lang,
                    { context => $v_text, site => $item->{anatomical_site} })->then(sub {
                    my $mapped = shift;
                    return undef unless $mapped && $mapped->{id};

                    my $chosen_label;
                    if (defined $canon_term && length($canon_term) > 1) {
                        $chosen_label = $canon_term;
                    } elsif (defined $mapped->{label} && length($mapped->{label})) {
                        $chosen_label = $mapped->{label};
                    } else {
                        $chosen_label = $v_text;
                    }
                    $chosen_label =~ s/^\s+|\s+$//g;

                    my @modifiers;
                    push @modifiers, $lat_code if defined $lat_code;

                    my $node = {
                        type      => { id => $mapped->{id}, label => $chosen_label },
                        modifiers => \@modifiers
                    };
                    $node->{excluded} = Mojo::JSON->true if $is_ex;
                    $node->{onset}    = { timestamp => $item_timestamp } if defined $item_timestamp;

                    return $node;
                });
                push @feature_promises, $p;
            }
        }

        # PHASE 2 PROGRESS TRACKING: Jedes Mapping zählt anteilig hoch (50% bis 92%)
        my @all_mapping_promises = (@feature_promises, @measurement_promises, @disease_promises, @procedure_promises, @medication_promises);
        my $total_map = scalar(@all_mapping_promises) || 1;
        my $done_map  = 0;

        my $track_sub = sub {
            my $res = shift;
            $done_map++;
            my $pct = int(50 + ($done_map / $total_map) * 42);
            $self->notify_task_progress($task_id, 'dense_retrieval', $pct, "Ontologie-Abgleich $done_map/$total_map ($pct%)...");
            return $res;
        };

        @feature_promises     = map { $_->then($track_sub) } @feature_promises;
        @measurement_promises = map { $_->then($track_sub) } @measurement_promises;
        @disease_promises     = map { $_->then($track_sub) } @disease_promises;
        @procedure_promises   = map { $_->then($track_sub) } @procedure_promises;
        @medication_promises  = map { $_->then($track_sub) } @medication_promises;

        my $p_hpo   = @feature_promises     ? Mojo::Promise->all(@feature_promises)     : Mojo::Promise->resolve();
        my $p_loinc = @measurement_promises ? Mojo::Promise->all(@measurement_promises) : Mojo::Promise->resolve();
        my $p_icd   = @disease_promises     ? Mojo::Promise->all(@disease_promises)     : Mojo::Promise->resolve();
        my $p_proc  = @procedure_promises   ? Mojo::Promise->all(@procedure_promises)   : Mojo::Promise->resolve();
        my $p_med   = @medication_promises  ? Mojo::Promise->all(@medication_promises)  : Mojo::Promise->resolve();

        return Mojo::Promise->all($p_hpo, $p_loinc, $p_icd, $p_proc, $p_med)->then(sub {
            my ($h_res, $l_res, $i_res, $pr_res, $m_res) = @_;

            $self->notify_task_progress($task_id, 'assembly', 95, "Phenopacket Assemblierung & Deduplizierung...");

            my @final_features = grep { defined } map { $_->[0] } @$h_res;

            my @final_measurements;
            foreach my $m_item (map { $_->[0] } @$l_res) {
                if (ref $m_item eq 'ARRAY') {
                    push @final_measurements, grep { defined } @$m_item;
                } elsif (ref $m_item eq 'HASH') {
                    push @final_measurements, $m_item;
                }
            }

            # Deduplizierung der Messwerte (verhindert z. B. doppelte Tensio-Messungen)
            my %seen_measurements;
            my @deduped_measurements;
            foreach my $m (@final_measurements) {
                next unless $m && $m->{assay} && $m->{assay}{id};
                my $assay_id = $m->{assay}{id};
                my $mv  = ref $m->{value} eq 'HASH' ? $m->{value} : {};
                my $val = (ref $mv->{quantity} eq 'HASH' && defined $mv->{quantity}{value})
                        ? $mv->{quantity}{value}
                        : (ref $mv->{ontologyClass} eq 'HASH'
                            # PATCH 2026-10-23: Label mitzählen, sonst fallen z. B. "Air" und "SF6 20%"
                            # (beide NCIT:C25250) zu einer Messung zusammen
                            ? (($mv->{ontologyClass}{id} // '') . '#' . ($mv->{ontologyClass}{label} // '')) : '');
                my $lat = 'none';
                foreach my $mod (@{$m->{modifiers} // []}) {
                    if ($mod->{id} =~ /^HP:001283[245]$/) {
                        $lat = $mod->{id};
                        last;
                    }
                }
                my $time = $m->{timeOfCollection}{timestamp} // '';
                my $sig = "$assay_id|$lat|$val|$time";
                push @deduped_measurements, $m unless $seen_measurements{$sig}++;
            }
            @final_measurements = @deduped_measurements;

            my @raw_diseases     = grep { defined } map { $_->[0] } @$i_res;
            my @raw_procedures   = grep { defined } map { $_->[0] } @$pr_res;
            my @raw_medications  = grep { defined } map { $_->[0] } @$m_res;

            @final_features = grep {
                defined $_ && $_->{type}{id} ne 'HP:0000118'
            } @final_features;

            my %features_by_key;
            foreach my $f (@final_features) {
                next unless $f && $f->{type}{id};
                my $lat_id = ($f->{modifiers} && @{$f->{modifiers}} && ref($f->{modifiers}[0]) eq 'HASH')
                           ? ($f->{modifiers}[0]{id} // 'none') : 'none';
                my $key = "$f->{type}{id}|$lat_id";

                if (!exists $features_by_key{$key}) {
                    $features_by_key{$key} = $f;
                } else {
                    if ($f->{onset} && !$features_by_key{$key}{onset}) {
                        $features_by_key{$key}{onset} = $f->{onset};
                    }
                    if (to_bool($f->{excluded})) {
                        $features_by_key{$key}{excluded} = Mojo::JSON->true;
                    }
                }
            }
            @final_features = values %features_by_key;

            my %lateralized_feature_types;
            foreach my $f (@final_features) {
                my $lat_id = ($f->{modifiers} && @{$f->{modifiers}}) ? ($f->{modifiers}[0]{id} // 'none') : 'none';
                if ($lat_id ne 'none') {
                    $lateralized_feature_types{$f->{type}{id}} = 1;
                }
            }

            @final_features = grep {
                my $f = $_;
                my $lat_id = ($f->{modifiers} && @{$f->{modifiers}}) ? ($f->{modifiers}[0]{id} // 'none') : 'none';
                !($lat_id eq 'none' && $lateralized_feature_types{$f->{type}{id}});
            } @final_features;

            foreach my $f (@final_features) {
                if ($f->{modifiers} && ref $f->{modifiers} eq 'ARRAY') {
                    @{$f->{modifiers}} = grep { ref $_ eq 'HASH' && scalar keys %$_ } @{$f->{modifiers}};
                }
            }

            my %diseases_by_code;
            foreach my $d (@raw_diseases) {
                next unless $d && $d->{term}{id};
                my $code = $d->{term}{id};
                my $is_excluded = to_bool($d->{excluded}) ? 1 : 0;
                
                # Bei H35.38 oder Sammelcodes den klinischen Begriff anhängen:
                my $clean_label = lc($d->{term}{label} // '');
                $clean_label =~ s/[^\p{L}\p{N}]+//g;
                
                my $key = "$code|$is_excluded";
                if ($code =~ /^ICD10:(?:H35|H26|Z88|T88|T78|M06)/i) {
                    $key .= "|$clean_label";
                }
                push @{$diseases_by_code{$key}}, $d;
            }

            my $get_site_id = sub {
                my ($obj) = @_;
                return 'none' unless ref $obj eq 'HASH' && ref $obj->{primarySite} eq 'HASH';
                return $obj->{primarySite}{id} // 'none';
            };

            my @final_diseases;
            foreach my $code (keys %diseases_by_code) {
                my @entries = @{$diseases_by_code{$code}};
                my $bilateral_entry = (grep { $get_site_id->($_) eq 'HP:0012832' } @entries)[0];

                if ($bilateral_entry) {
                    for my $e (@entries) {
                        if ($e->{onset} && !$bilateral_entry->{onset}) {
                            $bilateral_entry->{onset} = $e->{onset};
                        }
                    }
                    push @final_diseases, $bilateral_entry;
                } else {
                    my %seen_sites;
                    for my $e (@entries) {
                        my $site = $get_site_id->($e);
                        push @final_diseases, $e unless $seen_sites{$site}++;
                    }
                }
            }

            my $has_specific_cataract = (grep { $_->{term}{id} =~ /^ICD10:H25\.[0-8]/ } @final_diseases) ? 1 : 0;
            if ($has_specific_cataract) {
                @final_diseases = grep { $_->{term}{id} ne 'ICD10:H25.9' } @final_diseases;
            }

            foreach my $d (@final_diseases) {
                if (exists $d->{primarySite}) {
                    if (!ref $d->{primarySite} || ref $d->{primarySite} ne 'HASH' || !scalar keys %{$d->{primarySite}}) {
                        delete $d->{primarySite};
                    }
                }
            }

            my %seen_procs;
            my @final_procedures;

            foreach my $p (@raw_procedures) {
                next unless $p && $p->{code}{id};
                
                my $p_code = $p->{code}{id};
                my $p_site = $p->{bodySite} ? ($p->{bodySite}{id} // 'none') : 'none';
                my $p_time = $p->{performedTime};

                my $already_exists = 0;
                for my $existing (@final_procedures) {
                    my $e_code = $existing->{code}{id};
                    my $e_site = $existing->{bodySite} ? ($existing->{bodySite}{id} // 'none') : 'none';
                    my $e_time = $existing->{performedTime};

                    # Gleicher OPS-Code am gleichen Auge
                    if ($p_code eq $e_code && $p_site eq $e_site) {
                        # Fall 1: Exakt gleiches Datum
                        if (defined $p_time && defined $e_time && $p_time eq $e_time) {
                            $already_exists = 1;
                            last;
                        }
                        # Fall 2: Einer der beiden Einträge hat KEIN Datum (narrative Wiederholung in Anamnese)
                        # -> Das vorhandene konkrete Datum gewinnt immer!
                        if (!defined $p_time && defined $e_time) {
                            $already_exists = 1;
                            last;
                        }
                        if (defined $p_time && !defined $e_time) {
                            $existing->{performedTime} = $p_time; # Datum nachtragen
                            $already_exists = 1;
                            last;
                        }
                    }
                }
                push @final_procedures, $p unless $already_exists;
            }

            my @final_medications;
            foreach my $m (@raw_medications) {
                next unless $m && $m->{agent}{id};
                my $m_time = $m->{performedTime};
                my $m_site = $m->{bodySite} ? ($m->{bodySite}{id} // '') : '';

                my $is_duplicate = 0;
                for my $existing (@final_medications) {
                    if ($existing->{agent}{id} eq $m->{agent}{id}) {
                        my $e_time = $existing->{performedTime};
                        my $e_site = $existing->{bodySite} ? ($existing->{bodySite}{id} // '') : '';

                        # Verschiedene Augen sind keine Dubletten; eine fehlende Seite wird nachgetragen
                        next if $m_site ne '' && $e_site ne '' && $m_site ne $e_site;

                        if (!defined $m_time || !defined $e_time || $m_time eq $e_time) {
                            $existing->{performedTime} //= $m_time;
                            $existing->{bodySite}      //= $m->{bodySite} if $m->{bodySite};
                            $is_duplicate = 1;
                            last;
                        }

                        if (abs(date_diff_in_days($e_time, $m_time)) <= 14) {
                            $existing->{bodySite} //= $m->{bodySite} if $m->{bodySite};
                            $is_duplicate = 1;
                            last;
                        }
                    }
                }
                push @final_medications, $m unless $is_duplicate;
            }

            my @medical_actions;
            foreach my $proc (@final_procedures) {
                my $act = { procedure => { code => $proc->{code} } };
                $act->{procedure}{bodySite} = $proc->{bodySite} if $proc->{bodySite};
                if ($proc->{performedTime}) {
                    $act->{procedure}{performed} = { timestamp => $proc->{performedTime} };
                }
                push @medical_actions, $act;
            }
            foreach my $med (@final_medications) {
                my $treatment_obj = { agent => $med->{agent} };
                if ($med->{performedTime}) {
                    $treatment_obj->{performedTime} = $med->{performedTime};
                }
                if ($med->{bodySite}) {
                    $treatment_obj->{bodySite} = $med->{bodySite};
                }
                push @medical_actions, { treatment => $treatment_obj };
            }

            my $subject_obj = {
                id       => $candidate_id ? "candidate-$candidate_id" : "anonymous-patient",
                sex      => $detected_sex,
                taxonomy => { id => "NCBITaxon:9606", label => "homo sapiens" }
            };
            if (defined $detected_age_iso) {
                $subject_obj->{timeAtLastEncounter} = { age => { iso8601duration => $detected_age_iso } };
            }

            my @deduped_features;
            for my $i (0 .. $#final_features) {
                my $f1 = $final_features[$i];
                my $lat1 = ($f1->{modifiers}[0] ? $f1->{modifiers}[0]{id} : '');
                my $is_subsumed = 0;

                for my $j (0 .. $#final_features) {
                    next if $i == $j;
                    my $f2 = $final_features[$j];
                    my $lat2 = ($f2->{modifiers}[0] ? $f2->{modifiers}[0]{id} : '');
                    next unless $lat1 eq $lat2;
                    next unless to_bool($f1->{excluded}) == to_bool($f2->{excluded});

                    if ($self->is_subclass_of($f2->{type}{id}, $f1->{type}{id}) && $f1->{type}{id} ne $f2->{type}{id}) {
                        $is_subsumed = 1;
                        last;
                    }
                }
                push @deduped_features, $f1 unless $is_subsumed;
            }
            @final_features = @deduped_features;

            print STDERR "\n=======================================================\n";
            print STDERR ">>> [PHENOPACKET GENERATION SUMMARY]\n";
            print STDERR "    - Features:     " . scalar(@final_features) . "\n";
            print STDERR "    - Measurements: " . scalar(@final_measurements) . "\n";
            print STDERR "    - Diseases:     " . scalar(@final_diseases) . "\n";
            print STDERR "    - Procedures:   " . scalar(@final_procedures) . "\n";
            print STDERR "    - MedActions:   " . scalar(@medical_actions) . "\n";
            print STDERR "=======================================================\n\n";

            $self->notify_task_progress($task_id, 'finished', 100, "Phenopacket erfolgreich erzeugt");

            my $timestamp = strftime("%Y-%m-%dT%H:%M:%SZ", gmtime);
            my $ref_day = normalize_reference_day($reference_date);
            my $created = $ref_day
                ? "${ref_day}T00:00:00Z"
                : strftime("%Y-%m-%dT%H:%M:%SZ", gmtime);

            return {
                id                 => "phenopacket-" . time(),
                ($ref_day ? (reference_date => $ref_day) : ()),
                subject            => $subject_obj,
                phenotypicFeatures => \@final_features,
                measurements       => \@final_measurements,
                diseases           => \@final_diseases,
                procedures         => \@final_procedures,
                medicalActions     => \@medical_actions,
                metaData           => {
                    created                  => $created,
                    createdBy                => "$PIPELINE_CREATOR/$PIPELINE_VERSION",
                    phenopacketSchemaVersion => "2.0.0",
                    resources                => [
                        { id => "hp",     name => "human phenotype ontology", namespacePrefix => "HP" },
                        { id => "loinc",  name => "Logical Observation Identifiers Names and Codes", namespacePrefix => "LOINC" },
                        { id => "icd10",  name => "International Classification of Diseases 10", namespacePrefix => "ICD10" },
                        { id => "ops",    name => "Operationen- und Prozedurenschlüssel", namespacePrefix => "OPS" },
                        { id => "atc",    name => "Anatomical Therapeutic Chemical Classification", namespacePrefix => "ATC" },
                        { id => "snomed", name => "SNOMED Clinical Terms", namespacePrefix => "SNOMED" }
                    ]
                }
            };
        });
    });
};

post '/BBB/extract_phenopacket' => sub {
    my $c = shift;
    $c->inactivity_timeout(3000);
    my $payload        = $c->req->json // {};
    my $text_content   = $payload->{medical_report} // $payload->{report} // '';
    my $selected_model = $payload->{model};
    my $candidate_id   = $payload->{candidate_id};
    my $reference_date = $payload->{reference_date};
    my $deep_mode      = 0; #$payload->{deep_mode} // 0;
    my $task_id        = $payload->{task_id}   // 'phenopacket_extraction';

    unless ($text_content) {
        return $c->render(json => { error => "Missing payload content." }, status => 400);
    }

    $c->render_later;
    $c->generate_phenopacket_impl($text_content, $selected_model, $candidate_id, $reference_date, $deep_mode, $task_id)->then(sub {
        my $pp = shift;
        # Persistieren übernimmt das Backend; ein Fehler landet im catch (HTTP 500)
        $c->store_phenopacket($candidate_id, $pp) if defined $candidate_id && length $candidate_id;
        $c->render(json => $pp);
    })->catch(sub {
        my $err = shift;
        $c->notify_task_progress($task_id, 'failed', 0, "Pipeline-Fehler: $err");
        $c->render(json => { error => "Pipeline failure", details => "$err" }, status => 500);
    });
};

post '/BBB/extract_phenopacket_from_letter' => sub {
    my $c = shift;
    $c->inactivity_timeout(3000);
    my $json           = $c->req->json // {};
    my $text_content   = $json->{medical_letter}
                      // $json->{text}
                      // $json->{report}
                      // $c->req->text
                      // eval { decode('UTF-8', $c->req->body) }
                      // $c->req->body
                      // '';
    my $selected_model = $json->{model};
    my $candidate_id   = $json->{candidate_id};
    my $reference_date = $json->{reference_date};
    my $deep_mode      = $json->{deep_mode} // 0;
    my $task_id        = $json->{task_id}   // 'phenopacket_extraction';

    unless ($text_content) {
        return $c->render(json => { error => "Missing payload content." }, status => 400);
    }

    $c->render_later;
    $c->generate_phenopacket_impl($text_content, $selected_model, $candidate_id, $reference_date, $deep_mode, $task_id)->then(sub {
        my $pp = shift;
        # Persistieren übernimmt das Backend; ein Fehler landet im catch (HTTP 500)
        $c->store_phenopacket($candidate_id, $pp) if defined $candidate_id && length $candidate_id;
        $c->render(json => $pp);
    })->catch(sub {
        my $err = shift;
        $c->notify_task_progress($task_id, 'failed', 0, "Pipeline-Fehler: $err");
        $c->render(json => { error => "Pipeline failure", details => "$err" }, status => 500);
    });
};

# =========================================================================
# A) ENDPUNKT: ARZTBRIEF IMPORTIEREN & ASYNCHRON EXTRAHIEREN
#
# Payload (zusätzlich zu den bisherigen Feldern):
#   source              'argos' (Default) | 'dwh' | 'op' | ...  – Herkunft, Namensraum für doc_id
#                       ('op' u. a. aus ONTOTRIAL_SEPARATE_SOURCES: eigenständige
#                       Dokumente, kein Tagesabgleich mit Arztbriefen)
#   mode                'hard' | 'soft'                  – Default: hard für argos, soft sonst
#   date_tolerance_days 0..99 (Default ENV ONTOTRIAL_IMPORT_DATE_TOLERANCE_DAYS // 0)
#   force               true: Text immer übernehmen und neu extrahieren
#   dry_run             true: nur prüfen, nichts schreiben, nichts einreihen
#   tags                optionaler Tag-String für neu angelegte Kandidaten
#   priority            -100..100, Minion-Priorität (Default: argos 0, sonst -5).
#                       Hebt auch einen noch wartenden Job desselben Briefs an.
#
# hard: gleicher Brief (source + doc_id) -> aktualisieren, nur neu extrahieren,
#       wenn sich der Text geändert hat. Liegt für PIZ + Tag bereits ein Brief
#       einer ANDEREN Quelle vor (z. B. DWH-Kopie), wird diese Zeile übernommen
#       ("adopted") statt einen zweiten Kandidaten anzulegen.
# soft: ablehnen ("skipped"), wenn für PIZ + Tag (± Toleranz) schon irgendein
#       Brief registriert ist, derselbe Brief schon da ist oder derselbe Text
#       beim Patienten schon existiert. Überschreibt nie etwas.
#
# Antwort immer HTTP 200 mit status:
#   queued | would_queue | skipped | unchanged | already_queued
# Fehler: HTTP 4xx/5xx mit status 'rejected' bzw. 'error'.
# =========================================================================
my $import_date_tolerance = $ENV{ONTOTRIAL_IMPORT_DATE_TOLERANCE_DAYS} // 0;

# PATCH 2026-10-22: Quellen mit eigenständigen Dokumenten (z. B. OP-Berichte).
# Sie sind keine Kopien eines Arztbriefs: kein Abgleich über PIZ + Tag mit
# anderen Quellen (in beide Richtungen), keine Übernahme ("adopted"). Dubletten
# werden nur über source + doc_id und identischen Text erkannt.
our %SEPARATE_DOC_SOURCES = map { $_ => 1 } grep { length }
    split /\s*,\s*/, lc($ENV{ONTOTRIAL_SEPARATE_SOURCES} // 'op');

sub normalize_reference_day {
    my ($d) = @_;
    return undef unless defined $d && !ref $d && length $d;
    return $1 if $d =~ /^\s*(\d{4}-\d{2}-\d{2})/;
    return sprintf('%04d-%02d-%02d', $3, $2, $1) if $d =~ /^\s*(\d{1,2})\.(\d{1,2})\.(\d{4})\b/;
    # PATCH 2026-10-23: TT.MM.JJ ("25.8.11" = 25.08.2011), nie JJ.MM.TT
    return _ymd_from_dmy2($1, $2, $3) if $d =~ /^\s*(\d{1,2})\.(\d{1,2})\.(\d{2})(?!\d)/;
    return undef;
}

# =========================================================================
# PATCH 2026-10-23: ZWEISTELLIGE JAHRESZAHLEN IM BRIEFDATUM
# Deutsche Briefe schreiben TT.MM.JJ ("25.8.11"). Wird das vorgelagert als
# JJ.MM.TT gelesen, entsteht 2025-08-11 statt 2011-08-25 (bis hin zu Daten in
# der Zukunft). fix_swapped_reference_day erkennt genau dieses Muster anhand der
# Datumsangaben im Briefkopf und korrigiert es; alles andere bleibt unverändert.
# =========================================================================
sub _ymd_from_dmy2 {
    my ($d, $m, $yy) = @_;
    my $cur = (localtime)[5] % 100;
    my $y   = $yy <= $cur ? 2000 + $yy : 1900 + $yy;
    return undef unless $m >= 1 && $m <= 12 && $d >= 1 && $d <= 31;
    return sprintf('%04d-%02d-%02d', $y, $m, $d);
}

sub fix_swapped_reference_day {
    my ($ref, $text) = @_;
    return $ref unless defined $ref && $ref =~ /^(\d{4})-(\d{2})-(\d{2})/ && defined $text;
    my ($ry, $rm, $rd) = ($1 + 0, $2 + 0, $3 + 0);
    my $head = substr($text, 0, 2000);
    # Steht das Referenzdatum selbst im Kopf (TT.MM.JJ oder TT.MM.JJJJ), ist es bestätigt
    while ($head =~ /(?<![\d.])([0-3]?\d)\.([01]?\d)\.(\d{4}|\d{2})(?![\d.])/g) {
        my $iso = length($3) == 4 ? sprintf('%04d-%02d-%02d', $3, $2, $1) : _ymd_from_dmy2($1 + 0, $2 + 0, $3 + 0);
        return $ref if defined $iso && $iso eq substr($ref, 0, 10);
    }
    while ($head =~ /(?<![\d.])([0-3]?\d)\.([01]?\d)\.(\d{2})(?![\d.])/g) {
        my ($d, $m, $yy) = ($1 + 0, $2 + 0, $3 + 0);
        # Referenz = JJ.MM.TT-Lesart dieses TT.MM.JJ-Datums?
        next unless $ry == 2000 + $d && $rm == $m && $rd == $yy;
        my $fixed = _ymd_from_dmy2($d, $m, $yy) // next;
        next if $fixed eq substr($ref, 0, 10);
        warn "[REFERENCE DATE] $ref ist '$d.$m." . sprintf('%02d', $yy) . "' als JJ.MM.TT gelesen -> korrigiert auf $fixed\n";
        return $fixed;
    }
    return $ref;
}

helper extraction_pending => sub {
    my ($c, $job_id) = @_;
    return 0 unless $job_id;
    my $job = eval { $c->minion->job($job_id) } or return 0;
    return (($job->info->{state} // '') =~ /^(?:inactive|active)$/) ? 1 : 0;
};

helper enqueue_letter_extraction => sub {
    my ($c, $cand, $model, $deep_mode, $priority) = @_;
    # Ohne Vorgabe: Live-Briefe aus argos vor dem Altbestand abarbeiten
    $priority //= ($cand->{source} // '') eq 'argos' ? 0 : -5;
    my $job_id = $c->minion->enqueue(import_and_extract_letter_task => [{
        candidate_id   => $cand->{id},
        pseudonym      => $cand->{pseudonym},
        doc_id         => $cand->{doc_id},
        text_content   => $cand->{text},
        reference_date => $cand->{reference_date},
        model          => $model,
        deep_mode      => $deep_mode,
    }] => { priority => $priority });
    $c->pg->db->update('candidates', { extract_job_id => $job_id }, { id => $cand->{id} });
    return $job_id;
};

post '/BBB/import_and_extract_letter' => sub {
    my $c = shift;
    my $p = $c->req->json // {};

    my $pseudonym = $p->{pseudonym} // $p->{piz};
    my $doc_id    = $p->{doc_id}    // $p->{idbrief};
    my $text      = $p->{medical_report} // $p->{medical_letter} // $p->{text} // '';
    my $source    = lc($p->{source} // 'argos');
    my $mode      = lc($p->{mode}   // ($source eq 'argos' ? 'hard' : 'soft'));
    my $ref_day   = normalize_reference_day($p->{reference_date});
    $ref_day      = fix_swapped_reference_day($ref_day, $text) if defined $ref_day;   # PATCH 2026-10-23
    my $tol       = $p->{date_tolerance_days} // $import_date_tolerance;
    my $force     = to_bool($p->{force});
    my $dry_run   = to_bool($p->{dry_run});
    my $tags      = (defined $p->{tags} && !ref $p->{tags} && length $p->{tags}) ? $p->{tags} : undef;
    my $model     = $p->{model};
    my $deep_mode = $p->{deep_mode} // 0;
    my $prio      = $p->{priority};

    return $c->render(json => { status => 'rejected',
        error => "Pflichtfelder 'pseudonym' (oder 'piz') und 'medical_report' (oder 'text') fehlen." }, status => 400)
        unless defined $pseudonym && length $pseudonym && length $text;
    return $c->render(json => { status => 'rejected', error => "Ungültige Quelle '$source'." }, status => 400)
        unless $source =~ /^[a-z0-9_]{1,20}$/;
    return $c->render(json => { status => 'rejected', error => "Ungültiger Modus '$mode'." }, status => 400)
        unless $mode =~ /^(?:hard|soft)$/;
    if (defined $prio && !ref $prio && length $prio) {
        return $c->render(json => { status => 'rejected',
            error => "Ungültige Priorität '$prio' (ganze Zahl von -100 bis 100)." }, status => 400)
            unless $prio =~ /^-?\d{1,3}$/ && abs($prio) <= 100;
        $prio += 0;
    } else {
        $prio = undef;    # Standard je Quelle (enqueue_letter_extraction)
    }
    return $c->render(json => { status => 'rejected',
        error => "Soft-Push braucht ein gültiges 'reference_date' (JJJJ-MM-TT oder TT.MM.JJJJ)." }, status => 422)
        if $mode eq 'soft' && !$ref_day;

    $tol       = 0 unless defined $tol && $tol =~ /^\d{1,2}$/;
    $ref_day //= POSIX::strftime('%Y-%m-%d', localtime);
    $pseudonym = "$pseudonym";
    $doc_id    = (defined $doc_id && length $doc_id) ? "$doc_id" : undef;
    my $hash   = md5_hex(encode('UTF-8', $text));
    my $separate = $SEPARATE_DOC_SOURCES{$source} ? 1 : 0;
    my $sep_list = [ sort keys %SEPARATE_DOC_SOURCES ];

    my $db = $c->pg->db;
    my (%r, $enqueue_id, $bump_job);

    eval {
        my $tx = $db->begin;

        # argos- und DWH-Push laufen parallel: Importe desselben Patienten serialisieren
        $db->query('SELECT pg_advisory_xact_lock(hashtext(?))', "ontotrial-import|$pseudonym");

        # 1. Derselbe Brief aus derselben Quelle
        my $same = $doc_id ? $db->query(q{
            SELECT id, doc_hash, (phenopacket_json IS NOT NULL) AS has_pp, extract_job_id,
                   to_char(reference_date::date, 'YYYY-MM-DD') AS day
              FROM candidates
             WHERE doc_source = ? AND doc_id = ?
             ORDER BY id LIMIT 1
        }, $source, $doc_id)->hash : undef;
        my $self_id = $same ? $same->{id} : 0;

        # 2. Irgendein anderer Brief desselben Patienten am selben Tag (± Toleranz).
        #    Eigenständige Quellen (OP-Berichte) zählen hier nicht mit und werden
        #    selbst nicht über den Tag abgeglichen.
        my $same_day = $separate ? undef : $db->query(q{
            SELECT id, doc_source, doc_id::text AS doc_id,
                   to_char(reference_date::date, 'YYYY-MM-DD') AS day
              FROM candidates
             WHERE pseudonym = ?
               AND id <> ?
               AND reference_date >= ?::date - ?::int AND reference_date < ?::date + ?::int + 1
               AND lower(COALESCE(doc_source, '')) <> ALL(?)
             ORDER BY (doc_source = 'argos') DESC,
                      abs(reference_date::date - ?::date), id
             LIMIT 1
        }, $pseudonym, $self_id, $ref_day, $tol, $ref_day, $tol, $sep_list, $ref_day)->hash;

        # 3. Identischer Text beim selben Patienten (anderes Datum, andere ID)
        my $same_text = $db->query(q{
            SELECT id, doc_source, doc_id::text AS doc_id
              FROM candidates
             WHERE pseudonym = ? AND doc_hash = ? AND id <> ?
             ORDER BY id LIMIT 1
        }, $pseudonym, $hash, $self_id)->hash;

        my $conflict = sub {
            my $x = shift;
            return { candidate_id => $x->{id}, source => $x->{doc_source}, doc_id => $x->{doc_id},
                     (defined $x->{day} ? (reference_date => $x->{day}) : ()) };
        };
        my %row = (narrative_report => $text, doc_hash => $hash,
                   reference_date => $ref_day, phenopacket_json => undef);

        if ($same) {
            # Gleicher Text UND gleiches Datum: nichts zu tun. Ein geändertes Datum
            # verschiebt relative Zeitangaben und reference_date im Phenopacket -> neu extrahieren.
            if (!$force && ($same->{doc_hash} // '') eq $hash && ($same->{day} // '') eq $ref_day) {
                if ($same->{has_pp}) {
                    %r = (status => 'unchanged', candidate_id => $same->{id});
                } elsif ($c->extraction_pending($same->{extract_job_id})) {
                    %r = (status => 'already_queued', candidate_id => $same->{id});
                    $bump_job = $same->{extract_job_id};
                } else {
                    # Text gleich, aber (noch) kein Phenopacket und kein laufender Job
                    %r = (status => 'queued', action => 'requeued', candidate_id => $same->{id});
                    $enqueue_id = $same->{id};
                }
            } elsif ($mode eq 'soft' && !$force) {
                %r = (status => 'skipped', reason => 'same_doc', candidate_id => $same->{id});
            } else {
                $db->update('candidates', { %row, pseudonym => $pseudonym }, { id => $same->{id} });
                %r = (status => 'queued', action => 'updated', candidate_id => $same->{id});
                $enqueue_id = $same->{id};
            }
        }
        elsif ($mode eq 'soft' && $same_day) {
            %r = (status => 'skipped', reason => 'same_day', conflict => $conflict->($same_day));
        }
        elsif ($mode eq 'soft' && $same_text) {
            %r = (status => 'skipped', reason => 'same_text', conflict => $conflict->($same_text));
        }
        else {
            # hard: eine Kopie aus einer anderen (nicht manuellen) Quelle am selben Tag übernehmen
            my $adopt = ($mode eq 'hard' && !$separate) ? $db->query(q{
                SELECT id, doc_source, doc_id::text AS doc_id
                  FROM candidates
                 WHERE pseudonym = ?
                   AND doc_source NOT IN (?, 'manual')
                   AND lower(COALESCE(doc_source, '')) <> ALL(?)
                   AND reference_date >= ?::date - ?::int AND reference_date < ?::date + ?::int + 1
                 ORDER BY abs(reference_date::date - ?::date), id
                 LIMIT 1
            }, $pseudonym, $source, $sep_list, $ref_day, $tol, $ref_day, $tol, $ref_day)->hash : undef;

            if ($adopt) {
                $db->update('candidates',
                    { %row, doc_source => $source, doc_id => $doc_id, pseudonym => $pseudonym },
                    { id => $adopt->{id} });
                %r = (status => 'queued', action => 'adopted', candidate_id => $adopt->{id},
                      replaced => { source => $adopt->{doc_source}, doc_id => $adopt->{doc_id} });
                $enqueue_id = $adopt->{id};
            } else {
                my $id = $db->insert('candidates', {
                    %row,
                    pseudonym  => $pseudonym,
                    doc_id     => $doc_id,
                    doc_source => $source,
                    ($tags ? (tags => $tags) : ()),
                }, { returning => 'id' })->hash->{id};
                %r = (status => 'queued', action => 'created', candidate_id => $id);
                $enqueue_id = $id;
            }
        }

        if ($dry_run) {
            undef $tx;    # Rollback
            $r{dry_run} = Mojo::JSON->true;
            $r{status}  = 'would_queue' if $r{status} eq 'queued';
            delete $r{candidate_id} if ($r{action} // '') eq 'created';
            $enqueue_id = undef;
        } else {
            $tx->commit;
        }
        1;
    } or do {
        my $err = $@ || 'unbekannter Fehler';
        $c->app->log->error("[IMPORT ERROR] $source:" . ($doc_id // '-') . " (PIZ $pseudonym): $err");
        return $c->render(json => { status => 'error', error => "$err" }, status => 500);
    };

    # Noch wartenden Job desselben Briefs umpriorisieren. Laufende Jobs bleiben
    # unberührt (state = 'inactive' wird atomar im UPDATE geprüft).
    if ($bump_job && defined $prio && !$dry_run) {
        my $n = eval {
            # PATCH 2026-10-14: minion_jobs liegt in der Minion-Datenbank, nicht zwingend in der Hauptdatenbank
            $c->minion->backend->pg->db->query(
                q{UPDATE minion_jobs SET priority = ? WHERE id = ? AND state = 'inactive' AND priority <> ?},
                $prio, $bump_job, $prio)->rows;
        };
        $c->app->log->warn("[IMPORT] Priorität für Job $bump_job nicht geändert: $@") if $@;
        $r{priority_changed} = Mojo::JSON->true if $n;
    }

    if ($enqueue_id) {
        $r{job_id} = $c->enqueue_letter_extraction({
            id => $enqueue_id, pseudonym => $pseudonym, doc_id => $doc_id, source => $source,
            text => $text, reference_date => $ref_day,
        }, $model, $deep_mode, $prio);
    }
    $r{priority} = $prio if defined $prio;

    my $log_msg = sprintf("[IMPORT %s] %s:%s PIZ %s %s -> %s%s%s",
        uc($mode), $source, $doc_id // '-', $pseudonym, $ref_day, $r{status},
        ($r{action} ? " ($r{action})" : ''), ($r{reason} ? " ($r{reason})" : ''));
    $r{status} eq 'skipped' ? $c->app->log->debug($log_msg) : $c->app->log->info($log_msg);

    $c->render(json => {
        %r,
        pseudonym      => $pseudonym,
        doc_id         => $doc_id,
        source         => $source,
        reference_date => $ref_day,
        message        => sprintf("Arztbrief %s:%s (PIZ %s, %s): %s", $source, $doc_id // '-', $pseudonym, $ref_day, $r{status}),
    });
};


# =========================================================================
# B) MINION TASK: ASYNCHRONE ARZTBRIEF-EXTRAKTION (PHENOPACKET)
#    Neu: Job wird übersprungen bzw. sein Ergebnis verworfen, wenn der
#    Brieftext des Kandidaten inzwischen ersetzt wurde (z. B. DWH-Kopie
#    durch argos-Original übernommen). Verhindert, dass ein älterer Job
#    das Phenopacket des neueren überschreibt.
# =========================================================================
app->minion->add_task(import_and_extract_letter_task => sub {
    my ($job, $payload) = @_;
    my $app = $job->app;
    my $db  = $app->pg->db;

    my $candidate_id   = $payload->{candidate_id};
    my $pseudonym      = $payload->{pseudonym};
    my $text_content   = $payload->{text_content} // '';
    my $selected_model = $payload->{model};
    my $reference_date = $payload->{reference_date};
    my $deep_mode      = $payload->{deep_mode} // 0;
    my $task_id        = "minion_$candidate_id";

    # PATCH 2026-10-02: Watchdog. Hängt der Job (z. B. Regex-Backtracking),
    # werden Kontext und Perl-Stack protokolliert und der Kindprozess beendet.
    # Minion markiert den Job dann als fehlgeschlagen und gibt den Slot frei.
    # Ohne ->safe(1) läuft der Handler sofort, auch mitten in einem Regex.
    my $watchdog_s = $ENV{ONTOTRIAL_JOB_TIMEOUT} // 1800;
    POSIX::sigaction(POSIX::SIGALRM, POSIX::SigAction->new(sub {
        my $msg = sprintf("\n[%s] [MINION WATCHDOG] Job %s, Kandidat %s, nach %d s abgebrochen\nKontext: %s\n%s\n",
            scalar(localtime), $job->id, $candidate_id // '-', $watchdog_s,
            $main::DIAG_CTX // '-', Carp::longmess('Stack'));
        if (open my $fh, '>>:encoding(UTF-8)', $ENV{ONTOTRIAL_WATCHDOG_LOG} // '/tmp/ontotrial_watchdog.log') {
            print $fh $msg;
            close $fh;
        }
        POSIX::_exit(1);
    }));
    alarm $watchdog_s;

    my $my_hash    = md5_hex(encode('UTF-8', $text_content));
    my $is_current = sub {
        my $row = $db->query('SELECT md5(narrative_report) AS h FROM candidates WHERE id = ?', $candidate_id)->hash;
        return ($row && defined $row->{h} && $row->{h} eq $my_hash) ? 1 : 0;
    };

    unless ($is_current->()) {
        $app->log->info("[MINION TASK] Candidate $candidate_id: Brieftext wurde ersetzt oder gelöscht – Job übersprungen.");
        return $job->finish('superseded');
    }

    $job->note(status => 'processing', message => "Starte Extraktion für Pseudonym $pseudonym...", progress => 10);

    $app->generate_phenopacket_impl($text_content, $selected_model, $candidate_id, $reference_date, $deep_mode, $task_id)->then(sub {
        my $phenopacket = shift;

        unless ($is_current->()) {
            $app->log->info("[MINION TASK] Candidate $candidate_id: Brieftext wurde während der Extraktion ersetzt – Ergebnis verworfen.");
            return $job->finish('superseded');
        }

        # Speichert und benachrichtigt die GUI (Fireside Live-Sync)
        $app->store_phenopacket($candidate_id, $phenopacket, $text_content);

        $app->log->info("[MINION TASK] Extraktion für Candidate ID $candidate_id ($pseudonym) erfolgreich abgeschlossen.");
        $job->note(status => 'finished', message => "Extraktion für $pseudonym abgeschlossen.", progress => 100);
        $job->finish();
    })->catch(sub {
        my $err = shift;
        $app->log->error("[MINION TASK FEHLER] Extraktion für Candidate ID $candidate_id fehlgeschlagen: $err");
        $job->fail("Extraktionsfehler: $err");
    })->wait;
});
# =========================================================================
# MATCHING & TRACING ENGINE
# =========================================================================
get '/BBB/matches' => sub {
    my $self = shift;
    my $sql = q{
        SELECT m.*, t.name as trial_name, c.pseudonym as candidate_pseudonym,
        (CASE WHEN m.eligible = 1 THEN '🟢 Eligible'
              WHEN m.potentially_eligible = 1 THEN '🟠 Potentially Eligible'
              ELSE '🔴 Ineligible' END) as status_text
        FROM matches m
        LEFT JOIN trials t ON m.trial_id = t.id
        LEFT JOIN candidates c ON m.candidate_id = c.id
        ORDER BY m.timestamp DESC
    };
    $self->render(json => $self->pg->db->query($sql)->hashes->to_array);
};

post '/BBB/run_all_matches' => sub {
    my $c = shift;
    $c->inactivity_timeout(3000);

    my $payload      = eval { $c->req->json } // {};
    my $task_id      = (ref $payload eq 'HASH' ? $payload->{task_id} : undef) // 'targeted_matching';
    my $trial_id     = (ref $payload eq 'HASH' ? $payload->{trial_id} : undef);
    my $candidate_id = (ref $payload eq 'HASH' ? $payload->{candidate_id} : undef);
    my $tag          = (ref $payload eq 'HASH' ? $payload->{tag} : undef);

    my $log_target = ($trial_id ? "Trial: $trial_id " : "")
                   . ($candidate_id ? "Candidate: $candidate_id " : "")
                   . ($tag ? "Tag: '$tag' " : "");

    $c->app->log->info("[MATCHING START] Starte Match-Lauf (Task-ID: $task_id, $log_target)...");
    $c->render_later;

    # 1. Trials laden
    my $p_trials = $trial_id
        ? $c->pg->db->query_p("SELECT id, name, fhir_group_json FROM trials WHERE id = ?", $trial_id)
        : $c->pg->db->query_p("SELECT id, name, fhir_group_json FROM trials");

    # 2. Candidates laden (einzelner Patient, Tag-Kohorte oder alle)
    my $p_candidates;
    if ($candidate_id) {
        $p_candidates = $c->pg->db->query_p("SELECT id, pseudonym, doc_id, phenopacket_json, reference_date FROM candidates WHERE id = ?", $candidate_id);
    } elsif ($tag) {
        $p_candidates = $c->pg->db->query_p("SELECT id, pseudonym, doc_id, phenopacket_json, reference_date FROM candidates WHERE tags ILIKE ?", "%$tag%");
    } else {
        $p_candidates = $c->pg->db->query_p("SELECT id, pseudonym, doc_id, phenopacket_json, reference_date FROM candidates");
    }

    Mojo::Promise->all($p_trials, $p_candidates)->then(sub {
        my ($trials_res, $candidates_res) = @_;

        my $trials     = $trials_res->[0]->expand->hashes->to_array;
        my $candidates = $candidates_res->[0]->expand->hashes->to_array;

        my $total_trials     = scalar(@$trials);
        my $total_candidates = scalar(@$candidates);
        $c->app->log->info("[MATCHING DB] Geladen: $total_trials Trials und $total_candidates Candidates.");

        my $processed = 0;
        my $db = $c->pg->db;
        my $tx = $db->begin;

        foreach my $trial (@$trials) {
            my $curr_trial_id = $trial->{id};
            my $trial_name    = $trial->{name} // "ID $curr_trial_id";
            my $group         = $trial->{fhir_group_json};

            if ($group && !ref $group) {
                $group = eval { decode_json($group) };
            }

            unless (defined $group && ref $group eq 'HASH') {
                $c->app->log->warn("[MATCHING SKIP] Trial ID $curr_trial_id hat keine valide fhir_group_json.");
                next;
            }

            foreach my $candidate (@$candidates) {
                my $cand_id     = $candidate->{id};
                my $phenopacket = $candidate->{phenopacket_json};

                if ($phenopacket && !ref $phenopacket) {
                    $phenopacket = eval { decode_json($phenopacket) };
                }
                next unless defined $phenopacket && ref $phenopacket eq 'HASH';

                my $ref_date = $candidate->{reference_date} // POSIX::strftime("%Y-%m-%d", localtime);
                if ($ref_date =~ /^(\d{4}-\d{2}-\d{2})/) {
                    $ref_date = $1;
                }

                my ($is_eligible, $trace, $study_eye) = eval {
                    $c->evaluate_candidate_for_trial($group, $phenopacket, $ref_date);
                };

                if ($@) {
                    $c->app->log->error("[MATCHING EVAL ERROR] Trial $curr_trial_id x Cand $cand_id: $@");
                    next;
                }

                $trace //= [];
                my $any_potential = (grep { ($_->{status} // '') eq 'potentially_eligible' } @$trace) ? 1 : 0;
                my $trace_json    = eval { to_json($trace) } // '[]';

                my $sql = q{
                    INSERT INTO matches (trial_id, candidate_id, eligible, potentially_eligible, criteria_matches)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (trial_id, candidate_id)
                    DO UPDATE SET eligible = EXCLUDED.eligible,
                                  potentially_eligible = EXCLUDED.potentially_eligible,
                                  criteria_matches = EXCLUDED.criteria_matches,
                                  timestamp = CURRENT_TIMESTAMP
                };

                $db->query($sql, $curr_trial_id, $cand_id, ($is_eligible ? 1 : 0), $any_potential, $trace_json);
                $processed++;
            }
        }

        $tx->commit;
        $c->app->log->info("[MATCHING FINISHED] $processed Matches berechnet.");
        $c->notify_task_progress($task_id, 'finished', 100, "Abgeschlossen ($processed Matches).");
        $c->render(json => { success => 1, processed => $processed });
    })->catch(sub {
        my $err = shift;
        $c->app->log->error("[MATCHING FATAL] Fehler: $err");
        $c->notify_task_progress($task_id, 'failed', 0, "Match-Fehler: $err");
        $c->render(json => { error => "Match failure", details => "$err" }, status => 500);
    });
};

sub _hpo_to_int {
    my $hpo_str = shift;
    return undef unless $hpo_str;
    if ($hpo_str =~ /^hp:0*(\d+)$/i) { return int($1); }
    return undef;
}

my %HPO_SUBCLASS_CACHE;

helper is_subclass_of => sub {
    my ($self, $child_hpo_str, $parent_hpo_str) = @_;
    my $child_id  = _hpo_to_int($child_hpo_str);
    my $parent_id = _hpo_to_int($parent_hpo_str);
    return 0 unless defined $child_id && defined $parent_id;
    return 1 if $child_id == $parent_id;

    # 1. In-Memory Cache Lookup (verhindert tausende redundante CTE-Queries)
    my $cache_key = "$parent_id->$child_id";
    return $HPO_SUBCLASS_CACHE{$cache_key} if exists $HPO_SUBCLASS_CACHE{$cache_key};

    # 2. Rekursive CTE-Abfrage bei erstem Auftreten
    my $sql = q{
        WITH RECURSIVE descendants AS (
            SELECT idchild FROM public.isas WHERE idparent = ?
            UNION
            SELECT i.idchild FROM public.isas i JOIN descendants d ON i.idparent = d.idchild
        ) SELECT 1 FROM descendants WHERE idchild = ? LIMIT 1
    };

    my $next = $self->pg->db->query($sql, $parent_id, $child_id)->array;
    my $res  = $next ? ($next->[0] ? 1 : 0) : 0;

    return $HPO_SUBCLASS_CACHE{$cache_key} = $res;
};

helper is_icd10_subclass_of => sub {
    my ($self, $child_str, $parent_str) = @_;
    my $child  = uc($child_str // ''); $child =~ s/^ICD10://i; $child =~ s/\.//g;
    my $parent = uc($parent_str // ''); $parent =~ s/^ICD10://i; $parent =~ s/\.//g;
    return 0 unless $child && $parent;
    return 1 if $child eq $parent;
    return (index($child, $parent) == 0) ? 1 : 0;
};

helper is_ops_subclass_of => sub {
    my ($self, $child_str, $parent_str) = @_;
    my $child  = uc($child_str // ''); $child =~ s/^OPS://i; $child =~ s/\-//g;
    my $parent = uc($parent_str // ''); $parent =~ s/^OPS://i; $parent =~ s/\-//g;
    return 0 unless $child && $parent;
    return 1 if $child eq $parent;
    return (index($child, $parent) == 0) ? 1 : 0;
};

helper is_atc_subclass_of => sub {
    my ($self, $child_str, $parent_str) = @_;
    my $child  = uc($child_str // ''); $child =~ s/^ATC://i;
    my $parent = uc($parent_str // ''); $parent =~ s/^ATC://i;
    return 0 unless $child && $parent;
    return 1 if $child eq $parent;
    return (index($child, $parent) == 0) ? 1 : 0;
};

helper is_loinc_subclass_of => sub {
    my ($self, $child_str, $parent_str) = @_;
    my $child  = uc($child_str // ''); $child =~ s/^LOINC://i;
    my $parent = uc($parent_str // ''); $parent =~ s/^LOINC://i;
    return 0 unless $child && $parent;
    return ($child eq $parent) ? 1 : 0;
};

# =========================================================
# REAL TEMPORAL CONSTRAINT MATCHING ENGINE
# =========================================================
sub check_temporal_match {
    my ($perf_time_str, $ref_date_str, $value_quantity) = @_;
    return 1 unless $perf_time_str && $value_quantity;

    $ref_date_str //= POSIX::strftime("%Y-%m-%d", localtime);

    my ($y1, $m1, $d1) = $perf_time_str =~ /^(\d{4})-(\d{2})-(\d{2})/;
    my ($y2, $m2, $d2) = $ref_date_str  =~ /^(\d{4})-(\d{2})-(\d{2})/;
    return 1 unless $y1 && $y2;

    my $dt_perf = eval { DateTime->new(year => int($y1), month => int($m1), day => int($d1)) };
    my $dt_ref  = eval { DateTime->new(year => int($y2), month => int($m2), day => int($d2)) };
    return 1 unless $dt_perf && $dt_ref;

    # Calculate days elapsed between performedTime and reference_date
    my $days_ago = $dt_ref->delta_days($dt_perf)->in_units('days');
    if (DateTime->compare($dt_perf, $dt_ref) > 0) {
        $days_ago = -$days_ago; # Procedure was in the future relative to reference_date
    }

    my $target_val = ($value_quantity->{value} // 0) + 0;
    my $comp       = $value_quantity->{comparator} // '<=';
    my $unit       = lc($value_quantity->{unit} // 'd');

    # Normalize target timeframe to days
    my $target_days = $target_val;
    if    ($unit =~ /^(?:wk|w|weeks?)$/)  { $target_days *= 7; }
    elsif ($unit =~ /^(?:mo|m|months?)$/) { $target_days *= 30; }
    elsif ($unit =~ /^(?:a|y|years?)$/)  { $target_days *= 365; }

    # Perform temporal comparison
    if    ($comp eq '<=') { return $days_ago <= $target_days ? 1 : 0; }
    elsif ($comp eq '<')  { return $days_ago <  $target_days ? 1 : 0; }
    elsif ($comp eq '>=') { return $days_ago >= $target_days ? 1 : 0; }
    elsif ($comp eq '>')  { return $days_ago >  $target_days ? 1 : 0; }
    elsif ($comp eq '=')  { return $days_ago == $target_days ? 1 : 0; }

    return 1;
}

sub evaluate_and_trace_node {
    my ($c, $item, $contained_map, $phenopacket, $depth, $is_parent_exclude, $trace_arr, $context_perf_time, $ref_date) = @_;
    return 0 unless ref $item eq 'HASH';

    $ref_date //= $phenopacket->{reference_date} // POSIX::strftime("%Y-%m-%d", localtime);

    if (my $ref = $item->{valueReference}{reference}) {
        $ref =~ s/^#//;
        my $sub = $contained_map->{$ref};
        return evaluate_and_trace_node($c, $sub, $contained_map, $phenopacket, $depth, to_bool($item->{exclude}), $trace_arr, $context_perf_time, $ref_date) if $sub;
        return 0;
    }

    # --- GROUP NODE EVALUATION ---
    if ($item->{resourceType} && $item->{resourceType} eq 'Group') {
        my $comb_method = $item->{combinationMethod} // 'all-of';
        my $characteristics = $item->{characteristic} // [];
        my $is_exclude = ($is_parent_exclude || to_bool($item->{exclude})) ? 1 : 0;

        # First pass: Check if any member procedure/action has a performedTime to share with temporal sibling nodes
        my $shared_perf_time = $context_perf_time;
        unless ($shared_perf_time) {
            foreach my $char (@$characteristics) {
                my $c_code = $char->{code}{coding}[0]{code} // $char->{valueCodeableConcept}{coding}[0]{code} // '';
                if ($c_code =~ /^OPS:/i) {
                    foreach my $proc (@{$phenopacket->{procedures} // []}) {
                        if ($c->is_ops_subclass_of($proc->{code}{id}, $c_code)) {
                            $shared_perf_time = $proc->{performedTime} // (ref $proc->{performed} eq 'HASH' ? $proc->{performed}{timestamp} : undef);
                            last;
                        }
                    }
                } elsif ($c_code =~ /^ATC:/i) {
                    foreach my $act (@{$phenopacket->{medicalActions} // []}) {
                        if ($act->{treatment} && $c->is_atc_subclass_of($act->{treatment}{agent}{id}, $c_code)) {
                            $shared_perf_time = $act->{treatment}{performedTime} // (ref $act->{treatment}{performed} eq 'HASH' ? $act->{treatment}{performed}{timestamp} : undef);
                            last;
                        }
                    }
                }
                last if $shared_perf_time;
            }
        }

        my @child_results;
        foreach my $char (@$characteristics) {
            push @child_results, evaluate_and_trace_node($c, $char, $contained_map, $phenopacket, $depth + 1, $is_exclude, $trace_arr, $shared_perf_time, $ref_date);
        }

        if ($comb_method eq 'any-of') {
            return (grep { $_ == 1 } @child_results) ? 1 : 0;
        } else {
            return (grep { $_ == 0 } @child_results) ? 0 : 1;
        }
    }

    # --- ATOMIC CHARACTERISTIC EVALUATION ---
    if (my $coding = $item->{code}{coding}[0] // $item->{valueCodeableConcept}{coding}[0]) {
        my $crit_code = $coding->{code};
        my $crit_display = $coding->{display} // $crit_code;
        my $is_exclude = ($is_parent_exclude || to_bool($item->{exclude})) ? 1 : 0;

        # --- REAL TEMPORAL CONSTRAINT EVALUATION ---
        if ($crit_code eq 'temporal-constraint') {
            my $vq = $item->{valueQuantity};
            my $is_temporal_match = 1;
            my $match_label = "Temporal constraint evaluated";

            if ($context_perf_time && $vq) {
                $is_temporal_match = check_temporal_match($context_perf_time, $ref_date, $vq);
                my $req_str = "$vq->{comparator} $vq->{value} $vq->{unit}";
                $match_label = $is_temporal_match
                    ? "Performed ($context_perf_time) within $req_str of $ref_date"
                    : "Performed ($context_perf_time) EXCEEDS $req_str of $ref_date";
            } elsif (!$context_perf_time) {
                $is_temporal_match = $is_exclude ? 0 : 0;
                $match_label = "No procedure timestamp recorded";
            }

            my $status = $is_exclude
                ? ($is_temporal_match ? "exclusion_violation" : "exclusion_clear")
                : ($is_temporal_match ? "inclusion_met" : "inclusion_missing");

            push @$trace_arr, {
                criterion_code        => $crit_code,
                criterion_label       => $crit_display,
                is_exclusion          => $is_exclude,
                status                => $status,
                matched_patient_label => $match_label
            };

            return $is_exclude ? ($is_temporal_match ? 0 : 1) : $is_temporal_match;
        }

        # --- DEMOGRAPHIC INTERCEPTORS ---
        if ($crit_code eq '30525-0' || $crit_code eq '76689-9' || $crit_code eq 'LP7753-9') {
            my $status = $is_exclude ? "exclusion_clear" : "inclusion_met";
            push @$trace_arr, {
                criterion_code        => $crit_code,
                criterion_label       => $crit_display,
                is_exclusion          => $is_exclude,
                status                => $status,
                matched_patient_label => "Demographic/Measurement Rule Matched"
            };
            return 1;
        }

        my $val_coding = $item->{valueCodeableConcept}{coding}[0];
        if ($val_coding) {
            $crit_code = $val_coding->{code};
            $crit_display = $val_coding->{display} // $crit_code;
        }

        # --- OPHTHALMOLOGISCHER LATERALITÄTS-ABGLEICH ---
        if ($crit_code =~ /^(?:HP:001283[245]|SNOMED:(?:18944008|8966001|40638003)|26118[456]00[124])$/i) {
            my $lat_found = 0;

            # 1. In Phenotypic Features & Modifiers suchen (ausgeschlossene Befunde ignorieren!)
            foreach my $feat (@{$phenopacket->{phenotypicFeatures} // []}) {
                next if to_bool($feat->{excluded});
                if (is_laterality_match($feat->{type}{id}, $crit_code)) { $lat_found = 1; last; }
                foreach my $m (@{$feat->{modifiers} // []}) {
                    if (is_laterality_match($m->{id}, $crit_code)) { $lat_found = 1; last; }
                }
                last if $lat_found;
            }

            # 2. In Diagnosen suchen (ausgeschlossene Diagnosen ignorieren!)
            unless ($lat_found) {
                foreach my $dis (@{$phenopacket->{diseases} // []}) {
                    next if to_bool($dis->{excluded});
                    if ($dis->{primarySite} && is_laterality_match($dis->{primarySite}{id}, $crit_code)) {
                        $lat_found = 1; last;
                    }
                }
            }

            # 3. In Prozeduren suchen
            unless ($lat_found) {
                foreach my $proc (@{$phenopacket->{procedures} // []}) {
                    if ($proc->{bodySite} && is_laterality_match($proc->{bodySite}{id}, $crit_code)) {
                        $lat_found = 1; last;
                    }
                }
            }

            # 3b. In Medikamenten suchen (ausgeschlossene ignorieren)
            unless ($lat_found) {
                foreach my $act (@{$phenopacket->{medicalActions} // []}) {
                    my $tr = $act->{treatment};
                    next unless ref $tr eq 'HASH' && !to_bool($tr->{excluded});
                    if ($tr->{bodySite} && is_laterality_match($tr->{bodySite}{id}, $crit_code)) {
                        $lat_found = 1; last;
                    }
                }
            }

            # 4. In Messungen suchen
            unless ($lat_found) {
                foreach my $meas (@{$phenopacket->{measurements} // []}) {
                    foreach my $m (@{$meas->{modifiers} // []}) {
                        if (is_laterality_match($m->{id}, $crit_code)) { $lat_found = 1; last; }
                    }
                    last if $lat_found;
                }
            }

            my $status = $is_exclude
                ? ($lat_found ? "exclusion_violation" : "exclusion_clear")
                : ($lat_found ? "inclusion_met" : "inclusion_missing");

            push @$trace_arr, {
                criterion_code        => $crit_code,
                criterion_label       => $crit_display,
                is_exclusion          => $is_exclude,
                status                => $status,
                matched_patient_label => $lat_found ? "Laterality matched ($crit_display)" : "Laterality missing"
            };

            return $is_exclude ? ($lat_found ? 0 : 1) : ($lat_found ? 1 : 0);
        }

        # --- DIFFERENZIERTER ABGLEICH (VORHANDEN VS. AUSGESCHLOSSEN) ---
        my $present_match  = undef;
        my $excluded_match = undef;

        if ($crit_code =~ /^ICD10:/i) {
            foreach my $dis (@{$phenopacket->{diseases} // []}) {
                if ($c->is_icd10_subclass_of($dis->{term}{id}, $crit_code)) {
                    if (to_bool($dis->{excluded})) {
                        $excluded_match //= $dis;
                    } else {
                        $present_match = $dis;
                        last;
                    }
                }
            }
        } elsif ($crit_code =~ /^OPS:/i) {
            foreach my $proc (@{$phenopacket->{procedures} // []}) {
                if ($c->is_ops_subclass_of($proc->{code}{id}, $crit_code)) {
                    if (to_bool($proc->{excluded})) {
                        $excluded_match //= { type => $proc->{code} };
                    } else {
                        $present_match = { type => $proc->{code} };
                        last;
                    }
                }
            }
        } elsif ($crit_code =~ /^ATC:/i) {
            foreach my $act (@{$phenopacket->{medicalActions} // []}) {
                if ($act->{treatment} && $c->is_atc_subclass_of($act->{treatment}{agent}{id}, $crit_code)) {
                    if (to_bool($act->{treatment}{excluded})) {
                        $excluded_match //= { type => $act->{treatment}{agent} };
                    } else {
                        $present_match = { type => $act->{treatment}{agent} };
                        last;
                    }
                }
            }
        } elsif ($crit_code =~ /^LOINC:/i) {
            foreach my $meas (@{$phenopacket->{measurements} // []}) {
                if ($c->is_loinc_subclass_of($meas->{assay}{id}, $crit_code)) {
                    if (to_bool($meas->{excluded})) {
                        $excluded_match //= { type => $meas->{assay} };
                    } else {
                        $present_match = { type => $meas->{assay} };
                        last;
                    }
                }
            }
        } else {
            # HPO Phänotypen
            foreach my $feat (@{$phenopacket->{phenotypicFeatures} // []}) {
                if ($c->is_subclass_of($feat->{type}{id}, $crit_code)) {
                    if (to_bool($feat->{excluded})) {
                        $excluded_match //= $feat;
                    } else {
                        $present_match = $feat;
                        last;
                    }
                }
            }
        }

        # Hilfsfunktion zum sauberen Extrahieren von ID & Label
        my $extract_term_info = sub {
            my ($node) = @_;
            return (undef, undef) unless ref $node eq 'HASH';
            my $obj = $node->{term} // $node->{type} // $node->{code} // $node->{assay} // $node->{agent} // $node;
            return ($obj->{id}, $obj->{label} // $obj->{id});
        };

        my $success = 0;
        my $status  = "gray";
        my ($matched_id, $matched_lbl) = (undef, undef);

        if ($present_match) {
            # 1. Befund liegt aktiv beim Patienten vor
            ($matched_id, $matched_lbl) = $extract_term_info->($present_match);
            if ($is_exclude) {
                # Ausschlusskriterium verletzt! (Patient hat verbotenen Befund)
                $status  = "exclusion_violation";
                $success = 0;
            } else {
                # Einschlusskriterium erfüllt! (Patient hat geforderten Befund)
                $status  = "inclusion_met";
                $success = 1;
            }
        } elsif ($excluded_match) {
            # 2. Befund wurde explizit ausgeschlossen / negiert ('excluded: true')
            ($matched_id, $matched_lbl) = $extract_term_info->($excluded_match);
            if ($is_exclude) {
                # BEI AUSSCHLUSSKRITERIEN POSITIV GEWERTET:
                # Da die Krankheit nachweislich NICHT vorliegt, ist das Ausschlusskriterium bestanden (clear)
                $status  = "exclusion_clear";
                $success = 1;
                $matched_lbl = "Befundfrei / Ausgeschlossen: " . ($matched_lbl // $matched_id);
            } else {
                # BEI EINSCHLUSSKRITERIEN NEGATIV GEWERTET:
                # Da die geforderte Krankheit explizit negiert wurde, fehlt die Einschlussvoraussetzung
                $status  = "inclusion_missing";
                $success = 0;
                $matched_lbl = "Explizit negiert / abwesend: " . ($matched_lbl // $matched_id);
            }
        } else {
            # 3. Befund im Patientendatensatz nicht erwähnt
            if ($is_exclude) {
                # Kein Anhalt für Ausschluss -> Kriterium bestanden
                $status  = "exclusion_clear";
                $success = 1;
            } else {
                # Geforderter Einschluss nicht nachgewiesen -> Fehlt
                $status  = "inclusion_missing";
                $success = 0;
            }
        }

        push @$trace_arr, {
            criterion_code        => $crit_code,
            criterion_label       => $crit_display,
            is_exclusion          => $is_exclude,
            type                  => $is_exclude ? "Exclusion" : "Inclusion",
            indentation           => $depth,
            status                => $status,
            matched_patient_hpo   => $matched_id,
            matched_patient_label => $matched_lbl,
            is_group              => 0
        };

        return $success;
    }

    return 1;
}

# =========================================================================
# FEASIBILITY CHAT ASSISTANT & PHENOPACKET TOOL-CALLING ENGINE
# =========================================================================

helper get_parent_code_hierarchy => sub {
    my ($self, $domain, $code) = @_;
    return "" unless $domain && $code;
    my $db = $self->pg->db;

    if ($domain eq 'ops') {
        my $clean = $code; $clean =~ s/^OPS://i;
        my $row = eval { $db->query("SELECT parent_id, label FROM public.ops_terms WHERE id = ?", $clean)->hash };
        if ($row && $row->{parent_id}) {
            return sprintf(" | Übergeordneter breiter Code: OPS:%s (%s)", $row->{parent_id}, $row->{label} // '');
        }
    } elsif ($domain eq 'icd10') {
        my $clean = $code; $clean =~ s/^ICD10://i;
        my $row = eval { $db->query("SELECT parent_id, label FROM public.icd10_terms WHERE id = ?", $clean)->hash };
        if ($row && $row->{parent_id}) {
            return sprintf(" | Übergeordneter breiter Code: ICD10:%s (%s)", $row->{parent_id}, $row->{label} // '');
        }
    }
    return "";
};

helper get_feasibility_system_prompt => sub {
    my ($self) = @_;
    my $record = $self->get_llm_prompt('feasibility_chat_assistant');

    unless ($record && defined $record->{system_prompt} && length($record->{system_prompt})) {
        $self->app->log->error("[PROMPT ERROR] Kein aktiver Prompt 'feasibility_chat_assistant' in Tabelle public.llm_prompts gefunden.");
        die "Prompt 'feasibility_chat_assistant' fehlt oder ist inaktiv in public.llm_prompts.\n";
    }

    return $record->{system_prompt};
};

my $pheno_sql_tool_schema = {
    type     => 'function',
    function => {
        name        => 'execute_sql',
        description => 'Führt eine PostgreSQL SELECT/WITH-Abfrage auf "candidates" aus. '
                     . 'WICHTIG: Verwende COUNT(DISTINCT pseudonym) und array_agg(DISTINCT pseudonym). '
                     . 'VERWENDE NIEMALS jsonb_path_exists oder direkte Gleichheit "=" bei Codes! '
                     . 'Nutze IMMER die Funktion is_subclass_of(child_code, search_code) für hierarchische Vergleiche: '
                     . '- Symptome/Befunde: is_subclass_of(f->\'type\'->>\'id\', \'HP:...\') '
                     . '   UND ZWINGEND: COALESCE((f->>\'excluded\')::boolean, false) = false! '
                     . '- Diagnosen: is_subclass_of(d->\'term\'->>\'id\', \'ICD10:...\') '
                     . '   UND ZWINGEND: COALESCE((d->>\'excluded\')::boolean, false) = false! '
                     . '- Prozeduren: is_subclass_of(p->\'code\'->>\'id\', \'OPS:...\') '
                     . '- Medikamente: is_subclass_of(m->\'agent\'->>\'id\', \'ATC:...\') '
                     . 'Erstdiagnose: d->\'onset\'->>\'timestamp\'.',
        parameters  => {
            type       => 'object',
            properties => {
                sql => {
                    type        => 'string',
                    description => 'Die ausführbare PostgreSQL SELECT / WITH Abfrage mit LATERAL jsonb_array_elements und is_subclass_of().',
                },
            },
            required => ['sql'],
        },
    },
};

my $ontology_lookup_tool_schema = {
    type     => 'function',
    function => {
        name        => 'lookup_ontology_code',
        description => 'Ermittelt für einen medizinischen Freitext-Begriff (z.B. "feuchte Makuladegeneration", "IVOM", "Aflibercept", "Visus") '
                     . 'den zugehörigen Standard-Code (ICD10, OPS, ATC, LOINC oder HPO). Zuerst aufrufen, bevor SQL geschrieben wird!',
        parameters  => {
            type       => 'object',
            properties => {
                term => {
                    type        => 'string',
                    description => 'Der medizinische Suchbegriff.',
                },
                domain => {
                    type        => 'string',
                    enum        => ['icd10', 'ops', 'atc', 'loinc', 'hpo'],
                    description => 'Die Zieldomäne: icd10 (Diagnosen), ops (OPs/Injektionen), atc (Wirkstoffe), loinc (Messwerte), hpo (Symptome).',
                },
            },
            required => ['term', 'domain'],
        },
    },
};

my @pheno_chat_tools = ($pheno_sql_tool_schema, $ontology_lookup_tool_schema);

sub sanitize_phenopacket_sql {
    my ($sql) = @_;
    return '' unless defined $sql;

    # 1. Korrigiere jsonb_array_elements-Pfad von medications zu medicalActions
    $sql =~ s/jsonb_array_elements\s*\(\s*([a-zA-Z0-9_]+)\.phenopacket_json\s*->\s*'medications'\s*\)/jsonb_array_elements($1.phenopacket_json->'medicalActions')/gi;

    # 2. Korrigiere agent->id Zugriff, falls 'treatment' übersprungen wurde
    # Ersetzt: m->'agent'->>'id' oder ma->'agent'->>'id' durch ma->'treatment'->'agent'->>'id'
    $sql =~ s/([a-zA-Z0-9_]+)\s*->\s*'agent'\s*->>\s*'id'/$1->'treatment'->'agent'->>'id'/gi;

    # 3. Falls die Query zusätzlich auf procedures in medicalActions prüft
    $sql =~ s/([a-zA-Z0-9_]+)\s*->\s*'code'\s*->>\s*'id'/$1->'procedure'->'code'->>'id'/gi
        if $sql =~ /medicalActions/i && $sql !~ /->'procedure'/i;

    return $sql;
}

helper execute_safe_cohort_sql => sub {
    my ($self, $sql) = @_;
    my ($out, $err);

    # Kommentare und Whitespace am Anfang für die Validierung überspringen:
    my $stripped = $sql;
    $stripped =~ s/^(?:\s*|\/\*[\s\S]*?\*\/|--[^\n]*\n*)+//g;

    if ($stripped !~ /^(?:WITH|SELECT)\b/i) {
        return (undef, "Sicherheitsfehler: Es sind nur SELECT- und WITH-Abfragen erlaubt.");
    }

    $self->app->log->info("[COHORT CHAT SQL]: $sql");

    eval {
        my $results = $self->pg->db->query($sql)->hashes->to_array;
        if (@$results) {
            # Max 50 Zeilen an LLM zurückgeben, um Token-Limits zu schonen
            if (@$results > 50) {
                my @slice = @$results[0..49];
                $out = encode_json(\@slice) . "\n(Ergebnis auf 50 Zeilen gekürzt. Gesamtzeilen: " . scalar(@$results) . ")";
            } else {
                $out = encode_json($results);
            }
        } else {
            $out = "Abfrage erfolgreich ausgeführt: 0 Treffer gefunden.";
        }
    };
    $err = $@ if $@;
    return ($out, $err);
};

sub run_cohort_agent_loop {
    my ($c, $messages, $client_model, $step) = @_;
    if ($step >= 8) {
        return Mojo::Promise->resolve({ output => "Maximale Analyseschritte erreicht.", sql => "" });
    }

    my $llm_cfg = resolve_llm_config($client_model);
    my $api_payload = {
        model       => $llm_cfg->{model},
        messages    => $messages,
        temperature => 0.0,
        max_tokens  => 4096,
        tools       => \@pheno_chat_tools
    };

    return $ua->post_p($llm_cfg->{endpoint} => $llm_cfg->{headers} => json => $api_payload)->then(sub {
        my $tx = shift;
        unless ($tx->result && $tx->result->is_success) {
            die "LLM API Fehler: " . ($tx->error ? $tx->error->{message} : "Unbekannt");
        }

        my $raw_body = $tx->result->body;
        my $res = eval { decode_json($raw_body) } // clean_and_parse_json($raw_body);
        my $choice = $res->{choices}[0]{message} // {};
        my $tool_calls = $choice->{tool_calls} // [];
        
        # Text ermitteln (mit Fallback auf reasoning_content für gpt-oss-120b)
        my $content = $choice->{content} // '';
        if (!$content && $choice->{reasoning_content}) {
            $content = $choice->{reasoning_content};
        }
        $content =~ s/<think>.*?<\/think>//gs;
        $content =~ s/^\s+|\s+$//g;

        # Fallback für Modelle, die Tool-Calls im Freitext zurückgeben
        if (!@$tool_calls && $content =~ /```(?:json)?\s*(\{\s*"name"\s*:\s*"(?:execute_sql|lookup_ontology_code)".*?\})\s*```/s) {
            my $parsed = eval { decode_json($1) };
            if ($parsed && $parsed->{name}) {
                $tool_calls = [{
                    id       => 'call_' . time(),
                    type     => 'function',
                    function => { name => $parsed->{name}, arguments => encode_json($parsed->{arguments} // {}) }
                }];
                $content = '';
            }
        }

        if (@$tool_calls) {
            my $tc = $tool_calls->[0];
            my $func_name = $tc->{function}{name};
            my $args_raw  = $tc->{function}{arguments};
            my $args      = ref $args_raw eq 'HASH' ? $args_raw : (eval { decode_json($args_raw) } // {});
            my $tc_id     = $tc->{id} // 'call_id';

            push @$messages, $choice;

            if ($func_name eq 'execute_sql') {
                my $sql = $args->{sql} // '';
                $sql = sanitize_phenopacket_sql($sql);
                my ($out, $err) = $c->execute_safe_cohort_sql($sql);
                $c->app->log->info("[COHORT CHAT SQL RESULT]: " . ($err ? "ERROR: $err" : $out));

                push @$messages, {
                    role         => 'tool',
                    name         => 'execute_sql',
                    content      => $err ? "SQL-Fehler: $err\nACHTUNG: Verwende d->'term'->>'id' für Diagnosen und d->'onset'->>'timestamp' für das Datum!" : "Ergebnis:\n$out",
                    tool_call_id => $tc_id
                };
                return run_cohort_agent_loop($c, $messages, $client_model, $step + 1);
            }
            elsif ($func_name eq 'lookup_ontology_code') {
                my $term   = $args->{term} // '';
                my $domain = lc($args->{domain} // 'icd10');

                my $p;
                if ($domain eq 'icd10')    { $p = $c->map_to_icd10_async($term, undef, 'de'); }
                elsif ($domain eq 'ops')   { $p = $c->map_to_ops_async($term, 'de'); }
                elsif ($domain eq 'atc')   { $p = $c->map_to_atc_async($term, 'de'); }
                elsif ($domain eq 'loinc') { $p = $c->map_to_loinc_async($term, 'de'); }
                else                       { $p = $c->map_to_hpo_async($term, 0, 'de'); }

                return $p->then(sub {
                    my $hit = shift;
                    my $out = "Kein exakter Treffer.";
                    if ($hit && $hit->{id}) {
                        my $parent_info = $c->get_parent_code_hierarchy($domain, $hit->{id});
                        $out = "Gefundener Code: $hit->{id} ($hit->{label})" . $parent_info;
                    }
                    push @$messages, {
                        role         => 'tool',
                        name         => 'lookup_ontology_code',
                        content      => $out,
                        tool_call_id => $tc_id
                    };
                    return run_cohort_agent_loop($c, $messages, $client_model, $step + 1);
                });
            }
        }

        $c->app->log->info("[COHORT CHAT FINAL OUTPUT]: " . substr($content, 0, 150));
        return Mojo::Promise->resolve({ output => $content });
    });
}

# --- CHAT INITIALISIERUNG ---
post '/BBB/chat/init' => sub {
    my $c = shift;
    my $session_id = 'sess_' . time() . '_' . int(rand(10000));

    state $sessions = {};
    # Dynamisch aus DB laden:
    my $sys_prompt = $c->get_feasibility_system_prompt();
    $sessions->{$session_id} = [{ role => 'system', content => $sys_prompt }];

    $c->render(json => { status => 'ok', session_id => $session_id });
};

# =========================================================
# STATELESS COHORT CHAT QUERY (VOLLSTÄNDIGER ENDPUNKT)
# =========================================================
post '/BBB/chat/query' => sub {
    my $c = shift;
    $c->inactivity_timeout(300);

    my $payload = $c->req->json // {};
    my $prompt  = $payload->{prompt} // '';
    my $model   = $payload->{model};

    # Jede Anfrage startet frisch (stateless) mit aktuellem System-Prompt und NUR der neuen User-Anfrage
    my $sys_prompt = $c->get_feasibility_system_prompt();
    my $history    = [
        { role => 'system', content => $sys_prompt },
        { role => 'user',   content => $prompt }
    ];

    $c->render_later;

    run_cohort_agent_loop($c, $history, $model, 1)->then(sub {
        my $res = shift;

        # 1. Letzten ausgeführten SQL-Code aus Tool-Calls ermitteln
        my $last_sql = '';
        for my $msg (reverse @$history) {
            if ($msg->{tool_calls} && ref $msg->{tool_calls} eq 'ARRAY') {
                for my $tc (@{$msg->{tool_calls}}) {
                    if ($tc->{function}{name} eq 'execute_sql') {
                        my $args = eval { decode_json($tc->{function}{arguments}) };
                        $last_sql = $args->{sql} if $args && $args->{sql};
                        last;
                    }
                }
            }
            last if $last_sql;
        }

        my $clean_output = $res->{output} // '';

        # 2. Fallback: SQL aus Markdown-Codeblöcken extrahieren, falls nicht als Tool-Call geliefert
        if (!length($last_sql)) {
            if ($clean_output =~ /```(?:sql)?\s*([\s\S]*?)(?:```|$)/i) {
                my $candidate_sql = $1;
                # Prüfen, ob der Block tatsächlich eine SELECT- oder WITH-Query enthält
                if ($candidate_sql =~ /\b(?:SELECT|WITH)\b/i) {
                    $candidate_sql =~ s/^\s+|\s+$//g;
                    $last_sql = $candidate_sql;
                }
            }
        }

        # 3. SQL ausführen, Fehler sichern & Patienten-Pseudonyme sammeln
        my @found_patient_ids;
        my $db_error_msg = undef;

        if (length($last_sql)) {
            my ($db_out, $db_err) = $c->execute_safe_cohort_sql($last_sql);

            if ($db_err) {
                $db_error_msg = $db_err;
                $c->app->log->error("[COHORT SQL FEHLER]: $db_err");
                $clean_output .= "\n\n⚠️ **SQL-Ausführungsfehler:**\n```\n$db_err\n```";
            } elsif ($db_out) {
                $c->app->log->info("[COHORT SQL ERGEBNIS]: $db_out");
                my $parsed_res = eval { decode_json($db_out) };

                my $count = undef;
                if ($parsed_res && ref $parsed_res eq 'ARRAY' && @$parsed_res) {
                    $count = $parsed_res->[0]{patient_count};

                    # Pseudonyme extrahieren (aus patient_ids Array oder Einzelzeilen)
                    for my $row (@$parsed_res) {
                        if ($row->{patient_ids}) {
                            if (ref $row->{patient_ids} eq 'ARRAY') {
                                push @found_patient_ids, grep { defined && length($_) && $_ ne 'null' } @{$row->{patient_ids}};
                            } elsif ($row->{patient_ids} =~ /^\{(.*)\}$/) {
                                push @found_patient_ids, grep { length($_) } split(/,/, $1);
                            }
                        }
                        if ($row->{pseudonym}) {
                            push @found_patient_ids, $row->{pseudonym};
                        }
                    }
                } elsif ($db_out =~ /"patient_count"\s*:\s*(\d+)/) {
                    $count = $1;
                }

                # Duplikate filtern
                my %seen_p;
                @found_patient_ids = grep { !$seen_p{$_}++ } @found_patient_ids;
                $count //= scalar(@found_patient_ids);

                if (defined $count) {
                    $clean_output .= "\n\n **Datenbank-Ergebnis:**\nEs wurden **$count Patient(en)** in der Kohorte gefunden.";
                }
            }
        }

        if (!Encode::is_utf8($clean_output)) {
            $clean_output = eval { Encode::decode_utf8($clean_output) } // $clean_output;
        }

        # Response mit SQL, Fehlern und Patienten-Liste rendern
        $c->render(json => {
            success     => 1,
            output      => $clean_output,
            sql         => $last_sql,
            db_error    => $db_error_msg,
            patient_ids => \@found_patient_ids
        });
    })->catch(sub {
        my $err = shift;
        $c->app->log->error("[COHORT CHAT ERROR]: $err");
        $c->render(json => { success => 0, error => "$err" }, status => 500);
    });
};

# =========================================================
# ENDPUNKT FÜR DEN BUTTON "SQL AUSFÜHREN"
# =========================================================
post '/BBB/chat/execute_sql' => sub {
    my $c = shift;
    my $payload = $c->req->json // {};
    my $sql     = $payload->{sql} // '';

    $sql = sanitize_phenopacket_sql($sql);

    unless (length($sql)) {
        return $c->render(json => { success => 0, error => "Kein SQL übergeben." }, status => 400);
    }

    my ($db_out, $db_err) = $c->execute_safe_cohort_sql($sql);

    if ($db_err) {
        return $c->render(json => { success => 0, error => $db_err });
    }

    my $parsed_res = eval { Mojo::JSON::decode_json($db_out) } // [];
    my @found_patient_ids;
    my $count = undef;

    if (ref $parsed_res eq 'ARRAY') {
        if (@$parsed_res && exists $parsed_res->[0]{patient_count}) {
            $count = $parsed_res->[0]{patient_count};
        }
        for my $row (@$parsed_res) {
            if ($row->{patient_ids}) {
                if (ref $row->{patient_ids} eq 'ARRAY') {
                    push @found_patient_ids, grep { defined && length($_) && $_ ne 'null' } @{$row->{patient_ids}};
                } elsif ($row->{patient_ids} =~ /^\{(.*)\}$/) {
                    push @found_patient_ids, grep { length($_) } split(/,/, $1);
                }
            }
            if ($row->{pseudonym}) {
                push @found_patient_ids, $row->{pseudonym};
            }
        }
    }

    my %seen;
    @found_patient_ids = grep { !$seen{$_}++ } @found_patient_ids;
    $count //= scalar(@found_patient_ids);

    return $c->render(json => {
        success       => 1,
        patient_count => $count + 0,
        patient_ids   => \@found_patient_ids
    });
};

# =========================================================
# RECURSIVE SEARCH ENDPOINTS (REGISTERED BEFORE GENERIC REST)
# =========================================================
get '/BBB/hpo/search/:query' => sub {
    my $self = shift;
    my $query = $self->param('query');
    my $name_only = to_bool($self->param('nameOnly'));

    my $base_where;
    my @bind_params;

    if ($query =~ /^hp:0*(\d+)$/i) {
        my $numeric_id = $1;
        $base_where = "WHERE t.id = ?";
        @bind_params = ($numeric_id);
    } else {
        my $search_term = "%$query%";
        $base_where = "WHERE t.label ILIKE ?";
        @bind_params = ($search_term);

        if (!$name_only) {
            $base_where = "WHERE t.label ILIKE ? OR t.definition ILIKE ? OR EXISTS (SELECT 1 FROM public.synonyms s WHERE s.idterm = t.id AND s.label ILIKE ?)";
            push @bind_params, $search_term, $search_term;
        }
    }

    my $sql = qq{
        WITH RECURSIVE search_tree AS (
            SELECT t.id as match_id, t.id as current_id, ARRAY[t.id]::varchar[] as path
            FROM public.terms t
            $base_where
        UNION ALL
            SELECT st.match_id, i.idparent as current_id, i.idparent::text || st.path
            FROM search_tree st
            JOIN public.isas i ON st.current_id = i.idchild
        )
        SELECT DISTINCT ON (match_id) match_id, path
        FROM search_tree
        ORDER BY match_id, array_length(path, 1) DESC
    };

    my $results = $self->pg->db->query($sql, @bind_params)->hashes->to_array;
    foreach my $row (@$results) {
        if (defined $row->{path} && !ref $row->{path}) {
            if ($row->{path} =~ /^\{(.*)\}$/) {
                my @path_array = split(',', $1);
                $row->{path} = \@path_array;
            }
        }
    }
    $self->render(json => $results);
};

get '/BBB/icd10/search/:query' => [query => qr/.+/] => sub {
    my $self = shift;
    my $query = $self->param('query');

    my $base_where;
    my @bind_params;

    my $clean_query = uc($query);
    $clean_query =~ s/\.//g;

    if ($clean_query =~ /^[A-Z]\d{2,4}$/) {
        $base_where = "WHERE t.id = ? OR t.id LIKE ?";
        @bind_params = ($clean_query, "$clean_query%");
    }
    else {
        my $search_term = "%$query%";
        $base_where = "WHERE t.label ILIKE ? OR t.id ILIKE ?";
        @bind_params = ($search_term, $search_term);
    }

    my $sql = qq{
                    WITH RECURSIVE search_tree AS (
                        SELECT t.id as match_id, t.id as current_id, ARRAY[t.id]::varchar[] as path
                        FROM public.icd10_terms t
                        $base_where
                    UNION ALL
                        SELECT st.match_id, p.parent_id as current_id, p.parent_id || st.path
                        FROM search_tree st
                        JOIN public.icd10_terms p ON st.current_id = p.id
                        WHERE p.parent_id IS NOT NULL
                    )
                    SELECT DISTINCT ON (match_id) match_id, path
                    FROM search_tree
                    ORDER BY match_id, array_length(path, 1) DESC
                };

    my $results = $self->pg->db->query($sql, @bind_params)->hashes->to_array;

    foreach my $row (@$results) {
        if (defined $row->{path} && !ref $row->{path}) {
            if ($row->{path} =~ /^\{(.*)\}$/) {
                my @path_array = split(',', $1);
                $row->{path} = \@path_array;
            }
        }
    }

    $self->render(json => $results);
};

get '/BBB/ops/search/:query' => [query => qr/.+/] => sub {
    my $self = shift;
    my $query = $self->param('query');

    my $base_where;
    my @bind_params;

    # 1. 'OPS:'-Präfix und Whitespace entfernen
    my $clean_query = $query;
    $clean_query =~ s/^ops:\s*//i;
    $clean_query =~ s/^\s+|\s+$//g;

    # 2. VOR der Suche zwingend auf Kleinbuchstaben normieren (BfArM-Standard: 5-156.9b)
    $clean_query = lc($clean_query);

    # 3. Code-Muster oder Freitext-Suche
    if ($clean_query =~ /^[a-z0-9\-\.]{3,10}$/) {
        $base_where = "WHERE LOWER(t.id) = ? OR LOWER(t.id) LIKE ?";
        @bind_params = ($clean_query, "$clean_query%");
    } else {
        my $search_term = "%$query%";
        $base_where = "WHERE t.label ILIKE ? OR LOWER(t.id) ILIKE ?";
        @bind_params = ($search_term, "%$clean_query%");
    }

    my $sql = qq{
        WITH RECURSIVE search_tree AS (
            SELECT t.id as match_id, t.id as current_id, ARRAY[t.id]::varchar[] as path
            FROM public.ops_terms t
            $base_where
        UNION ALL
            SELECT st.match_id, p.parent_id as current_id, p.parent_id || st.path
            FROM search_tree st
            JOIN public.ops_terms p ON LOWER(st.current_id) = LOWER(p.id)
            WHERE p.parent_id IS NOT NULL
        )
        SELECT DISTINCT ON (match_id) match_id, path
        FROM search_tree
        ORDER BY match_id, array_length(path, 1) DESC
    };

    my $results = $self->pg->db->query($sql, @bind_params)->hashes->to_array;
    foreach my $row (@$results) {
        if (defined $row->{path} && !ref $row->{path}) {
            if ($row->{path} =~ /^\{(.*)\}$/) {
                my @path_array = split(',', $1);
                $row->{path} = \@path_array;
            }
        }
    }
    $self->render(json => $results);
};


get '/BBB/atc/search/:query' => [query => qr/.+/] => sub {
    my $self = shift;
    my $query = $self->param('query');

    my $base_where;
    my @bind_params;
    my $clean_query = $query;

    if ($clean_query =~ /^[A-Z0-9]{3,10}$/) {
        $base_where = "WHERE t.id = ? OR t.id LIKE ?";
        @bind_params = ($clean_query, "$clean_query%");
    } else {
        my $search_term = "%$query%";
        $base_where = "WHERE t.label ILIKE ? OR t.id ILIKE ?";
        @bind_params = ($search_term, $search_term);
    }

    my $sql = qq{
        WITH RECURSIVE search_tree AS (
            SELECT t.id as match_id, t.id as current_id, ARRAY[t.id]::varchar[] as path
            FROM public.atc_terms t
            $base_where
        UNION ALL
            SELECT st.match_id, p.parent_id as current_id, p.parent_id || st.path
            FROM search_tree st
            JOIN public.atc_terms p ON st.current_id = p.id
            WHERE p.parent_id IS NOT NULL
        )
        SELECT DISTINCT ON (match_id) match_id, path
        FROM search_tree
        ORDER BY match_id, array_length(path, 1) DESC
    };

    warn $sql;
    my $results = $self->pg->db->query($sql, @bind_params)->hashes->to_array;
    warn Dumper $results;

    foreach my $row (@$results) {
        if (defined $row->{path} && !ref $row->{path}) {
            if ($row->{path} =~ /^\{(.*)\}$/) {
                my @path_array = split(',', $1);
                $row->{path} = \@path_array;
            }
        }
    }
    $self->render(json => $results);
};

get '/BBB/loinc/search/:query' => [query => qr/.+/] => sub {
    my $self = shift;
    my $query = $self->param('query');

    my $base_where;
    my @bind_params;
    $query =~ s/^LP//;
    my $clean_query = uc($query);

    if ($clean_query =~ /^\d{3,6}-\d$/) {
        $base_where = "WHERE t.id = ? OR t.id LIKE ?";
        @bind_params = ($clean_query, "$clean_query%");
    } else {
        my $search_term = "%$query%";
        $base_where = "WHERE t.label ILIKE ? OR t.id ILIKE ? OR t.component ILIKE ?";
        @bind_params = ($search_term, $search_term, $search_term);
    }

    my $sql = qq{
        WITH RECURSIVE search_tree AS (
            SELECT t.id::varchar as match_id, t.id::varchar as current_id, ARRAY[t.id::varchar] as path
            FROM public.loinc_terms t
            $base_where
        UNION ALL
            SELECT st.match_id, p.parent_id::varchar as current_id, ARRAY[p.parent_id::varchar] || st.path
            FROM search_tree st
            JOIN public.loinc_terms p ON st.current_id = p.id
            WHERE p.parent_id IS NOT NULL
        )
        SELECT DISTINCT ON (match_id) match_id, path
        FROM search_tree
        ORDER BY match_id, array_length(path, 1) DESC
    };

    my $results = $self->pg->db->query($sql, @bind_params)->hashes->to_array;

    foreach my $row (@$results) {
        if (defined $row->{path} && !ref $row->{path}) {
            if ($row->{path} =~ /^\{(.*)\}$/) {
                my @path_array = split(',', $1);
                $row->{path} = \@path_array;
            }
        }
    }
    $self->render(json => $results);
};

# =========================================================
# ONTOLOGY TREE ROOT ENDPOINTS
# =========================================================
get '/BBB/hpo/roots' => sub {
    my $self = shift;
    my $sql = q{
        SELECT t.id, t.label, t.definition,
        (CASE WHEN EXISTS (SELECT 1 FROM public.isas WHERE idparent = t.id) THEN 0 ELSE 1 END) as is_leaf
        FROM public.terms t WHERE t.id in (SELECT idparent FROM public.isas ) ORDER BY 2
    };
    $self->render(json => $self->pg->db->query($sql)->hashes->to_array);
};

get '/BBB/hpo/children/:id' => [id => qr/.+/] => sub {
    my $self = shift;
    my $id = $self->param('id');
    my $sql = q{
        SELECT t.id, t.label, t.definition,
        (CASE WHEN EXISTS (SELECT 1 FROM public.isas WHERE idparent = t.id) THEN 0 ELSE 1 END) as is_leaf
        FROM public.terms t JOIN public.isas i ON t.id = i.idchild WHERE i.idparent = ? ORDER BY t.label
    };
    $self->render(json => $self->pg->db->query($sql, $id)->hashes->to_array);
};
get '/BBB/hpo/synonyms/:id' => [id => qr/.+/] => sub {
    my $self = shift;
    my $id = $self->param('id');
    my $sql = q{ SELECT distinct idterm, label FROM public.synonyms WHERE idterm = ? ORDER BY label };
    my $results = $self->pg->db->query($sql, $id)->hashes->to_array;
    $self->render(json => $results);
};

get '/BBB/hpo/xrefs/:id' => [id => qr/.+/] => sub {
    my $self = shift;
    my $id = $self->param('id');
    my $sql = q{
        SELECT distinct idterm, label
        FROM public.xrefs
        WHERE idterm = ?
        AND label NOT LIKE 'property_value%'
        AND label NOT LIKE 'created_by%'
        AND label NOT LIKE 'terms:%'
        ORDER BY label
    };
    my $results = $self->pg->db->query($sql, $id)->hashes->to_array;
    $self->render(json => $results);
};

get '/BBB/icd10/roots' => sub {
    my $self = shift;
    my $sql = q{
        SELECT t.id, t.label, t.code_formatted,
        (CASE WHEN EXISTS (SELECT 1 FROM public.icd10_terms WHERE parent_id = t.id) THEN 0 ELSE 1 END) as is_leaf
        FROM public.icd10_terms t WHERE t.parent_id IS NULL ORDER BY t.id
    };
    $self->render(json => $self->pg->db->query($sql)->hashes->to_array);
};

get '/BBB/icd10/children/:id' => [id => qr/.+/] => sub {
    my $self = shift;
    my $id = $self->param('id');
    my $sql = q{
        SELECT t.id, t.label, t.code_formatted,
        (CASE WHEN EXISTS (SELECT 1 FROM public.icd10_terms WHERE parent_id = t.id) THEN 0 ELSE 1 END) as is_leaf
        FROM public.icd10_terms t
        WHERE t.parent_id = ?
        ORDER BY t.id
    };
    my $results = $self->pg->db->query($sql, $id)->hashes->to_array;
    $self->render(json => $results);
};

#hpo
get '/BBB/children/idparent/:pk' => [pk=>qr/[0-9]+/] => sub {
    my $self = shift;
    my $pk  = $self->param('pk');

    my $sql=qq{ select distinct terms.id, terms.label, terms.definition from all_childen_of(?) a join terms on terms.id = a.identity };
    my $results = $self->pg->db->query($sql, $pk)->hashes->to_array;
    $self->render(json => $results);
};

get '/BBB/ops/roots' => sub {
    my $self = shift;
    my $sql = q{
        SELECT t.id, t.label, t.code_formatted,
        (CASE WHEN EXISTS (SELECT 1 FROM public.ops_terms WHERE parent_id = t.id) THEN 0 ELSE 1 END) as is_leaf
        FROM public.ops_terms t WHERE t.parent_id IS NULL ORDER BY t.id
    };
    $self->render(json => $self->pg->db->query($sql)->hashes->to_array);
};
get '/BBB/ops/children/:id' => [id => qr/.+/] => sub {
    my $self = shift;
    my $id = $self->param('id');
    my $sql = q{
        SELECT t.id, t.label, t.code_formatted,
        (CASE WHEN EXISTS (SELECT 1 FROM public.ops_terms WHERE parent_id = t.id) THEN 0 ELSE 1 END) as is_leaf
        FROM public.ops_terms t
        WHERE t.parent_id = ?
        ORDER BY t.id
    };
    my $results = $self->pg->db->query($sql, $id)->hashes->to_array;
    $self->render(json => $results);
};

get '/BBB/atc/roots' => sub {
    my $self = shift;
    my $sql = q{
        SELECT t.id, t.label, t.code_formatted,
        (CASE WHEN EXISTS (SELECT 1 FROM public.atc_terms WHERE parent_id = t.id) THEN 0 ELSE 1 END) as is_leaf
        FROM public.atc_terms t WHERE t.parent_id IS NULL ORDER BY t.id
    };
    $self->render(json => $self->pg->db->query($sql)->hashes->to_array);
};
get '/BBB/atc/children/:id' => [id => qr/.+/] => sub {
    my $self = shift;
    my $id = $self->param('id');
    my $sql = q{
        SELECT t.id, t.label, t.code_formatted,
        (CASE WHEN EXISTS (SELECT 1 FROM public.atc_terms WHERE parent_id = t.id) THEN 0 ELSE 1 END) as is_leaf
        FROM public.atc_terms t
        WHERE t.parent_id = ?
        ORDER BY t.id
    };
    my $results = $self->pg->db->query($sql, $id)->hashes->to_array;
    $self->render(json => $results);
};

get '/BBB/loinc/roots' => sub {
    my $self = shift;
    my $sql = q{
        SELECT t.id, t.label, t.code_formatted,
        (CASE WHEN EXISTS (SELECT 1 FROM public.loinc_terms WHERE parent_id = t.id) THEN 0 ELSE 1 END) as is_leaf
        FROM public.loinc_terms t WHERE t.parent_id IS NULL ORDER BY t.label
    };
    $self->render(json => $self->pg->db->query($sql)->hashes->to_array);
};

get '/BBB/loinc/children/:id' => [id => qr/.+/] => sub {
    my $self = shift;
    my $id = $self->param('id');
    my $sql = q{
        SELECT t.id, t.label, t.code_formatted, t.component, t.system, t.example_ucum_units,
        (CASE WHEN EXISTS (SELECT 1 FROM public.loinc_terms WHERE parent_id = t.id) THEN 0 ELSE 1 END) as is_leaf
        FROM public.loinc_terms t
        WHERE t.parent_id = ?
        ORDER BY t.label
    };
    my $results = $self->pg->db->query($sql, $id)->hashes->to_array;
    $self->render(json => $results);
};

# =========================================================
# HILFSFUNKTION: TAGE-DIFFERENZ ZWEIER DATUMS-STRINGS
# =========================================================
sub date_diff_in_days {
    my ($start_str, $end_str) = @_;
    return 0 unless $start_str && $end_str;

    my ($y1, $m1, $d1) = $start_str =~ /^(\d{4})-(\d{2})-(\d{2})/;
    my ($y2, $m2, $d2) = $end_str   =~ /^(\d{4})-(\d{2})-(\d{2})/;
    return 0 unless $y1 && $y2;

    my $dt1 = eval { DateTime->new(year => int($y1), month => int($m1), day => int($d1)) };
    my $dt2 = eval { DateTime->new(year => int($y2), month => int($m2), day => int($d2)) };
    return 0 unless $dt1 && $dt2;

    return $dt2->delta_days($dt1)->in_units('days');
}

# =========================================================
# HILFSFUNKTIONEN: OPHTHALMOLOGISCHE LATERALITÄTS-PROJEKTION
# =========================================================

sub is_laterality_match {
    my ($patient_lat_id, $target_lat_id) = @_;
    return 1 unless $target_lat_id; # Nicht-lateralisierte Kriterien matchen immer
    return 0 unless $patient_lat_id;

    my $p = uc($patient_lat_id);
    my $t = uc($target_lat_id);

    return 1 if $p eq $t;

    # Rechtes Auge Äquivalenzen (HP:0012834, SNOMED:18944008)
    my $is_p_right = ($p eq 'HP:0012834' || $p eq 'SNOMED:18944008' || $p eq '261185002');
    my $is_t_right = ($t eq 'HP:0012834' || $t eq 'SNOMED:18944008' || $t eq '261185002');
    return 1 if $is_p_right && $is_t_right;

    # Linkes Auge Äquivalenzen (HP:0012835, SNOMED:8966001)
    my $is_p_left = ($p eq 'HP:0012835' || $p eq 'SNOMED:8966001' || $p eq '261186004');
    my $is_t_left = ($t eq 'HP:0012835' || $t eq 'SNOMED:8966001' || $t eq '261186004');
    return 1 if $is_p_left && $is_t_left;

    # Bilateraler Befund erfüllt rechtes, linkes oder bilaterales Kriterium
    my $is_p_bilateral = ($p eq 'HP:0012832' || $p eq 'SNOMED:40638003' || $p eq '261184001');
    return 1 if $is_p_bilateral;

    return 0;
}

sub swap_phenopacket_laterality {
    my ($phenopacket) = @_;
    return $phenopacket unless ref $phenopacket eq 'HASH';

    # Deep Clone des Phenopackets
    my $clone = eval { decode_json(encode_json($phenopacket)) } // {};
    return $phenopacket unless %$clone;

    my $swap_lat_obj = sub {
        my ($obj) = @_;
        return unless ref $obj eq 'HASH' && $obj->{id};
        my $id = $obj->{id};

        if ($id eq 'HP:0012834' || $id eq 'SNOMED:18944008' || $id eq '261185002') {
            $obj->{id}    = 'HP:0012835';
            $obj->{label} = 'Left';
        } elsif ($id eq 'HP:0012835' || $id eq 'SNOMED:8966001' || $id eq '261186004') {
            $obj->{id}    = 'HP:0012834';
            $obj->{label} = 'Right';
        }
        # Bilaterale Befunde (HP:0012832) bleiben bilateral
    };

    # 1. Phenotypic Features spiegeln
    foreach my $feat (@{$clone->{phenotypicFeatures} // []}) {
        $swap_lat_obj->($feat->{type}) if $feat->{type};
        foreach my $mod (@{$feat->{modifiers} // []}) {
            $swap_lat_obj->($mod);
        }
    }

    # 2. Measurements spiegeln
    foreach my $meas (@{$clone->{measurements} // []}) {
        foreach my $mod (@{$meas->{modifiers} // []}) {
            $swap_lat_obj->($mod);
        }
    }

    # 3. Diseases / Diagnosen spiegeln
    foreach my $dis (@{$clone->{diseases} // []}) {
        $swap_lat_obj->($dis->{primarySite}) if $dis->{primarySite};
    }

    # 4. Procedures / Prozeduren spiegeln
    foreach my $proc (@{$clone->{procedures} // []}) {
        $swap_lat_obj->($proc->{bodySite}) if $proc->{bodySite};
    }

    # 5. Medical Actions spiegeln
    foreach my $act (@{$clone->{medicalActions} // []}) {
        if ($act->{procedure} && $act->{procedure}{bodySite}) {
            $swap_lat_obj->($act->{procedure}{bodySite});
        }
        if (ref $act->{treatment} eq 'HASH' && $act->{treatment}{bodySite}) {
            $swap_lat_obj->($act->{treatment}{bodySite});
        }
    }

    return $clone;
}

# =========================================================
#  EVALUATION KERNEL (ZWEI-HYPOTHESEN-MATCHING)
# =========================================================
helper evaluate_candidate_for_trial => sub {
    my ($self, $fhir_group, $phenopacket, $ref_date) = @_;
    return (0, [], 'none') unless ref $fhir_group eq 'HASH' && ref $phenopacket eq 'HASH';

    my %contained_map = map { $_->{id} => $_ } @{$fhir_group->{contained} // []};
    $ref_date //= $phenopacket->{reference_date} // POSIX::strftime("%Y-%m-%d", localtime);

    # Hypothese A: OD (Rechts) ist Studienauge, OS (Links) ist Partnerauge
    my @trace_direct;
    my $is_eligible_direct = evaluate_and_trace_node($self, $fhir_group, \%contained_map, $phenopacket, 0, 0, \@trace_direct, undef, $ref_date);

    # Hypothese B: OS (Links) ist Studienauge, OD (Rechts) ist Partnerauge (gespiegeltes Phenopacket)
    my $phenopacket_swapped = swap_phenopacket_laterality($phenopacket);
    my @trace_swapped;
    my $is_eligible_swapped = evaluate_and_trace_node($self, $fhir_group, \%contained_map, $phenopacket_swapped, 0, 0, \@trace_swapped, undef, $ref_date);

    # Auswertung: Welches Auge erfüllt die Kriterien?
    if ($is_eligible_direct && $is_eligible_swapped) {
        return (1, \@trace_direct, 'both'); # Beide Augen erfüllen unabhängig voneinander die Studienaugen-Kriterien
    } elsif ($is_eligible_direct) {
        return (1, \@trace_direct, 'OD');   # Rechtes Auge ist Studienauge
    } elsif ($is_eligible_swapped) {
        return (1, \@trace_swapped, 'OS');  # Linkes Auge ist Studienauge
    } else {
        return (0, \@trace_direct, 'none');
    }
};

# =========================================================
# TIME-TO-ELIGIBILITY KERNEL (OHNE 'date')
# =========================================================
helper calculate_time_to_eligibility => sub {
    my ($self, $trial_id, $piz_list_ref) = @_;
    my $db = $self->pg->db;

    my $trial = $db->select('trials', ['id', 'name', 'fhir_group_json'], { id => $trial_id })->expand->hash;
    return undef unless $trial && $trial->{fhir_group_json};

    my $fhir_group = $trial->{fhir_group_json};
    if ($fhir_group && !ref $fhir_group) {
        $fhir_group = eval { decode_json($fhir_group) };
    }
    return undef unless ref $fhir_group eq 'HASH';

    my @piz_list = (ref $piz_list_ref eq 'ARRAY' && @$piz_list_ref) ? @$piz_list_ref : ();

    unless (@piz_list) {
        my $piz_rows = $db->query("SELECT DISTINCT pseudonym FROM candidates WHERE pseudonym IS NOT NULL AND phenopacket_json IS NOT NULL ORDER BY pseudonym")->hashes;
        @piz_list = map { $_->{pseudonym} } @$piz_rows;
    }

    my @km_results;
    my $events_count   = 0;
    my $censored_count = 0;

    foreach my $piz (@piz_list) {
        next unless defined $piz && length($piz);

        # 'date' entfernt:
        my $sql = q{
            SELECT id, doc_id, pseudonym, phenopacket_json, reference_date
            FROM candidates
            WHERE pseudonym = ? AND phenopacket_json IS NOT NULL
            ORDER BY reference_date ASC, id ASC
        };
        my $briefe = $db->query($sql, $piz)->expand->hashes->to_array;

        unless (@$briefe) {
            push @km_results, {
                piz                    => $piz,
                status                 => 'no_data',
                event                  => 0,
                time_days              => 0,
                study_eye              => 'none',
                baseline_date          => undef,
                event_date             => undef,
                date_last_seen         => undef,
                first_eligible_doc_id  => undef,
                total_briefe_evaluated => 0
            };
            next;
        }

        my $baseline_date  = $briefe->[0]->{reference_date}  // POSIX::strftime("%Y-%m-%d", localtime);
        my $date_last_seen = $briefe->[-1]->{reference_date} // $baseline_date;

        my $event_occurred         = 0;
        my $event_date             = undef;
        my $study_eye_identified   = 'none';
        my $first_eligible_doc_id  = undef;
        my $first_eligible_cand_id = undef;
        my $evaluated_count        = 0;

        foreach my $brief (@$briefe) {
            $evaluated_count++;
            my $phenopacket = $brief->{phenopacket_json};
            if ($phenopacket && !ref $phenopacket) {
                $phenopacket = eval { decode_json($phenopacket) };
            }
            next unless defined $phenopacket && ref $phenopacket eq 'HASH';

            my $current_ref_date = $brief->{reference_date} // $baseline_date;

            my ($is_eligible, $trace, $study_eye) = $self->evaluate_candidate_for_trial($fhir_group, $phenopacket, $current_ref_date);

            if ($is_eligible) {
                $event_occurred         = 1;
                $event_date             = $current_ref_date;
                $study_eye_identified   = $study_eye;
                $first_eligible_doc_id  = $brief->{doc_id};
                $first_eligible_cand_id = $brief->{id};
                last;
            }
        }

        my $time_days = 0;
        if ($event_occurred) {
            $time_days = date_diff_in_days($baseline_date, $event_date);
            $events_count++;
        } else {
            $time_days = date_diff_in_days($baseline_date, $date_last_seen);
            $censored_count++;
        }

        push @km_results, {
            piz                         => $piz,
            time_days                   => $time_days,
            event                       => $event_occurred,
            study_eye                   => $study_eye_identified,
            baseline_date               => $baseline_date,
            event_date                  => $event_occurred ? $event_date : undef,
            date_last_seen              => $date_last_seen,
            first_eligible_doc_id       => $first_eligible_doc_id,
            first_eligible_candidate_id => $first_eligible_cand_id,
            total_briefe_evaluated      => $evaluated_count,
            status                      => $event_occurred ? 'eligible' : 'censored'
        };
    }

    return {
        trial_id          => $trial->{id},
        trial_name        => $trial->{name},
        total_patients    => scalar(@piz_list),
        events_count      => $events_count,
        censored_count    => $censored_count,
        kaplan_meier_data => \@km_results
    };
};

# =========================================================
# CSV ENDPUNKT (MIT STUDY_EYE FÜR R BASE)
# =========================================================
get '/BBB/trials/:id/time_to_eligibility.csv' => [id => qr/\d+/] => sub {
    my $c = shift;
    $c->inactivity_timeout(1800);
    my $trial_id = $c->param('id');
    my $piz_param = $c->param('piz');
    my @piz_list;
    @piz_list = split(/,/, $piz_param) if $piz_param;

    my $res = $c->calculate_time_to_eligibility($trial_id, \@piz_list);
    unless ($res) {
        return $c->render(text => "Error: Trial not found", status => 404);
    }

    my $csv = "piz,event,time_days,study_eye,baseline_date,event_date,date_last_seen,first_eligible_doc_id,total_briefe_evaluated\n";
    foreach my $row (@{$res->{kaplan_meier_data} // []}) {
        next if $row->{status} && $row->{status} eq 'no_data';
        $csv .= sprintf("%s,%d,%d,%s,%s,%s,%s,%s,%d\n",
            $row->{piz} // '',
            $row->{event} // 0,
            $row->{time_days} // 0,
            $row->{study_eye} // 'none',
            $row->{baseline_date} // '',
            $row->{event_date} // '',
            $row->{date_last_seen} // '',
            $row->{first_eligible_doc_id} // '',
            $row->{total_briefe_evaluated} // 0
        );
    }

    $c->res->headers->header('Content-Type' => 'text/csv; charset=UTF-8');
    $c->res->headers->header('Content-Disposition' => sprintf('attachment; filename="trial_%s_time_to_eligibility.csv"', $trial_id));
    $c->render(text => $csv);
};

# =========================================================
# REST ENDPUNKT 1: JSON FÜR FRONTEND
# =========================================================
post '/BBB/trials/:id/time_to_eligibility' => [id => qr/\d+/] => sub {
    my $c = shift;
    $c->inactivity_timeout(1800);
    my $trial_id = $c->param('id');
    my $payload  = $c->req->json;

    my @piz_list;
    if (ref $payload eq 'ARRAY') {
        @piz_list = @$payload;
    } elsif (ref $payload eq 'HASH') {
        @piz_list = @{ $payload->{pizs} // $payload->{pseudonyms} // [] };
    }

    my $res = $c->calculate_time_to_eligibility($trial_id, \@piz_list);
    return $c->render(json => { error => "Trial not found" }, status => 404) unless $res;
    $c->render(json => $res);
};

post '/BBB/candidates/batch_tag' => sub {
    my $c = shift;
    my $payload = $c->req->json // {};
    my $tag = $payload->{tag};
    my $pseudonyms = $payload->{pseudonyms} // [];
    my $append = $payload->{append} // 1;

    unless ($tag && @$pseudonyms) {
        return $c->render(json => { error => "Parameter 'tag' und 'pseudonyms' erforderlich." }, status => 400);
    }

    $tag =~ s/^\s+|\s+$//g;
    my $db = $c->pg->db;
    my $updated = 0;

    eval {
        my $tx = $db->begin;
        if (!$append) {
            # Ersetzen
            $updated = $db->query(
                "UPDATE candidates SET tags = ? WHERE pseudonym = ANY(?)",
                $tag, $pseudonyms
            )->rows;
        } else {
            # Anhängen (vermeidet doppelte Tags)
            $updated = $db->query(q{
                UPDATE candidates
                SET tags = CASE
                    WHEN tags IS NULL OR TRIM(tags) = '' THEN ?
                    WHEN tags ILIKE ? OR tags ILIKE ? OR tags ILIKE ? OR tags = ? THEN tags
                    ELSE tags || ', ' || ?
                END
                WHERE pseudonym = ANY(?)
            }, $tag, "%$tag,%", "%, $tag%", "%$tag", $tag, $tag, $pseudonyms)->rows;
        }
        $tx->commit;
    };

    if ($@) {
        $c->app->log->error("[BATCH TAG ERROR] $@");
        return $c->render(json => { error => "DB Fehler: $@" }, status => 500);
    }

    $c->app->log->info("[BATCH TAG] Tag '$tag' für $updated Datensätze gesetzt.");
    $c->render(json => { success => 1, updated => $updated });
};

# =========================================================
# DEDIZIERTER TERMINOLOGY-MAPPING ENDPUNKT FÜR LLM-EXTRACTOR
# =========================================================
post '/BBB/resolve_term' => sub {
    my $c = shift;
    my $payload = $c->req->json // {};
    my $raw_domain = $payload->{domain} // 'hpo';
    my $text       = $payload->{text} // '';
    my $lang       = $payload->{language} // 'de';

    # Normalisierung: TEXT2ICD -> icd10, TEXT2HPO -> hpo, icd -> icd10
    my $domain = lc($raw_domain);
    $domain =~ s/^\s+|\s+$//g;
    $domain =~ s/^text2//;
    $domain =~ s/_terms$//;
    $domain = 'icd10' if $domain eq 'icd';

    unless ($text) {
        return $c->render(json => { hit => 0, error => "Parameter 'text' fehlt." }, status => 400);
    }

    # 1. Stufe: Sofortprüfung auf deterministische Intercepts
    if (my $hit = $c->check_database_intercept($domain, $text)) {
        return $c->render(json => {
            hit    => 1,
            source => 'intercept',
            id     => $hit->{id},
            label  => $hit->{label}
        });
    }

    # 2. Stufe: Vektorsuche über OntoTrial
    my $promise;
    if ($domain eq 'icd10') {
        $promise = $c->map_to_icd10_async($text, undef, $lang);
    } elsif ($domain eq 'ops') {
        $promise = $c->map_to_ops_async($text, $lang);
    } elsif ($domain eq 'atc') {
        $promise = $c->map_to_atc_async($text, $lang);
    } elsif ($domain eq 'loinc') {
        $promise = $c->map_to_loinc_async($text, $lang);
    } else {
        $promise = $c->map_to_hpo_async($text, 0, $lang);
    }

    $c->render_later;
    $promise->then(sub {
        my $res = shift;
        if ($res && $res->{id}) {
            $c->render(json => {
                hit    => 1,
                source => 'dense_retrieval',
                id     => $res->{id},
                label  => $res->{label}
            });
        } else {
            $c->render(json => { hit => 0, id => undef, label => undef });
        }
    })->catch(sub {
        my $err = shift;
        $c->app->log->error("[RESOLVE_TERM ERROR] $err");
        $c->render(json => { hit => 0, error => "$err" }, status => 500);
    });
};

# =========================================================
# DEDIZIERTE CANDIDATES ENDPUNKTE (LIMITIERT & SERVER-SUCHE)
# =========================================================

# 1. Schnelle Server-Suche nach Pseudonym, Tags oder ID
get '/BBB/candidates/search/:query' => [query => qr/.+/] => sub {
    my $self = shift;
    my $q = $self->param('query');
    $q =~ s/^\s+|\s+$//g;

    my $sql = q{
        SELECT id, pseudonym, tags, reference_date, narrative_report, phenopacket_json
        FROM candidates
        WHERE pseudonym ILIKE ?
           OR tags ILIKE ?
           OR id::text = ?
        ORDER BY reference_date DESC NULLS LAST, id DESC
        LIMIT 250
    };
    my $term = "%$q%";
    my $rows = $self->pg->db->query($sql, $term, $term, $q)->hashes->to_array;
    $self->render(json => $rows);
};

# 2. Initialer Fetch (fireside does this, really!): Nur die neuesten 1.000 Patienten laden (statt 10.000+)
get '/BBB/candidates/1/1' => sub {
    my $self  = shift;
    my $limit = $self->param('limit') // 1000;
    my $sql   = q{
        SELECT id, pseudonym, tags, reference_date, narrative_report, phenopacket_json
        FROM candidates
        ORDER BY id DESC
        LIMIT ?
    };
    my $rows = $self->pg->db->query($sql, $limit)->hashes->to_array;
    $self->render(json => $rows);
};

# 3. Fallback für direkten Tabellenaufruf
get '/BBB/candidates' => sub {
    my $self  = shift;
    my $limit = $self->param('limit') // 1000;
    my $sql   = q{
        SELECT id, pseudonym, tags, reference_date, narrative_report, phenopacket_json
        FROM candidates
        ORDER BY id DESC
        LIMIT ?
    };
    my $rows = $self->pg->db->query($sql, $limit)->hashes->to_array;
    $self->render(json => $rows);
};

# =========================================================
# MATCHES FETCH (MIT GEJOINTEN TEXTEN FÜR FIRESIDE 1/1)
# =========================================================
sub _fetch_all_matches_sql {
    return q{
        SELECT m.*, t.name as trial_name, c.pseudonym as candidate_pseudonym,
        (CASE WHEN m.eligible = 1 THEN '🟢 Eligible'
              WHEN m.potentially_eligible = 1 THEN '🟠 Potentially Eligible'
              ELSE '🔴 Ineligible' END) as status_text
        FROM matches m
        LEFT JOIN trials t ON m.trial_id = t.id
        LEFT JOIN candidates c ON m.candidate_id = c.id
        ORDER BY m.timestamp DESC
    };
}

# Fängt den Fireside-Startup-Aufruf /BBB/matches/1/1 ab
get '/BBB/matches/1/1' => sub {
    my $self = shift;
    $self->render(json => $self->pg->db->query(_fetch_all_matches_sql())->hashes->to_array);
};

# Standard-Endpunkt
get '/BBB/matches' => sub {
    my $self = shift;
    $self->render(json => $self->pg->db->query(_fetch_all_matches_sql())->hashes->to_array);
};

our %PPD_DEFAULT_WEIGHTS = (
    demographics => 0.15,
    diseases     => 0.25,
    phenotypes   => 0.20,
    procedures   => 0.15,
    medications  => 0.10,
    measurements => 0.15,
);

# Ähnlichkeit an der tiefsten gemeinsamen Hierarchieebene
our %PPD_LEVEL_SIM = (
    icd10 => [0.10, 0.60, 0.85, 1.00],           # Buchstabe, Kategorie, 4-Steller, 5-Steller
    ops   => [0.05, 0.30, 0.60, 0.85, 1.00],     # Kapitel, Bereich, Kode, 1. und 2. Unterstelle
    atc   => [0.05, 0.30, 0.60, 0.85, 1.00],     # anatomisch, therapeutisch, pharmakologisch, chemisch, Wirkstoff
);

our $PPD_AGE_SCALE = 15;   # Altersdifferenz in Jahren, ab der die Distanz 1 ist

# Augenspezifische LOINC-Paare: Gruppe => [rechts, links]
our %PPD_LOINC_PAIRS = (
    iop    => ['79892-6',  '79893-4'],
    cct    => ['79888-4',  '79887-6'],
    va_bc  => ['65893-0',  '65897-1'],
    va_uc  => ['98499-7',  '98498-9'],
    # sphere/cyl/axis: Gruppe wird über das Label erkannt (_ppd_refraction_group),
    # weil die Codes jetzt aus ontology_intercepts kommen.
    axis   => ['79844-7',  '79845-4'],
    se     => ['95327-3',  '95328-1'],
    hertel => ['28998-3',  '28999-1'],
    rnfl   => ['86300-1',  '86299-5'],
    cdr    => ['71485-7',  '71484-0'],
    lid    => ['79855-3',  '79856-1'],
    ecd    => ['100076-9', '100077-7'],
    bmo    => ['86301-9b', '86290-4b'],
    gcl    => ['86301-9a', '86290-4a'],
    vf_md  => ['79803-3',  '79802-5'],
    trg    => ['95327-a',  '95328-a'],            # PATCH 2026-10-22: Zielrefraktion (lokal)
    cde    => ['64817-a',  '64818-a'],            # PATCH 2026-10-22: Phako-Zeitleistungswert (lokal)
    iol    => ['64819-a',  '64820-a'],            # PATCH 2026-10-22: IOL-Stärke (lokal)
);
our %PPD_LOINC_LOOKUP;
for my $g (keys %PPD_LOINC_PAIRS) {
    $PPD_LOINC_LOOKUP{ lc $PPD_LOINC_PAIRS{$g}[0] } = [$g, 'R'];
    $PPD_LOINC_LOOKUP{ lc $PPD_LOINC_PAIRS{$g}[1] } = [$g, 'L'];
}

# Differenz, bei der die Messdistanz 1 erreicht (Visus in logMAR)
our %PPD_MEAS_SCALE = (
    iop => 10, cct => 50, va_bc => 0.5, va_uc => 0.5,
    sphere => 3, cyl => 2, se => 3, hertel => 4, rnfl => 20, cdr => 0.3,
    lid => 3, ecd => 500, bmo => 0.5, gcl => 0.3, vf_md => 5,
    trg => 1, cde => 20, iol => 3,                        # PATCH 2026-10-22
    '4548-4' => 1.5,                              # HbA1c in %
);
our %PPD_SKIP_GROUPS = (axis => 1);               # Achse allein nicht sinnvoll vergleichbar
our %PPD_HPO_TRIVIAL = map { $_ => 1 } (1, 118, 478);   # All, Phenotypic abnormality, Abnormality of the eye

# ---------------------------------------------------------
# Lateralität
# ---------------------------------------------------------
sub _ppd_side {
    my ($obj) = @_;
    my $id = uc((ref $obj eq 'HASH' ? $obj->{id} : $obj) // '');
    return 'R' if $id =~ /^(?:HP:0012834|SNOMED:18944008|261185002)$/;
    return 'L' if $id =~ /^(?:HP:0012835|SNOMED:8966001|261186004)$/;
    return 'B' if $id =~ /^(?:HP:0012832|SNOMED:40638003|261184001)$/;
    return '';
}

sub _ppd_side_of_mods {
    for my $m (@{ $_[0] // [] }) {
        my $s = _ppd_side($m);
        return $s if $s;
    }
    return '';
}

sub _ppd_flip {
    my $s = shift // '';
    return $s eq 'R' ? 'L' : $s eq 'L' ? 'R' : $s;
}

# Seiten sind in den Codeblöcken nur noch 'U' (einseitig, RA oder LA), 'B' (beidseitig)
# oder '' (unbekannt); RA und LA gelten als gleichwertig.
sub _ppd_side_factor {
    my ($x, $y) = @_;
    return 1   if $x eq $y;
    return 0.9 if $x eq '' || $y eq '';
    return 0.8;                                   # einseitig vs. beidseitig
}

# Mehrere Nennungen eines Codes zu einer Seitenangabe zusammenfassen:
# R und L (oder B) -> 'B', nur R oder nur L -> 'U', sonst ''
sub _ppd_side_class {
    my ($sides) = @_;
    return 'B' if $sides->{B} || ($sides->{R} && $sides->{L});
    return 'U' if $sides->{R} || $sides->{L};
    return '';
}

# ---------------------------------------------------------
# Codehierarchien (ICD-10, OPS, ATC)
# ---------------------------------------------------------
sub _ppd_code_chain {
    my ($domain, $code) = @_;
    my $c = $code // '';
    $c =~ s/^(?:ICD10|OPS|ATC)://i;
    $c =~ s/\s+//g;
    return () unless length $c;

    if ($domain eq 'icd10') {
        $c = uc $c;
        return ($c) unless $c =~ /^([A-Z])(\d{2})(?:\.?(\d)(\d)?)?/;
        my @ch = ($1, "$1$2");
        push @ch, "$1$2.$3"   if defined $3;
        push @ch, "$1$2.$3$4" if defined $4;
        return @ch;
    }
    if ($domain eq 'ops') {
        $c = lc $c;
        return ($c) unless $c =~ /^(\d)-(\w\w)(\w)?(?:\.(\w)(\w)?)?/;
        my @ch = ($1, "$1-$2");
        push @ch, "$1-$2$3"      if defined $3;
        push @ch, "$1-$2$3.$4"   if defined $3 && defined $4;
        push @ch, "$1-$2$3.$4$5" if defined $3 && defined $4 && defined $5;
        return @ch;
    }
    if ($domain eq 'atc') {
        $c = uc $c;
        return map { substr($c, 0, $_) } grep { length($c) >= $_ } (1, 3, 4, 5, 7);
    }
    return ($c);
}

sub _ppd_chain_sim {
    my ($domain, $x, $y) = @_;
    return 1 if lc($x // '') eq lc($y // '');
    my @a = _ppd_code_chain($domain, $x);
    my @b = _ppd_code_chain($domain, $y);
    my $n = @a < @b ? scalar(@a) : scalar(@b);
    my $k = -1;
    for my $i (0 .. $n - 1) {
        last unless $a[$i] eq $b[$i];
        $k = $i;
    }
    return 0 if $k < 0;
    my $s = $PPD_LEVEL_SIM{$domain}[$k] // 0;
    return $s < 1 ? $s : 0.95;    # verschiedene Codes nie ganz 1
}

sub _ppd_ts {
    my $t = shift // '';
    return $t =~ /^(\d{4}(?:-\d{2}(?:-\d{2})?)?)/ ? $1 : '0000';   # "PAST-UK-UK" ganz nach hinten
}

# Refraktionsgröße am LOINC-Label erkennen (Codes sind konfigurierbar)
sub _ppd_refraction_group {
    my $l = lc(shift // '');
    return undef unless $l =~ /(?:refraction|refractor|phoropter|lensmeter|corrective lens|cylinder axis|spherical power|cylinder power)/;
    return 'se'     if $l =~ /spherical equivalent/;
    return 'axis'   if $l =~ /\baxis\b/;
    return 'cyl'    if $l =~ /\bcylinder\b/;
    return 'sphere' if $l =~ /\bsphere\b|spherical power/;
    return undef;
}

# ---------------------------------------------------------
# Merkmalsextraktion aus einem Phenopacket
# ---------------------------------------------------------
sub extract_ppd_features {
    my ($pp) = @_;
    my %f = (_ppd => 1, age => undef, sex => undef,
             diseases => [], phenotypes => [], procedures => [], medications => [], measurements => {});
    return \%f unless ref $pp eq 'HASH';

    my $subj = ref $pp->{subject} eq 'HASH' ? $pp->{subject} : {};
    my $iso  = eval { $subj->{timeAtLastEncounter}{age}{iso8601duration} } // '';
    $f{age}  = $1 + 0 if $iso =~ /^P(\d+)Y/;
    my $sex  = uc($subj->{sex} // '');
    $f{sex}  = $sex if $sex eq 'MALE' || $sex eq 'FEMALE';

    # Seiten je Code sammeln und erst danach zu einseitig/beidseitig verdichten
    my (%sides, @order);
    my $add = sub {
        my ($block, $id, $side) = @_;
        return unless defined $id && length $id;
        my $k = "$block|$id";
        push @order, [ $block, $id ] unless $sides{$k};
        $sides{$k}{ $side // '' } = 1;
    };

    for my $d (@{ $pp->{diseases} // [] }) {
        next unless ref $d eq 'HASH' && !to_bool($d->{excluded});
        $add->('diseases', $d->{term}{id}, _ppd_side($d->{primarySite}));
    }
    for my $p (@{ $pp->{phenotypicFeatures} // [] }) {
        next unless ref $p eq 'HASH' && !to_bool($p->{excluded});
        $add->('phenotypes', $p->{type}{id}, _ppd_side_of_mods($p->{modifiers}));
    }
    for my $p (@{ $pp->{procedures} // [] }) {
        next unless ref $p eq 'HASH' && !to_bool($p->{excluded});
        $add->('procedures', $p->{code}{id}, _ppd_side($p->{bodySite}));
    }
    for my $act (@{ $pp->{medicalActions} // [] }) {
        next unless ref $act eq 'HASH';
        if (ref $act->{procedure} eq 'HASH') {
            $add->('procedures', $act->{procedure}{code}{id}, _ppd_side($act->{procedure}{bodySite}));
        }
        if (ref $act->{treatment} eq 'HASH' && !to_bool($act->{treatment}{excluded})) {
            $add->('medications', $act->{treatment}{agent}{id}, _ppd_side($act->{treatment}{bodySite}));
        }
    }
    for my $o (@order) {
        my ($block, $id) = @$o;
        push @{ $f{$block} }, { id => $id, side => _ppd_side_class($sides{"$block|$id"}) };
    }

    # Messungen: jüngster Wert je Messgröße und Auge
    for my $m (@{ $pp->{measurements} // [] }) {
        next unless ref $m eq 'HASH' && !to_bool($m->{excluded});
        my $val = eval { $m->{value}{quantity}{value} };
        next unless defined $val && $val =~ /^-?\d+(?:\.\d+)?$/;
        (my $aid = lc($m->{assay}{id} // '')) =~ s/^loinc://;
        next unless length $aid;
        my ($grp, $side) = $PPD_LOINC_LOOKUP{$aid}
            ? @{ $PPD_LOINC_LOOKUP{$aid} }
            : (_ppd_refraction_group($m->{assay}{label}) // $aid, _ppd_side_of_mods($m->{modifiers}));
        next if $PPD_SKIP_GROUPS{$grp};
        $val += 0;
        $val = -log(($val > 0.001 ? $val : 0.001)) / log(10) if $grp =~ /^va_/;   # dezimal -> logMAR
        my $ts  = _ppd_ts(eval { $m->{timeOfCollection}{timestamp} });
        my $key = "$grp|$side";
        my $cur = $f{measurements}{$key};
        $f{measurements}{$key} = { group => $grp, side => $side, value => $val, ts => $ts }
            if !$cur || $ts ge $cur->{ts};
    }
    return \%f;
}

# Messwerte bleiben je Auge getrennt. Da RA und LA gleichwertig sind, werden die
# beiden Augen als ungeordnetes Paar verglichen: Zuordnung R-R/L-L oder R-L/L-R,
# einheitlich über alle Messgrößen (keine Mischzuordnung je Messgröße).
sub _ppd_swap_eyes_meas {
    my ($M) = @_;
    my %out;
    for my $x (values %$M) {
        my $s = _ppd_flip($x->{side});
        $out{"$x->{group}|$s"} = { %$x, side => $s };
    }
    return \%out;
}

sub _ppd_meas_dist_eye_agnostic {
    my ($MA, $MB) = @_;
    my ($d1, $det1) = _ppd_meas_dist($MA, $MB);
    my ($d2, $det2) = _ppd_meas_dist($MA, _ppd_swap_eyes_meas($MB));
    my ($n1, $n2) = (scalar @$det1, scalar @$det2);
    # mehr gemeinsam gemessene Größen zuerst, dann kleinere Distanz
    my $cross = $n2 > $n1 || ($n2 == $n1 && defined $d2 && defined $d1 && $d2 < $d1);
    return $cross ? ($d2, $det2, 1) : ($d1, $det1, 0);
}

# ---------------------------------------------------------
# Blockdistanzen
# ---------------------------------------------------------
# Symmetrischer Best-Match-Average: 1 - Mittel der besten Treffer in beide Richtungen
sub _ppd_bma {
    my ($A, $B, $sim, $explain) = @_;
    return (undef, []) if !@$A && !@$B;
    return (1, [])     if !@$A || !@$B;
    my @pairs;
    my $dir = sub {
        my ($X, $Y, $rec) = @_;
        my $tot = 0;
        for my $x (@$X) {
            my ($best, $by) = (0, undef);
            for my $y (@$Y) {
                my $s = $sim->($x, $y);
                ($best, $by) = ($s, $y) if $s > $best;
                last if $best >= 1;
            }
            $tot += $best;
            push @pairs, { a => "$x->{id}$x->{side}", b => ($by ? "$by->{id}$by->{side}" : undef),
                           sim => sprintf('%.3f', $best) + 0 } if $rec;
        }
        return $tot / @$X;
    };
    my $d = 1 - 0.5 * ($dir->($A, $B, $explain) + $dir->($B, $A, 0));
    return ($d, \@pairs);
}

# Nur Messgrößen, die beide Patienten haben, gehen ein
sub _ppd_meas_dist {
    my ($MA, $MB) = @_;
    my ($sum, $n, @det) = (0, 0);
    for my $k (sort keys %$MA) {
        my $y = $MB->{$k} or next;
        my $x = $MA->{$k};
        my $diff  = abs($x->{value} - $y->{value});
        my $scale = $PPD_MEAS_SCALE{ $x->{group} };
        my $d;
        if ($scale) {
            $d = $diff / $scale;
        } else {
            my $den = List::Util::max(abs($x->{value}), abs($y->{value}));
            $d = $den > 0 ? $diff / $den : 0;
        }
        $d = 1 if $d > 1;
        $sum += $d;
        $n++;
        push @det, { key => $k, a => $x->{value}, b => $y->{value}, d => sprintf('%.3f', $d) + 0 };
    }
    return ($n ? $sum / $n : undef, \@det);
}

sub _ppd_demo_dist {
    my ($fa, $fb) = @_;
    my @d;
    push @d, List::Util::min(abs($fa->{age} - $fb->{age}) / $PPD_AGE_SCALE, 1)
        if defined $fa->{age} && defined $fb->{age};
    if (defined $fa->{sex} && defined $fb->{sex}) {
        push @d, $fa->{sex} eq $fb->{sex} ? 0 : 1;
    } elsif (defined $fa->{sex} || defined $fb->{sex}) {
        push @d, 0.5;
    }
    return @d ? List::Util::sum(@d) / @d : undef;
}

# ---------------------------------------------------------
# Kern: Distanz zweier Merkmalsvektoren
# $opts: weights {}, exact ['sex'], explain (0), hpo_sim sub
# Lateralität: RA = LA, unterschieden wird nur einseitig vs. beidseitig
# ---------------------------------------------------------
sub phenopacket_distance_features {
    my ($fa, $fb, $opts) = @_;
    $opts //= {};
    my %w       = (%PPD_DEFAULT_WEIGHTS, %{ $opts->{weights} // {} });
    my $hpo_sim = $opts->{hpo_sim} // sub { $_[0] eq $_[1] ? 1 : 0 };
    my $explain = $opts->{explain} ? 1 : 0;

    for my $e (@{ $opts->{exact} // [] }) {
        if ($e eq 'sex' && defined $fa->{sex} && defined $fb->{sex} && $fa->{sex} ne $fb->{sex}) {
            return { distance => undef, excluded_by => 'sex' };
        }
    }

    my $sf = sub { _ppd_side_factor($_[0]{side}, $_[1]{side}) };
    my (%blk, %det, $crossed);

    ($blk{diseases}, $det{diseases}) = _ppd_bma($fa->{diseases}, $fb->{diseases},
        sub { _ppd_chain_sim('icd10', $_[0]{id}, $_[1]{id}) * $sf->(@_) }, $explain);
    ($blk{procedures}, $det{procedures}) = _ppd_bma($fa->{procedures}, $fb->{procedures},
        sub { _ppd_chain_sim('ops', $_[0]{id}, $_[1]{id}) * $sf->(@_) }, $explain);
    ($blk{medications}, $det{medications}) = _ppd_bma($fa->{medications}, $fb->{medications},
        sub { _ppd_chain_sim('atc', $_[0]{id}, $_[1]{id}) * $sf->(@_) }, $explain);
    ($blk{phenotypes}, $det{phenotypes}) = _ppd_bma($fa->{phenotypes}, $fb->{phenotypes},
        sub { $hpo_sim->($_[0]{id}, $_[1]{id}) * $sf->(@_) }, $explain);
    ($blk{measurements}, $det{measurements}, $crossed) = _ppd_meas_dist_eye_agnostic($fa->{measurements}, $fb->{measurements});
    $blk{demographics} = _ppd_demo_dist($fa, $fb);

    my ($num, $den, $wall) = (0, 0, 0);
    for my $b (keys %blk) {
        my $wb = $w{$b} // 0;
        next unless $wb > 0;
        $wall += $wb;
        next unless defined $blk{$b};
        $num += $wb * $blk{$b};
        $den += $wb;
    }
    my $r = {
        distance          => $den ? sprintf('%.4f', $num / $den) + 0 : undef,
        meas_eyes_crossed => $crossed ? \1 : \0,
        coverage          => $wall ? sprintf('%.3f', $den / $wall) + 0 : 0,
        blocks            => { map { $_ => (defined $blk{$_} ? sprintf('%.4f', $blk{$_}) + 0 : undef) } keys %blk },
    };
    $r->{details} = \%det if $explain;
    return $r;
}

sub _ppd_parse_json {
    my ($v) = @_;
    return $v if ref $v eq 'HASH';
    return undef unless defined $v && length $v;
    my $d = eval { from_json($v) } // eval { decode_json($v) } // eval { decode_json(encode('UTF-8', $v)) };
    return ref $d eq 'HASH' ? $d : undef;
}

sub _ppd_opts {
    my ($p) = @_;
    return {
        weights => (ref $p->{weights} eq 'HASH' ? $p->{weights} : {}),
        exact   => (ref $p->{exact} eq 'ARRAY' ? $p->{exact} : []),
        explain => to_bool($p->{explain}),
    };
}

# ---------------------------------------------------------
# HELPER: HPO-Ähnlichkeit über Vorfahrenmengen (isas, gecacht)
# ---------------------------------------------------------
helper hpo_ancestor_set => sub {
    my ($self, $code) = @_;
    state %cache;
    my $id = _hpo_to_int($code);
    return {} unless defined $id;
    return $cache{$id} if $cache{$id};
    my $rows = eval {
        $self->pg->db->query(q{
            WITH RECURSIVE up AS (
                SELECT ?::int AS id
                UNION
                SELECT i.idparent FROM public.isas i JOIN up ON i.idchild = up.id
            )
            SELECT id FROM up
        }, $id)->arrays->to_array;
    } // [];
    my %set = map { $_->[0] => 1 } grep { !$PPD_HPO_TRIVIAL{ $_->[0] } } @$rows;
    $set{$id} = 1;
    return $cache{$id} = \%set;
};

helper hpo_similarity => sub {
    my ($self, $x, $y) = @_;
    return 1 if $x eq $y;
    state %cache;
    my $key = $x lt $y ? "$x|$y" : "$y|$x";
    return $cache{$key} if exists $cache{$key};
    my $A = $self->hpo_ancestor_set($x);
    my $B = $self->hpo_ancestor_set($y);
    my $inter = grep { $B->{$_} } keys %$A;
    my $union = keys(%$A) + keys(%$B) - $inter;
    return $cache{$key} = ($union ? $inter / $union : 0);
};

# Phenopackets (oder bereits extrahierte Merkmale) vergleichen
helper phenopacket_distance => sub {
    my ($self, $pa, $pb, $opts) = @_;
    my %o = %{ $opts // {} };
    $o{hpo_sim} //= sub { $self->hpo_similarity(@_) };
    my $fa = (ref $pa eq 'HASH' && $pa->{_ppd}) ? $pa : extract_ppd_features($pa);
    my $fb = (ref $pb eq 'HASH' && $pb->{_ppd}) ? $pb : extract_ppd_features($pb);
    return phenopacket_distance_features($fa, $fb, \%o);
};

# Kandidaten laden; standardmäßig nur der jüngste Brief je Pseudonym
helper ppd_load_candidates => sub {
    my ($self, %arg) = @_;
    my @where = ("phenopacket_json IS NOT NULL");
    my @bind;
    if (ref $arg{ids} eq 'ARRAY' && @{ $arg{ids} }) {
        push @where, "id = ANY(?)";
        push @bind, [ map { int($_) } @{ $arg{ids} } ];
    }
    if (defined $arg{tag} && length $arg{tag}) {
        push @where, "tags ILIKE ?";
        push @bind, "%$arg{tag}%";
    }
    my $w   = join ' AND ', @where;
    my $sql = ($arg{latest_per_patient} // 1)
        ? "SELECT DISTINCT ON (COALESCE(pseudonym, id::text)) id, pseudonym, reference_date, phenopacket_json
             FROM candidates WHERE $w
            ORDER BY COALESCE(pseudonym, id::text), reference_date DESC NULLS LAST, id DESC"
        : "SELECT id, pseudonym, reference_date, phenopacket_json FROM candidates WHERE $w ORDER BY id";
    if ($arg{limit}) {
        $sql = "SELECT * FROM ($sql) s LIMIT ?";
        push @bind, int($arg{limit});
    }
    my $rows = $self->pg->db->query($sql, @bind)->hashes->to_array;
    my @out;
    for my $r (@$rows) {
        my $pp = _ppd_parse_json($r->{phenopacket_json}) or next;
        push @out, { id => $r->{id}, pseudonym => $r->{pseudonym},
                     reference_date => $r->{reference_date}, f => extract_ppd_features($pp) };
    }
    return \@out;
};

# =========================================================
# ENDPUNKT: Distanz zweier Phenopackets
# Body: { a: <candidate_id | phenopacket>, b: <...>,
#         weights: {...}, exact: ["sex"], explain: true }
# =========================================================
post '/BBB/phenopacket_distance' => sub {
    my $c = shift;
    my $p = $c->req->json // {};

    my $resolve = sub {
        my ($v) = @_;
        return undef unless defined $v;
        return _ppd_parse_json($v) if ref $v || $v !~ /^\d+$/;
        my $row = $c->pg->db->select('candidates', ['phenopacket_json'], { id => $v })->hash;
        return $row ? _ppd_parse_json($row->{phenopacket_json}) : undef;
    };
    my $pa = $resolve->($p->{a} // $p->{candidate_a});
    my $pb = $resolve->($p->{b} // $p->{candidate_b});
    return $c->render(json => { error => "Parameter 'a' und 'b' (candidate_id oder Phenopacket) erforderlich." }, status => 400)
        unless $pa && $pb;

    my $res = eval { $c->phenopacket_distance($pa, $pb, _ppd_opts($p)) };
    return $c->render(json => { error => "$@" }, status => 500) if $@;
    $c->render(json => $res);
};

# =========================================================
# ENDPUNKT: k nächste Nachbarn eines Kandidaten
# Body: { candidate_id, tag?, candidate_ids?, k: 10, caliper?, max_pool: 5000,
#         exclude_same_pseudonym: true, weights, exact }
# =========================================================
post '/BBB/phenopacket_distance/nearest' => sub {
    my $c = shift;
    $c->inactivity_timeout(900);
    my $p   = $c->req->json // {};
    my $cid = $p->{candidate_id}
        or return $c->render(json => { error => "Parameter 'candidate_id' erforderlich." }, status => 400);

    my ($ref) = @{ $c->ppd_load_candidates(ids => [$cid], latest_per_patient => 0) };
    return $c->render(json => { error => "Kandidat $cid ohne Phenopacket." }, status => 404) unless $ref;

    my $pool = $c->ppd_load_candidates(
        ids => $p->{candidate_ids}, tag => $p->{tag},
        limit => $p->{max_pool} // 5000, latest_per_patient => $p->{latest_per_patient} // 1);

    my $opts      = _ppd_opts($p);
    my $k         = int($p->{k} // 10) || 10;
    my $caliper   = $p->{caliper};
    my $excl_same = exists $p->{exclude_same_pseudonym} ? to_bool($p->{exclude_same_pseudonym}) : 1;

    my @res;
    for my $cand (@$pool) {
        next if $cand->{id} == $ref->{id};
        next if $excl_same && defined $ref->{pseudonym} && defined $cand->{pseudonym}
             && $cand->{pseudonym} eq $ref->{pseudonym};
        my $r = $c->phenopacket_distance($ref->{f}, $cand->{f}, $opts);
        next unless defined $r->{distance};
        next if defined $caliper && $r->{distance} > $caliper;
        push @res, { candidate_id => $cand->{id}, pseudonym => $cand->{pseudonym},
                     reference_date => $cand->{reference_date}, %$r };
    }
    @res = sort { $a->{distance} <=> $b->{distance} } @res;
    splice(@res, $k) if @res > $k;

    $c->render(json => { candidate_id => $ref->{id}, pseudonym => $ref->{pseudonym},
                         pool_size => scalar(@$pool), neighbours => \@res });
};

# =========================================================
# ENDPUNKT: Greedy-Matching Fälle -> Kontrollen (1:ratio, Caliper)
# Body: { treated_ids | treated_tag, control_ids | control_tag,
#         ratio: 1, caliper: 0.35, replace: false, max_pool: 5000,
#         weights, exact: ["sex"] }
# Aufwand O(Fälle x Kontrollen); große Kohorten besser als Minion-Task.
# =========================================================
post '/BBB/propensity_match' => sub {
    my $c = shift;
    $c->inactivity_timeout(3000);
    my $p = $c->req->json // {};

    unless ((ref $p->{treated_ids} eq 'ARRAY' && @{ $p->{treated_ids} }) || $p->{treated_tag}) {
        return $c->render(json => { error => "Parameter 'treated_ids' oder 'treated_tag' erforderlich." }, status => 400);
    }

    my $treated  = $c->ppd_load_candidates(ids => $p->{treated_ids}, tag => $p->{treated_tag});
    my $controls = $c->ppd_load_candidates(ids => $p->{control_ids}, tag => $p->{control_tag},
                                           limit => $p->{max_pool} // 5000);

    my $ratio   = int($p->{ratio} // 1) || 1;
    my $caliper = $p->{caliper};
    my $replace = to_bool($p->{replace});
    my $opts    = _ppd_opts($p);
    $opts->{explain} = 0;

    # Kontrollen dürfen nicht dieselben Patienten wie die Fälle sein
    my %tp   = map { (($_->{pseudonym} // "id$_->{id}") => 1) } @$treated;
    my @ctrl = grep { !$tp{ $_->{pseudonym} // "id$_->{id}" } } @$controls;

    my @pairs;
    for my $t (@$treated) {
        for my $k (@ctrl) {
            my $r = $c->phenopacket_distance($t->{f}, $k->{f}, $opts);
            next unless defined $r->{distance};
            next if defined $caliper && $r->{distance} > $caliper;
            push @pairs, [ $r->{distance}, $t, $k ];
        }
    }
    @pairs = sort { $a->[0] <=> $b->[0] } @pairs;

    my (%n_t, %used_c, %matches);
    for my $pr (@pairs) {
        my ($d, $t, $k) = @$pr;
        next if ($n_t{ $t->{id} } // 0) >= $ratio;
        next if !$replace && $used_c{ $k->{id} };
        $n_t{ $t->{id} }++;
        $used_c{ $k->{id} }++;
        push @{ $matches{ $t->{id} } }, { candidate_id => $k->{id}, pseudonym => $k->{pseudonym},
                                          distance => $d };
    }

    my @out = map { +{ treated_id => $_->{id}, treated_pseudonym => $_->{pseudonym},
                       controls => $matches{ $_->{id} } // [] } } @$treated;
    my @d_all = map { $_->{distance} } map { @{ $_->{controls} } } @out;

    $c->render(json => {
        n_treated        => scalar(@$treated),
        n_controls_pool  => scalar(@ctrl),
        n_fully_matched  => scalar(grep { @{ $_->{controls} } == $ratio } @out),
        mean_distance    => @d_all ? sprintf('%.4f', List::Util::sum(@d_all) / @d_all) + 0 : undef,
        unmatched        => [ map { $_->{treated_id} } grep { !@{ $_->{controls} } } @out ],
        matches          => \@out,
    });
};

get '/BBB/candidates/count_by_tag' => sub {
    my $c   = shift;
    my $tag = $c->param('tag') // '';
    $tag =~ s/^\s+|\s+$//g;
    return $c->render(json => { success => 0, error => "Parameter 'tag' ist erforderlich." }, status => 400)
        unless length $tag;

    my $row = eval {
        $c->pg->db->query(q{
            SELECT count(*) AS n FROM candidates
             WHERE (tags ILIKE ? OR tags ILIKE ? OR tags ILIKE ? OR tags = ?)
               AND narrative_report IS NOT NULL
               AND TRIM(narrative_report) <> ''
        }, "%$tag,%", "%, $tag%", "%$tag", $tag)->hash;
    };
    return $c->render(json => { success => 0, error => 'Datenbankfehler' }, status => 500) unless $row;
    $c->render(json => { success => 1, tag => $tag, count => $row->{n} + 0 });
};

# =========================================================
# ENDPUNKT: KANDIDATEN NACH TAG NEU BERECHNEN (MINION QUEUE)
# =========================================================
post '/BBB/candidates/recompute_by_tag' => sub {
    my $c = shift;
    my $payload = $c->req->json // {};
    my $tag            = $payload->{tag};
    my $selected_model = $payload->{model};
    my $deep_mode      = $payload->{deep_mode} // 0;

    unless ($tag && length($tag)) {
        return $c->render(json => { success => 0, error => "Parameter 'tag' ist erforderlich." }, status => 400);
    }

    $tag =~ s/^\s+|\s+$//g;
    my $db = $c->pg->db;

    # Alle Kandidaten mit dem Tag laden, die einen Freitextbericht besitzen
    my $candidates = eval {
        $db->query(q{
                        SELECT id, doc_id, pseudonym, narrative_report, reference_date
                        FROM candidates
                        WHERE (tags ILIKE ? OR tags ILIKE ? OR tags ILIKE ? OR tags = ?)
                          AND narrative_report IS NOT NULL
                          AND TRIM(narrative_report) <> ''
                        ORDER BY id ASC
                    }, "%$tag,%", "%, $tag%", "%$tag", $tag)->hashes->to_array;
    };

    if ($@) {
        $c->app->log->error("[RECOMPUTE BY TAG ERROR] $@");
        return $c->render(json => { success => 0, error => "DB Fehler: $@" }, status => 500);
    }

    my $queued_count = 0;
    for my $cand (@$candidates) {
        $c->minion->enqueue(import_and_extract_letter_task => [{
            candidate_id   => $cand->{id},
            pseudonym      => $cand->{pseudonym},
            doc_id         => $cand->{doc_id},
            text_content   => $cand->{narrative_report},
            reference_date => $cand->{reference_date},
            model          => $selected_model,
            deep_mode      => $deep_mode
        }]);
        $queued_count++;
    }

    $c->app->log->info("[RECOMPUTE BY TAG] $queued_count Kandidaten mit Tag '$tag' zur Neu-Extraktion in Minion eingereiht.");
    $c->render(json => { success => 1, tag => $tag, queued => $queued_count });
};

# =========================================================
# ANONYMISIERTER PHENOPACKET-EXPORT
# (DSFA OntoTrial V1.0 / Datenschutzkurzkonzept, Anlage V1.4)
#
#   Filter 1  Zero-Free-Text: nur validierte Codes mit kanonischem Label aus der
#             Terminologietabelle. canonical_term, Verbatim-Texte, Messungs-
#             Modifier und freie Einheiten werden nicht übernommen.
#   Filter 2  Flüchtige Zufalls-IDs je Exportlauf (/dev/urandom). Die Zuordnung
#             Pseudonym -> subject-ID existiert nur im Arbeitsspeicher dieses
#             Requests und wird nirgends gespeichert oder geloggt.
#   Filter 3  Monats-Trunkierung (JJJJ-MM) plus patientenkonstanter Versatz
#             Δm ∈ {-3,-2,-1,+1,+2,+3}. Nicht parsbare Daten ("PAST-UK-UK") entfallen.
#   Filter 4  Alter in vollen Jahren, Top-Coding ab 90 (P90Y = "90 oder älter"),
#             Generalisierung seltener Codes entlang der Hierarchie, bis jeder
#             ausgegebene Code von mindestens k Patienten stammt (k >= 5).
#
# Einfügen in backend.pl VOR dem Abschnitt
#   "GENERIC DB REST CRUD ENDPOINTS (MIT 1/1-SICHERUNG)",
# sonst fängt POST '/BBB/:table/:pk' die Anfrage ab.
# Benötigt die bereits vorhandenen _ppd_code_chain, _ppd_parse_json,
# _hpo_to_int, %PPD_HPO_TRIVIAL, to_bool und get_canonical_ontology_label.
# =========================================================

our $ANON_MIN_K  = 5;
our @ANON_SHIFTS = (-3, -2, -1, 1, 2, 3);

our %ANON_LATERALITY = (
    'HP:0012834'      => 'Right',
    'HP:0012835'      => 'Left',
    'HP:0012832'      => 'Bilateral',
    'SNOMED:18944008' => 'Right eye structure',
    'SNOMED:8966001'  => 'Left eye structure',
    'SNOMED:40638003' => 'Structure of both eyes',
);

# Lokale LOINC-Erweiterungscodes stehen nicht in loinc_terms
our %ANON_STATIC_LABELS = (
    'LOINC:86290-4a' => 'Left eye Retinal ganglion cell and inner plexiform layer volume by OCT',
    'LOINC:86301-9a' => 'Right eye Retinal ganglion cell and inner plexiform layer volume by OCT',
    'LOINC:86290-4b' => 'Left eye Bruch membrane opening area by OCT',
    'LOINC:86301-9b' => 'Right eye Bruch membrane opening area by OCT',
    # PATCH 2026-10-22: Katarakt-OP
    'LOINC:95327-A'  => 'Right eye Target refraction, planned postoperative (local code)',
    'LOINC:95328-A'  => 'Left eye Target refraction, planned postoperative (local code)',
    'LOINC:64817-A'  => 'Right eye Phacoemulsification cumulative dissipated energy (local code)',
    'LOINC:64818-A'  => 'Left eye Phacoemulsification cumulative dissipated energy (local code)',
    'LOINC:64819-A'  => 'Right eye Intraocular lens power, implanted (local code)',
    'LOINC:64820-A'  => 'Left eye Intraocular lens power, implanted (local code)',
    # PATCH 2026-10-23: Endotamponade
    'LOINC:64821-A'  => 'Right eye Vitreous cavity endotamponade (local code)',
    'LOINC:64822-A'  => 'Left eye Vitreous cavity endotamponade (local code)',
    'LOINC:64823-A'  => 'Right eye Anterior chamber tamponade (local code)',
    'LOINC:64824-A'  => 'Left eye Anterior chamber tamponade (local code)',
);

our %ANON_QUALITATIVE = map { $_ => 1 } ('Positive / Detected', 'Examined');
our %ANON_COMPARATORS = map { $_ => 1 } ('=', '<', '<=', '>', '>=');
our $ANON_UNIT_RE     = qr{^(?:[A-Za-zµ°%{}/.\^0-9*]{1,20}|scale \([A-Za-z0-9-]{1,12}\))$};
our %ANON_SEX         = (MALE => 'MALE', FEMALE => 'FEMALE', OTHER_SEX => 'OTHER_SEX');

our @ANON_RESOURCES = (
    { id => 'hp',     name => 'human phenotype ontology',                          namespacePrefix => 'HP' },
    { id => 'loinc',  name => 'Logical Observation Identifiers Names and Codes',   namespacePrefix => 'LOINC' },
    { id => 'icd10',  name => 'International Classification of Diseases 10 (GM)',  namespacePrefix => 'ICD10' },
    { id => 'ops',    name => 'Operationen- und Prozedurenschlüssel',               namespacePrefix => 'OPS' },
    { id => 'atc',    name => 'Anatomical Therapeutic Chemical Classification',     namespacePrefix => 'ATC' },
    { id => 'snomed', name => 'SNOMED Clinical Terms',                              namespacePrefix => 'SNOMED' },
);

# ---------------------------------------------------------
# Zufall aus /dev/urandom (Perls rand() ist nicht kryptographisch)
# ---------------------------------------------------------
sub _anon_random_bytes {
    my ($n) = @_;
    open my $fh, '<:raw', '/dev/urandom' or die "Kein /dev/urandom: $!\n";
    my $got = read($fh, my $buf, $n);
    close $fh;
    die "Zu wenige Zufallsbytes\n" unless defined $got && $got == $n;
    return $buf;
}

sub _anon_random_id { return unpack('H*', _anon_random_bytes($_[0] // 8)) }

sub _anon_random_shift {
    while (1) {                                   # Ablehnungsverfahren gegen Modulo-Verzerrung
        my $b = ord(_anon_random_bytes(1));
        return $ANON_SHIFTS[$b % 6] if $b < 252;
    }
}

sub _anon_shuffle {
    my @a = @_;
    return @a if @a < 2;
    my @r = unpack('N*', _anon_random_bytes(4 * $#a));
    for (my $i = $#a; $i > 0; $i--) {
        my $j = $r[$i - 1] % ($i + 1);
        @a[$i, $j] = @a[$j, $i];
    }
    return @a;
}

# ---------------------------------------------------------
# Datum, Alter, Listen, Domäne
# ---------------------------------------------------------
sub _anon_shift_ts {
    my ($ts, $delta) = @_;
    return undef unless defined $ts && !ref $ts;
    if ($ts =~ /^(\d{4})-(\d{2})/ && $2 >= 1 && $2 <= 12) {
        my $t = $1 * 12 + ($2 - 1) + $delta;
        return sprintf('%04d-%02d', int($t / 12), $t % 12 + 1);
    }
    return $1 if $ts =~ /^(\d{4})$/;               # Jahr allein ist gröber als ein Monat
    return undef;
}

sub _anon_age {
    my ($iso) = @_;
    return undef unless defined $iso && !ref $iso && $iso =~ /^P(\d{1,3})Y/;
    my $y = $1 + 0;
    $y = 90 if $y > 90;
    return "P${y}Y";
}

sub _anon_list { return ref $_[0] eq 'ARRAY' ? @{ $_[0] } : () }

sub _anon_domain {
    my ($id) = @_;
    return undef unless defined $id && !ref $id;
    return 'hpo'   if $id =~ /^HP:\d{7}$/;
    return 'icd10' if $id =~ /^ICD10:\S+$/;
    return 'ops'   if $id =~ /^OPS:\S+$/;
    return 'atc'   if $id =~ /^ATC:\S+$/;
    return 'loinc' if $id =~ /^LOINC:\S+$/;
    return undef;
}

sub _anon_collect_codes {
    my ($pp) = @_;
    my $id_of = sub {
        my ($h, $k) = @_;
        return (ref $h eq 'HASH' && ref $h->{$k} eq 'HASH' && defined $h->{$k}{id}) ? $h->{$k}{id} : ();
    };
    my @ids;
    push @ids, map { $id_of->($_, 'type')  } _anon_list($pp->{phenotypicFeatures});
    push @ids, map { $id_of->($_, 'term')  } _anon_list($pp->{diseases});
    push @ids, map { $id_of->($_, 'code')  } _anon_list($pp->{procedures});
    push @ids, map { $id_of->($_, 'assay') } _anon_list($pp->{measurements});
    for my $act (_anon_list($pp->{medicalActions})) {
        next unless ref $act eq 'HASH';
        push @ids, $id_of->($act->{procedure}, 'code');
        push @ids, $id_of->($act->{treatment}, 'agent');
    }
    return @ids;
}

# ---------------------------------------------------------
# Hierarchiekette eines Codes, von allgemein nach spezifisch.
# Untergrenzen: ICD-10 Dreisteller, OPS Viersteller, ATC Ebene 3.
# LOINC wird nicht generalisiert (seltene Assays entfallen).
# ---------------------------------------------------------
helper anon_code_chain => sub {
    my ($self, $id) = @_;
    state %cache;
    return @{ $cache{$id} } if $cache{$id};
    my $dom = _anon_domain($id) or return ();

    my @chain;
    if ($dom =~ /^(?:icd10|ops|atc)$/) {
        my %pfx  = (icd10 => 'ICD10:', ops => 'OPS:', atc => 'ATC:');
        my %skip = (icd10 => 1, ops => 2, atc => 2);
        my @c = _ppd_code_chain($dom, $id);
        splice(@c, 0, $skip{$dom}) if @c > $skip{$dom};
        @chain = map { $pfx{$dom} . $_ } @c;
    } elsif ($dom eq 'hpo') {
        @chain = ($id);
        my $cur = _hpo_to_int($id);
        for (1 .. 8) {
            my $r = eval {
                $self->pg->db->query(
                    'SELECT idparent FROM public.isas WHERE idchild = ? ORDER BY idparent LIMIT 1', $cur
                )->array;
            };
            last unless $r && defined $r->[0];
            $cur = $r->[0];
            last if $PPD_HPO_TRIVIAL{$cur};
            unshift @chain, sprintf('HP:%07d', $cur);
        }
    } else {
        @chain = ($id);
    }
    $cache{$id} = \@chain;
    return @chain;
};

# Kanonisches Label; undef bei unbekannten oder veralteten Codes
helper anon_label => sub {
    my ($self, $id) = @_;
    state %cache;
    return $cache{$id} if exists $cache{$id};
    my $label = $ANON_LATERALITY{$id} // $ANON_STATIC_LABELS{$id};
    if (!defined $label && (my $dom = _anon_domain($id))) {
        $label = eval { $self->get_canonical_ontology_label($dom, $id) };
    }
    $label = undef if defined $label && ($label !~ /\S/ || $label =~ /^\s*(?:obsolete|deprecated)\b/i);
    return $cache{$id} = $label;
};

# ---------------------------------------------------------
# Generalisierung: jedem Code den spezifischsten Knoten zuordnen,
# den mindestens k Patienten teilen. Wiederholt, bis jeder AUSGEGEBENE
# Code von >= k Patienten stammt. Negierte Befunde werden nie verallgemeinert
# ("kein H40.1" bedeutet nicht "kein H40"), sondern bei Seltenheit verworfen.
# ---------------------------------------------------------
helper anon_build_generalizer => sub {
    my ($self, $codes_by_patient, $k) = @_;
    my (%chain, %level);
    for my $codes (values %$codes_by_patient) {
        for my $id (keys %$codes) {
            next if exists $chain{$id};
            $chain{$id} = [ $self->anon_code_chain($id) ];
            $level{$id} = $#{ $chain{$id} };          # -1, wenn keine gültige Kette
        }
    }

    my $count = sub {
        my %cnt;
        for my $codes (values %$codes_by_patient) {
            my %seen;
            $seen{ $chain{$_}[ $level{$_} ] } = 1 for grep { $level{$_} >= 0 } keys %$codes;
            $cnt{$_}++ for keys %seen;
        }
        return \%cnt;
    };

    for (1 .. 50) {
        my $cnt = $count->();
        my $changed = 0;
        for my $id (keys %level) {
            next if $level{$id} < 0;
            next if ($cnt->{ $chain{$id}[ $level{$id} ] } // 0) >= $k;
            $level{$id}--;
            $changed = 1;
        }
        last unless $changed;
    }
    my $final = $count->();                            # Sicherung, falls die Schleife abbricht
    for my $id (keys %level) {
        next if $level{$id} < 0;
        $level{$id} = -1 if ($final->{ $chain{$id}[ $level{$id} ] } // 0) < $k;
    }

    return sub {
        my ($id, $excluded) = @_;
        return undef unless defined $id && exists $level{$id} && $level{$id} >= 0;
        return undef if $excluded && $level{$id} != $#{ $chain{$id} };
        return $chain{$id}[ $level{$id} ];
    };
};

# ---------------------------------------------------------
# Ein Phenopacket neu aufbauen (Whitelist statt Blacklist)
# $ctx: subject_id, shift, gen, stats, created
# ---------------------------------------------------------
helper anon_phenopacket => sub {
    my ($self, $pp, $ctx) = @_;
    my $st = $ctx->{stats};

    my $code = sub {
        my ($id, $excluded) = @_;
        my $g = $ctx->{gen}->($id, $excluded);
        unless (defined $g) { $st->{codes_suppressed}++; return undef }
        my $l = $self->anon_label($g);
        unless (defined $l) { $st->{codes_unresolved}++; return undef }
        my @ch = $self->anon_code_chain($id);
        $st->{codes_generalized}++ if @ch && $g ne $ch[-1];
        return { id => $g, label => $l };
    };
    my $lat = sub {
        my ($o) = @_;
        my $id = (ref $o eq 'HASH' && defined $o->{id}) ? $o->{id} : '';
        return exists $ANON_LATERALITY{$id} ? { id => $id, label => $ANON_LATERALITY{$id} } : undef;
    };
    my $ts  = sub { _anon_shift_ts($_[0], $ctx->{shift}) };
    my $get = sub { my ($h, @path) = @_; for (@path) { return undef unless ref $h eq 'HASH'; $h = $h->{$_} } return $h };

    # --- Subject ---
    my $subj = ref $pp->{subject} eq 'HASH' ? $pp->{subject} : {};
    my %subject = (
        id       => $ctx->{subject_id},
        sex      => $ANON_SEX{ uc($subj->{sex} // '') } // 'UNKNOWN_SEX',
        taxonomy => { id => 'NCBITaxon:9606', label => 'homo sapiens' },
    );
    if (my $age = _anon_age($get->($subj, qw(timeAtLastEncounter age iso8601duration)))) {
        $subject{timeAtLastEncounter} = { age => { iso8601duration => $age } };
    }

    # --- Phänotypen ---
    my (@features, %seen_f);
    for my $f (_anon_list($pp->{phenotypicFeatures})) {
        next unless ref $f eq 'HASH';
        my $ex   = to_bool($f->{excluded}) ? 1 : 0;
        my $t    = $code->($get->($f, qw(type id)), $ex) or next;
        my @mods = grep { defined } map { $lat->($_) } _anon_list($f->{modifiers});
        my $on   = $ts->($get->($f, qw(onset timestamp)));
        next if $seen_f{ join '|', $t->{id}, (map { $_->{id} } @mods), $ex, $on // '' }++;
        my $node = { type => $t };
        $node->{modifiers} = \@mods                    if @mods;
        $node->{excluded}  = Mojo::JSON->true          if $ex;
        $node->{onset}     = { timestamp => $on }      if defined $on;
        push @features, $node;
    }

    # --- Messungen ---
    my (@measurements, %seen_m);
    for my $m (_anon_list($pp->{measurements})) {
        next unless ref $m eq 'HASH';
        my $a = $code->($get->($m, qw(assay id)), 0) or next;
        my ($value, $vsig);
        my $q = $get->($m, qw(value quantity));
        my $oc = $get->($m, qw(value ontologyClass));
        if (ref $q eq 'HASH') {
            my $v   = $q->{value};
            my $u   = ref $q->{unit} eq 'HASH' ? $q->{unit}{label} : $q->{unit};
            my $cmp = $q->{comparator} // '=';
            unless (defined $v && !ref $v && $v =~ /^-?\d+(?:\.\d+)?$/
                    && $ANON_COMPARATORS{$cmp} && defined $u && !ref $u && $u =~ $ANON_UNIT_RE) {
                $st->{values_dropped}++;
                next;
            }
            $value = { quantity => { comparator => $cmp, value => $v + 0, unit => { label => $u } } };
            $vsig  = "$cmp$v$u";
        } elsif (ref $oc eq 'HASH' && ($oc->{id} // '') eq 'NCIT:C25250'
                 && ($ANON_QUALITATIVE{ $oc->{label} // '' } || ($oc->{label} // '') =~ $TAMPONADE_LABEL_RE)) {   # PATCH 2026-10-23
            $value = { ontologyClass => { id => 'NCIT:C25250', label => $oc->{label} } };
            $vsig  = $oc->{label};
        } else {
            $st->{values_dropped}++;
            next;
        }
        my @mods = grep { defined } map { $lat->($_) } _anon_list($m->{modifiers});
        my $tc   = $ts->($get->($m, qw(timeOfCollection timestamp)));
        next if $seen_m{ join '|', $a->{id}, (map { $_->{id} } @mods), $vsig, $tc // '' }++;
        my $node = { assay => $a, value => $value };
        $node->{modifiers}        = \@mods                if @mods;
        $node->{timeOfCollection} = { timestamp => $tc }  if defined $tc;
        push @measurements, $node;
    }

    # --- Diagnosen ---
    my (@diseases, %seen_d);
    for my $d (_anon_list($pp->{diseases})) {
        next unless ref $d eq 'HASH';
        my $ex   = to_bool($d->{excluded}) ? 1 : 0;
        my $t    = $code->($get->($d, qw(term id)), $ex) or next;
        my $site = $lat->($d->{primarySite});
        my $on   = $ts->($get->($d, qw(onset timestamp)));
        next if $seen_d{ join '|', $t->{id}, ($site ? $site->{id} : ''), $ex, $on // '' }++;
        my $node = { term => $t };
        $node->{excluded}    = Mojo::JSON->true      if $ex;
        $node->{primarySite} = $site                 if $site;
        $node->{onset}       = { timestamp => $on }  if defined $on;
        push @diseases, $node;
    }

    # --- Prozeduren (Top-Level wie im Konzept-Listing) ---
    my (@procedures, %seen_p);
    for my $p (_anon_list($pp->{procedures})) {
        next unless ref $p eq 'HASH';
        my $cd   = $code->($get->($p, qw(code id)), 0) or next;
        my $site = $lat->($p->{bodySite});
        my $pt   = $ts->($p->{performedTime});
        next if $seen_p{ join '|', $cd->{id}, ($site ? $site->{id} : ''), $pt // '' }++;
        my $node = { code => $cd };
        $node->{bodySite}      = $site if $site;
        $node->{performedTime} = $pt   if defined $pt;
        push @procedures, $node;
    }

    # --- Medical Actions ---
    my (@actions, %seen_a);
    for my $act (_anon_list($pp->{medicalActions})) {
        next unless ref $act eq 'HASH';
        if (ref $act->{procedure} eq 'HASH') {
            my $pr   = $act->{procedure};
            my $cd   = $code->($get->($pr, qw(code id)), 0) or next;
            my $site = $lat->($pr->{bodySite});
            my $pt   = $ts->($get->($pr, qw(performed timestamp)));
            next if $seen_a{ join '|', 'P', $cd->{id}, ($site ? $site->{id} : ''), $pt // '' }++;
            my $node = { code => $cd };
            $node->{bodySite}  = $site                 if $site;
            $node->{performed} = { timestamp => $pt }  if defined $pt;
            push @actions, { procedure => $node };
        } elsif (ref $act->{treatment} eq 'HASH') {
            my $tr   = $act->{treatment};
            my $ag   = $code->($get->($tr, qw(agent id)), 0) or next;
            my $site = $lat->($tr->{bodySite});
            my $pt   = $ts->($tr->{performedTime} // $get->($tr, qw(performed timestamp)));
            next if $seen_a{ join '|', 'T', $ag->{id}, ($site ? $site->{id} : ''), $pt // '' }++;
            my $node = { agent => $ag };
            $node->{bodySite}      = $site if $site;
            $node->{performedTime} = $pt   if defined $pt;
            push @actions, { treatment => $node };
        }
    }

    my $ref_month = $ts->($pp->{reference_date});
    my $created   = (defined $ref_month && $ref_month =~ /^\d{4}-\d{2}$/)
                  ? "$ref_month-01T00:00:00Z"
                  : $ctx->{created};

    return {
        id                 => 'phenopacket-' . _anon_random_id(8),
        (defined $ref_month ? (reference_date => $ref_month) : ()),
        subject            => \%subject,
        phenotypicFeatures => \@features,
        measurements       => \@measurements,
        diseases           => \@diseases,
        procedures         => \@procedures,
        medicalActions     => \@actions,
        metaData           => {
            created                  => $created,
            createdBy                => 'OntoTrial-DeidentificationEngine',
            phenopacketSchemaVersion => '2.0.0',
            resources                => [ map { +{ %$_ } } @ANON_RESOURCES ],
        },
    };
};

# =========================================================
# ENDPUNKT: ANONYMISIERTER EXPORT
# Body: { tag?: "...", candidate_ids?: [..], k?: 5 }
# Ein Phenopacket pro Arztbrief, Verlaufskopplung über subject.id,
# die nur innerhalb dieses Exportlaufs gilt.
# =========================================================
post '/BBB/export/anonymized_phenopackets' => sub {
    my $c = shift;
    $c->inactivity_timeout(1800);
    my $p = $c->req->json // {};

    my $k = int($p->{k} // $ANON_MIN_K);
    $k = $ANON_MIN_K if $k < $ANON_MIN_K;              # DSFA: k >= 5, nur Verschärfung erlaubt

    my @where = ('phenopacket_json IS NOT NULL');
    my @bind;
    if (ref $p->{candidate_ids} eq 'ARRAY' && @{ $p->{candidate_ids} }) {
        push @where, 'id = ANY(?)';
        push @bind, [ map { int($_) } @{ $p->{candidate_ids} } ];
    }
    if (defined $p->{tag} && !ref $p->{tag} && length $p->{tag}) {
        push @where, 'tags ILIKE ?';
        push @bind, '%' . $p->{tag} . '%';
    }

    my $rows = eval {
        $c->pg->db->query('SELECT id, pseudonym, phenopacket_json FROM candidates WHERE ' . join(' AND ', @where), @bind)
          ->hashes->to_array;
    };
    return $c->render(json => { error => 'Kandidaten konnten nicht geladen werden.' }, status => 500) unless $rows;

    # Gruppierung je Patient nur im Arbeitsspeicher
    my (%packets, %codes);
    for my $r (@$rows) {
        my $pp  = _ppd_parse_json($r->{phenopacket_json}) or next;
        my $pid = (defined $r->{pseudonym} && length $r->{pseudonym}) ? "p:$r->{pseudonym}" : "c:$r->{id}";
        push @{ $packets{$pid} }, $pp;
        $codes{$pid}{$_} = 1 for _anon_collect_codes($pp);
    }
    undef $rows;

    my $n_subjects = scalar keys %packets;
    if ($n_subjects < $k) {
        return $c->render(json => {
            error => "Die Auswahl umfasst $n_subjects Patient(en); k-Anonymität mit k = $k ist nicht erreichbar."
        }, status => 422);
    }

    my $gen   = $c->anon_build_generalizer(\%codes, $k);
    my %stats = map { $_ => 0 } qw(codes_suppressed codes_generalized codes_unresolved values_dropped);
    my ($mon, $year) = (gmtime)[4, 5];
    my $created = sprintf('%04d-%02d-01T00:00:00Z', $year + 1900, $mon + 1);

    my @out;
    for my $pid (keys %packets) {
        my $ctx = {
            subject_id => 'subject-' . _anon_random_id(8),
            shift      => _anon_random_shift(),
            gen        => $gen,
            stats      => \%stats,
            created    => $created,
        };
        push @out, $c->anon_phenopacket($_, $ctx) for @{ $packets{$pid} };
    }

    # Zuordnung verwerfen (wird nicht persistiert; Perl überschreibt freigegebenen
    # Speicher allerdings nicht zuverlässig)
    %packets = ();
    %codes   = ();

    @out = _anon_shuffle(@out);                        # Reihenfolge verrät keine internen IDs

    # Nur Zählwerte loggen, keine Inhalte
    $c->app->log->info(sprintf('[ANON EXPORT] %d Patienten, %d Phenopackets, k=%d', $n_subjects, scalar(@out), $k));

    $c->render(json => {
        k              => $k,
        n_subjects     => $n_subjects,
        n_phenopackets => scalar(@out),
        suppression    => \%stats,
        phenopackets   => \@out,
    });
};

# =========================================================
# LONG-FORMAT EXPORT FÜR STATISTIK (R, Python, Stata)
#
#   GET /BBB/export/long/events    eine Zeile je kodiertem Element
#   GET /BBB/export/long/patients  eine Zeile je Arztbrief (Phenopacket)
#
# Spalten "events" (kompatibel zum Fellow-Eye-Skript):
#   pseudonym, packet_id, packet_created, letter_date, candidate_id,
#   phenopacket_id, domain, code, label, site_id, date_raw, excluded,
#   value, unit, comparator, value_text, n_mentions, last_letter_date
#     domain   : procedure | disease | phenotype | treatment | measurement
#     site_id  : HP:0012834 rechts, HP:0012835 links, HP:0012832 beidseits
#     date_raw : unverändert ('YYYY', 'YYYY-MM', 'YYYY-MM-DD', ...)
#     packet_id: 'cand-<candidate_id>', eindeutig je Brief. Die interne
#                Phenopacket-ID ("phenopacket-<sekunde>") kann bei
#                gleichzeitig fertigen Extraktionen kollidieren und steht
#                nur noch in phenopacket_id.
#     letter_date : Briefdatum (candidates.reference_date)
#     n_mentions / last_letter_date : wie oft und bis wann das Element in
#                Briefen dieses Patienten vorkam (nach Deduplizierung)
#
# Parameter (Listen kommagetrennt oder mehrfach angegeben):
#   tag=...           Tag(s), exakter Token-Vergleich, ohne Groß/Klein
#   tag_scope=        patient (Default: alle Briefe getaggter Patienten) | letter
#   has_tag=...       Grundgesamtheit: Patienten, bei denen irgendein Brief den Tag
#                     trägt (exakter Token, ohne Groß/Klein). Wird vor allen anderen
#                     Filtern angewendet, unabhängig von from/to, sources und tag_scope.
#   has_tag_match=    any (Default) | all  – bei mehreren has_tag-Werten
#   has_code=...      Patient hat (nicht negiert) einen Code unterhalb, z. B. OPS:5-125
#   pseudonyms=...    explizite Pseudonyme
#   from=, to=        Briefdatum (JJJJ-MM-TT oder TT.MM.JJJJ), inklusiv
#   event_from=, event_to=  Ereignisdatum (nur events); keep_undated=1 (Default)
#   domains=...       Default: alle fünf
#   sources=...       doc_source, z. B. argos,dwh
#   include_excluded= 1 (Default) | 0
#   dedup=            exact (Default) | code | none
#   undated=          per_packet (Default) | first
#   limit_patients=N  Testausschnitt (erste N Pseudonyme)
#   all=1             nötig, wenn weder tag, has_tag, has_code noch pseudonyms gesetzt sind
#   format=           csv (Default) | ndjson
#   token=...         bzw. Header X-Export-Token, falls ONTOTRIAL_EXPORT_TOKEN gesetzt
#
# Deduplizierung:
#   1. Briefebene: identischer Brieftext beim selben Patienten (doc_hash,
#      z. B. argos- und DWH-Kopie) zählt einmal; bevorzugt argos, dann die
#      jüngste Extraktion.
#   2. Elementebene: datierte Elemente, die in mehreren Briefen identisch
#      vorkommen (fortgeschriebene Anamnese), erscheinen einmal, mit dem
#      frühesten Brief als packet_id. Undatierte Elemente bleiben je Brief
#      erhalten (undated=per_packet), weil die Auswertung sie mit dem
#      Briefdatum datiert; undated=first behält nur die früheste Nennung.
#      dedup=exact vergleicht auch das Label, dedup=code nur den Code.
#
# ACHTUNG: Ausgabe enthält Pseudonyme und exakte Daten (personenbeziehbar).
# Für Weitergaben den anonymisierten Export verwenden.
# =========================================================

our $LX_BATCH   = 5000;
our @LX_DOMAINS = qw(procedure disease phenotype treatment measurement);
our $LX_LAT_IDS = q{('HP:0012834', 'HP:0012835', 'HP:0012832')};

our @LX_EVENT_COLS = qw(pseudonym packet_id packet_created letter_date candidate_id phenopacket_id
                        domain code label site_id date_raw excluded value unit comparator value_text
                        n_mentions last_letter_date);
our @LX_PATIENT_COLS = qw(pseudonym packet_id packet_created letter_date candidate_id phenopacket_id
                          doc_source sex age_last_iso tags);
our %LX_NUMERIC = map { $_ => 1 } qw(candidate_id value n_mentions);

# jsonb-Feld nur entpacken, wenn es wirklich ein Array ist (sonst SQL-Fehler)
sub _lx_arr { my ($e) = @_; return "CASE WHEN jsonb_typeof($e) = 'array' THEN $e ELSE '[]'::jsonb END" }
sub _lx_flag { my ($e) = @_; return "(lower(COALESCE($e, '')) IN ('true', 't', '1', 'yes'))" }
sub _lx_lat {
    my ($e) = @_;
    return "(SELECT mm->>'id' FROM jsonb_array_elements(" . _lx_arr($e) . ") mm "
         . "WHERE jsonb_typeof(mm) = 'object' AND mm->>'id' IN $LX_LAT_IDS LIMIT 1)";
}

# SELECT-Zweig je Domäne. $b = Alias der Briefzeile mit Spalte pp.
sub _lx_branch {
    my ($dom, $b, $codes_only) = @_;
    my $head = $codes_only
        ? "SELECT $b.pseudonym,"
        : "SELECT $b.pseudonym, $b.candidate_id, $b.packet_id, $b.packet_created, $b.packet_date, $b.phenopacket_id, '$dom'::text AS domain,";
    my $tail_null = "NULL::numeric AS value, NULL::text AS unit, NULL::text AS comparator, NULL::text AS value_text";

    if ($dom eq 'procedure') {
        return "$head p->'code'->>'id' AS code, " . ($codes_only ? _lx_flag("p->>'excluded'") . " AS excluded" :
               "p->'code'->>'label' AS label, p->'bodySite'->>'id' AS site_id, "
             . "COALESCE(p->>'performedTime', p->'performed'->>'timestamp') AS date_raw, "
             . _lx_flag("p->>'excluded'") . " AS excluded, $tail_null")
             . " FROM jsonb_array_elements(" . _lx_arr("$b.pp->'procedures'") . ") p WHERE jsonb_typeof(p) = 'object'";
    }
    if ($dom eq 'disease') {
        return "$head d->'term'->>'id' AS code, " . ($codes_only ? _lx_flag("d->>'excluded'") . " AS excluded" :
               "d->'term'->>'label' AS label, d->'primarySite'->>'id' AS site_id, "
             . "d->'onset'->>'timestamp' AS date_raw, "
             . _lx_flag("d->>'excluded'") . " AS excluded, $tail_null")
             . " FROM jsonb_array_elements(" . _lx_arr("$b.pp->'diseases'") . ") d WHERE jsonb_typeof(d) = 'object'";
    }
    if ($dom eq 'phenotype') {
        return "$head f->'type'->>'id' AS code, " . ($codes_only ? _lx_flag("f->>'excluded'") . " AS excluded" :
               "f->'type'->>'label' AS label, " . _lx_lat("f->'modifiers'") . " AS site_id, "
             . "f->'onset'->>'timestamp' AS date_raw, "
             . _lx_flag("f->>'excluded'") . " AS excluded, $tail_null")
             . " FROM jsonb_array_elements(" . _lx_arr("$b.pp->'phenotypicFeatures'") . ") f WHERE jsonb_typeof(f) = 'object'";
    }
    if ($dom eq 'treatment') {
        # medicalActions[].procedure dupliziert procedures[] und wird nicht gelesen
        return "$head a->'treatment'->'agent'->>'id' AS code, " . ($codes_only ? _lx_flag("a->'treatment'->>'excluded'") . " AS excluded" :
               "a->'treatment'->'agent'->>'label' AS label, a->'treatment'->'bodySite'->>'id' AS site_id, "
             . "COALESCE(a->'treatment'->>'performedTime', a->'treatment'->'performed'->>'timestamp') AS date_raw, "
             . _lx_flag("a->'treatment'->>'excluded'") . " AS excluded, $tail_null")
             . " FROM jsonb_array_elements(" . _lx_arr("$b.pp->'medicalActions'") . ") a "
             . "WHERE jsonb_typeof(a) = 'object' AND jsonb_typeof(a->'treatment') = 'object'";
    }
    if ($dom eq 'measurement') {
        my $q = "m->'value'->'quantity'";
        return "$head m->'assay'->>'id' AS code, " . ($codes_only ? _lx_flag("m->>'excluded'") . " AS excluded" :
               "m->'assay'->>'label' AS label, " . _lx_lat("m->'modifiers'") . " AS site_id, "
             . "m->'timeOfCollection'->>'timestamp' AS date_raw, "
             . _lx_flag("m->>'excluded'") . " AS excluded, "
             . "CASE WHEN ($q->>'value') ~ '^\\s*-?[0-9]+(\\.[0-9]+)?([eE][-+]?[0-9]+)?\\s*\$' "
             . "THEN ($q->>'value')::numeric END AS value, "
             . "COALESCE($q->'unit'->>'label', CASE WHEN jsonb_typeof($q->'unit') = 'string' THEN $q->>'unit' END) AS unit, "
             . "$q->>'comparator' AS comparator, "
             . "m->'value'->'ontologyClass'->>'label' AS value_text")
             . " FROM jsonb_array_elements(" . _lx_arr("$b.pp->'measurements'") . ") m WHERE jsonb_typeof(m) = 'object'";
    }
    die "unbekannte Domäne $dom\n";
}

sub _lx_list {
    my @out;
    for my $v (@_) {
        next unless defined $v;
        for my $x (ref $v eq 'ARRAY' ? @$v : ($v)) {
            next unless defined $x;
            push @out, grep { length } map { s/^\s+|\s+$//gr } split /[,;\n]/, $x;
        }
    }
    my %seen;
    return grep { !$seen{$_}++ } @out;
}

sub _lx_csv_field {
    my ($v) = @_;
    return '' unless defined $v;
    $v = "$v";
    return $v unless $v =~ /[",\r\n]/ || $v =~ /^\s|\s$/;
    $v =~ s/"/""/g;
    return qq{"$v"};
}

# Ereignisdatum wie im R-Skript (pp_date): JJJJ-MM -> 15., JJJJ -> 1. Juli
sub _lx_event_day {
    my ($s) = @_;
    return undef unless defined $s;
    return "$1-$2-$3" if $s =~ /^\s*(\d{4})-(\d{2})-(\d{2})/;
    return "$1-$2-15" if $s =~ /^\s*(\d{4})-(\d{2})\s*$/;
    return "$1-07-01" if $s =~ /^\s*(\d{4})\s*$/;
    return undef;
}

# Parameter prüfen und SQL bauen. Rückgabe: { sql, bind, cols, filter, label } oder { error, status }
helper long_export_query => sub {
    my ($c, $what) = @_;
    my %err;
    my $bad = sub { $err{error} = shift; $err{status} = 400; \%err };

    my @tags   = map { lc } _lx_list($c->every_param('tag'), $c->every_param('tags'));
    my %htseen;
    my @htags  = grep { !$htseen{$_}++ } map { lc } _lx_list($c->every_param('has_tag'), $c->every_param('has_tags'));
    my $hmatch = lc($c->param('has_tag_match') // 'any');
    my $tscope = lc($c->param('tag_scope') // 'patient');
    my @codes  = _lx_list($c->every_param('has_code'));
    my @pseud  = _lx_list($c->every_param('pseudonyms'), $c->every_param('pseudonym'));
    my @srcs   = map { lc } _lx_list($c->every_param('sources'), $c->every_param('source'));
    my @doms   = map { lc } _lx_list($c->every_param('domains'), $c->every_param('domain'));
    my $dedup  = lc($c->param('dedup')   // 'exact');
    my $undat  = lc($c->param('undated') // 'per_packet');
    my $incl_x = to_bool($c->param('include_excluded') // 1);
    my $limit  = $c->param('limit_patients');

    return $bad->("tag_scope muss 'patient' oder 'letter' sein.")            unless $tscope =~ /^(?:patient|letter)$/;
    return $bad->("has_tag_match muss 'any' oder 'all' sein.")               unless $hmatch =~ /^(?:any|all)$/;
    return $bad->("dedup muss 'exact', 'code' oder 'none' sein.")            unless $dedup  =~ /^(?:exact|code|none)$/;
    return $bad->("undated muss 'per_packet' oder 'first' sein.")            unless $undat  =~ /^(?:per_packet|first)$/;
    return $bad->("Ungültiger Code in has_code: '$_' (Format PREFIX:CODE).") for grep { !/^[A-Za-z0-9]+:[A-Za-z0-9.\-]+$/ } @codes;
    return $bad->("Ungültige Quelle: '$_'.")                                  for grep { !/^[a-z0-9_]{1,20}$/ } @srcs;
    my %dom_ok = map { $_ => 1 } @LX_DOMAINS;
    return $bad->("Ungültige Domäne: '$_' (erlaubt: @LX_DOMAINS).")           for grep { !$dom_ok{$_} } @doms;
    @doms = @LX_DOMAINS unless @doms;
    return $bad->("limit_patients muss eine positive Zahl sein.")            if defined $limit && $limit !~ /^[1-9]\d{0,6}$/;
    return $bad->("Zu viele Werte (tag/has_tag/has_code max. 50, pseudonyms max. 100000).")
        if @tags > 50 || @htags > 50 || @codes > 50 || @pseud > 100000;

    my %day;
    for my $k (qw(from to event_from event_to)) {
        my $v = $c->param($k);
        next unless defined $v && length $v;
        $day{$k} = normalize_reference_day($v) // return $bad->("$k: ungültiges Datum '$v' (JJJJ-MM-TT oder TT.MM.JJJJ).");
    }

    unless (@tags || @htags || @codes || @pseud || to_bool($c->param('all'))) {
        return $bad->("Kein Kohortenfilter gesetzt. tag, has_tag, has_code oder pseudonyms angeben, oder all=1 für den Gesamtbestand.");
    }

    my @bind;

    # --- 1. Briefe (mit Briefebene-Deduplizierung) ---
    my @lw = ("c.phenopacket_json IS NOT NULL", "c.pseudonym IS NOT NULL",
              "jsonb_typeof(c.phenopacket_json) = 'object'");
    if ($day{from}) { push @lw, "c.reference_date::date >= ?::date"; push @bind, $day{from} }
    if ($day{to})   { push @lw, "c.reference_date::date <= ?::date"; push @bind, $day{to} }
    if (@srcs)      { push @lw, "lower(c.doc_source) = ANY(?)";      push @bind, [@srcs] }
    if (@pseud)     { push @lw, "c.pseudonym = ANY(?)";              push @bind, [@pseud] }
    if (@htags) {
        # Grundgesamtheit: Tag an irgendeinem Brief des Patienten, unabhängig von Datum und Quelle.
        # Steht vor Briefdeduplizierung, has_code und limit_patients, damit diese nur noch
        # die Briefe der Grundgesamtheit sehen.
        my $pop = "c.pseudonym IN (
        SELECT ht.pseudonym
          FROM candidates ht
         CROSS JOIN LATERAL unnest(string_to_array(COALESCE(ht.tags, ''), ',')) tt(t)
         WHERE ht.pseudonym IS NOT NULL
           AND lower(trim(tt.t)) = ANY(?)
         GROUP BY ht.pseudonym";
        push @bind, [@htags];
        if ($hmatch eq 'all' && @htags > 1) {
            $pop .= "\n        HAVING count(DISTINCT lower(trim(tt.t))) = ?";
            push @bind, scalar(@htags);
        }
        push @lw, "$pop)";
    }
    my $tag_match = "EXISTS (SELECT 1 FROM unnest(string_to_array(COALESCE(%s.tags, ''), ',')) tt(t) WHERE lower(trim(tt.t)) = ANY(?))";
    if (@tags && $tscope eq 'letter') { push @lw, sprintf($tag_match, 'c'); push @bind, [@tags] }

    my $sql = "WITH letters_all AS (
  SELECT c.id AS candidate_id, c.pseudonym, c.reference_date::date AS packet_date,
         c.doc_source, c.tags, c.phenopacket_json AS pp,
         'cand-' || c.id AS packet_id,
         c.phenopacket_json->>'id' AS phenopacket_id,
         c.phenopacket_json->'metaData'->>'created' AS packet_created,
         COALESCE(c.doc_hash, md5(c.narrative_report), 'id-' || c.id) AS text_key
    FROM candidates c
   WHERE " . join("\n     AND ", @lw) . "
),
letters AS (
  SELECT DISTINCT ON (pseudonym, text_key) *
    FROM letters_all
   ORDER BY pseudonym, text_key, (lower(COALESCE(doc_source, '')) = 'argos') DESC, candidate_id DESC
),";

    # --- 2. Kohorte (Patientenebene) ---
    my @cw;
    if (@tags && $tscope eq 'patient') {
        push @cw, "l.pseudonym IN (SELECT c.pseudonym FROM candidates c WHERE " . sprintf($tag_match, 'c') . ")";
        push @bind, [@tags];
    }
    if (@codes) {
        my $code_union = join("\n        UNION ALL ", map { _lx_branch($_, 'h', 1) } @LX_DOMAINS);
        push @cw, "l.pseudonym IN (
      SELECT x.pseudonym
        FROM letters h,
             LATERAL ($code_union) x
       WHERE x.code IS NOT NULL AND NOT x.excluded
         AND EXISTS (SELECT 1 FROM unnest(?::text[]) q(code) WHERE is_subclass_of(x.code, q.code)))";
        push @bind, [@codes];
    }
    $sql .= "
cohort AS (
  SELECT DISTINCT l.pseudonym
    FROM letters l
   WHERE " . (@cw ? join("\n     AND ", @cw) : 'TRUE') . "
   ORDER BY l.pseudonym" . (defined $limit ? "\n   LIMIT ?" : '') . "
),
base AS (
  SELECT l.* FROM letters l JOIN cohort USING (pseudonym)
)";
    push @bind, $limit + 0 if defined $limit;

    # --- 3a. Patienten / Briefe ---
    if ($what eq 'patients') {
        $sql .= "
SELECT b.pseudonym, b.packet_id, b.packet_created, to_char(b.packet_date, 'YYYY-MM-DD') AS letter_date,
       b.candidate_id, b.phenopacket_id, b.doc_source,
       b.pp->'subject'->>'sex' AS sex,
       b.pp->'subject'->'timeAtLastEncounter'->'age'->>'iso8601duration' AS age_last_iso,
       b.tags
  FROM base b
 ORDER BY b.pseudonym, b.packet_date NULLS LAST, b.candidate_id";
        return { sql => $sql, bind => \@bind, cols => \@LX_PATIENT_COLS, label => 'patients' };
    }

    # --- 3b. Ereignisse (mit Elementebene-Deduplizierung) ---
    my $branches = join("\n  UNION ALL\n  ", map { "SELECT b.packet_id AS _p, x.* FROM base b, LATERAL (" . _lx_branch($_, 'b', 0) . ") x" } @doms);
    my $undated_key = $undat eq 'per_packet' ? "'undated:' || candidate_id" : "'undated'";
    my @key = qw(pseudonym domain code);
    push @key, 'label' if $dedup eq 'exact';
    push @key, qw(site_id date_key excluded value unit comparator value_text);
    my $keys = join(', ', map { "k.$_" } @key);

    $sql .= ",
ev AS (
  SELECT u.* FROM (
  $branches
  ) u
  WHERE u.code IS NOT NULL" . ($incl_x ? '' : ' AND NOT u.excluded') . "
),
keyed AS (
  SELECT ev.*,
         CASE WHEN date_raw ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN substr(date_raw, 1, 10)
              WHEN date_raw ~ '^[0-9]{4}(-[0-9]{2})?\$'      THEN date_raw
              ELSE $undated_key END AS date_key
    FROM ev
),
ranked AS (
  SELECT k.*,
         count(*)           OVER w AS n_mentions,
         max(k.packet_date) OVER w AS last_packet_date_d,
         row_number()       OVER (w ORDER BY k.packet_date NULLS LAST, k.candidate_id) AS rn
    FROM keyed k
  WINDOW w AS (PARTITION BY $keys)
)
SELECT pseudonym, packet_id, packet_created, to_char(packet_date, 'YYYY-MM-DD') AS letter_date,
       candidate_id, phenopacket_id, domain, code, label, site_id, date_raw, excluded,
       value, unit, comparator, value_text, n_mentions,
       to_char(last_packet_date_d, 'YYYY-MM-DD') AS last_letter_date
  FROM ranked
" . ($dedup eq 'none' ? '' : " WHERE rn = 1\n") . " ORDER BY pseudonym, packet_date NULLS LAST, candidate_id, domain, code";

    # Ereignisdatum-Filter (im Stream, damit ungültige Datumsstrings die Abfrage nicht abbrechen)
    my $filter;
    if ($day{event_from} || $day{event_to}) {
        my $keep_undated = to_bool($c->param('keep_undated') // 1);
        my ($ef, $et) = ($day{event_from}, $day{event_to});
        $filter = sub {
            my $d = _lx_event_day($_[0]{date_raw});
            return $keep_undated unless defined $d;
            return 0 if $ef && $d lt $ef;
            return 0 if $et && $d gt $et;
            return 1;
        };
    }
    return { sql => $sql, bind => \@bind, cols => \@LX_EVENT_COLS, filter => $filter, label => 'events' };
};

# Ergebnis per Server-Cursor in Blöcken streamen (nicht blockierend, wenig Speicher)
helper long_export_stream => sub {
    my ($c, $q, $format) = @_;
    my $db = $c->pg->db;
    my $tx = $db->begin;

    # Eigener Cursorname je Exporttyp: Mojo::Pg cacht das FETCH-Statement pro
    # Verbindung, und ein gecachtes FETCH auf einen Cursor mit anderer
    # Spaltenstruktur bringt DBD::Pg zum Absturz (Segfault).
    my $cursor = "ontotrial_lx_$q->{label}";
    eval { $db->query("DECLARE $cursor NO SCROLL CURSOR FOR $q->{sql}", @{ $q->{bind} }); 1 } or do {
        my $err = $@;
        undef $tx;
        $c->app->log->error("[LONG EXPORT] Abfrage ungültig: $err");
        return $c->render(json => { error => 'Abfrage fehlgeschlagen', details => "$err" }, status => 500);
    };

    my @cols = @{ $q->{cols} };
    my $stamp = POSIX::strftime('%Y%m%d-%H%M%S', localtime);
    my $render_row = $format eq 'ndjson'
        ? sub {
              my $r = shift;
              my %o = map { $_ => $r->{$_} } @cols;
              $o{excluded} = $r->{excluded} ? Mojo::JSON->true : Mojo::JSON->false if exists $o{excluded};
              defined $o{$_} and $o{$_} += 0 for grep { exists $o{$_} } keys %LX_NUMERIC;
              return to_json(\%o) . "\n";
          }
        : sub {
              my $r = shift;
              local $r->{excluded} = exists $r->{excluded} ? ($r->{excluded} ? 'true' : 'false') : undef;
              return join(',', map { _lx_csv_field($r->{$_}) } @cols) . "\n";
          };

    my $h = $c->res->headers;
    if ($format eq 'ndjson') {
        $h->content_type('application/x-ndjson; charset=UTF-8');
    } else {
        $h->content_type('text/csv; charset=UTF-8');
        $h->content_disposition(qq{attachment; filename="ontotrial-$q->{label}-$stamp.csv"});
    }

    my ($started, $done, $n_rows, $next) = (0, 0, 0);
    my $t0 = [gettimeofday()];
    my $header = $format eq 'ndjson' ? '' : join(',', @cols) . "\n";

    $c->render_later;
    $c->on(finish => sub { $done = 1; undef $next });   # auch bei Verbindungsabbruch

    $next = sub {
        return if $done;
        $db->query_p("FETCH $LX_BATCH FROM $cursor")->then(sub {
            my $batch = shift->hashes->to_array;
            return if $done;

            if (!@$batch) {
                eval { $tx->commit; 1 } or $c->app->log->warn("[LONG EXPORT] Commit: $@");
                $c->app->log->info(sprintf('[LONG EXPORT] %s: %d Zeilen in %.1f s', $q->{label}, $n_rows, tv_interval($t0)));
                my $tail = $started ? '' : $header;
                $done = 1;
                undef $next;
                if (length $tail) { $c->write_chunk(encode('UTF-8', $tail) => sub { shift->finish }) }
                elsif ($started)  { $c->finish }
                else              { $c->rendered(200) }
                return;
            }

            my $buf = $started ? '' : $header;
            for my $r (@$batch) {
                next if $q->{filter} && !$q->{filter}->($r);
                $buf .= $render_row->($r);
                $n_rows++;
            }
            if (length $buf) {
                $started = 1;
                $c->write_chunk(encode('UTF-8', $buf) => sub { $next->() if $next });
            } else {
                Mojo::IOLoop->next_tick(sub { $next->() if $next });   # leeren Chunk vermeiden (= Stream-Ende)
            }
        })->catch(sub {
            my $err = shift;
            $c->app->log->error("[LONG EXPORT] Fehler nach $n_rows Zeilen: $err");
            $done = 1;
            undef $next;
            undef $tx;   # Rollback
            if ($started) { $c->finish }   # Ausgabe unvollständig; HTTP-Status ist schon gesendet
            else { $c->render(json => { error => 'Export fehlgeschlagen', details => "$err" }, status => 500) }
        });
    };
    $next->();
};

get '/BBB/export/long/:what' => [what => [qw(events patients)]] => sub {
    my $c = shift;
    $c->inactivity_timeout(3600);

    if (my $tok = $ENV{ONTOTRIAL_EXPORT_TOKEN}) {
        my $given = $c->req->headers->header('X-Export-Token') // $c->param('token') // '';
        return $c->render(json => { error => 'Export-Token fehlt oder ist falsch.' }, status => 403)
            unless $given eq $tok;
    }

    my $format = lc($c->param('format') // 'csv');
    return $c->render(json => { error => "format muss 'csv' oder 'ndjson' sein." }, status => 400)
        unless $format =~ /^(?:csv|ndjson)$/;

    my $q = $c->long_export_query($c->param('what'));
    return $c->render(json => { error => $q->{error} }, status => $q->{status}) if $q->{error};

    $c->app->log->info("[LONG EXPORT] $q->{label}: " . $c->req->url->query->to_string =~ s/token=[^&]*/token=***/r);
    $c->long_export_stream($q, $format);
};

# =========================================================
# VALIDIERUNG: Referenzdatensatz, Regressionstest, Validierungsstudie
# =========================================================
# Ein Validierungsdatensatz ist eine repräsentative Stichprobe von Briefen
# aus dem Bestand. Brieftext und Phenopacket werden bei der Ziehung als
# Kopie gespeichert, damit der Datensatz unabhängig von späteren
# Neu-Extraktionen oder Löschungen im Bestand bleibt.
#
#   Prüfen        Ärzte bewerten jeden extrahierten Eintrag (korrekt/Fehlertyp)
#                 und ergänzen fehlende Einträge. Bei Studien-Datensätzen
#                 zuerst blind eine Checkliste (Teil A), dann die Extraktion.
#   Referenz      Aus den Bewertungen (bzw. dem Konsens) wird die Referenz
#                 gebildet und eingefroren.
#   Regression    Die Briefe des Datensatzes laufen erneut durch die Pipeline
#                 (oder es werden die gespeicherten Phenopackets genommen) und
#                 werden mit der Referenz verglichen, inkl. Vergleich mit
#                 einem Basis-Lauf.
#   Studie        Kennzahlen nach Bewertungshandbuch (Precision, Attribut-
#                 genauigkeit, Recall über Checkliste, Kappa, Wachsamkeit
#                 über eingestreute Fehler), Rohdaten als CSV.
#
# Schema: migrations/ontotrial.sql, Version 2.
#
# Schutz: Datensätze sind standardmäßig gesperrt. Gesperrte Datensätze
# lassen sich nicht löschen, eingefrorene Bewertungen nicht ändern. Das
# erzwingen Trigger in der Datenbank, also auch gegen die generischen
# Tabellen-Routen; diese sind für validation_* zusätzlich gesperrt.
#
# Routen müssen VOR den generischen CRUD-Routen stehen.
# =========================================================

our $VAL_CONSENSUS = 'Konsens';
our @VAL_DOMAINS   = qw(disease phenotype procedure treatment measurement);

# Das Schema der Validierung ist Version 2 der Migration in migrations/ontotrial.sql.

# Generische Tabellen-Routen dürfen die Validierungstabellen nicht anfassen
hook before_dispatch => sub {
    my $c = shift;
    if ($c->req->url->path->to_string =~ m{^/BBB/validation_}i) {
        $c->render(json => { error => 'Validierungstabellen sind nur über /BBB/validation/... erreichbar.' }, status => 403);
    }
};

# ---------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------

# deterministische Zufallszahl in [0,1) aus Seed und Kennung
sub _val_rand {
    my ($seed, $tag) = @_;
    return hex(substr(md5_hex("$seed:$tag"), 0, 8)) / 4294967296;
}

sub _val_date {
    my $t = shift // '';
    return $t =~ /^(\d{4}(?:-\d{2}(?:-\d{2})?)?)/ ? $1 : '';
}

sub _val_code {
    my $c = uc(shift // '');
    $c =~ s/\s+//g;
    return $c;
}

sub _val_num {
    my $v = shift;
    return (defined $v && $v =~ /^\s*-?\d+(?:[.,]\d+)?\s*$/) ? ($v =~ tr/,/./r) + 0 : undef;
}

# Phenopacket -> flache Liste von Einträgen mit stabilem Schlüssel
sub _val_entries {
    my ($pp) = @_;
    my @e;
    return \@e unless ref $pp eq 'HASH';
    my $push = sub {
        my %x = @_;
        return unless defined $x{code} && length $x{code};
        $x{label}    //= '';
        $x{side}     //= '';
        $x{date}     //= '';
        $x{excluded} = $x{excluded} ? 1 : 0;
        push @e, \%x;
    };
    for my $d (@{ ref $pp->{diseases} eq 'ARRAY' ? $pp->{diseases} : [] }) {
        next unless ref $d eq 'HASH' && ref $d->{term} eq 'HASH';
        $push->(domain => 'disease', code => $d->{term}{id}, label => $d->{term}{label},
                side => _ppd_side($d->{primarySite}), excluded => to_bool($d->{excluded}),
                date => _val_date(ref $d->{onset} eq 'HASH' ? $d->{onset}{timestamp} : undef));
    }
    for my $p (@{ ref $pp->{phenotypicFeatures} eq 'ARRAY' ? $pp->{phenotypicFeatures} : [] }) {
        next unless ref $p eq 'HASH' && ref $p->{type} eq 'HASH';
        $push->(domain => 'phenotype', code => $p->{type}{id}, label => $p->{type}{label},
                side => _ppd_side_of_mods($p->{modifiers}), excluded => to_bool($p->{excluded}),
                date => _val_date(ref $p->{onset} eq 'HASH' ? $p->{onset}{timestamp} : undef));
    }
    for my $p (@{ ref $pp->{procedures} eq 'ARRAY' ? $pp->{procedures} : [] }) {
        next unless ref $p eq 'HASH' && ref $p->{code} eq 'HASH';
        $push->(domain => 'procedure', code => $p->{code}{id}, label => $p->{code}{label},
                side => _ppd_side($p->{bodySite}), excluded => to_bool($p->{excluded}),
                date => _val_date($p->{performedTime} // (ref $p->{performed} eq 'HASH' ? $p->{performed}{timestamp} : undef)));
    }
    for my $act (@{ ref $pp->{medicalActions} eq 'ARRAY' ? $pp->{medicalActions} : [] }) {
        next unless ref $act eq 'HASH' && ref $act->{treatment} eq 'HASH';
        my $tr = $act->{treatment};
        next unless ref $tr->{agent} eq 'HASH';
        $push->(domain => 'treatment', code => $tr->{agent}{id}, label => $tr->{agent}{label},
                side => _ppd_side($tr->{bodySite}), excluded => to_bool($tr->{excluded}),
                date => _val_date($tr->{performedTime} // (ref $tr->{performed} eq 'HASH' ? $tr->{performed}{timestamp} : undef)));
    }
    for my $m (@{ ref $pp->{measurements} eq 'ARRAY' ? $pp->{measurements} : [] }) {
        next unless ref $m eq 'HASH' && ref $m->{assay} eq 'HASH';
        my $v  = ref $m->{value} eq 'HASH' ? $m->{value} : {};
        my $q  = ref $v->{quantity} eq 'HASH' ? $v->{quantity} : {};
        my $u  = ref $q->{unit} eq 'HASH' ? ($q->{unit}{label} // $q->{unit}{id}) : $q->{unit};
        my $oc = ref $v->{ontologyClass} eq 'HASH' ? $v->{ontologyClass}{label} : undef;
        $push->(domain => 'measurement', code => $m->{assay}{id}, label => $m->{assay}{label},
                side => _ppd_side_of_mods($m->{modifiers}), excluded => to_bool($m->{excluded}),
                date => _val_date(ref $m->{timeOfCollection} eq 'HASH' ? $m->{timeOfCollection}{timestamp} : undef),
                value => $q->{value}, unit => $u // '', comparator => $q->{comparator} // '',
                value_text => $oc // '');
    }
    my %seen;
    for my $x (@e) {
        my $base = join('|', $x->{domain}, _val_code($x->{code}), $x->{side}, $x->{date}, $x->{excluded},
                        $x->{value} // $x->{value_text} // '');
        my $n = ++$seen{$base};
        $x->{key} = md5_hex(encode('UTF-8', $base)) . ($n > 1 ? "-$n" : '');
    }
    my %ord = (disease => 1, phenotype => 2, procedure => 3, treatment => 4, measurement => 5);
    return [ sort { $ord{$a->{domain}} <=> $ord{$b->{domain}} || lc($a->{label}) cmp lc($b->{label}) } @e ];
}

# Hierarchische Verwandtschaft zweier Codes derselben Domäne (für tolerante Wertung)
sub _val_related {
    my ($c, $domain, $x, $y) = @_;
    ($x, $y) = (_val_code($x), _val_code($y));
    return 0 unless length $x && length $y;
    if ($x =~ /^HP:/ && $y =~ /^HP:/) {
        return ($c->is_subclass_of($x, $y) || $c->is_subclass_of($y, $x)) ? 1 : 0;
    }
    return 0 if $domain eq 'measurement';
    s/^[A-Z0-9]+://, s/[.\-]//g for $x, $y;
    return 0 unless length($x) >= 3 && length($y) >= 3;
    return (index($x, $y) == 0 || index($y, $x) == 0) ? 1 : 0;
}

# ---------------------------------------------------------
# Bewertungen eines Briefs auflösen (Einzelprüfer, Übereinstimmung, Konsens)
# ---------------------------------------------------------
sub _val_core {
    my $j = shift // {};
    return join('/', map { $j->{$_} // '' } qw(verdict concept status side side_correct date date_correct value value_correct));
}

sub _val_missing_sig {
    my $m = shift;
    return join('|', _val_code($m->{code}), $m->{side} // '', _val_date($m->{date}), $m->{excluded} ? 1 : 0);
}

# Liefert { status => ok|incomplete|conflict, source => reviewer|agreement|Konsens,
#           judgments => {key => j}, missing => [...], checklist => {...}, conflicts => [...] }
sub _val_resolve {
    my ($item, $rows) = @_;
    my %by;
    for my $r (@$rows) {
        my $j = ref $r->{judgment} ? $r->{judgment} : (eval { decode_json(encode('UTF-8', $r->{judgment})) } // {});
        $by{ $r->{reviewer} }{ $r->{entry_key} } = $j;
    }
    my $pack = sub {
        my ($name, $src) = @_;
        my $h = $by{$name};
        my %j = map { $_ => $h->{$_} } grep { !/^(?:_|missing:)/ } keys %$h;
        my @m = map { $h->{$_} } grep { /^missing:/ && !$h->{$_}{deleted} } sort keys %$h;
        return { status => 'ok', source => $src, reviewer => $name, judgments => \%j, missing => \@m,
                 checklist => $h->{_checklist} };
    };
    my $is_done = sub { my $h = $by{ $_[0] }; return $h && ref $h->{_done} eq 'HASH' && $h->{_done}{done} ? 1 : 0 };
    return $pack->($VAL_CONSENSUS, $VAL_CONSENSUS) if $is_done->($VAL_CONSENSUS);

    my @done = sort grep { $_ ne $VAL_CONSENSUS && $is_done->($_) } keys %by;
    return { status => 'incomplete', done => \@done } if !@done || ($item->{double_review} && @done < 2);
    return $pack->($done[0], 'reviewer') if @done == 1;

    # mehrere Prüfer: Übereinstimmung prüfen
    my ($a, $b) = @by{ @done[0, 1] };
    my @conf;
    for my $e (@{ $item->{entries} }) {
        push @conf, $e->{key} if _val_core($a->{ $e->{key} }) ne _val_core($b->{ $e->{key} });
    }
    my $ms = sub { my $h = shift; join(';', sort map { _val_missing_sig($h->{$_}) } grep { /^missing:/ && !$h->{$_}{deleted} } keys %$h) };
    push @conf, 'missing' if $ms->($a) ne $ms->($b);
    return { status => 'conflict', conflicts => \@conf, reviewers => [ @done[0, 1] ] } if @conf;
    my $res = $pack->($done[0], 'agreement');
    $res->{reviewers} = [ @done ];
    return $res;
}

# Referenz eines Briefs aus der aufgelösten Bewertung
sub _val_build_reference {
    my ($item, $res) = @_;
    my (@ref, @tol);
    my %inj = map { $_->{key} => $_ } @{ $item->{injected} // [] };
    my %dropped_sig;

    for my $e (@{ $item->{entries} }) {
        if (my $i = $inj{ $e->{key} }) {               # eingestreuter Fehler: Wahrheit ist das Original
            push @ref, { %{ $i->{original} }, src => 'snapshot' };
            next;
        }
        my $j = $res->{judgments}{ $e->{key} } // {};
        my $v = $j->{verdict} // '';
        if ($v eq 'duplicate' || $v eq 'unclear') { push @tol, { %$e, why => $v }; next; }
        my $concept = $j->{concept} // 'ok';
        next if $concept =~ /^(?:wrong|absent|wrong_subject)$/;
        if ($concept =~ /^(?:broader|narrower)$/) { push @tol, { %$e, why => $concept }; next; }
        my $status = $j->{status} // 'ok';
        next if $status eq 'suspected' || $status eq 'planned';

        my %r = (%$e, src => 'snapshot');
        $r{excluded} = $r{excluded} ? 0 : 1 if $status eq 'negation';
        for my $attr (qw(side date value)) {
            my $s = $j->{$attr} // 'ok';
            next if $s eq 'ok' || $s eq 'na';
            my $corr = $j->{"${attr}_correct"};
            if ($s eq 'superfluous') { $r{$attr} = ''; $r{"${attr}_absent"} = 1; }
            elsif (defined $corr && length $corr) { $r{$attr} = $attr eq 'date' ? _val_date($corr) : $corr; }
            else { $r{$attr} = '?'; }
        }
        push @ref, \%r;
    }
    for my $i (values %inj) {
        next unless $i->{type} eq 'drop';
        push @ref, { %{ $i->{original} }, src => 'snapshot' };
        $dropped_sig{ _val_code($i->{original}{code}) } = 1;
    }
    for my $m (@{ $res->{missing} // [] }) {
        next unless defined $m->{code} && length $m->{code};
        next if delete $dropped_sig{ _val_code($m->{code}) };
        push @ref, { domain => $m->{domain}, code => $m->{code}, label => $m->{label} // '',
                     side => $m->{side} // '', date => _val_date($m->{date}), excluded => $m->{excluded} ? 1 : 0,
                     value => $m->{value}, unit => $m->{unit} // '', key => 'missing:' . md5_hex(encode('UTF-8', _val_missing_sig($m))),
                     src => 'missing' };
    }
    return { entries => \@ref, tolerated => \@tol, source => $res->{source},
             reviewers => $res->{reviewers} // [ $res->{reviewer} // () ] };
}

# ---------------------------------------------------------
# Vergleich einer Extraktion mit der Referenz
# ---------------------------------------------------------
sub _val_attr_check {
    my ($r, $p, $attr) = @_;
    my $rv = $r->{$attr};
    if ($attr eq 'value') {
        return undef if $r->{domain} ne 'measurement';
        return undef if defined $rv && $rv eq '?';
        my ($a, $b) = (_val_num($rv), _val_num($p->{value}));
        if (defined $a) {
            return 0 unless defined $b;
            return abs($a - $b) <= 1e-6 * (abs($a) > 1 ? abs($a) : 1) ? 1 : 0;
        }
        my $rt = lc($r->{value_text} // '');
        return undef unless length $rt;
        return lc($p->{value_text} // '') eq $rt ? 1 : 0;
    }
    $rv //= '';
    return undef if $rv eq '?';
    my $pv = $p->{$attr} // '';
    if ($attr eq 'date') {
        return ($pv eq '' ? 1 : 0) if $r->{date_absent};
        return undef if $rv eq '';
        return 0 if $pv eq '';
        return (index($pv, $rv) == 0 || index($rv, $pv) == 0) ? 1 : 0;
    }
    return $pv eq $rv ? 1 : 0;   # side
}

sub _val_compare {
    my ($c, $ref, $pred) = @_;
    my %dom = map { $_ => { tp => 0, fp => 0, fn => 0, partial => 0, tolerated => 0,
                            map { ("${_}_ok" => 0, "${_}_n" => 0) } qw(side date status value) } } @VAL_DOMAINS;
    my (@fn, @fp, @partial, @attr_err, @tp_keys);
    my @p = map { { %$_, _used => 0 } } @$pred;

    my $pairscore = sub {
        my ($r, $q) = @_;
        my $s = 0;
        $s += 4 if ($r->{excluded} // 0) == ($q->{excluded} // 0);
        $s += 2 if ($r->{side} // '') eq ($q->{side} // '');
        $s += 1 if length($r->{date} // '') && ($q->{date} // '') eq $r->{date};
        $s += 1 if defined _val_num($r->{value}) && defined _val_num($q->{value}) && _val_num($r->{value}) == _val_num($q->{value});
        return $s;
    };

    my @unmatched;
    for my $r (@{ $ref->{entries} }) {
        my $code = _val_code($r->{code});
        my ($best, $bs) = (undef, -1);
        for my $q (@p) {
            next if $q->{_used} || $q->{domain} ne $r->{domain} || _val_code($q->{code}) ne $code;
            my $s = $pairscore->($r, $q);
            ($best, $bs) = ($q, $s) if $s > $bs;
        }
        unless ($best) { push @unmatched, $r; next; }
        $best->{_used} = 1;
        my $d = $dom{ $r->{domain} } //= {};
        $d->{tp}++;
        push @tp_keys, $r->{key};
        my %err;
        for my $attr (qw(side date value)) {
            my $ok = _val_attr_check($r, $best, $attr);
            next unless defined $ok;
            $d->{"${attr}_n"}++;
            $d->{"${attr}_ok"} += $ok;
            $err{$attr} = { ref => $r->{$attr} // '', pred => $best->{$attr} // '' } unless $ok;
        }
        $d->{status_n}++;
        if (($r->{excluded} // 0) == ($best->{excluded} // 0)) { $d->{status_ok}++ }
        else { $err{status} = { ref => $r->{excluded} ? 'verneint' : 'vorhanden', pred => $best->{excluded} ? 'verneint' : 'vorhanden' } }
        push @attr_err, { key => $r->{key}, domain => $r->{domain}, code => $r->{code}, label => $r->{label}, errors => \%err } if %err;
    }
    # zweite Runde: hierarchisch verwandte Codes (zählen nur tolerant als Treffer)
    for my $r (@unmatched) {
        my ($hit) = grep { !$_->{_used} && $_->{domain} eq $r->{domain} && _val_related($c, $r->{domain}, $r->{code}, $_->{code}) } @p;
        if ($hit) {
            $hit->{_used} = 1;
            $dom{ $r->{domain} }{partial}++;
            push @partial, { key => $r->{key}, domain => $r->{domain}, ref_code => $r->{code}, ref_label => $r->{label},
                             pred_code => $hit->{code}, pred_label => $hit->{label} };
        } else {
            $dom{ $r->{domain} }{fn}++;
            push @fn, { key => $r->{key}, map { $_ => $r->{$_} } qw(domain code label side date excluded value) };
        }
    }
    # tolerierte Referenzeinträge (Dublette, unklar, zu allgemein/spezifisch) neutralisieren
    for my $t (@{ $ref->{tolerated} // [] }) {
        my ($hit) = grep { !$_->{_used} && $_->{domain} eq $t->{domain} && _val_code($_->{code}) eq _val_code($t->{code}) } @p;
        next unless $hit;
        $hit->{_used} = 1;
        $dom{ $t->{domain} }{tolerated}++;
    }
    for my $q (grep { !$_->{_used} } @p) {
        $dom{ $q->{domain} }{fp}++;
        push @fp, { sig => join('|', $q->{domain}, _val_code($q->{code}), $q->{side}, $q->{date}, $q->{excluded}),
                    map { $_ => $q->{$_} } qw(domain code label side date excluded value) };
    }
    return { domains => \%dom, fn => \@fn, fp => \@fp, partial => \@partial, attr_errors => \@attr_err, tp_keys => \@tp_keys };
}

sub _val_ratio { my ($a, $b) = @_; return $b ? sprintf('%.4f', $a / $b) + 0 : undef }

sub _val_metrics {
    my ($results) = @_;
    my %sum;
    for my $res (@$results) {
        for my $d (keys %{ $res->{domains} }) {
            $sum{$d}{$_} += $res->{domains}{$d}{$_} // 0 for keys %{ $res->{domains}{$d} };
        }
    }
    my %out;
    my %all;
    for my $d (@VAL_DOMAINS, 'all') {
        my $s = $d eq 'all' ? \%all : ($sum{$d} // {});
        if ($d ne 'all') { $all{$_} += $s->{$_} // 0 for keys %$s }
        my ($tp, $fp, $fn, $pa) = map { $s->{$_} // 0 } qw(tp fp fn partial);
        my %m = (n_ref => $tp + $fn + $pa, n_pred => $tp + $fp + $pa, tp => $tp, fp => $fp, fn => $fn,
                 partial => $pa, tolerated => $s->{tolerated} // 0);
        $m{precision}     = _val_ratio($tp, $tp + $fp + $pa);
        $m{recall}        = _val_ratio($tp, $tp + $fn + $pa);
        $m{f1}            = _val_ratio(2 * $tp, 2 * $tp + $fp + $fn + 2 * $pa);
        $m{precision_tol} = _val_ratio($tp + $pa, $tp + $fp + $pa);
        $m{recall_tol}    = _val_ratio($tp + $pa, $tp + $fn + $pa);
        $m{f1_tol}        = _val_ratio(2 * ($tp + $pa), 2 * ($tp + $pa) + $fp + $fn);
        $m{"${_}_accuracy"} = _val_ratio($s->{"${_}_ok"} // 0, $s->{"${_}_n"} // 0) for qw(side date status value);
        $m{"${_}_n"} = $s->{"${_}_n"} // 0 for qw(side date status value);
        $out{$d} = \%m;
    }
    return \%out;
}

# ---------------------------------------------------------
# Datenbankzugriffe
# ---------------------------------------------------------
sub _val_json { my $v = shift; return ref $v ? $v : (defined $v ? (eval { decode_json(encode('UTF-8', $v)) } // eval { from_json($v) }) : undef) }

sub _val_load_set {
    my ($db, $id) = @_;
    return undef unless defined $id && $id =~ /^\d+$/;
    my $s = $db->query('SELECT * FROM validation_sets WHERE id = ?', $id)->hash or return undef;
    $s->{params} = _val_json($s->{params}) // {};
    return $s;
}

sub _val_load_items {
    my ($db, $set_id) = @_;
    return $db->query('SELECT * FROM validation_items WHERE set_id = ? ORDER BY position', $set_id)->expand->hashes->to_array;
}

sub _val_reviews_by_item {
    my ($db, $set_id) = @_;
    my %r;
    my $rows = $db->query(q{SELECT r.item_id, r.reviewer, r.entry_key, r.judgment::text AS judgment, r.updated_at
                            FROM validation_reviews r JOIN validation_items i ON i.id = r.item_id
                            WHERE i.set_id = ?}, $set_id)->hashes;
    push @{ $r{ $_->{item_id} } }, $_ for @$rows;
    return \%r;
}

sub _val_confirm_ok {
    my ($set, $given) = @_;
    return defined $given && $given eq $set->{name};
}

sub _val_fingerprint {
    my ($app) = @_;
    my $db = $app->pg->db;
    my %fp;
    my $file = $0 =~ m{^/} ? $0 : $app->home->rel_file($0) . '';
    if (open my $fh, '<:raw', $file) { local $/; $fp{backend_md5} = md5_hex(<$fh>); close $fh; }
    (my $dir = $file) =~ s{/[^/]*$}{};
    my $git = `git -C '$dir' rev-parse --short HEAD 2>/dev/null` // '';
    chomp $git;
    $fp{git} = $git if length $git;
    my $prov = lc($ENV{LLM_PROVIDER} // 'vllm');
    $fp{model} = $prov eq 'ollama' ? ($ENV{OLLAMA_MODEL} // '') : ($ENV{VLLM_MODEL} // '');
    for my $t (qw(llm_prompts ontology_intercepts filter_rules catalog_versions)) {
        my $h = eval { $db->query("SELECT md5(coalesce(string_agg(x::text, '|' ORDER BY x::text), '')) AS h FROM $t x")->hash->{h} };
        $fp{$t} = $h if $h;
    }
    $fp{env} = { map { $_ => $ENV{$_} } grep { /^ONTOTRIAL_(?:RERANK|OCULAR|ICD|LABEL|BLOCK|INTERCEPT|PARENT|GROUND|TRANSLATION)/ } sort keys %ENV };
    $fp{hash} = substr(md5_hex(encode('UTF-8', join('|', map { "$_=" . (ref $fp{$_} ? to_json($fp{$_}) : $fp{$_}) } sort keys %fp))), 0, 12);
    return \%fp;
}

# ---------------------------------------------------------
# Datensätze: Liste, Ziehung, Sperre, Löschen, Sicherung
# ---------------------------------------------------------
get '/BBB/validation/sets' => sub {
    my $c = shift;
    my $rows = $c->pg->db->query(q{
        SELECT s.id, s.name, s.purpose, s.locked, s.frozen_at, s.frozen_by, s.created_at, s.created_by, s.reference_source,
               s.baseline_run_id, s.params, s.notes,
               (SELECT count(*) FROM validation_items i WHERE i.set_id = s.id) AS n_items,
               (SELECT count(*) FROM validation_runs r WHERE r.set_id = s.id) AS n_runs
        FROM validation_sets s ORDER BY s.created_at DESC
    })->hashes->to_array;
    $_->{params} = _val_json($_->{params}) for @$rows;
    $c->render(json => $rows);
};

post '/BBB/validation/sets' => sub {
    my $c  = shift;
    my $p  = $c->req->json // {};
    my $db = $c->pg->db;

    return $c->render(json => { error => "Zum Anlegen \"ANLEGEN\" bestätigen." }, status => 400)
        unless ($p->{confirm} // '') eq 'ANLEGEN';
    my $name = $p->{name} // '';
    $name =~ s/^\s+|\s+$//g;
    return $c->render(json => { error => 'Name fehlt.' }, status => 400) unless length $name;
    return $c->render(json => { error => "Datensatz \"$name\" existiert bereits." }, status => 409)
        if $db->query('SELECT 1 FROM validation_sets WHERE name = ?', $name)->array;

    my $purpose = ($p->{purpose} // '') eq 'study' ? 'study' : 'regression';
    my $n       = int($p->{n} // ($purpose eq 'study' ? 150 : 50));
    return $c->render(json => { error => 'Stichprobengröße muss zwischen 5 und 2000 liegen.' }, status => 400)
        unless $n >= 5 && $n <= 2000;
    my $seed    = defined $p->{seed} && $p->{seed} =~ /^\d+$/ ? $p->{seed} + 0 : int(rand(1e9));
    my $double  = $purpose eq 'study' ? ($p->{double_fraction} // 0.3) + 0 : 0;
    my $inject  = $purpose eq 'study' ? ($p->{inject_fraction} // 0.08) + 0 : 0;
    my @tags    = grep { length } map { lc s/^\s+|\s+$//gr } split /,/, ($p->{tag} // '');
    my $per_pat = exists $p->{one_per_patient} ? to_bool($p->{one_per_patient}) : 1;
    my $minlen  = int($p->{min_length} // 300);

    # Grundgesamtheit: Briefe mit Text und Phenopacket, je Brieftext einmal,
    # optional ein Brief je Patient, ohne Briefe aus anderen Validierungsdatensätzen
    my @bind = ($seed, $minlen);
    my $tag_sql = '';
    if (@tags) {
        $tag_sql = "AND EXISTS (SELECT 1 FROM unnest(string_to_array(COALESCE(c.tags, ''), ',')) tt(t) WHERE lower(trim(tt.t)) = ANY(?))";
        push @bind, \@tags;
    }
    my $pool = $db->query(qq{
        WITH pool AS (
            SELECT DISTINCT ON (md5(c.narrative_report))
                   c.id, c.pseudonym, c.doc_source, c.reference_date::text AS reference_date,
                   md5(?::text || ':' || c.id) AS r
            FROM candidates c
            WHERE c.phenopacket_json IS NOT NULL AND length(c.phenopacket_json::text) > 20
              AND c.narrative_report IS NOT NULL AND length(c.narrative_report) >= ?
              AND c.id NOT IN (SELECT candidate_id FROM validation_items WHERE candidate_id IS NOT NULL)
              $tag_sql
            ORDER BY md5(c.narrative_report), c.id
        )
        SELECT * FROM pool
    }, @bind)->hashes->to_array;

    if ($per_pat) {
        my %best;
        for my $r (@$pool) {
            my $k = $r->{pseudonym} // "id$r->{id}";
            $best{$k} = $r if !$best{$k} || $r->{r} lt $best{$k}{r};
        }
        $pool = [ values %best ];
    }
    return $c->render(json => { error => "Nur " . scalar(@$pool) . " geeignete Briefe gefunden, $n angefordert." }, status => 422)
        if @$pool < $n;

    # proportionale Schichtung nach Quelle und Jahr (Largest-Remainder-Verfahren)
    my %strata;
    for my $r (@$pool) {
        my $year = ($r->{reference_date} // '') =~ /^(\d{4})/ ? $1 : 'unbekannt';
        $r->{stratum} = ($r->{doc_source} // 'unbekannt') . "|$year";
        push @{ $strata{ $r->{stratum} } }, $r;
    }
    my $total = scalar @$pool;
    my (%alloc, @rem);
    for my $s (keys %strata) {
        my $exact = $n * @{ $strata{$s} } / $total;
        $alloc{$s} = int($exact);
        push @rem, [ $s, $exact - int($exact) ];
    }
    my $left = $n;
    $left -= $_ for values %alloc;
    for my $x (sort { $b->[1] <=> $a->[1] || $a->[0] cmp $b->[0] } @rem) {
        last if $left <= 0;
        $alloc{ $x->[0] }++;
        $left--;
    }
    my @chosen;
    for my $s (sort keys %strata) {
        my @sorted = sort { $a->{r} cmp $b->{r} } @{ $strata{$s} };
        push @chosen, @sorted[0 .. $alloc{$s} - 1] if $alloc{$s};
    }
    @chosen = sort { md5_hex("$seed:pos:$a->{id}") cmp md5_hex("$seed:pos:$b->{id}") } @chosen;

    my $tx = $db->begin;
    my $set_id = $db->insert('validation_sets', {
        name => $name, purpose => $purpose, created_by => $p->{created_by} // '', notes => $p->{notes} // '',
        params => to_json({ n => $n, seed => $seed, tags => \@tags, one_per_patient => $per_pat ? 1 : 0,
                            min_length => $minlen, double_fraction => $double, inject_fraction => $inject,
                            pool_size => $total, strata => { map { $_ => { pool => scalar @{ $strata{$_} }, sample => $alloc{$_} } } keys %strata } }),
    }, { returning => 'id' })->hash->{id};

    my ($pos, $n_double, $n_inject) = (0, 0, 0);
    for my $r (@chosen) {
        my $row = $db->query('SELECT narrative_report, phenopacket_json::text AS pp FROM candidates WHERE id = ?', $r->{id})->hash;
        my $pp  = _ppd_parse_json($row->{pp}) // {};
        my $entries = _val_entries($pp);
        my $is_double = $double > 0 && _val_rand($seed, "double:$r->{id}") < $double ? 1 : 0;
        my @inj;
        if ($inject > 0 && @$entries && _val_rand($seed, "inject:$r->{id}") < $inject) {
            my @cand = sort { _val_rand($seed, "pick:$a->{key}") <=> _val_rand($seed, "pick:$b->{key}") } @$entries;
            my $t = $cand[0];
            my ($sw) = grep { $_->{side} eq 'R' || $_->{side} eq 'L' } @cand;
            my ($dt) = grep { $_->{date} =~ /^\d{4}/ } @cand;
            my $kind = _val_rand($seed, "kind:$r->{id}");
            if ($sw && $kind < 0.4) {
                push @inj, { type => 'side_swap', key => $sw->{key}, original => { %$sw } };
                $sw->{side} = $sw->{side} eq 'R' ? 'L' : 'R';
            } elsif ($dt && $kind < 0.7) {
                push @inj, { type => 'date_shift', key => $dt->{key}, original => { %$dt } };
                $dt->{date} =~ s/^(\d{4})/$1 - 1/e;
            } else {
                push @inj, { type => 'drop', key => $t->{key}, original => { %$t } };
                $entries = [ grep { $_->{key} ne $t->{key} } @$entries ];
            }
        }
        $n_double++ if $is_double;
        $n_inject++ if @inj;
        $db->insert('validation_items', {
            set_id => $set_id, position => ++$pos, candidate_id => $r->{id}, pseudonym => $r->{pseudonym},
            doc_source => $r->{doc_source}, reference_date => $r->{reference_date}, stratum => $r->{stratum},
            narrative => $row->{narrative_report}, narrative_md5 => md5_hex(encode('UTF-8', $row->{narrative_report})),
            snapshot => to_json($pp), entries => to_json($entries),
            injected => @inj ? to_json(\@inj) : undef, double_review => $is_double ? 1 : 0,
        });
    }
    $tx->commit;
    $c->app->log->info("[VALIDATION] Datensatz \"$name\" ($purpose) mit $pos Briefen angelegt (Seed $seed).");
    $c->render(json => { id => $set_id, name => $name, n => $pos, seed => $seed, pool => $total,
                         double => $n_double, injected => $n_inject, strata => scalar keys %strata });
};

post '/BBB/validation/sets/:id/lock' => sub {
    my $c   = shift;
    my $p   = $c->req->json // {};
    my $db  = $c->pg->db;
    my $set = _val_load_set($db, $c->param('id')) or return $c->render(json => { error => 'Datensatz nicht gefunden.' }, status => 404);
    my $lock = to_bool($p->{locked}) ? 1 : 0;
    return $c->render(json => { error => 'Zum Entsperren den Namen des Datensatzes eingeben.' }, status => 400)
        if !$lock && !_val_confirm_ok($set, $p->{confirm});
    $db->update('validation_sets', { locked => $lock }, { id => $set->{id} });
    $c->render(json => { ok => 1, locked => $lock });
};

del '/BBB/validation/sets/:id' => sub {
    my $c   = shift;
    my $db  = $c->pg->db;
    my $set = _val_load_set($db, $c->param('id')) or return $c->render(json => { error => 'Datensatz nicht gefunden.' }, status => 404);
    my $confirm = ($c->req->json // {})->{confirm} // $c->param('confirm');
    return $c->render(json => { error => 'Datensatz ist gesperrt. Zuerst entsperren.' }, status => 409) if $set->{locked};
    return $c->render(json => { error => 'Zum Löschen den Namen des Datensatzes eingeben.' }, status => 400)
        unless _val_confirm_ok($set, $confirm);
    my $ok = eval {
        my $tx = $db->begin;
        $db->query('DELETE FROM validation_run_items WHERE run_id IN (SELECT id FROM validation_runs WHERE set_id = ?)', $set->{id});
        $db->query('DELETE FROM validation_runs WHERE set_id = ?', $set->{id});
        $db->query('UPDATE validation_sets SET frozen_at = NULL WHERE id = ?', $set->{id});
        $db->query('DELETE FROM validation_reviews WHERE item_id IN (SELECT id FROM validation_items WHERE set_id = ?)', $set->{id});
        $db->query('DELETE FROM validation_ai_reviews WHERE item_id IN (SELECT id FROM validation_items WHERE set_id = ?)', $set->{id});
        $db->query('DELETE FROM validation_items WHERE set_id = ?', $set->{id});
        $db->query('DELETE FROM validation_sets WHERE id = ?', $set->{id});
        $tx->commit;
        1;
    };
    return $c->render(json => { error => "Löschen fehlgeschlagen: $@" }, status => 500) unless $ok;
    $c->app->log->warn("[VALIDATION] Datensatz \"$set->{name}\" gelöscht.");
    $c->render(json => { ok => 1 });
};

get '/BBB/validation/sets/:id/export' => sub {
    my $c   = shift;
    my $db  = $c->pg->db;
    my $set = _val_load_set($db, $c->param('id')) or return $c->render(json => { error => 'Datensatz nicht gefunden.' }, status => 404);
    my $items = _val_load_items($db, $set->{id});
    my $rev   = $db->query(q{SELECT r.item_id, r.reviewer, r.entry_key, r.judgment, r.updated_at FROM validation_reviews r
                             JOIN validation_items i ON i.id = r.item_id WHERE i.set_id = ? ORDER BY r.id}, $set->{id})->expand->hashes->to_array;
    my $runs  = $db->query('SELECT id, mode, label, status, fingerprint, metrics, comparison, started_at, finished_at FROM validation_runs WHERE set_id = ? ORDER BY id',
                           $set->{id})->expand->hashes->to_array;
    (my $fn = $set->{name}) =~ s/[^A-Za-z0-9_\-]+/_/g;
    $c->res->headers->content_disposition("attachment; filename=\"validierung_${fn}.json\"");
    $c->render(json => { format => 'ontotrial-validation-1', exported_at => POSIX::strftime('%Y-%m-%dT%H:%M:%S', localtime),
                         set => $set, items => $items, reviews => $rev, runs => $runs });
};

# ---------------------------------------------------------
# Prüfen: Briefliste, Brief mit Einträgen, Bewertungen speichern
# ---------------------------------------------------------
get '/BBB/validation/sets/:id/items' => sub {
    my $c   = shift;
    my $db  = $c->pg->db;
    my $set = _val_load_set($db, $c->param('id')) or return $c->render(json => { error => 'Datensatz nicht gefunden.' }, status => 404);
    my $me  = $c->param('reviewer') // '';
    my $rows = $db->query(q{
        SELECT i.id, i.position, i.candidate_id, i.pseudonym, i.doc_source, i.reference_date, i.stratum, i.double_review,
               jsonb_array_length(i.entries) AS n_entries,
               EXISTS (SELECT 1 FROM validation_reviews r WHERE r.item_id = i.id AND r.reviewer = ? AND r.entry_key = '_done'
                       AND (r.judgment->>'done')::boolean) AS my_done,
               EXISTS (SELECT 1 FROM validation_reviews r WHERE r.item_id = i.id AND r.reviewer = ? AND r.entry_key = '_checklist'
                       AND (r.judgment->>'done')::boolean) AS my_checklist,
               (SELECT count(*) FROM validation_reviews r WHERE r.item_id = i.id AND r.reviewer = ? AND r.entry_key NOT LIKE '\_%' AND r.entry_key NOT LIKE 'missing:%') AS my_judged,
               (SELECT count(DISTINCT r.reviewer) FROM validation_reviews r WHERE r.item_id = i.id AND r.entry_key = '_done'
                AND (r.judgment->>'done')::boolean) AS n_done
        FROM validation_items i WHERE i.set_id = ? ORDER BY i.position
    }, $me, $me, $me, $set->{id})->hashes->to_array;
    $c->render(json => { set => $set, items => $rows });
};

get '/BBB/validation/items/:id' => sub {
    my $c    = shift;
    my $db   = $c->pg->db;
    my $me   = $c->param('reviewer') // '';
    my $item = $db->query('SELECT * FROM validation_items WHERE id = ?', $c->param('id'))->hash
        or return $c->render(json => { error => 'Brief nicht gefunden.' }, status => 404);
    $item->{entries} = _val_json($item->{entries});
    my $set = _val_load_set($db, $item->{set_id});
    my $rows = $db->query('SELECT reviewer, entry_key, judgment::text AS judgment FROM validation_reviews WHERE item_id = ?', $item->{id})->hashes;
    my (%mine, %others);
    for my $r (@$rows) {
        my $j = _val_json($r->{judgment});
        if ($r->{reviewer} eq $me) { $mine{ $r->{entry_key} } = $j }
        else { $others{ $r->{reviewer} }{ $r->{entry_key} } = $j }
    }
    my $blind = $set->{purpose} eq 'study' && $me ne $VAL_CONSENSUS && !($mine{_checklist} && $mine{_checklist}{done});
    my %out = (
        id => $item->{id}, set_id => $item->{set_id}, position => $item->{position}, pseudonym => $item->{pseudonym},
        doc_source => $item->{doc_source}, reference_date => $item->{reference_date}, double_review => $item->{double_review} ? 1 : 0,
        purpose => $set->{purpose}, frozen => $set->{frozen_at} ? 1 : 0,
        narrative => $item->{narrative}, blind => $blind ? 1 : 0,
        entries => $blind ? [] : $item->{entries}, judgments => \%mine,
    );
    # Konsens sieht die Urteile aller Prüfer, normale Prüfer nur die eigenen
    $out{others} = \%others if $me eq $VAL_CONSENSUS;
    $c->render(json => \%out);
};

post '/BBB/validation/items/:id/review' => sub {
    my $c    = shift;
    my $p    = $c->req->json // {};
    my $db   = $c->pg->db;
    my $me   = $p->{reviewer} // '';
    $me =~ s/^\s+|\s+$//g;
    return $c->render(json => { error => 'Prüfername fehlt.' }, status => 400) unless length $me;
    my $item = $db->query('SELECT id, set_id, entries FROM validation_items WHERE id = ?', $c->param('id'))->hash
        or return $c->render(json => { error => 'Brief nicht gefunden.' }, status => 404);
    my %valid = map { $_->{key} => 1 } @{ _val_json($item->{entries}) // [] };
    my @list = ref $p->{reviews} eq 'ARRAY' ? @{ $p->{reviews} } : ({ entry_key => $p->{entry_key}, judgment => $p->{judgment} });
    for my $r (@list) {
        my $k = $r->{entry_key} // '';
        return $c->render(json => { error => "Unbekannter Eintrag: $k" }, status => 400)
            unless $valid{$k} || $k =~ /^missing:[A-Za-z0-9\-]{1,64}$/ || $k eq '_checklist' || $k eq '_done';
        return $c->render(json => { error => 'Bewertung fehlt.' }, status => 400) unless ref $r->{judgment} eq 'HASH';
    }
    my $ok = eval {
        my $tx = $db->begin;
        for my $r (@list) {
            $db->query(q{INSERT INTO validation_reviews (item_id, reviewer, entry_key, judgment) VALUES (?, ?, ?, ?::jsonb)
                         ON CONFLICT (item_id, reviewer, entry_key) DO UPDATE SET judgment = EXCLUDED.judgment, updated_at = now()},
                       $item->{id}, $me, $r->{entry_key}, to_json($r->{judgment}));
        }
        $tx->commit;
        1;
    };
    return $c->render(json => { error => ($@ =~ /eingefroren/ ? 'Die Referenz ist eingefroren; Bewertungen sind nicht mehr änderbar.' : "Speichern fehlgeschlagen: $@") },
                      status => 409) unless $ok;
    $c->render(json => { ok => 1, saved => scalar @list });
};

# offene Punkte vor dem Einfrieren: unvollständig geprüfte Briefe und Abweichungen
get '/BBB/validation/sets/:id/status' => sub {
    my $c   = shift;
    my $db  = $c->pg->db;
    my $set = _val_load_set($db, $c->param('id')) or return $c->render(json => { error => 'Datensatz nicht gefunden.' }, status => 404);
    my $items = _val_load_items($db, $set->{id});
    my $revs  = _val_reviews_by_item($db, $set->{id});
    my (@incomplete, @conflicts, %reviewers);
    for my $i (@$items) {
        $reviewers{ $_->{reviewer} }++ for grep { $_->{entry_key} eq '_done' && (_val_json($_->{judgment}) // {})->{done} } @{ $revs->{ $i->{id} } // [] };
        my $res = _val_resolve($i, $revs->{ $i->{id} } // []);
        push @incomplete, { id => $i->{id}, position => $i->{position}, done => $res->{done} // [], double => $i->{double_review} ? 1 : 0 }
            if $res->{status} eq 'incomplete';
        push @conflicts, { id => $i->{id}, position => $i->{position}, reviewers => $res->{reviewers}, keys => $res->{conflicts} }
            if $res->{status} eq 'conflict';
    }
    $c->render(json => { set => $set, n_items => scalar @$items, incomplete => \@incomplete, conflicts => \@conflicts,
                         reviewers => \%reviewers });
};

post '/BBB/validation/sets/:id/freeze' => sub {
    my $c   = shift;
    my $p   = $c->req->json // {};
    my $db  = $c->pg->db;
    my $set = _val_load_set($db, $c->param('id')) or return $c->render(json => { error => 'Datensatz nicht gefunden.' }, status => 404);
    return $c->render(json => { error => 'Referenz ist bereits eingefroren.' }, status => 409) if $set->{frozen_at};
    return $c->render(json => { error => 'Zum Einfrieren den Namen des Datensatzes eingeben.' }, status => 400)
        unless _val_confirm_ok($set, $p->{confirm});
    my $items = _val_load_items($db, $set->{id});
    my $revs  = _val_reviews_by_item($db, $set->{id});
    my $judge = ($p->{source} // '') eq 'judge';
    my $ai    = {};
    if ($judge) {
        my $all = _val_ai_rows($db, $set->{id});
        my @m   = sort keys %$all;
        my $mod = $p->{model} // (@m == 1 ? $m[0] : undef);
        return $c->render(json => { error => @m ? 'Bitte das Judge-Modell wählen: ' . join(', ', @m) : 'Es gibt noch keine KI-Bewertungen.' }, status => 400)
            unless defined $mod && $all->{$mod};
        $ai = $all->{$mod};
    }
    my (@open, %refs, $source);
    for my $i (@$items) {
        my $res = $judge ? (_val_ai_resolution($ai->{ $i->{id} }) // { status => 'judge_missing' })
                         : _val_resolve($i, $revs->{ $i->{id} } // []);
        if ($res->{status} ne 'ok') { push @open, { position => $i->{position}, status => $res->{status} }; next; }
        $refs{ $i->{id} } = _val_build_reference($i, $res);
        $source = $judge ? 'judge:' . $ai->{ $i->{id} }{model} : 'human';
    }
    return $c->render(json => { error => scalar(@open) . ($judge ? ' Briefe haben noch keine fehlerfreie KI-Bewertung.'
                                                                 : ' Briefe sind noch nicht abschließend bewertet oder haben Abweichungen.'), open => \@open },
                      status => 409) if @open;
    my $tx = $db->begin;
    $db->update('validation_items', { reference => to_json($refs{$_}) }, { id => $_ }) for keys %refs;
    $db->update('validation_sets', { frozen_at => \'now()', frozen_by => $p->{by} // '', reference_source => $source // 'human' }, { id => $set->{id} });
    $tx->commit;
    my $n_ref = 0;
    $n_ref += scalar @{ $_->{entries} } for values %refs;
    $c->app->log->info("[VALIDATION] Referenz von \"$set->{name}\" eingefroren ($n_ref Einträge).");
    $c->render(json => { ok => 1, items => scalar keys %refs, reference_entries => $n_ref });
};

post '/BBB/validation/sets/:id/unfreeze' => sub {
    my $c   = shift;
    my $p   = $c->req->json // {};
    my $db  = $c->pg->db;
    my $set = _val_load_set($db, $c->param('id')) or return $c->render(json => { error => 'Datensatz nicht gefunden.' }, status => 404);
    return $c->render(json => { error => 'Datensatz ist gesperrt. Zum Auftauen zuerst entsperren.' }, status => 409) if $set->{locked};
    return $c->render(json => { error => 'Zum Auftauen den Namen des Datensatzes eingeben.' }, status => 400)
        unless _val_confirm_ok($set, $p->{confirm});
    $db->update('validation_sets', { frozen_at => undef, frozen_by => undef }, { id => $set->{id} });
    $c->render(json => { ok => 1 });
};

# ---------------------------------------------------------
# Regressionstest
# ---------------------------------------------------------
post '/BBB/validation/sets/:id/runs' => sub {
    my $c   = shift;
    my $p   = $c->req->json // {};
    my $db  = $c->pg->db;
    my $set = _val_load_set($db, $c->param('id')) or return $c->render(json => { error => 'Datensatz nicht gefunden.' }, status => 404);
    return $c->render(json => { error => 'Erst die Referenz einfrieren.' }, status => 409) unless $set->{frozen_at};
    return $c->render(json => { error => 'Für diesen Datensatz läuft bereits ein Lauf.' }, status => 409)
        if $db->query(q{SELECT 1 FROM validation_runs WHERE set_id = ? AND status IN ('queued', 'running')}, $set->{id})->array;
    my $mode = ($p->{mode} // '') eq 'stored' ? 'stored' : 'reextract';
    my $run_id = $db->insert('validation_runs', { set_id => $set->{id}, mode => $mode, label => $p->{label} // '',
                                                  fingerprint => to_json(_val_fingerprint($c->app)) }, { returning => 'id' })->hash->{id};
    $c->minion->enqueue(validation_run_task => [{ run_id => $run_id, model => $p->{model} }], { attempts => 1 });
    $c->render(json => { ok => 1, run_id => $run_id, mode => $mode });
};

get '/BBB/validation/sets/:id/runs' => sub {
    my $c = shift;
    my $rows = $c->pg->db->query(q{SELECT id, mode, label, status, progress, fingerprint, metrics, comparison, error, started_at, finished_at
                                   FROM validation_runs WHERE set_id = ? ORDER BY id DESC}, $c->param('id'))->expand->hashes->to_array;
    $c->render(json => $rows);
};

get '/BBB/validation/runs/:id' => sub {
    my $c   = shift;
    my $db  = $c->pg->db;
    my $run = $db->query('SELECT * FROM validation_runs WHERE id = ?', $c->param('id'))->expand->hash
        or return $c->render(json => { error => 'Lauf nicht gefunden.' }, status => 404);
    $run->{items} = $db->query(q{SELECT ri.item_id, i.position, i.pseudonym, ri.result, ri.error FROM validation_run_items ri
                                 JOIN validation_items i ON i.id = ri.item_id WHERE ri.run_id = ? ORDER BY i.position}, $run->{id})->expand->hashes->to_array;
    $c->render(json => $run);
};

post '/BBB/validation/sets/:id/baseline' => sub {
    my $c   = shift;
    my $p   = $c->req->json // {};
    my $db  = $c->pg->db;
    my $set = _val_load_set($db, $c->param('id')) or return $c->render(json => { error => 'Datensatz nicht gefunden.' }, status => 404);
    my $ok  = $db->query(q{SELECT 1 FROM validation_runs WHERE id = ? AND set_id = ? AND status = 'finished'}, $p->{run_id} // 0, $set->{id})->array;
    return $c->render(json => { error => 'Nur abgeschlossene Läufe dieses Datensatzes können Basis werden.' }, status => 400) unless $ok;
    $db->update('validation_sets', { baseline_run_id => $p->{run_id} }, { id => $set->{id} });
    $c->render(json => { ok => 1 });
};

get '/BBB/validation/runs/:id/report.csv' => sub {
    my $c   = shift;
    my $db  = $c->pg->db;
    my $rows = $db->query(q{SELECT i.position, i.pseudonym, ri.result, ri.error FROM validation_run_items ri
                            JOIN validation_items i ON i.id = ri.item_id WHERE ri.run_id = ? ORDER BY i.position}, $c->param('id'))->expand->hashes;
    my $cell = sub { my $v = shift // ''; $v =~ /[";\n]/ ? '"' . ($v =~ s/"/""/gr) . '"' : $v };
    my @out = ('position;pseudonym;art;domain;code;label;side;date;detail');
    for my $r (@$rows) {
        my $res = $r->{result} // {};
        push @out, join(';', map { $cell->($_) } $r->{position}, $r->{pseudonym}, 'fehler', '', '', '', '', '', $r->{error}) if $r->{error};
        push @out, join(';', map { $cell->($_) } $r->{position}, $r->{pseudonym}, 'fehlt', @$_{qw(domain code label side date)}, '') for @{ $res->{fn} // [] };
        push @out, join(';', map { $cell->($_) } $r->{position}, $r->{pseudonym}, 'zusaetzlich', @$_{qw(domain code label side date)}, '') for @{ $res->{fp} // [] };
        push @out, join(';', map { $cell->($_) } $r->{position}, $r->{pseudonym}, 'verwandt', $_->{domain}, $_->{pred_code}, $_->{pred_label}, '', '',
                                                  "Referenz $_->{ref_code} $_->{ref_label}") for @{ $res->{partial} // [] };
        for my $a (@{ $res->{attr_errors} // [] }) {
            my $d = join(', ', map { "$_: Referenz '$a->{errors}{$_}{ref}', Extraktion '$a->{errors}{$_}{pred}'" } sort keys %{ $a->{errors} });
            push @out, join(';', map { $cell->($_) } $r->{position}, $r->{pseudonym}, 'attribut', $a->{domain}, $a->{code}, $a->{label}, '', '', $d);
        }
    }
    $c->res->headers->content_type('text/csv; charset=utf-8');
    $c->res->headers->content_disposition('attachment; filename="regression_lauf_' . $c->param('id') . '.csv"');
    $c->render(data => encode('UTF-8', join("\n", @out) . "\n"));
};

sub _val_regression_compare {
    my ($metrics, $base_metrics, $items, $base_items) = @_;
    my $tol = $ENV{ONTOTRIAL_REGRESSION_TOLERANCE} // 0.02;
    my (%delta, @worse);
    for my $d (@VAL_DOMAINS, 'all') {
        my ($now, $was) = ($metrics->{$d}{f1}, $base_metrics->{$d}{f1});
        next unless defined $now && defined $was;
        $delta{$d} = sprintf('%.4f', $now - $was) + 0;
        push @worse, $d if $now - $was < -$tol;
    }
    my %base = map { $_->{item_id} => $_->{result} // {} } @$base_items;
    my @changes;
    for my $it (@$items) {
        my $b = $base{ $it->{item_id} } or next;
        my $r = $it->{result} // {};
        my %tp_now = map { $_ => 1 } @{ $r->{tp_keys} // [] };
        my %fp_was = map { $_->{sig} => 1 } @{ $b->{fp} // [] };
        my %ref_by_key = map { $_->{key} => $_ } @{ $r->{fn} // [] };
        my @lost   = map { $ref_by_key{$_} // { key => $_ } } grep { !$tp_now{$_} } @{ $b->{tp_keys} // [] };
        my %tp_was = map { $_ => 1 } @{ $b->{tp_keys} // [] };
        my @gained = grep { !$tp_was{$_} } @{ $r->{tp_keys} // [] };
        my @new_fp = grep { !$fp_was{ $_->{sig} } } @{ $r->{fp} // [] };
        push @changes, { item_id => $it->{item_id}, position => $it->{position}, lost => \@lost,
                         gained => scalar @gained, new_fp => \@new_fp } if @lost || @gained || @new_fp;
    }
    return { delta_f1 => \%delta, worse_domains => \@worse, tolerance => $tol + 0,
             verdict => @worse ? 'regression' : 'ok', changes => \@changes };
}

app->minion->add_task(validation_run_task => sub {
    my ($job, $payload) = @_;
    my $app    = $job->app;
    my $db     = $app->pg->db;
    my $run_id = $payload->{run_id};
    my $run    = $db->query('SELECT * FROM validation_runs WHERE id = ?', $run_id)->hash or return $job->fail('Lauf fehlt');
    my $set    = _val_load_set($db, $run->{set_id});
    my $items  = _val_load_items($db, $set->{id});
    my $task   = "validation_run_$run_id";
    my $n      = scalar @$items;
    $db->update('validation_runs', { status => 'running' }, { id => $run_id });

    my $k = 0;
    for my $i (@$items) {
        $k++;
        my ($pp, $err);
        if ($run->{mode} eq 'stored') {
            my $row = $i->{candidate_id} ? $db->query('SELECT narrative_report, phenopacket_json::text AS pp FROM candidates WHERE id = ?', $i->{candidate_id})->hash : undef;
            if (!$row) { $err = 'Brief nicht mehr im Bestand' }
            elsif (md5_hex(encode('UTF-8', $row->{narrative_report} // '')) ne $i->{narrative_md5}) { $err = 'Brieftext im Bestand wurde geändert' }
            else { $pp = _ppd_parse_json($row->{pp}) or $err = 'Phenopacket nicht lesbar' }
        } else {
            $app->generate_phenopacket_impl($i->{narrative}, $payload->{model}, undef, $i->{reference_date}, 0, $task)
                ->then(sub { $pp = shift })->catch(sub { $err = 'Pipeline-Fehler: ' . shift })->wait;
        }
        my $result = $pp && !$err ? _val_compare($app, $i->{reference} // { entries => [] }, _val_entries($pp)) : undef;
        $db->query(q{INSERT INTO validation_run_items (run_id, item_id, phenopacket, result, error) VALUES (?, ?, ?::jsonb, ?::jsonb, ?)
                     ON CONFLICT (run_id, item_id) DO UPDATE SET phenopacket = EXCLUDED.phenopacket, result = EXCLUDED.result, error = EXCLUDED.error},
                   $run_id, $i->{id}, $pp ? to_json($pp) : undef, $result ? to_json($result) : undef, $err);
        my $pct = int(100 * $k / ($n || 1));
        $db->update('validation_runs', { progress => $pct }, { id => $run_id });
        $app->notify_task_progress($task, 'running', $pct, "Validierung: Brief $k von $n");
    }

    my $rows    = $db->query('SELECT ri.item_id, i.position, ri.result FROM validation_run_items ri JOIN validation_items i ON i.id = ri.item_id WHERE ri.run_id = ? ORDER BY i.position', $run_id)->expand->hashes->to_array;
    my @results = map { $_->{result} } grep { $_->{result} } @$rows;
    my $metrics = _val_metrics(\@results);
    $metrics->{n_items}  = $n;
    $metrics->{n_failed} = $n - scalar @results;
    my $cmp;
    if (my $base_id = $set->{baseline_run_id}) {
        my $base = $db->query('SELECT metrics FROM validation_runs WHERE id = ?', $base_id)->expand->hash;
        my $bi   = $db->query('SELECT item_id, result FROM validation_run_items WHERE run_id = ?', $base_id)->expand->hashes->to_array;
        $cmp = _val_regression_compare($metrics, $base->{metrics} // {}, $rows, $bi) if $base;
        $cmp->{baseline_run_id} = $base_id + 0 if $cmp;
    }
    $db->update('validation_runs', { status => 'finished', progress => 100, metrics => to_json($metrics),
                                     comparison => $cmp ? to_json($cmp) : undef, finished_at => \'now()' }, { id => $run_id });
    $app->notify_task_progress($task, 'finished', 100, 'Validierung abgeschlossen');
    $job->finish({ run_id => $run_id });
});

# ---------------------------------------------------------
# Validierungsstudie: Kennzahlen nach Bewertungshandbuch und Rohdaten
# ---------------------------------------------------------
sub _val_kappa {
    my ($pairs) = @_;
    return undef unless @$pairs;
    my ($agree, %pa, %pb) = (0);
    for my $p (@$pairs) { $agree++ if $p->[0] eq $p->[1]; $pa{ $p->[0] }++; $pb{ $p->[1] }++; }
    my $n  = scalar @$pairs;
    my $po = $agree / $n;
    my $pe = 0;
    $pe += ($pa{$_} // 0) * ($pb{$_} // 0) / ($n * $n) for keys %{ { %pa, %pb } };
    return { n => $n, agreement => sprintf('%.4f', $po) + 0, kappa => $pe < 1 ? sprintf('%.4f', ($po - $pe) / (1 - $pe)) + 0 : undef };
}

sub _val_study_counts {
    my ($item, $res) = @_;
    my %inj = map { $_->{key} => $_ } @{ $item->{injected} // [] };
    my %c;
    for my $e (@{ $item->{entries} }) {
        next if $inj{ $e->{key} };
        my $j = $res->{judgments}{ $e->{key} } or next;
        my $v = $j->{verdict} // '';
        my $d = $e->{domain};
        if ($v eq 'duplicate') { $c{$d}{duplicate}++; next }
        if ($v eq 'unclear')   { $c{$d}{unclear}++;   next }
        my $concept = $j->{concept} // 'ok';
        $c{$d}{judged}++;
        $c{$d}{strict}++   if $concept eq 'ok';
        $c{$d}{tolerant}++ if $concept eq 'ok' || $concept eq 'broader';
        $c{$d}{"concept_$concept"}++;
        next unless $concept eq 'ok';
        for my $a (qw(side date value)) {
            my $s = $j->{$a} // 'ok';
            next if $s eq 'na' || ($a eq 'value' && $d ne 'measurement');
            $c{$d}{"${a}_n"}++;
            $c{$d}{"${a}_ok"}++ if $s eq 'ok';
        }
        $c{$d}{status_n}++;
        $c{$d}{status_ok}++ if ($j->{status} // 'ok') eq 'ok';
    }
    for my $l (@{ ($res->{checklist} // {})->{lines} // [] }) {
        my $cat = $l->{cat} // 'sonstiges';
        next unless length($l->{match} // '');
        $c{_recall}{$cat}{n}++;
        $c{_recall}{$cat}{found}++ if $l->{match} eq 'found' || $l->{match} eq 'attr';
        $c{_recall}{$cat}{exact}++ if $l->{match} eq 'found';
    }
    return \%c;
}

sub _val_detected {
    my ($inj, $judg) = @_;
    my $h = $judg // {};
    my $j = $h->{ $inj->{key} } // {};
    return (($j->{side} // '') =~ /^(?:wrong|missing)$/ || ($j->{concept} // 'ok') ne 'ok') ? 1 : 0 if $inj->{type} eq 'side_swap';
    return (($j->{date} // '') eq 'wrong' || ($j->{concept} // 'ok') ne 'ok') ? 1 : 0 if $inj->{type} eq 'date_shift';
    my $code = _val_code($inj->{original}{code});
    return (grep { /^missing:/ && !$h->{$_}{deleted} && _val_code($h->{$_}{code}) eq $code } keys %$h) ? 1 : 0;
}

get '/BBB/validation/sets/:id/study' => sub {
    my $c   = shift;
    $c->inactivity_timeout(600);
    my $db  = $c->pg->db;
    my $set = _val_load_set($db, $c->param('id')) or return $c->render(json => { error => 'Datensatz nicht gefunden.' }, status => 404);
    my $items = _val_load_items($db, $set->{id});
    my $revs  = _val_reviews_by_item($db, $set->{id});

    my (@per_item, %kappa_pairs, %vig, $skipped);
    for my $i (@$items) {
        my $rows = $revs->{ $i->{id} } // [];
        my $res  = _val_resolve($i, $rows);
        if ($res->{status} eq 'ok') { push @per_item, _val_study_counts($i, $res) } else { $skipped++ }

        # Übereinstimmung der beiden ersten Prüfer (vor Konsens)
        my %by;
        for my $r (@$rows) { $by{ $r->{reviewer} }{ $r->{entry_key} } = _val_json($r->{judgment}) }
        my $dn = sub { my $h = $by{ $_[0] }{_done}; ref $h eq 'HASH' && $h->{done} };
        my @rv = sort grep { $_ ne $VAL_CONSENSUS && $dn->($_) } keys %by;
        if (@rv >= 2) {
            for my $e (@{ $i->{entries} }) {
                my ($a, $b) = map { $by{$_}{ $e->{key} } } @rv[0, 1];
                next unless $a && $b;
                push @{ $kappa_pairs{overall} }, [ ($a->{verdict} // '') eq 'correct' ? 1 : 0, ($b->{verdict} // '') eq 'correct' ? 1 : 0 ];
                for my $attr (qw(concept status side date)) {
                    push @{ $kappa_pairs{$attr} }, [ $a->{$attr} // 'ok', $b->{$attr} // 'ok' ];
                }
            }
        }
        # Wachsamkeit: eingestreute Fehler je Prüfer
        for my $inj (@{ $i->{injected} // [] }) {
            for my $rv (@rv) {
                $vig{ $inj->{type} }{n}++;
                $vig{ $inj->{type} }{detected} += _val_detected($inj, $by{$rv});
            }
        }
    }

    my $agg = sub {
        my ($sample) = @_;
        my %s;
        for my $c (@$sample) {
            for my $d (keys %$c) {
                next if $d eq '_recall';
                $s{$d}{$_} += $c->{$d}{$_} for keys %{ $c->{$d} };
                $s{all}{$_} += $c->{$d}{$_} for keys %{ $c->{$d} };
            }
            for my $cat (keys %{ $c->{_recall} // {} }) {
                $s{_recall}{$cat}{$_} += $c->{_recall}{$cat}{$_} for keys %{ $c->{_recall}{$cat} };
                $s{_recall}{all}{$_}  += $c->{_recall}{$cat}{$_} for keys %{ $c->{_recall}{$cat} };
            }
        }
        my %m;
        for my $d (@VAL_DOMAINS, 'all') {
            my $x = $s{$d} // {};
            $m{$d} = { judged => $x->{judged} // 0, duplicate => $x->{duplicate} // 0, unclear => $x->{unclear} // 0,
                       precision_strict => _val_ratio($x->{strict} // 0, $x->{judged} // 0),
                       precision_tolerant => _val_ratio($x->{tolerant} // 0, $x->{judged} // 0),
                       map { ("${_}_accuracy" => _val_ratio($x->{"${_}_ok"} // 0, $x->{"${_}_n"} // 0), "${_}_n" => $x->{"${_}_n"} // 0) } qw(side date status value) };
            $m{$d}{"concept_$_"} = $x->{"concept_$_"} // 0 for qw(ok broader narrower wrong absent wrong_subject);
        }
        for my $cat (keys %{ $s{_recall} // {} }) {
            my $x = $s{_recall}{$cat};
            $m{recall}{$cat} = { n => $x->{n} // 0, recall => _val_ratio($x->{found} // 0, $x->{n} // 0),
                                 recall_exact => _val_ratio($x->{exact} // 0, $x->{n} // 0) };
        }
        return \%m;
    };

    my $point = $agg->(\@per_item);
    # 95-%-KI per Cluster-Bootstrap über Briefe
    my $B = 2000;
    my (%boot);
    my $rng = 42;
    my $rand = sub { $rng = ($rng * 1103515245 + 12345) % 2147483648; return $rng / 2147483648 };
    if (@per_item) {
        for (1 .. $B) {
            my @s = map { $per_item[ int($rand->() * @per_item) ] } 1 .. @per_item;
            my $m = $agg->(\@s);
            for my $d (@VAL_DOMAINS, 'all') {
                for my $k (qw(precision_strict precision_tolerant side_accuracy date_accuracy status_accuracy value_accuracy)) {
                    push @{ $boot{$d}{$k} }, $m->{$d}{$k} if defined $m->{$d}{$k};
                }
            }
            for my $cat (keys %{ $m->{recall} // {} }) {
                push @{ $boot{"recall:$cat"}{recall} }, $m->{recall}{$cat}{recall} if defined $m->{recall}{$cat}{recall};
            }
        }
    }
    my $ci = sub {
        my $v = shift;
        return undef unless $v && @$v >= 20;
        my @s = sort { $a <=> $b } @$v;
        return [ $s[ int(0.025 * $#s) ], $s[ int(0.975 * $#s) ] ];
    };
    for my $d (@VAL_DOMAINS, 'all') {
        $point->{$d}{"${_}_ci"} = $ci->($boot{$d}{$_}) for keys %{ $boot{$d} // {} };
    }
    for my $cat (keys %{ $point->{recall} // {} }) {
        $point->{recall}{$cat}{recall_ci} = $ci->($boot{"recall:$cat"}{recall});
    }
    my %kappa = map { $_ => _val_kappa($kappa_pairs{$_}) } keys %kappa_pairs;
    my %vigil = map { $_ => { %{ $vig{$_} }, rate => _val_ratio($vig{$_}{detected} // 0, $vig{$_}{n}) } } keys %vig;
    my $ai = _val_ai_rows($db, $set->{id});
    my %judges = map { $_ => _val_judge_agreement($items, $revs, $ai->{$_}) } keys %$ai;
    my @jm = sort keys %$ai;
    my $between;
    if (@jm >= 2) {
        my @pairs;
        for my $i (@$items) {
            my ($a, $b) = map { $ai->{$_}{ $i->{id} } } @jm[0, 1];
            next unless $a && $b && !$a->{error} && !$b->{error};
            for my $e (@{ $i->{entries} }) {
                my ($x, $y) = ($a->{judgments}{ $e->{key} }, $b->{judgments}{ $e->{key} });
                push @pairs, [ ($x->{verdict} // '') eq 'correct' ? 1 : 0, ($y->{verdict} // '') eq 'correct' ? 1 : 0 ] if $x && $y;
            }
        }
        $between = { models => [ @jm[0, 1] ], overall => _val_kappa(\@pairs) };
    }
    $c->render(json => { set => { id => $set->{id}, name => $set->{name}, purpose => $set->{purpose}, frozen_at => $set->{frozen_at},
                                  reference_source => $set->{reference_source} },
                         n_items => scalar @$items, n_evaluated => scalar @per_item, n_skipped => $skipped // 0,
                         metrics => $point, kappa => \%kappa, vigilance => \%vigil, bootstrap => $B,
                         judges => \%judges, judges_between => $between });
};

get '/BBB/validation/sets/:id/judgments.csv' => sub {
    my $c   = shift;
    my $db  = $c->pg->db;
    my $set = _val_load_set($db, $c->param('id')) or return $c->render(json => { error => 'Datensatz nicht gefunden.' }, status => 404);
    my $items = _val_load_items($db, $set->{id});
    my $revs  = _val_reviews_by_item($db, $set->{id});
    my $cell  = sub { my $v = shift // ''; $v =~ /[";\n]/ ? '"' . ($v =~ s/"/""/gr) . '"' : $v };
    my @cols  = qw(verdict concept status side side_correct date date_correct value value_correct comment);
    my @out   = (join(';', qw(set position item_id pseudonym stratum double_review reviewer row_type entry_key domain code label
                              side date excluded value injected), @cols, 'checklist_cat', 'checklist_match'));
    for my $i (@$items) {
        my %e   = map { $_->{key} => $_ } @{ $i->{entries} };
        my %inj = map { $_->{key} => $_->{type} } @{ $i->{injected} // [] };
        for my $r (sort { $a->{reviewer} cmp $b->{reviewer} || $a->{entry_key} cmp $b->{entry_key} } @{ $revs->{ $i->{id} } // [] }) {
            my $j    = _val_json($r->{judgment}) // {};
            my @base = ($set->{name}, $i->{position}, $i->{id}, $i->{pseudonym}, $i->{stratum}, $i->{double_review} ? 1 : 0, $r->{reviewer});
            if ($r->{entry_key} eq '_checklist') {
                for my $l (@{ $j->{lines} // [] }) {
                    push @out, join(';', map { $cell->($_) } @base, 'checkliste', '', '', '', $l->{text}, $l->{side}, $l->{date}, '', $l->{value},
                                                             '', ('') x @cols, $l->{cat}, $l->{match});
                }
                next;
            }
            next if $r->{entry_key} eq '_done';
            my $x    = $r->{entry_key} =~ /^missing:/ ? $j : ($e{ $r->{entry_key} } // {});
            my $type = $r->{entry_key} =~ /^missing:/ ? ($j->{deleted} ? 'ergaenzt_geloescht' : 'ergaenzt') : 'eintrag';
            push @out, join(';', map { $cell->($_) } @base, $type, $r->{entry_key}, @$x{qw(domain code label side date)}, $x->{excluded} ? 1 : 0,
                                                     $x->{value}, $inj{ $r->{entry_key} } // '', @$j{@cols}, '', '');
        }
    }
    (my $fn = $set->{name}) =~ s/[^A-Za-z0-9_\-]+/_/g;
    $c->res->headers->content_type('text/csv; charset=utf-8');
    $c->res->headers->content_disposition("attachment; filename=\"bewertungen_${fn}.csv\"");
    $c->render(data => encode('UTF-8', join("\n", @out) . "\n"));
};



# ---------------------------------------------------------
# KI-Judge: automatische Bewertung durch ein Claude-Modell
# ---------------------------------------------------------
# Der Judge bewertet jeden extrahierten Eintrag nach denselben Regeln wie die
# Ärzte (Bewertungshandbuch) und nennt fehlende Einträge. Seine Urteile liegen
# getrennt von den ärztlichen Bewertungen in validation_ai_reviews und dienen
#   - als KI-Referenz, solange (noch) keine ärztliche Referenz existiert,
#   - als zusätzlicher Bewerter, der in der Studie gegen die Ärzte gemessen wird.
#
# Zwei Anbieter, einzeln oder beide (dann werden sie auch gegeneinander verglichen):
#   anthropic  Claude über die externe API (Briefe verlassen die Klinik)
#   local      eigenes Modell, z. B. GLM-5, über eine OpenAI-kompatible API (vLLM)
#              oder Ollama; die Briefe bleiben im Haus
#
# Konfiguration (Environment), Claude:
#   ANTHROPIC_API_KEY              API-Schlüssel (ohne ihn ist der Claude-Judge aus)
#   ONTOTRIAL_JUDGE_MODEL          Default claude-opus-5-5
#   ONTOTRIAL_JUDGE_URL            Default https://api.anthropic.com/v1/messages
#   ONTOTRIAL_JUDGE_MAX_TOKENS     Default 16000
#   ONTOTRIAL_JUDGE_TEMPERATURE    leer = Modell-Default
#   ONTOTRIAL_JUDGE_PII_GUARD      1 (Default) = Briefe mit Geburtsdatum oder
#                                  Name mit Anrede werden nicht gesendet
#   ONTOTRIAL_JUDGE_PII_REGEX      zusätzliche eigene Sperr-Regel
# Lokaler Judge:
#   ONTOTRIAL_JUDGE_LOCAL_MODEL    Modellname, z. B. glm-5 (ohne ihn ist der lokale Judge aus)
#   ONTOTRIAL_JUDGE_LOCAL_URL      Chat-Completions-Endpunkt; Default wie die Pipeline (VLLM_ENDPOINT)
#   ONTOTRIAL_JUDGE_LOCAL_KEY      API-Schlüssel; Default VLLM_API_KEY
#   ONTOTRIAL_JUDGE_LOCAL_MAX_TOKENS  Default 32000 (Platz für den Denkprozess)
#   ONTOTRIAL_JUDGE_LOCAL_TEMPERATURE Default 0
#   ONTOTRIAL_JUDGE_LOCAL_THINKING    0 = Denkmodus über chat_template_kwargs abschalten
#   ONTOTRIAL_JUDGE_LOCAL_PII_GUARD   Default 0 (Briefe bleiben im Haus)
# ---------------------------------------------------------

our $VAL_JUDGE_SYSTEM = <<'TXT';
Du bist ein erfahrener Augenarzt und prüfst die automatische Kodierung eines deutschen augenärztlichen Arztbriefs.
Du erhältst den Brieftext und eine nummerierte Liste extrahierter Einträge (E1, E2, …). Jeder Eintrag hat eine
Domäne (Diagnose ICD-10-GM, Befund HPO, Eingriff OPS, Medikation ATC, Messwert LOINC), einen Code mit Bezeichnung,
eine Augenseite (RA, LA, beidseits oder keine), ein Datum, gegebenenfalls einen Messwert und den Status vorhanden/verneint.

Bewerte jeden Eintrag ausschließlich am Brieftext. Ergänze kein klinisches Wissen und prüfe nicht, ob der Brief medizinisch stimmt.

Konzept:
- ok: der Code trifft den im Brief genannten Sachverhalt auf der Ebene, die der Brief hergibt
- broader: richtige Oberklasse, der Brief stützt einen spezifischeren Code
- narrower: der Code enthält ein Detail, das der Brief nicht trägt
- wrong: der Code bezeichnet einen anderen Sachverhalt
- absent: der Sachverhalt steht nicht im Brief
- wrong_subject: der Sachverhalt betrifft nicht den Patienten (Familienanamnese, Spender, andere Person)
Status:
- ok: vorhanden/verneint stimmt
- negation: verneint und vorhanden sind vertauscht („kein Anhalt für“, „keine“, „ausgeschlossen“ = verneint)
- suspected: Verdacht, Differenzialdiagnose oder „fraglich“ wurde als gesichert übernommen
- planned: geplante oder empfohlene Maßnahme wurde als erfolgt übernommen
Augenseite und Datum: ok, wrong, missing (Brief nennt eine Angabe, der Eintrag hat keine), superfluous (Eintrag hat eine Angabe,
die der Brief nicht hergibt) oder na (nicht anwendbar, etwa bei systemischen Befunden). Gib bei wrong oder missing die richtige
Angabe an (Seite: R, L, B; bei superfluous: none; Datum: JJJJ, JJJJ-MM oder JJJJ-MM-TT, so genau wie im Brief).
Messwert: ok, wrong (Zahl, Einheit oder Vergleichsoperator falsch) oder na bei Nicht-Messwerten; bei wrong den richtigen Wert.

Regeln:
- Anamnestische Angaben („Z. n.“, „bekannte“, „seit“) gehören zum Brief. Ihr Datum muss der Genauigkeit im Brief entsprechen.
- Aktuelle Befunde ohne eigenes Datum gelten mit dem Briefdatum als korrekt datiert. Ein anamnestisches Ereignis ohne Datum
  darf nicht das Briefdatum tragen (dann Datum superfluous).
- Angaben wie „Tensio 18/21 mmHg“ werden als RA/LA gelesen.
- Zitierte Vorbefunde anderer Kliniken gelten als Inhalt des Briefs.
- Dosis und Applikationsfrequenz von Medikamenten werden nicht bewertet; Kombinationspräparate dürfen als Kombinationscode
  oder als Einzelwirkstoffe kodiert sein.

Fehlende Einträge: Nenne zusätzlich, was im Brief steht, aber nicht extrahiert wurde, beschränkt auf Augendiagnosen,
augenrelevante Befunde, Augenoperationen und -eingriffe, Augenmedikation, Visus, Augendruck und andere augenärztliche Messwerte
(höchstens 30). Gib einen Code nur an, wenn du ihn sicher kennst (ICD-10-GM, OPS, ATC, LOINC, HPO), sonst einen leeren Code.
Verneinte Befunde nur, wenn sie klinisch relevant sind.

Begründe jedes Urteil in höchstens einem kurzen Satz.
TXT

our $VAL_JUDGE_PROMPT_VERSION = substr(md5_hex(encode('UTF-8', $VAL_JUDGE_SYSTEM)), 0, 10);

sub _val_judge_schema {
    my $enum = sub { { type => 'string', enum => [@_] } };
    my $attr = $enum->(qw(ok wrong missing superfluous na));
    return {
        type => 'object',
        properties => {
            entries => { type => 'array', items => {
                type => 'object',
                properties => {
                    id            => { type => 'string' },
                    concept       => $enum->(qw(ok broader narrower wrong absent wrong_subject)),
                    status        => $enum->(qw(ok negation suspected planned)),
                    side          => $attr,
                    side_correct  => $enum->('', 'R', 'L', 'B', 'none'),
                    date          => $attr,
                    date_correct  => { type => 'string' },
                    value         => $enum->(qw(ok wrong na)),
                    value_correct => { type => 'string' },
                    reason        => { type => 'string' },
                },
                required => [qw(id concept status side side_correct date date_correct value value_correct reason)],
                additionalProperties => \0,
            } },
            missing => { type => 'array', items => {
                type => 'object',
                properties => {
                    domain   => $enum->(@VAL_DOMAINS),
                    label    => { type => 'string' },
                    code     => { type => 'string' },
                    side     => $enum->('', 'R', 'L', 'B'),
                    date     => { type => 'string' },
                    value    => { type => 'string' },
                    unit     => { type => 'string' },
                    excluded => { type => 'boolean' },
                    reason   => { type => 'string' },
                },
                required => [qw(domain label code side date value unit excluded reason)],
                additionalProperties => \0,
            } },
        },
        required => [qw(entries missing)],
        additionalProperties => \0,
    };
}

sub _val_judge_user_message {
    my ($item) = @_;
    my %dom  = (disease => 'Diagnose', phenotype => 'Befund', procedure => 'Eingriff', treatment => 'Medikation', measurement => 'Messwert');
    my %side = (R => 'RA', L => 'LA', B => 'beidseits', '' => 'keine');
    my @lines;
    my $n = 0;
    for my $e (@{ $item->{entries} // [] }) {
        $n++;
        my $val = defined $e->{value} && length $e->{value} ? " | Wert: " . ($e->{comparator} && $e->{comparator} ne '=' ? "$e->{comparator} " : '') .
                  "$e->{value}" . (length($e->{unit} // '') ? " $e->{unit}" : '') : (length($e->{value_text} // '') ? " | Wert: $e->{value_text}" : '');
        push @lines, sprintf('E%d | %s | %s %s | Seite: %s | Datum: %s | %s%s', $n, $dom{ $e->{domain} } // $e->{domain}, $e->{code},
                             $e->{label} // '', $side{ $e->{side} // '' } // $e->{side}, length($e->{date} // '') ? $e->{date} : 'keins',
                             $e->{excluded} ? 'verneint' : 'vorhanden', $val);
    }
    return "Briefdatum: " . ($item->{reference_date} // 'unbekannt') . "\n\n<brief>\n" . ($item->{narrative} // '') . "\n</brief>\n\n" .
           "Extrahierte Einträge (" . scalar(@lines) . "):\n" . (@lines ? join("\n", @lines) : '(keine)') . "\n\n" .
           "Bewerte jeden Eintrag (id = E-Nummer) und nenne fehlende Einträge.";
}

sub _val_pii_hit {
    my $t = shift // '';
    return undef if ($ENV{ONTOTRIAL_JUDGE_PII_GUARD} // '1') eq '0';
    if (my $re = $ENV{ONTOTRIAL_JUDGE_PII_REGEX}) {
        return 'eigene Sperr-Regel' if eval { $t =~ /$re/ };
    }
    return 'Geburtsdatum' if $t =~ /\bgeb(?:oren|\.)\s*(?:am\s*)?\d{1,2}\.\s*\d{1,2}\.\s*\d{2,4}/i;
    return 'Name mit Anrede' if $t =~ /\b(?:Herrn?|Frau)\s+(?!Kolleg|Dr\b|Dr\.|Prof|Doktor|Doctor)[A-ZÄÖÜ][a-zäöüß]{2,}/;
    return undef;
}

sub _val_judge_model { return $ENV{ONTOTRIAL_JUDGE_MODEL} || 'claude-opus-5-5' }

sub _val_judge_providers {
    return [
        { id => 'anthropic', label => 'Claude (externe API)', model => _val_judge_model(), external => 1,
          configured => $ENV{ANTHROPIC_API_KEY} ? 1 : 0 },
        { id => 'local', label => 'lokales Modell', model => $ENV{ONTOTRIAL_JUDGE_LOCAL_MODEL} // '', external => 0,
          configured => $ENV{ONTOTRIAL_JUDGE_LOCAL_MODEL} ? 1 : 0 },
    ];
}

sub _val_judge_provider {
    my $id = shift // '';
    my ($p) = grep { $_->{id} eq $id } @{ _val_judge_providers() };
    return $p;
}

sub _val_judge_call_local {
    my ($item) = @_;
    my $model = $ENV{ONTOTRIAL_JUDGE_LOCAL_MODEL} or die "ONTOTRIAL_JUDGE_LOCAL_MODEL ist nicht gesetzt\n";
    my $cfg   = resolve_llm_config($model);
    my $url   = $ENV{ONTOTRIAL_JUDGE_LOCAL_URL} || $cfg->{endpoint};
    my %hdr   = (%{ $cfg->{headers} // {} });
    $hdr{Authorization} = "Bearer $ENV{ONTOTRIAL_JUDGE_LOCAL_KEY}" if $ENV{ONTOTRIAL_JUDGE_LOCAL_KEY};
    my $ollama = $cfg->{is_ollama} && !$ENV{ONTOTRIAL_JUDGE_LOCAL_URL} ? 1 : ($url =~ m{/api/chat\b} ? 1 : 0);
    my $temp   = $ENV{ONTOTRIAL_JUDGE_LOCAL_TEMPERATURE} // '0';
    my $maxtok = ($ENV{ONTOTRIAL_JUDGE_LOCAL_MAX_TOKENS} || 32000) + 0;
    my @msgs   = ({ role => 'system', content => $VAL_JUDGE_SYSTEM }, { role => 'user', content => _val_judge_user_message($item) });
    my $body = $ollama
        ? { model => $model, messages => \@msgs, format => _val_judge_schema(), stream => Mojo::JSON->false,
            options => { (length $temp ? (temperature => $temp + 0) : ()), num_predict => $maxtok, num_ctx => 65536 } }
        : { model => $model, messages => \@msgs, max_tokens => $maxtok, (length $temp ? (temperature => $temp + 0) : ()),
            response_format => { type => 'json_schema', json_schema => { name => 'validation_judgment', strict => \1, schema => _val_judge_schema() } } };
    $body->{chat_template_kwargs} = { enable_thinking => Mojo::JSON->false }
        if !$ollama && ($ENV{ONTOTRIAL_JUDGE_LOCAL_THINKING} // '1') eq '0';

    my $ua = Mojo::UserAgent->new(connect_timeout => 30, inactivity_timeout => 1800, request_timeout => 1800);
    $ua->proxy->detect;
    my $last = '';
    for my $try (1 .. 3) {
        my $tx  = $ua->post($url => \%hdr => json => $body);
        my $res = $tx->res;
        if (my $err = $tx->error) {
            $last = $err->{code} ? "HTTP $err->{code}: " . substr($res->body // '', 0, 300) : "Verbindung: $err->{message}";
            die "Lokales Modell: $last\n" if ($err->{code} // 0) && $err->{code} < 500 && $err->{code} != 429;
            sleep 10 * $try;
            next;
        }
        my $j = $res->json // {};
        my ($content, $finish, %usage);
        if ($ollama) {
            $content = $j->{message}{content} // '';
            $finish  = ($j->{done_reason} // '') eq 'length' ? 'length' : 'stop';
            %usage   = (input_tokens => $j->{prompt_eval_count} // 0, output_tokens => $j->{eval_count} // 0);
        } else {
            my $ch = $j->{choices}[0] // {};
            $content = $ch->{message}{content} // '';
            $finish  = $ch->{finish_reason} // '';
            %usage   = (input_tokens => $j->{usage}{prompt_tokens} // 0, output_tokens => $j->{usage}{completion_tokens} // 0);
        }
        die "Antwort abgeschnitten (ONTOTRIAL_JUDGE_LOCAL_MAX_TOKENS zu klein)\n" if $finish eq 'length';
        my $out = clean_and_parse_json($content);
        if (ref $out ne 'HASH' && $content =~ /(\{.*\})/s) { $out = clean_and_parse_json($1) }
        die "Antwort des lokalen Modells ist kein gültiges JSON\n" unless ref $out eq 'HASH' && ref $out->{entries} eq 'ARRAY';
        return ($out, \%usage, $model);
    }
    die "Lokales Modell nicht erreichbar ($last)\n";
}

sub _val_judge_call {
    my ($item, $provider) = @_;
    return _val_judge_call_local($item) if ($provider // 'anthropic') eq 'local';
    my $key = $ENV{ANTHROPIC_API_KEY} or die "ANTHROPIC_API_KEY ist nicht gesetzt\n";
    my $model = _val_judge_model();
    my $body = {
        model      => $model,
        max_tokens => ($ENV{ONTOTRIAL_JUDGE_MAX_TOKENS} || 16000) + 0,
        system     => $VAL_JUDGE_SYSTEM,
        messages   => [ { role => 'user', content => _val_judge_user_message($item) } ],
        output_config => { format => { type => 'json_schema', schema => _val_judge_schema() } },
    };
    my $temp = $ENV{ONTOTRIAL_JUDGE_TEMPERATURE} // '';
    $body->{temperature} = $temp + 0 if length $temp;

    my $ua = Mojo::UserAgent->new(connect_timeout => 30, inactivity_timeout => 900, request_timeout => 900);
    $ua->proxy->detect;
    my $url = $ENV{ONTOTRIAL_JUDGE_URL} || 'https://api.anthropic.com/v1/messages';
    my $last = '';
    for my $try (1 .. 5) {
        my $tx  = $ua->post($url => { 'x-api-key' => $key, 'anthropic-version' => '2023-06-01' } => json => $body);
        my $res = $tx->res;
        if (my $err = $tx->error) {
            $last = $err->{code} ? "HTTP $err->{code}: " . substr($res->body // '', 0, 300) : "Verbindung: $err->{message}";
            my $code = $err->{code} // 0;
            die "API-Fehler $last\n" if $code && $code != 429 && $code < 500;
            my $wait = $res->headers->header('retry-after');
            sleep(($wait && $wait =~ /^\d+$/) ? $wait : 10 * $try);
            next;
        }
        my $j = $res->json // {};
        my $stop = $j->{stop_reason} // '';
        die "Antwort abgeschnitten (max_tokens zu klein)\n" if $stop eq 'max_tokens';
        die "Modell hat die Bewertung abgelehnt\n" if $stop eq 'refusal';
        my ($text) = map { $_->{text} } grep { ($_->{type} // '') eq 'text' } @{ $j->{content} // [] };
        my $out = eval { decode_json(encode('UTF-8', $text // '')) };
        die "Antwort ist kein gültiges JSON\n" unless ref $out eq 'HASH';
        return ($out, $j->{usage} // {}, $j->{model} // $model);
    }
    die "API nicht erreichbar ($last)\n";
}

my %VAL_ONT = (disease => 'icd10', phenotype => 'hpo', procedure => 'ops', treatment => 'atc', measurement => 'loinc');

sub _val_norm_code {
    my ($domain, $code) = @_;
    $code //= '';
    $code =~ s/^\s+|\s+$//g;
    return '' unless length $code;
    if ($domain eq 'phenotype') {
        return $code =~ /(\d{1,7})\s*$/ ? sprintf('HP:%07d', $1) : '';
    }
    my %pre = (disease => 'ICD10', procedure => 'OPS', treatment => 'ATC', measurement => 'LOINC');
    $code =~ s/^(?:ICD-?10(?:-GM)?|OPS|ATC|LOINC)\s*:\s*//i;
    $code = uc $code unless $domain eq 'measurement';
    return "$pre{$domain}:$code";
}

# Antwort des Judge in das Bewertungsformat der Ärzte übersetzen
sub _val_ai_convert {
    my ($c, $item, $out) = @_;
    my %by = map { uc($_->{id} // '') => $_ } @{ $out->{entries} // [] };
    my (%j, @missing, $unjudged);
    my $n = 0;
    for my $e (@{ $item->{entries} // [] }) {
        $n++;
        my $a = $by{"E$n"} or do { $unjudged++; next };
        my %x = map { $_ => lc($a->{$_} // '') } qw(concept status side date value);
        $x{side_correct}  = uc($a->{side_correct} // '');
        $x{date_correct}  = $a->{date_correct} // '';
        $x{value_correct} = $a->{value_correct} // '';
        $x{comment}       = $a->{reason} // '';
        if ($x{side_correct} eq 'NONE') {
            $x{side_correct} = '';
            $x{side} = 'superfluous' if $x{side} eq 'wrong' || $x{side} eq 'missing';
        }
        $x{value} = 'na' if $e->{domain} ne 'measurement';
        my $ok = $x{concept} eq 'ok' && $x{status} eq 'ok' && $x{side} =~ /^(?:ok|na)$/ && $x{date} =~ /^(?:ok|na)$/ && $x{value} =~ /^(?:ok|na)$/;
        $x{verdict} = $ok ? 'correct' : 'error';
        $j{ $e->{key} } = \%x;
    }
    for my $m (@{ $out->{missing} // [] }) {
        my $domain = lc($m->{domain} // '');
        next unless $VAL_ONT{$domain} && length($m->{label} // '');
        my $code  = _val_norm_code($domain, $m->{code});
        my $label = length $code ? eval { $c->get_canonical_ontology_label($VAL_ONT{$domain}, $code) } : undef;
        push @missing, {
            missing => 1, domain => $domain, label => $m->{label}, side => uc($m->{side} // ''),
            code => (defined $label ? $code : ''), code_suggested => $code, code_label => $label // '',
            date => _val_date($m->{date}), value => $m->{value} // '', unit => $m->{unit} // '',
            excluded => $m->{excluded} ? 1 : 0, comment => $m->{reason} // '',
        };
    }
    return (\%j, \@missing, $unjudged // 0);
}

# KI-Bewertungen eines Datensatzes: { model => { item_id => row } }
sub _val_ai_rows {
    my ($db, $set_id) = @_;
    my $rows = $db->query(q{SELECT a.* FROM validation_ai_reviews a JOIN validation_items i ON i.id = a.item_id WHERE i.set_id = ?}, $set_id)
                  ->expand->hashes->to_array;
    my %by;
    $by{ $_->{model} }{ $_->{item_id} } = $_ for @$rows;
    return \%by;
}

sub _val_ai_resolution {
    my ($ai) = @_;
    return undef unless $ai && !$ai->{error} && $ai->{judgments};
    return { status => 'ok', source => "KI-Judge ($ai->{model})", reviewer => "KI-Judge ($ai->{model})",
             judgments => $ai->{judgments}, missing => $ai->{missing} // [] };
}

get '/BBB/validation/sets/:id/judge' => sub {
    my $c   = shift;
    my $db  = $c->pg->db;
    my $set = _val_load_set($db, $c->param('id')) or return $c->render(json => { error => 'Datensatz nicht gefunden.' }, status => 404);
    my $models = $db->query(q{
        SELECT a.model, count(*) FILTER (WHERE a.error IS NULL) AS n_ok, count(*) FILTER (WHERE a.error IS NOT NULL) AS n_errors,
               coalesce(sum((a.usage->>'input_tokens')::bigint), 0) AS tokens_in, coalesce(sum((a.usage->>'output_tokens')::bigint), 0) AS tokens_out,
               max(a.created_at) AS last_at
        FROM validation_ai_reviews a JOIN validation_items i ON i.id = a.item_id WHERE i.set_id = ?
        GROUP BY a.model ORDER BY a.model
    }, $set->{id})->hashes->to_array;
    for my $m (@$models) {
        $m->{$_} += 0 for qw(n_ok n_errors tokens_in tokens_out);
        $m->{errors} = $db->query(q{SELECT i.position, a.error FROM validation_ai_reviews a JOIN validation_items i ON i.id = a.item_id
                                    WHERE i.set_id = ? AND a.model = ? AND a.error IS NOT NULL ORDER BY i.position LIMIT 10},
                                  $set->{id}, $m->{model})->hashes->to_array;
    }
    my @running;
    my $jobs = $c->minion->jobs({ tasks => ['validation_judge_task'], states => [qw(inactive active)] });
    while (my $job = $jobs->next) { push @running, $job->{args}[0]{provider} // 'anthropic' if ($job->{args}[0]{set_id} // 0) == $set->{id} }
    my $n_items = $db->query('SELECT count(*) AS n FROM validation_items WHERE set_id = ?', $set->{id})->hash->{n};
    $c->render(json => { providers => _val_judge_providers(), prompt_version => $VAL_JUDGE_PROMPT_VERSION, n_items => $n_items + 0,
                         running => \@running, reference_source => $set->{reference_source}, models => $models });
};

post '/BBB/validation/sets/:id/judge' => sub {
    my $c   = shift;
    my $p   = $c->req->json // {};
    my $db  = $c->pg->db;
    my $set = _val_load_set($db, $c->param('id')) or return $c->render(json => { error => 'Datensatz nicht gefunden.' }, status => 404);
    my $prov = _val_judge_provider($p->{provider} // 'anthropic')
        or return $c->render(json => { error => 'Unbekannter Judge-Anbieter.' }, status => 400);
    return $c->render(json => { error => "$prov->{label} ist nicht konfiguriert." }, status => 409) unless $prov->{configured};
    return $c->render(json => { error => 'Zum Senden der Briefe an die externe API "EXTERN" bestätigen.' }, status => 400)
        if $prov->{external} && ($p->{confirm} // '') ne 'EXTERN';
    my $jobs = $c->minion->jobs({ tasks => ['validation_judge_task'], states => [qw(inactive active)] });
    while (my $job = $jobs->next) {
        my $a = $job->{args}[0] // {};
        return $c->render(json => { error => "Für diesen Datensatz läuft $prov->{label} bereits." }, status => 409)
            if ($a->{set_id} // 0) == $set->{id} && ($a->{provider} // 'anthropic') eq $prov->{id};
    }
    my $id = $c->minion->enqueue(validation_judge_task => [{ set_id => $set->{id}, provider => $prov->{id},
                                                             overwrite => to_bool($p->{overwrite}) ? 1 : 0 }], { attempts => 1 });
    $c->app->log->info("[VALIDATION] KI-Judge für \"$set->{name}\" gestartet (Job $id, $prov->{label}, Modell $prov->{model}).");
    $c->render(json => { ok => 1, job => $id, provider => $prov->{id}, model => $prov->{model} });
};

app->minion->add_task(validation_judge_task => sub {
    my ($job, $payload) = @_;
    my $app   = $job->app;
    my $db    = $app->pg->db;
    my $set   = _val_load_set($db, $payload->{set_id}) or return $job->fail('Datensatz fehlt');
    my $items = _val_load_items($db, $set->{id});
    my $prov  = _val_judge_provider($payload->{provider} // 'anthropic') or return $job->fail('Unbekannter Anbieter');
    my $have  = _val_ai_rows($db, $set->{id})->{ $prov->{model} } // {};
    my $guard = $prov->{external} ? 1 : (($ENV{ONTOTRIAL_JUDGE_LOCAL_PII_GUARD} // '0') ne '0');
    my $task  = "validation_judge_$set->{id}";
    my ($k, $n, $done, $failed, $skipped) = (0, scalar @$items, 0, 0, 0);

    for my $i (@$items) {
        $k++;
        if ($have->{ $i->{id} } && !$have->{ $i->{id} }{error} && !$payload->{overwrite}) { $skipped++; next }
        my ($out, $usage, $model, $err);
        if (my $why = $guard ? _val_pii_hit($i->{narrative}) : undef) {
            $err = "nicht gesendet: Brief enthält möglicherweise identifizierende Angaben ($why)";
        } else {
            ($out, $usage, $model) = eval { _val_judge_call($i, $prov->{id}) };
            $err = $@ =~ s/\s+$//r if $@;
        }
        my ($judg, $missing, $unjudged) = $out ? _val_ai_convert($app, $i, $out) : ({}, [], 0);
        $err //= "$unjudged Einträge ohne Urteil" if $out && $unjudged;
        $db->query(q{INSERT INTO validation_ai_reviews (item_id, model, prompt_version, judgments, missing, raw, usage, error)
                     VALUES (?, ?, ?, ?::jsonb, ?::jsonb, ?::jsonb, ?::jsonb, ?)
                     ON CONFLICT (item_id, model) DO UPDATE SET prompt_version = EXCLUDED.prompt_version,
                       judgments = EXCLUDED.judgments, missing = EXCLUDED.missing, raw = EXCLUDED.raw, usage = EXCLUDED.usage,
                       error = EXCLUDED.error, created_at = now()},
                   $i->{id}, $prov->{model}, $VAL_JUDGE_PROMPT_VERSION, to_json($judg), to_json($missing),
                   $out ? to_json($out) : undef, to_json($usage // {}), $err);
        $err ? $failed++ : $done++;
        my $pct = int(100 * $k / ($n || 1));
        $job->note(progress => $pct, done => $done, failed => $failed);
        $app->notify_task_progress($task, 'running', $pct, "KI-Judge ($prov->{model}): Brief $k von $n");
    }
    $app->notify_task_progress($task, 'finished', 100, 'KI-Judge abgeschlossen');
    $job->finish({ done => $done, failed => $failed, skipped => $skipped });
});

# Vergleich KI-Judge gegen die aufgelöste ärztliche Bewertung
sub _val_judge_agreement {
    my ($items, $revs, $ai) = @_;
    my (%pairs, %conf, %miss, %vig);
    my $n_items = 0;
    for my $i (@$items) {
        my $a = $ai->{ $i->{id} };
        next unless $a && !$a->{error};
        my $res = _val_resolve($i, $revs->{ $i->{id} } // []);
        next unless $res->{status} eq 'ok';
        $n_items++;
        my %inj = map { $_->{key} => 1 } @{ $i->{injected} // [] };
        for my $e (@{ $i->{entries} }) {
            next if $inj{ $e->{key} };
            my ($h, $k) = ($res->{judgments}{ $e->{key} }, $a->{judgments}{ $e->{key} });
            next unless $h && $k && ($h->{verdict} // '') =~ /^(?:correct|error)$/;
            my ($hc, $kc) = (($h->{verdict} eq 'correct') ? 1 : 0, (($k->{verdict} // '') eq 'correct') ? 1 : 0);
            push @{ $pairs{overall} }, [ $hc, $kc ];
            $conf{ $hc ? ($kc ? 'both_correct' : 'judge_only_error') : ($kc ? 'judge_missed_error' : 'both_error') }++;
            push @{ $pairs{$_} }, [ $h->{$_} // 'ok', $k->{$_} // 'ok' ] for qw(concept status side date);
        }
        my %hm = map { _val_code($_->{code}) => 1 } grep { length($_->{code} // '') } @{ $res->{missing} // [] };
        my %km = map { _val_code($_->{code}) => 1 } grep { length($_->{code} // '') } @{ $a->{missing} // [] };
        $miss{both}       += scalar grep { $km{$_} } keys %hm;
        $miss{human_only} += scalar grep { !$km{$_} } keys %hm;
        $miss{judge_only} += scalar grep { !$hm{$_} } keys %km;
    }
    for my $i (@$items) {
        my $a = $ai->{ $i->{id} };
        next unless $a && !$a->{error};
        my %h = %{ $a->{judgments} // {} };
        my $m = 0;
        $h{ 'missing:' . $m++ } = $_ for @{ $a->{missing} // [] };
        for my $inj (@{ $i->{injected} // [] }) {
            $vig{ $inj->{type} }{n}++;
            $vig{ $inj->{type} }{detected} += _val_detected($inj, \%h);
        }
    }
    my $err_h = ($conf{both_error} // 0) + ($conf{judge_missed_error} // 0);
    my $ok_h  = ($conf{both_correct} // 0) + ($conf{judge_only_error} // 0);
    return {
        n_items     => $n_items,
        kappa       => { map { $_ => _val_kappa($pairs{$_}) } keys %pairs },
        confusion   => \%conf,
        sensitivity => _val_ratio($conf{both_error} // 0, $err_h),
        specificity => _val_ratio($conf{both_correct} // 0, $ok_h),
        missing     => \%miss,
        vigilance   => { map { $_ => { %{ $vig{$_} }, rate => _val_ratio($vig{$_}{detected} // 0, $vig{$_}{n}) } } keys %vig },
    };
}


# =========================================================
# GENERIC DB REST CRUD ENDPOINTS
# =========================================================

get '/BBB/:table/:col/:pk' => [col => qr/[a-z_0-9\s]+/, pk => qr/[a-z0-9\s\-_\.]+/i] => sub {
    my $self  = shift;
    my $table = resolve_table_name($self->param('table'));
    my $pk    = $self->param('pk');
    my $col   = $self->param('col');

    # SICHERUNG GEGEN ERROR: column "1" does not exist
    # Wenn Fireside '1/1' schickt, soll Postgres kein WHERE "1" = 1 ausführen,
    # sondern einfach alle Datensätze der Tabelle selektieren.
    if ($col eq '1' && $pk eq '1') {
        return $self->render(json => $self->pg->db->select($table, ['*'])->hashes->to_array);
    }

    $self->render(json => $self->pg->db->select($table, ['*'], {$col => $pk})->hashes->to_array);
};

get '/BBB/:table' => sub {
    my $self  = shift;
    my $table = resolve_table_name($self->param('table'));
    $self->render(json => $self->pg->db->select($table, ['*'])->hashes->to_array);
};

post '/BBB/:table/:pk' => sub {
    my $self    = shift;
    my $table   = $self->param('table');
    my $pk      = $self->param('pk');
    my $jsonR   = eval { decode_json( $self->req->body ) } // {};

    # Restore default 'New' handling for generic tables and provide 'New Patient' pseudonym for candidates
    if ($table eq 'candidates') {
        $jsonR->{pseudonym} //= delete $jsonR->{name} // 'New Patient';
    } else {
        $jsonR->{name} //= 'New';
    }

    # Delete primary key from insert payload if null/empty so PostgreSQL DEFAULT nextval(...) handles it
    delete $jsonR->{$pk} if exists $jsonR->{$pk} && (!defined $jsonR->{$pk} || $jsonR->{$pk} eq '');

    # Sanitize payload: filter out keys that are not actual columns in the target table
    eval {
        my $clean_table = resolve_table_name($table);
        $clean_table =~ s/^public\.//;
        my $cols = $self->pg->db->query(
        "SELECT column_name FROM information_schema.columns WHERE table_name = ?", $clean_table
        )->flatten->to_array;
        if (@$cols) {
            my %valid = map { $_ => 1 } @$cols;
            foreach my $k (keys %$jsonR) {
                delete $jsonR->{$k} unless $valid{$k};
            }
        }
    };

    my $valpk;
    eval {
        my $db_table = resolve_table_name($table);
        my $res = $self->pg->db->insert($db_table, $jsonR, {returning => $pk})->hash;
        $valpk = $res->{$pk} if $res;
    };
    my $err = $@ // $DBI::errstr;

    if ($valpk) {
        $jsonR->{$pk} = $valpk;
        $jsonR->{pk}  = $valpk;
        $jsonR->{err} = undef;
        $self->notify_change($table, $valpk, 'INSERT', $jsonR);
    } else {
        $jsonR->{err} = $err;
    }

    $self->render( json => $jsonR );
};

patch '/BBB/:table/:pk/:key' => [key => qr/\d+/] => sub {
    my $self  = shift;
    my $table_raw = $self->param('table');
    my $table = resolve_table_name($table_raw);
    my $pk    = $self->param('pk');
    my $key   = $self->param('key');
    my $jsonR = decode_json($self->req->body || '{}');

    eval { $self->pg->db->update($table, $jsonR, {$pk => $key}); };
    my $err = $@ // $DBI::errstr;
    $self->notify_change($table_raw, $key, 'UPDATE', $jsonR);
    $self->render(json => { err => $err });
};

del '/BBB/:table/:pk/:key' => [key => qr/\d+/] => sub {
    my $self  = shift;
    my $table_raw = $self->param('table');
    my $table = resolve_table_name($table_raw);
    my $pk    = $self->param('pk');
    my $key   = $self->param('key');

    eval { $self->pg->db->delete($table, {$pk => $key}); };
    my $err = $@ // $DBI::errstr;
    $self->notify_change($table_raw, $key, 'DELETE', {});
    $self->render(json => { err => $err });
};

# =========================================================
# APPLICATION STARTUP
# =========================================================
app->config(hypnotoad => { listen => ['http://*:4007'], workers => 3, heartbeat_timeout => 120, inactivity_timeout => 120 });
app->start;
