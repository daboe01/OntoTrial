/*
 * ToolsController.j
 * Werkzeuge im Aktionsmenü der Candidates-ButtonBar:
 *   - Anonymisierter Export      -> POST /BBB/export/anonymized_phenopackets
 *   - Propensity Matching        -> POST /BBB/propensity_match
 *
 * Aufruf aus AppController.j über showAnonymizedExportAction: und
 * showPropensityMatchingAction: (siehe dort).
 */

@import <Foundation/Foundation.j>
@import <AppKit/AppKit.j>

var SharedToolsController = nil;

// --------------------------------------------------------------------------------
// Hilfsfunktionen
// --------------------------------------------------------------------------------

function OTTrim(s)
{
    return String(s || "").replace(/^\s+|\s+$/g, "");
}

function OTSafeName(s)
{
    var clean = OTTrim(s).replace(/[^A-Za-z0-9_\-]+/g, "_").substring(0, 40);
    return clean.length ? clean : "alle";
}

function OTYearMonth()
{
    var now = new Date();
    return now.getFullYear() + "-" + ("0" + (now.getMonth() + 1)).slice(-2);
}

function OTDownload(filename, text, mime)
{
    var blob = new Blob([text], { type: mime || "application/json;charset=utf-8" });
    var url  = URL.createObjectURL(blob);
    var a    = document.createElement("a");
    a.href = url;
    a.download = filename;
    a.style.display = "none";
    document.body.appendChild(a);
    a.click();
    setTimeout(function() {
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    }, 1000);
}

function OTCsvCell(v)
{
    var s = (v === undefined || v === null) ? "" : String(v);
    return /[",;\n]/.test(s) ? "\"" + s.replace(/"/g, "\"\"") + "\"" : s;
}

function OTPostJSON(url, payload, timeout, callback)
{
    var request = [CPURLRequest requestWithURL:url
                                   cachePolicy:CPURLRequestUseProtocolCachePolicy
                               timeoutInterval:timeout];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:JSON.stringify(payload)];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
    {
        var res = null;
        if (!error && data)
        {
            try { res = (typeof data === "string") ? JSON.parse(data) : data; }
            catch (e) { res = null; }
        }
        callback(res, error);
    }];
}

function OTLabel(frame, text, bold)
{
    var l = [[CPTextField alloc] initWithFrame:frame];
    [l setStringValue:text];
    [l setEditable:NO];
    [l setBezeled:NO];
    [l setDrawsBackground:NO];
    [l setLineBreakMode:CPLineBreakByWordWrapping];
    [l setFont:(bold ? [CPFont boldSystemFontOfSize:11.0] : [CPFont systemFontOfSize:11.0])];
    return l;
}

function OTField(frame, value, placeholder)
{
    var f = [[CPTextField alloc] initWithFrame:frame];
    [f setEditable:YES];
    [f setBezeled:YES];
    [f setStringValue:value || ""];
    if (placeholder)
        [f setPlaceholderString:placeholder];
    return f;
}

function OTButton(frame, title, target, action)
{
    var b = [[CPButton alloc] initWithFrame:frame];
    [b setTitle:title];
    [b setTarget:target];
    [b setAction:action];
    return b;
}

function OTCheckBox(frame, title, isOn)
{
    var c = [[CPCheckBox alloc] initWithFrame:frame];
    [c setTitle:title];
    [c setState:(isOn ? CPOnState : CPOffState)];
    return c;
}

// --------------------------------------------------------------------------------
// ToolsController
// --------------------------------------------------------------------------------

@implementation ToolsController : CPObject
{
    id              _app;

    // Anonymisierter Export
    CPWindow        _anonWindow;
    CPTextField     _anonTagField;
    CPTextField     _anonKField;
    CPTextField     _anonSummaryLabel;
    CPTextView      _anonPreviewView;
    CPButton        _anonRunButton;
    CPButton        _anonDownloadButton;
    id              _anonResult;
    CPString        _anonTag;

    // Propensity Matching
    CPWindow        _psmWindow;
    CPTextField     _psmTreatedTagField;
    CPTextField     _psmControlTagField;
    CPPopUpButton   _psmRatioPopUp;
    CPTextField     _psmCaliperField;
    CPCheckBox      _psmExactSexBox;
    CPCheckBox      _psmMirrorBox;
    CPCheckBox      _psmReplaceBox;
    id              _psmWeightFields;
    CPButton        _psmRunButton;
    CPTextField     _psmSummaryLabel;
    CPTableView     _psmTableView;
    id              _psmRows;
    id              _psmResult;
    CPTextField     _psmTagOutField;
}

+ (ToolsController)sharedController
{
    if (!SharedToolsController)
        SharedToolsController = [[ToolsController alloc] init];
    return SharedToolsController;
}

- (void)setAppController:(id)anAppController
{
    _app = anAppController;
}

// ================================================================================
// ANONYMISIERTER EXPORT
// ================================================================================

- (void)showAnonymizedExport:(id)sender
{
    if (!_anonWindow)
        [self _buildAnonymizedExportWindow];

    [_anonWindow center];
    [_anonWindow makeKeyAndOrderFront:self];
}

- (void)_buildAnonymizedExportWindow
{
    _anonWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 560, 470)
                                              styleMask:CPTitledWindowMask | CPClosableWindowMask];
    [_anonWindow setTitle:@"Anonymisierter Export (GA4GH Phenopackets)"];
    var cv = [_anonWindow contentView];

    [cv addSubview:OTLabel(CGRectMake(20, 15, 330, 18), "Kandidaten mit Tag:", YES)];
    _anonTagField = OTField(CGRectMake(20, 36, 330, 26), "", "z. B. Kohorte_AMD_2026 (leer = alle Kandidaten)");
    [cv addSubview:_anonTagField];

    [cv addSubview:OTLabel(CGRectMake(370, 15, 170, 18), "k-Anonymität (k ≥ 5):", YES)];
    _anonKField = OTField(CGRectMake(370, 36, 70, 26), "5", nil);
    [cv addSubview:_anonKField];

    var note = "Exportiert werden nur validierte Ontologie-Codes mit kanonischem Label, Monatsdaten mit "
             + "patientenkonstantem Versatz (±1–3 Monate), Alter in Jahren (ab 90 zusammengefasst) und "
             + "Codes, die mindestens k Patienten teilen. Die Zuordnung zu Pseudonymen wird nicht gespeichert. "
             + "Export nur durch die Studienleitung.";
    [cv addSubview:OTLabel(CGRectMake(20, 74, 520, 64), note, NO)];

    _anonRunButton = OTButton(CGRectMake(20, 146, 150, 26), "Export erzeugen", self, @selector(runAnonymizedExport:));
    [cv addSubview:_anonRunButton];

    _anonDownloadButton = OTButton(CGRectMake(180, 146, 170, 26), "JSON herunterladen", self, @selector(downloadAnonymizedExport:));
    [_anonDownloadButton setEnabled:NO];
    [cv addSubview:_anonDownloadButton];

    _anonSummaryLabel = OTLabel(CGRectMake(20, 182, 520, 44), "Noch kein Export erzeugt.", NO);
    [cv addSubview:_anonSummaryLabel];

    [cv addSubview:OTLabel(CGRectMake(20, 232, 520, 18), "Vorschau (ein zufälliges Phenopacket):", YES)];

    var scroll = [[CPScrollView alloc] initWithFrame:CGRectMake(20, 254, 520, 196)];
    [scroll setHasHorizontalScroller:NO];
    [scroll setAutohidesScrollers:YES];
    _anonPreviewView = [[CPTextView alloc] initWithFrame:[scroll bounds]];
    [_anonPreviewView setAutoresizingMask:CPViewWidthSizable];
    [_anonPreviewView setEditable:NO];
    [_anonPreviewView setSelectable:YES];
    [_anonPreviewView setFont:[CPFont fontWithName:@"Courier" size:10.0]];
    [scroll setDocumentView:_anonPreviewView];
    [cv addSubview:scroll];
}

- (void)runAnonymizedExport:(id)sender
{
    var tag = OTTrim([_anonTagField stringValue]);
    if (!tag.length && !confirm("Ohne Tag werden alle Kandidaten mit Phenopacket exportiert. Fortfahren?"))
        return;

    var k = parseInt([_anonKField stringValue], 10);
    if (isNaN(k) || k < 5)
        k = 5;
    [_anonKField setStringValue:String(k)];

    _anonResult = nil;
    _anonTag = tag;
    [_anonPreviewView setString:@""];
    [_anonDownloadButton setEnabled:NO];
    [_anonRunButton setEnabled:NO];
    [_anonSummaryLabel setStringValue:@"Export läuft…"];

    var taskId = "anon_export";
    [_app addTaskWithName:@"Anonymisierter Export" identifier:taskId];
    [_app updateTaskWithIdentifier:taskId state:@"active" message:@"Erzeuge Phenopackets…" progress:30];

    var payload = { "k": k };
    if (tag.length)
        payload.tag = tag;

    OTPostJSON("/BBB/export/anonymized_phenopackets", payload, 1800.0, function(res, error)
    {
        [_anonRunButton setEnabled:YES];

        if (res && res.phenopackets)
        {
            _anonResult = res;
            var s = res.suppression || {};
            var summary = res.n_subjects + " Patient(en), " + res.n_phenopackets + " Phenopacket(s), k = " + res.k + ".\n"
                        + "Unterdrückt: " + (s.codes_suppressed || 0)
                        + " · verallgemeinert: " + (s.codes_generalized || 0)
                        + " · ohne Label: " + (s.codes_unresolved || 0)
                        + " · Werte verworfen: " + (s.values_dropped || 0);
            [_anonSummaryLabel setStringValue:summary];
            [_anonPreviewView setString:(res.phenopackets.length ? JSON.stringify(res.phenopackets[0], null, 2) : "")];
            [_anonDownloadButton setEnabled:(res.phenopackets.length > 0)];
            [_app updateTaskWithIdentifier:taskId state:@"finished" message:@"Export erzeugt" progress:100];
        }
        else
        {
            var msg = (res && res.error) ? res.error : (error ? [error description] : "Unbekannter Fehler");
            [_anonSummaryLabel setStringValue:@"Fehler: " + msg];
            [_app updateTaskWithIdentifier:taskId state:@"failed" message:@"Export fehlgeschlagen" progress:0];
        }
    });
}

- (void)downloadAnonymizedExport:(id)sender
{
    if (!_anonResult)
        return;
    OTDownload("ontotrial_anonym_" + OTSafeName(_anonTag) + "_" + OTYearMonth() + ".json",
               JSON.stringify(_anonResult, null, 2));
}

// ================================================================================
// PROPENSITY MATCHING
// ================================================================================

- (void)showPropensityMatching:(id)sender
{
    if (!_psmWindow)
        [self _buildPropensityMatchingWindow];

    [_psmWindow center];
    [_psmWindow makeKeyAndOrderFront:self];
}

- (void)_buildPropensityMatchingWindow
{
    _psmRows = [];
    _psmWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 640, 540)
                                             styleMask:CPTitledWindowMask | CPClosableWindowMask];
    [_psmWindow setTitle:@"Propensity Matching (Phenopacket-Distanz)"];
    var cv = [_psmWindow contentView];

    // --- Kohorten ---
    [cv addSubview:OTLabel(CGRectMake(20, 15, 280, 18), "Fälle (Tag):", YES)];
    _psmTreatedTagField = OTField(CGRectMake(20, 36, 280, 26), "", "z. B. Kohorte_DMEK");
    [cv addSubview:_psmTreatedTagField];

    [cv addSubview:OTLabel(CGRectMake(320, 15, 300, 18), "Kontrollpool (Tag, leer = alle Kandidaten):", YES)];
    _psmControlTagField = OTField(CGRectMake(320, 36, 300, 26), "", "z. B. Kontrollen_Hornhaut");
    [cv addSubview:_psmControlTagField];

    // --- Optionen ---
    [cv addSubview:OTLabel(CGRectMake(20, 76, 80, 18), "Verhältnis 1:", NO)];
    _psmRatioPopUp = [[CPPopUpButton alloc] initWithFrame:CGRectMake(100, 71, 60, 26) pullsDown:NO];
    [_psmRatioPopUp addItemsWithTitles:["1", "2", "3", "4", "5"]];
    [cv addSubview:_psmRatioPopUp];

    [cv addSubview:OTLabel(CGRectMake(180, 76, 60, 18), "Caliper:", NO)];
    _psmCaliperField = OTField(CGRectMake(235, 71, 70, 26), "0.35", "keiner");
    [cv addSubview:_psmCaliperField];

    _psmExactSexBox = OTCheckBox(CGRectMake(325, 75, 140, 20), "Geschlecht exakt", YES);
    [cv addSubview:_psmExactSexBox];

    _psmMirrorBox = OTCheckBox(CGRectMake(470, 75, 150, 20), "Augen spiegeln", YES);
    [cv addSubview:_psmMirrorBox];

    _psmReplaceBox = OTCheckBox(CGRectMake(20, 104, 250, 20), "Kontrollen mehrfach verwenden", NO);
    [cv addSubview:_psmReplaceBox];

    // --- Gewichte ---
    [cv addSubview:OTLabel(CGRectMake(20, 132, 400, 18), "Gewichte der Merkmalsblöcke:", YES)];
    var weights = [
        { key: "demographics", title: "Demografie",  value: "0.15" },
        { key: "diseases",     title: "Diagnosen",   value: "0.25" },
        { key: "phenotypes",   title: "Phänotypen",  value: "0.20" },
        { key: "procedures",   title: "Prozeduren",  value: "0.15" },
        { key: "medications",  title: "Medikation",  value: "0.10" },
        { key: "measurements", title: "Messwerte",   value: "0.15" }
    ];
    _psmWeightFields = [];
    for (var i = 0; i < weights.length; i++)
    {
        var x = 20 + i * 102;
        [cv addSubview:OTLabel(CGRectMake(x, 152, 96, 16), weights[i].title, NO)];
        var f = OTField(CGRectMake(x, 170, 90, 26), weights[i].value, nil);
        [cv addSubview:f];
        _psmWeightFields.push({ key: weights[i].key, field: f });
    }

    // --- Start & Zusammenfassung ---
    _psmRunButton = OTButton(CGRectMake(20, 210, 150, 26), "Matching starten", self, @selector(runPropensityMatching:));
    [cv addSubview:_psmRunButton];

    _psmSummaryLabel = OTLabel(CGRectMake(180, 206, 440, 36), "Noch kein Matching durchgeführt.", NO);
    [cv addSubview:_psmSummaryLabel];

    // --- Ergebnistabelle ---
    var scroll = [[CPScrollView alloc] initWithFrame:CGRectMake(20, 248, 600, 236)];
    [scroll setAutohidesScrollers:YES];

    _psmTableView = [[CPTableView alloc] initWithFrame:[scroll bounds]];
    [_psmTableView setUsesAlternatingRowBackgroundColors:YES];
    [_psmTableView setAllowsMultipleSelection:NO];

    var cols = [
        ["treated",  "Fall (Pseudonym)",      190],
        ["control",  "Kontrolle (Pseudonym)", 190],
        ["distance", "Distanz",                90],
        ["mirrored", "Gespiegelt",             90]
    ];
    for (var c = 0; c < cols.length; c++)
    {
        var col = [[CPTableColumn alloc] initWithIdentifier:cols[c][0]];
        [[col headerView] setStringValue:cols[c][1]];
        [col setWidth:cols[c][2]];
        [col setEditable:NO];
        [_psmTableView addTableColumn:col];
    }

    [_psmTableView setDataSource:self];
    [_psmTableView setDelegate:self];
    [_psmTableView setTarget:self];
    [_psmTableView setDoubleAction:@selector(psmDoubleClick:)];
    [scroll setDocumentView:_psmTableView];
    [cv addSubview:scroll];

    // --- Nachbearbeitung ---
    _psmTagOutField = OTField(CGRectMake(20, 496, 210, 26), "", "Tag für Kontrollen…");
    [cv addSubview:_psmTagOutField];
    [cv addSubview:OTButton(CGRectMake(240, 496, 140, 26), "Kontrollen taggen", self, @selector(tagPropensityControls:))];
    [cv addSubview:OTButton(CGRectMake(390, 496, 130, 26), "CSV exportieren", self, @selector(exportPropensityCSV:))];
}

- (void)runPropensityMatching:(id)sender
{
    var treatedTag = OTTrim([_psmTreatedTagField stringValue]);
    if (!treatedTag.length)
    {
        alert("Bitte ein Tag für die Fälle angeben.");
        return;
    }
    var controlTag = OTTrim([_psmControlTagField stringValue]);

    var payload = {
        "treated_tag": treatedTag,
        "ratio":       parseInt([_psmRatioPopUp titleOfSelectedItem], 10) || 1,
        "mirror":      ([_psmMirrorBox state] === CPOnState),
        "replace":     ([_psmReplaceBox state] === CPOnState),
        "exact":       ([_psmExactSexBox state] === CPOnState) ? ["sex"] : [],
        "weights":     {}
    };
    if (controlTag.length)
        payload.control_tag = controlTag;

    var caliper = parseFloat(String([_psmCaliperField stringValue]).replace(",", "."));
    if (!isNaN(caliper) && caliper > 0)
        payload.caliper = caliper;

    for (var i = 0; i < _psmWeightFields.length; i++)
    {
        var w = parseFloat(String([_psmWeightFields[i].field stringValue]).replace(",", "."));
        if (!isNaN(w))
            payload.weights[_psmWeightFields[i].key] = (w < 0) ? 0 : w;
    }

    _psmResult = nil;
    _psmRows = [];
    [_psmTableView reloadData];
    [_psmRunButton setEnabled:NO];
    [_psmSummaryLabel setStringValue:@"Matching läuft… (Aufwand wächst mit Fälle × Kontrollen)"];

    var taskId = "propensity_matching";
    [_app addTaskWithName:@"Propensity Matching: " + treatedTag identifier:taskId];
    [_app updateTaskWithIdentifier:taskId state:@"active" message:@"Berechne Distanzen…" progress:30];

    OTPostJSON("/BBB/propensity_match", payload, 3000.0, function(res, error)
    {
        [_psmRunButton setEnabled:YES];

        if (res && res.matches)
        {
            _psmResult = res;
            _psmRows = [];
            for (var i = 0; i < res.matches.length; i++)
            {
                var m = res.matches[i];
                var treatedLabel = m.treated_pseudonym || ("ID " + m.treated_id);
                var controls = m.controls || [];
                if (!controls.length)
                {
                    _psmRows.push({ treated: treatedLabel, treated_id: m.treated_id, treated_pseudonym: m.treated_pseudonym,
                                    control: "–", distance: "", mirrored: "" });
                    continue;
                }
                for (var j = 0; j < controls.length; j++)
                {
                    var k = controls[j];
                    _psmRows.push({
                        treated: treatedLabel, treated_id: m.treated_id, treated_pseudonym: m.treated_pseudonym,
                        control: k.pseudonym || ("ID " + k.candidate_id), control_id: k.candidate_id, control_pseudonym: k.pseudonym,
                        distance: (typeof k.distance === "number") ? k.distance.toFixed(3) : String(k.distance || ""),
                        mirrored: k.mirrored ? "ja" : "nein"
                    });
                }
            }
            [_psmTableView reloadData];

            var mean = (res.mean_distance !== null && res.mean_distance !== undefined) ? Number(res.mean_distance).toFixed(3) : "–";
            var summary = "Fälle: " + res.n_treated + " · Kontrollpool: " + res.n_controls_pool
                        + " · vollständig gematcht: " + res.n_fully_matched
                        + " · ohne Partner: " + (res.unmatched ? res.unmatched.length : 0)
                        + " · mittlere Distanz: " + mean;
            [_psmSummaryLabel setStringValue:summary];
            [_app updateTaskWithIdentifier:taskId state:@"finished" message:@"Abgeschlossen" progress:100];
        }
        else
        {
            var msg = (res && res.error) ? res.error : (error ? [error description] : "Unbekannter Fehler");
            [_psmSummaryLabel setStringValue:@"Fehler: " + msg];
            [_app updateTaskWithIdentifier:taskId state:@"failed" message:@"Matching fehlgeschlagen" progress:0];
        }
    });
}

- (void)psmDoubleClick:(id)sender
{
    var row = [_psmTableView clickedRow];
    if (row < 0 || row >= _psmRows.length)
        return;

    var r = _psmRows[row];
    var useTreated = ([_psmTableView clickedColumn] === 0) || !r.control_id;
    var target = useTreated ? (r.treated_pseudonym || String(r.treated_id))
                            : (r.control_pseudonym || String(r.control_id));
    if (!target)
        return;

    if (_app.mainWorkspaceTab)
        [_app.mainWorkspaceTab selectTabViewItemAtIndex:0];
    [_app setCandidateFilterString:target];
    [_app loadAndSelectCandidate:target];
}

- (void)tagPropensityControls:(id)sender
{
    var tag = OTTrim([_psmTagOutField stringValue]);
    if (!tag.length)
    {
        alert("Bitte einen Tag-Namen für die Kontrollen eingeben.");
        return;
    }

    var seen = {}, pseudonyms = [];
    for (var i = 0; i < _psmRows.length; i++)
    {
        var p = _psmRows[i].control_pseudonym;
        if (p && !seen[p])
        {
            seen[p] = true;
            pseudonyms.push(p);
        }
    }
    if (!pseudonyms.length)
    {
        alert("Keine gematchten Kontrollen mit Pseudonym vorhanden.");
        return;
    }

    [sender setEnabled:NO];
    OTPostJSON("/BBB/candidates/batch_tag", { "tag": tag, "pseudonyms": pseudonyms, "append": 1 }, 120.0, function(res, error)
    {
        [sender setEnabled:YES];
        if (res && res.success)
        {
            alert("Erfolgreich: " + (res.updated || 0) + " Datensatz/Datensätze mit Tag '" + tag + "' versehen.");

            var cc = [_app candidatesController];
            if (cc && cc._entity)
            {
                cc._entity._refreshCachedObjects = YES;
                [cc setContent:[cc._entity allObjects]];
                cc._entity._refreshCachedObjects = NO;
            }
            [_app updateCandidateFilter];
        }
        else
        {
            var msg = (res && res.error) ? res.error : (error ? [error description] : "Unbekannter Fehler");
            alert("Fehler beim Taggen: " + msg);
        }
    });
}

- (void)exportPropensityCSV:(id)sender
{
    if (!_psmRows || !_psmRows.length)
    {
        alert("Keine Matching-Ergebnisse vorhanden.");
        return;
    }

    var lines = ["treated_pseudonym;treated_id;control_pseudonym;control_id;distance;mirrored"];
    for (var i = 0; i < _psmRows.length; i++)
    {
        var r = _psmRows[i];
        lines.push([
            OTCsvCell(r.treated_pseudonym), OTCsvCell(r.treated_id),
            OTCsvCell(r.control_pseudonym), OTCsvCell(r.control_id),
            OTCsvCell(r.distance), OTCsvCell(r.mirrored)
        ].join(";"));
    }
    OTDownload("psm_" + OTSafeName([_psmTreatedTagField stringValue]) + "_" + OTYearMonth() + ".csv",
               "\uFEFF" + lines.join("\n") + "\n", "text/csv;charset=utf-8");
}

// --------------------------------------------------------------------------------
// Datenquelle der Ergebnistabelle
// --------------------------------------------------------------------------------

- (int)numberOfRowsInTableView:(CPTableView)aTableView
{
    return (aTableView === _psmTableView && _psmRows) ? _psmRows.length : 0;
}

- (id)tableView:(CPTableView)aTableView objectValueForTableColumn:(CPTableColumn)aColumn row:(int)row
{
    if (aTableView !== _psmTableView || !_psmRows || row >= _psmRows.length)
        return nil;
    return _psmRows[row][[aColumn identifier]];
}

@end
