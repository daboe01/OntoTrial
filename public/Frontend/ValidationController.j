/*
 * ValidationController.j
 * Validierung der Phenopacket-Extraktion:
 *   - Prüfen       Briefe eines Validierungsdatensatzes bewerten (Teil B),
 *                  fehlende Einträge ergänzen, bei Studien zuerst blind die
 *                  Checkliste ausfüllen (Teil A)
 *   - Referenz & Regression
 *                  Stand der Prüfung, Referenz einfrieren, Regressionsläufe
 *                  gegen die Referenz starten und vergleichen
 *   - Studie       Kennzahlen nach Bewertungshandbuch, Rohdaten als CSV
 *   - KI-Judge     Claude (extern) und/oder ein lokales Modell wie GLM-5 bewerten die
 *                  Briefe automatisch; liefert eine
 *                  KI-Referenz für Regressionstests und wird in der Studie
 *                  gegen die Ärzte gemessen
 *
 * Aufruf: Aktionsmenü „Validierung …“ (wird beim Start hinter
 * „Propensity Matching“ eingehängt) -> AppController showValidationAction:
 * Backend: /BBB/validation/...
 */

@import <Foundation/Foundation.j>
@import <AppKit/AppKit.j>
@import "ToolsController.j"

var SharedValidationController = nil;
var OVConsensusName = "Konsens";
var OVReviewerStorageKey = "ontotrial_validation_reviewer";

var OVDomains      = ["disease", "phenotype", "procedure", "treatment", "measurement"];
var OVDomainTitles = { disease: "Diagnose", phenotype: "Befund", procedure: "Eingriff", treatment: "Medikation", measurement: "Messwert" };
var OVResolveDomain = { disease: "icd10", phenotype: "hpo", procedure: "ops", treatment: "atc", measurement: "loinc" };
var OVSideTitles   = { R: "RA", L: "LA", B: "bds.", "": "", "?": "?" };

var OVConceptOpts = [["ok", "korrekt"], ["broader", "zu allgemein"], ["narrower", "zu spezifisch"],
                     ["wrong", "falsches Konzept"], ["absent", "nicht im Brief"], ["wrong_subject", "falscher Bezug"]];
var OVStatusOpts  = [["ok", "korrekt"], ["negation", "Verneinung falsch"], ["suspected", "Verdacht als gesichert"],
                     ["planned", "Geplantes als erfolgt"]];
var OVAttrOpts    = [["ok", "korrekt"], ["wrong", "falsch"], ["missing", "fehlt"], ["superfluous", "überflüssig"],
                     ["na", "nicht anwendbar"]];
var OVValueOpts   = [["ok", "korrekt"], ["wrong", "falsch"], ["na", "nicht anwendbar"]];
var OVSideOpts    = [["", "– unbekannt –"], ["R", "RA"], ["L", "LA"], ["B", "beidseits"], ["none", "keine Seite"]];
var OVChecklistCats = ["Augen", "Diagnose", "Eingriff", "Medikation", "Visus", "Tensio", "Messwert"];
var OVMatchTitles = { "": "", found: "gefunden", attr: "Attributfehler", missing: "fehlt" };

function OVOptTitle(opts, key)
{
    for (var i = 0; i < opts.length; i++)
        if (opts[i][0] === key)
            return opts[i][1];
    return key || "";
}

function OVPopUp(frame, opts)
{
    var p = [[CPPopUpButton alloc] initWithFrame:frame pullsDown:NO];
    for (var i = 0; i < opts.length; i++)
        [p addItemWithTitle:opts[i][1]];
    return p;
}

function OVPopUpSelect(popUp, opts, key)
{
    for (var i = 0; i < opts.length; i++)
        if (opts[i][0] === key)
        {
            [popUp selectItemAtIndex:i];
            return;
        }
    [popUp selectItemAtIndex:0];
}

function OVPopUpKey(popUp, opts)
{
    var i = [popUp indexOfSelectedItem];
    return (i >= 0 && i < opts.length) ? opts[i][0] : "";
}

function OVJudgmentText(j)
{
    if (!j)
        return "–";
    if (j.verdict === "correct")
        return "korrekt";
    if (j.verdict === "duplicate")
        return "Dublette";
    if (j.verdict === "unclear")
        return "unklar";

    var parts = [];
    if (j.concept && j.concept !== "ok")
        parts.push(OVOptTitle(OVConceptOpts, j.concept));
    if (j.status && j.status !== "ok")
        parts.push(OVOptTitle(OVStatusOpts, j.status));
    if (j.side && j.side !== "ok" && j.side !== "na")
        parts.push("Seite " + OVOptTitle(OVAttrOpts, j.side));
    if (j.date && j.date !== "ok" && j.date !== "na")
        parts.push("Datum " + OVOptTitle(OVAttrOpts, j.date));
    if (j.value && j.value !== "ok" && j.value !== "na")
        parts.push("Wert " + OVOptTitle(OVValueOpts, j.value));
    return parts.length ? parts.join(", ") : "Fehler";
}

function OVPct(v)
{
    return (v === undefined || v === null) ? "–" : (100 * v).toFixed(1) + " %";
}

function OVPctCI(v, ci)
{
    var s = OVPct(v);
    if (ci && ci.length === 2)
        s += " (" + (100 * ci[0]).toFixed(1) + "–" + (100 * ci[1]).toFixed(1) + ")";
    return s;
}

function OVPad(s, n)
{
    s = String(s === undefined || s === null ? "" : s);
    while (s.length < n)
        s += " ";
    return s;
}

function OVSend(method, url, payload, timeout, callback)
{
    var request = [CPURLRequest requestWithURL:url
                                   cachePolicy:CPURLRequestUseProtocolCachePolicy
                               timeoutInterval:timeout];
    [request setHTTPMethod:method];
    if (payload)
    {
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setHTTPBody:JSON.stringify(payload)];
    }
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

// Autoresizing-Maske setzen und View zurückgeben
function OVM(view, mask)
{
    [view setAutoresizingMask:mask];
    return view;
}

function OVTable(frame, cols, owner)
{
    var scroll = [[CPScrollView alloc] initWithFrame:frame];
    [scroll setAutohidesScrollers:YES];
    var table = [[CPTableView alloc] initWithFrame:[scroll bounds]];
    [table setUsesAlternatingRowBackgroundColors:YES];
    [table setAllowsMultipleSelection:NO];
    for (var c = 0; c < cols.length; c++)
    {
        var col = [[CPTableColumn alloc] initWithIdentifier:cols[c][0]];
        [[col headerView] setStringValue:cols[c][1]];
        [col setWidth:cols[c][2]];
        [col setEditable:NO];
        [table addTableColumn:col];
    }
    [table setDataSource:owner];
    [table setDelegate:owner];
    [scroll setDocumentView:table];
    return { scroll: scroll, table: table };
}

function OVTextArea(frame, monospace)
{
    var scroll = [[CPScrollView alloc] initWithFrame:frame];
    [scroll setHasHorizontalScroller:NO];
    [scroll setAutohidesScrollers:YES];
    var tv = [[CPTextView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width - 16, frame.size.height)];
    [tv setEditable:NO];
    [tv setAutoresizingMask:CPViewWidthSizable];
    [tv setFont:(monospace ? [CPFont fontWithName:@"Menlo, Monaco, monospace" size:11.0] : [CPFont systemFontOfSize:12.0])];
    [scroll setDocumentView:tv];
    return { scroll: scroll, text: tv };
}

@implementation ValidationController : CPObject
{
    id              _app;
    CPWindow        _window;
    CPPopUpButton   _setPopUp;
    CPTextField     _reviewerField;
    CPTextField     _setInfoLabel;
    id              _sets;
    id              _currentSet;

    // Prüfen
    CPTableView     _itemsTable;
    CPTextField     _progressLabel;
    CPTextField     _letterHeader;
    CPTextView      _letterView;
    CPTableView     _entriesTable;
    CPView          _entriesBox;
    CPTextField     _blindLabel;
    CPButton        _showExtractionButton;
    CPTableView     _missingTable;
    CPView          _checklistBox;
    CPTableView     _checklistTable;
    CPButton        _doneButton;
    id              _items;
    id              _item;
    id              _judgments;
    id              _missing;
    id              _checklist;

    // Fehler-Panel
    CPWindow        _errorPanel;
    CPPopUpButton   _ePConcept;
    CPPopUpButton   _ePStatus;
    CPPopUpButton   _ePSide;
    CPPopUpButton   _ePSideCorrect;
    CPPopUpButton   _ePDate;
    CPTextField     _ePDateCorrect;
    CPPopUpButton   _ePValue;
    CPTextField     _ePValueCorrect;
    CPTextField     _ePComment;
    CPTextField     _ePTitle;

    // Eintrag-Panel (fehlender Eintrag / Checklistenzeile)
    CPWindow        _entryPanel;
    CPString        _entryMode;
    CPTextField     _enTitle;
    CPPopUpButton   _enDomain;
    CPTextField     _enLabel;
    CPTextField     _enCode;
    CPButton        _enLookup;
    CPPopUpButton   _enSide;
    CPTextField     _enDate;
    CPTextField     _enValue;
    CPTextField     _enUnit;
    CPCheckBox      _enExcluded;

    // Neuer Datensatz
    CPWindow        _newPanel;
    CPTextField     _nsName;
    CPPopUpButton   _nsPurpose;
    CPTextField     _nsSize;
    CPTextField     _nsSeed;
    CPTextField     _nsTag;
    CPTextField     _nsDouble;
    CPTextField     _nsInject;
    CPCheckBox      _nsPerPatient;
    CPTextField     _nsConfirm;

    // Referenz & Regression
    CPTextView      _statusView;
    CPTableView     _runsTable;
    CPTextView      _runDetailView;
    id              _runs;
    id              _pollTimer;
    BOOL            _runsActive;
    BOOL            _judgeActive;
    id              _judgeStatus;
    CPString        _statusText;
    CPString        _judgeText;

    // Studie
    CPTextView      _studyView;
}

+ (ValidationController)sharedController
{
    if (!SharedValidationController)
        SharedValidationController = [[ValidationController alloc] init];
    return SharedValidationController;
}

// --------------------------------------------------------------------------------
// Menüeintrag „Validierung …“ hinter „Propensity Matching“ einhängen
// --------------------------------------------------------------------------------

+ (BOOL)installMenuItemWithTarget:(id)aTarget
{
    var windows = [CPApp windows];
    for (var w = 0; w < windows.length; w++)
        if ([self _installInView:[windows[w] contentView] target:aTarget])
            return YES;

    if ([CPApp mainMenu] && [self _installInMenu:[CPApp mainMenu] target:aTarget])
        return YES;

    console.warn("[Validierung] Aktionsmenü nicht gefunden. Menüeintrag in gui.gsmarkup ergänzen: " +
                 "<menuItem title=\"Validierung …\" action=\"showValidationAction:\" target=\"#CPOwner\"/>");
    return NO;
}

+ (BOOL)_installInView:(CPView)aView target:(id)aTarget
{
    if (!aView)
        return NO;

    if ([aView respondsToSelector:@selector(menu)])
    {
        var menu = [aView menu];
        if (menu && [self _installInMenu:menu target:aTarget])
            return YES;
    }

    if ([aView isKindOfClass:[CPTabView class]])
    {
        var tabItems = [aView tabViewItems];
        for (var t = 0; t < tabItems.length; t++)
            if ([self _installInView:[tabItems[t] view] target:aTarget])
                return YES;
    }

    var subviews = [aView subviews];
    for (var i = 0; i < subviews.length; i++)
        if ([self _installInView:subviews[i] target:aTarget])
            return YES;
    return NO;
}

+ (BOOL)_installInMenu:(CPMenu)aMenu target:(id)aTarget
{
    var items = [aMenu itemArray];
    for (var i = 0; i < items.length; i++)
        if ([items[i] action] === @selector(showValidationAction:))
            return YES;

    for (var i = 0; i < items.length; i++)
    {
        if ([items[i] action] === @selector(showPropensityMatchingAction:))
        {
            var item = [[CPMenuItem alloc] initWithTitle:@"Validierung …" action:@selector(showValidationAction:) keyEquivalent:@""];
            [item setTarget:aTarget];
            [aMenu insertItem:item atIndex:i + 1];
            return YES;
        }
        if ([items[i] hasSubmenu] && [self _installInMenu:[items[i] submenu] target:aTarget])
            return YES;
    }
    return NO;
}

- (void)setAppController:(id)anAppController
{
    _app = anAppController;
}

- (CPString)reviewer
{
    return OTTrim([_reviewerField stringValue]);
}

- (BOOL)isConsensus
{
    return [self reviewer] === OVConsensusName;
}

// ================================================================================
// FENSTER
// ================================================================================

- (void)show:(id)sender
{
    if (!_window)
        [self _buildWindow];

    [self _fitWindowToScreen];
    [_window makeKeyAndOrderFront:self];
    [self loadSets:nil];
}

- (void)_buildWindow
{
    _items = [];
    _judgments = {};
    _missing = [];
    _checklist = { lines: [], done: 0 };
    _runs = [];

    _window = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 1300, 800)
                                          styleMask:CPTitledWindowMask | CPClosableWindowMask | CPResizableWindowMask];
    [_window setMinSize:CGSizeMake(1000, 560)];
    [_window setTitle:@"Validierung der Extraktion"];
    [_window setDelegate:self];
    var cv = [_window contentView];

    [cv addSubview:OTLabel(CGRectMake(15, 17, 70, 18), "Datensatz:", YES)];
    _setPopUp = [[CPPopUpButton alloc] initWithFrame:CGRectMake(85, 12, 320, 26) pullsDown:NO];
    [_setPopUp setTarget:self];
    [_setPopUp setAction:@selector(setChanged:)];
    [cv addSubview:_setPopUp];
    [cv addSubview:OTButton(CGRectMake(415, 12, 150, 26), "Neuer Datensatz …", self, @selector(showNewSetPanel:))];
    [cv addSubview:OTButton(CGRectMake(575, 12, 150, 26), "Sicherung laden", self, @selector(exportSet:))];

    [cv addSubview:OTLabel(CGRectMake(745, 17, 50, 18), "Prüfer:", YES)];
    var stored = "";
    try { stored = window.localStorage.getItem(OVReviewerStorageKey) || ""; } catch (e) { stored = ""; }
    _reviewerField = OTField(CGRectMake(795, 12, 150, 26), stored, "Name");
    [_reviewerField setTarget:self];
    [_reviewerField setAction:@selector(reviewerChanged:)];
    [cv addSubview:_reviewerField];

    _setInfoLabel = OVM(OTLabel(CGRectMake(960, 10, 330, 32), "", NO), CPViewWidthSizable);
    [_setInfoLabel setTextColor:[CPColor grayColor]];
    [cv addSubview:_setInfoLabel];

    var tabView = OVM([[CPTabView alloc] initWithFrame:CGRectMake(10, 46, 1280, 744)], CPViewWidthSizable | CPViewHeightSizable);
    [tabView setDelegate:self];
    [tabView addTabViewItem:[self _tabWithId:"review" label:"Prüfen" view:[self _buildReviewView]]];
    [tabView addTabViewItem:[self _tabWithId:"regression" label:"Referenz & Regression" view:[self _buildRegressionView]]];
    [tabView addTabViewItem:[self _tabWithId:"study" label:"Studie" view:[self _buildStudyView]]];
    [cv addSubview:tabView];
    [self _fitWindowToScreen];
}

// Fenster auf die sichtbare Browserfläche verkleinern; die Inhalte passen sich über ihre Masken an
- (void)_fitWindowToScreen
{
    var availW = (window.innerWidth || 1320) - 20,
        availH = (window.innerHeight || 840) - 30;
    var frame = [_window frame];
    var w = MAX(1000, MIN(frame.size.width, availW)),
        h = MAX(560, MIN(frame.size.height, availH));
    [_window setFrame:CGRectMake(MAX(0, (availW - w) / 2), 10, w, h)];
}

- (CPTabViewItem)_tabWithId:(CPString)anId label:(CPString)aLabel view:(CPView)aView
{
    var item = [[CPTabViewItem alloc] initWithIdentifier:anId];
    [item setLabel:aLabel];
    [aView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [item setView:aView];
    return item;
}

- (void)windowWillClose:(CPNotification)aNotification
{
    [self _stopPolling];
}

- (void)reviewerChanged:(id)sender
{
    try { window.localStorage.setItem(OVReviewerStorageKey, [self reviewer]); } catch (e) {}
    [self loadItems:nil];
}

- (void)tabView:(CPTabView)aTabView didSelectTabViewItem:(CPTabViewItem)anItem
{
    var ident = [anItem identifier];
    if (ident === "regression")
        [self refreshRegressionTab:nil];
}

// ================================================================================
// DATENSÄTZE
// ================================================================================

- (void)loadSets:(id)sender
{
    var keepId = _currentSet ? _currentSet.id : null;
    OTGetJSON("/BBB/validation/sets", 60.0, function(res, error)
    {
        _sets = (res && res.length !== undefined) ? res : [];
        [_setPopUp removeAllItems];
        if (!_sets.length)
        {
            [_setPopUp addItemWithTitle:@"– noch kein Datensatz –"];
            _currentSet = nil;
            [self _updateSetInfo];
            return;
        }
        var sel = 0;
        for (var i = 0; i < _sets.length; i++)
        {
            var s = _sets[i];
            [_setPopUp addItemWithTitle:s.name + (s.purpose === "study" ? "  (Studie)" : "  (Regression)")];
            if (keepId && s.id === keepId)
                sel = i;
        }
        [_setPopUp selectItemAtIndex:sel];
        [self setChanged:nil];
    });
}

- (void)setChanged:(id)sender
{
    var i = [_setPopUp indexOfSelectedItem];
    _currentSet = (_sets && i >= 0 && i < _sets.length) ? _sets[i] : nil;
    [self _updateSetInfo];
    _item = nil;
    [self _showItem];
    [self loadItems:nil];
    [_studyView setString:@""];
    [_runDetailView setString:@""];
    _runs = [];
    [_runsTable reloadData];
}

- (void)_updateSetInfo
{
    if (!_currentSet)
    {
        [_setInfoLabel setStringValue:@"Neuen Datensatz anlegen, um mit der Prüfung zu beginnen."];
        return;
    }
    var s = _currentSet;
    var info = s.n_items + " Briefe · Seed " + (s.params ? s.params.seed : "–") +
               (s.locked ? " · gesperrt" : " · ENTSPERRT") +
               (s.frozen_at ? " · Referenz eingefroren" + (String(s.reference_source || "").indexOf("judge") === 0 ? " (KI)" : " (Ärzte)") : " · Referenz offen");
    [_setInfoLabel setStringValue:info];
}

- (void)exportSet:(id)sender
{
    if (!_currentSet)
        return;
    window.open("/BBB/validation/sets/" + _currentSet.id + "/export", "_blank");
}

- (void)showNewSetPanel:(id)sender
{
    if (!_newPanel)
    {
        _newPanel = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 480, 400)
                                                styleMask:CPTitledWindowMask | CPClosableWindowMask];
        [_newPanel setTitle:@"Neuen Validierungsdatensatz ziehen"];
        var cv = [_newPanel contentView];
        var y = 15;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 150, 18), "Name:", YES)];
        _nsName = OTField(CGRectMake(170, y, 290, 26), "", "z. B. Referenz 2026");
        [cv addSubview:_nsName];
        y += 34;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 150, 18), "Zweck:", YES)];
        _nsPurpose = OVPopUp(CGRectMake(170, y, 290, 26), [["regression", "Regressionstest"], ["study", "Validierungsstudie"]]);
        [_nsPurpose setTarget:self];
        [_nsPurpose setAction:@selector(newSetPurposeChanged:)];
        [cv addSubview:_nsPurpose];
        y += 34;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 150, 18), "Anzahl Briefe:", NO)];
        _nsSize = OTField(CGRectMake(170, y, 80, 26), "50", nil);
        [cv addSubview:_nsSize];
        [cv addSubview:OTLabel(CGRectMake(270, y + 4, 60, 18), "Seed:", NO)];
        _nsSeed = OTField(CGRectMake(320, y, 140, 26), "", "zufällig");
        [cv addSubview:_nsSeed];
        y += 34;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 150, 18), "Nur Tag (optional):", NO)];
        _nsTag = OTField(CGRectMake(170, y, 290, 26), "", "leer = gesamter Bestand");
        [cv addSubview:_nsTag];
        y += 34;
        _nsPerPatient = OTCheckBox(CGRectMake(170, y, 290, 20), "höchstens ein Brief je Patient", YES);
        [cv addSubview:_nsPerPatient];
        y += 30;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 150, 18), "Doppelt prüfen (Anteil):", NO)];
        _nsDouble = OTField(CGRectMake(170, y, 60, 26), "0.3", nil);
        [cv addSubview:_nsDouble];
        [cv addSubview:OTLabel(CGRectMake(245, y + 4, 150, 18), "Eingestreute Fehler:", NO)];
        _nsInject = OTField(CGRectMake(390, y, 70, 26), "0.08", nil);
        [cv addSubview:_nsInject];
        y += 40;
        [cv addSubview:OTLabel(CGRectMake(20, y, 440, 48),
            "Die Stichprobe wird nach Quelle und Jahr geschichtet gezogen. Brieftext und Extraktion werden als Kopie gespeichert. " +
            "Der Datensatz ist danach gesperrt und lässt sich nur nach Entsperren löschen.", NO)];
        y += 56;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 150, 18), "Zum Bestätigen ANLEGEN:", YES)];
        _nsConfirm = OTField(CGRectMake(170, y, 120, 26), "", "ANLEGEN");
        [cv addSubview:_nsConfirm];
        [cv addSubview:OTButton(CGRectMake(310, y, 150, 26), "Stichprobe ziehen", self, @selector(createSet:))];
    }
    [self newSetPurposeChanged:nil];
    [_nsConfirm setStringValue:@""];
    [_newPanel center];
    [_newPanel makeKeyAndOrderFront:self];
}

- (void)newSetPurposeChanged:(id)sender
{
    var study = OVPopUpKey(_nsPurpose, [["regression"], ["study"]]) === "study";
    [_nsDouble setEnabled:study];
    [_nsInject setEnabled:study];
    if (sender)
        [_nsSize setStringValue:(study ? "150" : "50")];
}

- (void)createSet:(id)sender
{
    if (OTTrim([_nsConfirm stringValue]) !== "ANLEGEN")
    {
        alert("Bitte zum Bestätigen ANLEGEN eintragen.");
        return;
    }
    var payload = {
        name: OTTrim([_nsName stringValue]),
        purpose: OVPopUpKey(_nsPurpose, [["regression"], ["study"]]),
        n: parseInt([_nsSize stringValue], 10),
        tag: OTTrim([_nsTag stringValue]),
        one_per_patient: [_nsPerPatient state] === CPOnState ? 1 : 0,
        double_fraction: parseFloat([_nsDouble stringValue]) || 0,
        inject_fraction: parseFloat([_nsInject stringValue]) || 0,
        created_by: [self reviewer],
        confirm: "ANLEGEN"
    };
    var seed = OTTrim([_nsSeed stringValue]);
    if (seed.length)
        payload.seed = parseInt(seed, 10);

    OTPostJSON("/BBB/validation/sets", payload, 600.0, function(res, error)
    {
        if (!res || res.error)
        {
            alert("Datensatz nicht angelegt: " + (res && res.error ? res.error : "keine Antwort vom Server"));
            return;
        }
        [_newPanel orderOut:self];
        alert("Datensatz „" + res.name + "“ angelegt: " + res.n + " Briefe aus " + res.pool + " geeigneten, " +
              res.strata + " Schichten" + (res.double ? ", " + res.double + " doppelt zu prüfen" : "") +
              (res.injected ? ", " + res.injected + " mit eingestreutem Fehler" : "") + ".");
        _currentSet = { id: res.id };
        [self loadSets:nil];
    });
}

// ================================================================================
// PRÜFEN
// ================================================================================

- (CPView)_buildReviewView
{
    var v = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 1270, 710)];

    var it = OVTable(CGRectMake(5, 5, 230, 640), [["position", "#", 45], ["pseudonym", "Pseudonym", 85], ["state", "Stand", 85]], self);
    _itemsTable = it.table;
    [v addSubview:OVM(it.scroll, CPViewHeightSizable)];
    _progressLabel = OVM(OTLabel(CGRectMake(5, 650, 230, 40), "", NO), CPViewMinYMargin);
    [v addSubview:_progressLabel];

    _letterHeader = OVM(OTLabel(CGRectMake(245, 5, 430, 18), "", YES), CPViewWidthSizable);
    [v addSubview:_letterHeader];
    var lt = OVTextArea(CGRectMake(245, 26, 430, 674), NO);
    _letterView = lt.text;
    [v addSubview:OVM(lt.scroll, CPViewWidthSizable | CPViewHeightSizable)];

    // rechte Spalte
    var x = 685, w = 580;

    _checklistBox = OVM([[CPView alloc] initWithFrame:CGRectMake(x, 5, w, 180)], CPViewMinXMargin);
    [_checklistBox addSubview:OTLabel(CGRectMake(0, 0, w, 18), "Teil A – Checkliste (vor der Extraktion ausfüllen)", YES)];
    var ct = OVTable(CGRectMake(0, 20, w, 120), [["cat", "Kategorie", 90], ["text", "Angabe", 200], ["side", "Seite", 50],
                                                 ["date", "Datum", 80], ["value", "Wert", 60], ["match", "Abgleich", 95]], self);
    _checklistTable = ct.table;
    [_checklistBox addSubview:ct.scroll];
    [_checklistBox addSubview:OTButton(CGRectMake(0, 148, 120, 24), "Zeile hinzufügen …", self, @selector(addChecklistLine:))];
    [_checklistBox addSubview:OTButton(CGRectMake(125, 148, 70, 24), "Entfernen", self, @selector(removeChecklistLine:))];
    [_checklistBox addSubview:OTButton(CGRectMake(240, 148, 80, 24), "Gefunden", self, @selector(matchFound:))];
    [_checklistBox addSubview:OTButton(CGRectMake(325, 148, 110, 24), "Attributfehler", self, @selector(matchAttr:))];
    [_checklistBox addSubview:OTButton(CGRectMake(440, 148, 70, 24), "Fehlt", self, @selector(matchMissing:))];
    [v addSubview:_checklistBox];

    _blindLabel = OVM(OTLabel(CGRectMake(x, 200, w, 40),
        "Die Extraktion bleibt verborgen, bis die Checkliste abgeschlossen ist. So wird die Vollständigkeit unverzerrt gemessen.", NO), CPViewMinXMargin);
    [v addSubview:_blindLabel];
    _showExtractionButton = OVM(OTButton(CGRectMake(x, 245, 280, 26), "Checkliste abschließen, Extraktion zeigen", self, @selector(finishChecklist:)), CPViewMinXMargin);
    [v addSubview:_showExtractionButton];

    _entriesBox = OVM([[CPView alloc] initWithFrame:CGRectMake(x, 190, w, 470)], CPViewMinXMargin | CPViewHeightSizable);
    [_entriesBox addSubview:OTLabel(CGRectMake(0, 0, w, 18), "Teil B – Extrahierte Einträge", YES)];
    var et = OVTable(CGRectMake(0, 20, w, 270), [["domain", "Domäne", 75], ["label", "Bezeichnung", 160], ["code", "Code", 85],
                                                 ["side", "Seite", 38], ["date", "Datum", 72], ["value", "Wert", 50],
                                                 ["judgment", "Urteil", 160], ["others", "Andere Prüfer", 200]], self);
    _entriesTable = et.table;
    [_entriesTable setTarget:self];
    [_entriesTable setDoubleAction:@selector(showErrorPanel:)];
    [_entriesBox addSubview:OVM(et.scroll, CPViewHeightSizable)];
    var by = 296, bm = CPViewMinYMargin;
    [_entriesBox addSubview:OVM(OTButton(CGRectMake(0, by, 75, 26), "Korrekt", self, @selector(markCorrect:)), bm)];
    [_entriesBox addSubview:OVM(OTButton(CGRectMake(80, by, 80, 26), "Fehler …", self, @selector(showErrorPanel:)), bm)];
    [_entriesBox addSubview:OVM(OTButton(CGRectMake(165, by, 75, 26), "Dublette", self, @selector(markDuplicate:)), bm)];
    [_entriesBox addSubview:OVM(OTButton(CGRectMake(245, by, 65, 26), "Unklar", self, @selector(markUnclear:)), bm)];
    [_entriesBox addSubview:OVM(OTButton(CGRectMake(315, by, 110, 26), "Zurücksetzen", self, @selector(clearJudgment:)), bm)];
    [_entriesBox addSubview:OVM(OTButton(CGRectMake(450, by, 130, 26), "Übrige korrekt", self, @selector(markRestCorrect:)), bm)];

    [_entriesBox addSubview:OVM(OTLabel(CGRectMake(0, by + 36, w, 18), "Im Brief vorhanden, aber nicht extrahiert", YES), bm)];
    var mt = OVTable(CGRectMake(0, by + 56, w, 80), [["domain", "Domäne", 75], ["label", "Bezeichnung", 200], ["code", "Code", 100],
                                                     ["side", "Seite", 50], ["date", "Datum", 80], ["value", "Wert", 60]], self);
    _missingTable = mt.table;
    [_entriesBox addSubview:OVM(mt.scroll, bm)];
    [_entriesBox addSubview:OVM(OTButton(CGRectMake(0, by + 142, 200, 26), "Fehlenden Eintrag ergänzen …", self, @selector(addMissing:)), bm)];
    [_entriesBox addSubview:OVM(OTButton(CGRectMake(205, by + 142, 80, 26), "Entfernen", self, @selector(removeMissing:)), bm)];
    [v addSubview:_entriesBox];

    _doneButton = OVM(OTButton(CGRectMake(x, 672, 180, 28), "Brief abschließen", self, @selector(toggleDone:)), CPViewMinXMargin | CPViewMinYMargin);
    [v addSubview:_doneButton];
    [v addSubview:OVM(OTButton(CGRectMake(x + 190, 672, 150, 28), "Nächster offener Brief", self, @selector(nextOpenItem:)), CPViewMinXMargin | CPViewMinYMargin)];
    return v;
}

- (void)loadItems:(id)sender
{
    if (!_currentSet)
    {
        _items = [];
        [_itemsTable reloadData];
        [_progressLabel setStringValue:@""];
        return;
    }
    var keepId = _item ? _item.id : null;
    OTGetJSON("/BBB/validation/sets/" + _currentSet.id + "/items?reviewer=" + encodeURIComponent([self reviewer]), 60.0, function(res, error)
    {
        _items = (res && res.items) ? res.items : [];
        if (res && res.set)
        {
            res.set.n_items = _items.length;
            if (_currentSet && _currentSet.n_runs !== undefined)
                res.set.n_runs = _currentSet.n_runs;
            _currentSet = res.set;
            [self _updateSetInfo];
        }
        [_itemsTable reloadData];
        var done = 0;
        for (var i = 0; i < _items.length; i++)
        {
            if (_items[i].my_done)
                done++;
            if (keepId && _items[i].id === keepId)
                [_itemsTable selectRowIndexes:[CPIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
        }
        [_progressLabel setStringValue:([self reviewer].length ?
            "Von " + [self reviewer] + " abgeschlossen: " + done + " von " + _items.length :
            "Bitte oben einen Prüfernamen eintragen.")];
    });
}

- (CPString)_itemState:(id)it
{
    var s;
    if (it.my_done)
        s = "fertig";
    else if (it.my_judged > 0)
        s = it.my_judged + "/" + it.n_entries;
    else if (it.my_checklist)
        s = "Checkliste ✓";
    else
        s = "offen";
    if (it.double_review)
        s += " · 2×";
    return s;
}

- (void)loadItem:(id)anItemId
{
    var me = [self reviewer];
    OTGetJSON("/BBB/validation/items/" + anItemId + "?reviewer=" + encodeURIComponent(me), 60.0, function(res, error)
    {
        if (!res || res.error)
        {
            alert("Brief konnte nicht geladen werden: " + (res && res.error ? res.error : "keine Antwort"));
            return;
        }
        _item = res;
        _judgments = res.judgments || {};
        _missing = [];
        for (var k in _judgments)
            if (k.indexOf("missing:") === 0 && !_judgments[k].deleted)
                _missing.push({ key: k, data: _judgments[k] });
        _checklist = _judgments["_checklist"] || { lines: [], done: 0 };
        if (!_checklist.lines)
            _checklist.lines = [];
        [self _showItem];
    });
}

- (void)_showItem
{
    var it = _item;
    var isStudy = _currentSet && _currentSet.purpose === "study";
    if (!it)
    {
        [_letterHeader setStringValue:@""];
        [_letterView setString:@""];
        [_entriesBox setHidden:YES];
        [_checklistBox setHidden:YES];
        [_blindLabel setHidden:YES];
        [_showExtractionButton setHidden:YES];
        [_doneButton setEnabled:NO];
        return;
    }
    [_letterHeader setStringValue:"Brief " + it.position + " · " + (it.pseudonym || "") + " · " +
                                  (it.reference_date || "") + " · " + (it.doc_source || "") +
                                  (it.double_review ? " · doppelt geprüft" : "")];
    [_letterView setString:it.narrative || ""];
    [_letterView scrollPoint:CGPointMake(0, 0)];

    // ohne Checkliste (Regressions-Datensatz) rücken die Einträge nach oben
    var eb = [_entriesBox frame], top = isStudy ? 190 : 5;
    var bottom = CGRectGetMinY([_doneButton frame]) - 12;
    if (CGRectGetMinY(eb) !== top)
        [_entriesBox setFrame:CGRectMake(CGRectGetMinX(eb), top, CGRectGetWidth(eb), bottom - top)];

    var blind = !!it.blind;
    [_checklistBox setHidden:!isStudy];
    [_blindLabel setHidden:!blind];
    [_showExtractionButton setHidden:!blind];
    [_entriesBox setHidden:blind];

    var done = !!(_judgments["_done"] && _judgments["_done"].done);
    [_doneButton setTitle:(done ? "Wieder öffnen" : "Brief abschließen")];
    [_doneButton setEnabled:!it.frozen && !blind];

    var othersCol = [_entriesTable tableColumnWithIdentifier:"others"];
    if (othersCol)
        [othersCol setHidden:![self isConsensus]];

    [_entriesTable reloadData];
    [_missingTable reloadData];
    [_checklistTable reloadData];
}

- (BOOL)_requireReviewer
{
    if (![self reviewer].length)
    {
        alert("Bitte oben einen Prüfernamen eintragen.");
        return NO;
    }
    if (_item && _item.frozen)
    {
        alert("Die Referenz dieses Datensatzes ist eingefroren; Bewertungen sind nicht mehr änderbar.");
        return NO;
    }
    return !!_item;
}

- (void)_save:(id)reviews then:(Function)aCallback
{
    var itemId = _item.id;
    OTPostJSON("/BBB/validation/items/" + itemId + "/review", { reviewer: [self reviewer], reviews: reviews }, 60.0, function(res, error)
    {
        if (!res || res.error)
        {
            alert("Nicht gespeichert: " + (res && res.error ? res.error : "keine Antwort vom Server"));
            return;
        }
        if (aCallback)
            aCallback();
    });
}

- (id)_selectedEntry
{
    var row = [_entriesTable selectedRow];
    if (!_item || !_item.entries || row < 0 || row >= _item.entries.length)
        return nil;
    return _item.entries[row];
}

- (void)_setJudgment:(id)aJudgment forEntry:(id)anEntry advance:(BOOL)shouldAdvance
{
    if (![self _requireReviewer] || !anEntry)
        return;
    var row = [_entriesTable selectedRow];
    _judgments[anEntry.key] = aJudgment;
    [_entriesTable reloadData];
    [self _save:[{ entry_key: anEntry.key, judgment: aJudgment }] then:function() { [self _refreshItemRow]; }];
    if (shouldAdvance && row + 1 < _item.entries.length)
        [_entriesTable selectRowIndexes:[CPIndexSet indexSetWithIndex:row + 1] byExtendingSelection:NO];
}

- (void)markCorrect:(id)sender
{
    [self _setJudgment:{ verdict: "correct", concept: "ok", status: "ok", side: "ok", date: "ok", value: "ok" }
              forEntry:[self _selectedEntry] advance:YES];
}

- (void)markDuplicate:(id)sender
{
    [self _setJudgment:{ verdict: "duplicate" } forEntry:[self _selectedEntry] advance:YES];
}

- (void)markUnclear:(id)sender
{
    var comment = prompt("Warum ist der Eintrag nicht beurteilbar? (Pflichtkommentar)", "");
    if (comment === null || !OTTrim(comment).length)
        return;
    [self _setJudgment:{ verdict: "unclear", comment: OTTrim(comment) } forEntry:[self _selectedEntry] advance:YES];
}

- (void)clearJudgment:(id)sender
{
    [self _setJudgment:{ verdict: "", cleared: 1 } forEntry:[self _selectedEntry] advance:NO];
}

- (void)markRestCorrect:(id)sender
{
    if (![self _requireReviewer])
        return;
    var reviews = [];
    for (var i = 0; i < _item.entries.length; i++)
    {
        var e = _item.entries[i];
        var j = _judgments[e.key];
        if (j && j.verdict)
            continue;
        j = { verdict: "correct", concept: "ok", status: "ok", side: "ok", date: "ok", value: "ok" };
        _judgments[e.key] = j;
        reviews.push({ entry_key: e.key, judgment: j });
    }
    if (!reviews.length)
        return;
    if (!confirm(reviews.length + " noch nicht bewertete Einträge als korrekt markieren?"))
    {
        for (var r = 0; r < reviews.length; r++)
            delete _judgments[reviews[r].entry_key];
        return;
    }
    [_entriesTable reloadData];
    [self _save:reviews then:function() { [self _refreshItemRow]; }];
}

- (void)_refreshItemRow
{
    if (!_item)
        return;
    var judged = 0;
    for (var i = 0; i < _item.entries.length; i++)
    {
        var j = _judgments[_item.entries[i].key];
        if (j && j.verdict)
            judged++;
    }
    for (var r = 0; r < _items.length; r++)
        if (_items[r].id === _item.id)
        {
            _items[r].my_judged = judged;
            _items[r].my_done = !!(_judgments["_done"] && _judgments["_done"].done);
            _items[r].my_checklist = !!_checklist.done;
        }
    [_itemsTable reloadData];
}

- (void)toggleDone:(id)sender
{
    if (![self _requireReviewer])
        return;
    var isDone = !!(_judgments["_done"] && _judgments["_done"].done);
    if (!isDone)
    {
        var open = 0;
        for (var i = 0; i < _item.entries.length; i++)
        {
            var j = _judgments[_item.entries[i].key];
            if (!j || !j.verdict)
                open++;
        }
        if (open)
        {
            alert(open + " Einträge sind noch nicht bewertet.");
            return;
        }
        if (_currentSet.purpose === "study")
        {
            for (var l = 0; l < _checklist.lines.length; l++)
                if (!_checklist.lines[l].match)
                {
                    alert("Bitte für jede Checklistenzeile den Abgleich setzen (gefunden, Attributfehler oder fehlt).");
                    return;
                }
        }
    }
    var j = { done: isDone ? 0 : 1, at: new Date().toISOString() };
    _judgments["_done"] = j;
    [self _save:[{ entry_key: "_done", judgment: j }] then:function()
    {
        [self _refreshItemRow];
        [self _showItem];
        if (!isDone)
            [self nextOpenItem:nil];
    }];
}

- (void)nextOpenItem:(id)sender
{
    var start = [_itemsTable selectedRow];
    for (var k = 1; k <= _items.length; k++)
    {
        var i = (start + k) % _items.length;
        if (!_items[i].my_done)
        {
            [_itemsTable selectRowIndexes:[CPIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
            [_itemsTable scrollRowToVisible:i];
            return;
        }
    }
    alert("Alle Briefe dieses Datensatzes sind von " + [self reviewer] + " abgeschlossen.");
}

// --- Fehler-Panel -----------------------------------------------------------------

- (void)showErrorPanel:(id)sender
{
    var e = [self _selectedEntry];
    if (!e || ![self _requireReviewer])
        return;

    if (!_errorPanel)
    {
        _errorPanel = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 470, 330)
                                                  styleMask:CPTitledWindowMask | CPClosableWindowMask];
        [_errorPanel setTitle:@"Eintrag bewerten"];
        var cv = [_errorPanel contentView];
        _ePTitle = OTLabel(CGRectMake(20, 12, 430, 36), "", YES);
        [cv addSubview:_ePTitle];
        var y = 55;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 110, 18), "Konzept:", NO)];
        _ePConcept = OVPopUp(CGRectMake(130, y, 200, 26), OVConceptOpts);
        [cv addSubview:_ePConcept];
        y += 34;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 110, 18), "Status:", NO)];
        _ePStatus = OVPopUp(CGRectMake(130, y, 200, 26), OVStatusOpts);
        [cv addSubview:_ePStatus];
        y += 34;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 110, 18), "Augenseite:", NO)];
        _ePSide = OVPopUp(CGRectMake(130, y, 160, 26), OVAttrOpts);
        [cv addSubview:_ePSide];
        [cv addSubview:OTLabel(CGRectMake(300, y + 4, 50, 18), "richtig:", NO)];
        _ePSideCorrect = OVPopUp(CGRectMake(350, y, 100, 26), OVSideOpts);
        [cv addSubview:_ePSideCorrect];
        y += 34;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 110, 18), "Datum:", NO)];
        _ePDate = OVPopUp(CGRectMake(130, y, 160, 26), OVAttrOpts);
        [cv addSubview:_ePDate];
        [cv addSubview:OTLabel(CGRectMake(300, y + 4, 50, 18), "richtig:", NO)];
        _ePDateCorrect = OTField(CGRectMake(350, y, 100, 26), "", "JJJJ-MM-TT");
        [cv addSubview:_ePDateCorrect];
        y += 34;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 110, 18), "Messwert:", NO)];
        _ePValue = OVPopUp(CGRectMake(130, y, 160, 26), OVValueOpts);
        [cv addSubview:_ePValue];
        [cv addSubview:OTLabel(CGRectMake(300, y + 4, 50, 18), "richtig:", NO)];
        _ePValueCorrect = OTField(CGRectMake(350, y, 100, 26), "", "");
        [cv addSubview:_ePValueCorrect];
        y += 34;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 110, 18), "Kommentar:", NO)];
        _ePComment = OTField(CGRectMake(130, y, 320, 26), "", "optional");
        [cv addSubview:_ePComment];
        y += 40;
        [cv addSubview:OTButton(CGRectMake(240, y, 100, 26), "Abbrechen", self, @selector(cancelErrorPanel:))];
        [cv addSubview:OTButton(CGRectMake(350, y, 100, 26), "Speichern", self, @selector(saveErrorPanel:))];
    }

    var j = _judgments[e.key] || {};
    [_ePTitle setStringValue:(OVDomainTitles[e.domain] || e.domain) + ": " + (e.label || "") + " (" + e.code + ")" +
                            (e.side ? " · " + OVSideTitles[e.side] : "") + (e.date ? " · " + e.date : "")];
    OVPopUpSelect(_ePConcept, OVConceptOpts, j.concept || "ok");
    OVPopUpSelect(_ePStatus, OVStatusOpts, j.status || "ok");
    OVPopUpSelect(_ePSide, OVAttrOpts, j.side || (e.side ? "ok" : "na"));
    OVPopUpSelect(_ePSideCorrect, OVSideOpts, j.side_correct === "" && j.side === "superfluous" ? "none" : (j.side_correct || ""));
    OVPopUpSelect(_ePDate, OVAttrOpts, j.date || (e.date ? "ok" : "na"));
    [_ePDateCorrect setStringValue:j.date_correct || ""];
    OVPopUpSelect(_ePValue, OVValueOpts, j.value || (e.domain === "measurement" ? "ok" : "na"));
    [_ePValueCorrect setStringValue:j.value_correct || ""];
    [_ePComment setStringValue:j.comment || ""];
    [_errorPanel center];
    [_errorPanel makeKeyAndOrderFront:self];
}

- (void)cancelErrorPanel:(id)sender
{
    [_errorPanel orderOut:self];
}

- (void)saveErrorPanel:(id)sender
{
    var e = [self _selectedEntry];
    if (!e)
        return;
    var sideCorrect = OVPopUpKey(_ePSideCorrect, OVSideOpts);
    var j = {
        concept: OVPopUpKey(_ePConcept, OVConceptOpts),
        status: OVPopUpKey(_ePStatus, OVStatusOpts),
        side: OVPopUpKey(_ePSide, OVAttrOpts),
        side_correct: sideCorrect === "none" ? "" : sideCorrect,
        date: OVPopUpKey(_ePDate, OVAttrOpts),
        date_correct: OTTrim([_ePDateCorrect stringValue]),
        value: OVPopUpKey(_ePValue, OVValueOpts),
        value_correct: OTTrim([_ePValueCorrect stringValue]),
        comment: OTTrim([_ePComment stringValue])
    };
    if (sideCorrect === "none" && (j.side === "wrong" || j.side === "missing"))
        j.side = "superfluous";
    var allOk = j.concept === "ok" && j.status === "ok" && (j.side === "ok" || j.side === "na") &&
                (j.date === "ok" || j.date === "na") && (j.value === "ok" || j.value === "na");
    j.verdict = allOk ? "correct" : "error";
    [_errorPanel orderOut:self];
    [self _setJudgment:j forEntry:e advance:YES];
}

// --- fehlende Einträge und Checkliste ------------------------------------------------

- (void)_showEntryPanel:(CPString)aMode
{
    if (![self _requireReviewer])
        return;
    _entryMode = aMode;
    if (!_entryPanel)
    {
        _entryPanel = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 470, 320)
                                                  styleMask:CPTitledWindowMask | CPClosableWindowMask];
        var cv = [_entryPanel contentView];
        _enTitle = OTLabel(CGRectMake(20, 12, 430, 36), "", NO);
        [cv addSubview:_enTitle];
        var y = 55;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 100, 18), "Art:", NO)];
        _enDomain = [[CPPopUpButton alloc] initWithFrame:CGRectMake(120, y, 200, 26) pullsDown:NO];
        [cv addSubview:_enDomain];
        y += 34;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 100, 18), "Bezeichnung:", NO)];
        _enLabel = OTField(CGRectMake(120, y, 330, 26), "", "wie im Brief");
        [cv addSubview:_enLabel];
        y += 34;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 100, 18), "Code:", NO)];
        _enCode = OTField(CGRectMake(120, y, 200, 26), "", "z. B. ICD10:H18.5");
        [cv addSubview:_enCode];
        _enLookup = OTButton(CGRectMake(330, y, 120, 26), "Code suchen", self, @selector(lookupCode:));
        [cv addSubview:_enLookup];
        y += 34;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 100, 18), "Augenseite:", NO)];
        _enSide = OVPopUp(CGRectMake(120, y, 130, 26), OVSideOpts);
        [cv addSubview:_enSide];
        [cv addSubview:OTLabel(CGRectMake(265, y + 4, 50, 18), "Datum:", NO)];
        _enDate = OTField(CGRectMake(320, y, 130, 26), "", "JJJJ-MM-TT");
        [cv addSubview:_enDate];
        y += 34;
        [cv addSubview:OTLabel(CGRectMake(20, y + 4, 100, 18), "Wert:", NO)];
        _enValue = OTField(CGRectMake(120, y, 130, 26), "", "");
        [cv addSubview:_enValue];
        [cv addSubview:OTLabel(CGRectMake(265, y + 4, 50, 18), "Einheit:", NO)];
        _enUnit = OTField(CGRectMake(320, y, 130, 26), "", "");
        [cv addSubview:_enUnit];
        y += 34;
        _enExcluded = OTCheckBox(CGRectMake(120, y, 250, 20), "im Brief verneint", NO);
        [cv addSubview:_enExcluded];
        y += 34;
        [cv addSubview:OTButton(CGRectMake(240, y, 100, 26), "Abbrechen", self, @selector(cancelEntryPanel:))];
        [cv addSubview:OTButton(CGRectMake(350, y, 100, 26), "Übernehmen", self, @selector(saveEntryPanel:))];
    }
    var isMissing = aMode === "missing";
    [_entryPanel setTitle:(isMissing ? "Fehlenden Eintrag ergänzen" : "Checklistenzeile hinzufügen")];
    [_enTitle setStringValue:(isMissing ?
        "Eintrag, der im Brief steht, aber nicht extrahiert wurde. Für den Regressionstest wird ein Code benötigt." :
        "Angabe aus dem Brief, ohne die Extraktion anzusehen. Stichworte genügen, Codes sind nicht nötig.")];
    [_enDomain removeAllItems];
    if (isMissing)
        for (var i = 0; i < OVDomains.length; i++)
            [_enDomain addItemWithTitle:OVDomainTitles[OVDomains[i]]];
    else
        [_enDomain addItemsWithTitles:OVChecklistCats];
    [_enCode setHidden:!isMissing];
    [_enLookup setHidden:!isMissing];
    [_enExcluded setHidden:!isMissing];
    [_enUnit setHidden:!isMissing];
    [_enLabel setStringValue:@""];
    [_enCode setStringValue:@""];
    [_enDate setStringValue:@""];
    [_enValue setStringValue:@""];
    [_enUnit setStringValue:@""];
    [_enSide selectItemAtIndex:0];
    [_enExcluded setState:CPOffState];
    [_entryPanel center];
    [_entryPanel makeKeyAndOrderFront:self];
}

- (void)lookupCode:(id)sender
{
    var domain = OVDomains[[_enDomain indexOfSelectedItem]];
    var text = OTTrim([_enLabel stringValue]);
    if (!text.length)
    {
        alert("Bitte zuerst die Bezeichnung eintragen.");
        return;
    }
    [_enLookup setEnabled:NO];
    OTPostJSON("/BBB/resolve_term", { domain: OVResolveDomain[domain], text: text, language: "de" }, 120.0, function(res, error)
    {
        [_enLookup setEnabled:YES];
        if (res && res.hit && res.id)
        {
            [_enCode setStringValue:res.id];
            if (res.label && confirm("Gefunden: " + res.id + " – " + res.label + "\nBezeichnung übernehmen?"))
                [_enLabel setStringValue:res.label];
        }
        else
            alert("Kein passender Code gefunden. Bitte den Code von Hand eintragen.");
    });
}

- (void)cancelEntryPanel:(id)sender
{
    [_entryPanel orderOut:self];
}

- (void)saveEntryPanel:(id)sender
{
    var label = OTTrim([_enLabel stringValue]);
    if (!label.length)
    {
        alert("Bitte eine Bezeichnung eintragen.");
        return;
    }
    var side = OVPopUpKey(_enSide, OVSideOpts);
    if (side === "none")
        side = "";

    if (_entryMode === "missing")
    {
        var code = OTTrim([_enCode stringValue]);
        if (!code.length && !confirm("Ohne Code zählt der Eintrag in der Studie, aber nicht im Regressionstest. Trotzdem übernehmen?"))
            return;
        var m = {
            missing: 1, domain: OVDomains[[_enDomain indexOfSelectedItem]], label: label, code: code, side: side,
            date: OTTrim([_enDate stringValue]), value: OTTrim([_enValue stringValue]), unit: OTTrim([_enUnit stringValue]),
            excluded: [_enExcluded state] === CPOnState ? 1 : 0
        };
        var key = "missing:" + (new Date().getTime().toString(36)) + Math.floor(Math.random() * 1e6).toString(36);
        _judgments[key] = m;
        _missing.push({ key: key, data: m });
        [_missingTable reloadData];
        [self _save:[{ entry_key: key, judgment: m }] then:nil];
    }
    else
    {
        _checklist.lines.push({ cat: [_enDomain titleOfSelectedItem], text: label, side: side,
                                date: OTTrim([_enDate stringValue]), value: OTTrim([_enValue stringValue]), match: "" });
        [self _saveChecklist];
    }
    [_entryPanel orderOut:self];
}

- (void)addMissing:(id)sender
{
    [self _showEntryPanel:"missing"];
}

- (void)removeMissing:(id)sender
{
    var row = [_missingTable selectedRow];
    if (row < 0 || row >= _missing.length || ![self _requireReviewer])
        return;
    var m = _missing[row];
    m.data.deleted = 1;
    _missing.splice(row, 1);
    [_missingTable reloadData];
    [self _save:[{ entry_key: m.key, judgment: m.data }] then:nil];
}

- (void)addChecklistLine:(id)sender
{
    if (_checklist.done && _item && !_item.blind && !confirm("Die Checkliste ist bereits abgeschlossen. Trotzdem eine Zeile ergänzen?"))
        return;
    [self _showEntryPanel:"checklist"];
}

- (void)removeChecklistLine:(id)sender
{
    var row = [_checklistTable selectedRow];
    if (row < 0 || row >= _checklist.lines.length || ![self _requireReviewer])
        return;
    if (_checklist.done && !confirm("Die Checkliste ist bereits abgeschlossen. Zeile trotzdem entfernen?"))
        return;
    _checklist.lines.splice(row, 1);
    [self _saveChecklist];
}

- (void)_saveChecklist
{
    _judgments["_checklist"] = _checklist;
    [_checklistTable reloadData];
    [self _save:[{ entry_key: "_checklist", judgment: _checklist }] then:nil];
}

- (void)finishChecklist:(id)sender
{
    if (![self _requireReviewer])
        return;
    if (!_checklist.lines.length && !confirm("Die Checkliste ist leer. Trotzdem abschließen?"))
        return;
    _checklist.done = 1;
    _judgments["_checklist"] = _checklist;
    var itemId = _item.id;
    [self _save:[{ entry_key: "_checklist", judgment: _checklist }] then:function()
    {
        [self loadItem:itemId];
        [self _refreshItemRow];
    }];
}

- (void)_setMatch:(CPString)aMatch
{
    var row = [_checklistTable selectedRow];
    if (row < 0 || row >= _checklist.lines.length || ![self _requireReviewer])
        return;
    if (_item.blind)
    {
        alert("Der Abgleich ist erst nach Abschluss der Checkliste möglich.");
        return;
    }
    _checklist.lines[row].match = aMatch;
    [self _saveChecklist];
    if (row + 1 < _checklist.lines.length)
        [_checklistTable selectRowIndexes:[CPIndexSet indexSetWithIndex:row + 1] byExtendingSelection:NO];
}

- (void)matchFound:(id)sender   { [self _setMatch:"found"]; }
- (void)matchAttr:(id)sender    { [self _setMatch:"attr"]; }
- (void)matchMissing:(id)sender { [self _setMatch:"missing"]; }

// ================================================================================
// REFERENZ & REGRESSION
// ================================================================================

- (CPView)_buildRegressionView
{
    var v = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 1270, 710)];

    [v addSubview:OTLabel(CGRectMake(5, 5, 600, 18), "Stand der Prüfung und Referenz", YES)];
    var st = OVTextArea(CGRectMake(5, 26, 620, 150), YES);
    _statusView = st.text;
    [v addSubview:st.scroll];
    var bx = 640;
    [v addSubview:OTButton(CGRectMake(bx, 26, 200, 26), "Stand aktualisieren", self, @selector(refreshRegressionTab:))];
    [v addSubview:OTButton(CGRectMake(bx, 58, 200, 26), "Referenz einfrieren …", self, @selector(freezeSet:))];
    [v addSubview:OTButton(CGRectMake(bx, 90, 200, 26), "Referenz auftauen …", self, @selector(unfreezeSet:))];
    [v addSubview:OTButton(CGRectMake(bx + 210, 26, 200, 26), "Sperren / Entsperren …", self, @selector(toggleLock:))];
    [v addSubview:OTButton(CGRectMake(bx + 210, 58, 200, 26), "Datensatz löschen …", self, @selector(deleteSet:))];
    [v addSubview:OTLabel(CGRectMake(bx + 420, 5, 200, 18), "KI-Judge", YES)];
    [v addSubview:OTButton(CGRectMake(bx + 420, 26, 200, 26), "KI-Judge bewerten lassen …", self, @selector(startJudge:))];
    [v addSubview:OTButton(CGRectMake(bx + 420, 58, 200, 26), "KI-Referenz einfrieren …", self, @selector(freezeJudgeSet:))];
    [v addSubview:OTLabel(CGRectMake(bx, 124, 620, 52),
        "Einfrieren übernimmt die Bewertungen als Referenz und schützt sie vor Änderungen. Abweichungen zwischen zwei Prüfern " +
        "klärt ein Prüfer mit dem Namen „Konsens“; er sieht die Urteile beider. Eine KI-Referenz entsteht aus den Urteilen des KI-Judge.", NO)];

    [v addSubview:OTLabel(CGRectMake(5, 190, 600, 18), "Regressionsläufe gegen die Referenz", YES)];
    var rt = OVTable(CGRectMake(5, 212, 1260, 190), [["id", "Lauf", 45], ["started", "Gestartet", 135], ["mode", "Quelle", 120],
                                                    ["status", "Status", 95], ["f1", "F1", 65], ["precision", "Precision", 75],
                                                    ["recall", "Recall", 65], ["delta", "ΔF1 zur Basis", 95], ["verdict", "Ergebnis", 105],
                                                    ["fingerprint", "Pipeline-Stand", 120], ["label", "Bezeichnung", 300]], self);
    _runsTable = rt.table;
    [v addSubview:OVM(rt.scroll, CPViewWidthSizable)];

    var by = 408;
    [v addSubview:OTButton(CGRectMake(5, by, 230, 26), "Lauf starten (neu extrahieren) …", self, @selector(startReextractRun:))];
    [v addSubview:OTButton(CGRectMake(240, by, 250, 26), "Gespeicherte Phenopackets prüfen", self, @selector(startStoredRun:))];
    [v addSubview:OTButton(CGRectMake(495, by, 160, 26), "Als Basis festlegen", self, @selector(setBaseline:))];
    [v addSubview:OTButton(CGRectMake(660, by, 140, 26), "Bericht als CSV", self, @selector(downloadRunReport:))];

    var dt = OVTextArea(CGRectMake(5, 442, 1260, 262), YES);
    _runDetailView = dt.text;
    [v addSubview:OVM(dt.scroll, CPViewWidthSizable | CPViewHeightSizable)];
    return v;
}

- (void)refreshRegressionTab:(id)sender
{
    if (!_currentSet)
        return;
    var setId = _currentSet.id;
    OTGetJSON("/BBB/validation/sets/" + setId + "/status", 120.0, function(res, error)
    {
        if (!res || res.error)
        {
            _statusText = "Stand nicht abrufbar: " + (res && res.error ? res.error : "keine Antwort");
            [self _renderStatus];
            return;
        }
        var s = res.set, lines = [];
        lines.push("Datensatz:   " + s.name + " (" + (s.purpose === "study" ? "Validierungsstudie" : "Regressionstest") + ")");
        lines.push("Briefe:      " + res.n_items + "   Seed " + (s.params ? s.params.seed : "–") +
                   "   Grundgesamtheit " + (s.params ? s.params.pool_size : "–"));
        lines.push("Schutz:      " + (s.locked ? "gesperrt" : "ENTSPERRT – kann gelöscht werden"));
        lines.push("Referenz:    " + (s.frozen_at ? "eingefroren am " + String(s.frozen_at).substring(0, 16) + (s.frozen_by ? " von " + s.frozen_by : "") +
                   (String(s.reference_source || "").indexOf("judge:") === 0 ? " – Quelle KI-Judge " + s.reference_source.substring(6) : " – Quelle Ärzte") : "noch offen"));
        var rv = [];
        for (var name in res.reviewers)
            rv.push(name + ": " + res.reviewers[name]);
        lines.push("Abgeschlossen je Prüfer: " + (rv.length ? rv.join(", ") : "–"));
        lines.push("Unvollständig: " + res.incomplete.length + "   Abweichungen zwischen Prüfern: " + res.conflicts.length);
        if (res.conflicts.length)
        {
            var cl = [];
            for (var i = 0; i < res.conflicts.length && i < 30; i++)
                cl.push("#" + res.conflicts[i].position + " (" + res.conflicts[i].keys.length + ")");
            lines.push("  Abweichungen in Brief " + cl.join(", "));
        }
        if (res.incomplete.length && res.incomplete.length <= 40)
        {
            var il = [];
            for (var k = 0; k < res.incomplete.length; k++)
                il.push("#" + res.incomplete[k].position);
            lines.push("  Offen: " + il.join(", "));
        }
        _statusText = lines.join("\n");
        [self _renderStatus];
    });
    [self loadRuns:nil];
    [self loadJudgeStatus:nil];
}

- (void)_renderStatus
{
    [_statusView setString:(_statusText || "") + (_judgeText ? "\n\n" + _judgeText : "")];
}

// --- KI-Judge -----------------------------------------------------------------------

- (void)loadJudgeStatus:(id)sender
{
    if (!_currentSet)
        return;
    OTGetJSON("/BBB/validation/sets/" + _currentSet.id + "/judge", 60.0, function(res, error)
    {
        _judgeStatus = res;
        if (!res || res.error)
        {
            _judgeText = nil;
            _judgeActive = NO;
        }
        else
        {
            var L = [], provs = res.providers || [], running = res.running || [];
            var conf = [];
            for (var p = 0; p < provs.length; p++)
                if (provs[p].configured)
                    conf.push(provs[p].label + " " + provs[p].model + (running.indexOf(provs[p].id) >= 0 ? " – läuft" : ""));
            L.push("KI-Judge:    " + (conf.length ? conf.join(", ") : "nicht konfiguriert") + "   Prompt " + res.prompt_version);
            var models = res.models || [];
            for (var m = 0; m < models.length; m++)
            {
                var md = models[m];
                L.push("  " + OVPad(md.model, 18) + "bewertet " + md.n_ok + " von " + res.n_items + " Briefen" +
                       (md.n_errors > 0 ? ", " + md.n_errors + " mit Fehler" : "") + "   Tokens " + md.tokens_in + " ein / " + md.tokens_out + " aus");
                var errs = md.errors || [];
                for (var i = 0; i < errs.length && i < 5; i++)
                    L.push("    Brief " + errs[i].position + ": " + errs[i].error);
            }
            _judgeText = L.join("\n");
            _judgeActive = running.length > 0;
        }
        [self _renderStatus];
        [self _updatePolling];
    });
}

- (void)startJudge:(id)sender
{
    if (!_currentSet)
        return;
    var st = _judgeStatus || {}, provs = [];
    for (var i = 0; i < (st.providers || []).length; i++)
        if (st.providers[i].configured)
            provs.push(st.providers[i]);
    if (!provs.length)
    {
        alert("Kein KI-Judge konfiguriert. Im Backend ANTHROPIC_API_KEY (Claude) und/oder ONTOTRIAL_JUDGE_LOCAL_MODEL (lokales Modell) setzen " +
              "und Backend sowie Minion-Worker neu starten.");
        return;
    }
    var prov = provs[0];
    if (provs.length > 1)
    {
        var q = "Welcher KI-Judge soll bewerten?\n";
        for (var k = 0; k < provs.length; k++)
            q += "\n" + (k + 1) + " = " + provs[k].label + " (" + provs[k].model + ")";
        var pick = prompt(q + "\n\nNummer eingeben:", "1");
        if (pick === null)
            return;
        prov = provs[parseInt(pick, 10) - 1];
        if (!prov)
        {
            alert("Ungültige Auswahl. Abgebrochen.");
            return;
        }
    }

    var payload = { provider: prov.id };
    if (prov.external)
    {
        var answer = prompt("Die Brieftexte dieses Datensatzes werden an die externe API gesendet (" + prov.label + ", " + prov.model + ").\n" +
                            "Briefe mit Geburtsdatum oder Namen mit Anrede werden automatisch zurückgehalten.\n\n" +
                            "Nur fortfahren, wenn der Datenschutz dem zugestimmt hat. Zum Bestätigen EXTERN eingeben:", "");
        if (answer === null)
            return;
        if (answer !== "EXTERN")
        {
            alert("Nicht bestätigt. Abgebrochen.");
            return;
        }
        payload.confirm = "EXTERN";
    }
    else if (!confirm("Alle Briefe dieses Datensatzes vom lokalen Modell " + prov.model + " bewerten lassen?"))
        return;

    var done = 0;
    for (var m = 0; m < (st.models || []).length; m++)
        if (st.models[m].model === prov.model)
            done = st.models[m].n_ok;
    payload.overwrite = (done > 0 && confirm(done + " Briefe hat " + prov.model + " bereits bewertet. Auch diese neu bewerten lassen?\n" +
                                            "(Abbrechen = nur fehlende und fehlerhafte Briefe)")) ? 1 : 0;

    OTPostJSON("/BBB/validation/sets/" + _currentSet.id + "/judge", payload, 60.0, function(res, error)
    {
        if (!res || res.error)
        {
            alert("KI-Judge nicht gestartet: " + (res && res.error ? res.error : "keine Antwort vom Server"));
            return;
        }
        _judgeActive = YES;
        [self loadJudgeStatus:nil];
    });
}

- (void)freezeJudgeSet:(id)sender
{
    if (!_currentSet)
        return;
    var models = (_judgeStatus && _judgeStatus.models) ? _judgeStatus.models : [];
    if (!models.length)
    {
        alert("Es gibt noch keine KI-Bewertungen für diesen Datensatz.");
        return;
    }
    var model = models[0].model;
    if (models.length > 1)
    {
        var q = "Aus welchem KI-Judge soll die Referenz entstehen?\n";
        for (var k = 0; k < models.length; k++)
            q += "\n" + (k + 1) + " = " + models[k].model + " (" + models[k].n_ok + " von " + _judgeStatus.n_items + " Briefen bewertet)";
        var pick = prompt(q + "\n\nNummer eingeben:", "1");
        if (pick === null)
            return;
        var chosen = models[parseInt(pick, 10) - 1];
        if (!chosen)
        {
            alert("Ungültige Auswahl. Abgebrochen.");
            return;
        }
        model = chosen.model;
    }
    if (![self _confirmSetName:"Referenz aus den Urteilen von " + model + " einfrieren? Sie dient dann als Basis für Regressionstests, bis eine ärztliche Referenz vorliegt."])
        return;
    [self _postSetAction:"freeze" payload:{ confirm: _currentSet.name, by: [self reviewer], source: "judge", model: model }
                 message:"KI-Referenz aus " + model + " eingefroren."];
}

- (void)loadRuns:(id)sender
{
    if (!_currentSet)
        return;
    OTGetJSON("/BBB/validation/sets/" + _currentSet.id + "/runs", 60.0, function(res, error)
    {
        _runs = (res && res.length !== undefined) ? res : [];
        [_runsTable reloadData];
        _runsActive = NO;
        for (var i = 0; i < _runs.length; i++)
            if (_runs[i].status === "queued" || _runs[i].status === "running")
                _runsActive = YES;
        [self _updatePolling];
        [self _showRunDetail];
    });
}

- (void)_updatePolling
{
    if (_runsActive || _judgeActive)
        [self _startPolling];
    else
        [self _stopPolling];
}

- (void)_startPolling
{
    if (_pollTimer)
        return;
    _pollTimer = window.setInterval(function()
    {
        [self loadRuns:nil];
        [self loadJudgeStatus:nil];
    }, 5000);
}

- (void)_stopPolling
{
    if (_pollTimer)
        window.clearInterval(_pollTimer);
    _pollTimer = nil;
}

- (BOOL)_confirmSetName:(CPString)aQuestion
{
    if (!_currentSet)
        return NO;
    var answer = prompt(aQuestion + "\n\nZum Bestätigen den Namen des Datensatzes eingeben:\n" + _currentSet.name, "");
    if (answer === null)
        return NO;
    if (answer !== _currentSet.name)
    {
        alert("Der Name stimmt nicht überein. Abgebrochen.");
        return NO;
    }
    return YES;
}

- (void)_postSetAction:(CPString)aPath payload:(id)aPayload message:(CPString)aMessage
{
    OTPostJSON("/BBB/validation/sets/" + _currentSet.id + "/" + aPath, aPayload, 300.0, function(res, error)
    {
        if (!res || res.error)
        {
            var msg = res && res.error ? res.error : "keine Antwort vom Server";
            if (res && res.open)
            {
                var o = [];
                for (var i = 0; i < res.open.length && i < 30; i++)
                    o.push("#" + res.open[i].position + " " + (res.open[i].status === "conflict" ? "Abweichung" : "unvollständig"));
                msg += "\n" + o.join(", ");
            }
            alert(msg);
            return;
        }
        if (aMessage)
            alert(aMessage);
        [self loadSets:nil];
        [self refreshRegressionTab:nil];
    });
}

- (void)freezeSet:(id)sender
{
    if (![self _confirmSetName:"Referenz einfrieren? Danach sind die Bewertungen nicht mehr änderbar."])
        return;
    [self _postSetAction:"freeze" payload:{ confirm: _currentSet.name, by: [self reviewer] } message:"Referenz eingefroren."];
}

- (void)unfreezeSet:(id)sender
{
    if (_currentSet && _currentSet.locked)
    {
        alert("Der Datensatz ist gesperrt. Zum Auftauen zuerst entsperren.");
        return;
    }
    if (![self _confirmSetName:"Referenz auftauen? Bewertungen werden wieder änderbar; bestehende Regressionsläufe beziehen sich auf die alte Referenz."])
        return;
    [self _postSetAction:"unfreeze" payload:{ confirm: _currentSet.name } message:"Referenz aufgetaut."];
}

- (void)toggleLock:(id)sender
{
    if (!_currentSet)
        return;
    if (_currentSet.locked)
    {
        if (![self _confirmSetName:"Datensatz entsperren? Danach kann er gelöscht werden."])
            return;
        [self _postSetAction:"lock" payload:{ locked: 0, confirm: _currentSet.name } message:"Datensatz entsperrt."];
    }
    else
        [self _postSetAction:"lock" payload:{ locked: 1 } message:"Datensatz gesperrt."];
}

- (void)deleteSet:(id)sender
{
    if (!_currentSet)
        return;
    if (_currentSet.locked)
    {
        alert("Der Datensatz ist gesperrt und kann nicht gelöscht werden. Zuerst entsperren.");
        return;
    }
    if (![self _confirmSetName:"Datensatz mit allen Bewertungen und Läufen endgültig löschen? Vorher am besten eine Sicherung laden."])
        return;
    OVSend("DELETE", "/BBB/validation/sets/" + _currentSet.id, { confirm: _currentSet.name }, 120.0, function(res, error)
    {
        if (!res || res.error)
        {
            alert("Nicht gelöscht: " + (res && res.error ? res.error : "keine Antwort vom Server"));
            return;
        }
        _currentSet = nil;
        [self loadSets:nil];
    });
}

- (void)_startRun:(CPString)aMode
{
    if (!_currentSet)
        return;
    if (!_currentSet.frozen_at)
    {
        alert("Erst die Referenz einfrieren.");
        return;
    }
    var label = prompt(aMode === "stored" ?
        "Bezeichnung des Laufs (z. B. „Bestand vor Neu-Extraktion“):" :
        "Bezeichnung des Laufs (z. B. „nach Update Reranker“). Alle " + _currentSet.n_items + " Briefe werden neu extrahiert; das dauert.", "");
    if (label === null)
        return;
    OTPostJSON("/BBB/validation/sets/" + _currentSet.id + "/runs", { mode: aMode, label: label }, 60.0, function(res, error)
    {
        if (!res || res.error)
        {
            alert("Lauf nicht gestartet: " + (res && res.error ? res.error : "keine Antwort vom Server"));
            return;
        }
        [self loadRuns:nil];
    });
}

- (void)startReextractRun:(id)sender { [self _startRun:"reextract"]; }
- (void)startStoredRun:(id)sender    { [self _startRun:"stored"]; }

- (id)_selectedRun
{
    var row = [_runsTable selectedRow];
    return (row >= 0 && row < _runs.length) ? _runs[row] : nil;
}

- (void)setBaseline:(id)sender
{
    var r = [self _selectedRun];
    if (!r || r.status !== "finished")
    {
        alert("Bitte einen abgeschlossenen Lauf auswählen.");
        return;
    }
    [self _postSetAction:"baseline" payload:{ run_id: r.id } message:"Lauf " + r.id + " ist jetzt die Basis für weitere Vergleiche."];
}

- (void)downloadRunReport:(id)sender
{
    var r = [self _selectedRun];
    if (!r)
        return;
    window.open("/BBB/validation/runs/" + r.id + "/report.csv", "_blank");
}

- (void)_showRunDetail
{
    var r = [self _selectedRun] || (_runs.length ? _runs[0] : nil);
    if (!r)
    {
        [_runDetailView setString:@"Noch kein Lauf. Nach dem Einfrieren der Referenz einen Lauf starten."];
        return;
    }
    var L = [];
    L.push("Lauf " + r.id + (r.label ? " – " + r.label : "") + "   (" + (r.mode === "stored" ? "gespeicherte Phenopackets" : "neu extrahiert") +
           ", Status " + r.status + (r.status === "running" ? " " + r.progress + " %" : "") + ")");
    if (r.error)
        L.push("Fehler: " + r.error);
    var fp = r.fingerprint || {};
    L.push("Pipeline-Stand " + (fp.hash || "–") + "   Modell " + (fp.model || "–") + "   Git " + (fp.git || "–"));
    var m = r.metrics;
    if (m)
    {
        L.push("");
        L.push(OVPad("Domäne", 14) + OVPad("Ref", 6) + OVPad("Extr", 6) + OVPad("TP", 6) + OVPad("FP", 6) + OVPad("FN", 6) + OVPad("verw.", 7) +
               OVPad("Precision", 11) + OVPad("Recall", 9) + OVPad("F1", 9) + OVPad("F1 tol.", 9) + OVPad("Seite", 9) + OVPad("Datum", 9) +
               OVPad("Status", 9) + "Wert");
        var doms = OVDomains.concat(["all"]);
        for (var i = 0; i < doms.length; i++)
        {
            var d = m[doms[i]];
            if (!d)
                continue;
            L.push(OVPad(doms[i] === "all" ? "gesamt" : OVDomainTitles[doms[i]], 14) + OVPad(d.n_ref, 6) + OVPad(d.n_pred, 6) + OVPad(d.tp, 6) +
                   OVPad(d.fp, 6) + OVPad(d.fn, 6) + OVPad(d.partial, 7) + OVPad(OVPct(d.precision), 11) + OVPad(OVPct(d.recall), 9) +
                   OVPad(OVPct(d.f1), 9) + OVPad(OVPct(d.f1_tol), 9) + OVPad(OVPct(d.side_accuracy), 9) + OVPad(OVPct(d.date_accuracy), 9) +
                   OVPad(OVPct(d.status_accuracy), 9) + OVPct(d.value_accuracy));
        }
        if (m.n_failed)
            L.push(m.n_failed + " von " + m.n_items + " Briefen ohne Ergebnis (siehe CSV).");
    }
    var c = r.comparison;
    if (c)
    {
        L.push("");
        L.push("Vergleich mit Basis-Lauf " + c.baseline_run_id + ": " + (c.verdict === "ok" ? "keine Regression" : "REGRESSION in " + c.worse_domains.join(", ")) +
               " (Toleranz " + OVPct(c.tolerance) + " F1)");
        var ch = c.changes || [];
        for (var k = 0; k < ch.length && k < 40; k++)
        {
            var parts = [];
            for (var a = 0; a < ch[k].lost.length; a++)
                parts.push("verloren: " + (ch[k].lost[a].label || ch[k].lost[a].code || ch[k].lost[a].key));
            for (var b = 0; b < ch[k].new_fp.length; b++)
                parts.push("neu falsch: " + (ch[k].new_fp[b].label || ch[k].new_fp[b].code));
            if (ch[k].gained)
                parts.push(ch[k].gained + " neu richtig");
            L.push("  Brief " + ch[k].position + ": " + parts.join("; "));
        }
        if (ch.length > 40)
            L.push("  … " + (ch.length - 40) + " weitere Briefe, Details im CSV-Bericht");
    }
    [_runDetailView setString:L.join("\n")];
}

// ================================================================================
// STUDIE
// ================================================================================

- (CPView)_buildStudyView
{
    var v = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 1270, 710)];
    [v addSubview:OTButton(CGRectMake(5, 5, 180, 26), "Kennzahlen berechnen", self, @selector(computeStudy:))];
    [v addSubview:OTButton(CGRectMake(190, 5, 200, 26), "Bewertungen als CSV", self, @selector(downloadJudgments:))];
    [v addSubview:OTLabel(CGRectMake(400, 2, 860, 34),
        "Kennzahlen nach Bewertungshandbuch: Precision je Domäne (streng und tolerant), Attributgenauigkeit, Recall über die Checkliste, " +
        "Übereinstimmung zweier Prüfer (Cohens κ) und Wachsamkeit bei eingestreuten Fehlern. 95-%-KI per Bootstrap über Briefe.", NO)];
    var st = OVTextArea(CGRectMake(5, 40, 1260, 664), YES);
    _studyView = st.text;
    [v addSubview:OVM(st.scroll, CPViewWidthSizable | CPViewHeightSizable)];
    return v;
}

- (void)downloadJudgments:(id)sender
{
    if (_currentSet)
        window.open("/BBB/validation/sets/" + _currentSet.id + "/judgments.csv", "_blank");
}

- (void)computeStudy:(id)sender
{
    if (!_currentSet)
        return;
    [_studyView setString:@"Berechne Kennzahlen (Bootstrap) …"];
    OTGetJSON("/BBB/validation/sets/" + _currentSet.id + "/study", 600.0, function(res, error)
    {
        if (!res || res.error)
        {
            [_studyView setString:"Keine Kennzahlen: " + (res && res.error ? res.error : "keine Antwort vom Server")];
            return;
        }
        var L = [], m = res.metrics;
        L.push("Datensatz " + res.set.name + ": " + res.n_evaluated + " von " + res.n_items + " Briefen ausgewertet" +
               (res.n_skipped ? " (" + res.n_skipped + " unvollständig oder mit offener Abweichung)" : "") + ".");
        L.push("");
        L.push("Richtigkeit je Domäne (Teil B)");
        L.push(OVPad("Domäne", 13) + OVPad("bewertet", 10) + OVPad("Precision streng", 26) + OVPad("Precision tolerant", 26) +
               OVPad("Seite", 24) + OVPad("Datum", 24) + OVPad("Status", 24) + "Wert");
        var doms = OVDomains.concat(["all"]);
        for (var i = 0; i < doms.length; i++)
        {
            var d = m[doms[i]];
            if (!d)
                continue;
            L.push(OVPad(doms[i] === "all" ? "gesamt" : OVDomainTitles[doms[i]], 13) + OVPad(d.judged, 10) +
                   OVPad(OVPctCI(d.precision_strict, d.precision_strict_ci), 26) + OVPad(OVPctCI(d.precision_tolerant, d.precision_tolerant_ci), 26) +
                   OVPad(OVPctCI(d.side_accuracy, d.side_accuracy_ci), 24) + OVPad(OVPctCI(d.date_accuracy, d.date_accuracy_ci), 24) +
                   OVPad(OVPctCI(d.status_accuracy, d.status_accuracy_ci), 24) + OVPctCI(d.value_accuracy, d.value_accuracy_ci));
        }
        var all = m.all || {};
        L.push("Konzeptfehler gesamt: zu allgemein " + all.concept_broader + ", zu spezifisch " + all.concept_narrower + ", falsches Konzept " +
               all.concept_wrong + ", nicht im Brief " + all.concept_absent + ", falscher Bezug " + all.concept_wrong_subject +
               "; Dubletten " + all.duplicate + ", nicht beurteilbar " + all.unclear);
        L.push("");
        L.push("Vollständigkeit über die Checkliste (Teil A)");
        var rec = m.recall || {};
        var cats = [];
        for (var c in rec)
            cats.push(c);
        cats.sort(function(a, b) { return a === "all" ? 1 : (b === "all" ? -1 : a.localeCompare(b)); });
        if (!cats.length)
            L.push("  keine abgeglichenen Checklistenzeilen");
        for (var k = 0; k < cats.length; k++)
        {
            var r = rec[cats[k]];
            L.push("  " + OVPad(cats[k] === "all" ? "gesamt" : cats[k], 12) + OVPad("n = " + r.n, 10) + "Recall " + OVPad(OVPctCI(r.recall, r.recall_ci), 26) +
                   "ohne Attributfehler " + OVPct(r.recall_exact));
        }
        L.push("");
        L.push("Übereinstimmung zweier Prüfer (doppelt geprüfte Briefe)");
        var kap = res.kappa || {};
        var kl = { overall: "korrekt ja/nein", concept: "Konzept", status: "Status", side: "Seite", date: "Datum" };
        var anyK = NO;
        for (var key in kl)
            if (kap[key])
            {
                anyK = YES;
                L.push("  " + OVPad(kl[key], 18) + "n = " + OVPad(kap[key].n, 6) + "Übereinstimmung " + OVPad(OVPct(kap[key].agreement), 10) +
                       "κ = " + (kap[key].kappa === null || kap[key].kappa === undefined ? "–" : kap[key].kappa.toFixed(3)));
            }
        if (!anyK)
            L.push("  noch keine doppelt abgeschlossenen Briefe");
        L.push("");
        L.push("Wachsamkeit bei eingestreuten Fehlern");
        var vg = res.vigilance || {}, vt = { side_swap: "Seite vertauscht", date_shift: "Datum verschoben", drop: "Eintrag entfernt" };
        var anyV = NO;
        for (var t in vg)
        {
            anyV = YES;
            L.push("  " + OVPad(vt[t] || t, 18) + OVPad(vg[t].detected + " von " + vg[t].n, 12) + "erkannt " + OVPct(vg[t].rate));
        }
        if (!anyV)
            L.push("  keine eingestreuten Fehler bewertet");

        var judges = res.judges || {}, jnames = [];
        for (var jn in judges)
            jnames.push(jn);
        jnames.sort();
        if (!jnames.length)
        {
            L.push("");
            L.push("KI-Judge im Vergleich zu den Ärzten");
            L.push("  noch keine KI-Bewertungen");
        }
        for (var q = 0; q < jnames.length; q++)
        {
            var jg = judges[jnames[q]];
            L.push("");
            L.push("KI-Judge " + jnames[q] + " im Vergleich zu den Ärzten");
            if (!jg || !jg.n_items)
            {
                L.push("  noch keine Briefe, die von Ärzten abgeschlossen und von diesem Judge bewertet sind");
                continue;
            }
            var cf = jg.confusion || {};
            L.push("  " + jg.n_items + " Briefe. Von den Ärzten gefundene Fehler erkennt der Judge zu " + OVPct(jg.sensitivity) +
                   " (Sensitivität); als korrekt bewertete Einträge bestätigt er zu " + OVPct(jg.specificity) + " (Spezifität).");
            L.push("  beide korrekt " + (cf.both_correct || 0) + ", beide Fehler " + (cf.both_error || 0) + ", nur Judge Fehler " +
                   (cf.judge_only_error || 0) + ", vom Judge übersehen " + (cf.judge_missed_error || 0));
            var jk = jg.kappa || {};
            for (var key2 in kl)
                if (jk[key2])
                    L.push("  " + OVPad(kl[key2], 18) + "n = " + OVPad(jk[key2].n, 6) + "Übereinstimmung " + OVPad(OVPct(jk[key2].agreement), 10) +
                           "κ = " + (jk[key2].kappa === null || jk[key2].kappa === undefined ? "–" : jk[key2].kappa.toFixed(3)));
            var jm = jg.missing || {};
            L.push("  Fehlende Einträge (mit Code): von beiden genannt " + (jm.both || 0) + ", nur Ärzte " + (jm.human_only || 0) +
                   ", nur Judge " + (jm.judge_only || 0));
            var jv = jg.vigilance || {};
            for (var t2 in jv)
                L.push("  eingestreut: " + OVPad(vt[t2] || t2, 18) + OVPad(jv[t2].detected + " von " + jv[t2].n, 12) + "erkannt " + OVPct(jv[t2].rate));
        }
        var jb = res.judges_between;
        if (jb && jb.overall)
        {
            L.push("");
            L.push("Judges untereinander (" + jb.models.join(" vs. ") + "): n = " + jb.overall.n + ", Übereinstimmung " + OVPct(jb.overall.agreement) +
                   ", κ = " + (jb.overall.kappa === null || jb.overall.kappa === undefined ? "–" : jb.overall.kappa.toFixed(3)));
        }
        [_studyView setString:L.join("\n")];
    });
}

// ================================================================================
// TABELLEN
// ================================================================================

- (int)numberOfRowsInTableView:(CPTableView)aTableView
{
    if (aTableView === _itemsTable)
        return _items ? _items.length : 0;
    if (aTableView === _entriesTable)
        return (_item && _item.entries) ? _item.entries.length : 0;
    if (aTableView === _missingTable)
        return _missing ? _missing.length : 0;
    if (aTableView === _checklistTable)
        return (_checklist && _checklist.lines) ? _checklist.lines.length : 0;
    if (aTableView === _runsTable)
        return _runs ? _runs.length : 0;
    return 0;
}

- (id)tableView:(CPTableView)aTableView objectValueForTableColumn:(CPTableColumn)aColumn row:(int)row
{
    var ident = [aColumn identifier];

    if (aTableView === _itemsTable)
    {
        var it = _items[row];
        if (!it)
            return @"";
        if (ident === "state")
            return [self _itemState:it];
        return it[ident] === undefined || it[ident] === null ? @"" : String(it[ident]);
    }

    if (aTableView === _entriesTable)
    {
        var e = _item.entries[row];
        if (!e)
            return @"";
        switch (ident)
        {
            case "domain":   return OVDomainTitles[e.domain] || e.domain;
            case "side":     return OVSideTitles[e.side] || e.side || "";
            case "value":    return e.value !== undefined && e.value !== null ? String(e.value) + (e.unit ? " " + e.unit : "") : (e.value_text || "");
            case "judgment": return (e.excluded ? "[verneint] " : "") + OVJudgmentText(_judgments[e.key]);
            case "others":
                if (!_item.others)
                    return @"";
                var parts = [];
                for (var name in _item.others)
                    parts.push(name + ": " + OVJudgmentText(_item.others[name][e.key]));
                return parts.join(" | ");
            default:         return e[ident] === undefined || e[ident] === null ? @"" : String(e[ident]);
        }
    }

    if (aTableView === _missingTable)
    {
        var m = _missing[row] ? _missing[row].data : nil;
        if (!m)
            return @"";
        if (ident === "domain")
            return OVDomainTitles[m.domain] || m.domain;
        if (ident === "side")
            return OVSideTitles[m.side] || m.side || "";
        return m[ident] || @"";
    }

    if (aTableView === _checklistTable)
    {
        var l = _checklist.lines[row];
        if (!l)
            return @"";
        if (ident === "side")
            return OVSideTitles[l.side] || l.side || "";
        if (ident === "match")
            return OVMatchTitles[l.match || ""];
        return l[ident] || @"";
    }

    if (aTableView === _runsTable)
    {
        var r = _runs[row];
        if (!r)
            return @"";
        var all = (r.metrics && r.metrics.all) ? r.metrics.all : {};
        switch (ident)
        {
            case "started":     return String(r.started_at || "").substring(0, 16);
            case "mode":        return r.mode === "stored" ? "gespeichert" : "neu extrahiert";
            case "status":      return r.status === "running" ? "läuft " + r.progress + " %" : (r.status === "finished" ? "fertig" : r.status);
            case "f1":          return OVPct(all.f1);
            case "precision":   return OVPct(all.precision);
            case "recall":      return OVPct(all.recall);
            case "delta":
                if (!r.comparison || !r.comparison.delta_f1 || r.comparison.delta_f1.all === undefined)
                    return (_currentSet && _currentSet.baseline_run_id === r.id) ? "Basis" : "–";
                var dv = r.comparison.delta_f1.all;
                return (dv >= 0 ? "+" : "") + (100 * dv).toFixed(1) + " Pp.";
            case "verdict":
                if (!r.comparison)
                    return (_currentSet && _currentSet.baseline_run_id === r.id) ? "Basis" : "";
                return r.comparison.verdict === "ok" ? "ok" : "Regression";
            case "fingerprint": return r.fingerprint ? (r.fingerprint.hash || "") : "";
            default:            return r[ident] === undefined || r[ident] === null ? @"" : String(r[ident]);
        }
    }
    return @"";
}

- (void)tableViewSelectionDidChange:(CPNotification)aNotification
{
    var table = [aNotification object];
    if (table === _itemsTable)
    {
        var row = [_itemsTable selectedRow];
        if (row >= 0 && row < _items.length && (!_item || _item.id !== _items[row].id))
            [self loadItem:_items[row].id];
    }
    else if (table === _runsTable)
        [self _showRunDetail];
}

@end
