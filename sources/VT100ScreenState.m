//
//  VT100ScreenState.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 12/10/21.
//

#import "VT100ScreenState.h"
#import "VT100ScreenState+Private.h"

#import "DebugLogging.h"
#import "IntervalTree.h"
#import "iTermOrderEnforcer.h"
#import "LineBuffer.h"
#import "NSDictionary+iTerm.h"

static const int kDefaultMaxScrollbackLines = 1000;


@implementation VT100ScreenState

@synthesize audibleBell = _audibleBell;
@synthesize showBellIndicator = _showBellIndicator;
@synthesize flashBell = _flashBell;
@synthesize postUserNotifications = _postUserNotifications;
@synthesize cursorBlinks = _cursorBlinks;
@synthesize collectInputForPrinting = _collectInputForPrinting;
@synthesize printBuffer = _printBuffer;
@synthesize allowTitleReporting = _allowTitleReporting;
@synthesize lastBell = _lastBell;
@synthesize animatedLines = _animatedLines;
@synthesize pasteboardString = _pasteboardString;
@synthesize intervalTree = _intervalTree;
@synthesize primaryGrid = _primaryGrid;
@synthesize altGrid = _altGrid;
@synthesize currentGrid = _currentGrid;
@synthesize realCurrentGrid = _realCurrentGrid;
@synthesize savedIntervalTree = _savedIntervalTree;
@synthesize wraparoundMode = _wraparoundMode;
@synthesize ansi = _ansi;
@synthesize insert = _insert;
@synthesize unlimitedScrollback = _unlimitedScrollback;
@synthesize terminal = _terminal;
@synthesize findContext = _findContext;
@synthesize scrollbackOverflow = _scrollbackOverflow;
@synthesize commandStartCoord = _commandStartCoord;
@synthesize markCache = _markCache;
@synthesize maxScrollbackLines = _maxScrollbackLines;
@synthesize savedFindContextAbsPos = _savedFindContextAbsPos;
@synthesize tabStops = _tabStops;
@synthesize charsetUsesLineDrawingMode = _charsetUsesLineDrawingMode;
@synthesize lastCharacter = _lastCharacter;
@synthesize lastCharacterIsDoubleWidth = _lastCharacterIsDoubleWidth;
@synthesize lastExternalAttribute = _lastExternalAttribute;
@synthesize saveToScrollbackInAlternateScreen = _saveToScrollbackInAlternateScreen;
@synthesize cursorVisible = _cursorVisible;
@synthesize shellIntegrationInstalled = _shellIntegrationInstalled;
@synthesize lastCommandOutputRange = _lastCommandOutputRange;
@synthesize currentPromptRange = _currentPromptRange;
@synthesize startOfRunningCommandOutput = _startOfRunningCommandOutput;
@synthesize protectedMode = _protectedMode;
@synthesize initialSize = _initialSize;
@synthesize cumulativeScrollbackOverflow = _cumulativeScrollbackOverflow;
@synthesize linebuffer = _linebuffer;
@synthesize trackCursorLineMovement = _trackCursorLineMovement;
@synthesize appendToScrollbackWithStatusBar = _appendToScrollbackWithStatusBar;
@synthesize normalization = _normalization;
@synthesize intervalTreeObserver = _intervalTreeObserver;
@synthesize lastCommandMark = _lastCommandMark;
@synthesize colorMap = _colorMap;
@synthesize temporaryDoubleBuffer = _temporaryDoubleBuffer;
@synthesize fakePromptDetectedAbsLine = _fakePromptDetectedAbsLine;
@synthesize lastPromptLine = _lastPromptLine;
@synthesize sideEffects = _sideEffects;
@synthesize shouldExpectPromptMarks = _shouldExpectPromptMarks;
@synthesize needsRedraw = _needsRedraw;

- (instancetype)initForMutation {
    self = [super init];
    if (self) {
        _animatedLines = [NSMutableIndexSet indexSet];
        _intervalTree = [[IntervalTree alloc] init];
        _savedIntervalTree = [[IntervalTree alloc] init];
        _findContext = [[FindContext alloc] init];
        _commandStartCoord = VT100GridAbsCoordMake(-1, -1);
        _markCache = [[NSMutableDictionary alloc] init];
        _maxScrollbackLines = kDefaultMaxScrollbackLines;
        _tabStops = [[NSMutableSet alloc] init];
        _charsetUsesLineDrawingMode = [NSMutableSet set];
        _cursorVisible = YES;
        _lastCommandOutputRange = VT100GridAbsCoordRangeMake(-1, -1, -1, -1);
        _startOfRunningCommandOutput = VT100GridAbsCoordMake(-1, -1);
        _initialSize = VT100GridSizeMake(-1, -1);
        _linebuffer = [[LineBuffer alloc] init];
        _colorMap = [[iTermColorMap alloc] init];
        _temporaryDoubleBuffer = [[iTermTemporaryDoubleBufferedGridController alloc] init];
        _fakePromptDetectedAbsLine = -1;
        _sideEffects = [[VT100ScreenSideEffectQueue alloc] init];
    }
    return self;
}

- (instancetype)initWithState:(VT100ScreenMutableState *)source {
    self = [super init];
    if (self) {
        _audibleBell = source.audibleBell;
        _showBellIndicator = source.showBellIndicator;
        _flashBell = source.flashBell;
        _postUserNotifications = source.postUserNotifications;
        _cursorBlinks = source.cursorBlinks;
        _collectInputForPrinting = source.collectInputForPrinting;
        _printBuffer = [source.printBuffer copy];
        _allowTitleReporting = source.allowTitleReporting;
        _lastBell = source.lastBell;
        _wraparoundMode = source.wraparoundMode;
        _ansi = source.ansi;
        _insert = source.insert;
        _unlimitedScrollback = source.unlimitedScrollback;
        _scrollbackOverflow = source.scrollbackOverflow;
        _commandStartCoord = source.commandStartCoord;
        _maxScrollbackLines = source.maxScrollbackLines;
        _savedFindContextAbsPos = source.savedFindContextAbsPos;
        _lastCharacter = source.lastCharacter;
        _lastCharacterIsDoubleWidth = source.lastCharacterIsDoubleWidth;
        _lastExternalAttribute = source.lastExternalAttribute;
        _saveToScrollbackInAlternateScreen = source.saveToScrollbackInAlternateScreen;
        _cursorVisible = source.cursorVisible;
        _shellIntegrationInstalled = source.shellIntegrationInstalled;
        _lastCommandOutputRange = source.lastCommandOutputRange;
        _currentPromptRange = source.currentPromptRange;
        _startOfRunningCommandOutput = source.startOfRunningCommandOutput;
        _protectedMode = source.protectedMode;
        _initialSize = source.initialSize;
        _cumulativeScrollbackOverflow = source.cumulativeScrollbackOverflow;
        _trackCursorLineMovement = source.trackCursorLineMovement;
        _appendToScrollbackWithStatusBar = source.appendToScrollbackWithStatusBar;
        _normalization = source.normalization;
        _fakePromptDetectedAbsLine = source.fakePromptDetectedAbsLine;
        _lastPromptLine = source.lastPromptLine;
        _needsRedraw = source.needsRedraw;

        _intervalTreeObserver = source.intervalTreeObserver;
#warning TODO: I need a read-only protocol for VT100ScreenMark
        _lastCommandMark = [source.lastCommandMark copy];
        _shouldExpectPromptMarks = source.shouldExpectPromptMarks;

        _linebuffer = [source.linebuffer copy];
        NSMutableDictionary<NSNumber *, id<iTermMark>> *temp = [NSMutableDictionary dictionary];
        [source.markCache enumerateKeysAndObjectsUsingBlock:^(NSNumber * _Nonnull key, id<iTermMark>  _Nonnull obj, BOOL * _Nonnull stop) {
            NSDictionary *encoded = [obj dictionaryValue];
            Class theClass = [obj class];
            // TODO: This is going to be really slow. Marks being mutable is going to be a problem.
            // I think that very few kinds of marks are actually mutable, and in those cases a journal
            // might provide a cheap way to update an existing copy.
            temp[key] = [[theClass alloc] initWithDictionary:encoded];
        }];
        _markCache = temp;

        _animatedLines = [source.animatedLines copy];
        _pasteboardString = [source.pasteboardString copy];
        _intervalTree = [source.intervalTree copy];
        _savedIntervalTree = [source.savedIntervalTree copy];
        _findContext = [source.findContext copy];
        _tabStops = [source.tabStops copy];
        _charsetUsesLineDrawingMode = [source.charsetUsesLineDrawingMode copy];
        _colorMap = [source.colorMap copy];
        _temporaryDoubleBuffer = [source.temporaryDoubleBuffer copy];
        _sideEffects = [source.sideEffects copy];
    }
    return self;
}

- (void)dealloc {
    [_temporaryDoubleBuffer reset];
}

#pragma mark - Grid

- (int)cursorY {
    return self.currentGrid.cursorY + 1;
}

- (int)cursorX {
    return self.currentGrid.cursorX + 1;
}

- (int)width {
    return self.currentGrid.size.width;
}

- (int)height {
    return self.currentGrid.size.height;
}

#pragma mark - Scollback

- (int)numberOfScrollbackLines {
    return [self.linebuffer numLinesWithWidth:self.currentGrid.size.width];
}

#pragma mark - Interval Tree

- (VT100GridCoordRange)coordRangeForInterval:(Interval *)interval {
    VT100GridCoordRange result;
    const int w = self.width + 1;
    result.start.y = interval.location / w - self.cumulativeScrollbackOverflow;
    result.start.x = interval.location % w;
    result.end.y = interval.limit / w - self.cumulativeScrollbackOverflow;
    result.end.x = interval.limit % w;

    if (result.start.y < 0) {
        result.start.y = 0;
        result.start.x = 0;
    }
    if (result.start.x == self.width) {
        result.start.y += 1;
        result.start.x = 0;
    }
    return result;
}

- (VT100GridRange)lineNumberRangeOfInterval:(Interval *)interval {
    VT100GridCoordRange range = [self coordRangeForInterval:interval];
    return VT100GridRangeMake(range.start.y, range.end.y - range.start.y + 1);
}

- (Interval *)intervalForGridCoordRange:(VT100GridCoordRange)range {
    return [self intervalForGridCoordRange:range
                                     width:self.width
                               linesOffset:self.cumulativeScrollbackOverflow];
}

- (Interval *)intervalForGridCoordRange:(VT100GridCoordRange)range
                                  width:(int)width
                            linesOffset:(long long)linesOffset {
    VT100GridCoord start = range.start;
    VT100GridCoord end = range.end;
    long long si = start.y;
    si += linesOffset;
    si *= (width + 1);
    si += start.x;
    long long ei = end.y;
    ei += linesOffset;
    ei *= (width + 1);
    ei += end.x;
    if (ei < si) {
        long long temp = ei;
        ei = si;
        si = temp;
    }
    return [Interval intervalWithLocation:si length:ei - si];
}

#pragma mark - Combined Grid And Scrollback

- (int)numberOfLines {
    return [self.linebuffer numLinesWithWidth:self.currentGrid.size.width] + self.currentGrid.size.height;
}

#pragma mark - Shell Integration

- (VT100ScreenMark *)lastCommandMark {
    DLog(@"Searching for last command mark...");
    if (_lastCommandMark) {
        DLog(@"Return cached mark %@", _lastCommandMark);
        return _lastCommandMark;
    }
    NSEnumerator *enumerator = [self.intervalTree reverseLimitEnumerator];
    NSArray *objects = [enumerator nextObject];
    int numChecked = 0;
    while (objects && numChecked < 500) {
        for (id<IntervalTreeObject> obj in objects) {
            if ([obj isKindOfClass:[VT100ScreenMark class]]) {
                VT100ScreenMark *mark = (VT100ScreenMark *)obj;
                if (mark.command) {
                    DLog(@"Found mark %@ in line number range %@", mark,
                         VT100GridRangeDescription([self lineNumberRangeOfInterval:obj.entry.interval]));
                    _lastCommandMark = mark;
                    return mark;
                }
            }
            ++numChecked;
        }
        objects = [enumerator nextObject];
    }

    DLog(@"No last command mark found");
    return nil;
}

@end
