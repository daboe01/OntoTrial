#!/usr/bin/env perl
# =========================================================
# update_catalogs.pl – Katalog-Aktualisierung für OntoTrial
#
#   perl update_catalogs.pl inventory
#   perl update_catalogs.pl hpo   hp.obo                [--dry-run] [--keep-synonyms]
#   perl update_catalogs.pl icd10 icd10gm2027syst.xml   [--dry-run] [--version 2027]
#   perl update_catalogs.pl ops   ops2027syst.xml       [--dry-run] [--version 2027]
#   perl update_catalogs.pl atc   atc_amtlich.csv       [--dry-run] [--version 2027]
#   perl update_catalogs.pl check [ontotrial.pl]
#
# Optionen:
#   --db URL            Postgres-URL (Default: $ONTOTRIAL_DB oder localhost/hpo)
#   --dry-run           parsen, prüfen, schreiben – dann Rollback
#   --keep-synonyms     HPO: vorhandene (z. B. deutsche) Synonyme behalten, neue ergänzen
#   --structure / --no-structure
#                       ICD/OPS: Kapitel und Gruppen mit importieren
#                       (Default: so wie in der bisherigen Tabelle)
#   --no-modifiers      ICD/OPS: keine Kodes aus ClaML-Modifikatoren erzeugen
#   --force             Plausibilitätsprüfungen nur warnen statt abbrechen
#
# Jeder Import sichert die Zieltabellen vorher als <tabelle>_bak_<zeitstempel>
# und läuft in EINER Transaktion (laufende Leser sehen bis zum Commit den alten Stand).
# =========================================================
use strict;
use warnings;
use utf8;
use feature qw(say state);
use Mojo::Pg;
use Mojo::DOM;
use Mojo::File qw(path);
use Encode qw(decode);
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $db_url   = $ENV{ONTOTRIAL_DB} // 'postgresql://postgres:postgres@localhost/hpo';
my $version  = '';
my $dry      = 0;
my $keep_syn = 0;
my $force    = 0;
my $no_mod   = 0;
my $structure;    # undef = wie bisherige Tabelle

GetOptions(
           'db=s'          => \$db_url,
           'version=s'     => \$version,
           'dry-run'       => \$dry,
           'keep-synonyms' => \$keep_syn,
           'force'         => \$force,
           'no-modifiers'  => \$no_mod,
           'structure!'    => \$structure,
           ) or usage();

my ($cmd, $file) = @ARGV;
usage() unless $cmd;

my $pg = Mojo::Pg->new($db_url);
my $db = $pg->db;
ensure_meta_tables();

if    ($cmd eq 'inventory') { inventory() }
elsif ($cmd eq 'hpo')       { need_file(); import_hpo($file) }
elsif ($cmd eq 'icd10')     { need_file(); import_claml('icd10', $file) }
elsif ($cmd eq 'ops')       { need_file(); import_claml('ops', $file) }
elsif ($cmd eq 'atc')       { need_file(); import_atc($file) }
elsif ($cmd eq 'check')     { check_codes($file) }
else                        { usage() }

# =========================================================
# ALLGEMEINE HILFSFUNKTIONEN
# =========================================================
sub usage {
    print STDERR "Aufruf: $0 inventory|hpo|icd10|ops|atc|check [DATEI] [--dry-run] [--force] ...\n";
    exit 1;
}

sub need_file {
    die "Datei fehlt oder ist nicht lesbar: " . ($file // '(keine)') . "\n" unless defined $file && -r $file;
}

sub sanity {
    my ($ok, $msg) = @_;
    return if $ok;
    die "Plausibilitätsprüfung fehlgeschlagen: $msg (mit --force trotzdem importieren)\n" unless $force;
    warn "WARNUNG: $msg\n";
}

sub ensure_meta_tables {
    $db->query(q{
        CREATE TABLE IF NOT EXISTS public.catalog_versions (
        id          SERIAL PRIMARY KEY,
        catalog     TEXT NOT NULL,
        version     TEXT,
        source_file TEXT,
        n_codes     INTEGER,
        imported_at TIMESTAMPTZ DEFAULT now()
        )});
    # Veraltete/zusammengelegte HPO-Terme -> Nachfolger (für Migration von Studienkriterien)
    $db->query(q{
        CREATE TABLE IF NOT EXISTS public.hpo_replacements (
        old_id INTEGER PRIMARY KEY,
        new_id INTEGER NOT NULL,
        kind   TEXT NOT NULL      -- alt_id | replaced_by | consider
        )});
}

sub backup_table {
    my ($table) = @_;
    my $bak = $table . '_bak_' . strftime('%Y%m%d_%H%M', localtime);
    $db->query("CREATE TABLE public.$bak AS SELECT * FROM public.$table");
    say "  Sicherung: public.$bak";
    return $bak;
}

sub record_version {
    my ($catalog, $ver, $src, $n) = @_;
    $db->query('INSERT INTO public.catalog_versions (catalog, version, source_file, n_codes) VALUES (?, ?, ?, ?)',
    $catalog, $ver, $src, $n);
}

sub finish {
    my ($tx) = @_;
    if ($dry) {
        say "Dry-run: alle Änderungen werden zurückgerollt.";
        return;    # $tx wird beim Verlassen des Aufrufers verworfen -> Rollback
    }
    $tx->commit;
    say "Übernommen. Danach: hypnotoad und Minion-Worker neu starten, Vektorindex neu aufbauen, 'check' laufen lassen.";
}

sub icd_id_format {
    my $r = eval {
        $db->query(q{
            SELECT count(*) FILTER (WHERE id ~ '^[A-Z][0-9]{2}\.[0-9]') AS dotted,
            count(*) FILTER (WHERE id ~ '^[A-Z][0-9]{3,}')        AS dotless
            FROM public.icd10_terms})->hash;
    } // {};
    return (($r->{dotless} // 0) > ($r->{dotted} // 0)) ? 'dotless' : 'dotted';
}

sub has_structure {
    my ($table, $domain) = @_;
    return $structure if defined $structure;
    my $re = $domain eq 'icd10'
    ? q{^[A-Z][0-9]{2}-[A-Z][0-9]{2}$|^[IVXL]+$}   # Gruppen A00-A09, Kapitel I..XXII
    : q{\.\.\.|^[0-9]$};                          # Gruppen 5-08...5-16, Kapitel 1..9
    my $n = eval { $db->query("SELECT count(*) FROM public.$table WHERE id ~ ?", $re)->array->[0] } // 0;
    return $n > 0 ? 1 : 0;
}

# Ersetzt eine flache Code-Tabelle (id, label, parent_id, code_formatted) und
# berichtet, welche Codes neu sind und welche entfallen.
sub replace_flat_table {
    my ($table, $rows) = @_;    # [ [id, label, parent_id, code_formatted], ... ]

    my %old = map { $_->[0] => 1 } @{ $db->query("SELECT id FROM public.$table")->arrays };
    my %new = map { $_->[0] => 1 } @$rows;
    my @added = sort grep { !$old{$_} } keys %new;
    my @gone  = sort grep { !$new{$_} } keys %old;

    say "  gegenüber bisher: " . scalar(@added) . " neu, " . scalar(@gone) . " entfallen";
    say "  neu (Auszug):      " . join(', ', @added[0 .. ($#added < 19 ? $#added : 19)]) if @added;
    say "  entfallen (Auszug): " . join(', ', @gone[0 .. ($#gone < 19 ? $#gone : 19)]) if @gone;
    say "  -> entfallene Codes über die BfArM-Überleitungstabelle prüfen (Studien, Intercepts)" if @gone && $table ne 'atc_terms';

    backup_table($table);
    $db->query("DELETE FROM public.$table");

    # Erst ohne parent_id einfügen, dann verknüpfen: ops_terms und atc_terms haben
    # einen nicht verzögerbaren Self-FK, damit spielt die Reihenfolge der Quelle keine Rolle.
    my $is_icd = $table eq 'icd10_terms';
    for my $r (@$rows) {
        my ($id, $label, undef, $fmt, $level, $terminal) = @$r;
        if ($is_icd) {
            $db->query(q{INSERT INTO public.icd10_terms (id, label, parent_id, code_formatted, level, terminal)
                VALUES (?, ?, NULL, ?, ?, ?)},
            $id, $label, $fmt, $level, ($terminal ? 'true' : 'false'));
        } else {
            $db->query("INSERT INTO public.$table (id, label, parent_id, code_formatted) VALUES (?, ?, NULL, ?)",
            $id, $label, $fmt);
        }
    }
    my $n_link = 0;
    for my $r (@$rows) {
        my ($id, undef, $pid) = @$r;
        next unless defined $pid && $new{$pid};
        $n_link += $db->query("UPDATE public.$table SET parent_id = ? WHERE id = ?", $pid, $id)->rows;
    }
    say "  $table: " . scalar(@$rows) . " Zeilen, $n_link Elternverknüpfungen";
}

# Ebene für icd10_terms.level: Tiefe im neuen Baum plus Versatz. Der Versatz wird
# am bisherigen Wert eines bekannten Dreistellers abgelesen, damit die neue Tabelle
# dieselbe Zählweise hat wie die alte.
sub icd_level_offset {
    my ($entry, $depth_of, $to_id) = @_;
    for my $probe (qw(A00 H35 E10 Z00)) {
        next unless $entry->{$probe};
        my $old = eval { $db->query('SELECT level FROM public.icd10_terms WHERE id = ?', $to_id->($probe))->array };
        return ($old->[0] - $depth_of->($probe), "übernommen vom bisherigen Wert für $probe")
        if $old && defined $old->[0];
    }
    my ($p) = grep { $entry->{$_} } qw(A00 H35);
    return ((defined $p ? 3 - $depth_of->($p) : 3), 'Standard: Dreisteller = 3');
}

# =========================================================
# INVENTORY
# =========================================================
sub inventory {
    say "Tabellengrößen:";
    for my $t (qw(terms isas hpo_closure synonyms xrefs icd10_terms ops_terms atc_terms loinc_terms ontology_intercepts)) {
        my $n = eval { $db->query("SELECT count(*) FROM public.$t")->array->[0] } // 'fehlt';
        printf "  %-22s %s\n", $t, $n;
    }

    say "\nLetzte Importe laut catalog_versions:";
    my $rows = $db->query(q{
        SELECT DISTINCT ON (catalog) catalog, version, imported_at::date AS d, n_codes
        FROM public.catalog_versions ORDER BY catalog, imported_at DESC})->hashes;
    if ($rows->size) { say "  $_->{catalog}: $_->{version} ($_->{d}, $_->{n_codes} Codes)" for @$rows }
    else             { say "  (keine Einträge – bisherige Stände sind nicht protokolliert)" }

    my $maxhp = eval { $db->query('SELECT max(id) FROM public.terms')->array->[0] };
    say sprintf("\nHöchste HPO-ID: HP:%07d (mit dem aktuellen Release vergleichen)", $maxhp) if $maxhp;
    my $obs = eval { $db->query(q{SELECT count(*) FROM public.terms WHERE label ~* '^\s*obsolete'})->array->[0] } // 0;
    say "HPO-Terme mit 'obsolete'-Label: $obs" . ($obs == 0 ? "  (0 = veraltete Terme wurden bisher nicht importiert)" : '');

    my $de = eval { $db->query(q{SELECT count(*) FROM public.synonyms WHERE label ~ '[äöüÄÖÜß]'})->array->[0] } // 0;
    say "HPO-Synonyme mit Umlauten: $de" . ($de > 50 ? "  -> vermutlich deutsche Übersetzungen: beim HPO-Import --keep-synonyms verwenden" : '');

    say "ICD-10-ID-Format: " . icd_id_format();
    my $lv = eval { $db->query(q{SELECT level, count(*) AS n, min(id) AS bsp FROM public.icd10_terms GROUP BY level ORDER BY level})->hashes };
    say "ICD-10-Ebenen: " . join(', ', map { "$_->{level}=$_->{n} (z. B. $_->{bsp})" } @$lv) if $lv && $lv->size;
    say "ICD-10 mit Kapiteln/Gruppen: " . (has_structure('icd10_terms', 'icd10') ? 'ja' : 'nein');
    say "OPS mit Kapiteln/Gruppen:    " . (has_structure('ops_terms', 'ops') ? 'ja' : 'nein');

    my $st = eval { $db->query(q{SELECT status, count(*) AS n FROM public.loinc_terms GROUP BY 1 ORDER BY 2 DESC})->hashes };
    say "LOINC-Status: " . join(', ', map { ($_->{status} // 'NULL') . "=$_->{n}" } @$st) if $st && $st->size;
    my $local = eval { $db->query(q{SELECT count(*) FROM public.loinc_terms WHERE id ~ '^[0-9]+-[0-9][a-z]$'})->array->[0] } // 0;
    say "Lokale LOINC-Erweiterungscodes (86290-4a ...): $local";
}

# =========================================================
# HPO (hp.obo)
# =========================================================
sub parse_obo {
    my ($f) = @_;
    open my $fh, '<:encoding(UTF-8)', $f or die "Kann $f nicht öffnen: $!\n";
    my ($ver, @terms, $cur, $in_header) = ('', (), undef, 1);
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/\r$//;
        if ($in_header && $line =~ /^data-version:\s*(\S+)/) { $ver = $1; next }
        if ($line =~ /^\[(\w+)\]/) {
            $in_header = 0;
            push @terms, $cur if $cur;
            $cur = ($1 eq 'Term')
            ? { is_a => [], syn => [], xref => [], alt => [], replaced => [], consider => [], subset => [] }
            : undef;
            next;
        }
        next unless $cur;
        if    ($line =~ /^id:\s*HP:(\d+)\s*$/)                    { $cur->{id} = $1 + 0 }
        elsif ($line =~ /^name:\s*(.+?)\s*$/)                      { $cur->{name} = $1 }
        elsif ($line =~ /^def:\s*"((?:[^"\\]|\\.)*)"/)             { ($cur->{def} = $1) =~ s/\\(.)/$1/g }
        elsif ($line =~ /^synonym:\s*"((?:[^"\\]|\\.)*)"/)         { (my $s = $1) =~ s/\\(.)/$1/g; push @{ $cur->{syn} }, $s }
        elsif ($line =~ /^xref:\s*(\S+)/)                          { push @{ $cur->{xref} }, $1 }
        elsif ($line =~ /^is_a:\s*HP:(\d+)/)                       { push @{ $cur->{is_a} }, $1 + 0 }
        elsif ($line =~ /^alt_id:\s*HP:(\d+)/)                     { push @{ $cur->{alt} }, $1 + 0 }
        elsif ($line =~ /^replaced_by:\s*HP:(\d+)/)                { push @{ $cur->{replaced} }, $1 + 0 }
        elsif ($line =~ /^consider:\s*HP:(\d+)/)                   { push @{ $cur->{consider} }, $1 + 0 }
        elsif ($line =~ /^is_obsolete:\s*true/)                    { $cur->{obsolete} = 1 }
        elsif ($line =~ /^comment:\s*(.+?)\s*$/)                   { $cur->{comment} = $1 }
        elsif ($line =~ /^subset:\s*(\S+)/)                        { push @{ $cur->{subset} }, $1 }
    }
    push @terms, $cur if $cur;
    close $fh;
    return ($ver, [ grep { defined $_->{id} } @terms ]);
}

sub import_hpo {
    my ($f) = @_;
    my ($ver, $terms) = parse_obo($f);
    $ver = $version if length $version;
    my @active = grep { !$_->{obsolete} } @$terms;
    my %ids    = map { $_->{id} => 1 } @$terms;

    say "HPO $ver: " . scalar(@$terms) . " Terme, davon " . scalar(@active) . " aktiv";
    sanity(@active > 15000 && $ids{1} && $ids{118},
    'HPO-Datei unvollständig (erwartet > 15000 aktive Terme sowie HP:0000001 und HP:0000118)');

    my $de = $db->query(q{SELECT count(*) FROM public.synonyms WHERE label ~ '[äöüÄÖÜß]'})->array->[0];
    if ($de > 50 && !$keep_syn && !$force) {
        die "Abbruch: $de Synonyme enthalten Umlaute (vermutlich deutsche Übersetzungen). "
        . "Mit --keep-synonyms bleiben sie erhalten, mit --force werden sie ersetzt.\n";
    }

    my $tx = $db->begin;
    backup_table($_) for qw(terms isas hpo_closure synonyms xrefs);

    # Terme: Update-or-Insert statt DELETE. HPO löscht keine IDs, und ein DELETE auf
    # terms würde über ON DELETE CASCADE alle Synonyme und Xrefs mitlöschen.
    # Veraltete Terme bleiben mit "obsolete"-Label erhalten, damit alte Codes
    # auflösbar bleiben und der Obsolete-Guard in ontotrial greift.
    my ($upd, $ins) = (0, 0);
    for my $t (@$terms) {
        my $label = $t->{name} // sprintf('HP:%07d', $t->{id});
        $label = "obsolete $label" if $t->{obsolete} && $label !~ /^obsolete\b/i;
        my $subset = @{ $t->{subset} } ? join(', ', @{ $t->{subset} }) : undef;
        my $n = $db->query('UPDATE public.terms SET label = ?, definition = ?, comment = ?, subset = ? WHERE id = ?',
        $label, $t->{def}, $t->{comment}, $subset, $t->{id})->rows;
        if ($n) { $upd++ }
        else {
            $db->query('INSERT INTO public.terms (id, label, definition, comment, subset) VALUES (?, ?, ?, ?, ?)',
            $t->{id}, $label, $t->{def}, $t->{comment}, $subset);
            $ins++;
        }
    }
    say "  terms: $upd aktualisiert, $ins neu";

    $db->query('DELETE FROM public.isas');
    my $n_isa = 0;
    for my $t (@active) {
        for my $p (@{ $t->{is_a} }) {
            next unless $ids{$p};
            $db->query('INSERT INTO public.isas (idparent, idchild) VALUES (?, ?)', $p, $t->{id});
            $n_isa++;
        }
    }
    say "  isas: $n_isa Relationen";

    # hpo_closure ist die transitive Hülle, die is_hpo_subclass()/is_subclass_of()
    # in SQL benutzen (Kohorten-Chat). Ohne Neuaufbau arbeitet der Chat mit der
    # alten Hierarchie, während das Perl-Matching über isas schon die neue nutzt.
    $db->query('DELETE FROM public.hpo_closure');
    my $n_cl = $db->query(q{
        INSERT INTO public.hpo_closure (idchild, idparent)
        WITH RECURSIVE c(idchild, idparent) AS (
        SELECT idchild, idparent FROM public.isas
        UNION
        SELECT c.idchild, i.idparent FROM c JOIN public.isas i ON i.idchild = c.idparent
        )
        SELECT idchild, idparent FROM c
    })->rows;
    say "  hpo_closure: $n_cl Paare";

    $db->query('DELETE FROM public.synonyms') unless $keep_syn;
    my $n_syn = 0;
    for my $t (@$terms) {
        my %seen;
        for my $s (grep { length && !$seen{ lc $_ }++ } @{ $t->{syn} }) {
            if ($keep_syn) {
                $n_syn += $db->query(q{
                    INSERT INTO public.synonyms (idterm, label)
                    SELECT ?::int, ?::text
                    WHERE NOT EXISTS (SELECT 1 FROM public.synonyms WHERE idterm = ?::int AND label = ?::text)
                }, $t->{id}, $s, $t->{id}, $s)->rows;
            } else {
                $db->query('INSERT INTO public.synonyms (idterm, label) VALUES (?, ?)', $t->{id}, $s);
                $n_syn++;
            }
        }
    }
    say "  synonyms: $n_syn " . ($keep_syn ? 'ergänzt (vorhandene behalten)' : 'geladen');

    $db->query('DELETE FROM public.xrefs');
    my $n_x = 0;
    for my $t (@$terms) {
        my %seen;
        for my $x (grep { !$seen{$_}++ } @{ $t->{xref} }) {
            $db->query('INSERT INTO public.xrefs (idterm, label) VALUES (?, ?)', $t->{id}, $x);
            $n_x++;
        }
    }
    say "  xrefs: $n_x";

    $db->query('DELETE FROM public.hpo_replacements');
    my $n_r = 0;
    my $add_repl = sub {
        my ($old, $new, $kind) = @_;
        $n_r += $db->query('INSERT INTO public.hpo_replacements (old_id, new_id, kind) VALUES (?, ?, ?) ON CONFLICT (old_id) DO NOTHING',
        $old, $new, $kind)->rows;
    };
    for my $t (@$terms) {
        $add_repl->($_, $t->{id}, 'alt_id') for @{ $t->{alt} };
        next unless $t->{obsolete};
        if    (@{ $t->{replaced} }) { $add_repl->($t->{id}, $t->{replaced}[0], 'replaced_by') }
        elsif (@{ $t->{consider} }) { $add_repl->($t->{id}, $t->{consider}[0], 'consider') }
    }
    say "  hpo_replacements: $n_r";

    record_version('hpo', $ver, $f, scalar @active);
    finish($tx);
}

# =========================================================
# ICD-10-GM / OPS (ClaML-XML des BfArM)
# =========================================================
sub pref_label {
    my ($node) = @_;
    my $l = $node->at('Rubric[kind="preferred"] > Label') // $node->at('Rubric[kind="preferredLong"] > Label');
    my $t = $l ? $l->all_text : '';
    $t =~ s/\s+/ /g;
    $t =~ s/^\s+|\s+$//g;
    return $t;
}

sub import_claml {
    my ($domain, $f) = @_;
    my $table = $domain eq 'icd10' ? 'icd10_terms' : 'ops_terms';

    my $bytes = path($f)->slurp;
    my ($enc) = $bytes =~ /^<\?xml[^>]*encoding="([^"]+)"/;
    my $xml = decode($enc // 'UTF-8', $bytes);
    $xml =~ s/<!DOCTYPE[^>\[]*>//;
    say "Parse $f (" . int(length($bytes) / 1e6) . " MB, kann einige Minuten und etwas RAM brauchen) ...";
    my $dom = Mojo::DOM->new->xml(1)->parse($xml);

    my $title = $dom->at('Title');
    my $ver   = length $version ? $version : ($title ? ($title->attr('version') // $title->attr('date') // '') : '');
    my $id_fmt      = $domain eq 'icd10' ? icd_id_format() : 'lowercase';
    my $with_struct = has_structure($table, $domain);

    my (%entry, @order, %modcls, @modified);
    for my $c ($dom->find('Class')->each) {
        my $code = $c->attr('code') // next;
        my $kind = $c->attr('kind') // '';
        next if !$with_struct && $kind ne 'category';
        my $sup = $c->at('SuperClass');
        $entry{$code} = { kind => $kind, parent => ($sup ? $sup->attr('code') : undef), label => pref_label($c) };
        push @order, $code;

        next unless $kind eq 'category';
        my %excl = map { ($_->attr('code') // '') => 1 } $c->find('ExcludeModifier')->each;
        my @mb = grep { !$excl{ $_->{code} } } map {
            {
                code  => $_->attr('code') // '',
                all   => (($_->attr('all') // 'true') eq 'true') ? 1 : 0,
                valid => [ map { $_->attr('code') // $_->text } $_->find('ValidModifierClass')->each ],
            }
        } $c->find('ModifiedBy')->each;
        push @modified, [ $code, \@mb ] if @mb;
    }
    for my $m ($dom->find('ModifierClass')->each) {
        push @{ $modcls{ $m->attr('modifier') // '' } }, { code => $m->attr('code') // '', label => pref_label($m) };
    }

    # Kodes, die in ClaML nur über Modifikatoren definiert sind (z. B. Lokalisations-
    # oder Zusatzstellen), explizit erzeugen. Explizite Klassen haben immer Vorrang.
    my $n_gen = 0;
    if (@modified && !$no_mod) {
        for my $pair (@modified) {
            my ($code, $mbs) = @$pair;
            my @stems = ($code);
            for my $mb (@$mbs) {
                my @mc = @{ $modcls{ $mb->{code} } // [] };
                if (!$mb->{all} && @{ $mb->{valid} }) {
                    my %v = map { $_ => 1 } @{ $mb->{valid} };
                    @mc = grep { $v{ $_->{code} } } @mc;
                }
                my @next;
                for my $s (@stems) {
                    for my $x (@mc) {
                        my $new = $s . $x->{code};
                        push @next, $new;
                        next if $entry{$new};
                        $entry{$new} = { kind => 'category', parent => $s, label => "$entry{$s}{label}: $x->{label}", generated => 1 };
                        push @order, $new;
                        $n_gen++;
                    }
                }
                @stems = @next if @next;
            }
        }
    }

    my $to_id = sub {
        my ($c) = @_;
        return undef unless defined $c;
        return lc $c if $domain eq 'ops';
        return ($id_fmt eq 'dotless' && $c =~ /^[A-Z]\d{2}\./) ? ($c =~ s/\.//gr) : $c;
    };

    my $n_cat = grep { $entry{$_}{kind} eq 'category' } @order;
    my $min   = $domain eq 'icd10' ? 10000 : 20000;
    say "\U$domain\E $ver: $n_cat Kodes"
    . ($n_gen ? " (davon $n_gen aus Modifikatoren erzeugt – Stichprobe gegen die BfArM-Systematik prüfen!)" : '')
    . ", Kapitel/Gruppen: " . ($with_struct ? 'ja' : 'nein') . ", ID-Format: $id_fmt";
    say "  Hinweis: " . scalar(@modified) . " Klassen tragen Modifikatoren, --no-modifiers aktiv" if @modified && $no_mod;
    sanity($n_cat > $min, "nur $n_cat Kodes gefunden (erwartet > $min)");

    # Kinder zählen (terminal) und Tiefe im neuen Baum bestimmen (Wurzel = 0)
    my (%has_child, %depth);
    for my $c (@order) {
        my $p = $entry{$c}{parent};
        $has_child{$p}++ if defined $p && $entry{$p};
    }
    my $depth_of;
    $depth_of = sub {
        my ($c) = @_;
        return $depth{$c} //= do {
            my $p = $entry{$c}{parent};
            (defined $p && $entry{$p} && $p ne $c) ? $depth_of->($p) + 1 : 0;
        };
    };

    my ($off, $off_src) = (0, '');
    if ($domain eq 'icd10') {
        ($off, $off_src) = icd_level_offset(\%entry, $depth_of, $to_id);
        my ($p) = grep { $entry{$_} } qw(A00 H35);
        say "  Ebenen: Dreisteller = " . ($depth_of->($p // $order[0]) + $off) . " ($off_src)";
    }

    my @rows = map {
        [ $to_id->($_), $entry{$_}{label}, $to_id->($entry{$_}{parent}), $_,
        $depth_of->($_) + $off, ($has_child{$_} ? 0 : 1) ]
    } @order;

    my $tx = $db->begin;
    replace_flat_table($table, \@rows);
    record_version($domain, $ver, $f, $n_cat);
    finish($tx);
}

# =========================================================
# ATC (CSV: Code;Bezeichnung – z. B. Export der amtlichen BfArM-Fassung)
# =========================================================
sub import_atc {
    my ($f) = @_;
    my $raw = path($f)->slurp;
    my $tmp = $raw;
    my $txt = eval { decode('UTF-8', $tmp, Encode::FB_CROAK) } // decode('cp1252', $raw);

    my (%label, @order);
    my $code_re = qr/^[A-Z](?:\d{2}(?:[A-Z](?:[A-Z](?:\d{2})?)?)?)?$/;
    for my $line (split /\r?\n/, $txt) {
        my @f = split /\t|;/, $line;
        s/^\s*"?|"?\s*$//g for @f;
        my ($i) = grep { $f[$_] =~ $code_re } 0 .. $#f;
        next unless defined $i;
        my $code = $f[$i];
        my ($lab) = grep { length && /\p{L}{3}/ && !/$code_re/ } @f[ $i + 1 .. $#f ];
        next unless defined $lab && !exists $label{$code};
        $label{$code} = $lab;
        push @order, $code;
    }

    my %plen = (3 => 1, 4 => 3, 5 => 4, 7 => 5);
    my @rows;
    for my $code (@order) {
        my $l   = $plen{ length $code };
        my $pid = $l ? substr($code, 0, $l) : undef;
        $pid = undef unless defined $pid && exists $label{$pid};
        push @rows, [ $code, $label{$code}, $pid, $code ];
    }

    my $ver = length $version ? $version : '';
    my $n7  = grep { length($_) == 7 } @order;
    say "ATC $ver: " . scalar(@order) . " Codes, davon $n7 Wirkstoffe (7-stellig)";
    sanity($n7 > 4000, "nur $n7 Wirkstoffcodes gefunden (Spaltenformat prüfen: Code;Bezeichnung)");

    my $tx = $db->begin;
    replace_flat_table('atc_terms', \@rows);
    record_version('atc', $ver, $f, scalar @order);
    finish($tx);
}

# =========================================================
# CHECK: alle verwendeten Codes gegen die aktuellen Tabellen prüfen
# =========================================================
sub code_info {
    my ($code) = @_;
    state %cache;
    return @{ $cache{$code} } if $cache{$code};

    my ($sys, $c) = split /:/, $code, 2;
    my $row = eval {
        $sys eq 'HP'    ? $db->query('SELECT label FROM public.terms WHERE id = ?', $c + 0)->hash
        : $sys eq 'ICD10' ? $db->query('SELECT label FROM public.icd10_terms WHERE id = ? OR id = ? LIMIT 1', $c, ($c =~ s/\.//gr))->hash
        : $sys eq 'OPS'   ? $db->query('SELECT label FROM public.ops_terms WHERE lower(id) = lower(?) LIMIT 1', $c)->hash
        : $sys eq 'ATC'   ? $db->query('SELECT label FROM public.atc_terms WHERE upper(id) = upper(?) LIMIT 1', $c)->hash
        :                   $db->query('SELECT label, status FROM public.loinc_terms WHERE id = ? LIMIT 1', $c)->hash;
    };

    my $flag = '';
    if (!$row) { $flag = 'fehlt' }
    elsif (($row->{label} // '') =~ /^\s*(?:obsolete|deprecated)\b/i
    || ($row->{status} // '') =~ /^(?:DEPRECATED|DISCOURAGED)$/i) { $flag = 'veraltet' }

    my $hint = '';
    if ($flag && $sys eq 'HP') {
        my $r = eval {
            $db->query(q{SELECT r.new_id, r.kind, t.label FROM public.hpo_replacements r
                LEFT JOIN public.terms t ON t.id = r.new_id WHERE r.old_id = ?}, $c + 0)->hash;
        };
        $hint = sprintf(' -> %s HP:%07d (%s)', $r->{kind}, $r->{new_id}, $r->{label} // '?') if $r;
    }
    $cache{$code} = [ $flag, $row ? $row->{label} : undef, $hint ];
    return @{ $cache{$code} };
}

sub check_codes {
    my ($src) = @_;
    my $re = qr/\b(HP:\d{7}|ICD10:[A-Z]\d{2}(?:\.[0-9A-Z]{1,2})?|OPS:\d-\d{2,3}(?:\.[0-9a-zA-Z]{1,3})?|ATC:[A-Z]\d{2}(?:[A-Z]{1,2}(?:\d{2})?)?|LOINC:\d{1,7}-\d[a-z]?)(?!\w)/;
    my %where;
    my $scan = sub {
        my ($text, $origin) = @_;
        return unless defined $text;
        $where{$1}{$origin}++ while $text =~ /$re/g;
    };

    if (defined $src) {
        die "Quelldatei nicht lesbar: $src\n" unless -r $src;
        $scan->(path($src)->slurp, 'Quellcode');
    }
    # Fest verdrahtete HPO-Nummern (ohne "HP:"-Präfix) in der SQL-Funktion stemmed_hpo_code
    my $fn = eval {
        $db->query(q{SELECT p.proname, pg_get_functiondef(p.oid) AS def
            FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = 'stemmed_hpo_code'})->hashes;
    } // [];
    for my $f (@$fn) {
        my $d = $f->{def};
        $where{"HP:$1"}{"SQL $f->{proname}"}++ while $d =~ /(?<!\d)(\d{7})(?!\d)/g;
    }

    my $ic = eval { $db->query(q{SELECT code FROM public.ontology_intercepts WHERE active AND NOT COALESCE(suppress, FALSE)})->hashes } // [];
    $scan->($_->{code}, 'Intercept') for @$ic;

    my $tr = eval { $db->query(q{SELECT id, fhir_group_json::text AS j FROM public.trials WHERE fhir_group_json IS NOT NULL})->hashes } // [];
    $scan->($_->{j}, "Studie $_->{id}") for @$tr;

    my $cd = eval { $db->query(q{SELECT phenopacket_json::text AS j FROM public.candidates WHERE phenopacket_json IS NOT NULL})->hashes } // [];
    $scan->($_->{j}, 'Kandidaten') for @$cd;

    my (@bad, $ok);
    for my $code (sort keys %where) {
        my ($flag, $label, $hint) = code_info($code);
        if (!$flag) { $ok++; next }
        my $src_str = join(', ', map { "$_ ×$where{$code}{$_}" } sort keys %{ $where{$code} });
        push @bad, sprintf("%-9s %-18s %-40s [%s]%s", $flag, $code, substr($label // '', 0, 40), $src_str, $hint);
    }

    say "Geprüft: " . scalar(keys %where) . " verschiedene Codes, " . ($ok // 0) . " in Ordnung, " . scalar(@bad) . " auffällig.";
    say "(Lokale LOINC-Codes wie 86290-4a sind nur ok, wenn sie in loinc_terms stehen.)";
    say $_ for @bad;
}
