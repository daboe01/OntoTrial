#!/usr/bin/env perl

# OntoTrial Backend - Step-by-Step Extraction & Deduplicated Disjunctive Assembly Engine
# + FHIR Eye Normalization (Study Eye -> Right Eye, Fellow Eye -> Left Eye)
# TODO: use a BERT model to validate idems after union ensemble (idea)
# TODO: backport of event date (or use observed date) for PhenoViewer to work properly
# TODO: support orphacodes

use utf8;
use Mojolicious::Lite;
use Mojo::Pg;
use Data::Dumper;
use Mojo::UserAgent;
use Apache::Session::File;
use Encode qw(decode_utf8 is_utf8 encode decode);
use Mojo::JSON qw(decode_json encode_json from_json to_json);
use Mojo::Loader qw(data_section);
use POSIX qw(strftime);
use DateTime;
use Time::HiRes qw(gettimeofday tv_interval);
use Text::CSV;

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
helper pg => sub {
    state $pg = Mojo::Pg->new('postgresql://postgres:postgres@localhost/hpo')
};


plugin Minion => {Pg => 'postgresql://postgres:postgres@localhost/hpo'};

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
my $api_key      = $ENV{VLLM_API_KEY}   // 'ap-';
my $endpoint     = $ENV{VLLM_ENDPOINT}  // 'https://inference-api.aipier.kn.uniklinik-freiburg.de/v1/chat/completions';
my $model        = $ENV{VLLM_MODEL}     // 'gpt-oss-120b';

# Configuration for Local Testing / LLM Provider Selection
my $llm_provider = $ENV{LLM_PROVIDER}   // 'vllm'; # Options: 'vllm' or 'ollama'
my $ollama_model = $ENV{OLLAMA_MODEL}   // 'gemma4:31b-mlx';

my $patchbay_url = $ENV{PATCHBAY_URL}   // 'http://localhost:3036';

# Concurrency throttling configuration for Patchbay
my $max_patchbay_concurrency = 1;
my $active_patchbay_calls    = 0;
my @patchbay_queue;

use constant {
    LLM_HPO_RETRIEVAL_PROMPT_ID          => 51,
    LLM_HPO_MODIFIER_RETRIEVAL_PROMPT_ID => 52,
    LLM_ICD10_RETRIEVAL_PROMPT_ID        => 64,
    LLM_OPS_RETRIEVAL_PROMPT_ID          => 65,
    LLM_ATC_RETRIEVAL_PROMPT_ID          => 66,
    LLM_LOINC_RETRIEVAL_PROMPT_ID        => 69,
};

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
                    demographic_value => {
                        type => 'string',
                        description => 'Raw numerical threshold or constraint value (e.g., ">= 18", "< 3 mm", "FEMALE", "MALE_OR_FEMALE", "<= 180 days")'
                    }
                },
                required => ['verbatim_text', 'canonical_term', 'event_date', 'is_exclusion', 'combination_method', 'disjunction_group_id', 'domain', 'laterality', 'has_modifiers', 'demographic_type', 'demographic_value'],
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

    # Historische Datumsangaben & Vorvisus-Werte abschneiden
    $input =~ s/\b(?:0?[1-9]|1[0-2])[\/\.](?:19|20)?\d{2}\s*[:=]\s*(?:0[\.,]\d+|1[\.,]\d+|[1-6]\/\d+)\b//gi;
    $input =~ s/\bBrillenpass.*$//gi;
    $input =~ s/\(\s*(?:(?:0?[1-9]|1[0-2])[\/\.](?:19|20)\d{2}|(?:19|20)\d{2}|am\b|im\b|in\s+(?:19|20)\d{2}|zuletzt|früher|vorvisus|vor\s+\d+|brillenpass).*?\)//gi;

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
    1 while $clean_for_visus =~ s/\((?:[^()]+|(?R))*\)//g;

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

    return undef unless defined $max_visus || defined $sph;

    # Korrekturstatus sauber differenzieren
    my $is_own_glasses = ($clean_for_visus =~ /\b(?:eB|m\.?e\.?B|eigene\s+brille)\b/i) ? 1 : 0;
    my $is_corrected   = 0;

    if (defined $sph || $clean_for_visus =~ /\b(?:cc|mit\s+korrektur)\b/i) {
        $is_corrected = 1; # Bestkorrigiert mit Refraktion / Gläsern
    } elsif ($clean_for_visus =~ /\bsc\b|\bohne\s+korrektur\b/i && !$is_own_glasses) {
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
        is_best_corrected    => $is_corrected,
        is_own_glasses       => $is_own_glasses,
        sphere               => $sph,
        cylinder             => $cyl,
        axis                 => $axis,
        spherical_equivalent => $sph_eq,
    };
}


# =========================================================================
# OPHTHALMOLOGY LOINC MEASUREMENT BUILDER MIT LOGS
# =========================================================================
sub build_ophthalmic_loinc_measurements {
    my ($parsed_ref, $laterality, $ref_date) = @_;
    return () unless ref $parsed_ref eq 'HASH';

    my $lat = lc($laterality // 'none');
    my $is_left  = ($lat eq 'left'  || $lat eq 'os' || $lat eq 'la');
    my $is_right = ($lat eq 'right' || $lat eq 'od' || $lat eq 'ra');

    my $lat_obj = $is_left  ? { id => "HP:0012835", label => "Left" }
                : $is_right ? { id => "HP:0012834", label => "Right" }
                : undef;

    my @measurements;

    # 1. Visual Acuity (Bestkorrigiert, Eigene Brille oder Unkorrigiert)
    if (defined $parsed_ref->{visus_value}) {
        my ($loinc_id, $loinc_label);
        my @extra_mods;

        if ($parsed_ref->{is_own_glasses}) {
            $loinc_id    = "LOINC:28637-7";
            $loinc_label = $is_left ? "Visual acuity with own glasses Left eye"
                         : ($is_right ? "Visual acuity with own glasses Right eye" : "Visual acuity with own glasses");
            push @extra_mods, { id => "LP7753-9", label => "with own glasses (eB)" };
        } elsif ($parsed_ref->{is_best_corrected}) {
            $loinc_id    = $is_left ? "LOINC:65897-1" : ($is_right ? "LOINC:65893-0" : "LOINC:28637-7");
            $loinc_label = $is_left ? "Visual acuity best corrected Left eye"
                         : ($is_right ? "Visual acuity best corrected Right eye" : "Visual acuity best corrected");
        } else {
            $loinc_id    = $is_left ? "LOINC:65896-3" : ($is_right ? "LOINC:65892-2" : "LOINC:28637-7");
            $loinc_label = $is_left ? "Visual acuity uncorrected Left eye"
                         : ($is_right ? "Visual acuity uncorrected Right eye" : "Visual acuity uncorrected");
        }

        my @mods = ({ id => "LP7753-9", label => "Measurement: = $parsed_ref->{visus_value} decimal" });
        push @mods, @extra_mods;
        push @mods, $lat_obj if $lat_obj;

        push @measurements, {
            assay => { id => $loinc_id, label => $loinc_label },
            value => { quantity => { comparator => '=', value => $parsed_ref->{visus_value}, unit => { label => "decimal" } } },
            modifiers => \@mods,
            ($ref_date ? (timeOfCollection => { timestamp => $ref_date }) : ())
        };
    }

    # 2. Sphere
    if (defined $parsed_ref->{sphere}) {
        my $loinc_id    = $is_left ? "LOINC:65891-4" : "LOINC:65890-6";
        my $loinc_label = $is_left ? "Spherical power [Inverse Length] Left eye" : "Spherical power [Inverse Length] Right eye";
        my @mods = ({ id => "LP7753-9", label => "Measurement: = $parsed_ref->{sphere} [diop]" });
        push @mods, $lat_obj if $lat_obj;

        push @measurements, {
            assay => { id => $loinc_id, label => $loinc_label },
            value => { quantity => { comparator => '=', value => $parsed_ref->{sphere}, unit => { label => "diopter" } } },
            modifiers => \@mods,
            ($ref_date ? (timeOfCollection => { timestamp => $ref_date }) : ())
        };
    }

    # 3. Cylinder
    if (defined $parsed_ref->{cylinder}) {
        my $loinc_id    = $is_left ? "LOINC:65895-5" : "LOINC:65894-8";
        my $loinc_label = $is_left ? "Cylinder power [Inverse Length] Left eye" : "Cylinder power [Inverse Length] Right eye";
        my @mods = ({ id => "LP7753-9", label => "Measurement: = $parsed_ref->{cylinder} [diop]" });
        push @mods, $lat_obj if $lat_obj;

        push @measurements, {
            assay => { id => $loinc_id, label => $loinc_label },
            value => { quantity => { comparator => '=', value => $parsed_ref->{cylinder}, unit => { label => "diopter" } } },
            modifiers => \@mods,
            ($ref_date ? (timeOfCollection => { timestamp => $ref_date }) : ())
        };
    }

    # 4. Axis
    if (defined $parsed_ref->{axis}) {
        my $loinc_id    = $is_left ? "LOINC:65899-7" : "LOINC:65898-9";
        my $loinc_label = $is_left ? "Cylinder axis [Angle] Left eye" : "Cylinder axis [Angle] Right eye";
        my @mods = ({ id => "LP7753-9", label => "Measurement: = $parsed_ref->{axis} deg" });
        push @mods, $lat_obj if $lat_obj;

        push @measurements, {
            assay => { id => $loinc_id, label => $loinc_label },
            value => { quantity => { comparator => '=', value => $parsed_ref->{axis}, unit => { label => "deg" } } },
            modifiers => \@mods,
            ($ref_date ? (timeOfCollection => { timestamp => $ref_date }) : ())
        };
    }

    # 5. Spherical Equivalent
    if (defined $parsed_ref->{spherical_equivalent}) {
        my $loinc_id    = $is_left ? "LOINC:76588-3" : "LOINC:76587-5";
        my $loinc_label = $is_left ? "Spherical equivalent.refraction [Diopters] Left eye" : "Spherical equivalent.refraction [Diopters] Right eye";
        my @mods = ({ id => "LP7753-9", label => "Measurement: = $parsed_ref->{spherical_equivalent} [diop]" });
        push @mods, $lat_obj if $lat_obj;

        push @measurements, {
            assay => { id => $loinc_id, label => $loinc_label },
            value => { quantity => { comparator => '=', value => $parsed_ref->{spherical_equivalent}, unit => { label => "diopter" } } },
            modifiers => \@mods,
            ($ref_date ? (timeOfCollection => { timestamp => $ref_date }) : ())
        };
    }

    return @measurements;
}

# =========================================================================
# QUANTITATIVE CONSTRAINT PARSER (OPHTHALMIC, LABORATORY & CLINICAL METRICS)
# =========================================================================
sub parse_quantitative_constraint {
    my ($text) = @_;
    return undef unless defined $text && $text ne '';

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
    if ($text =~ /\b(?:visus|sehschärfe|visual\s*acuity|aufnahmevisus|entlassvisus|sc\b|cc\b|hbw\b|lsp\b|lsw\b|nulla\s*lux|handbewegung|fingerzählen)\b/i) {
        my $parsed_eye = extract_visus_and_refraction($text);
        if ($parsed_eye && defined $parsed_eye->{visus_value}) {
            my $comp = '=';
            $comp = '>=' if $text =~ /(?:at least|mindestens|≥|>|or better|besser)/i;
            $comp = '<=' if $text =~ /(?:at most|maximal|≤|<|or worse|schlechter)/i;

            return {
                comparator => $comp,
                value      => $parsed_eye->{visus_value},
                unit       => 'decimal',
                formatted  => "$comp $parsed_eye->{visus_value} decimal"
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

    # Bilateraler BMO-Area / OCT-Flächen-Intercept (z. B. "BMO-Area: 1,49/1,83 mm²")
    if ($text =~ /\b(?:bmo[- ]?(?:area|fl[äa]che)?|fl[äa]che)\s*[:=]?\s*(\d+(?:[\.,]\d+)?)\s*[\/;]\s*(\d+(?:[\.,]\d+)?)\s*(?:mm[²2])?\b/i) {
        my ($bmo_r, $bmo_l) = ($1 + 0.0, $2 + 0.0);
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
    return "ICD10:U99" unless $raw_id;
    $raw_id =~ s/^\s+//; $raw_id =~ s/\s+$//;
    $raw_id =~ s/^icd10:\s*//i;

    # Trailing .- oder . entfernen (z. B. L82.- -> L82)
    $raw_id =~ s/[\.\-]+$//;

    # Bereinigt freiburg-spezifische codes fuer seltene erkrankungen wie "D33.3A0" -> "D33.3"
    $raw_id =~ s/^([A-Z]\d{2}(?:\.\d{1,2})?)[A-Z][A-Z0-9]*$/$1/i;

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
    if ($raw_id =~ /^loinc:(.+)$/i) { return "LOINC:" . uc($1); }
    if ($raw_id !~ /^loinc/i) { return "LOINC:" . uc($raw_id); }
    return uc($raw_id);
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
                description => "The most specific concise 1-4 word search query in $target_language."
            }
        },
        required => ['detected_language', 'query'],
        additionalProperties => \0
    };

    my $llm_cfg         = resolve_llm_config($client_model);
    my $active_model    = $llm_cfg->{model};
    my $active_endpoint = $llm_cfg->{endpoint};
    my $headers         = $llm_cfg->{headers};
    my $is_local        = $llm_cfg->{is_ollama};

    my $api_payload;
    
    if ($is_local) {
        $api_payload = {
            model    => $active_model,
            messages => [
                { role => 'system', content => $sys_prompt },
                { role => 'user',   content => $user_prompt }
            ],
            format   => $translation_schema,
            stream   => Mojo::JSON->false,
            options  => {
                temperature    => 0.0,
                repeat_penalty => 1.15,
                repeat_last_n  => 512,
                num_predict    => 512,
            }
        };
    } else {
        $api_payload = {
            model       => $active_model,
            messages    => [
                { role => 'system', content => $sys_prompt },
                { role => 'user',   content => $user_prompt }
            ],
            temperature => 0.0,
            response_format => {
                type => 'json_schema',
                json_schema => {
                    name => "query_language_translation",
                    strict => \1,
                    schema => $translation_schema
                }
            }
        };
    }
    
    return $ua_fast->post_p($active_endpoint => $headers => json => $api_payload)->then(sub {
        my $tx = shift;
        if ($tx->result && $tx->result->is_success) {
            my $raw_content = $is_local
                ? ($tx->result->json('/message/content') // '')
                : ($tx->result->json('/choices/0/message/content') // '');

            my $data = clean_and_parse_json($raw_content);
            if (ref $data eq 'HASH' && defined $data->{query} && length($data->{query}) > 0) {
                my $clean_query = $data->{query};
                my $det_lang    = lc($data->{detected_language} // 'unknown');

                $clean_query =~ s/<think>.*?<\/think>//gs;
                $clean_query =~ s/^\s*["'\`\:\-\>\#\*\.]+|["'\`\.]+\s*$//g;
                $clean_query =~ s/\s+/ /g;
                $clean_query =~ s/^\s+|\s+$//g;

                if (length($clean_query) > 1) {
                    $self->app->log->info("[QUERY TRANSLATION] ($domain) Detected: '$det_lang' -> Target: '$target_language' | '$verbatim_text' -> '$clean_query'");
                    return $clean_query;
                }
            }
        }
        return $fallback;
    })->catch(sub {
        return $fallback;
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
                "SELECT pattern, code, label FROM public.ontology_intercepts WHERE domain = ? AND active = TRUE ORDER BY priority ASC, id ASC",
                $domain
            )->hashes->to_array;
            $cache->{$domain} = $rows // [];
            $last_fetch->{$domain} = $now;
        };
        if ($@) {
            $self->app->log->error("[INTERCEPT DB ERROR] Failed to load intercepts for domain '$domain': $@");
        }
    }
    return $cache->{$domain} // [];
};

helper check_database_intercept => sub {
    my ($self, $domain, $text) = @_;
    return undef unless defined $text && length($text);

    my $intercepts = $self->get_domain_intercepts($domain);
    for my $rule (@$intercepts) {
        my $pattern = $rule->{pattern};
        next unless defined $pattern && length($pattern);

        # Safe UTF-8 aware regex evaluation against input text
        my $matched = eval { $text =~ qr/$pattern/i };
        if ($@) {
            $self->app->log->warn("[INVALID REGEX IN DB] Domain: '$domain', Pattern: '$pattern' - $@");
            next;
        }

        if ($matched) {
            return {
                id    => $rule->{code},
                label => $rule->{label}
            };
        }
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

    # Schutz: Wenn ein Befund aus VAA/Lid/Wunde stammt, darf er NICHT zur Netzhaut werden,
    # es sei denn, im Kriterium selbst steht explizit Netzhaut/Fundus/Makula/OCT.
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
                # Signifikante Wörter aus dem Originaltext prüfen
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

        # Ophthalmo-Sicherheitsnetz:
        # "Neovaskularisation" im Augenbericht ist IMMER retinal, solange NICHT die Hornhaut/Limbus genannt ist:
        if ($term =~ /\b(?:neovaskularisation|neovascularization|neovask)\b/i && $combined !~ /\b(?:cornea|hornhaut|limbus|pannus)\b/i) {
            $is_retina = 1;
        }
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
    }

    # ---------------------------------------------------------------------
    # 2. AUSWERTUNG: NETZHAUT / MAKULA / OCT / FAG (RETINA)
    # ---------------------------------------------------------------------
    if ($is_retina) {
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
        if ($term =~ /\b(?:zentrale\s+|alte\s+|pigmentierte\s+)?narbe\w*\b/i && $combined !~ /\b(?:cornea|hornhaut|lid|bindehaut)\b/i) {
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
    my ($self, $term, $is_modifier, $doc_lang) = @_;
    return Mojo::Promise->resolve(undef) unless defined $term && length($term);
    return Mojo::Promise->resolve(undef) if $term =~ /unknown/i;

    # 1. Check auf Originalbegriff
    if (my $hit = $self->check_database_intercept('hpo', $term)) {
        $self->app->log->info("[HPO DB INTERCEPT] '$term' -> $hit->{id} ($hit->{label})");
        return Mojo::Promise->resolve($hit);
    }

    $doc_lang = lc($doc_lang // 'de');

    my $p_query = ($doc_lang eq 'en')
        ? Mojo::Promise->resolve(clean_term_for_vector_mapping($term))
        : $self->normalize_criterion_for_retrieval_async($term, 'hpo');

    return $p_query->then(sub {
        my $clean_query = shift;

        # 2. Check auf übersetzten / bereinigten Suchbegriff
        if (my $hit = $self->check_database_intercept('hpo', $clean_query)) {
            $self->app->log->info("[HPO DB INTERCEPT] '$clean_query' -> $hit->{id} ($hit->{label})");
            return $hit;
        }

        my $execute_call = sub {
            my $prompt_id = $is_modifier ? LLM_HPO_MODIFIER_RETRIEVAL_PROMPT_ID : LLM_HPO_RETRIEVAL_PROMPT_ID;
            my $url_retrieve = "$patchbay_url/LLM/run_stateless/" . $prompt_id;

            my $encoded_payload = encode('UTF-8', $clean_query);

            return $ua_fast->post_p(
                $url_retrieve => { 'Content-Type' => 'text/plain; charset=UTF-8', Accept => '*/*' } => $encoded_payload
            )->then(sub {
                my $tx = shift;
                if ($tx->result && $tx->result->is_success) {
                    my $body = $tx->result->body;
                    my $matches = eval { decode_json($body) } // eval { from_json(decode('UTF-8', $body)) } // [];
                    if (ref $matches eq 'ARRAY' && @$matches && defined $matches->[0]->{label}) {
                        my $raw_code      = $matches->[0]->{label};
                        my $matched_id    = $self->format_hpo_id($raw_code);
                        my $db_label      = $self->get_canonical_ontology_label('hpo', $raw_code);
                        my $matched_label = $db_label // $matches->[0]->{payload} // $term;

                        $self->app->log->info("[HPO RETRIEVAL] '$clean_query' -> $matched_id ($matched_label)");
                        return { id => $matched_id, label => $matched_label };
                    }
                }
                return { id => "HP:0000118", label => $term };
            })->catch(sub { return { id => "HP:0000118", label => $term }; });
        };
        return $self->enqueue_patchbay_call($execute_call, $clean_query);
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

# =========================================================================
# ICD-10 ASYNCHRONOUS MAPPING ENGINE MIT DB-INTERCEPT & ATC-ALLERGIE-FIX
# =========================================================================
helper map_to_icd10_async => sub {
    my ($self, $verbatim_term, $canonical_term, $doc_lang) = @_;

    # Fallback bei flexibler Parameterübergabe
    if (!defined $doc_lang && defined $canonical_term && $canonical_term =~ /^(?:de|en|other)$/i) {
        $doc_lang       = $canonical_term;
        $canonical_term = undef;
    }
    $doc_lang = lc($doc_lang // 'de');

    return Mojo::Promise->resolve(undef) unless defined $verbatim_term && length($verbatim_term);

    # 1. Allergie-/Unverträglichkeits-Erkennung
    my $is_allergy = (($verbatim_term =~ /allerg|unvertr|intoler/i) ||
                      (defined $canonical_term && $canonical_term =~ /allerg|unvertr|intoler/i)) ? 1 : 0;

    my $primary_term  = ($is_allergy && defined $canonical_term && length($canonical_term) > 1)
                      ? $canonical_term
                      : $verbatim_term;
    my $fallback_term = ($primary_term eq $verbatim_term) ? $canonical_term : $verbatim_term;

    # --- HILFSFUNKTION: ATC-ANREICHERUNG FÜR Z88.8 ALLERGIEN ---
    my $apply_allergy_atc_override = sub {
        my ($res) = @_;
        return Mojo::Promise->resolve($res) unless $res && $res->{id};

        if ($is_allergy) {
            my $is_specific_code = ($res->{id} =~ /^ICD10:Z88\.0/i); # Z88.0 = Penicillin hat eigenen Code

            my $is_unspecific = (!$is_specific_code) && (
                $res->{id} =~ /^ICD10:(?:T88|T78|Z88\.8|Z88\.9|Z88$)/i ||
                $res->{id} =~ /^ICD10:Z88\.[1-9]/i
            );

            if ($is_unspecific) {
                my $extract_substance = sub {
                    my ($t) = @_;
                    return '' unless defined $t && length($t);
                    my $s = $t;
                    $s =~ s/[-_]/ /g;
                    $s =~ s/\b(?:allergie\s*(?:gegen|auf|g\/?g)?|unvertr(?:ä|a)glichkeit\s*(?:gegen|auf)?|intoleranz\s*(?:gegen|auf)?|anaphylaktische\s*reaktion\s*(?:auf|nach)?|anaphylaxie\s*(?:auf|nach|gegen)?|überempfindlichkeit\s*(?:gegen|auf)?)\s*:\s*/ /gi;
                    $s =~ s/\b(?:allergie\s*(?:gegen|auf|g\/?g)?|unvertr(?:ä|a)glichkeit\s*(?:gegen|auf)?|intoleranz\s*(?:gegen|auf)?|anaphylaktische\s*reaktion\s*(?:auf|nach)?|anaphylaxie\s*(?:auf|nach|gegen)?|überempfindlichkeit\s*(?:gegen|auf)?)\b/ /gi;
                    $s =~ s/\b(?:in\s+der\s+eigenanamnese|eigenanamnese|anamnestisch|bekannte?r?s?)\b/ /gi;
                    $s =~ s/\b(?:i\.?\s*v\.?|oral|intravenös(?:e)?|therapie|gabe|behandlung|medikation|arzneimittel|medikament|präparat|tabletten?|tropfen|kapseln?|infusion)\b/ /gi;
                    $s =~ s/[^\p{L}\p{N}\s]+//g;
                    $s =~ s/\s+/ /g;
                    $s =~ s/^\s+|\s+$//g;
                    return $s;
                };

                my $substance = $extract_substance->($canonical_term);
                $substance = $extract_substance->($verbatim_term) unless length($substance) > 2;

                if (length($substance) > 2) {
                    return $self->map_to_atc_async($substance, $doc_lang)->then(sub {
                        my $atc_hit = shift;
                        my $klartext = (uc($substance) eq $substance) ? $substance : ucfirst(lc($substance));

                        if ($atc_hit && $atc_hit->{id} && $atc_hit->{id} ne 'ATC:V03AX') {
                            $self->app->log->info("[ICD10 DRUG ALLERGY OVERRIDE] '$substance' -> ICD10:Z88.8 ($atc_hit->{id} ($klartext))");
                            return {
                                id    => 'ICD10:Z88.8',
                                label => "$atc_hit->{id} ($klartext)"
                            };
                        } else {
                            $self->app->log->info("[ICD10 DRUG ALLERGY OVERRIDE] '$substance' -> ICD10:Z88.8 (Allergie gegen $klartext)");
                            return {
                                id    => 'ICD10:Z88.8',
                                label => "Allergie gegen $klartext"
                            };
                        }
                    });
                }
            }
        }
        return Mojo::Promise->resolve($res);
    };

    # 2. DB-Intercepts prüfen (JETZT MIT ATC-ANREICHERUNG BEI ALLERGIEN!)
    for my $cand ($verbatim_term, $primary_term, $canonical_term) {
        next unless defined $cand && length($cand);
        my $clean = lc(clean_term_for_vector_mapping($cand));
        if (my $hit = $self->check_database_intercept('icd10', $clean) || $self->check_database_intercept('icd10', $cand)) {
            $self->app->log->info("[ICD10 DB INTERCEPT] '$cand' -> $hit->{id} ($hit->{label})");
            # Wenn es eine Allergie ist, nicht blind abbrechen, sondern ATC-Code anhängen!
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

    my $fetch_match = sub {
        my ($q) = @_;
        my $call = sub {
            my $url = "$patchbay_url/LLM/run_stateless/" . LLM_ICD10_RETRIEVAL_PROMPT_ID;
            my $payload = Encode::encode('UTF-8', $q);
            return $ua_fast->post_p(
                $url => { 'Content-Type' => 'text/plain; charset=UTF-8', Accept => '*/*' } => $payload
            )->then(sub {
                my $tx = shift;
                if ($tx->result && $tx->result->is_success) {
                    my $body = $tx->result->body;
                    my $matches = eval { decode_json($body) } // eval { from_json(decode('UTF-8', $body)) } // [];
                    return $matches->[0] if ref $matches eq 'ARRAY' && @$matches;
                }
                return undef;
            });
        };
        return $self->enqueue_patchbay_call($call, $q);
    };

    # 4. Vektorsuche mit Fallback und abschließender Allergie-Anreicherung
    return $normalize->($primary_term)->then(sub {
        my $clean_query = shift;

        return $fetch_match->($clean_query)->then(sub {
            my $top_match = shift;
            my $sim  = $top_match ? ($top_match->{similarity} // $top_match->{sim}) : 0;
            my $dist = defined $sim ? (1.0 - $sim) : ($top_match->{distance} // 1.0);

            my $fb_clean = defined $fallback_term ? clean_term_for_vector_mapping($fallback_term) : '';

            if ($dist > 0.035 && length($fb_clean) > 1 && lc($fb_clean) ne lc($clean_query)) {
                $self->app->log->info("[ICD10 FALLBACK TRIGGERED] Dist $dist > 0.035 für '$clean_query'. Prüfe Fallback: '$fb_clean'");

                return $fetch_match->($fb_clean)->then(sub {
                    my $fb_match = shift;
                    if ($fb_match && defined $fb_match->{label}) {
                        my $fb_sim  = $fb_match->{similarity} // $fb_match->{sim};
                        my $fb_dist = defined $fb_sim ? (1.0 - $fb_sim) : ($fb_match->{distance} // 1.0);

                        if (!defined $top_match || $fb_dist < $dist) {
                            return $self->_build_icd10_res($fb_match, $fb_clean);
                        }
                    }
                    return $self->_build_icd10_res($top_match, $clean_query);
                });
            }

            return $self->_build_icd10_res($top_match, $clean_query);
        });
    })->then(sub {
        my $res = shift;
        return $apply_allergy_atc_override->($res);
    });
};

# -------------------------------------------------------------------------
# Helper zur Auswertung & harten Unterdrückung (Cut-off bei Distanz > xxxx)
# -------------------------------------------------------------------------
helper _build_icd10_res => sub {
    my ($self, $match, $term, $max_allowed_dist) = @_;
    
    $max_allowed_dist //= 0.05;

    return undef unless $match && defined $match->{label};

    my $sim  = $match->{similarity} // $match->{sim};
    my $dist = defined $sim ? (1.0 - $sim) : ($match->{distance} // 1.0);

    # HARTE UNTERDRÜCKUNG: Wenn der Treffer über dem Schwellenwert liegt
    if ($dist > $max_allowed_dist) {
        my $dist_str = _extract_vector_dist_str($match);
        $self->app->log->warn("[ICD10 SUPPRESSED]$dist_str '$term' -> $match->{label} überschreitet Max-Distanz ($dist > $max_allowed_dist). Diagnose wird unterdrückt.");
        return undef;
    }

    my $raw_code      = $match->{label};
    my $matched_id    = $self->format_icd10_id($raw_code);
    my $db_label      = $self->get_canonical_ontology_label('icd10', $raw_code);
    my $matched_label = $db_label // $match->{payload} // $term;
    my $dist_str      = _extract_vector_dist_str($match);

    # --- TRAUMA-FILTER (S-Codes) ---
    # S-Codes nur dann abweisen, wenn der Begriff ABSOLUT KEIN Trauma/Verletzung darstellt
    if ($matched_id =~ /^ICD10:S/i) {
        my $is_trauma_term = ($term =~ /(?:trauma\w*|unfall\w*|verletz\w*|fraktur\w*|\bfx\b|trümmer\w*|luxation\w*|perforat\w*|ruptur\w*|prolaps\w*|h[äa]matom\w*|monokel\w*|ri[ßs]s?\w*|wunde\w*|quetsch\w*|prell\w*|fremdkörper\w*|kontusion\w*|sturz\w*|schnitt\w*|verätzung\w*|verbrennung\w*|erosio)/i);

        unless ($is_trauma_term) {
            $self->app->log->warn("[ICD10 BLOCKED] Trauma-Code $matched_id für nichttraumatischen Begriff '$term' abgewiesen.");
            return undef;
        }
    }

    $self->app->log->info("[ICD10 RETRIEVAL]$dist_str '$term' -> $matched_id ($matched_label)");
    return { id => $matched_id, label => $matched_label };
};

helper map_to_ops_async => sub {
    my ($self, $term, $doc_lang) = @_;
    return Mojo::Promise->resolve(undef) unless defined $term && length($term);

    my $clean = $term;

    # 1. Check Dynamic Database Intercepts (cleaned and verbatim term)
    if (my $hit = $self->check_database_intercept('ops', $clean) || $self->check_database_intercept('ops', $term)) {
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

        my $execute_call = sub {
            my $url_retrieve = "$patchbay_url/LLM/run_stateless/" . LLM_OPS_RETRIEVAL_PROMPT_ID;

            my $encoded_payload = encode('UTF-8', $clean_query);

            return $ua_fast->post_p(
                $url_retrieve => { 'Content-Type' => 'text/plain; charset=UTF-8', Accept => '*/*' } => $encoded_payload
            )->then(sub {
                my $tx = shift;
                if ($tx->result && $tx->result->is_success) {
                    my $body = $tx->result->body;
                    my $matches = eval { decode_json($body) } // eval { from_json(decode('UTF-8', $body)) } // [];
                    if (ref $matches eq 'ARRAY' && @$matches && defined $matches->[0]->{label}) {
                        my $raw_code      = $matches->[0]->{label};
                        my $matched_id    = $self->format_ops_id($raw_code);
                        my $db_label      = $self->get_canonical_ontology_label('ops', $raw_code);
                        my $matched_label = $db_label // 'Inoffizieller Code'// $term;

                        $self->app->log->info("[OPS RETRIEVAL] '$clean_query' -> $matched_id ($matched_label)");
                        return { id => $matched_id, label => $matched_label };
                    }
                }
                return { id => "OPS:9-999", label => $term };
            })->catch(sub { return { id => "OPS:9-999", label => $term }; });
        };
        return $self->enqueue_patchbay_call($execute_call, $clean_query);
    });
};

helper map_to_atc_async => sub {
    my ($self, $term, $doc_lang) = @_;
    return Mojo::Promise->resolve(undef) unless defined $term && length($term);

    my $clean_term = clean_atc_term($term);

    # 1. Check Dynamic Database Intercepts (raw and cleaned term)
    if (my $hit = $self->check_database_intercept('atc', $term) || $self->check_database_intercept('atc', $clean_term)) {
        $self->app->log->info("[ATC DB INTERCEPT] '$term' -> $hit->{id} ($hit->{label})");
        return Mojo::Promise->resolve($hit);
    }

    $doc_lang = lc($doc_lang // 'de');
    my $search_payload = uc $clean_term;

    # Target: GERMAN ('de'). If doc is already German ('de'), skip translation!
    my $p_query = ($doc_lang eq 'de')
        ? Mojo::Promise->resolve(clean_term_for_vector_mapping($search_payload))
        : $self->normalize_criterion_for_retrieval_async($search_payload, 'atc');

    return $p_query->then(sub {
        my $clean_query = shift;

        my $execute_call = sub {
            my $url_retrieve = "$patchbay_url/LLM/run_stateless/" . LLM_ATC_RETRIEVAL_PROMPT_ID;

            my $encoded_payload = encode('UTF-8', $clean_query);

            return $ua_fast->post_p(
                $url_retrieve => { 'Content-Type' => 'text/plain; charset=UTF-8', Accept => '*/*' } => $encoded_payload
            )->then(sub {
                my $tx = shift;
                if ($tx->result && $tx->result->is_success) {
                    my $body = $tx->result->body;
                    my $matches = eval { decode_json($body) } // eval { from_json(decode('UTF-8', $body)) } // [];
                    if (ref $matches eq 'ARRAY' && @$matches && defined $matches->[0]->{label}) {
                        my $raw_code      = $matches->[0]->{label};
                        my $matched_id    = $self->format_atc_id($raw_code);
                        my $db_label      = $self->get_canonical_ontology_label('atc', $raw_code);
                        my $matched_label = $db_label // $matches->[0]->{payload} // $term;

                        $self->app->log->info("[ATC RETRIEVAL] '$clean_query' -> $matched_id ($matched_label)");
                        return { id => $matched_id, label => $matched_label };
                    }
                }
                return { id => "ATC:V03AX", label => $term };
            })->catch(sub { return { id => "ATC:V03AX", label => $term }; });
        };
        return $self->enqueue_patchbay_call($execute_call, $clean_query);
    });
};

helper map_to_loinc_async => sub {
    my ($self, $term, $doc_lang) = @_;
    return Mojo::Promise->resolve(undef) unless defined $term && length($term);
    return Mojo::Promise->resolve(undef) if $term =~ /unknown/i;

    # SOFORT-EXIT: Wenn der Term bereits ein aufgelöster LOINC-Code ist
    if ($term =~ /^(LOINC:\d+-\w*)\s*(.*)$/i) {
        return Mojo::Promise->resolve({ id => $1, label => ($2 || $term) });
    }

    # 1. Check Dynamic Database Intercepts (raw term)
    if (my $hit = $self->check_database_intercept('loinc', $term)) {
        $self->app->log->info("[LOINC DB INTERCEPT] '$term' -> $hit->{id} ($hit->{label})");
        return Mojo::Promise->resolve($hit);
    }

    $doc_lang = lc($doc_lang // 'de');

    # Target: ENGLISH ('en'). If doc is already English ('en'), skip translation!
    my $p_query = ($doc_lang eq 'en')
        ? Mojo::Promise->resolve(clean_term_for_vector_mapping($term))
        : $self->normalize_criterion_for_retrieval_async($term, 'loinc');

    return $p_query->then(sub {
        my $distilled_query = shift;
        my $loinc_payload_query = prepare_loinc_search_term($term, $distilled_query);

        # Secondary intercept check on the prepared payload query
        if (my $hit = $self->check_database_intercept('loinc', $loinc_payload_query)) {
            $self->app->log->info("[LOINC DB INTERCEPT] '$loinc_payload_query' -> $hit->{id} ($hit->{label})");
            return $hit;
        }

        my $execute_call = sub {
            my $url_retrieve = "$patchbay_url/LLM/run_stateless/" . LLM_LOINC_RETRIEVAL_PROMPT_ID;

            my $encoded_payload = encode('UTF-8', $loinc_payload_query);

            return $ua_fast->post_p(
                $url_retrieve => { 'Content-Type' => 'text/plain; charset=UTF-8', Accept => '*/*' } => $encoded_payload
            )->then(sub {
                my $tx = shift;
                if ($tx->result && $tx->result->is_success) {
                    my $body = $tx->result->body;
                    my $matches = eval { decode_json($body) } // eval { from_json(decode('UTF-8', $body)) } // [];
                    if (ref $matches eq 'ARRAY' && @$matches && defined $matches->[0]->{label}) {
                        my $raw_code      = $matches->[0]->{label};
                        my $matched_id    = $self->format_loinc_id($raw_code);
                        my $db_label      = $self->get_canonical_ontology_label('loinc', $raw_code);
                        my $matched_label = $db_label // $matches->[0]->{payload} // $term;

                        $self->app->log->info("[LOINC RETRIEVAL] '$loinc_payload_query' -> $matched_id ($matched_label)");
                        return { id => $matched_id, label => $matched_label };
                    }
                }
                return { id => "LOINC:21889-1", label => $term };
            })->catch(sub { return { id => "LOINC:21889-1", label => $term }; });
        };
        return $self->enqueue_patchbay_call($execute_call, $loinc_payload_query);
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

    return length($clean) > 1 ? $clean : $term;
}


# =========================================================================
# UNIVERSELLES KLINISCHES & STUDIEN-CHUNKING (PHENOPACKET & FHIR SAFE)
# =========================================================================
sub split_into_clinical_section_chunks {
    my ($text, $target_chunk_chars) = @_;
    $target_chunk_chars //= 800; # Standard-Zielgröße für fokussierte LLM-Chunks

    return () unless defined $text && length($text);

    # 1. SCHRITT: Lateralitäts-Präfixe/-Suffixe (RA, LA, BA, OD, OS, OU, R, L, B)
    my $lat_pattern = qr/(?:\s+(?:[rlb]|ra|la|ba|od|os|ou|rechts?|links?|beidseits))/i;

    # 2. SCHRITT: Header-Regex definieren (inkl. FAG, IOL-Master, VAA-OCT etc.)
    my $header_pattern = qr{(?:
        (?:inclusion(?:\s+criteria)?|einschluss(?:kriterien)?|key\s+inclusion)|
        (?:exclusion(?:\s+criteria)?|ausschluss(?:kriterien)?|key\s+exclusion)|
        (?:study\s+eye(?:\s+criteria)?|fellow\s+eye(?:\s+criteria)?|studienauge|partnerauge)|
        (?:general\s+criteria|allgemeine\s+kriterien|safety\s+criteria)|
        (?:diagnosen?|anamnese|ivom(?:[\s\-]anamnese)?|therapie|aktuelle\s+(?:ophthalmologische\s+)?therapie|lokaltherapie|medikation|dauermedikation|blutverd[üu]nnung|vorgeschichte|allgemein(?:erkrankungen(?:\/medikation)?)?|allergien?)$lat_pattern?|
        (?:visus|refraktion|skiaskopie|brille|orthoptik|binokularsehen|motilit[äa]t|stereosehen|tensio|druck|tonometrie|pachymetrie|pentacam|topographie|gf|gesichtsfeld|perimetrie|hertel|iolmaster|biometrie)$lat_pattern?|
        (?:vaa|vorderabschnitt|spaltlampe|hornhaut|fundus|papille|makula|nh[\s\-]oct|rnfl(?:[\s\-]oct)?|oct|bmo[\s\-]oct|gcl(?:[\s\-]oct)?|vaa[\s\-]oct|fag|fla|fl[\s\-]angio|angiograph\w*)$lat_pattern?|
        (?:lebensalter|geschlecht|alter|befund|prozeduren?|operationen?|orderheute|bemerkungen)
    )\s*[:=]}ix;

    # 3. SCHRITT: Zeilenumbrüche vor jedem erkannten Header sicherstellen
    $text =~ s/($header_pattern)/\n$1/g;

    my @lines = split /\r?\n/, $text;
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

    # 4. SCHRITT: Lateralitäts-Kontext injizieren & Chunks bündeln
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

        # Sektionen bis zur Zielgröße zusammenfassen
        if (length($current_chunk) + length($sec_text) + 2 > $target_chunk_chars && length($current_chunk) > 0) {
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

                if ($self->is_uncodable_or_future_rule($v) || $self->is_uncodable_or_future_rule($item->{canonical_term})) {
                    $self->app->log->info("[UNCODABLE / ADMINISTRATIVE RULE FILTERED] '$v' (Term: '$item->{canonical_term}')");
                    next;
                }

                if ($self->is_normal_physiological_finding($v) || $self->is_normal_physiological_finding($item->{canonical_term})) {
                    $self->app->log->info("[NORMAL PHYSIOLOGICAL FINDING FILTERED] '$v'");
                    next;
                }

                if (defined $item->{disjunction_group_id} && $item->{disjunction_group_id} =~ /^(?:none|null|n\/?a|0|\s*)$/i) {
                    $item->{disjunction_group_id} = '';
                }

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

    # 0. Bereits ISO
    if ($text =~ /\b((?:19|20)\d{2}-[0-1]\d-[0-3]\d)\b/) { return $1; }
    if ($text =~ /\b((?:19|20)\d{2}-[0-1]\d)\b/)          { return $1; }

    # 1. Vollständiges deutsches Datum: DD.MM.YYYY
    if ($text =~ /\b([0-3]?\d)\.([0-1]?\d)\.((?:19|20)\d{2})\b/) {
        return sprintf("%04d-%02d-%02d", $3, $2, $1);
    }

    # 2. Monat / Jahr (MM/YYYY)
    if ($text =~ /\b(0?[1-9]|1[0-2])[\/\.]((?:19|20)\d{2})\b/) {
        return sprintf("%04d-%02d", $2, $1);
    }

    # 3. Vierstelliges Einzeljahr (19xx oder 20xx)
    if ($text =~ /\b((?:19|20)\d{2})\b/) {
        return sprintf("%04d", $1);
    }

    # 4. Relative Zeitangaben auflösen (z.B. "vor über 20 Jahre", "vor ca. 3 Monaten")
    if ($text =~ /\b(?:vor|seit)\s+(?:über|mehr\s+als|knapp|ca\.?|etwa)?\s*(\d+)\s*(tage?n?|wochen?|monate?n?|jahre?n?|d|wk|mo|y)\b/i) {
        return calculate_absolute_date($ref_date_str, "$1 $2");
    }

    if ($text =~ /\b(?:ED|EM|Erstdiagnose|Erstmanifestation)\s*:?\s*(0?[1-9]|1[0-2])[\/\.](\d{2})\b/i) {
        my ($m, $y) = ($1, $2 + 0);
        my $full_year = ($y < 70) ? (2000 + $y) : (1900 + $y);
        return sprintf("%04d-%02d", $full_year, $m);
    }
    if ($text =~ /\b(?:ED|EM|Erstdiagnose|Erstmanifestation)\s*:?\s*((?:19|20)?\d{2})\b/i) {
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

    my $label = eval {
        my $row = $self->pg->db->select($table, ['label'], { id => $clean_code })->hash;
        return $row->{label} if $row && defined $row->{label} && length $row->{label};
        return undef;
    };

    return $label;
};

helper is_uncodable_or_future_rule => sub {
    my ($self, $text) = @_;
    if (!ref($self) && defined($text) && !defined($_[2])) {
        $text = $self;
        $self = app();
    }
    return 1 unless defined $text && length($text);
    $text =~ s/^\s+|\s+$//g;

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
        return clean_term_for_vector_mapping($combined_context);
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
                            unit       => "cells/mm2",
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
                        my $loinc_id = $parsed_eye->{is_best_corrected} ? "LOINC:65893-0" : "LOINC:65892-2";
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
                my $p_loinc = $c->map_to_loinc_async($loinc_search_term, $doc_lang);
                my $p_hpo   = $c->map_to_hpo_async($clean_search_term, 0, $doc_lang);

                my $p_combined = Mojo::Promise->all($p_loinc, $p_hpo)->then(sub {
                    my ($loinc_res, $hpo_res) = @_;
                    my $mapped_loinc = $loinc_res->[0];
                    my $mapped_hpo   = $hpo_res->[0];

                    my $assay_node = {
                        exclude => $is_ex ? \1 : \0,
                        combinationMethod => $comb_method,
                        code => { coding => [{ system => "http://snomed.info/sct", code => "8116006", display => "Phänotypisches Merkmal" }] },
                        valueCodeableConcept => { coding => [{ system => "http://loinc.org", code => $mapped_loinc->{id}, display => $mapped_loinc->{label} // $v_text, is_modifier => \0 }] }
                    };

                    my $paired_node = $pair_with_quantity->($assay_node);

                    if ($mapped_hpo && $mapped_hpo->{id} && $mapped_hpo->{id} ne 'HP:0000118') {
                        my $hpo_node = {
                            exclude => $is_ex ? \1 : \0,
                            combinationMethod => $comb_method,
                            code => { coding => [{ system => "http://snomed.info/sct", code => "8116006", display => "Phänotypisches Merkmal" }] },
                            valueCodeableConcept => { coding => [{ system => "http://purl.obolibrary.org/obo/hp.owl", code => $mapped_hpo->{id}, display => $mapped_hpo->{label} // $v_text, is_modifier => \0 }] }
                        };

                        my $composite_group = {
                            resourceType      => 'Group',
                            combinationMethod => 'all-of',
                            exclude           => $is_ex ? \1 : \0,
                            characteristic    => [ $hpo_node, $paired_node ]
                        };
                        return $wrap_res->($composite_group);
                    }

                    return $wrap_res->($paired_node);
                });

                push @row_promises, $p_combined;
                next;
            }

            # --- ICD-10 Diagnoses ---
            if ($domain eq 'icd10') {
                my $p_icd = $c->map_to_icd10_async($clean_search_term, $doc_lang)->then(sub {
                    my $mapped = shift;
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
                my $p_ops = $c->map_to_ops_async($clean_search_term, $doc_lang)->then(sub {
                    my $mapped = shift;
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
                my $p_atc = $c->map_to_atc_async($clean_search_term, $doc_lang)->then(sub {
                    my $mapped = shift;
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

            my $p_hpo = $c->map_to_hpo_async($enriched_term, 0, $doc_lang)->then(sub {
                my $mapped = shift;
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
        # Konfliktlösung (Ausschluss sticht Verdacht)
        # -------------------------------------------------------------
        my %excluded_phrases;
        my %excluded_tokens;

        foreach my $it (@$atomic_items) {
            if (to_bool($it->{is_exclusion})) {
                for my $raw ($it->{canonical_term}, $it->{verbatim_text}) {
                    next unless defined $raw && length($raw);
                    my $clean = lc(clean_term_for_vector_mapping($raw));
                    $clean =~ s/\b(?:kein[enms]?|ohne|hinweis|auf|nicht|frei|ausschluss)\b//gi;
                    $clean =~ s/^\s+|\s+$//g;

                    if (length($clean) > 3) {
                        $excluded_phrases{$clean} = 1;
                        foreach my $token (split(/[^\p{L}\p{N}]+/, $clean)) {
                            $excluded_tokens{$token} = 1 if length($token) >= 5;
                        }
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
                for my $cand ($it->{canonical_term}, $it->{verbatim_text}) {
                    next unless defined $cand && length($cand);
                    my $clean = lc(clean_term_for_vector_mapping($cand));
                    $clean =~ s/\b(?:v\.?\s*a\.?|verdacht|fraglich)\b//gi;
                    $clean =~ s/^\s+|\s+$//g;

                    if ($excluded_phrases{$clean}) {
                        $should_drop = 1;
                        $matched_reason = "Phrase '$clean'";
                        last;
                    }
                    foreach my $token (split(/[^\p{L}\p{N}]+/, $clean)) {
                        if (length($token) >= 5 && $excluded_tokens{$token}) {
                            $should_drop = 1;
                            $matched_reason = "Token '$token'";
                            last;
                        }
                    }
                    last if $should_drop;
                }
            }

            if ($should_drop) {
                $self->app->log->info("[SUSPECTED DIAGNOSIS REMOVED BY EXCLUSION] '$it->{verbatim_text}' matched exclusion ($matched_reason)");
                0;
            } else {
                1;
            }
        } @$atomic_items;

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
            if ($v =~ /\b(?:absto[ßs]ung\w*|graft\s*rejection\w*|transplantatversagen\w*)\b/i
                || $c =~ /\b(?:absto[ßs]ung\w*|graft\s*rejection\w*|transplantatversagen\w*)\b/i) {
                $item->{domain}         = 'icd10';
                $item->{canonical_term} = 'Hornhauttransplantatabstoßung';
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

        }

        @$atomic_items = grep { ($_->{domain} // '') ne 'skip' } @$atomic_items;

        my @feature_promises;
        my @measurement_promises;
        my @disease_promises;
        my @procedure_promises;
        my @medication_promises;

        my $detected_sex = 'UNKNOWN';
        my $detected_age_iso = undef;

        foreach my $item (@$atomic_items) {
            my $v_text      = $item->{verbatim_text} // '';
            my $canon_term  = $item->{canonical_term} // '';
            my $event_date  = $item->{event_date} // '';
            my $domain      = lc($item->{domain} // 'hpo');
            my $demo_type   = lc($item->{demographic_type} // 'none');
            my $demo_val    = $item->{demographic_value} // '';
            my $is_ex       = to_bool($item->{is_exclusion});

            my $time_from_verb  = extract_event_date($v_text, $reference_date);
            my $time_from_event = extract_event_date($event_date, $reference_date);
            my $date_source;
            if ($time_from_verb && $time_from_event) {
                $date_source = (length($time_from_verb) >= length($time_from_event))
                    ? $time_from_verb : $time_from_event;
            } else {
                $date_source = $time_from_verb // $time_from_event // $event_date // $v_text;
            }
            my $item_timestamp = extract_event_date($date_source, $reference_date);

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

                my $is_visus_candidate = (
                    $canon_term =~ /\b(?:visual\s*acuity|visus|refraction|refraktion|skiaskop\w*|c[- ]?skia\w*|sphere|sphäre|cylinder|zylinder)\b/i
                    || $v_text =~ /\b(?:visus|sehschärfe|visual\s*acuity|aufnahmevisus|entlassvisus|refraktion|skiaskop\w*|c[- ]?skia\w*|sc\b|cc\b|hbw\b|lsp\b|lsw\b|nulla\s*lux)\b/i
                ) && ($v_text !~ /\b(?:osdi|vas|but|tbut|pachymetrie|k1|k2|kmax|astigmatismus|rr|blutdruck)\b/i);

                my $time_obs = $item_timestamp;
                if ($is_visus_candidate && $v_text =~ /^\s*visus\s*[rlb]?\s*:\s*[\d\.,]+/i) {
                    $time_obs = $reference_date;
                } else {
                    $time_obs //= $reference_date;
                }

                if ($is_visus_candidate) {
                    my $parsed_eye = extract_visus_and_refraction($v_text, $text_content);
                    if ($parsed_eye && (defined $parsed_eye->{visus_value} || defined $parsed_eye->{sphere})) {
                        my @eye_meas = build_ophthalmic_loinc_measurements($parsed_eye, $item_lat, $time_obs);
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

                my $p = $self->map_to_loinc_async($loinc_search_term, $doc_lang)->then(sub {
                    my $mapped = shift;
                    return [] unless defined $mapped && defined $mapped->{id};

                    my $quant = parse_quantitative_constraint($v_text)
                             // parse_quantitative_constraint($demo_val);

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
                $search_icd = enrich_term_with_section_context($search_icd, "$v_text $canon_term", $text_content);

                my $p = $self->map_to_icd10_async($search_icd, $canon_term, $doc_lang)->then(sub {
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

                if ($v_text =~ /\b(avastin|bevacizumab|lucentis|ranibizumab|eylea|aflibercept|vabysmo|faricimab|beovu|brolucizumab|ozurdex|dexamethason)\b/i) {
                    my $substance = $1;
                    my $p_atc_auto = $self->map_to_atc_async($substance, $doc_lang)->then(sub {
                        my $mapped_atc = shift;
                        return undef unless $mapped_atc && $mapped_atc->{id};

                        my $chosen_med_label = (defined $canon_term && length($canon_term) > 1 && $canon_term =~ /$substance/i)
                            ? $canon_term
                            : ($mapped_atc->{label} // ucfirst($substance));

                        my $med_obj = { agent => { id => $mapped_atc->{id}, label => $chosen_med_label } };
                        $med_obj->{performedTime} = $item_timestamp if defined $item_timestamp;
                        return $med_obj;
                    });
                    push @medication_promises, $p_atc_auto;
                }

                my $p = $self->map_to_ops_async($search_proc, $doc_lang)->then(sub {
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
                my $direct_hit = $self->check_database_intercept('atc', $v_text);
                $direct_hit //= $self->check_database_intercept('atc', $canon_term) if defined $canon_term;

                if ($direct_hit) {
                    $self->app->log->info("[ATC DB INTERCEPT OVERRIDE] '$v_text' -> $direct_hit->{id} ($direct_hit->{label})");
                    my $med_obj = { agent => { id => $direct_hit->{id}, label => $direct_hit->{label} } };
                    $med_obj->{performedTime} = $item_timestamp if defined $item_timestamp;
                    push @medication_promises, Mojo::Promise->resolve($med_obj);
                    next;
                }

                my $search_med = (defined $canon_term && length($canon_term) > 1) ? $canon_term : $v_text;
                my $p = $self->map_to_atc_async($search_med, $doc_lang)->then(sub {
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
                    return $med_obj;
                });
                push @medication_promises, $p;
            }
            # --- HPO PHENOTYPES ---
            else {
                my $direct_hit;
                if (defined $canon_term && length($canon_term) > 1) {
                    $direct_hit = $self->check_database_intercept('hpo', $canon_term);
                }
                $direct_hit //= $self->check_database_intercept('hpo', $v_text);

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

                my $p = $self->map_to_hpo_async($search_term, 0, $doc_lang)->then(sub {
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
                my $key = $d->{term}{id};
                if ($key =~ /^ICD10:(?:Z88|T88\.7|T78\.4)/i) {
                    my $clean_label = lc($d->{term}{label} // '');
                    $clean_label =~ s/\b(?:allergie\s*(?:gegen)?|unvertr\w*)\b//gi;
                    $clean_label =~ s/^\s+|\s+$//g;
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
                my $key = join('|',
                    $p->{code}{id},
                    ($p->{bodySite} ? $p->{bodySite}{id} : 'none'),
                    ($p->{performedTime} // 'none')
                );
                next if $seen_procs{$key}++;
                push @final_procedures, $p;
            }

            my @final_medications;
            foreach my $m (@raw_medications) {
                next unless $m && $m->{agent}{id};
                my $m_time = $m->{performedTime};

                my $is_duplicate = 0;
                for my $existing (@final_medications) {
                    if ($existing->{agent}{id} eq $m->{agent}{id}) {
                        my $e_time = $existing->{performedTime};

                        if (!defined $m_time || !defined $e_time || $m_time eq $e_time) {
                            $existing->{performedTime} //= $m_time;
                            $is_duplicate = 1;
                            last;
                        }

                        if (abs(date_diff_in_days($e_time, $m_time)) <= 14) {
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
            return {
                id                 => "phenopacket-" . time(),
                subject            => $subject_obj,
                phenotypicFeatures => \@final_features,
                measurements       => \@final_measurements,
                diseases           => \@final_diseases,
                procedures         => \@final_procedures,
                medicalActions     => \@medical_actions,
                metaData           => {
                    created                  => $timestamp,
                    createdBy                => "OntoTrial2-DisjunctiveDeduplicatedStepEngine",
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
        $c->render(json => shift);
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
        $c->render(json => shift);
    })->catch(sub {
        my $err = shift;
        $c->notify_task_progress($task_id, 'failed', 0, "Pipeline-Fehler: $err");
        $c->render(json => { error => "Pipeline failure", details => "$err" }, status => 500);
    });
};

# =========================================================
# ENDPUNKT: ARZTBRIEF IMPORTIEREN & ASYNCHRON EXTRAHIEREN
# =========================================================
post '/BBB/import_and_extract_letter' => sub {
    my $c = shift;
    my $payload = $c->req->json // {};

    my $pseudonym      = $payload->{pseudonym} // $payload->{piz};
    my $doc_id         = $payload->{doc_id}    // $payload->{idbrief};
    my $text_content   = $payload->{medical_report} // $payload->{medical_letter} // $payload->{text} // '';
    my $reference_date = $payload->{reference_date} // POSIX::strftime("%Y-%m-%d", localtime);
    my $selected_model = $payload->{model};
    my $deep_mode      = $payload->{deep_mode} // 0;

    unless ($pseudonym && $text_content) {
        return $c->render(json => {
            error => "Pflichtfelder 'pseudonym' (oder 'piz') und 'medical_report' (oder 'text') fehlen."
        }, status => 400);
    }

    my $db = $c->pg->db;

    # 1. Prüfung: Existiert GENAU DIESER Arztbrief (über doc_id) bereits?
    my $existing = $doc_id
        ? $db->select('candidates', ['id'], { doc_id => $doc_id })->hash
        : undef;

    my $candidate_id;

    if ($existing) {
        $candidate_id = $existing->{id};
        # Bestehenden Brief-Eintrag aktualisieren
        $db->update('candidates', {
            pseudonym        => $pseudonym,
            narrative_report => $text_content,
            phenopacket_json => undef,
            reference_date   => $reference_date
        }, { id => $candidate_id });

        $c->app->log->info("Brief Doc-ID '$doc_id' (PIZ $pseudonym, ID: $candidate_id) existierte bereits - Inhalt wird neu extrahiert.");
    } else {
        # Neuen Arztbrief-Datensatz anlegen
        $candidate_id = $db->insert('candidates', {
            pseudonym        => $pseudonym,
            doc_id           => $doc_id,
            narrative_report => $text_content,
            reference_date   => $reference_date,
            phenopacket_json => undef
        }, { returning => 'id' })->hash->{id};

        $c->app->log->info("Neuer Brief für PIZ '$pseudonym' angelegt (Doc-ID: $doc_id, ID: $candidate_id).");
    }

    # 2. Minion-Task für Hintergrund-Extraktion einreihen
    my $job_id = $c->minion->enqueue(import_and_extract_letter_task => [{
        candidate_id   => $candidate_id,
        pseudonym      => $pseudonym,
        doc_id         => $doc_id,
        text_content   => $text_content,
        reference_date => $reference_date,
        model          => $selected_model,
        deep_mode      => $deep_mode
    }]);

    # Sofortige Rückmeldung mit Job-ID
    $c->render(json => {
        status       => 'queued',
        job_id       => $job_id,
        candidate_id => $candidate_id,
        pseudonym    => $pseudonym,
        doc_id       => $doc_id,
        action       => $existing ? 'updated' : 'created',
        message      => sprintf("Arztbrief %s (PIZ %s) zur Extraktion im Hintergrund eingereiht.", $doc_id // $candidate_id, $pseudonym)
    });
};

# =========================================================
# MINION TASK: ASYNCHRONE ARZTBRIEF-EXTRAKTION (PHENOPACKET)
# =========================================================
app->minion->add_task(import_and_extract_letter_task => sub {
    my ($job, $payload) = @_;
    my $app = $job->app;
    my $db  = $app->pg->db;

    my $candidate_id   = $payload->{candidate_id};
    my $pseudonym      = $payload->{pseudonym};
    my $text_content   = $payload->{text_content};
    my $selected_model = $payload->{model};
    my $reference_date = $payload->{reference_date};
    my $deep_mode      = $payload->{deep_mode} // 0;
    my $task_id        = "minion_$candidate_id";

    $job->note(status => 'processing', message => "Starte Extraktion für Pseudonym $pseudonym...", progress => 10);

    # Führe Phenopacket-Extraktionspipeline aus
    $app->generate_phenopacket_impl($text_content, $selected_model, $candidate_id, $reference_date, $deep_mode, $task_id)->then(sub {
        my $phenopacket = shift;

        # Extrahiertes Phenopacket in der Datenbank speichern
        $db->update('candidates', {
            phenopacket_json => to_json($phenopacket),
                    narrative_report   => $text_content
        }, { id => $candidate_id });

        $app->log->info("[MINION TASK] Extraktion für Candidate ID $candidate_id ($pseudonym) erfolgreich abgeschlossen.");
        $job->note(status => 'finished', message => "Extraktion für $pseudonym abgeschlossen.", progress => 100);
        $job->finish();
    })->catch(sub {
        my $err = shift;
        $app->log->error("[MINION TASK FEHLER] Extraktion für Candidate ID $candidate_id fehlgeschlagen: $err");
        $job->fail("Extraktionsfehler: $err");
    })->wait; # ->wait stellt sicher, dass das Promise innerhalb des Minion-Workers abgewartet wird
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
                            $shared_perf_time = $proc->{performedTime} // $proc->{performed}{timestamp};
                            last;
                        }
                    }
                } elsif ($c_code =~ /^ATC:/i) {
                    foreach my $act (@{$phenopacket->{medicalActions} // []}) {
                        if ($act->{treatment} && $c->is_atc_subclass_of($act->{treatment}{agent}{id}, $c_code)) {
                            $shared_perf_time = $act->{treatment}{performedTime} // $act->{treatment}{performed}{timestamp};
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


# =========================================================
# GENERIC DB REST CRUD ENDPOINTS (MIT 1/1-SICHERUNG)
# =========================================================
helper fetchFromTable => sub {
    my ($self, $table_raw, $sessionid, $where) = @_;
    my $table = resolve_table_name($table_raw);
    return $self->pg->db->select($table, ['*'], $where)->hashes->to_array;
};

get '/BBB/:table' => sub {
    my $self  = shift;
    my $table = resolve_table_name($self->param('table'));
    $self->render(json => $self->pg->db->select($table, ['*'])->hashes->to_array);
};

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
# GENERIC DB REST CRUD ENDPOINTS
# =========================================================
helper fetchFromTable => sub {
    my ($self, $table_raw, $sessionid, $where) = @_;
    my $table = resolve_table_name($table_raw);
    return $self->pg->db->select($table, ['*'], $where)->hashes->to_array;
};

get '/BBB/:table' => sub {
    my $self  = shift;
    my $table = resolve_table_name($self->param('table'));
    $self->render(json => $self->pg->db->select($table, ['*'])->hashes->to_array);
};

get '/BBB/:table/:col/:pk' => [col => qr/[a-z_0-9\s]+/, pk => qr/[a-z0-9\s\-_\.]+/i] => sub {
    my $self  = shift;
    my $table = resolve_table_name($self->param('table'));
    my $pk    = $self->param('pk');
    my $col   = $self->param('col');
    $self->render(json => $self->pg->db->select($table, ['*'], {$col => $pk})->hashes->to_array);
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
# LOINC DATABASE IMPORT
# =========================================================
any '/_import_loinc' => sub {
    my $c = shift;
    $c->inactivity_timeout(1200); # 20 minutes for bulk insertion of ~100k records

    my $filepath = '/Users/Shared/bin/OntoTrial2/_sources/Loinc2.csv';

    unless (-e $filepath) {
        $c->app->log->error("LOINC import file not found at: $filepath");
        return $c->render(json => { error => "File not found at $filepath" }, status => 404);
    }

    my $db = $c->pg->db;
    my $imported_count = 0;

    eval {
        my $tx = $db->begin;

        # Truncate existing table
        $db->query("TRUNCATE TABLE public.loinc_terms RESTART IDENTITY CASCADE");

        my $sql_insert = q{
            INSERT INTO public.loinc_terms (
                id, label, component, property, time_aspect, system,
                scale_type, method_type, class_name, parent_id,
                code_formatted, status, example_ucum_units
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET
                label = EXCLUDED.label,
                component = EXCLUDED.component,
                property = EXCLUDED.property,
                time_aspect = EXCLUDED.time_aspect,
                system = EXCLUDED.system,
                scale_type = EXCLUDED.scale_type,
                method_type = EXCLUDED.method_type,
                class_name = EXCLUDED.class_name,
                parent_id = EXCLUDED.parent_id,
                code_formatted = EXCLUDED.code_formatted,
                status = EXCLUDED.status,
                example_ucum_units = EXCLUDED.example_ucum_units
        };

        my $csv = Text::CSV->new({
            binary           => 1,
            auto_diag        => 1,
            allow_loose_quotes => 1,
        }) or die "Cannot use Text::CSV: " . Text::CSV->error_diag();

        open my $fh, "<:encoding(UTF-8)", $filepath or die "Could not open $filepath: $!";

        # Read header row and map column positions
        my $headers = $csv->getline($fh);
        unless ($headers) {
            die "Failed to parse CSV header row.";
        }

        my %col;
        for (my $i = 0; $i < @$headers; $i++) {
            $col{$headers->[$i]} = $i;
        }

        my %created_classes;

        while (my $row = $csv->getline($fh)) {
            my $loinc_num = $row->[ $col{"LOINC_NUM"} ];
            next unless defined $loinc_num && $loinc_num ne '';

            my $component     = $row->[ $col{"COMPONENT"} ] // '';
            my $property      = $row->[ $col{"PROPERTY"} ] // '';
            my $time_aspect   = $row->[ $col{"TIME_ASPCT"} ] // '';
            my $system        = $row->[ $col{"SYSTEM"} ] // '';
            my $scale_type    = $row->[ $col{"SCALE_TYP"} ] // '';
            my $method_type   = $row->[ $col{"METHOD_TYP"} ] // '';
            my $class_name    = $row->[ $col{"CLASS"} ] // 'OTHER';
            my $status        = $row->[ $col{"STATUS"} ] // 'ACTIVE';
            my $ucum_units    = $row->[ $col{"EXAMPLE_UCUM_UNITS"} ] // '';

            # Prefer LONG_COMMON_NAME, then DisplayName, then COMPONENT
            my $label = $row->[ $col{"LONG_COMMON_NAME"} ]
                     || $row->[ $col{"DisplayName"} ]
                     || $component
                     || "LOINC $loinc_num";

            # Ensure parent CLASS category node exists
            my $parent_class_id = "CLASS-" . uc($class_name);
            unless ($created_classes{$parent_class_id}) {
                $db->query(
                    $sql_insert,
                    $parent_class_id, "LOINC Class: $class_name",
                    undef, undef, undef, undef,
                    undef, undef, $class_name, undef,
                    $parent_class_id, "ACTIVE", undef
                );
                $created_classes{$parent_class_id} = 1;
                $imported_count++;
            }

            # Insert individual LOINC term under its CLASS parent
            $db->query(
                $sql_insert,
                $loinc_num, $label, $component, $property, $time_aspect, $system,
                $scale_type, $method_type, $class_name, $parent_class_id,
                $loinc_num, $status, $ucum_units
            );

            $imported_count++;
        }

        close $fh;
        $tx->commit;
    };

    if ($@) {
        $c->app->log->error("Error during LOINC import: $@");
        return $c->render(json => { error => "Import failed", details => "$@" }, status => 500);
    }

    $c->app->log->info("LOINC import completed. $imported_count records inserted/updated.");
    $c->render(json => { success => 1, message => "Successfully imported $imported_count LOINC entries." });
};

# =========================================================
# APPLICATION STARTUP
# =========================================================
app->config(hypnotoad => { listen => ['http://*:4007'], workers => 3, heartbeat_timeout => 120, inactivity_timeout => 120 });
app->start;
