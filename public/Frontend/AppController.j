/*
 * AppController.j
 * Integrated FHIR R6 Eligibility Criteria Editor, HPO Tree Browser & Phenopacket Extractor
 * Refactored to utilize Cappusance XML Layouts & DB Entity Bindings
 */

@import <Foundation/Foundation.j>
@import <AppKit/AppKit.j>
@import <Renaissance/Renaissance.j>
@import "ToolsController.j"

@implementation _CPStateMarker(_MonkeyPatch)
- (integer)length{ return 0}
@end

// --------------------------------------------------------------------------------
// Renaissance Custom Layout Tag Registrations
// --------------------------------------------------------------------------------


@implementation GSMarkupTagRuleEditor : GSMarkupTagControl
+ (CPString)tagName
{
    return @"ruleEditor";
}
+ (Class)platformObjectClass
{
    return [FHIRRuleEditor class];
}

- (id)initPlatformObject:(id)platformObject
{
    platformObject = [super initPlatformObject: platformObject];

    [platformObject setRowHeight:28.0];
    [platformObject setCanRemoveAllRows:YES];
    [platformObject setNestingMode:CPRuleEditorNestingModeCompound];
    [platformObject setRowClass:[FHIRCriteriaNode class]];
    [platformObject setRowTypeKeyPath:@"rowType"];
    [platformObject setSubrowsKeyPath:@"subrows_none"];
    [platformObject setCriteriaKeyPath:@"criteria"];
    [platformObject setDisplayValuesKeyPath:@"displayValues"];

    return platformObject;
}

@end

@implementation GSMarkupTagHPOOutlineView : GSMarkupTagControl
+ (CPString)tagName { return @"HPOOutlineView"; }
+ (Class)platformObjectClass { return [HPOOutlineView class]; }
- (id)initPlatformObject:(id)platformObject
{
    platformObject = [super initPlatformObject: platformObject];
    var column = [[CPTableColumn alloc] initWithIdentifier:@"name"];
    [[column headerView] setStringValue:@"Hierarchy Nodes"];
    [column setResizingMask:CPTableColumnAutoresizingMask];
    [platformObject setColumnAutoresizingStyle:CPTableViewLastColumnOnlyAutoresizingStyle];
    [platformObject addTableColumn:column];
    [platformObject setOutlineTableColumn:column];
    [platformObject setAllowsMultipleSelection:NO];

    return platformObject;
}

@end

@implementation GSMarkupTagNoCibTableView : GSMarkupTagTableView
+ (CPString)tagName { return @"noCibTableView"; }
+ (Class)platformObjectClass { return [NoCibTableView class]; }
- (id)initPlatformObject:(id)platformObject
{
    platformObject = [super initPlatformObject: platformObject];
    [platformObject setRowHeight:26.0];

    return platformObject;
}

@end

HostURL = ""
BaseURL = HostURL + "/";

window.G_SESSION = ''

@implementation SessionStore : FSStore

- (CPURLRequest)requestForAddressingObjectsWithKey:(CPString)aKey equallingValue:(id)someval inEntity:(FSEntity)someEntity
{
    return [CPURLRequest requestWithURL:[self baseURL]+"/"+[someEntity name]+"/"+aKey+"/"+someval+"?session="+ window.G_SESSION];
}
- (CPURLRequest)requestForFuzzilyAddressingObjectsWithKey:(CPString)aKey equallingValue:(id)someval inEntity:(FSEntity)someEntity
{
    return [CPURLRequest requestWithURL:[self baseURL]+"/"+[someEntity name]+"/"+aKey+"/like/"+someval+"?session="+ window.G_SESSION];
}
- (CPURLRequest)requestForAddressingAllObjectsInEntity:(FSEntity)someEntity
{
    return [CPURLRequest requestWithURL: [self baseURL]+"/"+[someEntity name]+"?session="+ window.G_SESSION];
}

@end

// --------------------------------------------------------------------------------
// HPOOutlineView Subclass (Supports dragging while keeping TreeController Bindings)
// --------------------------------------------------------------------------------

@implementation HPOOutlineView : CPOutlineView

- (GSAutoLayoutAlignment) autolayoutDefaultVerticalAlignment
{
    return GSAutoLayoutExpand;
}
- (GSAutoLayoutAlignment) autolayoutDefaultHorizontalAlignment
{
    return GSAutoLayoutExpand;
}

- (void)mouseDragged:(CPEvent)anEvent
{
    var rep = [self representedObject];
    if (!rep || !rep.code) return;

    var pboard = [CPPasteboard pasteboardWithName:CPDragPboard];
    [pboard declareTypes:[CPArray arrayWithObjects:@"HPOTermPboardType", CPStringPboardType, nil] owner:self];

    var dict = [CPDictionary dictionaryWithObjectsAndKeys:
                    rep.code, @"code",
                rep.display, @"display",
                (rep.is_modifier) ? [CPNumber numberWithBool:YES] : [CPNumber numberWithBool:NO], @"is_modifier"
    ];

    [pboard setPropertyList:dict forType:@"HPOTermPboardType"];
    [pboard setString:rep.code forType:CPStringPboardType];

    var isDiag  = NO;
    var isOps   = NO;
    var isAtc   = NO;
    var isLoinc = NO;
    
    if (rep.code) {
        if ([rep.code hasPrefix:@"ICD10:"]) isDiag = YES;
        else if ([rep.code hasPrefix:@"OPS:"]) isOps = YES;
        else if ([rep.code hasPrefix:@"ATC:"]) isAtc = YES;
        else if ([rep.code hasPrefix:@"LOINC:"]) isLoinc = YES;
    }

    var dragView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 150, 20)];
    if (isDiag) {
        [dragView setBackgroundColor:[CPColor colorWithRed:40/255.0 green:130/255.0 blue:80/255.0 alpha:0.85]]; // Clinical Green
    } else if (isOps) {
        [dragView setBackgroundColor:[CPColor colorWithRed:150/255.0 green:40/255.0 blue:130/255.0 alpha:0.85]]; // OPS Violet
    } else if (isAtc) {
        [dragView setBackgroundColor:[CPColor colorWithRed:180/255.0 green:40/255.0 blue:40/255.0 alpha:0.85]]; // ATC Crimson
    } else if (isLoinc) {
        [dragView setBackgroundColor:[CPColor colorWithRed:0/255.0 green:140/255.0 blue:140/255.0 alpha:0.85]]; // LOINC Teal
    } else {
        [dragView setBackgroundColor:[CPColor colorWithRed:0.0 green:0.5 blue:0.7 alpha:0.85]]; // HPO Blue
    }

    var dragLabel = [[CPTextField alloc] initWithFrame:CGRectMake(5, 2, 140, 16)];
    [dragLabel setStringValue:rep.display];
    [dragLabel setTextColor:[CPColor whiteColor]];
    [dragLabel setFont:[CPFont systemFontOfSize:10.0]];
    [dragView addSubview:dragLabel];

    [self dragView:dragView
                at:CGPointMakeZero()
            offset:CGSizeMakeZero()
             event:anEvent
        pasteboard:pboard
            source:self
         slideBack:YES];
}

@end

// Helper to allow native JS object serialization to work nicely in Cappuccino
@implementation CPDictionary (JSONHelper)
- (id)JSObject
{
    var obj = {};
    var keys = [self allKeys];
    for (var i = 0; i < [keys count]; i++)
    {
        var key = [keys objectAtIndex:i];
        var val = [self objectForKey:key];

        if (val && val.isa && [val respondsToSelector:@selector(JSObject)])
            obj[key] = [val JSObject];
        else
            obj[key] = val;
    }
    return obj;
}
@end

@implementation CPArray (JSONHelper)
- (id)JSObject
{
    var arr = [];
    for (var i = 0; i < [self count]; i++)
    {
        var val = [self objectAtIndex:i];
        if (val && val.isa && [val respondsToSelector:@selector(JSObject)])
            arr.push([val JSObject]);
        else
            arr.push(val);
    }
    return arr;
}
@end

// --------------------------------------------------------------------------------
// SelectionColorTextField Subclass (Ensures readability in selected/unselected rows)
// --------------------------------------------------------------------------------

@implementation SelectionColorTextField : CPTextField
{
    CPColor _unselectedColor;
}

- (void)setUnselectedColor:(CPColor)aColor
{
    _unselectedColor = aColor;
    if ([self hasThemeState:CPThemeStateSelectedDataView])
    {
        [self setTextColor:[CPColor whiteColor]];
    }
    else
    {
        [self setTextColor:_unselectedColor];
    }
}

- (BOOL)setThemeState:(CPThemeState)aState
{
    var result = [super setThemeState:aState];
    if (aState === CPThemeStateSelectedDataView)
    {
        [self setTextColor:[CPColor whiteColor]];
    }
    return result;
}

- (BOOL)unsetThemeState:(CPThemeState)aState
{
    var result = [super unsetThemeState:aState];
    if (aState === CPThemeStateSelectedDataView)
    {
        [self setTextColor:_unselectedColor || [CPColor blackColor]];
    }
    return result;
}

@end

// --------------------------------------------------------------------------------
// Subclass for Custom Token Customization (HPO/ICD-10/OPS/ATC Code + Label Styling)
// --------------------------------------------------------------------------------

@implementation HPOTokenFieldToken : _CPTokenFieldToken

+ (CPString)defaultThemeClass
{
    return "tokenfield-token";
}

- (void)setHighlighted:(BOOL)isHighlighted
{
    [super setHighlighted:isHighlighted];
    [self setNeedsLayout];
    
    if (isHighlighted && self._tokenField)
    {
        [[CPNotificationCenter defaultCenter] postNotificationName:@"HPOTokenDidSelectNotification"
                                                            object:self._tokenField];
    }
}

- (CGSize)_minimumFrameSize
{
    var minSize = [self currentValueForThemeAttribute:@"min-size"],
        contentInset = [self currentValueForThemeAttribute:@"content-inset"];
    var size = CGSizeMake(0, 18);
    var rep = [self representedObject];
    if (rep && rep.code)
    {
        var codeWidth = [rep.code sizeWithFont:[CPFont boldSystemFontOfSize:8.0]].width + 10;

        var displayText = rep.display || @"";
        if (displayText.length > 30) {
            displayText = [displayText substringToIndex:30] + @"...";
        }
        var textWidth = [displayText sizeWithFont:[CPFont systemFontOfSize:9.0]].width + 6;
        
        var buttonSpacing = (self._buttonType === CPTokenFieldDeleteButtonType) ? 14 : 0;
        size.width = codeWidth + textWidth + 24 + buttonSpacing;
    }
    else
    {
        size.width = MAX(minSize.width, [([self stringValue] || @" ") sizeWithFont:[self font]].width + contentInset.left + contentInset.right);
    }
    return size;
}

- (void)_delete:(id)sender
{
    if (self._tokenField)
    {
        [self._tokenField _deleteToken:self];
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    if (self._DOMTextElement) {
        self._DOMTextElement.innerHTML = "";
        self._DOMTextElement.style.display = "none";
        self._DOMTextElement.style.visibility = "hidden";
        self._DOMTextElement.style.color = "transparent";
    }

    var defaultContentView = [self layoutEphemeralSubviewNamed:@"content-view"
                                                    positioned:CPWindowAbove
                               relativeToEphemeralSubviewNamed:nil];
    if (defaultContentView) {
        [defaultContentView setHidden:YES];
    }

    self._DOMElement.style.outline = "none";
    self._DOMElement.style.boxShadow = "none";

    if (self._deleteButton)
    {
        var tokenWidth = [self bounds].size.width;
        [self._deleteButton setFrame:CGRectMake(tokenWidth - 15, 2, 12, 12)];
        [self._deleteButton setHidden:NO];
        [self._deleteButton setEnabled:YES];
        [self._deleteButton setTarget:self];
        [self._deleteButton setAction:@selector(_delete:)];
    }

    var rep = [self representedObject];
    if (rep && rep.code)
    {
        var codeLabel = [self viewWithTag:101];
        if (!codeLabel)
        {
            codeLabel = [[CPView alloc] initWithFrame:CGRectMakeZero()];
            [codeLabel setTag:101];
            [codeLabel setHitTests:NO];
            [self addSubview:codeLabel];
        }

        var textLabel = [self viewWithTag:102];
        if (!textLabel)
        {
            textLabel = [[CPView alloc] initWithFrame:CGRectMakeZero()];
            [textLabel setTag:102];
            [textLabel setHitTests:NO];
            [self addSubview:textLabel];
        }

        if (codeLabel._DOMElement)
        {
            codeLabel._DOMElement.innerHTML = rep.code;
            var codeStyle = codeLabel._DOMElement.style;
            
            var isOrange = (rep.code === "30525-0" ||
                            rep.code === "76689-9" ||
                            rep.code === "LP7753-9" ||
                            rep.code === "21889-1" ||
                            rep.code === "LOINC:LP7753-9" ||
                            rep.code === "temporal-constraint" ||
                            rep.code === "performed-time" ||
                            rep.code === "onset" ||
                            rep.is_demographic);

            // Prüfung auf Augenseite / Lateraltät (SNOMED-Codes & Beschriftung)
            var isLaterality = (rep.code.indexOf("SNOMED:") === 0 ||
                                rep.code === "261185002" ||
                                rep.code === "261186004" ||
                                rep.code === "261184001" ||
                                (rep.display && (rep.display === "Right eye" || rep.display === "Left eye" || rep.display === "Both eyes")));

            if (isLaterality) {
                codeStyle.backgroundColor = "rgb(200, 100, 0)"; // Einheitliches Orange für Augenseite
            } else if (rep.code.indexOf("ICD10:") === 0) {
                codeStyle.backgroundColor = "rgb(40, 130, 80)"; // Clinical Green
            } else if (rep.code.indexOf("OPS:") === 0) {
                codeStyle.backgroundColor = "rgb(150, 40, 130)"; // Violet for OPS
            } else if (rep.code.indexOf("ATC:") === 0) {
                codeStyle.backgroundColor = "rgb(180, 40, 40)"; // Crimson for ATC
            } else if (isOrange) {
                codeStyle.backgroundColor = "rgb(200, 100, 0)"; // Orange Badge
            } else if (rep.code.indexOf("LOINC:") === 0) {
                codeStyle.backgroundColor = "rgb(0, 140, 140)"; // LOINC Teal
            } else if (rep.is_modifier) {
                codeStyle.backgroundColor = "rgb(120, 120, 120)"; // Slate Gray
            } else {
                codeStyle.backgroundColor = "rgb(0, 128, 180)"; // HPO Blue
            }

            codeStyle.borderRadius = "3px";
            codeStyle.color = "white";
            codeStyle.lineHeight = "12px";
            codeStyle.textAlign = "center";
            codeStyle.fontSize = "8px";
            codeStyle.fontWeight = "bold";
            codeStyle.fontFamily = "sans-serif";
        }

        var displayText = rep.display || @"";
        if (displayText.length > 30) {
            displayText = [displayText substringToIndex:30] + @"...";
        }

        if (textLabel._DOMElement)
        {
            textLabel._DOMElement.innerHTML = displayText;
            var textStyle = textLabel._DOMElement.style;
            
            var isRowSelected = NO;
            if (self._tokenField && ([self._tokenField hasThemeState:CPThemeStateSelectedDataView] || [self._tokenField hasThemeState:CPThemeStateSelected]))
            {
                isRowSelected = YES;
            }

            if ([self hasThemeState:CPThemeStateHighlighted] || [self hasThemeState:CPThemeStateSelected] || isRowSelected) {
                textStyle.color = "rgb(235, 245, 255)";
            } else {
                textStyle.color = "rgb(100, 100, 100)";
            }
            
            textStyle.lineHeight = "12px";
            textStyle.textAlign = "center";
            textStyle.fontSize = "9px";
            textStyle.fontFamily = "sans-serif";
        }

        var bounds = [self bounds];
        var codeWidth = [rep.code sizeWithFont:[CPFont boldSystemFontOfSize:8.0]].width + 10;
        var textWidth = [displayText sizeWithFont:[CPFont systemFontOfSize:9.0]].width + 6;

        [codeLabel setFrame:CGRectMake(4, 2, codeWidth, 12)];
        [textLabel setFrame:CGRectMake(codeWidth + 8, 2, textWidth, 12)];
    }
}

- (void)mouseUp:(CPEvent)anEvent
{
    [super mouseUp:anEvent];

    var rep = [self representedObject];
    if (!rep || !rep.code) return;

    var isSearchableCode = ([rep.code hasPrefix:@"HP:"] ||
                            [rep.code hasPrefix:@"ICD10:"] ||
                            [rep.code hasPrefix:@"OPS:"] ||
                            [rep.code hasPrefix:@"ATC:"] ||
                            ([rep.code hasPrefix:@"LOINC:"] && rep.code !== "LOINC:29003-1" && rep.code !== "LOINC:LP7753-9"));

    var isOrangeToken = (rep.code === "30525-0" ||
                         rep.code === "76689-9" ||
                         rep.code === "LP7753-9" ||
                         rep.code === "21889-1" ||
                         rep.code === "LOINC:LP7753-9" ||
                         rep.code === "temporal-constraint" ||
                         rep.code === "performed-time" ||
                         rep.code === "onset" ||
                         rep.is_demographic);

    if (isOrangeToken)
    {
        var popover = [[CPPopover alloc] init];
        [popover setBehavior:CPPopoverBehaviorTransient];
        [popover setAppearance:CPPopoverAppearanceMinimal];
        [popover setAnimates:YES];

        var editVC = [[TokenEditViewController alloc] initWithTokenView:self popover:popover];
        [popover setContentViewController:editVC];

        [popover showRelativeToRect:[self bounds] ofView:self preferredEdge:CPMinYEdge];
        [editVC performSelector:@selector(focusTextField) withObject:nil afterDelay:0.0];
    }
    else
    {
        var appDelegate = [CPApp delegate];
        if (appDelegate && [appDelegate respondsToSelector:@selector(searchForHPOTerm:)])
        {
            [appDelegate searchForHPOTerm:rep.code];
        }
    }
}

- (void)mouseDragged:(CPEvent)anEvent
{
    var rep = [self representedObject];
    if (!rep || !rep.code) return;

    var pboard = [CPPasteboard pasteboardWithName:CPDragPboard];
    [pboard declareTypes:[CPArray arrayWithObjects:@"HPOTermPboardType", CPStringPboardType, nil] owner:self];

    var dict = [CPDictionary dictionaryWithObjectsAndKeys:
                    rep.code, @"code",
                rep.display, @"display",
                (rep.is_modifier) ? [CPNumber numberWithBool:YES] : [CPNumber numberWithBool:NO], @"is_modifier"
    ];

    [pboard setPropertyList:dict forType:@"HPOTermPboardType"];
    [pboard setString:rep.code forType:CPStringPboardType];

    var dragView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 150, 20)];
    [dragView setBackgroundColor:[CPColor colorWithRed:0.0 green:0.5 blue:0.7 alpha:0.85]];

    var dragLabel = [[CPTextField alloc] initWithFrame:CGRectMake(5, 2, 140, 16)];
    [dragLabel setStringValue:rep.display];
    [dragLabel setTextColor:[CPColor whiteColor]];
    [dragLabel setFont:[CPFont systemFontOfSize:10.0]];
    [dragView addSubview:dragLabel];

    [self dragView:dragView
                at:CGPointMakeZero()
            offset:CGSizeMakeZero()
             event:anEvent
        pasteboard:pboard
            source:self
         slideBack:YES];
}

@end

_CPTokenFieldToken = HPOTokenFieldToken;

// --------------------------------------------------------------------------------
// HPOTokenField Subclass (With Centering, Deselection, and Drag-and-Drop)
// --------------------------------------------------------------------------------

@implementation HPOTokenField : CPTokenField
{
    id _editorController;
}

- (id)initWithFrame:(CGRect)aFrame
{
    self = [super initWithFrame:aFrame];
    if (self)
    {
        [[CPNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(otherTokenDidSelect:)
                                                     name:@"HPOTokenDidSelectNotification"
                                                   object:nil];
    }
    return self;
}

- (CGSize)_adjustedFrameSizeForSize:(CGSize)aSize
{
    var parentView = [self superview];
    if (parentView && [parentView respondsToSelector:@selector(rowIndex)])
    {
        var parentWidth = [parentView frame].size.width;
        var tokenX = [self frame].origin.x;
        var rightBoundary = parentWidth;
        
        var subviews = [parentView subviews];
        for (var i = 0; i < subviews.length; i++)
        {
            var otherView = subviews[i];
            if (otherView !== self)
            {
                var otherX = [otherView frame].origin.x;
                if (otherX > tokenX)
                {
                    rightBoundary = MIN(rightBoundary, otherX);
                }
            }
        }
        
        var newWidth = rightBoundary - tokenX - 8;
        if (newWidth > 0)
        {
            aSize.width = newWidth;
        }
    }
    return aSize;
}

- (void)setFrame:(CGRect)aFrame
{
    aFrame.size = [self _adjustedFrameSizeForSize:aFrame.size];
    [super setFrame:aFrame];
}

- (void)setFrameSize:(CGSize)aSize
{
    aSize = [self _adjustedFrameSizeForSize:aSize];
    [super setFrameSize:aSize];
}

- (void)dealloc
{
    [[CPNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (void)setEditorController:(id)aController
{
    _editorController = aController;
}

- (BOOL)setThemeState:(CPThemeState)aState
{
    var result = [super setThemeState:aState];
    [self setNeedsLayout];
    [self setNeedsDisplay:YES];
    return result;
}

- (BOOL)unsetThemeState:(CPThemeState)aState
{
    var result = [super unsetThemeState:aState];
    [self setNeedsLayout];
    [self setNeedsDisplay:YES];
    return result;
}

- (void)otherTokenDidSelect:(CPNotification)aNotification
{
    if ([aNotification object] !== self)
    {
        [self _selectToken:nil byExtendingSelection:NO];
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    
    var fieldBounds = [self bounds];
    if (self._tokenScrollView)
    {
        [self._tokenScrollView setFrame:CGRectMake(0, 0, fieldBounds.size.width - 20, fieldBounds.size.height)];
        
        var documentView = [self._tokenScrollView documentView];
        if (documentView)
        {
            [documentView setFrameSize:CGSizeMake([documentView frameSize].width, fieldBounds.size.height)];
            
            var subviews = [documentView subviews];
            for (var i = 0; i < subviews.length; i++)
            {
                var subview = subviews[i];
                if ([subview isKindOfClass:[_CPTokenFieldToken class]])
                {
                    var frame = [subview frame],
                        tokenHeight = frame.size.height,
                        centerY = Math.round((fieldBounds.size.height - tokenHeight) / 2.0);
                    
                    [subview setFrameOrigin:CGPointMake(frame.origin.x, centerY)];
                    [subview setNeedsLayout];
                }
            }
        }
    }
}

- (void)keyDown:(CPEvent)anEvent
{
    var keyCode = [anEvent keyCode];
    if ((keyCode === 8 || keyCode === 46) && _selectedRange && _selectedRange.length > 0)
    {
        [self _removeSelectedTokens:nil];
        return;
    }
    [super keyDown:anEvent];
}

- (CPDragOperation)draggingEntered:(id <CPDraggingInfo>)sender
{
    var pboard = [sender draggingPasteboard];
    if ([[pboard types] containsObject:@"HPOTermPboardType"] || [[pboard types] containsObject:CPStringPboardType])
    {
        self._DOMElement.style.outline = "2px dashed #0080B4";
        [self setBackgroundColor:[CPColor colorWithRed:0.94 green:0.97 blue:1.0 alpha:1.0]];
        return CPDragOperationCopy;
    }
    return CPDragOperationNone;
}

- (CPDragOperation)draggingUpdated:(id <CPDraggingInfo>)sender
{
    var pboard = [sender draggingPasteboard];
    if ([[pboard types] containsObject:@"HPOTermPboardType"] || [[pboard types] containsObject:CPStringPboardType])
    {
        return CPDragOperationCopy;
    }
    return CPDragOperationNone;
}

- (void)draggingExited:(id <CPDraggingInfo>)sender
{
    self._DOMElement.style.outline = "none";
    [self setBackgroundColor:[CPColor whiteColor]];
}

- (BOOL)performDragOperation:(id <CPDraggingInfo>)sender
{
    self._DOMElement.style.outline = "none";
    [self setBackgroundColor:[CPColor whiteColor]];

    var pboard = [sender draggingPasteboard];
    var dict = nil;

    if ([[pboard types] containsObject:@"HPOTermPboardType"])
    {
        dict = [pboard propertyListForType:@"HPOTermPboardType"];
    }

    if (!dict && [[pboard types] containsObject:CPStringPboardType])
    {
        var str = [pboard stringForType:CPStringPboardType];

        if (str && ([str hasPrefix:@"HP:"] || [str hasPrefix:@"ICD10:"] || [str hasPrefix:@"OPS:"] || [str hasPrefix:@"ATC:"] || [str hasPrefix:@"LOINC:"]))
        {
            dict = { "code": str, "display": str };
        }
    }

    if (dict)
    {
        var code = nil;
        var display = nil;
        var isModifier = false;

        if ([dict respondsToSelector:@selector(objectForKey:)])
        {
            code = [dict objectForKey:@"code"];
            display = [dict objectForKey:@"display"];
            isModifier = [[dict objectForKey:@"is_modifier"] boolValue];
        }
        else
        {
            code = dict.code;
            display = dict.display;
            isModifier = dict.is_modifier;
        }

        if (code)
        {
            var tokens = [self objectValue] || [];
            var exists = NO;
            for (var i = 0; i < tokens.length; i++)
            {
                var existingCode = tokens[i].code;
                if (existingCode === code)
                {
                    exists = YES;
                    break;
                }
            }
            if (!exists)
            {
                var mutableTokens = [CPMutableArray arrayWithArray:tokens];
                [mutableTokens addObject:{ "code": code, "display": display, "is_modifier": isModifier }];
                [self setObjectValue:mutableTokens];

                if (_editorController)
                {
                    [_editorController ruleEditorDidChange:self];
                }
            }
            return YES;
        }
    }
    return NO;
}

@end

// --------------------------------------------------------------------------------
// NoCibTableView Subclass (View-Based TableView without CIB Loading)
// --------------------------------------------------------------------------------

@implementation NoCibTableView : CPTableView

- (id)makeViewWithIdentifier:(CPString)anIdentifier owner:(id)anOwner
{
    if (!anIdentifier)
        return nil;

    var reusableViews = _cachedDataViews[anIdentifier];
    if (reusableViews && reusableViews.length > 0)
    {
        return reusableViews.pop();
    }

    return nil;
}

- sizeToFit {return nil}
@end

// --------------------------------------------------------------------------------
// Category to make _CPRuleEditorRowObject fully API-compatible with FHIRCriteriaNode
// --------------------------------------------------------------------------------
@implementation _CPRuleEditorRowObject (CustomKeysPatch)

- (CPArray)subrows_none
{
    return [self subrows];
}

- (void)setSubrows_none:(CPArray)value
{
    [self setSubrows:value];
}

- (int)indentation
{
    return self._indentation || 0;
}

- (void)setIndentation:(int)value
{
    if (value === 0 && (self._indentation || 0) > 0)
    {
        return;
    }
    self._indentation = value;
}

- (id)tokenField
{
    return self._tokenField;
}

- (void)setTokenField:(id)value
{
    self._tokenField = value;
}

- (CPArray)hpoTokens
{
    return self._hpoTokens || [];
}

- (void)setHpoTokens:(CPArray)value
{
    self._hpoTokens = value;
}

- (CPString)symptomText
{
    return self._symptomText || @"";
}

- (void)setSymptomText:(CPString)value
{
    self._symptomText = value;
}

- (BOOL)isDiagnosis
{
    return self._isDiagnosis || NO;
}

- (void)setIsDiagnosis:(BOOL)value
{
    self._isDiagnosis = value;
}

- (BOOL)isProcedure
{
    return self._isProcedure || NO;
}

- (void)setIsProcedure:(BOOL)value
{
    self._isProcedure = value;
}

- (BOOL)isMedication
{
    return self._isMedication || NO;
}

- (void)setIsMedication:(BOOL)value
{
    self._isMedication = value;
}

- (BOOL)isDemographic
{
    return self._isDemographic || NO;
}

- (void)setIsDemographic:(BOOL)value
{
    self._isDemographic = value;
}

- (CPString)presenceMode
{
    return self._presenceMode || @"all-present";
}

- (void)setPresenceMode:(CPString)value
{
    self._presenceMode = value;
}

- (CPString)combinationMethod
{
    return self._combinationMethod || @"all-of";
}

- (void)setCombinationMethod:(CPString)value
{
    self._combinationMethod = value;
}

- (BOOL)exclude
{
    return self._exclude || NO;
}

- (void)setExclude:(BOOL)value
{
    self._exclude = value;
}

@end

// --------------------------------------------------------------------------------
// FHIRCriteriaNode (Structured MVC Row Model)
// --------------------------------------------------------------------------------

@implementation FHIRCriteriaNode : CPObject
{
    CPRuleEditorRowType _rowType           @accessors(property=rowType);
    CPMutableArray      _subrows           @accessors(property=subrows);
    CPArray             _criteria          @accessors(property=criteria);
    CPArray             _displayValues     @accessors(property=displayValues);

    CPString            _symptomText;
    BOOL                _exclude;
    CPString            _presenceMode;
    CPString            _combinationMethod @accessors(property=combinationMethod);
    int                 _indentation       @accessors(property=indentation);

    HPOTokenField       _tokenField        @accessors(property=tokenField);
    CPArray             _hpoTokens         @accessors(property=hpoTokens);

    BOOL                _isDiagnosis       @accessors(property=isDiagnosis);
    BOOL                _isProcedure       @accessors(property=isProcedure);
    BOOL                _isMedication      @accessors(property=isMedication);
    BOOL                _isLoinc           @accessors(property=isLoinc);
    BOOL                _isDemographic     @accessors(property=isDemographic);
    CPArray             _subrows_none      @accessors(property=subrows_none);
}

- (id)init
{
    self = [super init];
    if (self)
    {
        _subrows = [CPMutableArray array];
        _criteria = [CPArray array];
        _displayValues = [CPArray array];
        _rowType = CPRuleEditorRowTypeSimple;
        _symptomText = @"";
        _exclude = NO;
        _presenceMode = @"all-present";
        _combinationMethod = @"all-of";
        _indentation = 0;
        _hpoTokens = [];
        _isDiagnosis = NO;
        _isProcedure = NO;
        _isMedication = NO;
        _isLoinc = NO;
        _isDemographic = NO;
        _subrows_none = [];

        [self updateCriteriaAndDisplayValues];
    }
    return self;
}

- (CPArray)subrows_none
{
    return [];
}

- (void)setSymptomText:(CPString)text
{
    if (_symptomText !== text)
    {
        _symptomText = text;
        [self updateCriteriaAndDisplayValues];
    }
}

- (CPString)symptomText
{
    return _symptomText;
}

- (void)setPresenceMode:(CPString)mode
{
    if (_presenceMode !== mode)
    {
        _presenceMode = mode;
        _exclude = [mode isEqualToString:@"neither-present"];
        [self updateCriteriaAndDisplayValues];
    }
}

- (CPString)presenceMode
{
    return _presenceMode;
}

- (void)setExclude:(BOOL)exclude
{
    if (_exclude !== exclude)
    {
        _exclude = exclude;
        _presenceMode = _exclude ? @"neither-present" : @"all-present";
        [self updateCriteriaAndDisplayValues];
    }
}

- (BOOL)exclude
{
    return _exclude;
}

- (void)setCombinationMethod:(CPString)method
{
    if (_combinationMethod !== method)
    {
        _combinationMethod = method;
        [self updateCriteriaAndDisplayValues];
    }
}

- (void)setCriteria:(CPArray)criteria
{
    if (_criteria !== criteria)
    {
        _criteria = criteria;

        if (_rowType === CPRuleEditorRowTypeCompound)
        {
            if ([_criteria count] > 0)
            {
                var first = [_criteria objectAtIndex:0];
                _combinationMethod = (first === CPOrPredicateType) ? @"any-of" : @"all-of";
            }
        }
        else
        {
            if ([_criteria count] > 0)
            {
                var first = [_criteria objectAtIndex:0];
                if ([first isEqualToString:@"diagnosis"]) {
                    _isDiagnosis = YES; _isDemographic = NO; _isProcedure = NO; _isMedication = NO; _isLoinc = NO;
                } else if ([first isEqualToString:@"demographic"]) {
                    _isDemographic = YES; _isDiagnosis = NO; _isProcedure = NO; _isMedication = NO; _isLoinc = NO;
                } else if ([first isEqualToString:@"procedure"]) {
                    _isProcedure = YES; _isDiagnosis = NO; _isDemographic = NO; _isMedication = NO; _isLoinc = NO;
                } else if ([first isEqualToString:@"medication"]) {
                    _isMedication = YES; _isDiagnosis = NO; _isDemographic = NO; _isProcedure = NO; _isLoinc = NO;
                } else if ([first isEqualToString:@"loinc"]) {
                    _isLoinc = YES; _isDiagnosis = NO; _isDemographic = NO; _isProcedure = NO; _isMedication = NO;
                } else {
                    _isDiagnosis = NO; _isDemographic = NO; _isProcedure = NO; _isMedication = NO; _isLoinc = NO;
                }
            }
            if ([_criteria count] > 1)
            {
                var second = [_criteria objectAtIndex:1];
                _presenceMode = second;
                _exclude = [second isEqualToString:@"neither-present"];
            }
        }
    }
}

- (void)updateCriteriaAndDisplayValues
{
    if (_rowType === CPRuleEditorRowTypeCompound)
    {
        var predicateType = (_combinationMethod === @"any-of") ? CPOrPredicateType : CPAndPredicateType;
        var dispAllAny = (_combinationMethod === @"any-of") ? @"Any" : @"All";

        [self setCriteria:[CPArray arrayWithObjects:predicateType, @"_logical_text_", nil]];
        [self setDisplayValues:[CPArray arrayWithObjects:dispAllAny, @"of the following are true", nil]];
    }
    else
    {
        if (!_presenceMode) {
            _presenceMode = _exclude ? @"neither-present" : @"all-present";
        }

        var dispPresence = @"All must be present";
        if (_presenceMode === @"any-present") {
            dispPresence = @"Any must be present";
        } else if (_presenceMode === @"neither-present") {
            dispPresence = @"Neither must be present";
        }

        if (_isLoinc)
        {
            [self setCriteria:[CPArray arrayWithObjects:@"loinc", _presenceMode, @"_value_field_", nil]];
            [self setDisplayValues:[CPArray arrayWithObjects:@"LOINC / Lab Assay", dispPresence, @"_value_field_", nil]];
        }
        else if (_isDemographic)
        {
            [self setCriteria:[CPArray arrayWithObjects:@"demographic", _presenceMode, @"_value_field_", nil]];
            [self setDisplayValues:[CPArray arrayWithObjects:@"Demographic", dispPresence, @"_value_field_", nil]];
        }
        else if (_isDiagnosis)
        {
            [self setCriteria:[CPArray arrayWithObjects:@"diagnosis", _presenceMode, @"_value_field_", nil]];
            [self setDisplayValues:[CPArray arrayWithObjects:@"Diagnosis", dispPresence, @"_value_field_", nil]];
        }
        else if (_isProcedure)
        {
            [self setCriteria:[CPArray arrayWithObjects:@"procedure", _presenceMode, @"_value_field_", nil]];
            [self setDisplayValues:[CPArray arrayWithObjects:@"Procedure", dispPresence, @"_value_field_", nil]];
        }
        else if (_isMedication)
        {
            [self setCriteria:[CPArray arrayWithObjects:@"medication", _presenceMode, @"_value_field_", nil]];
            [self setDisplayValues:[CPArray arrayWithObjects:@"Medication", dispPresence, @"_value_field_", nil]];
        }
        else
        {
            [self setCriteria:[CPArray arrayWithObjects:@"phenotype", _presenceMode, @"_value_field_", nil]];
            [self setDisplayValues:[CPArray arrayWithObjects:@"Symptom / Phenotype", dispPresence, @"_value_field_", nil]];
        }
    }
}

@end

// --------------------------------------------------------------------------------
// FHIRRuleEditor Subclass
// --------------------------------------------------------------------------------

@implementation FHIRRuleEditor : CPRuleEditor
{
    BOOL _insertCompoundMode;
}

- (GSAutoLayoutAlignment) autolayoutDefaultVerticalAlignment
{
    return GSAutoLayoutExpand;
}
- (GSAutoLayoutAlignment) autolayoutDefaultHorizontalAlignment
{
    return GSAutoLayoutExpand;
}

- (void)setInsertCompoundMode:(BOOL)flag
{
    _insertCompoundMode = flag;
}

- (BOOL)insertCompoundMode
{
    return _insertCompoundMode;
}

- (void)_addOptionFromSlice:(id)slice ofRowType:(unsigned int)type
{
    var forcedType = _insertCompoundMode ? CPRuleEditorRowTypeCompound : CPRuleEditorRowTypeSimple;
    [super _addOptionFromSlice:slice ofRowType:forcedType];
}

- (void)_updateSliceRows
{
    [super _updateSliceRows];

    var count = [self numberOfRows];
    for (var i = 0; i < count; i++)
    {
        var slice = [_slices objectAtIndex:i];
        var depth = [self depthOfRowAtIndex:i];
        [slice setIndentation:depth];
    }
}

- (int)depthOfRowAtIndex:(int)rowIndex
{
    if (rowIndex < 0 || rowIndex >= [self numberOfRows])
        return 0;

    var rowCache = [self _rowCacheForIndex:rowIndex];
    if (rowCache)
    {
        var node = [rowCache respondsToSelector:@selector(rowObject)] ? [rowCache rowObject] : nil;
        if (node && [node respondsToSelector:@selector(indentation)])
        {
            return [node indentation];
        }
    }
    return 0;
}

- (id)nodeAtRowIndex:(int)rowIndex
{
    if (rowIndex < 0 || rowIndex >= [self numberOfRows])
        return nil;

    var rowCache = [self _rowCacheForIndex:rowIndex];
    return rowCache ? [rowCache rowObject] : nil;
}

- (CPIndexSet)indexesOfRowAndItsChildren:(int)rowIndex
{
    var count = [self numberOfRows];
    var indexes = [CPMutableIndexSet indexSetWithIndex:rowIndex];
    
    var headerNode = [self nodeAtRowIndex:rowIndex];
    if (!headerNode || [headerNode rowType] !== CPRuleEditorRowTypeCompound)
    {
        return indexes;
    }
    
    var headerDepth = [self depthOfRowAtIndex:rowIndex];
    
    for (var i = rowIndex + 1; i < count; i++)
    {
        var childDepth = [self depthOfRowAtIndex:i];
        if (childDepth > headerDepth)
        {
            [indexes addIndex:i];
        }
        else
        {
            break;
        }
    }
    
    return indexes;
}

- (BOOL)_performDragForSlice:(id)slice withEvent:(CPEvent)event
{
    var mainRowIndex = [slice rowIndex];
    console.log("[FHIR DRAG START] _performDragForSlice initiated for slice index: " + mainRowIndex);

    var draggingRows = [CPMutableIndexSet indexSetWithIndex:mainRowIndex],
        selected_indices = [self _selectedSliceIndices],
        pasteboard = [CPPasteboard pasteboardWithName:CPDragPboard];

    [pasteboard declareTypes:[CPArray arrayWithObjects:@"CPRuleEditorItemPBoardType", nil] owner:self];

    if ([selected_indices containsIndex:mainRowIndex])
    {
        [draggingRows addIndexes:selected_indices];
    }

    var expandedIndexes = [CPMutableIndexSet indexSet];
    var index = [draggingRows firstIndex];
    while (index !== CPNotFound)
    {
        var childrenOfIndex = [self indexesOfRowAndItsChildren:index];
        [expandedIndexes addIndexes:childrenOfIndex];
        index = [draggingRows indexGreaterThanIndex:index];
    }
    
    _draggingRows = expandedIndexes;

    var firstIndex = [_draggingRows firstIndex],
        firstSlice = [_slices objectAtIndex:firstIndex],
        sliceWidth = CGRectGetWidth([firstSlice frame]),
        sliceHeight = CGRectGetHeight([firstSlice frame]);

    var dragview = [[CPView alloc] initWithFrame:CGRectMake(0, 0, sliceWidth, sliceHeight)];

    var html = firstSlice._DOMElement.innerHTML;
    dragview._DOMElement.innerHTML = [html copy];

    [dragview setBackgroundColor:[firstSlice backgroundColor]];
    [dragview setAlphaValue:0.7];

    var dragPoint = CGPointMake(0, firstIndex * _sliceHeight);

    [self dragView:dragview
                at:dragPoint
            offset:CGSizeMake(0, _sliceHeight)
             event:event
        pasteboard:pasteboard
            source:self
         slideBack:YES];

    return YES;
}

- (BOOL)performDragOperation:(id <CPDraggingInfo>)sender
{
    if (!_draggingRows || [_draggingRows count] === 0)
    {
        return [super performDragOperation:sender];
    }
    
    var observedObject = _boundArrayOwner;
    var observedKeyPath = _boundArrayKeyPath;
    
    if (!observedObject || !observedKeyPath)
    {
        return [super performDragOperation:sender];
    }
    
    var rootNodes = [observedObject mutableArrayValueForKey:observedKeyPath];
    if (!rootNodes || [rootNodes count] === 0)
    {
        return [super performDragOperation:sender];
    }
    
    var targetIndex = _subviewIndexOfDropLine;
    if (targetIndex === CPNotFound)
    {
        return [super performDragOperation:sender];
    }

    var objectsToMove = [CPMutableArray array];
    var idx = [_draggingRows firstIndex];
    while (idx !== CPNotFound)
    {
        [objectsToMove addObject:[rootNodes objectAtIndex:idx]];
        idx = [_draggingRows indexGreaterThanIndex:idx];
    }
    
    var adjustedTarget = targetIndex;
    idx = [_draggingRows firstIndex];
    while (idx !== CPNotFound)
    {
        if (idx < targetIndex)
        {
            adjustedTarget--;
        }
        idx = [_draggingRows indexGreaterThanIndex:idx];
    }
    
    idx = [_draggingRows lastIndex];
    while (idx !== CPNotFound)
    {
        [rootNodes removeObjectAtIndex:idx];
        idx = [_draggingRows indexLessThanIndex:idx];
    }
    
    for (var i = 0; i < [objectsToMove count]; i++)
    {
        var obj = [objectsToMove objectAtIndex:i];
        [rootNodes insertObject:obj atIndex:adjustedTarget + i];
    }
    
    [self _clearDropLine];
    _draggingRows = nil;
    
    if ([self target] && [self action])
    {
        [self sendAction:[self action] to:[self target]];
    }
    
    return YES;
}

@end


// --------------------------------------------------------------------------------
// FHIRRuleDelegate
// --------------------------------------------------------------------------------

@implementation FHIRRuleDelegate : CPObject
{
    id _controller;
}

- (id)initWithController:(id)aController
{
    self = [super init];
    if (self)
    {
        _controller = aController;
    }
    return self;
}

- (int)ruleEditor:(CPRuleEditor)editor numberOfChildrenForCriterion:(id)criterion withRowType:(CPRuleEditorRowType)rowType
{
    if (rowType === CPRuleEditorRowTypeCompound)
    {
        if (criterion == nil) return 2;
        if (criterion == CPOrPredicateType || criterion == CPAndPredicateType) return 1;
        return 0;
    }

    if (rowType === CPRuleEditorRowTypeSimple)
    {
        if (criterion == nil) return 6; // Phenotype, Diagnosis, Demographic, Procedure, Medication, LOINC
        if (criterion == @"phenotype" || criterion == @"diagnosis" || criterion == @"demographic" || criterion == @"procedure" || criterion == @"medication" || criterion == @"loinc") return 3;
        if (criterion == @"all-present" || criterion == @"any-present" || criterion == @"neither-present") return 1;
    }
    return 0;
}

- (id)ruleEditor:(CPRuleEditor)editor child:(int)index forCriterion:(id)criterion withRowType:(CPRuleEditorRowType)rowType
{
    if (rowType === CPRuleEditorRowTypeCompound)
    {
        if (criterion == nil)
            return (index == 0) ? CPAndPredicateType : CPOrPredicateType;

        return @"_logical_text_";
    }

    if (criterion == nil) {
        if (index == 0) return @"phenotype";
        if (index == 1) return @"diagnosis";
        if (index == 2) return @"demographic";
        if (index == 3) return @"procedure";
        if (index == 4) return @"medication";
        if (index == 5) return @"loinc";
    }

    if (criterion == @"phenotype" || criterion == @"diagnosis" || criterion == @"demographic" || criterion == @"procedure" || criterion == @"medication" || criterion == @"loinc")
        return (index == 0) ? @"all-present" : ((index == 1) ? @"any-present" : @"neither-present");

    if (criterion == @"all-present" || criterion == @"any-present" || criterion == @"neither-present")
        return @"_value_field_";

    return nil;
}

- (id)ruleEditor:(CPRuleEditor)editor displayValueForCriterion:(id)criterion inRow:(int)row
{
    if (criterion === CPAndPredicateType) return @"All";
    if (criterion === CPOrPredicateType) return @"Any";
    if (criterion === @"_logical_text_") return @"of the following are true";

    if (criterion == @"phenotype") return @"Symptom / Phenotype";
    if (criterion == @"diagnosis") return @"Diagnosis";
    if (criterion == @"demographic") return @"Demographic";
    if (criterion == @"procedure") return @"Procedure";
    if (criterion == @"medication") return @"Medication";
    if (criterion == @"loinc") return @"LOINC / Lab Assay";
    if (criterion == @"all-present") return @"All must be present";
    if (criterion == @"any-present") return @"Any must be present";
    if (criterion == @"neither-present") return @"Neither must be present";

    if (criterion == @"_value_field_")
    {
        var node = [_controller nodeAtRowIndex:row];
        if (node)
        {
            var cachedField = [node tokenField];
            if (cachedField)
            {
                return cachedField;
            }

            var tokenField = [[HPOTokenField alloc] initWithFrame:CGRectMake(0, 0, 800, 24)];
            [tokenField setEditorController:_controller];
            [tokenField registerForDraggedTypes:[CPArray arrayWithObjects:@"HPOTermPboardType", nil]];

            [tokenField setAutoresizingMask:CPViewWidthSizable];

            [tokenField setEditable:YES];
            [tokenField setBezeled:YES];
            [tokenField setPlaceholderString:@"Drag and drop demographic traits or ontology codes here..."];
            [tokenField setDelegate:_controller];

            var hpoTokens = [node hpoTokens] || [];
            [tokenField setObjectValue:hpoTokens];

            [tokenField setTarget:_controller];
            [tokenField setAction:@selector(ruleEditorDidChange:)];

            tokenField.node = node;

            [[CPNotificationCenter defaultCenter] addObserver:_controller
                                                     selector:@selector(ruleEditorDidChange:)
                                                         name:CPControlTextDidEndEditingNotification
                                                       object:tokenField];

            [node setTokenField:tokenField];
            return tokenField;
        }
    }

    return criterion;
}

- (CPDictionary)ruleEditor:(CPRuleEditor)editor predicatePartsForCriterion:(id)criterion withDisplayValue:(id)value inRow:(int)row
{
    var result = [CPDictionary dictionary];

    if (criterion === CPOrPredicateType || criterion === CPAndPredicateType)
    {
        [result setObject:criterion forKey:CPRuleEditorPredicateCompoundType];
    }
    else if (criterion === @"phenotype")
    {
        [result setObject:[CPExpression expressionForKeyPath:@"phenotype"] forKey:CPRuleEditorPredicateLeftExpression];
    }
    else if (criterion === @"diagnosis")
    {
        [result setObject:[CPExpression expressionForKeyPath:@"diagnosis"] forKey:CPRuleEditorPredicateLeftExpression];
    }
    else if (criterion === @"demographic")
    {
        [result setObject:[CPExpression expressionForKeyPath:@"demographic"] forKey:CPRuleEditorPredicateLeftExpression];
    }
    else if (criterion === @"procedure")
    {
        [result setObject:[CPExpression expressionForKeyPath:@"procedure"] forKey:CPRuleEditorPredicateLeftExpression];
    }
    else if (criterion === @"medication")
    {
        [result setObject:[CPExpression expressionForKeyPath:@"medication"] forKey:CPRuleEditorPredicateLeftExpression];
    }
    else if (criterion === @"loinc")
    {
        [result setObject:[CPExpression expressionForKeyPath:@"loinc"] forKey:CPRuleEditorPredicateLeftExpression];
    }
    else if (criterion === @"all-present" || criterion === @"any-present")
    {
        [result setObject:[CPNumber numberWithInt:CPEqualToPredicateOperatorType] forKey:CPRuleEditorPredicateOperatorType];
        [result setObject:[CPNumber numberWithInt:CPDirectPredicateModifier] forKey:CPRuleEditorPredicateComparisonModifier];
        [result setObject:[CPNumber numberWithInt:CPCaseInsensitivePredicateOption] forKey:CPRuleEditorPredicateOptions];
    }
    else if (criterion === @"neither-present")
    {
        [result setObject:[CPNumber numberWithInt:CPNotEqualToPredicateOperatorType] forKey:CPRuleEditorPredicateOperatorType];
        [result setObject:[CPNumber numberWithInt:CPDirectPredicateModifier] forKey:CPRuleEditorPredicateComparisonModifier];
        [result setObject:[CPNumber numberWithInt:CPCaseInsensitivePredicateOption] forKey:CPRuleEditorPredicateOptions];
    }
    else if (criterion === @"_value_field_")
    {
        var textValue = [value respondsToSelector:@selector(stringValue)] ? [value stringValue] : @"";
        [result setObject:[CPExpression expressionForConstantValue:textValue] forKey:CPRuleEditorPredicateRightExpression];
    }
    return result;
}

@end

// --------------------------------------------------------------------------------
// JobStatusView für das OntoTrial-Hintergrundprozess-Panel
// --------------------------------------------------------------------------------
@implementation HPOJobStatusView : CPView
{
    CPProgressIndicator progressBar;
    CPTextField         statusLabel;
}

- (id)initWithFrame:(CGRect)aFrame
{
    self = [super initWithFrame:aFrame];
    if (self)
    {
        statusLabel = [[CPTextField alloc] initWithFrame:CGRectMake(0, 2, 220, 20)];
        [statusLabel setFont:[CPFont systemFontOfSize:11]];
        [statusLabel setAlignment:CPLeftTextAlignment];
        [self addSubview:statusLabel];

        progressBar = [[CPProgressIndicator alloc] initWithFrame:CGRectMake(225, 6, CGRectGetWidth(aFrame) - 230, 12)];
        [progressBar setControlSize:CPSmallControlSize];
        [progressBar setMinValue:0.0];
        [progressBar setMaxValue:100.0];
        [self addSubview:progressBar];
    }
    return self;
}

- (void)setObjectValue:(id)aTaskObject
{
    if (!aTaskObject) return;

    var state = aTaskObject.state;
    var msg   = aTaskObject.message || "";
    var val   = aTaskObject.progress;

    [statusLabel setStringValue:msg];

    if (state === "active")
    {
        [statusLabel setTextColor:[CPColor colorWithCalibratedRed:0.0 green:0.4 blue:0.8 alpha:1.0]];
        if (val !== undefined && val !== null)
        {
            [progressBar setIndeterminate:NO];
            [progressBar setDoubleValue:val];
        }
        else
        {
            [progressBar setIndeterminate:YES];
            [progressBar startAnimation:self];
        }
    }
    else if (state === "finished")
    {
        [statusLabel setTextColor:[CPColor colorWithCalibratedRed:0.0 green:0.6 blue:0.0 alpha:1.0]];
        [progressBar setIndeterminate:NO];
        [progressBar setDoubleValue:100.0];
    }
    else if (state === "failed")
    {
        [statusLabel setTextColor:[CPColor redColor]];
        [progressBar setIndeterminate:NO];
        [progressBar setDoubleValue:0.0];
    }
}
@end

// --------------------------------------------------------------------------------
// TokenEditViewController (Controls the inline text editor inside the popover)
// --------------------------------------------------------------------------------

@implementation TokenEditViewController : CPViewController
{
    CPTextField         _editField;
    HPOTokenFieldToken  _tokenView;
    CPPopover           _popover;
}

- (id)initWithTokenView:(HPOTokenFieldToken)aTokenView popover:(CPPopover)aPopover
{
    self = [super init];
    if (self)
    {
        _tokenView = aTokenView;
        _popover = aPopover;
    }
    return self;
}

- (void)loadView
{
    var view = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 240, 50)];
    
    _editField = [[CPTextField alloc] initWithFrame:CGRectMake(10, 12, 220, 25)];
    [_editField setEditable:YES];
    [_editField setBezeled:YES];
    [_editField setFont:[CPFont systemFontOfSize:11.0]];
    
    var rep = [_tokenView representedObject];
    [_editField setStringValue:rep.display || @""];
    
    [_editField setTarget:self];
    [_editField setAction:@selector(commitEdit:)];
    
    [view addSubview:_editField];
    [self setView:view];
}

- (void)focusTextField
{
    [[_editField window] makeFirstResponder:_editField];
}

- (void)commitEdit:(id)sender
{
    var newValue = [_editField stringValue];
    var rep = [_tokenView representedObject];
    
    if (rep)
    {
        if (rep.code === "30525-0" && ![newValue hasPrefix:@"Age:"]) {
            newValue = "Age: " + newValue;
        } else if (rep.code === "76689-9" && ![newValue hasPrefix:@"Sex:"]) {
            newValue = "Sex: " + newValue;
        } else if ((rep.code === "LP7753-9" || rep.code === "21889-1" || rep.code === "LOINC:LP7753-9") && ![newValue hasPrefix:@"Measurement:"]) {
            newValue = "Measurement: " + newValue;
        } else if ((rep.code === "29003-1" || rep.code === "LOINC:29003-1") && ![newValue hasPrefix:@"Schirmer Test:"]) {
            newValue = "Schirmer Test: " + newValue;
        } else if (rep.code === "temporal-constraint" && ![newValue hasPrefix:@"Temporal:"]) {
            newValue = "Temporal: " + newValue;
        } else if (rep.code === "performed-time" && ![newValue hasPrefix:@"Performed:"]) {
            newValue = "Performed: " + newValue;
        } else if (rep.code === "onset" && ![newValue hasPrefix:@"Onset:"]) {     // <-- HINZUFÜGEN
            newValue = "Onset: " + newValue;
        }

        rep.display = newValue;
        
        [_tokenView setNeedsLayout];
        [_tokenView setNeedsDisplay:YES];
        
        var tokenField = _tokenView._tokenField;
        if (tokenField)
        {
            [tokenField setNeedsLayout];
            [tokenField setNeedsDisplay:YES];
            
            if ([tokenField target] && [tokenField action])
            {
                [tokenField sendAction:[tokenField action] to:[tokenField target]];
            }
        }
    }
    
    [_popover close];
}

@end

// --------------------------------------------------------------------------------
// AppController
// --------------------------------------------------------------------------------

@implementation AppController : CPObject
{
    id  store @accessors;
    CPWindow mainWindow;
    
    // Array controllers managed by Cappusance
    id  trialsController @accessors;
    id  candidatesController @accessors;
    
    // Workspace details outlets
    FHIRRuleEditor       _ruleEditor;
    FHIRRuleDelegate     _ruleDelegate;
    CPTextView           _synopsisInputTextView;
    CPTextView           _reportInputTextView;
    CPTextView           _phenopacketOutputTextView;
    NoCibTableView       _phenoVisualTableView;
    
    // Matching - Per Study
    id                   matchesController @accessors;
    NoCibTableView       _crossmatchTableView;
    CPTextView           _narrativeTextView;
    CPArray              _crossmatchResults;
    
    // Matching - Per Patient
    id                   patientMatchesController @accessors;
    NoCibTableView       _patientCrossmatchTableView;
    CPTextView           _patientNarrativeTextView;
    CPArray              _patientCrossmatchResults;
    
    // Navigation Outlets
    CPTabView            mainWorkspaceTab;
    CPTabView            _matchingSubTabView;
    
    // Filter-Suchfelder (KVO Bindings)
    CPString             candidateFilterString @accessors;
    CPString             studyMatchFilterString @accessors;
    CPString             patientMatchFilterString @accessors;
    
    // Tagging Window Outlets
    CPWindow             _taggingWindow;
    CPTextView           _taggingPseudonymsTextView;
    CPTextField          _taggingTagTextField;
    CPCheckBox           _taggingAppendCheckBox;
    
    // Sidebar browser outlets
    CPOutlineView        outlineView;
    CPTreeController     treeController;
    CPSegmentedControl   _pickerControl;
    CPCheckBox           _nameOnlyCheckbox;
    CPTextField          _searchField;
    CPTextField          _searchStatusLabel;
    HPOTokenField        _searchTokenField;
    CPTextView           definitionTextView;
    CPTableView          synonymsTableView;
    CPTableView          xrefsTableView;
    CPTableView          downstreamTableView;
    
    CPString             _fhirJsonString;
    CPPopover            _jsonPopover;
    CPTextView           _popoverTextView;
    
    CPPopover            _exportPopover;
    CPTextView           _exportTextView;
    
    CPMutableArray       _rootNodes          @accessors(property=rootNodes);
    BOOL                 _isImportingJSON;
    
    CPArray              _allRoots;
    CPArray              _synonyms;
    CPArray              _xrefs;
    CPArray              _downstreamTerms;
    CPArray              _matchedIndexPaths;
    int                  _currentMatchIndex;
    
    CPArray              _phenoVisualItems;
    
    CPString             _currentPickerType;
    CPString             selectedModel @accessors;
    
    CPPanel              _tasksPanel;
    CPTableView          _tasksTable;
    CPMutableArray       _tasksData;
    
    CPTableView          _timeToEventTableView;
    CPTextField          _tteSummaryLabel;
    CPArray              _timeToEventResults;
    
    BOOL                 deepModeEnabled     @accessors(property=deepModeEnabled);
    CPCheckBox           _deepModeSwitch;
    
    // Feasibility Chat Outlets
    CPTableView         _chatPatientsTableView;
    CPTextField         _chatTagTextField;
    CPButton            _chatSendButton;
    CPTextField         _chatCohortCountLabel;
    CPMutableArray      _chatFoundPatients;
    CPTextView          _chatInputTextView;
    CPTextView          _chatSqlTextView;
    CPTextField         _chatStatusLabel;
    CPString            _chatSessionId;

    CPPopover           _chatPseudonymsPopover;
    CPTextView          _chatPseudonymsTextView;
}

- (void)applicationDidFinishLaunching:(CPNotification)aNotification
{
    store = [[SessionStore alloc] initWithBaseURL:HostURL + @"/BBB"];
    _ruleDelegate = [[FHIRRuleDelegate alloc] initWithController:self];

    // patientMatchesController VOR gui.gsmarkup erzeugen
    patientMatchesController = [[CPArrayController alloc] init];
    [patientMatchesController setAvoidsEmptySelection:NO];
    [patientMatchesController setClearsFilterPredicateOnInsertion:NO];

    [CPBundle loadRessourceNamed:@"model.gsmarkup" owner:self];
    [CPBundle loadRessourceNamed:@"gui.gsmarkup" owner:self];

    // patientMatchesController an matchesController anbinden
    [patientMatchesController bind:@"contentArray" toObject:matchesController withKeyPath:@"contentArray" options:nil];

    _isImportingJSON = NO;
    _rootNodes = [];
    _phenoVisualItems = [];
    _crossmatchResults = [];
    _patientCrossmatchResults = [];
    _currentPickerType = @"HPO";

    candidateFilterString = @"";
    studyMatchFilterString = @"";
    patientMatchFilterString = @"";

    _fhirJsonStr = @"";

    [_ruleEditor bind:@"rows" toObject:self withKeyPath:@"rootNodes" options:nil];

    [_phenoVisualTableView setDataSource:self];
    [downstreamTableView setDataSource:self];

    [_searchStatusLabel setFont:[CPFont systemFontOfSize:10.0]];
    [_searchStatusLabel setTextColor:[CPColor grayColor]];
    [_searchStatusLabel setAlignment:CPCenterTextAlignment];

    treeController = [[CPTreeController alloc] init];
    [treeController setChildrenKeyPath:@"children"];
    [treeController setLeafKeyPath:@"isLeaf"];

    [trialsController addObserver:self forKeyPath:@"selection" options:CPKeyValueObservingOptionNew context:nil];
    [candidatesController addObserver:self forKeyPath:@"selection" options:CPKeyValueObservingOptionNew context:nil];

    [outlineView bind:@"content" toObject:treeController withKeyPath:@"arrangedObjects" options:nil];
    [outlineView bind:@"selectionIndexPaths" toObject:treeController withKeyPath:@"selectionIndexPaths" options:nil];

    [[CPNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ruleEditorDidChange:)
                                                 name:CPRuleEditorRowsDidChangeNotification
                                               object:_ruleEditor];

    [mainWindow orderFront:self];
    [self fetchRoots];
    [trialsController willChangeValueForKey:"selection"];
    [trialsController didChangeValueForKey:"selection"];

    [candidatesController willChangeValueForKey:"selection"];
    [candidatesController didChangeValueForKey:"selection"];

    [self setSelectedModel:"gpt-oss-120b"];
    [self setDeepModeEnabled:NO]; // Standard: Deep Mode inaktiv

    [_phenoVisualTableView setDataSource:self];
    [downstreamTableView setDataSource:self];

    [_crossmatchTableView setDataSource:self];
    [_crossmatchTableView setDelegate:self];

    [_patientCrossmatchTableView setDataSource:self];
    [_patientCrossmatchTableView setDelegate:self];

    [synonymsTableView setDataSource:self];
    [xrefsTableView setDataSource:self];

    _timeToEventResults = [];
    [_timeToEventTableView setDataSource:self];
    [_timeToEventTableView setDelegate:self];

    [matchesController addObserver:self forKeyPath:@"selection" options:CPKeyValueObservingOptionNew context:nil];
    [patientMatchesController addObserver:self forKeyPath:@"selection" options:CPKeyValueObservingOptionNew context:nil];
    
    
    if (_chatSqlTextView) {
        [_chatSqlTextView setFont:[CPFont fontWithName:@"Courier" size:11.0]];
        [_chatSqlTextView setTextColor:[CPColor colorWithCalibratedRed:0.1 green:0.2 blue:0.5 alpha:1.0]];
        [_chatSqlTextView setString:@"-- Noch kein SQL-Code ausgeführt."];
    }
    
    if (_chatInputTextView) {
        [_chatInputTextView setString:@"Bitte suche die Patienten mit Epitheldefekt bei neurotropher Keratopathie aber ohne perforierende Keratoplastik."];
    }
    
    _chatFoundPatients = [CPMutableArray array];
    [_chatPatientsTableView setDataSource:self];
    [_chatPatientsTableView setDelegate:self];
    [_chatPatientsTableView setTarget:self];
    [_chatPatientsTableView setDoubleAction:@selector(doubleClickChatPatient:)];
    
    [self initializeChatSession:nil];
    
    [self connectWebSocket];
}

- (void)showAnonymizedExportAction:(id)sender
{
    var tools = [ToolsController sharedController];
    [tools setAppController:self];
    [tools showAnonymizedExport:sender];
}

- (void)showPropensityMatchingAction:(id)sender
{
    var tools = [ToolsController sharedController];
    [tools setAppController:self];
    [tools showPropensityMatching:sender];
}

- (void)doubleClickChatPatient:(id)sender
{
    var clickedRow = [_chatPatientsTableView clickedRow];
    if (clickedRow < 0 || clickedRow >= [_chatFoundPatients count])
        return;

    var pseudonymOrId = [_chatFoundPatients objectAtIndex:clickedRow];
    if (!pseudonymOrId)
        return;

    // 1. Auf den ersten Tab "Candidates" umschalten (Index 0)
    if (mainWorkspaceTab)
    {
        [mainWorkspaceTab selectTabViewItemAtIndex:0];
    }

    // 2. Filter-Feld setzen
    [self setCandidateFilterString:pseudonymOrId];

    // 3. Gezielt nachladen (falls nicht in den initialen 1.000 enthalten) und selektieren
    [self loadAndSelectCandidate:pseudonymOrId];
}

- (void)loadAndSelectCandidate:(CPString)aTarget
{
    if (!aTarget || [aTarget length] === 0)
        return;

    // A. Prüfen, ob der Patient bereits im Speicher vorhanden ist
    var arranged = [candidatesController arrangedObjects];
    for (var i = 0; i < [arranged count]; i++)
    {
        var cand = [arranged objectAtIndex:i];
        if ([[cand valueForKey:@"pseudonym"] isEqualToString:aTarget] || String([cand valueForKey:@"id"]) === String(aTarget))
        {
            [candidatesController setSelectionIndex:i];
            return;
        }
    }

    // B. Wenn noch nicht im Speicher: Direkt per REST vom Server holen
    var urlString = @"/BBB/candidates/search/" + encodeURIComponent(aTarget);
    var request = [CPURLRequest requestWithURL:urlString];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
    {
        if (!error && data)
        {
            try {
                var items = JSON.parse(data);
                if (items && items.length > 0)
                {
                    var entity = [candidatesController entity];
                    var contentArr = [candidatesController content];
                    var internalArr = [contentArr respondsToSelector:@selector(_representedObject)]
                                      ? [contentArr _representedObject]
                                      : contentArr;

                    for (var i = 0; i < items.length; i++)
                    {
                        var obj = [store _processJSON:items[i] forEntity:entity];
                        if (internalArr.indexOf(obj) === -1)
                        {
                            internalArr.push(obj);
                        }
                    }

                    [candidatesController rearrangeObjects];

                    var newArranged = [candidatesController arrangedObjects];
                    for (var j = 0; j < [newArranged count]; j++)
                    {
                        var cObj = [newArranged objectAtIndex:j];
                        if ([[cObj valueForKey:@"pseudonym"] isEqualToString:aTarget] || String([cObj valueForKey:@"id"]) === String(aTarget))
                        {
                            [candidatesController setSelectionIndex:j];
                            return;
                        }
                    }
                    if ([newArranged count] > 0)
                    {
                        [candidatesController setSelectionIndex:0];
                    }
                }
            } catch(e) {
                console.error("Fehler beim Laden des Zielkandidaten: ", e);
            }
        }
    }];
}

// ================================================================================
// FEASIBILITY CHAT ASSISTANT (STATELESS & OHNE PROMPT-LÖSCHUNG)
// ================================================================================

- (void)initializeChatSession:(id)sender
{
    [_chatStatusLabel setStringValue:@"Bereit für Kohorten-Abfragen."];
    [_chatFoundPatients removeAllObjects];
    [_chatPatientsTableView reloadData];
    [_chatCohortCountLabel setStringValue:@"0 Patienten"];
    [_chatTagTextField setStringValue:@""];
    
    if (_chatSqlTextView) {
        [_chatSqlTextView setEditable:YES];
        [_chatSqlTextView setFont:[CPFont fontWithName:@"Courier" size:11.0]];
        [_chatSqlTextView setString:@"-- Noch kein SQL-Code erzeugt --"];
    }

    // Default-Prompt vorlegen, falls das Feld leer ist
    var defaultPrompt = @"Bitte suche die Patienten mit Epitheldefekt bei neurotropher Keratopathie aber  ohne perforierender Keratoplastik.";
    if (_chatInputTextView) {
        var currentText = [[_chatInputTextView string] stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!currentText || [currentText length] === 0) {
            [_chatInputTextView setString:defaultPrompt];
        }
    }
}

- (void)sendChatQueryAction:(id)sender
{
    var userPrompt = [[_chatInputTextView string] stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!userPrompt || [userPrompt length] === 0) return;
    
    // 1. Sofort "Generating Query..." im SQL-Feld einblenden
    [_chatSqlTextView setString:@"-- Generating Query..."];
    [_chatStatusLabel setStringValue:@"Generating Query..."];
    [_chatSendButton setEnabled:NO];
    
    var request = [CPURLRequest requestWithURL:@"/BBB/chat/query" cachePolicy:CPURLRequestUseProtocolCachePolicy timeoutInterval:300.0];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    var payload = {
        "prompt": userPrompt,
        "model": selectedModel
    };
    [request setHTTPBody:JSON.stringify(payload)];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
    {
        [_chatSendButton setEnabled:YES];

        if (!error && data) {
            try {
                var res = typeof data === "string" ? JSON.parse(data) : data;
                if (res.success)
                {
                    var sqlOutput = res.sql || @"-- Kein SQL-Code generiert.";

                    // Datenbank-Fehlermeldung direkt im SQL-Feld anhängen
                    if (res.db_error && [res.db_error length] > 0) {
                        sqlOutput += @"\n\n/* ⚠️ DATENBANK-FEHLER:\n" + res.db_error + @"\n*/";
                    }
                    [_chatSqlTextView setString:sqlOutput];

                    // Gefundene Patienten in Tabelle anzeigen
                    var patientIds = res.patient_ids || [];
                    _chatFoundPatients = [CPMutableArray arrayWithArray:patientIds];
                    [_chatPatientsTableView reloadData];
                    [_chatCohortCountLabel setStringValue:[CPString stringWithFormat:@"%d Patient(en)", [_chatFoundPatients count]]];

                    if (res.db_error) {
                        [_chatStatusLabel setStringValue:@"SQL mit Datenbank-Fehler ausgeführt (siehe Feld)."];
                    } else {
                        [_chatStatusLabel setStringValue:[CPString stringWithFormat:@"Fertig: %d Patient(en) ermittelt.", [_chatFoundPatients count]]];
                    }
                } else {
                    var errMsg = res.error || @"Unbekannter Fehler";
                    [_chatSqlTextView setString:@"/* ⚠️ FEHLER BEI DER GENERIERUNG:\n" + errMsg + @"\n*/"];
                    [_chatStatusLabel setStringValue:@"Fehler: " + errMsg];
                }
            } catch(e) {
                console.error("Chat Query Error:", e);
                [_chatSqlTextView setString:@"/* ⚠️ VERARBEITUNGSFEHLER:\n" + e.message + @"\n*/"];
                [_chatStatusLabel setStringValue:@"Fehler beim Verarbeiten."];
            }
        } else {
            var msg = error ? [error description] : @"Netzwerkfehler";
            [_chatSqlTextView setString:@"/* ⚠️ VERBINDUNGSFEHLER:\n" + msg + @"\n*/"];
            [_chatStatusLabel setStringValue:@"Netzwerkfehler beim Chat."];
        }
    }];
}

- (void)runManualSqlAction:(id)sender
{
    var sql = [[_chatSqlTextView string] stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!sql || [sql length] === 0) {
        alert("Kein SQL-Code zum Ausführen vorhanden.");
        return;
    }

    // Vorherige Fehlerkommentare aus dem SQL-String entfernen, bevor neu ausgeführt wird
    var cleanedSql = sql.replace(/\/\* ⚠️ DATENBANK-FEHLER:[\s\S]*?\*\//g, "").trim();
    [_chatSqlTextView setString:cleanedSql];

    [_chatStatusLabel setStringValue:@"Führe SQL manuell aus..."];
    [sender setEnabled:NO];

    var request = [CPURLRequest requestWithURL:@"/BBB/chat/execute_sql"];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:JSON.stringify({ "sql": cleanedSql })];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
    {
        [sender setEnabled:YES];
        if (!error && data) {
            try {
                var res = typeof data === "string" ? JSON.parse(data) : data;
                if (res.success) {
                    var patientIds = res.patient_ids || [];
                    _chatFoundPatients = [CPMutableArray arrayWithArray:patientIds];
                    [_chatPatientsTableView reloadData];

                    var count = (res.patient_count !== undefined) ? res.patient_count : [_chatFoundPatients count];
                    [_chatCohortCountLabel setStringValue:[CPString stringWithFormat:@"%d Patient(en)", count]];
                    [_chatStatusLabel setStringValue:[CPString stringWithFormat:@"SQL ausgeführt: %d Patient(en) ermittelt.", count]];
                } else {
                    var err = res.error || "SQL-Fehler";
                    // Fehlermeldung direkt lesbar in das SQL-Textfeld einfügen
                    [_chatSqlTextView setString:cleanedSql + @"\n\n/* ⚠️ DATENBANK-FEHLER:\n" + err + @"\n*/"];
                    [_chatStatusLabel setStringValue:@"SQL-Fehler (siehe unten im Textfeld)."];
                }
            } catch(e) {
                [_chatSqlTextView setString:cleanedSql + @"\n\n/* ⚠️ ANTWORT-PARSING-FEHLER:\n" + e.message + @"\n*/"];
                [_chatStatusLabel setStringValue:@"Fehler beim Verarbeiten der Antwort."];
            }
        } else {
            var msg = error ? [error description] : @"Netzwerkfehler";
            [_chatSqlTextView setString:cleanedSql + @"\n\n/* ⚠️ VERBINDUNGSFEHLER:\n" + msg + @"\n*/"];
            [_chatStatusLabel setStringValue:@"Netzwerkfehler bei der SQL-Ausführung."];
        }
    }];
}

- (void)tagChatCohortAction:(id)sender
{
    if (!_chatFoundPatients || [_chatFoundPatients count] === 0)
    {
        alert("Keine Patienten in der Kohorten-Tabelle vorhanden.");
        return;
    }

    var tag = [[_chatTagTextField stringValue] stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!tag || [tag length] === 0)
    {
        alert("Bitte geben Sie einen Tag-Namen in das Textfeld ein.");
        return;
    }

    [sender setEnabled:NO];
    [sender setTitle:@"Speichere..."];

    var request = [CPURLRequest requestWithURL:@"/BBB/candidates/batch_tag"];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var payload = {
        "tag": tag,
        "pseudonyms": _chatFoundPatients,
        "append": 1
    };
    [request setHTTPBody:JSON.stringify(payload)];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [sender setEnabled:YES];
        [sender setTitle:@"Kohorte taggen"];

        if (!error && data)
        {
            try {
                var res = JSON.parse(data);
                alert("Erfolgreich: " + (res.updated || 0) + " Patient(en) mit Tag '" + tag + "' versehen.");

                // Kandidatenliste im Hauptfenster aktualisieren
                candidatesController._entity._refreshCachedObjects = YES;
                [candidatesController setContent:[candidatesController._entity allObjects]];
                candidatesController._entity._refreshCachedObjects = NO;
                [self updateCandidateFilter];
            } catch(e) {
                alert("Fehler beim Verarbeiten der Serverantwort: " + e.message);
            }
        }
        else
        {
            var msg = error ? [error description] : "Verbindungsfehler";
            alert("Fehler beim Setzen der Tags: " + msg);
        }
     }];
}
- (void)connectWebSocket
{
    var socketUrl = (window.location.protocol === "https:" ? "wss://" : "ws://") + window.location.host + "/BBB/socket";
    var ws = new WebSocket(socketUrl);
    
    ws.onmessage = function(event) {
        try {
            var payload = JSON.parse(event.data);
            
            if (payload && payload.type === "TASK_PROGRESS") {
                var state = @"active";
                if (payload.phase === "finished") state = @"finished";
                if (payload.phase === "failed")   state = @"failed";
                
                [self updateTaskWithIdentifier:payload.task_id
                                         state:state
                                       message:payload.message
                                      progress:payload.progress];
            }
        } catch(e) {
        }
    };
    
    ws.onclose = function() {
        setTimeout(function() { [self connectWebSocket]; }, 5000);
    };
}

- (void)initTasksPanel
{
    _tasksPanel = [[CPPanel alloc] initWithContentRect:CGRectMake(400, 800, 500, 220)
                                             styleMask:CPHUDBackgroundWindowMask | CPClosableWindowMask | CPResizableWindowMask | CPTitledWindowMask];
    [_tasksPanel setTitle:@"OntoTrial Hintergrundprozesse"];
    [_tasksPanel setFloatingPanel:YES];

    var contentView = [_tasksPanel contentView];

    var scrollView = [[CPScrollView alloc] initWithFrame:CGRectInset([contentView bounds], 10, 10)];
    [scrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    _tasksTable = [[NoCibTableView alloc] initWithFrame:[scrollView bounds]];
    [_tasksTable setDataSource:self];
    [_tasksTable setDelegate:self];
    [_tasksTable setUsesAlternatingRowBackgroundColors:YES];
    [_tasksTable setRowHeight:28.0];

    var col1 = [[CPTableColumn alloc] initWithIdentifier:@"name"];
    [[col1 headerView] setStringValue:@"Prozess / Aufgabe"];
    [col1 setWidth:180.0];
    [_tasksTable addTableColumn:col1];

    var col2 = [[CPTableColumn alloc] initWithIdentifier:@"status"];
    [[col2 headerView] setStringValue:@"Fortschritt & Status"];
    [col2 setWidth:280.0];
    [_tasksTable addTableColumn:col2];

    [scrollView setDocumentView:_tasksTable];
    [contentView addSubview:scrollView];
}

- (void)addTaskWithName:(CPString)aName identifier:(CPString)anID
{
    if (!_tasksPanel) {
        [self initTasksPanel];
    }
    
    if (!_tasksData) {
        _tasksData = [CPMutableArray array];
    }
    
    for (var i = 0; i < [_tasksData count]; i++) {
        if ([_tasksData[i].identifier isEqualToString:anID]) {
            [_tasksData removeObjectAtIndex:i];
            break;
        }
    }
    
    var task = {
        "name": aName,
        "identifier": anID,
        "state": @"active",
        "message": @"Wird ausgeführt...",
        "progress": 25
    };
    
    [_tasksData insertObject:task atIndex:0];
    [_tasksTable reloadData];
    
    if (![_tasksPanel isVisible]) {
        [_tasksPanel makeKeyAndOrderFront:self];
    }
}

- (void)removeTaskWithIdentifier:(CPString)anID
{
    if (!_tasksData) return;
    
    for (var i = 0; i < [_tasksData count]; i++) {
        var task = _tasksData[i];
        if ([task.identifier isEqualToString:anID]) {
            [_tasksData removeObjectAtIndex:i];
            [_tasksTable reloadData];
            break;
        }
    }
}

- (void)updateTaskWithIdentifier:(CPString)anID state:(CPString)aState message:(CPString)aMessage progress:(float)aProgress
{
    if (!_tasksData) return;
    
    for (var i = 0; i < [_tasksData count]; i++) {
        var task = _tasksData[i];
        if ([task.identifier isEqualToString:anID]) {
            task.state = aState;
            task.message = aMessage;
            task.progress = aProgress;
            [_tasksTable reloadData];
            
            if ([aState isEqualToString:@"finished"] || [aState isEqualToString:@"failed"]) {
                [self performSelector:@selector(removeTaskWithIdentifier:)
                           withObject:anID
                           afterDelay:1.0];
            }
            break;
        }
    }
}

- (void)observeValueForKeyPath:(CPString)keyPath ofObject:(id)object change:(CPDictionary)change context:(void)context
{
    if (object === trialsController && [keyPath isEqualToString:@"selection"])
    {
        [self updateMatchesFilter];

        var selectedTrial = [trialsController selection];

        if (selectedTrial && ![selectedTrial isMemberOfClass:[CPNull class]])
        {
            var fhirJsonStr = [selectedTrial valueForKey:@"fhir_group_json"] || @"";
            
            _fhirJsonString = fhirJsonStr;

            if (fhirJsonStr && [fhirJsonStr length] > 0)
            {
                try {
                    var parsed = JSON.parse(fhirJsonStr);
                    _isImportingJSON = YES;
                    [self importFHIRGroup:parsed];
                    _isImportingJSON = NO;
                } catch(e) {
                    [self resetEditor:self];
                }
            }
            else
            {
                [self resetEditor:self];
            }
        }
        else
        {
            [self resetEditor:self];
        }
    }
    else if (object === candidatesController && [keyPath isEqualToString:@"selection"])
    {
        [self updatePatientMatchesFilter];

        var selectedCandidate = [candidatesController selection];
        if (selectedCandidate && ![selectedCandidate isMemberOfClass:[CPNull class]])
        {
            var phenoJsonStr = [selectedCandidate valueForKey:@"phenopacket_json"];
            if (phenoJsonStr && [phenoJsonStr length] > 0)
            {
                [_phenopacketOutputTextView setString:phenoJsonStr];
                [self parseActivePhenopacketToVisualItems];
            }
            else
            {
                [_phenopacketOutputTextView setString:@""];
                [self parseActivePhenopacketToVisualItems];
            }
        }
        else
        {
            [_phenopacketOutputTextView setString:@""];
            [self parseActivePhenopacketToVisualItems];
        }
    }
    else if (object === matchesController && [keyPath isEqualToString:@"content"])
    {
        [patientMatchesController setContent:[matchesController content]];
        [self updatePatientMatchesFilter];
    }
    else if (object === matchesController && [keyPath isEqualToString:@"selection"])
    {
        var selectedMatch = [matchesController selection];
        [self updateCrossmatchDetailWithMatch:selectedMatch
                                        table:_crossmatchTableView
                                         view:_narrativeTextView
                                resultsTarget:@"_crossmatchResults"];
    }
    else if (object === patientMatchesController && [keyPath isEqualToString:@"selection"])
    {
        var selectedMatch = [patientMatchesController selection];
        [self updateCrossmatchDetailWithMatch:selectedMatch
                                        table:_patientCrossmatchTableView
                                         view:_patientNarrativeTextView
                                resultsTarget:@"_patientCrossmatchResults"];
    }
}

- (void)setCandidateFilterString:(CPString)aString
{
    [self willChangeValueForKey:@"candidateFilterString"];
    candidateFilterString = aString || @"";
    [self didChangeValueForKey:@"candidateFilterString"];

    [self updateCandidateFilter];
}

- (void)candidateSearchFieldChanged:(id)sender
{
    [self setCandidateFilterString:[sender stringValue]];
}

- (void)updateCandidateFilter
{
    var cleanText = candidateFilterString ? [candidateFilterString stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    if ([cleanText length] > 0)
    {
        // 1. Sofort lokaler Predicate-Filter für bereits geladene Datensätze (kein UI-Lag)
        var predicate = [CPPredicate predicateWithFormat:@"pseudonym CONTAINS[cd] %@ OR tags CONTAINS[cd] %@ OR id = %@", cleanText, cleanText, cleanText];
        [candidatesController setFilterPredicate:predicate];

        // 2. Debounced Server-Suche in PostgreSQL (wartet 300ms nach dem Tippen)
        [CPObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(executeServerCandidateSearch:) object:nil];
        [self performSelector:@selector(executeServerCandidateSearch:) withObject:cleanText afterDelay:0.3];
    }
    else
    {
        [CPObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(executeServerCandidateSearch:) object:nil];
        [candidatesController setFilterPredicate:nil];
    }
}

- (void)executeServerCandidateSearch:(CPString)query
{
    if (!query || [query length] === 0)
        return;

    var urlString = @"/BBB/candidates/search/" + encodeURIComponent(query);
    var request = [CPURLRequest requestWithURL:urlString];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
    {
        if (!error && data)
        {
            try {
                var items = JSON.parse(data);
                if (items && items.length > 0)
                {
                    var entity = [candidatesController entity];
                    var contentArr = [candidatesController content];
                    
                    // Sicher auf das interne Array zugreifen, um _addToDBObject (POST/INSERT) zu umgehen
                    var internalArr = [contentArr respondsToSelector:@selector(_representedObject)]
                                      ? [contentArr _representedObject]
                                      : contentArr;
                    var addedAny = NO;

                    for (var i = 0; i < items.length; i++)
                    {
                        var obj = [store _processJSON:items[i] forEntity:entity];
                        if (internalArr.indexOf(obj) === -1)
                        {
                            internalArr.push(obj);
                            addedAny = YES;
                        }
                    }

                    if (addedAny)
                    {
                        [candidatesController rearrangeObjects];
                    }
                }
            } catch(e) {
                console.error("Fehler beim Verarbeiten der Server-Kandidatensuche: ", e);
            }
        }
    }];
}

- (void)setStudyMatchFilterString:(CPString)aString
{
    [self willChangeValueForKey:@"studyMatchFilterString"];
    studyMatchFilterString = aString || @"";
    [self didChangeValueForKey:@"studyMatchFilterString"];

    [self updateMatchesFilter];
}

- (void)studyMatchSearchFieldChanged:(id)sender
{
    [self setStudyMatchFilterString:[sender stringValue]];
}

- (void)setPatientMatchFilterString:(CPString)aString
{
    [self willChangeValueForKey:@"patientMatchFilterString"];
    patientMatchFilterString = aString || @"";
    [self didChangeValueForKey:@"patientMatchFilterString"];

    [self updatePatientMatchesFilter];
}

- (void)patientMatchSearchFieldChanged:(id)sender
{
    [self setPatientMatchFilterString:[sender stringValue]];
}

- (void)updateMatchesFilter
{
    var selectedTrial = [trialsController selection];
    if (!selectedTrial || [selectedTrial isMemberOfClass:[CPNull class]])
    {
        [matchesController setFilterPredicate:[CPPredicate predicateWithValue:NO]];
        return;
    }

    var trialId = [selectedTrial valueForKey:@"id"];
    if (trialId === undefined || trialId === null)
    {
        [matchesController setFilterPredicate:[CPPredicate predicateWithValue:NO]];
        return;
    }

    var cleanText = studyMatchFilterString ? [studyMatchFilterString stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    if ([cleanText length] > 0)
    {
        var predicate = [CPPredicate predicateWithFormat:@"trial_id = %@ AND (candidate_pseudonym CONTAINS[cd] %@ OR status_text CONTAINS[cd] %@)", trialId, cleanText, cleanText];
        [matchesController setFilterPredicate:predicate];
    }
    else
    {
        var predicate = [CPPredicate predicateWithFormat:@"trial_id = %@", trialId];
        [matchesController setFilterPredicate:predicate];
    }
}

- (void)updatePatientMatchesFilter
{
    var selectedCandidate = [candidatesController selection];
    if (!selectedCandidate || [selectedCandidate isMemberOfClass:[CPNull class]])
    {
        [patientMatchesController setFilterPredicate:[CPPredicate predicateWithValue:NO]];
        return;
    }

    var candidateId = [selectedCandidate valueForKey:@"id"];
    if (candidateId === undefined || candidateId === null)
    {
        [patientMatchesController setFilterPredicate:[CPPredicate predicateWithValue:NO]];
        return;
    }

    var cleanText = patientMatchFilterString ? [patientMatchFilterString stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    if ([cleanText length] > 0)
    {
        var predicate = [CPPredicate predicateWithFormat:@"candidate_id = %@ AND (trial_name CONTAINS[cd] %@ OR status_text CONTAINS[cd] %@)", candidateId, cleanText, cleanText];
        [patientMatchesController setFilterPredicate:predicate];
    }
    else
    {
        var predicate = [CPPredicate predicateWithFormat:@"candidate_id = %@", candidateId];
        [patientMatchesController setFilterPredicate:predicate];
    }
}

- (void)showTaggingWindowAction:(id)sender
{
    if (!_taggingWindow)
    {
        _taggingWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(200, 200, 480, 400)
                                                     styleMask:CPTitledWindowMask | CPClosableWindowMask];
        [_taggingWindow setTitle:@"Kandidaten-Tagging (Batch)"];

        var contentView = [_taggingWindow contentView];

        var lbl1 = [[CPTextField alloc] initWithFrame:CGRectMake(20, 15, 440, 20)];
        [lbl1 setStringValue:@"Pseudonyme / PIZs (Komma-, Leerzeichen- oder Zeilen-getrennt):"];
        [lbl1 setFont:[CPFont boldSystemFontOfSize:11.0]];
        [contentView addSubview:lbl1];

        var scroll = [[CPScrollView alloc] initWithFrame:CGRectMake(20, 40, 440, 180)];
        [scroll setHasHorizontalScroller:NO];
        [scroll setHasVerticalScroller:YES];
        [scroll setAutohidesScrollers:YES];

        _taggingPseudonymsTextView = [[CPTextView alloc] initWithFrame:[scroll bounds]];
        [_taggingPseudonymsTextView setAutoresizingMask:CPViewWidthSizable];
        [_taggingPseudonymsTextView setEditable:YES];
        [_taggingPseudonymsTextView setFont:[CPFont fontWithName:@"Courier" size:11.0]];
        [scroll setDocumentView:_taggingPseudonymsTextView];
        [contentView addSubview:scroll];

        var lbl2 = [[CPTextField alloc] initWithFrame:CGRectMake(20, 230, 440, 20)];
        [lbl2 setStringValue:@"Tag-Name (z. B. Kohorte_A, Glaukom_Studie):"];
        [lbl2 setFont:[CPFont boldSystemFontOfSize:11.0]];
        [contentView addSubview:lbl2];

        _taggingTagTextField = [[CPTextField alloc] initWithFrame:CGRectMake(20, 255, 440, 26)];
        [_taggingTagTextField setEditable:YES];
        [_taggingTagTextField setBezeled:YES];
        [_taggingTagTextField setPlaceholderString:@"Name des Tags eingeben..."];
        [contentView addSubview:_taggingTagTextField];

        _taggingAppendCheckBox = [[CPCheckBox alloc] initWithFrame:CGRectMake(20, 290, 440, 20)];
        [_taggingAppendCheckBox setTitle:@"Bestehende Tags beibehalten (Tag anhängen)"];
        [_taggingAppendCheckBox setState:CPOnState];
        [contentView addSubview:_taggingAppendCheckBox];

        var btnCancel = [[CPButton alloc] initWithFrame:CGRectMake(260, 335, 90, 26)];
        [btnCancel setTitle:@"Abbrechen"];
        [btnCancel setTarget:self];
        [btnCancel setAction:@selector(closeTaggingWindowAction:)];
        [contentView addSubview:btnCancel];

        var btnCommit = [[CPButton alloc] initWithFrame:CGRectMake(360, 335, 100, 26)];
        [btnCommit setTitle:@"Tag setzen"];
        [btnCommit setTheme:[CPTheme defaultTheme]];
        [btnCommit setTarget:self];
        [btnCommit setAction:@selector(commitTaggingAction:)];
        [contentView addSubview:btnCommit];
    }

    [_taggingPseudonymsTextView setString:@""];
    [_taggingTagTextField setStringValue:@""];
    [_taggingAppendCheckBox setState:CPOnState];

    [_taggingWindow center];
    [_taggingWindow makeKeyAndOrderFront:self];
}

- (void)closeTaggingWindowAction:(id)sender
{
    if (_taggingWindow)
    {
        [_taggingWindow orderOut:self];
    }
}

- (void)commitTaggingAction:(id)sender
{
    var rawText = [[_taggingPseudonymsTextView string] stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]];
    var tag = [[_taggingTagTextField stringValue] stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]];

    if (!tag || [tag length] === 0)
    {
        alert("Bitte geben Sie einen Tag-Namen ein.");
        return;
    }

    if (!rawText || [rawText length] === 0)
    {
        alert("Bitte fügen Sie mindestens ein Pseudonym ein.");
        return;
    }

    var tokens = rawText.split(/[\s,;]+/);
    var pseudonyms = [];
    var seen = {};

    for (var i = 0; i < tokens.length; i++)
    {
        var p = tokens[i].trim();
        if (p.length > 0 && !seen[p])
        {
            seen[p] = true;
            pseudonyms.push(p);
        }
    }

    if (pseudonyms.length === 0)
    {
        alert("Keine gültigen Pseudonyme gefunden.");
        return;
    }

    var isAppend = ([_taggingAppendCheckBox state] === CPOnState);

    [sender setEnabled:NO];
    [sender setTitle:@"Speichere..."];

    var request = [CPURLRequest requestWithURL:"/BBB/candidates/batch_tag"];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var payload = {
        "tag": tag,
        "pseudonyms": pseudonyms,
        "append": isAppend ? 1 : 0
    };

    [request setHTTPBody:JSON.stringify(payload)];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [sender setEnabled:YES];
        [sender setTitle:@"Tag setzen"];

        if (!error && data)
        {
            try {
                var res = JSON.parse(data);
                alert("Erfolgreich: " + (res.updated || 0) + " Kandidat(en) mit Tag '" + tag + "' versehen.");

                // Kandidatendaten neu laden
                candidatesController._entity._refreshCachedObjects = YES;
                [candidatesController setContent:[candidatesController._entity allObjects]];
                candidatesController._entity._refreshCachedObjects = NO;

                [self updateCandidateFilter];
                [self closeTaggingWindowAction:nil];
            } catch(e) {
                alert("Fehler beim Verarbeiten der Serverantwort: " + e.message);
            }
        }
        else
        {
            var msg = error ? [error description] : "Verbindungsfehler";
            alert("Fehler beim Setzen der Tags: " + msg);
        }
     }];
}

- (void)matchTagAgainstTrialsAction:(id)sender
{
    var tag = prompt("Geben Sie das Tag ein, dessen Patienten gematcht werden sollen:", "");
    if (!tag) return;

    tag = tag.trim();
    if (tag.length === 0) return;

    // 1. Suche bei Candidates auf dieses Tag setzen
    [self setCandidateFilterString:tag];

    // 2. Tab auf Matching wechseln
    if (mainWorkspaceTab) {
        [mainWorkspaceTab selectTabViewItemAtIndex:2];
    }
    if (_matchingSubTabView) {
        [_matchingSubTabView selectTabViewItemAtIndex:0]; // Per Study
    }

    [self addTaskWithName:@"Tag-Matching: " + tag identifier:@"tag_matching_" + tag];
    [self updateTaskWithIdentifier:@"tag_matching_" + tag state:@"active" message:@"Matche Kohorte..." progress:25];

    var request = [CPURLRequest requestWithURL:"/BBB/run_all_matches"
                                   cachePolicy:CPURLRequestUseProtocolCachePolicy
                               timeoutInterval:1800.0];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var payload = {
        "tag": tag,
        "task_id": "tag_matching_" + tag
    };
    [request setHTTPBody:JSON.stringify(payload)];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        if (!error && data) {
            try {
                [self updateTaskWithIdentifier:@"tag_matching_" + tag state:@"finished" message:@"Abgeschlossen" progress:100];

                matchesController._entity._refreshCachedObjects = YES;
                var allObjs = [matchesController._entity allObjects];
                [matchesController setContent:allObjs];
                matchesController._entity._refreshCachedObjects = NO;

                [patientMatchesController setContent:allObjs];
                [self updateMatchesFilter];
                [self updatePatientMatchesFilter];

                alert("Matching für Tag '" + tag + "' erfolgreich abgeschlossen.");
            } catch (e) {
                [self updateTaskWithIdentifier:@"tag_matching_" + tag state:@"failed" message:@"Verarbeitungsfehler" progress:0];
            }
        } else {
            [self updateTaskWithIdentifier:@"tag_matching_" + tag state:@"failed" message:@"Verbindungsfehler" progress:0];
            alert("Fehler beim Tag-Matching.");
        }
     }];
}
- (void)runPatientMatchingAction:(id)sender
{
    var selectedTrial = [trialsController selection];
    if (!selectedTrial || [selectedTrial isMemberOfClass:[CPNull class]]) {
        alert("Bitte wählen Sie zuerst links in der Tabelle eine Studie aus.");
        return;
    }

    var trialId = [selectedTrial valueForKey:@"id"];
    var trialName = [selectedTrial valueForKey:@"name"] || ("ID " + trialId);

    [sender setEnabled:NO];
    [sender setTitle:@"Matching..."];

    [self addTaskWithName:@"Matching: " + trialName identifier:@"patient_matching"];
    [self updateTaskWithIdentifier:@"patient_matching" state:@"active" message:@"Gezielter Abgleich läuft..." progress:20];

    var request = [CPURLRequest requestWithURL:"/BBB/run_all_matches"
                                   cachePolicy:CPURLRequestUseProtocolCachePolicy
                               timeoutInterval:1800.0];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var payload = {
        "trial_id": trialId,
        "task_id": @"patient_matching"
    };
    var postData = [CPString stringWithString:JSON.stringify(payload)];
    [request setHTTPBody:postData];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [sender setEnabled:YES];
        [sender setTitle:@"Run Matching for Selected Trial"];

        if (!error && data) {
            try {
                [self updateTaskWithIdentifier:@"patient_matching" state:@"finished" message:@"Erfolgreich" progress:100];
                
                matchesController._entity._refreshCachedObjects = YES;
                var allObjs = [matchesController._entity allObjects];
                [matchesController setContent:allObjs];
                matchesController._entity._refreshCachedObjects = NO;

                [patientMatchesController setContent:allObjs];
                [self updateMatchesFilter];
                [self updatePatientMatchesFilter];

            } catch (e) {
                alert("Fehler beim Verarbeiten der Antwort: " + e.message);
                [self updateTaskWithIdentifier:@"patient_matching" state:@"failed" message:@"Verarbeitungsfehler" progress:0];
            }
        } else {
            var errorMsg = (error) ? [error description] : @"Verbindung zum Matching-Service fehlgeschlagen.";
            [self updateTaskWithIdentifier:@"patient_matching" state:@"failed" message:@"Verbindungsfehler" progress:0];
            alert("Matching-Fehler:\n" + errorMsg);
        }
     }];
}

- (void)calculateTimeToEventAction:(id)sender
{
    var selectedTrial = [trialsController selection];
    if (!selectedTrial || [selectedTrial isMemberOfClass:[CPNull class]]) {
        alert("Bitte wählen Sie zuerst links eine Studie aus.");
        return;
    }

    var trialId = [selectedTrial valueForKey:@"id"];
    var trialName = [selectedTrial valueForKey:@"name"] || ("ID " + trialId);

    [sender setEnabled:NO];
    [sender setTitle:@"Berechne..."];
    [_tteSummaryLabel setStringValue:@"Longitudinale Kohortenanalyse läuft..."];

    [self addTaskWithName:@"Time-to-Eligibility (" + trialName + ")" identifier:@"tte_calc"];
    [self updateTaskWithIdentifier:@"tte_calc" state:@"active" message:@"Analysiere Brief-Verläufe..." progress:30];

    var request = [CPURLRequest requestWithURL:@"/BBB/trials/" + trialId + @"/time_to_eligibility"
                                   cachePolicy:CPURLRequestUseProtocolCachePolicy
                               timeoutInterval:1800.0];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [sender setEnabled:YES];
        [sender setTitle:@"Calculate Time to Eligibility"];

        if (!error && data) {
            try {
                var jsonRes = JSON.parse(data);
                _timeToEventResults = jsonRes.kaplan_meier_data || [];
                [_timeToEventTableView reloadData];

                var summary = "Patienten: " + (jsonRes.total_patients || 0) +
                              " | Events (Einschluss): " + (jsonRes.events_count || 0) +
                              " | Zensiert: " + (jsonRes.censored_count || 0);
                [_tteSummaryLabel setStringValue:summary];

                [self updateTaskWithIdentifier:@"tte_calc" state:@"finished" message:@"Abgeschlossen" progress:100];
            } catch (e) {
                [_tteSummaryLabel setStringValue:@"Fehler beim Parsen der Time-to-Event Daten."];
                [self updateTaskWithIdentifier:@"tte_calc" state:@"failed" message:@"Verarbeitungsfehler" progress:0];
            }
        } else {
            var msg = error ? [error description] : "Verbindungsfehler";
            [_tteSummaryLabel setStringValue:@"Serverfehler: " + msg];
            [self updateTaskWithIdentifier:@"tte_calc" state:@"failed" message:@"Verbindungsfehler" progress:0];
        }
     }];
}

- (void)exportTimeToEventCSVAction:(id)sender
{
    var selectedTrial = [trialsController selection];
    if (!selectedTrial || [selectedTrial isMemberOfClass:[CPNull class]]) {
        alert("Bitte wählen Sie zuerst links eine Studie aus.");
        return;
    }

    var trialId = [selectedTrial valueForKey:@"id"];
    var downloadUrl = "/BBB/trials/" + trialId + "/time_to_eligibility.csv";
    
    window.open(downloadUrl, "_blank");
}

- (void)matchCandidateAgainstTrialsAction:(id)sender
{
    var selectedCandidate = [candidatesController selection];
    if (!selectedCandidate || [selectedCandidate isMemberOfClass:[CPNull class]]) {
        alert("Bitte wählen Sie zuerst links einen Kandidaten / Patienten aus.");
        return;
    }

    var candidateId = [selectedCandidate valueForKey:@"id"];
    var candidatePseudonym = [selectedCandidate valueForKey:@"pseudonym"] || ("ID " + candidateId);

    // 1. Wechsle auf Tab 'Matching' (Index 2) und dort auf Sub-Tab 'Per Patient' (Index 1)
    if (mainWorkspaceTab) {
        [mainWorkspaceTab selectTabViewItemAtIndex:2];
    }
    if (_matchingSubTabView) {
        [_matchingSubTabView selectTabViewItemAtIndex:1];
    }

    [self updatePatientMatchesFilter];

    [sender setEnabled:NO];
    [sender setTitle:@"Matching..."];

    var taskId = @"candidate_matching_" + candidateId;
    [self addTaskWithName:@"Matching: " + candidatePseudonym identifier:taskId];
    [self updateTaskWithIdentifier:taskId state:@"active" message:@"Gezielter Abgleich läuft..." progress:20];

    var request = [CPURLRequest requestWithURL:"/BBB/run_all_matches"
                                   cachePolicy:CPURLRequestUseProtocolCachePolicy
                               timeoutInterval:1800.0];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var payload = {
        "candidate_id": candidateId,
        "task_id": taskId
    };
    var postData = [CPString stringWithString:JSON.stringify(payload)];
    [request setHTTPBody:postData];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [sender setEnabled:YES];
        [sender setTitle:@"Match against trials"];

        if (!error && data) {
            try {
                [self updateTaskWithIdentifier:taskId state:@"finished" message:@"Erfolgreich" progress:100];
                
                matchesController._entity._refreshCachedObjects = YES;
                var allObjs = [matchesController._entity allObjects];
                [matchesController setContent:allObjs];
                matchesController._entity._refreshCachedObjects = NO;

                [patientMatchesController setContent:allObjs];
                [self updateMatchesFilter];
                [self updatePatientMatchesFilter];
            } catch (e) {
                alert("Fehler beim Verarbeiten der Antwort: " + e.message);
                [self updateTaskWithIdentifier:taskId state:@"failed" message:@"Verarbeitungsfehler" progress:0];
            }
        } else {
            var errorMsg = (error) ? [error description] : @"Verbindung zum Matching-Service fehlgeschlagen.";
            [self updateTaskWithIdentifier:taskId state:@"failed" message:@"Verbindungsfehler" progress:0];
            alert("Matching-Fehler:\n" + errorMsg);
        }
     }];
}

- (void)updateCrossmatchDetailWithMatch:(id)selectedMatch table:(NoCibTableView)tableView view:(CPTextView)textView resultsTarget:(CPString)targetKey
{
    var results = [];
    if (selectedMatch && ![selectedMatch isMemberOfClass:[CPNull class]])
    {
        var matchesJsonStr = [selectedMatch valueForKey:@"criteria_matches"];
        if (matchesJsonStr && [matchesJsonStr length] > 0)
        {
            try {
                results = [CPArray arrayWithArray:JSON.parse(matchesJsonStr)];
            } catch(e) {
                results = [];
            }
        }

        var summary = [selectedMatch valueForKey:@"summary"] || @"";
        if ([summary length] > 0) {
            var parsedAttrStr = [CPMarkdownParser attributedStringFromMarkdown:summary];
            [textView setString:parsedAttrStr];
        } else {
            [textView setString:@"No narrative generated for this crossmatch yet."];
        }
    }
    else
    {
        [textView setString:@""];
    }

    [self setValue:results forKey:targetKey];
    [tableView reloadData];
}

- (void)updateMatchesFilter
{
    var selectedTrial = [trialsController selection];
    if (selectedTrial && ![selectedTrial isMemberOfClass:[CPNull class]])
    {
        var trialId = [selectedTrial valueForKey:@"id"];
        if (trialId !== undefined && trialId !== null)
        {
            var predicate = [CPPredicate predicateWithFormat:@"trial_id = %@", trialId];
            [matchesController setFilterPredicate:predicate];
            return;
        }
    }
    [matchesController setFilterPredicate:[CPPredicate predicateWithValue:NO]];
}

- (void)updatePatientMatchesFilter
{
    var selectedCandidate = [candidatesController selection];
    if (selectedCandidate && ![selectedCandidate isMemberOfClass:[CPNull class]])
    {
        var candidateId = [selectedCandidate valueForKey:@"id"];
        if (candidateId !== undefined && candidateId !== null)
        {
            var predicate = [CPPredicate predicateWithFormat:@"candidate_id = %@", candidateId];
            [patientMatchesController setFilterPredicate:predicate];
            return;
        }
    }
    [patientMatchesController setFilterPredicate:[CPPredicate predicateWithValue:NO]];
}

- (void)generatePatientNarrativeSummaryAction:(id)sender
{
    [self _generateNarrativeSummaryForController:patientMatchesController targetView:_patientNarrativeTextView sender:sender];
}

- (void)generateNarrativeSummaryAction:(id)sender
{
    [self _generateNarrativeSummaryForController:matchesController targetView:_narrativeTextView sender:sender];
}

- (void)_generateNarrativeSummaryForController:(id)controller targetView:(CPTextView)targetTextView sender:(id)sender
{
    var selectedMatch = [controller selection];
    if (!selectedMatch || [selectedMatch isMemberOfClass:[CPNull class]]) {
        alert("Please select a match row first.");
        return;
    }

    var matchId = [selectedMatch valueForKey:@"id"];
    if (!matchId) {
        alert("No valid Match ID found.");
        return;
    }

    [sender setEnabled:NO];
    [sender setTitle:@"Generating..."];
    [targetTextView setString:@"Requesting narrative clinical summary from LLM, please wait..."];

    [self addTaskWithName:@"Narrative Summary" identifier:@"narrative_summary"];
    [self updateTaskWithIdentifier:@"narrative_summary" state:@"active" message:@"Generiere Bericht..." progress:30];

    var request = [CPURLRequest requestWithURL:@"/BBB/matches/generate_summary"];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var payload = {
        "match_id": matchId,
        "model": selectedModel
    };
    var postData = [CPString stringWithString:JSON.stringify(payload)];
    [request setHTTPBody:postData];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [sender setEnabled:YES];
        [sender setTitle:@"Create Narrative Summary"];

        if (!error && data) {
            try {
                var parsedData = JSON.parse(data);
                var summary = parsedData.summary || "No narrative generated by the model.";
                var parsedAttrStr = [CPMarkdownParser attributedStringFromMarkdown:summary];
                [targetTextView setString:parsedAttrStr];
                
                [selectedMatch setValue:summary forKey:@"summary"];
                [self updateTaskWithIdentifier:@"narrative_summary" state:@"finished" message:@"Abgeschlossen" progress:100];
            } catch (e) {
                [targetTextView setString:@"Error parsing narrative response: " + e.message];
                [self updateTaskWithIdentifier:@"narrative_summary" state:@"failed" message:@"Fehler beim Verarbeiten" progress:0];
            }
        } else {
            var errorMsg = (error) ? [error description] : @"Could not contact the summary database service.";
            [targetTextView setString:@"Narrative generation failed:\n\n" + errorMsg];
            [self updateTaskWithIdentifier:@"narrative_summary" state:@"failed" message:@"Verbindungsfehler" progress:0];
        }
     }];
}

// --------------------------------------------------------------------------------
// CPTokenFieldDelegate Implementations (Converting strings to rich tokens)
// --------------------------------------------------------------------------------

- (CPString)tokenField:(CPTokenField)tokenField displayStringForRepresentedObject:(id)representedObject
{
    return "";
}

- (id)tokenField:(CPTokenField)tokenField representedObjectForEditingString:(CPString)editingString
{
    var cleanString = [editingString stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([cleanString hasPrefix:@"HP:"] || [cleanString hasPrefix:@"ICD10:"] || [cleanString hasPrefix:@"OPS:"] || [cleanString hasPrefix:@"ATC:"])
    {
        var parts = [cleanString componentsSeparatedByString:@" "];
        var code = parts[0];
        [parts removeObjectAtIndex:0];
        var display = [parts componentsJoinedByString:@" "] || @"Manual Entry";
        return { "code": code, "display": display, "is_demographic": false };
    }
    else if ([cleanString hasPrefix:@"30525-0"] || [cleanString hasPrefix:@"76689-9"] || [cleanString hasPrefix:@"temporal-constraint"] || [cleanString hasPrefix:@"Age:"] || [cleanString hasPrefix:@"Sex:"] || [cleanString hasPrefix:@"Temporal:"])
    {
        var isAge = [cleanString hasPrefix:@"30525-0"] || [cleanString hasPrefix:@"Age:"];
        var isSex = [cleanString hasPrefix:@"76689-9"] || [cleanString hasPrefix:@"Sex:"];
        var code = isAge ? @"30525-0" : (isSex ? @"76689-9" : @"temporal-constraint");
        var display = cleanString;
        return { "code": code, "display": display, "is_demographic": true };
    }
    return { "code": @"HP:0000118", "display": cleanString, "is_demographic": false };
}

- (CPArray)tokenField:(CPTokenField)tokenField completionsForSubstring:(CPString)substring indexOfToken:(CPInteger)tokenIndex indexOfSelectedItem:(CPInteger)selectedIndex
{
    return [];
}

// --------------------------------------------------------------------------------
// Native Drag Source implementation for Hierarchy elements
// --------------------------------------------------------------------------------

- (BOOL)outlineView:(CPOutlineView)anOutlineView writeItems:(CPArray)items toPasteboard:(CPPasteboard)pboard
{
    if ([items count] === 0) return NO;
    var treeNode = [items objectAtIndex:0];
    var node = [treeNode representedObject];
    if (!node || [node name] === @"Loading...") return NO;

    var termId = [node termId];
    var formattedId = "";

    if ([node nodeType] === @"ICD-10")
    {
        if ([termId hasPrefix:@"KAP-"]) return NO;
        formattedId = "ICD10:" + termId;
    }
    else if ([node nodeType] === @"OPS")
    {
        formattedId = "OPS:" + termId;
    }
    else if ([node nodeType] === @"ATC")
    {
        formattedId = "ATC:" + termId;
    }
    else
    {
        formattedId = formatHPOId(termId);
    }

    var dict = [CPDictionary dictionaryWithObjectsAndKeys:
                    formattedId, @"code",
                [node name], @"display",
                [CPNumber numberWithBool:NO], @"is_modifier"
    ];

    [pboard declareTypes:[CPArray arrayWithObjects:@"HPOTermPboardType", CPStringPboardType, nil] owner:self];
    [pboard setPropertyList:dict forType:@"HPOTermPboardType"];
    [pboard setString:formattedId forType:CPStringPboardType];
    return YES;
}

- (BOOL)tableView:(CPTableView)aTableView writeRowsWithIndexes:(CPIndexSet)rowIndexes toPasteboard:(CPPasteboard)pboard
{
    if (aTableView === downstreamTableView)
    {
        var clickedRow = [rowIndexes firstIndex];
        if (clickedRow === CPNotFound || clickedRow >= [_downstreamTerms count]) return NO;

        var term = _downstreamTerms[clickedRow];
        var formattedId = "";

        if ([_currentPickerType isEqualToString:@"ICD-10"])
        {
            formattedId = "ICD10:" + term.id;
        }
        else if ([_currentPickerType isEqualToString:@"OPS"])
        {
            formattedId = "OPS:" + term.id;
        }
        else if ([_currentPickerType isEqualToString:@"ATC"])
        {
            formattedId = "ATC:" + term.id;
        }
        else
        {
            formattedId = formatHPOId(term.id);
        }

        var dict = [CPDictionary dictionaryWithObjectsAndKeys:
                        formattedId, @"code",
                    term.label, @"display",
                    [CPNumber numberWithBool:NO], @"is_modifier"
        ];

        [pboard declareTypes:[CPArray arrayWithObjects:@"HPOTermPboardType", CPStringPboardType, nil] owner:self];
        [pboard setPropertyList:dict forType:@"HPOTermPboardType"];
        [pboard setString:formattedId forType:CPStringPboardType];
        return YES;
    }
    else if (aTableView === _phenoVisualTableView)
    {
        var clickedRow = [rowIndexes firstIndex];
        if (clickedRow === CPNotFound || clickedRow >= [_phenoVisualItems count]) return NO;

        var item = _phenoVisualItems[clickedRow];
        var formattedId = item.code;

        var dict = [CPDictionary dictionaryWithObjectsAndKeys:
                        formattedId, @"code",
                    item.label, @"display",
                    [CPNumber numberWithBool:NO], @"is_modifier",
                    (item.category === "Demographics") ? [CPNumber numberWithBool:YES] : [CPNumber numberWithBool:NO], @"is_demographic"
        ];

        [pboard declareTypes:[CPArray arrayWithObjects:@"HPOTermPboardType", CPStringPboardType, nil] owner:self];
        [pboard setPropertyList:dict forType:@"HPOTermPboardType"];
        [pboard setString:formattedId forType:CPStringPboardType];
        return YES;
    }
    return NO;
}


- (void)pickerTypeChanged:(id)sender
{
    var selected = [sender selectedSegment];
    if (selected === 0)
    {
        _currentPickerType = @"HPO";
        [_nameOnlyCheckbox setHidden:NO];
        [_searchField setStringValue:@""];
        [_searchField setPlaceholderString:@"Search HPO terms..."];
        [_searchTokenField setPlaceholderString:@"Selected HPO term (drag from here)..."];
        [_searchTokenField setObjectValue:[]];
        _matchedIndexPaths = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@""];
        [self fetchRoots];
    }
    else if (selected === 1)
    {
        _currentPickerType = @"ICD-10";
        [_nameOnlyCheckbox setHidden:YES];
        [_searchField setStringValue:@""];
        [_searchField setPlaceholderString:@"Search ICD-10 codes/text..."];
        [_searchTokenField setPlaceholderString:@"Selected ICD-10 term (drag from here)..."];
        [_searchTokenField setObjectValue:[]];
        _matchedIndexPaths = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@""];
        [self fetchICD10Roots];
    }
    else if (selected === 2)
    {
        _currentPickerType = @"OPS";
        [_nameOnlyCheckbox setHidden:YES];
        [_searchField setStringValue:@""];
        [_searchField setPlaceholderString:@"Search OPS codes/text..."];
        [_searchTokenField setPlaceholderString:@"Selected OPS term (drag from here)..."];
        [_searchTokenField setObjectValue:[]];
        _matchedIndexPaths = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@""];
        [self fetchOPSRoots];
    }
    else if (selected === 3)
    {
        _currentPickerType = @"ATC";
        [_nameOnlyCheckbox setHidden:YES];
        [_searchField setStringValue:@""];
        [_searchField setPlaceholderString:@"Search ATC codes/text..."];
        [_searchTokenField setPlaceholderString:@"Selected ATC term (drag from here)..."];
        [_searchTokenField setObjectValue:[]];
        _matchedIndexPaths = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@""];
        [self fetchATCRoots];
    }
    else if (selected === 4)
    {
        _currentPickerType = @"LOINC";
        [_nameOnlyCheckbox setHidden:YES];
        [_searchField setStringValue:@""];
        [_searchField setPlaceholderString:@"Search LOINC codes/text..."];
        [_searchTokenField setPlaceholderString:@"Selected LOINC term (drag from here)..."];
        [_searchTokenField setObjectValue:[]];
        _matchedIndexPaths = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@""];
        [self fetchLOINCRoots];
    }
    [_searchTokenField setNeedsLayout];
}

- (id)convertCustomJSONToFHIRGroup:(id)customNode
{
    if (!customNode) return nil;

    console.group("🔍 [CHECKPOINT 2] Custom JSON Conversion");
    console.log("Input custom node:", customNode);
    
    var group = {};
    group.resourceType = "Group";
    group.combinationMethod = customNode.combinationMethod || "all-of";

    var customCharacteristics = customNode.characteristics || customNode.characteristic || [];
    var fhirCharacteristics = [];

    for (var i = 0; i < customCharacteristics.length; i++)
    {
        var item = customCharacteristics[i];

        if (item.subgroup)
        {
            var subGroup = [self convertCustomJSONToFHIRGroup:item.subgroup];
            if (subGroup)
            {
                fhirCharacteristics.push(subGroup);
            }
        }
        else if (item.symptom)
        {
            console.log(`Item [${i}] symptom raw payload:`, item.symptom);
            var sym = item.symptom;
            var tokens = [];
            var rawLabels = sym.labels || (sym.label ? [sym.label] : []);
            var isDiagRow = NO;
            var isDemoRow = sym.is_demographic ? true : false;
            var isProcRow = sym.is_procedure ? true : false;
            var isMedRow = sym.is_medication ? true : false;

            for (var k = 0; k < rawLabels.length; k++) {
                var codeVal = "";
                var systemVal = "http://human-phenotype-ontology.org";
                if (rawLabels[k].indexOf("ICD10:") === 0 || isDiagRow) {
                    codeVal = rawLabels[k];
                    systemVal = "http://hl7.org/fhir/sid/icd-10";
                    isDiagRow = YES;
                } else if (rawLabels[k].indexOf("OPS:") === 0 || isProcRow) {
                    codeVal = rawLabels[k];
                    systemVal = "http://fhir.de/CodeSystem/bfarm/ops";
                    isProcRow = YES;
                } else if (rawLabels[k].indexOf("ATC:") === 0 || isMedRow) {
                    codeVal = rawLabels[k];
                    systemVal = "http://www.whocc.no/atc";
                    isMedRow = YES;
                } else if (isDemoRow) {
                    codeVal = (sym.demographic_type === "sex") ? "76689-9" : "30525-0";
                    systemVal = "http://loinc.org";
                }
                tokens.push({
                    "system": systemVal,
                    "code": codeVal,
                    "display": rawLabels[k],
                    "is_demographic": isDemoRow
                });
            }

            var codingSct = isDiagRow ? "2931005" : (isDemoRow ? "30525-0" : (isProcRow ? "71388002" : (isMedRow ? "410942007" : "8116006")));
            var displaySct = isDiagRow ? "Diagnose" : (isDemoRow ? "Demographic Constraint" : (isProcRow ? "Prozedur (OPS)" : (isMedRow ? "Medikament (ATC)" : "Phänotypisches Merkmal")));

            var fhirChar = {
                "exclude": sym.exclude ? true : false,
                "combinationMethod": fhirCharacteristics.length > 0 ? (sym.combinationMethod || "all-of") : (sym.exclude ? "neither-of" : "all-of"),
                "code": {
                    "coding": [{
                        "system": isDemoRow ? "http://loinc.org" : "http://snomed.info/sct",
                        "code": codingSct,
                        "display": displaySct
                    }]
                },
                "valueCodeableConcept": {
                    "coding": tokens
                }
            };
            fhirCharacteristics.push(fhirChar);
        }
        else if (item.characteristic || item.resourceType === "Group")
        {
            var subGroup = [self convertCustomJSONToFHIRGroup:item];
            if (subGroup)
            {
                fhirCharacteristics.push(subGroup);
            }
        }
        else
        {
            fhirCharacteristics.push(item);
        }
    }

    group.characteristic = fhirCharacteristics;
    
    console.log("Converted FHIR Group result:", group);
    console.groupEnd();

    return group;
}

// --------------------------------------------------------------------------------
// Hierarchy Helpers
// --------------------------------------------------------------------------------

- (FHIRCriteriaNode)nodeAtRowIndex:(int)rowIndex
{
    if (rowIndex < 0 || rowIndex >= [_ruleEditor numberOfRows])
        return nil;

    var rowCache = [_ruleEditor _rowCacheForIndex:rowIndex];
    return rowCache ? [rowCache rowObject] : nil;
}

- (id)textFieldForRow:(int)row
{
    var node = [self nodeAtRowIndex:row];
    return node ? [node tokenField] : nil;
}

// --------------------------------------------------------------------------------
// Unified Workspace Insertion Methods
// --------------------------------------------------------------------------------

- (void)flattenNode:(FHIRCriteriaNode)node depth:(int)depth intoArray:(CPMutableArray)array
{
    if (!node) return;

    [node setIndentation:depth];
    [array addObject:node];

    var subrows = [node subrows] || [];
    for (var i = 0; i < [subrows count]; i++)
    {
        [self flattenNode:subrows[i] depth:depth + 1 intoArray:array];
    }
}

- (void)insertNode:(FHIRCriteriaNode)newNode
{
    var selectedRows = [_ruleEditor selectedRowIndexes];
    var selectedIndex = [selectedRows count] > 0 ? [selectedRows lastIndex] : CPNotFound;

    if (selectedIndex === CPNotFound)
    {
        [newNode setIndentation:0];
        [[self mutableArrayValueForKey:@"rootNodes"] addObject:newNode];
        return;
    }

    var selectedNode = [_rootNodes objectAtIndex:selectedIndex];
    var targetDepth = [selectedNode indentation];

    if ([selectedNode rowType] === CPRuleEditorRowTypeCompound)
    {
        targetDepth = targetDepth + 1;
    }

    [newNode setIndentation:targetDepth];
    [[self mutableArrayValueForKey:@"rootNodes"] insertObject:newNode atIndex:selectedIndex + 1];
}

- (void)addSimpleRule:(id)sender
{
    var newNode = [[FHIRCriteriaNode alloc] init];
    [newNode setRowType:CPRuleEditorRowTypeSimple];
    [newNode setIsDiagnosis:NO];
    [newNode setIsProcedure:NO];
    [newNode setIsMedication:NO];
    [newNode setIsDemographic:NO];
    [newNode updateCriteriaAndDisplayValues];

    [self insertNode:newNode];
}

- (void)addGroupRule:(id)sender
{
    var newNode = [[FHIRCriteriaNode alloc] init];
    [newNode setRowType:CPRuleEditorRowTypeCompound];
    [newNode setCombinationMethod:@"all-of"];
    [newNode updateCriteriaAndDisplayValues];

    [self insertNode:newNode];

    var childNode = [[FHIRCriteriaNode alloc] init];
    [childNode setRowType:CPRuleEditorRowTypeSimple];
    [childNode setIsDiagnosis:NO];
    [childNode setIsProcedure:NO];
    [childNode setIsMedication:NO];
    [childNode setIsDemographic:NO];
    [childNode updateCriteriaAndDisplayValues];
    [childNode setIndentation:[newNode indentation] + 1];

    var groupIndex = [_rootNodes indexOfObjectIdenticalTo:newNode];
    if (groupIndex !== CPNotFound)
    {
        [[self mutableArrayValueForKey:@"rootNodes"] insertObject:childNode atIndex:groupIndex + 1];
    }
}

- (void)removeRule:(id)sender
{
    var selectedIndexes = [_ruleEditor selectedRowIndexes];
    if (!selectedIndexes || [selectedIndexes count] === 0)
    {
        alert("Bitte wählen Sie zuerst eine Zeile im Kriterien-Editor aus.");
        return;
    }

    // Erfasse alle zu löschenden Indizes (bei Gruppen inkl. aller Kind-Zeilen)
    var allIndexesToDelete = [CPMutableIndexSet indexSet];
    var idx = [selectedIndexes firstIndex];
    while (idx !== CPNotFound)
    {
        if ([_ruleEditor respondsToSelector:@selector(indexesOfRowAndItsChildren:)])
        {
            var childIndexes = [_ruleEditor indexesOfRowAndItsChildren:idx];
            [allIndexesToDelete addIndexes:childIndexes];
        }
        else
        {
            [allIndexesToDelete addIndex:idx];
        }
        idx = [selectedIndexes indexGreaterThanIndex:idx];
    }

    var rootNodesProxy = [self mutableArrayValueForKey:@"rootNodes"];

    // Rückwärts löschen, um Index-Verschiebungen zu vermeiden
    var delIdx = [allIndexesToDelete lastIndex];
    while (delIdx !== CPNotFound)
    {
        if (delIdx < [rootNodesProxy count])
        {
            [rootNodesProxy removeObjectAtIndex:delIdx];
        }
        delIdx = [allIndexesToDelete indexLessThanIndex:delIdx];
    }

    // Neue Auswahl setzen und FHIR JSON aktualisieren
    var newSelectionIndex = [allIndexesToDelete firstIndex] - 1;
    if (newSelectionIndex >= 0 && newSelectionIndex < [rootNodesProxy count])
    {
        [_ruleEditor setSelectedRowIndexes:[CPIndexSet indexSetWithIndex:newSelectionIndex]];
    }
    else if ([rootNodesProxy count] > 0)
    {
        [_ruleEditor setSelectedRowIndexes:[CPIndexSet indexSetWithIndex:0]];
    }
    else
    {
        [_ruleEditor setSelectedRowIndexes:[CPIndexSet indexSet]];
    }

    [self updateFHIRGroupRepresentation];
}

- (void)resetEditor:(id)sender
{
    [self updateFHIRGroupRepresentation];
}

- (void)ruleEditorDidChange:(id)sender
{
    if (_isImportingJSON)
        return;

    var control = sender;
    if ([sender isKindOfClass:[CPNotification class]])
    {
        control = [sender object];
    }

    if ([control isKindOfClass:[HPOTokenField class]] && control.node)
    {
        var tokens = [control objectValue] || [];
        [control.node setHpoTokens:tokens];
        if (tokens.length > 0)
        {
            [control.node setSymptomText:tokens[0].display];
        }
    }
    
    if ([control isKindOfClass:[HPOTokenField class]] && control.rowIndex !== undefined)
    {
        [self phenoVisualTokenFieldDidChange:control];
    }

    [self updateFHIRGroupRepresentation];
}

// --------------------------------------------------------------------------------
// FHIR Extraction & Representation Methods
// --------------------------------------------------------------------------------

- (void)extractFHIRCriteriaAction:(id)sender
{
    var synopsisText = [[_synopsisInputTextView string] stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!synopsisText || [synopsisText length] === 0) {
        alert("Please paste a clinical trial synopsis or FHIR Group JSON into the input area first.");
        return;
    }

    if ([synopsisText hasPrefix:@"{"] || [synopsisText hasPrefix:@"["])
    {
        try {
            var parsedData = JSON.parse(synopsisText);
            
            console.group("🔍 [CHECKPOINT 1] Server Extraction Output");
            console.log("Raw parsed server response:", parsedData);
            console.groupEnd();
            
            if (parsedData) {
                if (parsedData.resourceType !== "Group" && (parsedData.characteristics || parsedData.combinationMethod)) {
                    console.log("⚠️ [CHECKPOINT 1] Format is custom LLM JSON -> converting to FHIR Group...");
                    parsedData = [self convertCustomJSONToFHIRGroup:parsedData];
                }

                if (parsedData && parsedData.resourceType === "Group") {
                    [self importFHIRGroup:parsedData];
                    return;
                }
            }
        } catch (e) {
        }
    }

    [sender setEnabled:NO];
    [sender setTitle:@"Extracting..."];

    [self addTaskWithName:@"FHIR Eligibility Extraction" identifier:@"fhir_extraction"];
    [self updateTaskWithIdentifier:@"fhir_extraction" state:@"active" message:@"Extrahiere Kriterien..." progress:25];

    var request = [CPURLRequest requestWithURL:"/BBB/extract_fhir_inex_criteria"
                                   cachePolicy:CPURLRequestUseProtocolCachePolicy
                               timeoutInterval:1800.0];

    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var payload = {
        "report": synopsisText,
        "model": selectedModel,
        "deep_mode": deepModeEnabled ? 1 : 0,
        "task_id": @"fhir_extraction"
    };
    var postData = [CPString stringWithString:JSON.stringify(payload)];
    [request setHTTPBody:postData];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [sender setEnabled:YES];
        [sender setTitle:@"Extract FHIR Group"];

        if (!error && data)
        {
            try
            {
                var parsedData = JSON.parse(data);
                
                if (parsedData && parsedData.resourceType !== "Group" && (parsedData.characteristics || parsedData.combinationMethod))
                {
                    parsedData = [self convertCustomJSONToFHIRGroup:parsedData];
                }

                if (parsedData && parsedData.resourceType === "Group")
                {
                    [self importFHIRGroup:parsedData];

                    var selectedTrial = [trialsController selection];

                    if (selectedTrial && ![selectedTrial isMemberOfClass:[CPNull class]])
                    {
                        var prettyJson = JSON.stringify([[self compileGroupFromFlatNodes:_rootNodes] JSObject], null, 2);
                        [selectedTrial setValue:prettyJson forKey:@"fhir_group_json"];
                    }

                }
                else
                {
                    [self importPhenopacketToEditor:parsedData];
                }
                [self updateTaskWithIdentifier:@"fhir_extraction" state:@"finished" message:@"Erfolgreich abgeschlossen" progress:100];
            } catch (e) {
                alert("Error parsing server-side extraction response: " + e.message);
                [self updateTaskWithIdentifier:@"fhir_extraction" state:@"failed" message:@"Verarbeitungsfehler" progress:0];
            }
        } else {
            var errorMsg = (error) ? [error description] : @"Could not connect to database services.";
            alert("Model Extraction Failure:\n" + errorMsg);
            [self updateTaskWithIdentifier:@"fhir_extraction" state:@"failed" message:@"Verbindungsfehler" progress:0];
        }
    }];
}

- (void)prepopulateMockData
{
    [self extractFHIRCriteriaAction:nil];
    [self extractPhenopacketAction:nil];
}

// --------------------------------------------------------------------------------
// Phenopacket Extractor Actions
// --------------------------------------------------------------------------------

- (void)extractPhenopacketAction:(id)sender
{
    var narrativeText = [[_reportInputTextView string] stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]];

    if (!narrativeText || [narrativeText length] === 0) {
        [_phenopacketOutputTextView setString:@"Please paste a medical report or Phenopacket JSON on the left before extracting."];
        return;
    }

    if ([narrativeText hasPrefix:@"{"] || [narrativeText hasPrefix:@"["])
    {
        try {
            var parsedData = JSON.parse(narrativeText);
            if (parsedData && (parsedData.phenotypicFeatures || parsedData.subject || parsedData.id)) {
                var prettyJSON = JSON.stringify(parsedData, null, 4);
                [_phenopacketOutputTextView setString:prettyJSON];
                [self parseActivePhenopacketToVisualItems];
                return;
            }
        } catch (e) {
        }
    }

    // Extract selected candidate details (ID and reference date)
    var selectedCandidate = [candidatesController selection];
    var candidateId = (selectedCandidate && ![selectedCandidate isMemberOfClass:[CPNull class]]) ? [selectedCandidate valueForKey:@"id"] : nil;
    var refDate = (selectedCandidate && ![selectedCandidate isMemberOfClass:[CPNull class]]) ? ([selectedCandidate valueForKey:@"reference_date"]) : nil;

    [sender setEnabled:NO];
    [sender setTitle:@"Extracting..."];
    [_phenopacketOutputTextView setString:@"Extracting phenopacket & diagnoses, please wait..."];

    [self addTaskWithName:@"Phenopacket Extraction" identifier:@"phenopacket_extraction"];
    [self updateTaskWithIdentifier:@"phenopacket_extraction" state:@"active" message:@"Extrahiere Phenopacket..." progress:25];

    var request = [CPURLRequest requestWithURL:"/BBB/extract_phenopacket_from_letter"
                                   cachePolicy:CPURLRequestUseProtocolCachePolicy
                               timeoutInterval:900.0];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var payload = {
        "report": narrativeText,
        "model": selectedModel,
        "deep_mode": deepModeEnabled ? 1 : 0,
        "task_id": @"phenopacket_extraction",
        "candidate_id": candidateId,
        "reference_date": refDate
    };
    var postData = [CPString stringWithString:JSON.stringify(payload)];
    [request setHTTPBody:postData];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [sender setEnabled:YES];
        [sender setTitle:@"Extract phenopacket"];

        if (!error && data) {
            try {
                var parsedData = JSON.parse(data);
                var prettyJSON = JSON.stringify(parsedData, null, 4);
                [_phenopacketOutputTextView setString:prettyJSON];
                [self parseActivePhenopacketToVisualItems];
                
                if (selectedCandidate && ![selectedCandidate isMemberOfClass:[CPNull class]])
                {
                    [selectedCandidate setValue:prettyJSON forKey:@"phenopacket_json"];
                }
                
                [self updateTaskWithIdentifier:@"phenopacket_extraction" state:@"finished" message:@"Erfolgreich abgeschlossen" progress:100];
            } catch (e) {
                [_phenopacketOutputTextView setString:data];
                [self parseActivePhenopacketToVisualItems];
                [self updateTaskWithIdentifier:@"phenopacket_extraction" state:@"failed" message:@"Verarbeitungsfehler" progress:0];
            }
        } else {
            var errorMsg = (error) ? [error description] : @"Unknown error occurred.";
            [_phenopacketOutputTextView setString:@"Failed to extract phenopacket:\n\n" + errorMsg];
            [self parseActivePhenopacketToVisualItems];
            console.log("Extraction Error: ", error);
            [self updateTaskWithIdentifier:@"phenopacket_extraction" state:@"failed" message:@"Verbindungsfehler" progress:0];
        }
     }];
}

- (void)importPhenopacketToEditor:(id)phenopacket
{
    if (!phenopacket) return;
    var features = phenopacket.phenotypicFeatures || [];
    var diseases = phenopacket.diseases || [];
    var characteristics = [];

    if (phenopacket.subject) {
        var age = phenopacket.subject.age;
        var sex = phenopacket.subject.sex;
        
        if (age) {
            characteristics.push({
                "exclude": false,
                "combinationMethod": "all-of",
                "code": {
                    "coding": [{
                        "system": "http://loinc.org",
                        "code": "30525-0",
                        "display": "Age Constraint"
                    }]
                },
                "valueQuantity": {
                    "comparator": ">=",
                    "value": parseInt(age, 10),
                    "unit": "years",
                    "system": "http://unitsofmeasure.org",
                    "code": "a"
                }
            });
        }
        
        if (sex && sex !== "UNKNOWN") {
            characteristics.push({
                "exclude": false,
                "combinationMethod": "all-of",
                "code": {
                    "coding": [{
                        "system": "http://loinc.org",
                        "code": "76689-9",
                        "display": "Sex Constraint"
                    }]
                },
                "valueCodeableConcept": {
                    "coding": [{
                        "system": "http://loinc.org",
                        "code": sex.toUpperCase(),
                        "display": sex
                    }]
                }
            });
        }
    }

    for (var i = 0; i < features.length; i++) {
        var feat = features[i];
        if (!feat.type) continue;

        characteristics.push({
            "exclude": feat.exclude ? true : false,
            "combinationMethod": feat.exclude ? "neither-of" : "all-of",
            "code": {
                "coding": [
                    {
                        "system": "http://snomed.info/sct",
                        "code": "8116006",
                        "display": "Phänotypisches Merkmal"
                    }
                ]
            },
            "valueCodeableConcept": {
                "coding": [{
                    "system": "http://human-phenotype-ontology.org",
                    "code": feat.type.id || "",
                    "display": feat.type.label || ""
                }]
            }
        });
    }

    for (var i = 0; i < diseases.length; i++) {
        var dis = diseases[i];
        if (!dis.term) continue;

        characteristics.push({
            "exclude": dis.exclude ? true : false,
            "combinationMethod": dis.exclude ? "neither-of" : "all-of",
            "code": {
                "coding": [
                    {
                        "system": "http://snomed.info/sct",
                        "code": "2931005",
                        "display": "Diagnose"
                    }
                ]
            },
            "valueCodeableConcept": {
                "coding": [{
                    "system": "http://hl7.org/fhir/sid/icd-10",
                    "code": dis.term.id || "",
                    "display": dis.term.label || ""
                }]
            }
        });
    }

    var rootGroup = {
        "resourceType": "Group",
        "combinationMethod": "all-of",
        "characteristic": characteristics
    };

    [self importFHIRGroup:rootGroup];
}

- (void)showJSONPopover:(id)sender
{
    [self updateFHIRGroupRepresentation];

    if (!_jsonPopover)
    {
        _jsonPopover = [CPPopover new];
        [_jsonPopover setBehavior:CPPopoverBehaviorTransient];
        [_jsonPopover setAppearance:CPPopoverAppearanceMinimal];
        [_jsonPopover setAnimates:YES];

        var containerView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 500, 420)];

        var scrollView = [[CPScrollView alloc] initWithFrame:[containerView bounds]];
        [scrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [scrollView setAutohidesScrollers:YES];

        _popoverTextView = [[CPTextView alloc] initWithFrame:[scrollView bounds]];
        [_popoverTextView setAutoresizingMask:CPViewWidthSizable];
        [_popoverTextView setEditable:NO];
        [_popoverTextView setSelectable:YES];
        [_popoverTextView setFont:[CPFont fontWithName:@"Courier" size:11.0]];
        [_popoverTextView setTextColor:[CPColor colorWithRed:0.1 green:0.4 blue:0.1 alpha:1.0]];

        [scrollView setDocumentView:_popoverTextView];
        [containerView addSubview:scrollView];

        var popoverController = [CPViewController new];
        [popoverController setView:containerView];
        [_jsonPopover setContentViewController:popoverController];
    }

    [_popoverTextView setString:_fhirJsonString || @""];
    [_jsonPopover showRelativeToRect:[sender bounds] ofView:sender preferredEdge:CPMinYEdge];
}

- (void)updateFHIRGroupRepresentation
{
    if (_isImportingJSON)
        return;

    _isImportingJSON = YES;

    try
    {
        var rootGroup = [self compileGroupFromFlatNodes:_rootNodes];
        var jsFormattedObject = [rootGroup JSObject];
        var prettyJson = JSON.stringify(jsFormattedObject, null, 2);

        var selectedTrial = [trialsController selection];
        if (selectedTrial && ![selectedTrial isMemberOfClass:[CPNull class]])
        {
            var currentJson = [selectedTrial valueForKey:@"fhir_group_json"] || @"";
            if (currentJson !== prettyJson)
            {
                [selectedTrial setValue:prettyJson forKey:@"fhir_group_json"];
            }
        }

        if (_fhirJsonString !== prettyJson)
        {
            _fhirJsonString = prettyJson;
        }
    }
    catch (e)
    {
        console.error("[FHIR Error] Critical formatting error in compiler: ", e);
    }
    finally
    {
        _isImportingJSON = NO;
    }
}

- (id)resolveContainedReferencesInGroup:(id)rootGroup
{
    if (!rootGroup) return nil;
    var contained = rootGroup.contained || [];
    var containedMap = {};
    for (var i = 0; i < contained.length; i++) {
        var c = contained[i];
        if (c.id) {
            containedMap["#" + c.id] = c;
        }
    }
    return [self resolveReferencesInItem:rootGroup withMap:containedMap];
}

- (id)resolveReferencesInItem:(id)item withMap:(id)containedMap
{
    if (!item || typeof item !== 'object') return item;

    if (item.valueReference && item.valueReference.reference) {
        var ref = item.valueReference.reference;
        var referenced = containedMap[ref];
        if (referenced) {
            var resolved = JSON.parse(JSON.stringify(referenced));
            resolved.exclude = item.exclude ? true : false;
            return [self resolveReferencesInItem:resolved withMap:containedMap];
        }
    }

    if (Array.isArray(item)) {
        var arr = [];
        for (var i = 0; i < item.length; i++) {
            var resolvedItem = [self resolveReferencesInItem:item[i] withMap:containedMap];
            
            if (resolvedItem !== null && resolvedItem !== undefined) {
                arr.push(resolvedItem);
            }
        }
        return arr;
    }

    var keys = Object.keys(item);
    var result = {};
    for (var i = 0; i < keys.length; i++) {
        var k = keys[i];
        result[k] = [self resolveReferencesInItem:item[k] withMap:containedMap];
    }
    return result;
}

- (FHIRCriteriaNode)nodeFromFHIRGroup:(id)group
{
    if (!group) return nil;

    var node = [[FHIRCriteriaNode alloc] init];

    var isCompound = NO;
    var combMethod = group.combinationMethod || "all-of";
    var characteristics = group.characteristic || [];

    if (characteristics.length > 0 || group.resourceType === "Group")
    {
        isCompound = YES;
    }

    if (isCompound)
    {
        [node setRowType:CPRuleEditorRowTypeCompound];
        [node setCombinationMethod:combMethod];
        [node updateCriteriaAndDisplayValues];

        var subrows = [CPMutableArray array];
        for (var i = 0; i < characteristics.length; i++)
        {
            var charItem = characteristics[i];
            var isCompositeSubgroup = NO;
            var isSubgroup = (charItem.resourceType === "Group" || (charItem.characteristic && charItem.characteristic.length > 0));
            
            if (isSubgroup)
            {
                if (charItem.id && charItem.id.indexOf("composite-") === 0)
                {
                    isCompositeSubgroup = YES;
                }
                else
                {
                    var subChars = charItem.characteristic || [];
                    var hasNestedGroups = NO;
                    for (var k = 0; k < subChars.length; k++)
                    {
                        var cItem = subChars[k];
                        if (cItem.resourceType === "Group" || cItem.characteristic || cItem.combinationMethod)
                        {
                            hasNestedGroups = YES;
                            break;
                        }
                    }
                    if (!hasNestedGroups && subChars.length > 0)
                    {
                        isCompositeSubgroup = YES;
                    }
                }
            }

            if (isCompositeSubgroup)
            {
                var subNode = [[FHIRCriteriaNode alloc] init];
                [subNode setRowType:CPRuleEditorRowTypeSimple];

                var subChars = charItem.characteristic || [];
                var isDiag  = false;
                var isProc  = false;
                var isMed   = false;
                var isLoinc = false;
                var isDemo  = false;

                // Priority 1: Check outer group code
                if (charItem.code && charItem.code.coding && charItem.code.coding.length > 0)
                {
                    var codeVal = charItem.code.coding[0].code;
                    if (codeVal === "2931005") isDiag = true;
                    else if (codeVal === "71388002") isProc = true;
                    else if (codeVal === "410942007") isMed = true;
                }

                // Priority 2: Scan subChars for primary clinical concepts
                for (var m = 0; m < subChars.length; m++)
                {
                    var nestedChar = subChars[m];
                    var nestedValCode = nestedChar.valueCodeableConcept;
                    var nestedCode = (nestedChar.code && nestedChar.code.coding && nestedChar.code.coding.length > 0) ? nestedChar.code.coding[0].code : null;

                    if (nestedCode === "2931005") isDiag = true;
                    else if (nestedCode === "71388002") isProc = true;
                    else if (nestedCode === "410942007") isMed = true;
                    
                    if (nestedValCode && nestedValCode.coding && nestedValCode.coding.length > 0)
                    {
                        var sys = nestedValCode.coding[0].system || "";
                        var codeVal = nestedValCode.coding[0].code || "";
                        if (codeVal.indexOf("ICD10:") === 0) isDiag = true;
                        else if (codeVal.indexOf("OPS:") === 0) isProc = true;
                        else if (codeVal.indexOf("ATC:") === 0) isMed = true;
                        else if (sys.indexOf("loinc.org") !== -1 || codeVal.indexOf("LOINC:") === 0) {
                            if (codeVal !== "LP7753-9" && codeVal !== "30525-0" && codeVal !== "76689-9") {
                                isLoinc = true;
                            }
                        }
                    }
                }

                // Priority 3: Only if NO clinical concept exists, check for standalone demographic
                if (!isDiag && !isProc && !isMed && !isLoinc)
                {
                    var hasClinicalPheno = false;
                    for (var m = 0; m < subChars.length; m++)
                    {
                        var nestedChar = subChars[m];
                        var nestedValCode = nestedChar.valueCodeableConcept;
                        var nestedCode = (nestedChar.code && nestedChar.code.coding && nestedChar.code.coding.length > 0) ? nestedChar.code.coding[0].code : null;

                        if (nestedCode === "8116006" && nestedValCode && nestedValCode.coding && nestedValCode.coding.length > 0) {
                            var codeVal = nestedValCode.coding[0].code || "";
                            if (codeVal.indexOf("HP:") === 0 || codeVal.indexOf("http") !== -1 || codeVal.length > 0) {
                                hasClinicalPheno = true;
                            }
                        }
                        if (nestedCode === "30525-0" || nestedCode === "76689-9" || nestedCode === "LP7753-9" || nestedCode === "temporal-constraint" || nestedChar.relativeTime) {
                            isDemo = true;
                        }
                    }
                    if (hasClinicalPheno) {
                        isDemo = false; // Phenotype takes precedence over measurement modifier
                    }
                }

                [subNode setIsDiagnosis:isDiag];
                [subNode setIsDemographic:isDemo];
                [subNode setIsProcedure:isProc];
                [subNode setIsMedication:isMed];
                [subNode setIsLoinc:isLoinc];

                var isExclude = (charItem.exclude === true);

                if (!isExclude && charItem.characteristic)
                {
                    for (var m = 0; m < charItem.characteristic.length; m++)
                    {
                        if (charItem.characteristic[m].exclude === true)
                        {
                            isExclude = true;
                            break;
                        }
                    }
                }

                var presenceMode = @"all-present";
                if (isExclude || charItem.combinationMethod === "neither-of")
                {
                    presenceMode = @"neither-present";
                }
                else if (charItem.combinationMethod === "any-of")
                {
                    presenceMode = @"any-present";
                }
                [subNode setPresenceMode:presenceMode];

                var tokens = [];
                var addedTemporalKeys = {};

                for (var m = 0; m < subChars.length; m++)
                {
                    var nestedChar = subChars[m];
                    var nestedValCode = nestedChar.valueCodeableConcept;
                    
                    var nestedCode = null;
                    if (nestedChar.code && nestedChar.code.coding && nestedChar.code.coding.length > 0)
                    {
                        nestedCode = nestedChar.code.coding[0].code;
                    }
                    
                    if (nestedChar.relativeTime && nestedChar.relativeTime.length > 0)
                    {
                        for (var r = 0; r < nestedChar.relativeTime.length; r++)
                        {
                            var rt = nestedChar.relativeTime[r];
                            var offset = rt.offsetDuration;
                            if (offset)
                            {
                                var comp = offset.comparator || "<=";
                                var val  = offset.value || "";
                                var unit = offset.unit || "days";
                                var desc = "Temporal: " + comp + " " + val + " " + unit;
                                
                                if (!addedTemporalKeys[desc]) {
                                    addedTemporalKeys[desc] = true;
                                    tokens.push({
                                        "code": "temporal-constraint",
                                        "display": desc,
                                        "is_demographic": true,
                                        "is_modifier": false
                                    });
                                }
                            }
                        }
                    }
                    
                    if (nestedCode === "30525-0" || nestedCode === "76689-9" || nestedCode === "LP7753-9" || nestedCode === "21889-1" || nestedCode === "29003-1" || nestedCode === "LOINC:29003-1" || nestedCode === "LOINC:LP7753-9" || nestedCode === "temporal-constraint")
                    {
                        var demoVal = "";
                        if (nestedChar.valueQuantity && nestedChar.valueQuantity.value !== undefined)
                        {
                            var comp = nestedChar.valueQuantity.comparator || ">=";
                            var val  = nestedChar.valueQuantity.value;
                            var unit = nestedChar.valueQuantity.unit || "";
                            demoVal = comp + " " + val + (unit ? " " + unit : "");
                        }
                        else if (nestedValCode && nestedValCode.coding && nestedValCode.coding.length > 0)
                        {
                            demoVal = nestedValCode.coding[0].display || nestedValCode.coding[0].code || "";
                        }

                        var desc = "";
                        if (nestedCode === "30525-0") { desc = "Age: " + (demoVal || ">= 18 years"); }
                        else if (nestedCode === "76689-9") { desc = "Sex: " + (demoVal || "FEMALE"); }
                        else if (nestedCode === "LP7753-9" || nestedCode === "21889-1" || nestedCode === "LOINC:LP7753-9") { desc = "Measurement: " + (demoVal || "< 3 mm"); }
                        else if (nestedCode === "29003-1" || nestedCode === "LOINC:29003-1") { desc = "Schirmer Test: " + (demoVal || "Right eye Tear secretion 1"); }
                        else if (nestedCode === "temporal-constraint") { desc = "Temporal: " + (demoVal || "<= 14 days"); }

                        tokens.push({
                            "code": nestedCode,
                            "display": desc.trim(),
                            "is_demographic": true,
                            "is_modifier": false
                        });
                    }
                    else if (nestedValCode && nestedValCode.coding)
                    {
                        var codings = nestedValCode.coding;
                        for (var j = 0; j < codings.length; j++)
                        {
                            var coding = codings[j];
                            var codeVal = coding.code || "";
                            if (codeVal && codeVal.indexOf("[HPO_CODE_FOR_") !== 0 && codeVal.indexOf("[ICD10_CODE_FOR_") !== 0 && codeVal.indexOf("[OPS_CODE_FOR_") !== 0 && codeVal.indexOf("[ATC_CODE_FOR_") !== 0)
                            {
                                tokens.push({
                                    "code": codeVal,
                                    "display": coding.display || codeVal,
                                    "is_modifier": (coding.is_modifier === true || coding.is_modifier === 1)
                                });
                            }
                            else
                            {
                                var fallbackCode = isDiag ? @"ICD10:U99" : (isProc ? @"OPS:9-999" : (isMed ? @"ATC:V03AX" : @"HP:0000118"));
                                tokens.push({
                                    "code": fallbackCode,
                                    "display": coding.display || @"Symptom"
                                });
                            }
                        }
                    }
                }

                [subNode setHpoTokens:tokens];
                if (tokens.length > 0)
                {
                    [subNode setSymptomText:tokens[0].display];
                }

                [subNode updateCriteriaAndDisplayValues];
                [subrows addObject:subNode];
            }
            else if (isSubgroup)
            {
                var subNode = [self nodeFromFHIRGroup:charItem];
                if (subNode)
                {
                    [subrows addObject:subNode];
                }
            }
            else
            {
                var subNode = [[FHIRCriteriaNode alloc] init];
                [subNode setRowType:CPRuleEditorRowTypeSimple];

                var isDiag  = false;
                var isDemo  = false;
                var isProc  = false;
                var isMed   = false;
                var isLoinc = false;

                if (charItem.code && charItem.code.coding && charItem.code.coding.length > 0)
                {
                    var codeVal = charItem.code.coding[0].code;
                    if (codeVal === "2931005") {
                        isDiag = true;
                    } else if (codeVal === "71388002") {
                        isProc = true;
                    } else if (codeVal === "410942007") {
                        isMed = true;
                    } else if (codeVal === "30525-0" || codeVal === "76689-9" || codeVal === "LP7753-9" || codeVal === "21889-1" || codeVal === "temporal-constraint" || charItem.relativeTime) {
                        isDemo = true;
                    }
                }
                var valCode = charItem.valueCodeableConcept;
                if (!isDiag && !isDemo && !isProc && !isMed && valCode && valCode.coding && valCode.coding.length > 0)
                {
                    var codeVal = valCode.coding[0].code || "";
                    if (codeVal.indexOf("ICD10:") === 0) {
                        isDiag = true;
                    } else if (codeVal.indexOf("OPS:") === 0) {
                        isProc = true;
                    } else if (codeVal.indexOf("ATC:") === 0) {
                        isMed = true;
                    } else if (codeVal.indexOf("LOINC:") === 0) {
                        isLoinc = true;
                    }
                }
                [subNode setIsDiagnosis:isDiag];
                [subNode setIsDemographic:isDemo];
                [subNode setIsProcedure:isProc];
                [subNode setIsMedication:isMed];
                [subNode setIsLoinc:isLoinc];

                var isExclude = (charItem.exclude === true);
                var presenceMode = @"all-present";
                if (isExclude || charItem.combinationMethod === "neither-of")
                {
                    presenceMode = @"neither-present";
                }
                else if (charItem.combinationMethod === "any-of")
                {
                    presenceMode = @"any-present";
                }
                [subNode setPresenceMode:presenceMode];

                var tokens = [];
                
                if (charItem.relativeTime && charItem.relativeTime.length > 0) {
                    for (var r = 0; r < charItem.relativeTime.length; r++) {
                        var rt = charItem.relativeTime[r];
                        var offset = rt.offsetDuration;
                        if (offset) {
                            var comp = offset.comparator || "<=";
                            var val  = offset.value || "";
                            var unit = offset.unit || "days";
                            tokens.push({
                                "code": "temporal-constraint",
                                "display": "Temporal: " + comp + " " + val + " " + unit,
                                "is_demographic": true
                            });
                        }
                    }
                }
                
                if (isDemo && (!charItem.relativeTime)) {
                    var demoVal = "";
                    if (charItem.valueQuantity) {
                        var comp = charItem.valueQuantity.comparator || ">=";
                        var val  = charItem.valueQuantity.value;
                        var unit = charItem.valueQuantity.unit || "";
                        demoVal = comp + " " + val + (unit ? " " + unit : "");
                    } else if (valCode && valCode.coding && valCode.coding.length > 0) {
                        demoVal = valCode.coding[0].code || valCode.coding[0].display || "";
                    }

                    var code = (charItem.code && charItem.code.coding && charItem.code.coding.length > 0) ? charItem.code.coding[0].code : "30525-0";
                    var desc = "";

                    if (code === "30525-0") { desc = "Age: " + (demoVal || ">= 18 years"); }
                    else if (code === "76689-9") { desc = "Sex: " + (demoVal || "FEMALE"); }
                    else if (code === "LP7753-9" || code === "21889-1") { desc = "Measurement: " + (demoVal || "< 3 mm"); }
                    else if (code === "temporal-constraint") { desc = "Temporal: " + (demoVal || "<= 14 days"); }

                    tokens.push({
                        "code": code,
                        "display": desc.trim(),
                        "is_demographic": true
                    });
                } else {
                    if (valCode && valCode.coding)
                    {
                        var codings = valCode.coding;
                        for (var j = 0; j < codings.length; j++)
                        {
                            var coding = codings[j];
                            var codeVal = coding.code || "";
                            if (codeVal && codeVal.indexOf("[HPO_CODE_FOR_") !== 0 && codeVal.indexOf("[ICD10_CODE_FOR_") !== 0 && codeVal.indexOf("[OPS_CODE_FOR_") !== 0 && codeVal.indexOf("[ATC_CODE_FOR_") !== 0)
                            {
                                tokens.push({
                                    "code": codeVal,
                                    "display": coding.display || codeVal,
                                    "is_modifier": (coding.is_modifier === true || coding.is_modifier === 1)
                                });
                            }
                            else
                            {
                                var fallbackCode = isDiag ? @"ICD10:U99" : (isProc ? @"OPS:9-999" : (isMed ? @"ATC:V03AX" : @"HP:0000118"));
                                tokens.push({
                                    "code": fallbackCode,
                                    "display": coding.display || @"Symptom"
                                });
                            }
                        }
                    }
                }
                [subNode setHpoTokens:tokens];
                if (tokens.length > 0)
                {
                    [subNode setSymptomText:tokens[0].display];
                }

                [subNode updateCriteriaAndDisplayValues];
                [subrows addObject:subNode];
            }
        }
        [node setSubrows:subrows];
    }
    else
    {
        [node setRowType:CPRuleEditorRowTypeSimple];
        
        var isDiag  = false;
        var isDemo  = false;
        var isProc  = false;
        var isMed   = false;
        var isLoinc = false;

        if (group.code && group.code.coding && group.code.coding.length > 0)
        {
            var codeVal = group.code.coding[0].code;
            if (codeVal === "2931005") {
                isDiag = true;
            } else if (codeVal === "71388002") {
                isProc = true;
            } else if (codeVal === "410942007") {
                isMed = true;
            } else if (codeVal === "30525-0" || codeVal === "76689-9" || codeVal === "LP7753-9" || codeVal === "21889-1" || codeVal === "temporal-constraint" || group.relativeTime) {
                isDemo = true;
            }
        }
        var valCode = group.valueCodeableConcept;
        if (!isDiag && !isDemo && !isProc && !isMed && valCode && valCode.coding && valCode.coding.length > 0)
        {
            var codeVal = valCode.coding[0].code || "";
            if (codeVal.indexOf("ICD10:") === 0) {
                isDiag = true;
            } else if (codeVal.indexOf("OPS:") === 0) {
                isProc = true;
            } else if (codeVal.indexOf("ATC:") === 0) {
                isMed = true;
            } else if (codeVal.indexOf("LOINC:") === 0) {
                isLoinc = true;
            }
        }
        [node setIsDiagnosis:isDiag];
        [node setIsDemographic:isDemo];
        [node setIsProcedure:isProc];
        [node setIsMedication:isMed];
        [node setIsLoinc:isLoinc];

        var isExclude = (group.exclude === true);
        var presenceMode = @"all-present";
        if (isExclude || group.combinationMethod === "neither-of")
        {
            presenceMode = @"neither-present";
        }
        else if (group.combinationMethod === "any-of")
        {
            presenceMode = @"any-present";
        }
        [node setPresenceMode:presenceMode];

        var tokens = [];
        
        if (group.relativeTime && group.relativeTime.length > 0) {
            for (var r = 0; r < group.relativeTime.length; r++) {
                var rt = group.relativeTime[r];
                var offset = rt.offsetDuration;
                if (offset) {
                    var comp = offset.comparator || "<=";
                    var val  = offset.value || "";
                    var unit = offset.unit || "days";
                    tokens.push({
                        "code": "temporal-constraint",
                        "display": "Temporal: " + comp + " " + val + " " + unit,
                        "is_demographic": true
                    });
                }
            }
        }
        
        if (isDemo && (!group.relativeTime)) {
            var demoVal = "";
            if (group.valueQuantity) {
                var comp = group.valueQuantity.comparator || ">=";
                var val  = group.valueQuantity.value;
                var unit = group.valueQuantity.unit || "";
                demoVal = comp + " " + val + (unit ? " " + unit : "");
            } else if (valCode && valCode.coding && valCode.coding.length > 0) {
                demoVal = valCode.coding[0].code || valCode.coding[0].display || "";
            }

            var code = (group.code && group.code.coding && group.code.coding.length > 0) ? group.code.coding[0].code : "30525-0";
            var desc = "";

            if (code === "30525-0") { desc = "Age: " + (demoVal || ">= 18 years"); }
            else if (code === "76689-9") { desc = "Sex: " + (demoVal || "FEMALE"); }
            else if (code === "LP7753-9" || code === "21889-1") { desc = "Measurement: " + (demoVal || "< 3 mm"); }
            else if (code === "temporal-constraint") { desc = "Temporal: " + (demoVal || "<= 14 days"); }

            tokens.push({
                "code": code,
                "display": desc.trim(),
                "is_demographic": true
            });
        } else {
            if (valCode && valCode.coding)
            {
                var codings = valCode.coding;
                for (var j = 0; j < codings.length; j++)
                {
                    var coding = codings[j];
                    var codeVal = coding.code || "";
                    if (codeVal && codeVal.indexOf("[HPO_CODE_FOR_") !== 0 && codeVal.indexOf("[ICD10_CODE_FOR_") !== 0 && codeVal.indexOf("[OPS_CODE_FOR_") !== 0 && codeVal.indexOf("[ATC_CODE_FOR_") !== 0)
                    {
                        tokens.push({
                            "code": codeVal,
                            "display": coding.display || codeVal,
                            "is_modifier": (coding.is_modifier === true || coding.is_modifier === 1)
                        });
                    }
                    else
                    {
                        var fallbackCode = isDiag ? @"ICD10:U99" : (isProc ? @"OPS:9-999" : (isMed ? @"ATC:V03AX" : @"HP:0000118"));
                        tokens.push({
                            "code": fallbackCode,
                            "display": coding.display || @"Symptom"
                        });
                    }
                }
            }
        }
        [node setHpoTokens:tokens];
        if (tokens.length > 0)
        {
            [node setSymptomText:tokens[0].display];
        }

        [node updateCriteriaAndDisplayValues];
    }

    return node;
}

- (void)importFHIRGroup:(id)rootGroup
{
    if (!rootGroup) return;
    try
    {
        _isImportingJSON = YES;
        console.group("🔍 [CHECKPOINT 3] FHIR Group Import");
        console.log("1. Incoming rootGroup:", rootGroup);
        
        var resolvedGroup = [self resolveContainedReferencesInGroup:rootGroup];

        console.log("2. Resolved contained references:", resolvedGroup);

        var flattenedGroup = [self _flattenFHIRGroup:resolvedGroup];

        console.log("3. Flattened Group structure:", flattenedGroup);
        console.groupEnd();

        var rootNode = [self nodeFromFHIRGroup:flattenedGroup];

        var flatList = [CPMutableArray array];
        if (rootNode)
        {
            var combinationMethod = flattenedGroup.combinationMethod || "all-of";
            if (combinationMethod === "any-of")
            {
                [self flattenNode:rootNode depth:0 intoArray:flatList];
            }
            else
            {
                var children = [rootNode subrows];
                for (var i = 0; i < [children count]; i++)
                {
                    [self flattenNode:children[i] depth:0 intoArray:flatList];
                }
            }
        }

        var rootNodesProxy = [self mutableArrayValueForKey:@"rootNodes"];
        [rootNodesProxy removeAllObjects];
        [rootNodesProxy addObjectsFromArray:flatList];

        [self performSelector:@selector(_enableImporting) withObject:nil afterDelay:0];
    }
    catch (e)
    {
        console.error("[FHIR Error] Exception in structural reconstruction: ", e);
        _isImportingJSON = NO;
    }
}

- (void)_enableImporting
{
    _isImportingJSON = NO;
    [_ruleEditor setNeedsLayout];
    [_ruleEditor setNeedsDisplay:YES];
    [[_ruleEditor superview] setNeedsLayout];
}

- (CPMutableDictionary)compileGroupFromFlatNodes:(CPArray)flatNodes
{
    if ([flatNodes count] === 0) return [CPMutableDictionary dictionary];

    var pseudoRoot = [[FHIRCriteriaNode alloc] init];
    [pseudoRoot setRowType:CPRuleEditorRowTypeCompound];
    [pseudoRoot setCombinationMethod:@"all-of"];

    var stack = [pseudoRoot];

    for (var i = 0; i < [flatNodes count]; i++)
    {
        var node = flatNodes[i];
        [[node subrows] removeAllObjects];

        var depth = [node indentation];

        while (stack.length > depth + 1)
        {
            stack.pop();
        }

        var parent = stack[stack.length - 1];
        [[parent subrows] addObject:node];
        stack.push(node);
    }

    var containedArray = [CPMutableArray array];
    var subgroupCounter = { value: 0 };
    var rootGroup = [self compileGroupFromNode:pseudoRoot containedArray:containedArray subgroupCounter:subgroupCounter];

    [rootGroup setObject:@"Group" forKey:@"resourceType"];
    [rootGroup setObject:@"eligibility-criteria" forKey:@"id"];
    [rootGroup setObject:@"active" forKey:@"status"];
    [rootGroup setObject:@"definitional" forKey:@"membership"];
    [rootGroup setObject:@"person" forKey:@"type"];

    var rootCombMethod = "all-of";
    if ([flatNodes count] === 1 && [[flatNodes objectAtIndex:0] rowType] == CPRuleEditorRowTypeCompound)
    {
        rootCombMethod = [[flatNodes objectAtIndex:0] combinationMethod] || "all-of";
    }
    [rootGroup setObject:rootCombMethod forKey:@"combinationMethod"];

    if ([containedArray count] > 0)
    {
        [rootGroup setObject:containedArray forKey:@"contained"];
    }

    return rootGroup;
}

- (CPMutableDictionary)compileGroupFromNode:(FHIRCriteriaNode)node containedArray:(CPMutableArray)containedArray subgroupCounter:(id)subgroupCounter
{
    var group = [CPMutableDictionary dictionary];
    [group setObject:@"Group" forKey:@"resourceType"];

    var subrows = [node subrows] || [];
    var characteristics = [CPMutableArray array];

    for (var i = 0; i < [subrows count]; i++)
    {
        var childNode = subrows[i];

        if ([childNode rowType] === CPRuleEditorRowTypeCompound)
        {
            subgroupCounter.value = subgroupCounter.value + 1;
            var subgroupID = "subgroup-" + subgroupCounter.value;

            var subGroup = [self compileGroupFromNode:childNode containedArray:containedArray subgroupCounter:subgroupCounter];
            [subGroup setObject:subgroupID forKey:@"id"];
            [subGroup setObject:@"conceptual" forKey:@"membership"];
            [subGroup setObject:@"person" forKey:@"type"];
            [subGroup setObject:[childNode combinationMethod] forKey:@"combinationMethod"];

            [containedArray addObject:subGroup];

            var refCharacteristic = [CPMutableDictionary dictionary];
            [refCharacteristic setObject:{ "text": @"Logical subgroup" } forKey:@"code"];
            [refCharacteristic setObject:{ "reference": "#" + subgroupID } forKey:@"valueReference"];
            [refCharacteristic setObject:NO forKey:@"exclude"];

            [characteristics addObject:refCharacteristic];
        }
        else
        {
            var tokenField = [childNode tokenField];
            var tokens = tokenField ? [tokenField objectValue] : [];

            if (tokens.length > 1)
            {
                subgroupCounter.value = subgroupCounter.value + 1;
                var compositeID = "composite-symptom-" + subgroupCounter.value;

                var subGroup = [CPMutableDictionary dictionary];
                [subGroup setObject:@"Group" forKey:@"resourceType"];
                [subGroup setObject:compositeID forKey:@"id"];
                [subGroup setObject:@"conceptual" forKey:@"membership"];
                [subGroup setObject:@"person" forKey:@"type"];

                var subCombMethod = @"all-of";
                if ([[childNode presenceMode] isEqualToString:@"any-present"]) {
                    subCombMethod = @"any-of";
                }
                [subGroup setObject:subCombMethod forKey:@"combinationMethod"];

                var subCharacteristics = [CPMutableArray array];
                var isExclude = [[childNode presenceMode] isEqualToString:@"neither-present"];

                var clinicalTokens = [];
                var relativeTimeArray = null;

                for (var k = 0; k < tokens.length; k++)
                {
                    var tok = tokens[k];
                    if (tok.code === "temporal-constraint") {
                        var comp = "<=";
                        var valNum = 180;
                        var unit = "days";
                        var cleanLabel = tok.display.replace("Temporal: ", "");
                        var match = cleanLabel.match(/([<>]=?|=)?\s*(\d+)\s*(\w+)/);
                        if (match) {
                            comp = match[1] || "<=";
                            valNum = parseInt(match[2], 10);
                            unit = match[3] || "days";
                        }
                        
                        relativeTimeArray = [{
                            "contextCode": {
                                "coding": [{
                                    "system": "http://hl7.org/fhir/relative-time-context",
                                    "code": "event",
                                    "display": "Event"
                                }]
                            },
                            "offsetDuration": {
                                "value": valNum,
                                "comparator": comp,
                                "unit": unit,
                                "system": "http://unitsofmeasure.org",
                                "code": unit.substring(0, 1)
                            }
                        }];
                    } else {
                        clinicalTokens.push(tok);
                    }
                }

                for (var k = 0; k < clinicalTokens.length; k++)
                {
                    var tok = clinicalTokens[k];
                    var subCharItem = [CPMutableDictionary dictionary];
                    
                    var charSnomedCode = "8116006";
                    var charSnomedDisplay = "Phänotypisches Merkmal";
                    var system = "http://purl.obolibrary.org/obo/hp.owl";

                    if ([childNode isDiagnosis] || tok.code.indexOf("ICD10:") === 0) {
                        charSnomedCode = "2931005";
                        charSnomedDisplay = "Diagnose";
                        system = "http://hl7.org/fhir/sid/icd-10";
                    }
                    else if ([childNode isProcedure] || tok.code.indexOf("OPS:") === 0) {
                        charSnomedCode = "71388002";
                        charSnomedDisplay = "Prozedur (OPS)";
                        system = "http://fhir.de/CodeSystem/bfarm/ops";
                    }
                    else if ([childNode isMedication] || tok.code.indexOf("ATC:") === 0) {
                        charSnomedCode = "410942007";
                        charSnomedDisplay = "Medikament (ATC)";
                        system = "http://www.whocc.no/atc";
                    }
                    else if ([childNode isLoinc] || tok.code.indexOf("LOINC:") === 0) {
                        charSnomedCode = "8116006";
                        charSnomedDisplay = "Phänotypisches Merkmal";
                        system = "http://loinc.org";
                    }

                    [subCharItem setObject:{
                        "coding": [
                                   {
                                       "system": "http://snomed.info/sct",
                                       "code": charSnomedCode,
                                       "display": charSnomedDisplay
                                   }
                                   ]
                    } forKey:@"code"];

                    var codings = [{
                        "system": system,
                        "code": tok.code,
                        "display": tok.display,
                        "is_modifier": tok.is_modifier ? true : false
                    }];

                    [subCharItem setObject:{"coding": codings} forKey:@"valueCodeableConcept"];
                    [subCharItem setObject:isExclude forKey:@"exclude"];

                    var itemComb = isExclude ? @"neither-of" : @"all-of";
                    [subCharItem setObject:itemComb forKey:@"combinationMethod"];

                    if (relativeTimeArray) {
                        [subCharItem setObject:relativeTimeArray forKey:@"relativeTime"];
                    }

                    [subCharacteristics addObject:subCharItem];
                }
                [subGroup setObject:subCharacteristics forKey:@"characteristic"];
                [containedArray addObject:subGroup];

                var refCharacteristic = [CPMutableDictionary dictionary];
                [refCharacteristic setObject:{"text": "Composite Logical subgroup"} forKey:@"code"];
                [refCharacteristic setObject:{"reference": "#" + compositeID} forKey:@"valueReference"];
                [refCharacteristic setObject:isExclude forKey:@"exclude"];

                [characteristics addObject:refCharacteristic];
            }
            else
            {
                if ([childNode isDemographic])
                {
                    var charItem = [CPMutableDictionary dictionary];
                    var tok = (tokens && tokens.length > 0) ? tokens[0] : nil;
                    var codeVal = tok ? tok.code : "LP7753-9";
                    var displayVal = tok ? tok.display : "Measurement: < 3 mm";

                    var isExclude = [[childNode presenceMode] isEqualToString:@"neither-present"];
                    [charItem setObject:isExclude forKey:@"exclude"];

                    if (codeVal === "30525-0") {
                        [charItem setObject:{
                            "coding": [{ "system": "http://loinc.org", "code": "30525-0", "display": "Age Constraint" }]
                        } forKey:@"code"];
                        var comp = ">="; var valNum = 18;
                        var match = displayVal.replace("Age: ", "").match(/([<>]=?|=)\s*(\d+)/);
                        if (match) { comp = match[1]; valNum = parseInt(match[2], 10); }
                        [charItem setObject:{ "comparator": comp, "value": valNum, "unit": "years", "system": "http://unitsofmeasure.org", "code": "a" } forKey:@"valueQuantity"];

                    } else if (codeVal === "76689-9") {
                        [charItem setObject:{
                            "coding": [{ "system": "http://loinc.org", "code": "76689-9", "display": "Sex Constraint" }]
                        } forKey:@"code"];
                        
                        var cleanSex = displayVal.replace("Sex: ", "").trim().toUpperCase();
                        var finalSex = "MALE";
                        
                        // Check for explicit dual-sex combinations first
                        if (cleanSex.indexOf("MALE_OR_FEMALE") !== -1 ||
                            cleanSex.indexOf("BOTH") !== -1 ||
                            (cleanSex.indexOf("MALE") !== -1 && cleanSex.indexOf("FEMALE") !== -1))
                        {
                            finalSex = "MALE_OR_FEMALE";
                        }
                        // Only set FEMALE if MALE is not part of the string
                        else if (cleanSex === "FEMALE" || (cleanSex.indexOf("FEMALE") !== -1 && cleanSex.indexOf("MALE") === -1))
                        {
                            finalSex = "FEMALE";
                        }
                        
                        [charItem setObject:{ "coding": [{ "system": "http://loinc.org", "code": finalSex, "display": finalSex }] } forKey:@"valueCodeableConcept"];
                    } else if (codeVal === "temporal-constraint" || codeVal === "performed-time" || displayVal.indexOf("Temporal:") === 0 || displayVal.indexOf("Performed:") === 0) {
                        [charItem setObject:{
                            "coding": [{ "system": "http://loinc.org", "code": "temporal-constraint", "display": "Temporal Timeframe Constraint" }]
                        } forKey:@"code"];

                        var comp = "<=";
                        var valNum = 180;
                        var unit = "days";
                        var cleanLabel = displayVal.replace("Temporal: ", "").replace("Performed: ", "");
                        var match = cleanLabel.match(/([<>]=?|=)?\s*(\d+)\s*(\w+)/);
                        if (match) {
                            comp = match[1] || "<=";
                            valNum = parseInt(match[2], 10);
                            unit = match[3] || "days";
                        }

                        [charItem setObject:[{
                            "contextCode": {
                                "coding": [{
                                    "system": "http://hl7.org/fhir/relative-time-context",
                                    "code": "event",
                                    "display": "Event"
                                }]
                            },
                            "offsetDuration": {
                                "value": valNum,
                                "comparator": comp,
                                "unit": unit,
                                "system": "http://unitsofmeasure.org",
                                "code": unit.substring(0, 1)
                            }
                        }] forKey:@"relativeTime"];

                    } else { // Mandatory fallback for LP7753-9, 21889-1, or ANY custom quantitative measurement code
                        [charItem setObject:{
                            "coding": [{ "system": "http://loinc.org", "code": "LP7753-9", "display": "Quantitative Measurement (Qn)" }]
                        } forKey:@"code"];

                        var comp = "?";
                        var valNum = 0.0;
                        var unit = "??";
                        var cleanLabel = displayVal.replace("Measurement: ", "");
                        var match = cleanLabel.match(/([<>]=?|=)?\s*(\d+(?:\.\d+)?)\s*([a-zA-Zµ%°\/]+)?/);
                        if (match) {
                            comp = match[1] || "<=";
                            valNum = parseFloat(match[2]);
                            unit = match[3] || "mm";
                        }

                        [charItem setObject:{
                            "comparator": comp,
                            "value": valNum,
                            "unit": unit,
                            "system": "http://unitsofmeasure.org",
                            "code": unit
                        } forKey:@"valueQuantity"];
                    }

                    var combMethod = isExclude ? "neither-of" : "all-of";
                    [charItem setObject:combMethod forKey:@"combinationMethod"];
                    [characteristics addObject:charItem];
                }
                else if ([childNode isLoinc])
                {
                    var tok = tokens.length > 0 ? tokens[0] : nil;
                    var loincCode = tok ? tok.code : "LOINC:29003-1";
                    var loincDisplay = tok ? tok.display : "Right eye Tear secretion 1 Schirmer test";

                    var charItem = [CPMutableDictionary dictionary];
                    [charItem setObject:{
                        "coding": [{ "system": "http://snomed.info/sct", "code": "8116006", "display": "Phänotypisches Merkmal" }]
                    } forKey:@"code"];

                    [charItem setObject:{
                        "coding": [{ "system": "http://loinc.org", "code": loincCode, "display": loincDisplay, "is_modifier": false }]
                    } forKey:@"valueCodeableConcept"];

                    var isExclude = [[childNode presenceMode] isEqualToString:@"neither-present"];
                    [charItem setObject:isExclude forKey:@"exclude"];
                    [charItem setObject:(isExclude ? "neither-of" : "all-of") forKey:@"combinationMethod"];

                    [characteristics addObject:charItem];
                }
                else
                {
                    var codings = [];
                    var charSnomedCode = "8116006";
                    var charSnomedDisplay = "Phänotypisches Merkmal";

                    if (tokens.length > 0)
                    {
                        var tok = tokens[0];
                        if (tok && tok.code)
                        {
                            var system = "http://purl.obolibrary.org/obo/hp.owl";
                            if ([childNode isDiagnosis] || tok.code.indexOf("ICD10:") === 0) {
                                charSnomedCode = "2931005";
                                charSnomedDisplay = "Diagnose";
                                system = "http://hl7.org/fhir/sid/icd-10";
                            }
                            else if ([childNode isProcedure] || tok.code.indexOf("OPS:") === 0) {
                                charSnomedCode = "71388002";
                                charSnomedDisplay = "Prozedur (OPS)";
                                system = "http://fhir.de/CodeSystem/bfarm/ops";
                            }
                            else if ([childNode isMedication] || tok.code.indexOf("ATC:") === 0) {
                                charSnomedCode = "410942007";
                                charSnomedDisplay = "Medikament (ATC)";
                                system = "http://www.whocc.no/atc";
                            }
                            codings.push({
                                "system": system,
                                "code": tok.code,
                                "display": tok.display,
                                "is_modifier": tok.is_modifier ? true : false
                            });
                        }
                    }
                    else
                    {
                        var rawText = [childNode symptomText] || @"";
                        var clinicalTerm = [rawText stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]];
                        var hpoTermName = [clinicalTerm isEqualToString:@""] ? @"UNDEFINED" : clinicalTerm;

                        var formattedTerm = hpoTermName.toUpperCase().replace(/\s+/g, '_');
                        var hpoCodePlaceholder = [childNode isDiagnosis] ? "[ICD10_CODE_FOR_" + formattedTerm + "]" : "[HPO_CODE_FOR_" + formattedTerm + "]";

                        if ([childNode isDiagnosis]) {
                            charSnomedCode = "2931005";
                            charSnomedDisplay = "Diagnose";
                            codings.push({
                                "system": "http://hl7.org/fhir/sid/icd-10",
                                "code": hpoCodePlaceholder,
                                "display": hpoTermName
                            });
                        } else {
                            codings.push({
                                "system": "http://purl.obolibrary.org/obo/hp.owl",
                                "code": hpoCodePlaceholder,
                                "display": hpoTermName
                            });
                        }
                    }

                    var charItem = [CPMutableDictionary dictionary];
                    [charItem setObject:{
                        "coding": [{
                            "system": "http://snomed.info/sct",
                            "code": charSnomedCode,
                            "display": charSnomedDisplay
                        }]
                    } forKey:@"code"];

                    [charItem setObject:{"coding": codings} forKey:@"valueCodeableConcept"];

                    var isExclude = [[childNode presenceMode] isEqualToString:@"neither-present"];
                    [charItem setObject:isExclude forKey:@"exclude"];

                    var combMethod = isExclude ? "neither-of" : "all-of";
                    [charItem setObject:combMethod forKey:@"combinationMethod"];

                    [characteristics addObject:charItem];
                }
            }
        }
    }
    [group setObject:characteristics forKey:@"characteristic"];
    return group;
}

- (BOOL)_groupContainsExclusions:(id)group
{
    if (!group || typeof group !== 'object') return NO;

    var characteristics = group.characteristic || [];
    
    for (var i = 0; i < characteristics.length; i++)
    {
        var charItem = characteristics[i];
        if (!charItem || typeof charItem !== 'object') continue;

        if (charItem.exclude === true || charItem.combinationMethod === "neither-of")
            return YES;

        var isSubgroup = (charItem.resourceType === "Group" || (charItem.characteristic && charItem.characteristic.length > 0));
        if (isSubgroup)
        {
            if ([self _groupContainsExclusions:charItem])
                return YES;
        }
    }
    return NO;
}

- (id)_flattenFHIRGroup:(id)group
{
    if (!group || typeof group !== 'object') return group;

    var flattenedCharacteristics = [];
    var characteristics = group.characteristic || [];

    for (var i = 0; i < characteristics.length; i++)
    {
        var charItem = characteristics[i];
        if (!charItem || typeof charItem !== 'object') continue;

        var isSubgroup = (charItem.resourceType === "Group" || (charItem.characteristic && charItem.characteristic.length > 0));
        if (isSubgroup)
        {
            var flattenedSubgroup = [self _flattenFHIRGroup:charItem];
            if (!flattenedSubgroup || typeof flattenedSubgroup !== 'object') continue;

            var isComposite = NO;
            if (flattenedSubgroup.id && (flattenedSubgroup.id.indexOf("composite-") === 0 || flattenedSubgroup.id.indexOf("subgroup-") === 0))
            {
                isComposite = YES;
            }
            else
            {
                var subChars = flattenedSubgroup.characteristic || [];
                var hasNested = NO;
                var hasLOINCMeasurement = NO;

                for (var k = 0; k < subChars.length; k++)
                {
                    var cItem = subChars[k];
                    if (!cItem || typeof cItem !== 'object') continue;

                    if (cItem.resourceType === "Group" || cItem.characteristic || cItem.combinationMethod)
                    {
                        hasNested = YES;
                    }
                    if (cItem.code && cItem.code.coding && cItem.code.coding.length > 0 && cItem.code.coding[0].code === "LP7753-9")
                    {
                        hasLOINCMeasurement = YES;
                    }
                }

                if (!hasNested && subChars.length > 0)
                {
                    isComposite = YES;
                }
                if (hasLOINCMeasurement)
                {
                    isComposite = YES; // Schützt Messungen mit Threshold vor dem Zerfallen
                }
            }

            var shouldFlatten = !isComposite &&
                (flattenedSubgroup.combinationMethod === group.combinationMethod) &&
                ![self _groupContainsExclusions:flattenedSubgroup];

            if (shouldFlatten)
            {
                var subCharacteristics = flattenedSubgroup.characteristic || [];
                for (var j = 0; j < subCharacteristics.length; j++)
                {
                    if (subCharacteristics[j] && typeof subCharacteristics[j] === 'object') {
                        flattenedCharacteristics.push(subCharacteristics[j]);
                    }
                }
            }
            else
            {
                flattenedCharacteristics.push(flattenedSubgroup);
            }
        }
        else
        {
            flattenedCharacteristics.push(charItem);
        }
    }

    group.characteristic = flattenedCharacteristics;
    return group;
}

// --------------------------------------------------------------------------------
// Tab 1 & Tab 2: HPO Browser Data Source & Search Operations
// --------------------------------------------------------------------------------

- (int)numberOfRowsInTableView:(CPTableView)tableView
{
    if (tableView === _tasksTable) return _tasksData ? [_tasksData count] : 0;
    if (tableView === synonymsTableView) return [_synonyms count];
    if (tableView === xrefsTableView) return [_xrefs count];
    if (tableView === downstreamTableView) return [_downstreamTerms count];
    if (tableView === _crossmatchTableView) return [_crossmatchResults count];
    if (tableView === _patientCrossmatchTableView) return [_patientCrossmatchResults count];
    if (tableView === _phenoVisualTableView) return [_phenoVisualItems count];
    if (tableView === _timeToEventTableView) return [_timeToEventResults count];
    if (tableView === _chatPatientsTableView) return _chatFoundPatients ? [_chatFoundPatients count] : 0;
    if (tableView === _tasksTable) return _tasksData ? [_tasksData count] : 0;

    return 0;
}

- (id)tableView:(CPTableView)tableView objectValueForTableColumn:(CPTableColumn)tableColumn row:(int)row
{
    if (tableView === _chatPatientsTableView) {
        if (row >= [_chatFoundPatients count]) return nil;
        var ident = [tableColumn identifier];
        if ([ident isEqualToString:@"index"]) {
            return (row + 1) + "";
        }
        return [_chatFoundPatients objectAtIndex:row];
    }
    if (tableView === _tasksTable) {
        if (row >= [_tasksData count]) return nil;
        var task = _tasksData[row];
        if ([[tableColumn identifier] isEqualToString:@"name"])
            return task.name;
        if ([[tableColumn identifier] isEqualToString:@"status"])
            return task;
    }
    if (tableView === synonymsTableView) {
        return (row < [_synonyms count]) ? _synonyms[row].label : nil;
    }
    if (tableView === xrefsTableView) {
        return (row < [_xrefs count]) ? _xrefs[row].label : nil;
    }
    if (tableView === downstreamTableView) {
        if (row >= [_downstreamTerms count]) return nil;
        var term = _downstreamTerms[row];
        if ([tableColumn identifier] === @"id") {
            return term.id;
        } else if ([tableColumn identifier] === @"label") {
            return term.label;
        }
    }

    if (tableView === _phenoVisualTableView)
    {
        if (row >= [_phenoVisualItems count]) return nil;
        var item = _phenoVisualItems[row];
        var ident = [tableColumn identifier];

        if (ident === @"category") {
            return item.category;
        }
        if (ident === @"code") {
            return item.code;
        }
        if (ident === @"status") {
            return item.excluded ? @"🔴 Excluded" : @"🟢 Observed";
        }
        if (ident === @"label") {
            var tokens = [];
            if (item.code) {
                tokens.push({
                    "code": item.code,
                    "display": item.label,
                    "is_modifier": NO,
                    "is_demographic": (item.category === "Demographics"),
                    "is_procedure": (item.category === "Procedure"),
                    "is_medication": (item.category === "Medication")
                });
            }
            var modifiers = item.modifiers || [];
            for (var m = 0; m < modifiers.length; m++) {
                tokens.push(modifiers[m]);
            }
            return tokens;
        }
    }

    if (tableView === _crossmatchTableView || tableView === _patientCrossmatchTableView) {
        var results = (tableView === _patientCrossmatchTableView) ? _patientCrossmatchResults : _crossmatchResults;
        if (row >= [results count]) return nil;
        var item = results[row];
        var ident = [tableColumn identifier];

        if (ident === @"status") {
            if (item.status === "inclusion_met") return "🟢 Satisfied";
            if (item.status === "exclusion_violation") return "🔴 Violated (Excluded)";
            if (item.status === "inclusion_missing") return "🟡 Missing (Unmet)";
            if (item.status === "potentially_eligible") {
                return item.is_exclusion ? "🟠 Potentially Ineligible (Check modifier)" : "🟡 Potentially Eligible (Missing modifier)";
            }
            if (item.status === "exclusion_clear") return "⚪ Clear (No Info)";
            return "⚪ Unknown";
        }
        if (ident === @"type") {
            return item.is_exclusion ? @"Exclusion" : @"Inclusion";
        }
        if (ident === @"criterion") {
            var indentPrefix = "";
            var depth = item.indentation || 0;
            for (var i = 0; i < depth; i++) {
                indentPrefix += "    ";
            }
            
            var displayVal = item.criterion_label || "";
            if (item.criterion_code) {
                displayVal += " (" + item.criterion_code + ")";
            }
            return indentPrefix + displayVal;
        }
        if (ident === @"evidence") {
            if (item.matched_patient_label) {
                return item.matched_patient_label;
            }
            return "-";
        }
    }

    if (tableView === _timeToEventTableView) {
        if (row >= [_timeToEventResults count]) return nil;
        var item = _timeToEventResults[row];
        var ident = [tableColumn identifier];

        if (ident === @"piz") return item.piz;
        if (ident === @"status") return (item.event == 1) ? @"🟢 Eligible" : @"⚪ Censored";
        if (ident === @"event") return item.event;
        if (ident === @"time_days") return item.time_days + @" d";
        if (ident === @"study_eye") return item.study_eye ? item.study_eye : @"none";
        if (ident === @"baseline_date") return item.baseline_date;
        if (ident === @"event_date") return item.event_date || @"-";
        if (ident === @"total_briefe_evaluated") return item.total_briefe_evaluated;
    }
    return nil;
}

// --------------------------------------------------------------------------------
// View-Based Table View Delegate (Modifiers Programmatic Editing and Custom Cells)
// --------------------------------------------------------------------------------

- (CPView)tableView:(CPTableView)aTableView viewForTableColumn:(CPTableColumn)tableColumn row:(CPInteger)row
{
    var identifier = [tableColumn identifier];

    if (aTableView === _tasksTable)
    {
        if (row >= [_tasksData count])
            return nil;

        var task = _tasksData[row];
        if (identifier === @"name")
        {
            var cellView = [aTableView makeViewWithIdentifier:@"taskNameCell" owner:self];
            if (!cellView) {
                cellView = [[CPTextField alloc] initWithFrame:CGRectMake(0, 0, [tableColumn width], 24)];
                [cellView setIdentifier:@"taskNameCell"];
                [cellView setEditable:NO];
                [cellView setBezeled:NO];
                [cellView setFont:[CPFont systemFontOfSize:11.0]];
            }
            [cellView setStringValue:task.name];
            return cellView;
        }
        else if (identifier === @"status")
        {
            var cellView = [aTableView makeViewWithIdentifier:@"taskStatusCell" owner:self];
            if (!cellView) {
                cellView = [[HPOJobStatusView alloc] initWithFrame:CGRectMake(0, 0, [tableColumn width], 28)];
                [cellView setIdentifier:@"taskStatusCell"];
            }
            [cellView setObjectValue:task];
            return cellView;
        }
    }
    else if (aTableView === _phenoVisualTableView)
    {
        if (row >= [_phenoVisualItems count])
            return nil;

        if (identifier === @"category")
        {
            var cellView = [aTableView makeViewWithIdentifier:@"categoryCell" owner:self];
            if (!cellView) {
                cellView = [[SelectionColorTextField alloc] initWithFrame:CGRectMake(0, 0, [tableColumn width], 24)];
                [cellView setIdentifier:@"categoryCell"];
                [cellView setEditable:NO];
                [cellView setBezeled:NO];
            }
            var item = _phenoVisualItems[row];
            [cellView setStringValue:item.category];
            return cellView;
        }
        else if (identifier === @"code")
        {
            var cellView = [aTableView makeViewWithIdentifier:@"codeCell" owner:self];
            if (!cellView) {
                cellView = [[SelectionColorTextField alloc] initWithFrame:CGRectMake(0, 0, [tableColumn width], 24)];
                [cellView setIdentifier:@"codeCell"];
                [cellView setEditable:NO];
                [cellView setBezeled:NO];
            }
            var item = _phenoVisualItems[row];
            [cellView setStringValue:item.code];
            return cellView;
        }
        else if (identifier === @"label")
        {
            var tokenField = [aTableView makeViewWithIdentifier:@"labelTokenFieldCell" owner:self];
            if (!tokenField) {
                tokenField = [[HPOTokenField alloc] initWithFrame:CGRectMake(0, 0, [tableColumn width], 24)];
                [tokenField setIdentifier:@"labelTokenFieldCell"];
                [tokenField setEditorController:self];
                [tokenField registerForDraggedTypes:[CPArray arrayWithObjects:@"HPOTermPboardType", nil]];
                [tokenField setEditable:YES];
                [tokenField setBezeled:NO];
                [tokenField setPlaceholderString:@"Add modifiers / codes..."];
                [tokenField setDelegate:self];
                [tokenField setTarget:self];
                [tokenField setAction:@selector(phenoVisualTokenFieldDidChange:)];
            }
            
            var item = _phenoVisualItems[row];
            tokenField.rowIndex = row;
            
            var tokens = [];
            if (item && item.code) {
                tokens.push({
                    "code": item.code,
                    "display": item.label,
                    "is_modifier": NO,
                    "is_demographic": (item.category === "Demographics"),
                    "is_procedure": (item.category === "Procedure"),
                    "is_medication": (item.category === "Medication")
                });
            }
            
            var modifiers = (item && item.modifiers) ? item.modifiers : [];
            for (var m = 0; m < modifiers.length; m++) {
                tokens.push(modifiers[m]);
            }
            
            [tokenField setObjectValue:tokens];
            return tokenField;
        }
        else if (identifier === @"status")
        {
            var cellView = [aTableView makeViewWithIdentifier:@"statusCell" owner:self];
            if (!cellView) {
                cellView = [[SelectionColorTextField alloc] initWithFrame:CGRectMake(0, 0, [tableColumn width], 24)];
                [cellView setIdentifier:@"statusCell"];
                [cellView setEditable:NO];
                [cellView setBezeled:NO];
            }
            var item = _phenoVisualItems[row];
            [cellView setStringValue:(item.excluded ? @"🔴 Excluded" : @"🟢 Observed")];
            return cellView;
        }
    }
    else if (aTableView === _crossmatchTableView || aTableView === _patientCrossmatchTableView)
    {
        var results = (aTableView === _patientCrossmatchTableView) ? _patientCrossmatchResults : _crossmatchResults;
        if (row >= [results count])
            return nil;

        var cellIdentifier = identifier + @"Cell";
        var cellView = [aTableView makeViewWithIdentifier:cellIdentifier owner:self];
        if (!cellView) {
            cellView = [[SelectionColorTextField alloc] initWithFrame:CGRectMake(0, 0, [tableColumn width], 24)];
            [cellView setIdentifier:cellIdentifier];
            [cellView setEditable:NO];
            [cellView setBezeled:NO];
        }

        var value = [self tableView:aTableView objectValueForTableColumn:tableColumn row:row];
        [cellView setStringValue:value || @""];
        return cellView;
    }
    else if (aTableView === _timeToEventTableView)
    {
        if (row >= [_timeToEventResults count])
            return nil;

        var cellIdentifier = identifier + @"TTECell";
        var cellView = [aTableView makeViewWithIdentifier:cellIdentifier owner:self];
        if (!cellView) {
            cellView = [[SelectionColorTextField alloc] initWithFrame:CGRectMake(0, 0, [tableColumn width], 24)];
            [cellView setIdentifier:cellIdentifier];
            [cellView setEditable:NO];
            [cellView setBezeled:NO];
        }

        var value = [self tableView:aTableView objectValueForTableColumn:tableColumn row:row];
        [cellView setStringValue:value || @""];
        return cellView;
    }
    else if (aTableView === _chatPatientsTableView)
        {
            if (row >= [_chatFoundPatients count])
                return nil;

            var cellIdentifier = identifier + @"ChatPatientCell";
            var cellView = [aTableView makeViewWithIdentifier:cellIdentifier owner:self];
            if (!cellView) {
                cellView = [[SelectionColorTextField alloc] initWithFrame:CGRectMake(0, 0, [tableColumn width], 24)];
                [cellView setIdentifier:cellIdentifier];
                [cellView setEditable:NO];
                [cellView setBezeled:NO];
            }

            var value = [self tableView:aTableView objectValueForTableColumn:tableColumn row:row];
            [cellView setStringValue:value || @""];
            return cellView;
        }

    return nil;
}

- (void)tableView:(CPTableView)aTableView willDisplayView:(id)aView forTableColumn:(CPTableColumn)aTableColumn row:(CPInteger)rowIndex
{
    if (aTableView === _phenoVisualTableView)
    {
        if (rowIndex >= [_phenoVisualItems count]) return;
        var item = _phenoVisualItems[rowIndex];
        var ident = [aTableColumn identifier];

        var defaultColor = [CPColor blackColor];

        if (ident === @"status")
        {
            if (item.excluded)
            {
                defaultColor = [CPColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:1.0];
            }
            else
            {
                defaultColor = [CPColor colorWithRed:0.0 green:0.6 blue:0.0 alpha:1.0];
            }
        }
        else if (ident === @"category")
        {
            if ([item.category isEqualToString:@"Phenotype"])
            {
                defaultColor = [CPColor colorWithRed:0.0 green:0.5 blue:0.7 alpha:1.0];
            }
            else if ([item.category isEqualToString:@"Demographics"] || [item.category isEqualToString:@"Procedure"] || [item.category isEqualToString:@"Medication"])
            {
                defaultColor = [CPColor colorWithRed:200/255.0 green:100/255.0 blue:0.0 alpha:1.0];
            }
            else
            {
                defaultColor = [CPColor colorWithRed:40/255.0 green:130/255.0 blue:80/255.0 alpha:1.0];
            }
        }
        if ([aView respondsToSelector:@selector(setUnselectedColor:)])
        {
            [aView setUnselectedColor:defaultColor];
        }
        else
        {
            [aView setTextColor:defaultColor];
        }
    }
    else if (aTableView === _crossmatchTableView || aTableView === _patientCrossmatchTableView)
    {
        var results = (aTableView === _patientCrossmatchTableView) ? _patientCrossmatchResults : _crossmatchResults;
        if (rowIndex >= [results count]) return;
        var item = results[rowIndex];
        var ident = [aTableColumn identifier];

        var defaultColor = [CPColor blackColor];

        if (ident === @"status")
        {
            if (item.status === "inclusion_met" || item.status === "exclusion_clear")
            {
                defaultColor = [CPColor colorWithRed:0.0 green:0.6 blue:0.0 alpha:1.0];
            }
            else if (item.status === "potentially_eligible")
            {
                defaultColor = [CPColor colorWithRed:0.75 green:0.55 blue:0.0 alpha:1.0];
            }
            else if (item.status === "exclusion_violation" || item.status === "inclusion_missing")
            {
                defaultColor = [CPColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:1.0];
            }
            else
            {
                defaultColor = [CPColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1.0];
            }
        }
        else
        {
            if (item.is_group)
            {
                [aView setFont:[CPFont boldSystemFontOfSize:11.0]];
                defaultColor = [CPColor colorWithRed:0.1 green:0.3 blue:0.5 alpha:1.0];
            }
            else
            {
                [aView setFont:[CPFont systemFontOfSize:11.0]];
                defaultColor = [CPColor blackColor];
            }
        }

        if ([aView respondsToSelector:@selector(setUnselectedColor:)])
        {
            [aView setUnselectedColor:defaultColor];
        }
        else
        {
            [aView setTextColor:defaultColor];
        }
    }
    else if (aTableView === _timeToEventTableView)
    {
        if (rowIndex >= [_timeToEventResults count]) return;
        var item = _timeToEventResults[rowIndex];
        var ident = [aTableColumn identifier];

        var defaultColor = [CPColor blackColor];

        if (ident === @"status")
        {
            if (item.event == 1) {
                defaultColor = [CPColor colorWithRed:0.0 green:0.6 blue:0.0 alpha:1.0];
            } else {
                defaultColor = [CPColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1.0];
            }
        }

        if ([aView respondsToSelector:@selector(setUnselectedColor:)]) {
            [aView setUnselectedColor:defaultColor];
        } else {
            [aView setTextColor:defaultColor];
        }
    }
}

- (void)tableView:(CPTableView)tableView sortDescriptorsDidChange:(CPArray)oldDescriptors
{
    var arrayToSort = nil;
    if (tableView === synonymsTableView) {
        arrayToSort = _synonyms;
    } else if (tableView === xrefsTableView) {
        arrayToSort = _xrefs;
    } else if (tableView === downstreamTableView) {
        arrayToSort = _downstreamTerms;
    } else if (tableView === _phenoVisualTableView) {
        arrayToSort = _phenoVisualItems;
    }

    if (!arrayToSort || [arrayToSort count] === 0)
        return;

    var descriptors = [tableView sortDescriptors];
    var mainDescriptor = [descriptors count] > 0 ? [descriptors objectAtIndex:0] : nil;
    if (!mainDescriptor) return;

    var key = [mainDescriptor key];
    var ascending = [mainDescriptor ascending];

    arrayToSort.sort(function(a, b) {
        var valA = a[key];
        var valB = b[key];

        if (valA === undefined) valA = "";
        if (valB === undefined) valB = "";

        if (valA < valB) return ascending ? -1 : 1;
        if (valA > valB) return ascending ? 1 : -1;
        return 0;
    });

    [tableView reloadData];
}

function formatHPOId(termId)
{
    if (!termId)
        return "";
    
    var strId = String(termId);
    
    if (strId.indexOf("HP:") === 0)
        return strId;
    
    var numericPart = parseInt(strId.replace(/\D/g, ""), 10);
    if (isNaN(numericPart)) return strId;
    return "HP:" + [CPString stringWithFormat:@"%07d", numericPart];
}

- (void)outlineViewSelectionDidChange:(CPNotification)notification
{
    var selectedRow = [outlineView selectedRow];

    if (selectedRow === -1) {
        _synonyms = [];
        _xrefs = [];
        _downstreamTerms = [];
        [definitionTextView setString:@""];

        [synonymsTableView reloadData];
        [xrefsTableView reloadData];
        [downstreamTableView reloadData];

        [_searchTokenField setObjectValue:[]];
        return;
    }

    var item = [outlineView itemAtRow:selectedRow];
    var node = item ? [item representedObject] : nil;
    if (!node) return;

    var formattedId = "";
    if ([node nodeType] === @"ICD-10")
    {
        formattedId = [node termId];
        if (![formattedId hasPrefix:@"KAP-"]) {
            formattedId = "ICD10:" + formattedId;
        }
        [definitionTextView setString:[node name] + " (" + formattedId + ")"];

        _synonyms = []; _xrefs = [];
        [synonymsTableView reloadData]; [xrefsTableView reloadData];
        [self fetchICD10DownstreamForNode:node];
    }
    else if ([node nodeType] === @"OPS")
    {
        formattedId = "OPS:" + [node termId];
        [definitionTextView setString:[node name] + " (" + formattedId + ")"];
        _synonyms = []; _xrefs = [];
        [synonymsTableView reloadData]; [xrefsTableView reloadData];
        [self fetchOPSDownstreamForNode:node];
    }
    else if ([node nodeType] === @"ATC")
    {
        formattedId = "ATC:" + [node termId];
        [definitionTextView setString:[node name] + " (" + formattedId + ")"];
        _synonyms = []; _xrefs = [];
        [synonymsTableView reloadData]; [xrefsTableView reloadData];
        [self fetchATCDownstreamForNode:node];
    }
    else if ([node nodeType] === @"LOINC")
    {
        formattedId = "LOINC:" + [node termId];
        [definitionTextView setString:[node name] + " (" + formattedId + ")"];
        _synonyms = []; _xrefs = [];
        [synonymsTableView reloadData]; [xrefsTableView reloadData];
        [self fetchLOINCDownstreamForNode:node];
    }
    else
    {
        formattedId = formatHPOId(node._termId);
        [definitionTextView setString:[node definition] + ' (' + formattedId + ')' || @"No definition available."];
        [self fetchDownstreamForNode:node];
        [self fetchSynonymsForNode:node];
        [self fetchXrefsForNode:node];
    }

    var termDict = { "code": formattedId, "display": [node name], "is_modifier": NO, "is_demographic": false };
    [_searchTokenField setObjectValue:[termDict]];
}

- (BOOL)outlineView:(CPOutlineView)anOutlineView shouldExpandItem:(id)anItem
{
    var node = anItem ? [anItem representedObject] : nil;
    if (!node || [node isLeaf]) return YES;

    if ([node hasLoadedChildren]) {
        [self syncTreeNode:anItem withModelChildren:[node children]];
        return YES;
    }

    var expandStartTime = [CPDate timeIntervalSinceReferenceDate];
    [node fetchChildrenWithCompletion:function(newChildren) {
        var elapsed = [CPDate timeIntervalSinceReferenceDate] - expandStartTime;
        var animationDuration = 0.25;
        var delay = MAX(0, animationDuration - elapsed + 0.05);

        setTimeout(function() {
            [self syncTreeNode:anItem withModelChildren:newChildren];
            [anOutlineView reloadItem:anItem reloadChildren:YES];
        }, delay * 1000);
    }];

    return YES;
}

// --------------------------------------------------------------------------------
// Outer Connection Handlers
// --------------------------------------------------------------------------------

- (void)fetchRoots
{
    var request = [CPURLRequest requestWithURL:"/BBB/hpo/roots"];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error) {
        if (!error && data) {
            var json = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            var roots = [CPMutableArray array];
            if (json && json.length) {
                for (var i = 0; i < json.length; i++) {
                    var node = [[HPONode alloc] initWithDict:json[i]];
                    [roots addObject:node];
                }
            }
            _allRoots = roots;
            [treeController setContent:_allRoots];
        } else {
            console.error("Failed to fetch HPO roots: " + error);
        }
    }];
}

- (void)fetchDownstreamForNode:(HPONode)node
{
    if (!node) return;
    var urlString = "/BBB/children/idparent/" + [node termId];
    var request = [CPURLRequest requestWithURL:urlString];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        if (!error && data) {
            var parsed = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            _downstreamTerms = (parsed && parsed.length) ? parsed : [];
        } else {
            _downstreamTerms = [];
        }
        [downstreamTableView reloadData];
    }];
}

- (void)fetchSynonymsForNode:(HPONode)node
{
    if (!node) return;
    var urlString = "/BBB/hpo/synonyms/" + [node termId];
    var request = [CPURLRequest requestWithURL:urlString];
    [CPURLConnection sendAsynchronousRequest:request queue:[CPOperationQueue mainQueue] completionHandler:function(response, data, error) {
        if (!error && data) {
            var parsed = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            _synonyms = (parsed && parsed.length) ? parsed : [];
        } else {
            _synonyms = [];
        }
        [synonymsTableView reloadData];
    }];
}

- (void)fetchXrefsForNode:(HPONode)node
{
    if (!node) return;
    var urlString = "/BBB/hpo/xrefs/" + [node termId];
    var request = [CPURLRequest requestWithURL:urlString];
    [CPURLConnection sendAsynchronousRequest:request queue:[CPOperationQueue mainQueue] completionHandler:function(response, data, error) {
        if (!error && data) {
            var parsed = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            _xrefs = (parsed && parsed.length) ? parsed : [];
        } else {
            _xrefs = [];
        }
        [xrefsTableView reloadData];
    }];
}

- (void)fetchLOINCRoots
{
    var request = [CPURLRequest requestWithURL:"/BBB/loinc/roots"];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error) {
        if (!error && data) {
            var json = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            var roots = [CPMutableArray array];
            if (json && json.length) {
                for (var i = 0; i < json.length; i++) {
                    var node = [[HPONode alloc] initWithDict:json[i] nodeType:@"LOINC"];
                    [roots addObject:node];
                }
            }
            _allRoots = roots;
            [treeController setContent:_allRoots];
        } else {
            console.error("Failed to fetch LOINC roots: " + error);
        }
    }];
}

- (void)fetchLOINCDownstreamForNode:(HPONode)node
{
    if (!node) return;
    var urlString = "/BBB/loinc/children/" + [node termId];
    var request = [CPURLRequest requestWithURL:urlString];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        if (!error && data) {
            var parsed = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            _downstreamTerms = [];
            if (parsed && parsed.length) {
                for (var i = 0; i < parsed.length; i++) {
                    _downstreamTerms.push({ id: parsed[i].id, label: parsed[i].label });
                }
            }
        } else {
            _downstreamTerms = [];
        }
        [downstreamTableView reloadData];
    }];
}

- (void)performLOINCSearchForString:(CPString)searchString
{
    if (!searchString || [searchString length] === 0) return;
    [_searchStatusLabel setStringValue:@"Searching..."];
    [self startPulsatingAnimation];

    var urlString = "/BBB/loinc/search/" + encodeURIComponent(searchString);
    var request = [CPURLRequest requestWithURL:urlString];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error) {
        [self stopPulsatingAnimation];
        if (!error && data) {
            var json = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [self expandAndSelectLOINCPaths:json];
        } else {
            [_searchStatusLabel setStringValue:@"Error"];
        }
    }];
}

- (void)resolveLOINCPath:(CPArray)nodeIds currentIndex:(int)index currentModels:(CPArray)models baseIndexPath:(CPIndexPath)indexPath completion:(Function)callback
{
    if (!nodeIds || index >= nodeIds.length) {
        callback(indexPath);
        return;
    }

    var targetId = nodeIds[index];
    var foundModelIndex = -1;
    var foundModel = nil;

    for (var i = 0; i < [models count]; i++) {
        if ([models[i] termId] === targetId) {
            foundModelIndex = i;
            foundModel = models[i];
            break;
        }
    }

    if (!foundModel) {
        callback(nil);
        return;
    }

    var nextIndexPath = indexPath ? [indexPath indexPathByAddingIndex:foundModelIndex] : [CPIndexPath indexPathWithIndex:foundModelIndex];

    if (index === nodeIds.length - 1) {
        callback(nextIndexPath);
    } else {
        [foundModel fetchChildrenWithCompletion:function(newChildren) {
            var treeNode = [[treeController arrangedObjects] descendantNodeAtIndexPath:nextIndexPath];
            if (treeNode) {
                [self syncTreeNode:treeNode withModelChildren:newChildren];
            }
            [self resolveLOINCPath:nodeIds currentIndex:(index + 1) currentModels:newChildren baseIndexPath:nextIndexPath completion:callback];
        }];
    }
}

- (void)expandAndSelectLOINCPaths:(CPArray)searchResults
{
    if (!searchResults || !searchResults.length)
    {
        [treeController setSelectionIndexPaths:[]];
        _matchedIndexPaths = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@"0 hits"];
        return;
    }

    var targetIndexPaths = [CPMutableArray array];
    var pendingPaths = searchResults.length;

    for (var i = 0; i < searchResults.length; i++)
    {
        var nodeIds = searchResults[i].path;
        [self resolveLOINCPath:nodeIds
                  currentIndex:0
                 currentModels:_allRoots
                 baseIndexPath:nil
                    completion:function(finalIndexPath) {
            if (finalIndexPath)
            {
                [targetIndexPaths addObject:finalIndexPath];
            }
            pendingPaths--;

            if (pendingPaths === 0)
            {
                _matchedIndexPaths = targetIndexPaths;
                _currentMatchIndex = 0;

                setTimeout(function() {
                    [self updateSelectionToCurrentMatch];
                }, 50);
            }
        }];
    }
}

// --------------------------------------------------------------------------------
// Search & Hierarchy Expansion Algorithms
// --------------------------------------------------------------------------------

- (void)searchForHPOTerm:(CPString)aCode
{
    if (!aCode || [aCode length] === 0) return;

    var isICD10 = [aCode hasPrefix:@"ICD10:"];
    var isHPO   = [aCode hasPrefix:@"HP:"];
    var isOps   = [aCode hasPrefix:@"OPS:"];
    var isAtc   = [aCode hasPrefix:@"ATC:"];
    var isLoinc = [aCode hasPrefix:@"LOINC:"];

    if (isICD10)
    {
        if (![_currentPickerType isEqualToString:@"ICD-10"])
        {
            [_pickerControl setSelectedSegment:1];
            [self pickerTypeChanged:_pickerControl];
        }

        var cleanCode = [aCode substringFromIndex:6];
        [_searchField setStringValue:cleanCode];
        [self performICD10SearchForString:cleanCode];
    }
    else if (isHPO)
    {
        if (![_currentPickerType isEqualToString:@"HPO"])
        {
            [_pickerControl setSelectedSegment:0];
            [self pickerTypeChanged:_pickerControl];
        }

        [_searchField setStringValue:aCode];
        [_nameOnlyCheckbox setState:CPOffState];
        [self performSearchForString:aCode isNameOnly:NO];
    }
    else if (isOps)
    {
        if (![_currentPickerType isEqualToString:@"OPS"])
        {
            [_pickerControl setSelectedSegment:2];
            [self pickerTypeChanged:_pickerControl];
        }
        var cleanCode = [aCode substringFromIndex:4];
        [_searchField setStringValue:cleanCode];
        [self performOPSSearchForString:cleanCode];
    }
    else if (isAtc)
    {
        if (![_currentPickerType isEqualToString:@"ATC"])
        {
            [_pickerControl setSelectedSegment:3];
            [self pickerTypeChanged:_pickerControl];
        }
        var cleanCode = [aCode substringFromIndex:4];
        [_searchField setStringValue:cleanCode];
        [self performATCSearchForString:cleanCode];
    }
    else if (isLoinc)
    {
        if (![_currentPickerType isEqualToString:@"LOINC"])
        {
            [_pickerControl setSelectedSegment:4];
            [self pickerTypeChanged:_pickerControl];
        }
        var cleanCode = [aCode substringFromIndex:6];
        [_searchField setStringValue:cleanCode];
        [self performLOINCSearchForString:cleanCode];
    }
}

- (void)searchAction:(id)sender
{
    var searchString = [sender stringValue];
    if (_currentPickerType === @"ICD-10")
    {
        [self performICD10SearchForString:searchString];
    }
    else if (_currentPickerType === @"OPS")
    {
        [self performOPSSearchForString:searchString];
    }
    else if (_currentPickerType === @"ATC")
    {
        [self performATCSearchForString:searchString];
    }
    else if (_currentPickerType === @"LOINC")
    {
        [self performLOINCSearchForString:searchString];
    }
    else
    {
        var isNameOnly = [_nameOnlyCheckbox state] === CPOnState;
        [self performSearchForString:searchString isNameOnly:isNameOnly];
    }
}

- (void)performSearchForString:(CPString)searchString isNameOnly:(BOOL)isNameOnly
{
    if (!searchString || [searchString length] === 0)
    {
        [treeController setSelectionIndexPaths:[]];
        _matchedIndexPaths = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@""];
        return;
    }

    [_searchStatusLabel setStringValue:@"Searching..."];
    [self startPulsatingAnimation];

    var urlString = "/BBB/hpo/search/" + encodeURIComponent(searchString) + "?nameOnly=" + (isNameOnly ? "1" : "0");
    var request = [CPURLRequest requestWithURL:urlString];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [self stopPulsatingAnimation];
        if (!error && data)
        {
            var json = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [self expandAndSelectPaths:json];
        }
        else
        {
            [_searchStatusLabel setStringValue:@"Error"];
        }
    }];
}

- (void)resolvePath:(CPArray)nodeIds currentIndex:(int)index currentModels:(CPArray)models baseIndexPath:(CPIndexPath)indexPath completion:(Function)callback
{
    if (!nodeIds || index >= nodeIds.length) {
        callback(indexPath);
        return;
    }

    var targetId = parseInt(nodeIds[index], 10);
    var foundModelIndex = -1;
    var foundModel = nil;

    for (var i = 0; i < [models count]; i++) {
        if ([models[i] termId] === targetId) {
            foundModelIndex = i;
            foundModel = models[i];
            break;
        }
    }

    if (!foundModel) {
        callback(nil);
        return;
    }

    var nextIndexPath = indexPath ? [indexPath indexPathByAddingIndex:foundModelIndex] : [CPIndexPath indexPathWithIndex:foundModelIndex];

    if (index === nodeIds.length - 1) {
        callback(nextIndexPath);
    } else {
        [foundModel fetchChildrenWithCompletion:function(newChildren) {
            var treeNode = [[treeController arrangedObjects] descendantNodeAtIndexPath:nextIndexPath];
            if (treeNode) {
                [self syncTreeNode:treeNode withModelChildren:newChildren];
            }
            [self resolvePath:nodeIds currentIndex:(index + 1) currentModels:newChildren baseIndexPath:nextIndexPath completion:callback];
        }];
    }
}

- (void)expandAndSelectPaths:(CPArray)searchResults
{
    if (!searchResults || !searchResults.length)
    {
        [treeController setSelectionIndexPaths:[]];
        _matchedIndexPaths = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@"0 hits"];
        return;
    }

    var targetIndexPaths = [CPMutableArray array];
    var pendingPaths = searchResults.length;

    for (var i = 0; i < searchResults.length; i++)
    {
        var nodeIds = searchResults[i].path;
        [self resolvePath:nodeIds
             currentIndex:0
            currentModels:_allRoots
            baseIndexPath:nil
               completion:function(finalIndexPath) {
            if (finalIndexPath)
            {
                [targetIndexPaths addObject:finalIndexPath];
            }
            pendingPaths--;

            if (pendingPaths === 0)
            {
                _matchedIndexPaths = targetIndexPaths;
                _currentMatchIndex = 0;

                setTimeout(function() {
                    [self updateSelectionToCurrentMatch];
                }, 50);
            }
        }];
    }
}

- (void)updateSelectionToCurrentMatch
{
    if (!_matchedIndexPaths || [_matchedIndexPaths count] === 0)
    {
        [_searchStatusLabel setStringValue:@"0 hits"];
        return;
    }

    var path = _matchedIndexPaths[_currentMatchIndex];
    var partialPath = [CPIndexPath indexPathWithIndex:[path indexAtPosition:0]];

    for (var level = 1; level < [path length]; level++)
    {
        var treeNode = [[treeController arrangedObjects] descendantNodeAtIndexPath:partialPath];
        if (treeNode)
            [outlineView expandItem:treeNode];

        partialPath = [partialPath indexPathByAddingIndex:[path indexAtPosition:level]];
    }

    [treeController setSelectionIndexPath:path];
    [_searchStatusLabel setStringValue:(_currentMatchIndex + 1) + @" of " + [_matchedIndexPaths count]];

    setTimeout(function() {
        var node = [[treeController arrangedObjects] descendantNodeAtIndexPath:path];
        if (node) {
            var rowIndex = [outlineView rowForItem:node];
            if (rowIndex >= 0) {
                [outlineView scrollRowToVisible:rowIndex];
            }
        }
    }, 300);
}

- (void)prevMatch:(id)sender
{
    if (!_matchedIndexPaths || _matchedIndexPaths.length === 0) return;
    _currentMatchIndex--;
    if (_currentMatchIndex < 0)
        _currentMatchIndex = _matchedIndexPaths.length - 1;
    [self updateSelectionToCurrentMatch];
}

- (void)nextMatch:(id)sender
{
    if (!_matchedIndexPaths || _matchedIndexPaths.length === 0) return;
    _currentMatchIndex++;
    if (_currentMatchIndex >= _matchedIndexPaths.length)
        _currentMatchIndex = 0;
    [self updateSelectionToCurrentMatch];
}

- (void)doubleClickDownstream:(id)sender
{
    var clickedRow = [downstreamTableView clickedRow];
    if (clickedRow < 0 || clickedRow >= [_downstreamTerms count]) return;

    var term = _downstreamTerms[clickedRow];
    var formattedId = term.id;

    if (_currentPickerType === @"ICD-10") {
        [_searchField setStringValue:formattedId];
        [self performICD10SearchForString:formattedId];
    } else if (_currentPickerType === @"OPS") {
        [_searchField setStringValue:formattedId];
        [self performOPSSearchForString:formattedId];
    } else if (_currentPickerType === @"ATC") {
        [_searchField setStringValue:formattedId];
        [self performATCSearchForString:formattedId];
    } else {
        formattedId = formatHPOId(term.id);
        [_searchField setStringValue:formattedId];
        [_nameOnlyCheckbox setState:CPOffState];
        [self performSearchForString:formattedId isNameOnly:NO];
    }
}

- (void)exportDownstream:(id)sender
{
    if (!_downstreamTerms || [_downstreamTerms count] === 0) return;

    var textToExport = "";
    for (var i = 0; i < [_downstreamTerms count]; i++) {
        var termId = _downstreamTerms[i].id;
        var formatted = "";
        if (_currentPickerType === @"ICD-10") {
            formatted = termId;
        } else {
            formatted = formatHPOId(termId);
        }
        textToExport += formatted + "\n";
    }

    if (!_exportPopover)
    {
        _exportPopover = [CPPopover new];
        [_exportPopover setBehavior:CPPopoverBehaviorTransient];
        [_exportPopover setAppearance:CPPopoverAppearanceMinimal];
        [_exportPopover setAnimates:YES];

        var containerView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 250, 350)];
        var scrollView = [[CPScrollView alloc] initWithFrame:[containerView bounds]];
        [scrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [scrollView setAutohidesScrollers:YES];

        _exportTextView = [[CPTextView alloc] initWithFrame:[scrollView bounds]];
        [_exportTextView setAutoresizingMask:CPViewWidthSizable];
        [_exportTextView setEditable:NO];
        [_exportTextView setSelectable:YES];

        [scrollView setDocumentView:_exportTextView];
        [containerView addSubview:scrollView];

        var myViewController = [CPViewController new];
        [myViewController setView:containerView];
        [_exportPopover setContentViewController:myViewController];
    }

    [_exportTextView setString:textToExport];
    [_exportPopover showRelativeToRect:[sender bounds] ofView:sender preferredEdge:CPMinYEdge];

    window.setTimeout(function() {
        [_exportTextView selectAll:self];
    }, 50);
}

- (void)syncTreeNode:(CPTreeNode)treeNode withModelChildren:(CPArray)newChildren
{
    if (!treeNode) return;

    var mutableChildNodes = [treeNode mutableChildNodes];

    if ([mutableChildNodes count] > 0)
    {
        var firstChildObj = [[mutableChildNodes objectAtIndex:0] representedObject];
        if ([firstChildObj name] !== @"Loading...") {
            return;
        }
    } else if ([mutableChildNodes count] === 0 && [newChildren count] === 0) {
        return;
    }

    [mutableChildNodes removeAllObjects];

    for (var i = 0; i < [newChildren count]; i++) {
        var childModel = newChildren[i];
        var childTreeNode = [[CPTreeNode alloc] initWithRepresentedObject:childModel];

        if (![childModel isLeaf] && [[childModel children] count] > 0) {
            var dummyModel = [[childModel children] objectAtIndex:0];
            var dummyTreeNode = [[CPTreeNode alloc] initWithRepresentedObject:dummyModel];
            [[childTreeNode mutableChildNodes] addObject:dummyTreeNode];
        }

        [mutableChildNodes addObject:childTreeNode];
    }
}

// --------------------------------------------------------------------------------
// Status Pulse Animations
// --------------------------------------------------------------------------------

- (void)startPulsatingAnimation
{
    [_searchStatusLabel setWantsLayer:YES];
    var layer = [_searchStatusLabel layer];
    [layer setDelegate:self];

    var pulseAnimation = [CABasicAnimation animationWithKeyPath:@"searchAlphaValue"];
    pulseAnimation._animationID = "searchPulse";
    [pulseAnimation setDelegate:self];
    [pulseAnimation setFromValue:1.0];
    [pulseAnimation setToValue:0.2];
    [pulseAnimation setDuration:0.6];
    [layer addAnimation:pulseAnimation forKey:@"searchAlphaValue"];
}

- (void)stopPulsatingAnimation
{
    [[_searchStatusLabel layer] removeAnimationForKey:@"searchAlphaValue"];
    [_searchStatusLabel setAlphaValue:1.0];
}

- (void)setSearchAlphaValue:(float)val
{
    [_searchStatusLabel setAlphaValue:val];
}

- (void)startExtractPulsatingAnimation
{
    [_searchStatusLabel setWantsLayer:YES];
    var layer = [_searchStatusLabel layer];
    [layer setDelegate:self];

    var pulseAnimation = [CABasicAnimation animationWithKeyPath:@"extractAlphaValue"];
    pulseAnimation._animationID = "extractPulse";
    [pulseAnimation setDelegate:self];
    [pulseAnimation setFromValue:1.0];
    [pulseAnimation setToValue:0.2];
    [pulseAnimation setDuration:0.6];
    [layer addAnimation:pulseAnimation forKey:@"extractAlphaValue"];
}

- (void)stopExtractPulsatingAnimation
{
    [[_searchStatusLabel layer] removeAnimationForKey:@"extractAlphaValue"];
    [_searchStatusLabel setAlphaValue:1.0];
}

- (void)setExtractAlphaValue:(float)val
{
    [_searchStatusLabel setAlphaValue:val];
}

- (void)animationDidStop:(CAAnimation)anim finished:(BOOL)finished
{
    if (!finished) return;

    if (anim._animationID === @"searchPulse") {
        var currentOpacity = [_searchStatusLabel alphaValue];
        var fromVal = (currentOpacity < 0.5) ? 0.2 : 1.0;
        var toVal   = (currentOpacity < 0.5) ? 1.0 : 0.2;

        var layer = [_searchStatusLabel layer];
        var pulseAnimation = [CABasicAnimation animationWithKeyPath:@"searchAlphaValue"];
        pulseAnimation._animationID = "searchPulse";
        [pulseAnimation setDelegate:self];
        [pulseAnimation setFromValue:fromVal];
        [pulseAnimation setToValue:toVal];
        [pulseAnimation setDuration:0.6];
        [layer addAnimation:pulseAnimation forKey:@"searchAlphaValue"];
    }
    else if (anim._animationID === @"extractPulse") {
        var currentOpacity = [_searchStatusLabel alphaValue];
        var fromVal = (currentOpacity < 0.5) ? 0.2 : 1.0;
        var toVal   = (currentOpacity < 0.5) ? 1.0 : 0.2;

        var layer = [_searchStatusLabel layer];
        var pulseAnimation = [CABasicAnimation animationWithKeyPath:@"extractAlphaValue"];
        pulseAnimation._animationID = "extractPulse";
        [pulseAnimation setDelegate:self];
        [pulseAnimation setFromValue:fromVal];
        [pulseAnimation setToValue:toVal];
        [pulseAnimation setDuration:0.6];
        [layer addAnimation:pulseAnimation forKey:@"extractAlphaValue"];
    }
}

- (void)fetchICD10Roots
{
    var request = [CPURLRequest requestWithURL:"/BBB/icd10/roots"];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error) {
        if (!error && data) {
            var json = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            var roots = [CPMutableArray array];
            if (json && json.length) {
                for (var i = 0; i < json.length; i++) {
                    var node = [[HPONode alloc] initWithDict:json[i] nodeType:@"ICD-10"];
                    [roots addObject:node];
                }
            }
            _allRoots = roots;
            [treeController setContent:_allRoots];
        } else {
            console.error("Failed to fetch ICD-10 roots: " + error);
        }
    }];
}

- (void)fetchOPSRoots
{
    var request = [CPURLRequest requestWithURL:"/BBB/ops/roots"];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error) {
        if (!error && data) {
            var json = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            var roots = [CPMutableArray array];
            if (json && json.length) {
                for (var i = 0; i < json.length; i++) {
                    var node = [[HPONode alloc] initWithDict:json[i] nodeType:@"OPS"];
                    [roots addObject:node];
                }
            }
            _allRoots = roots;
            [treeController setContent:_allRoots];
        } else {
            console.error("Failed to fetch OPS roots: " + error);
        }
    }];
}

- (void)fetchATCRoots
{
    var request = [CPURLRequest requestWithURL:"/BBB/atc/roots"];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error) {
        if (!error && data) {
            var json = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            var roots = [CPMutableArray array];
            if (json && json.length) {
                for (var i = 0; i < json.length; i++) {
                    var node = [[HPONode alloc] initWithDict:json[i] nodeType:@"ATC"];
                    [roots addObject:node];
                }
            }
            _allRoots = roots;
            [treeController setContent:_allRoots];
        } else {
            console.error("Failed to fetch ATC roots: " + error);
        }
    }];
}

- (void)fetchICD10DownstreamForNode:(HPONode)node
{
    if (!node) return;
    var urlString = "/BBB/icd10/children/" + [node termId];
    var request = [CPURLRequest requestWithURL:urlString];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        if (!error && data) {
            var parsed = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            _downstreamTerms = [];
            if (parsed && parsed.length) {
                for (var i = 0; i < parsed.length; i++) {
                    _downstreamTerms.push({
                        id: parsed[i].id,
                        label: parsed[i].label
                    });
                }
            }
        } else {
            _downstreamTerms = [];
        }
        [downstreamTableView reloadData];
    }];
}

- (void)fetchOPSDownstreamForNode:(HPONode)node
{
    if (!node) return;
    var urlString = "/BBB/ops/children/" + [node termId];
    var request = [CPURLRequest requestWithURL:urlString];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        if (!error && data) {
            var parsed = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            _downstreamTerms = [];
            if (parsed && parsed.length) {
                for (var i = 0; i < parsed.length; i++) {
                    _downstreamTerms.push({ id: parsed[i].id, label: parsed[i].label });
                }
            }
        } else {
            _downstreamTerms = [];
        }
        [downstreamTableView reloadData];
    }];
}

- (void)fetchATCDownstreamForNode:(HPONode)node
{
    if (!node) return;
    var urlString = "/BBB/atc/children/" + [node termId];
    var request = [CPURLRequest requestWithURL:urlString];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        if (!error && data) {
            var parsed = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            _downstreamTerms = [];
            if (parsed && parsed.length) {
                for (var i = 0; i < parsed.length; i++) {
                    _downstreamTerms.push({ id: parsed[i].id, label: parsed[i].label });
                }
            }
        } else {
            _downstreamTerms = [];
        }
        [downstreamTableView reloadData];
    }];
}

- (void)performICD10SearchForString:(CPString)searchString
{
    if (!searchString || [searchString length] === 0)
    {
        [treeController setSelectionIndexPaths:[]];
        _matchedIndexPaths = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@""];
        return;
    }

    [_searchStatusLabel setStringValue:@"Searching..."];
    [self startPulsatingAnimation];

    var urlString = "/BBB/icd10/search/" + encodeURIComponent(searchString);
    var request = [CPURLRequest requestWithURL:urlString];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [self stopPulsatingAnimation];
        if (!error && data)
        {
            var json = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [self expandAndSelectICD10Paths:json];
        }
        else
        {
            [_searchStatusLabel setStringValue:@"Error"];
        }
    }];
}

- (void)performOPSSearchForString:(CPString)searchString
{
    if (!searchString || [searchString length] === 0) return;
    [_searchStatusLabel setStringValue:@"Searching..."];
    [self startPulsatingAnimation];

    var urlString = "/BBB/ops/search/" + encodeURIComponent(searchString);
    var request = [CPURLRequest requestWithURL:urlString];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error) {
        [self stopPulsatingAnimation];
        if (!error && data) {
            var json = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [self expandAndSelectOPSPaths:json];
        } else {
            [_searchStatusLabel setStringValue:@"Error"];
        }
    }];
}

- (void)performATCSearchForString:(CPString)searchString
{
    if (!searchString || [searchString length] === 0) return;
    [_searchStatusLabel setStringValue:@"Searching..."];
    [self startPulsatingAnimation];

    var urlString = "/BBB/atc/search/" + encodeURIComponent(searchString);
    var request = [CPURLRequest requestWithURL:urlString];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error) {
        [self stopPulsatingAnimation];
        if (!error && data) {
            var json = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [self expandAndSelectATCPaths:json];
        } else {
            [_searchStatusLabel setStringValue:@"Error"];
        }
    }];
}

- (void)resolveICD10Path:(CPArray)nodeIds currentIndex:(int)index currentModels:(CPArray)models baseIndexPath:(CPIndexPath)indexPath completion:(Function)callback
{
    if (!nodeIds || index >= nodeIds.length) {
        callback(indexPath);
        return;
    }

    var targetId = nodeIds[index];
    var foundModelIndex = -1;
    var foundModel = nil;

    for (var i = 0; i < [models count]; i++) {
        if ([models[i] termId] === targetId) {
            foundModelIndex = i;
            foundModel = models[i];
            break;
        }
    }

    if (!foundModel) {
        callback(nil);
        return;
    }

    var nextIndexPath = indexPath ? [indexPath indexPathByAddingIndex:foundModelIndex] : [CPIndexPath indexPathWithIndex:foundModelIndex];

    if (index === nodeIds.length - 1) {
        callback(nextIndexPath);
    } else {
        [foundModel fetchChildrenWithCompletion:function(newChildren) {
            var treeNode = [[treeController arrangedObjects] descendantNodeAtIndexPath:nextIndexPath];
            if (treeNode) {
                [self syncTreeNode:treeNode withModelChildren:newChildren];
            }
            [self resolveICD10Path:nodeIds currentIndex:(index + 1) currentModels:newChildren baseIndexPath:nextIndexPath completion:callback];
        }];
    }
}

- (void)resolveOPSPath:(CPArray)nodeIds currentIndex:(int)index currentModels:(CPArray)models baseIndexPath:(CPIndexPath)indexPath completion:(Function)callback
{
    if (!nodeIds || index >= nodeIds.length) {
        callback(indexPath);
        return;
    }

    var targetId = nodeIds[index];
    var foundModelIndex = -1;
    var foundModel = nil;

    for (var i = 0; i < [models count]; i++) {
        if ([models[i] termId] === targetId) {
            foundModelIndex = i;
            foundModel = models[i];
            break;
        }
    }

    if (!foundModel) {
        callback(nil);
        return;
    }

    var nextIndexPath = indexPath ? [indexPath indexPathByAddingIndex:foundModelIndex] : [CPIndexPath indexPathWithIndex:foundModelIndex];

    if (index === nodeIds.length - 1) {
        callback(nextIndexPath);
    } else {
        [foundModel fetchChildrenWithCompletion:function(newChildren) {
            var treeNode = [[treeController arrangedObjects] descendantNodeAtIndexPath:nextIndexPath];
            if (treeNode) {
                [self syncTreeNode:treeNode withModelChildren:newChildren];
            }
            [self resolveOPSPath:nodeIds currentIndex:(index + 1) currentModels:newChildren baseIndexPath:nextIndexPath completion:callback];
        }];
    }
}

- (void)resolveATCPath:(CPArray)nodeIds currentIndex:(int)index currentModels:(CPArray)models baseIndexPath:(CPIndexPath)indexPath completion:(Function)callback
{
    if (!nodeIds || index >= nodeIds.length) {
        callback(indexPath);
        return;
    }

    var targetId = nodeIds[index];
    var foundModelIndex = -1;
    var foundModel = nil;

    for (var i = 0; i < [models count]; i++) {
        if ([models[i] termId] === targetId) {
            foundModelIndex = i;
            foundModel = models[i];
            break;
        }
    }

    if (!foundModel) {
        callback(nil);
        return;
    }

    var nextIndexPath = indexPath ? [indexPath indexPathByAddingIndex:foundModelIndex] : [CPIndexPath indexPathWithIndex:foundModelIndex];

    if (index === nodeIds.length - 1) {
        callback(nextIndexPath);
    } else {
        [foundModel fetchChildrenWithCompletion:function(newChildren) {
            var treeNode = [[treeController arrangedObjects] descendantNodeAtIndexPath:nextIndexPath];
            if (treeNode) {
                [self syncTreeNode:treeNode withModelChildren:newChildren];
            }
            [self resolveATCPath:nodeIds currentIndex:(index + 1) currentModels:newChildren baseIndexPath:nextIndexPath completion:callback];
        }];
    }
}

- (void)expandAndSelectICD10Paths:(CPArray)searchResults
{
    if (!searchResults || !searchResults.length)
    {
        [treeController setSelectionIndexPaths:[]];
        _matchedIndexPaths = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@"0 hits"];
        return;
    }

    var targetIndexPaths = [CPMutableArray array];
    var pendingPaths = searchResults.length;

    for (var i = 0; i < searchResults.length; i++)
    {
        var nodeIds = searchResults[i].path;
        [self resolveICD10Path:nodeIds
                  currentIndex:0
                 currentModels:_allRoots
                 baseIndexPath:nil
                    completion:function(finalIndexPath) {
            if (finalIndexPath)
            {
                [targetIndexPaths addObject:finalIndexPath];
            }
            pendingPaths--;

            if (pendingPaths === 0)
            {
                _matchedIndexPaths = targetIndexPaths;
                _currentMatchIndex = 0;

                setTimeout(function() {
                    [self updateSelectionToCurrentMatch];
                }, 50);
            }
        }];
    }
}

- (void)expandAndSelectOPSPaths:(CPArray)searchResults
{
    if (!searchResults || !searchResults.length)
    {
        [treeController setSelectionIndexPaths:[]];
        _matchedIndexPaths = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@"0 hits"];
        return;
    }

    var targetIndexPaths = [CPMutableArray array];
    var pendingPaths = searchResults.length;

    for (var i = 0; i < searchResults.length; i++)
    {
        var nodeIds = searchResults[i].path;
        [self resolveOPSPath:nodeIds
                  currentIndex:0
                 currentModels:_allRoots
                 baseIndexPath:nil
                    completion:function(finalIndexPath) {
            if (finalIndexPath)
            {
                [targetIndexPaths addObject:finalIndexPath];
            }
            pendingPaths--;

            if (pendingPaths === 0)
            {
                _matchedIndexPaths = targetIndexPaths;
                _currentMatchIndex = 0;

                setTimeout(function() {
                    [self updateSelectionToCurrentMatch];
                }, 50);
            }
        }];
    }
}

- (void)expandAndSelectATCPaths:(CPArray)searchResults
{
    if (!searchResults || !searchResults.length)
    {
        [treeController setSelectionIndexPaths:[]];
        _matchedIndexPaths = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@"0 hits"];
        return;
    }

    var targetIndexPaths = [CPMutableArray array];
    var pendingPaths = searchResults.length;

    for (var i = 0; i < searchResults.length; i++)
    {
        var nodeIds = searchResults[i].path;
        [self resolveATCPath:nodeIds
                  currentIndex:0
                 currentModels:_allRoots
                 baseIndexPath:nil
                    completion:function(finalIndexPath) {
            if (finalIndexPath)
            {
                [targetIndexPaths addObject:finalIndexPath];
            }
            pendingPaths--;

            if (pendingPaths === 0)
            {
                _matchedIndexPaths = targetIndexPaths;
                _currentMatchIndex = 0;

                setTimeout(function() {
                    [self updateSelectionToCurrentMatch];
                }, 50);
            }
        }];
    }
}

// --------------------------------------------------------------------------------
// Phenopacket Visual Parsing and Interactive Integration
// --------------------------------------------------------------------------------

- (void)tabView:(CPTabView)tabView didSelectTabViewItem:(CPTabViewItem)tabViewItem
{
    if ([[tabViewItem identifier] isEqualToString:@"phenoVisualTab"])
    {
        [self parseActivePhenopacketToVisualItems];
    }
}

- (void)parseActivePhenopacketToVisualItems
{
    var jsonText = [_phenopacketOutputTextView string];
    _phenoVisualItems = [];

    if (!jsonText || [jsonText length] === 0)
    {
        [_phenoVisualTableView reloadData];
        return;
    }

    try {
        var phenopacket = JSON.parse(jsonText);
        if (phenopacket) {
            
            if (phenopacket.subject) {
                var age = phenopacket.subject.age;
                var sex = phenopacket.subject.sex;
                if (age) {
                    _phenoVisualItems.push({
                        "category": @"Demographics",
                        "code": @"30525-0",
                        "label": @"Age: " + age,
                        "excluded": NO,
                        "modifiers": []
                    });
                }
                if (sex && sex !== "UNKNOWN") {
                    _phenoVisualItems.push({
                        "category": @"Demographics",
                        "code": @"76689-9",
                        "label": @"Sex: " + sex,
                        "excluded": NO,
                        "modifiers": []
                    });
                }
            }
            
            var measurements = phenopacket.measurements || [];
            for (var i = 0; i < measurements.length; i++) {
                var meas = measurements[i];
                if (meas.assay) {
                    var valStr = "";
                    if (meas.value && meas.value.quantity) {
                        var q = meas.value.quantity;
                        valStr = (q.comparator || "=") + " " + q.value + " " + (q.unit ? (q.unit.label || q.unit || "") : "");
                    }
                    
                    var loincCode = meas.assay.id || "LOINC:29003-1";
                    var mods = [];
                    
                    var rawMods = meas.modifiers || [];
                    var hasLP = false;
                    for (var m = 0; m < rawMods.length; m++) {
                        if (rawMods[m].id === "LP7753-9" || rawMods[m].id === "21889-1") {
                            hasLP = true;
                        }
                        mods.push({
                            "code": rawMods[m].id || "LP7753-9",
                            "display": rawMods[m].label || "Measurement",
                            "is_modifier": YES,
                            "is_demographic": YES
                        });
                    }
                    
                    if (!hasLP && valStr.trim().length > 0) {
                        mods.push({
                            "code": "LP7753-9",
                            "display": "Measurement: " + valStr.trim(),
                            "is_modifier": YES,
                            "is_demographic": YES
                        });
                    }

                    _phenoVisualItems.push({
                        "category": @"Measurement (LOINC)",
                        "code": loincCode,
                        "label": meas.assay.label || "Measurement",
                        "excluded": NO,
                        "modifiers": mods
                    });
                }
            }

            var features = phenopacket.phenotypicFeatures || [];
            for (var i = 0; i < features.length; i++) {
                var feat = features[i];
                if (feat.type) {
                    var mods = [];
                    if (feat.severity) {
                        mods.push({
                            "code": feat.severity.id || @"",
                            "display": feat.severity.label || @"",
                            "is_modifier": YES,
                            "is_severity": true
                        });
                    }
                    var rawMods = feat.modifiers || [];
                    for (var m = 0; m < rawMods.length; m++) {
                        var isDemoMod = (rawMods[m].id === "LP7753-9" || rawMods[m].id === "21889-1" || rawMods[m].is_demographic) ? YES : NO;
                        mods.push({
                            "code": rawMods[m].id || @"",
                            "display": rawMods[m].label || @"",
                            "is_modifier": YES,
                            "is_demographic": isDemoMod
                        });
                    }

                    _phenoVisualItems.push({
                        "category": @"Phenotype",
                        "code": feat.type.id || @"",
                        "label": feat.type.label || @"",
                        "excluded": feat.excluded ? true : (feat.exclude ? true : false),
                        "modifiers": mods
                    });
                }
                var featOnsetTime = (typeof feat.onset === 'object') ? (feat.onset.timestamp || feat.onset.age || "") : feat.onset;
                if (featOnsetTime) {
                    mods.push({
                        "code": "onset",
                        "display": "Onset: " + featOnsetTime,
                        "is_modifier": YES
                    });
                }
            }

            var diseases = phenopacket.diseases || [];
            for (var i = 0; i < diseases.length; i++) {
                var dis = diseases[i];
                if (dis.term) {
                    var mods = [];
                    if (dis.primarySite) {
                        mods.push({
                            "code": dis.primarySite.id || @"",
                            "display": dis.primarySite.label || @"",
                            "is_modifier": YES
                        });
                    }
                    if (dis.onset) {
                        var onsetTime = (typeof dis.onset === 'object') ? (dis.onset.timestamp || dis.onset.age || "") : dis.onset;
                        if (onsetTime) {
                            mods.push({
                                "code": "onset",
                                "display": "Onset: " + onsetTime,
                                "is_modifier": YES
                            });
                        }
                    }
                    _phenoVisualItems.push({
                        "category": @"Disease / Diagnosis",
                        "code": dis.term.id || @"",
                        "label": dis.term.label || @"",
                        "excluded": dis.excluded ? true : (dis.exclude ? true : false),
                        "modifiers": mods
                    });
                }
            }

            var procedures = phenopacket.procedures || [];
            for (var i = 0; i < procedures.length; i++) {
                var proc = procedures[i];
                if (proc.code) {
                    var mods = [];
                    if (proc.bodySite) {
                        mods.push({
                            "code": proc.bodySite.id || @"",
                            "display": proc.bodySite.label || @"",
                            "is_modifier": YES
                        });
                    }
                    if (proc.performedTime) {
                        mods.push({
                            "code": "performed-time",
                            "display": "Performed: " + proc.performedTime,
                            "is_modifier": YES
                        });
                    }
                    _phenoVisualItems.push({
                        "category": @"Procedure",
                        "code": proc.code.id || @"",
                        "label": proc.code.label || @"",
                        "excluded": NO,
                        "modifiers": mods
                    });
                }
            }

            var medicalActions = phenopacket.medicalActions || [];
            for (var i = 0; i < medicalActions.length; i++) {
                var action = medicalActions[i];
                if (action.treatment && action.treatment.agent) {
                    _phenoVisualItems.push({
                        "category": @"Medication",
                        "code": action.treatment.agent.id || @"",
                        "label": action.treatment.agent.label || @"",
                        "excluded": NO,
                        "modifiers": []
                    });
                }
                if (action.procedure && action.procedure.code) {
                    var proc = action.procedure;
                    var perfTime = (proc.performed && proc.performed.timestamp) ? proc.performed.timestamp.substring(0, 10) : "";
                    var mods = [];
                    if (proc.bodySite) {
                        mods.push({
                            "code": proc.bodySite.id || @"",
                            "display": proc.bodySite.label || @"",
                            "is_modifier": YES
                        });
                    }
                    if (perfTime) {
                        mods.push({
                            "code": "performed-time",
                            "display": "Performed: " + perfTime,
                            "is_modifier": YES
                        });
                    }
                    var alreadyAdded = false;
                    for (var p = 0; p < _phenoVisualItems.length; p++) {
                        if (_phenoVisualItems[p].category === "Procedure" && _phenoVisualItems[p].code === proc.code.id) {
                            alreadyAdded = true;
                            break;
                        }
                    }
                    if (!alreadyAdded) {
                        _phenoVisualItems.push({
                            "category": @"Procedure",
                            "code": proc.code.id || @"",
                            "label": proc.code.label || @"",
                            "excluded": NO,
                            "modifiers": mods
                        });
                    }
                }
            }
        }
    } catch (e) {
        console.log("Could not parse Phenopacket JSON for Visual Tab: ", e);
    }

    [_phenoVisualTableView reloadData];
}

- (void)phenoVisualTokenFieldDidChange:(id)sender
{
    var tokenField = sender;
    if ([sender isKindOfClass:[CPNotification class]])
    {
        tokenField = [sender object];
    }
    
    if (tokenField && tokenField.rowIndex !== undefined)
    {
        var row = tokenField.rowIndex;
        if (row < _phenoVisualItems.length)
        {
            var tokens = [tokenField objectValue] || [];
            if (tokens.length > 0)
            {
                var mainToken = tokens[0];
                _phenoVisualItems[row].code = mainToken.code;
                _phenoVisualItems[row].label = mainToken.display;
                
                var modifiers = [];
                for (var i = 1; i < tokens.length; i++)
                {
                    var tok = tokens[i];
                    tok.is_modifier = YES;
                    modifiers.push(tok);
                }
                _phenoVisualItems[row].modifiers = modifiers;
            }
            else
            {
                _phenoVisualItems[row].code = @"";
                _phenoVisualItems[row].label = @"";
                _phenoVisualItems[row].modifiers = [];
            }
            
            [self updatePhenopacketJSONFromVisualItems];
        }
    }
}

- (void)updatePhenopacketJSONFromVisualItems
{
    var jsonText = [_phenopacketOutputTextView string];
    var phenopacket = {};
    
    try {
        if (jsonText && [jsonText length] > 0) {
            phenopacket = JSON.parse(jsonText);
        }
    } catch(e) {
    }
    
    phenopacket.id = phenopacket.id || "patient-1";
    phenopacket.phenotypicFeatures = [];
    phenopacket.measurements = [];
    phenopacket.diseases = [];
    phenopacket.procedures = [];
    phenopacket.medicalActions = [];
    phenopacket.subject = phenopacket.subject || { "id": "anonymous-patient" };
    
    for (var i = 0; i < _phenoVisualItems.length; i++)
    {
        var item = _phenoVisualItems[i];
        if ([item.category isEqualToString:@"Demographics"])
        {
            if (item.code === "30525-0") {
                phenopacket.subject.age = item.label.replace("Age: ", "");
            } else if (item.code === "76689-9") {
                phenopacket.subject.sex = item.label.replace("Sex: ", "").toUpperCase();
            }
        }
        else if ([item.category isEqualToString:@"Measurement (LOINC)"])
        {
            var valComp = "<=";
            var valNum = 0;
            var unitStr = "mm";
            
            var mods = item.modifiers || [];
            var rawMods = [];
            for (var m = 0; m < mods.length; m++) {
                var tok = mods[m];
                var cleanDisp = tok.display.replace("Measurement: ", "").trim();
                var match = cleanDisp.match(/([<>]=?|=)?\s*(\d+(?:\.\d+)?)\s*(.*)/);
                if (match) {
                    valComp = match[1] || "<=";
                    valNum = parseFloat(match[2]);
                    unitStr = match[3] || "mm";
                }
                rawMods.push({
                    "id": tok.code || "LP7753-9",
                    "label": tok.display
                });
            }

            phenopacket.measurements.push({
                "assay": {
                    "id": item.code,
                    "label": item.label
                },
                "value": {
                    "quantity": {
                        "comparator": valComp,
                        "value": valNum,
                        "unit": { "label": unitStr }
                    }
                },
                "modifiers": rawMods
            });
        }
        else if ([item.category isEqualToString:@"Phenotype"])
        {
            var rawMods = [];
            var severityObj = undefined;
            var mods = item.modifiers || [];
            
            for (var m = 0; m < mods.length; m++) {
                if (mods[m].is_severity) {
                    severityObj = {
                        "id": mods[m].code,
                        "label": mods[m].display
                    };
                } else {
                    rawMods.push({
                        "id": mods[m].code,
                        "label": mods[m].display
                    });
                }
            }
            
            phenopacket.phenotypicFeatures.push({
                "type": {
                    "id": item.code,
                    "label": item.label
                },
                "excluded": item.excluded ? true : false,
                "modifiers": rawMods,
                "severity": severityObj
            });
        }
        else if ([item.category isEqualToString:@"Procedure"])
        {
            var perfTime = "";
            var bodySiteObj = undefined;
            var mods = item.modifiers || [];
            for (var m = 0; m < mods.length; m++) {
                if (mods[m].code === "performed-time" || mods[m].display.indexOf("Performed: ") === 0) {
                    perfTime = mods[m].display.replace("Performed: ", "");
                } else if (mods[m].code) {
                    bodySiteObj = {
                        "id": mods[m].code,
                        "label": mods[m].display
                    };
                }
            }
            
            phenopacket.procedures.push({
                "code": {
                    "id": item.code,
                    "label": item.label
                },
                "bodySite": bodySiteObj,
                "performedTime": perfTime
            });

            phenopacket.medicalActions.push({
                "procedure": {
                    "code": {
                        "id": item.code,
                        "label": item.label
                    },
                    "bodySite": bodySiteObj,
                    "performed": perfTime ? { "timestamp": perfTime + "T00:00:00Z" } : undefined
                }
            });
        }
        else
        {
            var primarySiteObj = undefined;
            var onsetObj = undefined;
            var mods = item.modifiers || [];
            for (var m = 0; m < mods.length; m++) {
                if (mods[m].code === "onset" || (mods[m].display && mods[m].display.indexOf("Onset: ") === 0)) {
                    var oTime = mods[m].display.replace("Onset: ", "").trim();
                    if (oTime) {
                        onsetObj = { "timestamp": oTime };
                    }
                } else if (mods[m].code) {
                    primarySiteObj = {
                        "id": mods[m].code,
                        "label": mods[m].display
                    };
                }
            }

            var diseaseEntry = {
                "term": {
                    "id": item.code,
                    "label": item.label
                },
                "excluded": item.excluded ? true : false
            };

            if (primarySiteObj) {
                diseaseEntry.primarySite = primarySiteObj;
            }
            if (onsetObj) {
                diseaseEntry.onset = onsetObj;
            }

            phenopacket.diseases.push(diseaseEntry);
        }
    }

    var prettyJSON = JSON.stringify(phenopacket, null, 4);
    [_phenopacketOutputTextView setString:prettyJSON];

    var selectedCandidate = [candidatesController selection];

    if (selectedCandidate && ![selectedCandidate isMemberOfClass:[CPNull class]])
    {
        [selectedCandidate setValue:prettyJSON forKey:@"phenopacket_json"];
    }
}

- (void)doubleClickPhenoVisual:(id)sender
{
    var clickedRow = [_phenoVisualTableView clickedRow];
    if (clickedRow < 0 || clickedRow >= [_phenoVisualItems count]) return;

    var item = _phenoVisualItems[clickedRow];
    if (item && item.code && item.category !== "Demographics")
    {
        [self searchForHPOTerm:item.code];
    }
}

- (void)addPhenotypeItem:(id)sender
{
    var newItem = {
        "category": @"Phenotype",
        "code": @"HP:0000118",
        "label": @"Phenotypic abnormality",
        "excluded": NO,
        "modifiers": []
    };
    
    if (!_phenoVisualItems) {
        _phenoVisualItems = [];
    }
    
    [_phenoVisualItems addObject:newItem];
    [_phenoVisualTableView reloadData];
    [self updatePhenopacketJSONFromVisualItems];
    
    var lastRow = [_phenoVisualItems count] - 1;
    [_phenoVisualTableView selectRowIndexes:[CPIndexSet indexSetWithIndex:lastRow] byExtendingSelection:NO];
    [_phenoVisualTableView scrollRowToVisible:lastRow];
}

- (void)removePhenotypeItem:(id)sender
{
    var selectedRow = [_phenoVisualTableView selectedRow];
    if (selectedRow !== -1 && selectedRow < [_phenoVisualItems count])
    {
        [_phenoVisualItems removeObjectAtIndex:selectedRow];
        [_phenoVisualTableView reloadData];
        [self updatePhenopacketJSONFromVisualItems];
        
        var newSelection = MIN(selectedRow, [_phenoVisualItems count] - 1);
        if (newSelection >= 0) {
            [_phenoVisualTableView selectRowIndexes:[CPIndexSet indexSetWithIndex:newSelection] byExtendingSelection:NO];
        }
    }
}

- (void)copyChatPseudonymsAction:(id)sender
{
    if (!_chatFoundPatients || [_chatFoundPatients count] === 0)
    {
        alert("Keine Patienten in der Kohorten-Tabelle vorhanden.");
        return;
    }

    var textToExport = "";
    for (var i = 0; i < [_chatFoundPatients count]; i++)
    {
        var item = [_chatFoundPatients objectAtIndex:i];
        if (item && [item length] > 0)
        {
            textToExport += item + "\n";
        }
    }

    if (!_chatPseudonymsPopover)
    {
        _chatPseudonymsPopover = [CPPopover new];
        [_chatPseudonymsPopover setBehavior:CPPopoverBehaviorTransient];
        [_chatPseudonymsPopover setAppearance:CPPopoverAppearanceMinimal];
        [_chatPseudonymsPopover setAnimates:YES];

        var containerView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 260, 320)];
        var scrollView = [[CPScrollView alloc] initWithFrame:[containerView bounds]];
        [scrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [scrollView setAutohidesScrollers:YES];

        _chatPseudonymsTextView = [[CPTextView alloc] initWithFrame:[scrollView bounds]];
        [_chatPseudonymsTextView setAutoresizingMask:CPViewWidthSizable];
        [_chatPseudonymsTextView setEditable:NO];
        [_chatPseudonymsTextView setSelectable:YES];
        [_chatPseudonymsTextView setFont:[CPFont fontWithName:@"Courier" size:11.0]];

        [scrollView setDocumentView:_chatPseudonymsTextView];
        [containerView addSubview:scrollView];

        var popoverController = [CPViewController new];
        [popoverController setView:containerView];
        [_chatPseudonymsPopover setContentViewController:popoverController];
    }

    [_chatPseudonymsTextView setString:textToExport];
    [_chatPseudonymsPopover showRelativeToRect:[sender bounds] ofView:sender preferredEdge:CPMinYEdge];

    window.setTimeout(function() {
        [[_chatPseudonymsTextView window] makeFirstResponder:_chatPseudonymsTextView];
        [_chatPseudonymsTextView selectAll:self];
    }, 50);
}

- (void)recomputeCandidatesWithTagAction:(id)sender
{
    var tag = prompt("Geben Sie das Tag ein, dessen Kandidaten neu extrahiert werden sollen:", "");
    if (!tag) return;

    tag = tag.trim();
    if (tag.length === 0) return;

    if (!confirm("Möchten Sie wirklich alle Kandidaten mit dem Tag '" + tag + "' neu extrahieren lassen? Vorhandene Phenopackets werden dabei im Hintergrund neu generiert."))
    {
        return;
    }

    var taskId = @"recompute_tag_" + tag;
    [self addTaskWithName:@"Neu-Extraktion Tag: " + tag identifier:taskId];
    [self updateTaskWithIdentifier:taskId state:@"active" message:@"Reiht Kandidaten in Extraktions-Queue ein..." progress:20];

    var request = [CPURLRequest requestWithURL:@"/BBB/candidates/recompute_by_tag"
                                   cachePolicy:CPURLRequestUseProtocolCachePolicy
                               timeoutInterval:120.0];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var payload = {
        "tag": tag,
        "model": selectedModel,
        "deep_mode": deepModeEnabled ? 1 : 0
    };
    [request setHTTPBody:JSON.stringify(payload)];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
    {
        if (!error && data)
        {
            try {
                var res = JSON.parse(data);
                if (res.success)
                {
                    var count = res.queued || 0;
                    [self updateTaskWithIdentifier:taskId state:@"finished" message:[CPString stringWithFormat:@"%d Kandidat(en) eingereiht", count] progress:100];
                    alert([CPString stringWithFormat:@"Erfolgreich: %d Kandidat(en) mit Tag '%@' wurden in die Hintergrund-Queue (Minion) eingereiht.", count, tag]);
                }
                else
                {
                    var errMsg = res.error || @"Unbekannter Fehler";
                    [self updateTaskWithIdentifier:taskId state:@"failed" message:errMsg progress:0];
                    alert(@"Fehler beim Einreihen: " + errMsg);
                }
            } catch(e) {
                [self updateTaskWithIdentifier:taskId state:@"failed" message:@"Verarbeitungsfehler" progress:0];
                alert(@"Fehler beim Parsen der Serverantwort: " + e.message);
            }
        }
        else
        {
            var msg = error ? [error description] : @"Verbindungsfehler";
            [self updateTaskWithIdentifier:taskId state:@"failed" message:@"Verbindungsfehler" progress:0];
            alert(@"Netzwerkfehler: " + msg);
        }
    }];
}

@end


// --------------------------------------------------------------------------------
// Custom HPO Node Implementation
// --------------------------------------------------------------------------------

@implementation HPONode : CPObject
{
    CPString _termId           @accessors(property=termId);
    CPString name              @accessors(property=name);
    CPString definition        @accessors(property=definition);
    BOOL     isLeaf            @accessors(property=isLeaf);
    CPArray  children;
    BOOL     hasLoadedChildren @accessors(property=hasLoadedChildren);
    BOOL     _isFetching;
    CPArray  _fetchCallbacks;
    CPString nodeType          @accessors(property=nodeType);
}

- (id)initWithDict:(JSObject)dict
{
    return [self initWithDict:dict nodeType:@"HPO"];
}

- (id)initWithDict:(JSObject)dict nodeType:(CPString)aType
{
    self = [super init];
    if (self)
    {
        _termId = dict.id;
        name = dict.label;
        nodeType = aType || @"HPO";
        definition = dict.definition || dict.label;
        isLeaf = (dict.is_leaf == 1);

        if (!isLeaf)
        {
            var dummyNode = [[HPONode alloc] initAsDummyWithNodeType:nodeType];
            children = [dummyNode];
        }
        else
        {
            children = [];
        }
        hasLoadedChildren = NO;
    }
    return self;
}

- (id)initAsDummy
{
    return [self initAsDummyWithNodeType:@"HPO"];
}

- (id)initAsDummyWithNodeType:(CPString)aType
{
    self = [super init];
    if (self)
    {
        name = @"Loading...";
        definition = @"";
        isLeaf = YES;
        children = [];
        hasLoadedChildren = YES;
        nodeType = aType || @"HPO";
    }
    return self;
}

- (void)setChildren:(CPArray)someChildren
{
    [self willChangeValueForKey:@"children"];
    children = someChildren;
    [self didChangeValueForKey:@"children"];
}

- (CPArray)children
{
    return children;
}

- (void)fetchChildrenWithCompletion:(Function)completion
{
    if (hasLoadedChildren) {
        if (completion) completion(children);
        return;
    }

    if (!_fetchCallbacks) _fetchCallbacks = [];
    if (completion) [_fetchCallbacks addObject:completion];

    if (_isFetching) return;
    _isFetching = YES;

    var urlString = "";
    if (nodeType === @"ICD-10") {
        urlString = "/BBB/icd10/children/" + _termId;
    } else if (nodeType === @"OPS") {
        urlString = "/BBB/ops/children/" + _termId;
    } else if (nodeType === @"ATC") {
        urlString = "/BBB/atc/children/" + _termId;
    } else if (nodeType === @"LOINC") {
        urlString = "/BBB/loinc/children/" + _termId;
    } else {
        urlString = "/BBB/hpo/children/" + _termId;
    }
    
    var request = [CPURLRequest requestWithURL:urlString];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error) {
        _isFetching = NO;

        if (!error && data)
        {
            var json = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            var newChildren = [CPMutableArray array];

            if (json && json.length) {
                for (var i = 0; i < json.length; i++) {
                    var childNode = [[HPONode alloc] initWithDict:json[i] nodeType:nodeType];
                    [newChildren addObject:childNode];
                }
            }

            hasLoadedChildren = YES;
            [self setChildren:newChildren];

            var callbacksToRun = [_fetchCallbacks copy];
            [_fetchCallbacks removeAllObjects];
            for (var i = 0; i < callbacksToRun.length; i++) {
                callbacksToRun[i](newChildren);
            }
        } else {
            var callbacksToRun = [_fetchCallbacks copy];
            [_fetchCallbacks removeAllObjects];
            for (var i = 0; i < callbacksToRun.length; i++) {
                callbacksToRun[i]([]);
            }
        }
    }];
}

@end


// --------------------------------------------------------------------------------
// JSON Serialization Utilities
// --------------------------------------------------------------------------------

@implementation CPJSONSerialization : CPObject

+ (id)JSONObjectWithData:(CPString)data options:(int)options error:(id)error
{
    if (!data || [data length] === 0) return nil;
    try {
        return JSON.parse(data);
    } catch (e) {
        return nil;
    }
}

+ (CPString)dataWithJSONObject:(id)object options:(int)options error:(id)error
{
    if (!object) return nil;
    try {
        return JSON.stringify(object);
    } catch (e) {
        return nil;
    }
}

@end
