//
//  VT100ScreenMutableState+Resizing.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 1/10/22.
//

#import "VT100ScreenMutableState+Resizing.h"

#import "DebugLogging.h"
#import "PTYAnnotation.h"
#import "VT100RemoteHost.h"
#import "VT100ScreenDelegate.h"
#import "VT100WorkingDirectory.h"
#import "iTermImageMark.h"
#import "iTermSelection.h"
#import "iTermURLMark.h"

@implementation VT100ScreenMutableState (Resizing)

- (void)setSize:(VT100GridSize)proposedSize
      visibleLines:(VT100GridRange)previouslyVisibleLineRange
         selection:(iTermSelection *)selection
           hasView:(BOOL)hasView
       delegate:(id<VT100ScreenDelegate>)delegate {
    const VT100GridSize newSize = [self safeSizeForSize:proposedSize];
    if (![self shouldSetSizeTo:newSize]) {
        return;
    }
    [self.linebuffer beginResizing];
    [self reallySetSize:newSize
           visibleLines:previouslyVisibleLineRange
              selection:selection
               delegate:delegate
                hasView:hasView];
    [self.linebuffer endResizing];

    if (gDebugLogging) {
        DLog(@"Notes after resizing to width=%@", @(self.width));
        for (id<IntervalTreeObject> object in self.intervalTree.allObjects) {
            if (![object isKindOfClass:[PTYAnnotation class]]) {
                continue;
            }
            DLog(@"Note has coord range %@", VT100GridCoordRangeDescription([self coordRangeForInterval:object.entry.interval]));
        }
        DLog(@"------------ end -----------");
    }
}

#pragma mark - Private

- (VT100GridSize)safeSizeForSize:(VT100GridSize)proposedSize {
    VT100GridSize size;
    size.width = MAX(proposedSize.width, 1);
    size.height = MAX(proposedSize.height, 1);
    return size;
}

- (BOOL)shouldSetSizeTo:(VT100GridSize)size {
    [self.temporaryDoubleBuffer reset];

    DLog(@"Resize session to %@", VT100GridSizeDescription(size));
    DLog(@"Before:\n%@", [self.currentGrid compactLineDumpWithContinuationMarks]);
    DLog(@"Cursor at %d,%d", self.currentGrid.cursorX, self.currentGrid.cursorY);
    if (self.commandStartCoord.x != -1) {
        [self didUpdatePromptLocation];
        [self commandDidEndWithRange:self.commandRange];
        [self invalidateCommandStartCoordWithoutSideEffects];
    }
    self.lastCommandMark = nil;

    if (self.currentGrid.size.width == 0 ||
        self.currentGrid.size.height == 0 ||
        (size.width == self.currentGrid.size.width &&
         size.height == self.currentGrid.size.height)) {
        return NO;
    }
    return YES;
}

- (void)sanityCheckIntervalsFrom:(VT100GridSize)oldSize note:(NSString *)note {
#if BETA
    for (id<IntervalTreeObject> obj in [self.intervalTree allObjects]) {
        IntervalTreeEntry *entry = obj.entry;
        Interval *interval = entry.interval;
        ITBetaAssert(interval.limit >= 0, @"Bogus interval %@ after resizing from %@ to %@. Note: %@",
                     interval, VT100GridSizeDescription(oldSize), VT100GridSizeDescription(self.currentGrid.size),
                     note);
    }
#endif
}

- (void)willSetSizeWithSelection:(iTermSelection *)selection {
    if (selection.live) {
        [selection endLiveSelection];
    }
    [selection removeWindowsWithWidth:self.width];
}

// This assumes the window's height is going to change to newHeight but self.currentGrid.size.height
// is still the "old" height. Returns the number of lines appended.
- (int)appendScreen:(VT100Grid *)grid
        toScrollback:(LineBuffer *)lineBufferToUse
      withUsedHeight:(int)usedHeight
           newHeight:(int)newHeight {
    int n;
    if (grid.size.height - newHeight >= usedHeight) {
        // Height is decreasing but pushing HEIGHT lines into the buffer would scroll all the used
        // lines off the top, leaving the cursor floating without any text. Keep all used lines that
        // fit onscreen.
        n = MAX(usedHeight, newHeight);
    } else {
        if (newHeight < grid.size.height) {
            // Screen is shrinking.
            // If possible, keep the last used line a fixed distance from the top of
            // the screen. If not, at least save all the used lines.
            n = usedHeight;
        } else {
            // Screen is not shrinking in height. New content may be brought in on top.
            n = grid.size.height;
        }
    }
    [grid appendLines:n toLineBuffer:lineBufferToUse];

    return n;
}

// It's kind of wrong to use VT100GridRun here, but I think it's harmless enough.
- (VT100GridRun)runByTrimmingNullsFromRun:(VT100GridRun)run {
    VT100GridRun result = run;
    int x = result.origin.x;
    int y = result.origin.y;
    ITBetaAssert(y >= 0, @"Negative y to runByTrimmingNullsFromRun");
    const screen_char_t *line = [self getLineAtIndex:y];
    int numberOfLines = self.numberOfLines;
    int width = self.width;
    if (x > 0) {
        while (result.length > 0 && line[x].code == 0 && y < numberOfLines) {
            x++;
            result.length--;
            if (x == width) {
                x = 0;
                y++;
                if (y == numberOfLines) {
                    // Run is all nulls
                    result.length = 0;
                    return result;
                }
                break;
            }
        }
    }
    result.origin = VT100GridCoordMake(x, y);

    VT100GridCoord end = VT100GridRunMax(run, width);
    x = end.x;
    y = end.y;
    ITBetaAssert(y >= 0, @"Negative y to from max of run %@", VT100GridRunDescription(run));
    line = [self getLineAtIndex:y];
    if (x < width - 1) {
        while (result.length > 0 && line[x].code == 0 && y < numberOfLines) {
            x--;
            result.length--;
            if (x == -1) {
                break;
            }
        }
    }
    return result;
}

static BOOL XYIsBeforeXY(int px1, int py1, int px2, int py2) {
    if (py1 == py2) {
        return px1 < px2;
    } else if (py1 < py2) {
        return YES;
    } else {
        return NO;
    }
}

static void SwapInt(int *a, int *b) {
    int temp = *a;
    *a = *b;
    *b = temp;
}

- (BOOL)trimSelectionFromStart:(VT100GridCoord)start
                           end:(VT100GridCoord)end
                      toStartX:(VT100GridCoord *)startPtr
                        toEndX:(VT100GridCoord *)endPtr {
    if (start.x < 0 || end.x < 0 ||
        start.y < 0 || end.y < 0) {
        *startPtr = start;
        *endPtr = end;
        return YES;
    }

    if (!XYIsBeforeXY(start.x, start.y, end.x, end.y)) {
        SwapInt(&start.x, &end.x);
        SwapInt(&start.y, &end.y);
    }

    // Advance start position until it hits a non-null or equals the end position.
    int startX = start.x;
    int startY = start.y;
    if (startX == self.currentGrid.size.width) {
        startX = 0;
        startY++;
    }

    int endX = end.x;
    int endY = end.y;
    if (endX == self.currentGrid.size.width) {
        endX = 0;
        endY++;
    }

    VT100GridRun run = VT100GridRunFromCoords(VT100GridCoordMake(startX, startY),
                                              VT100GridCoordMake(endX, endY),
                                              self.currentGrid.size.width);
    if (run.length <= 0) {
        DLog(@"Run has length %@ given start and end of %@ and %@", @(run.length), VT100GridCoordDescription(start),
             VT100GridCoordDescription(end));
        return NO;
    }
    run = [self runByTrimmingNullsFromRun:run];
    if (run.length == 0) {
        DLog(@"After trimming, run has length 0 given start and end of %@ and %@", VT100GridCoordDescription(start),
             VT100GridCoordDescription(end));
        return NO;
    }
    VT100GridCoord max = VT100GridRunMax(run, self.currentGrid.size.width);

    *startPtr = run.origin;
    *endPtr = max;
    return YES;
}

- (LineBufferPositionRange *)positionRangeForCoordRange:(VT100GridCoordRange)range
                                           inLineBuffer:(LineBuffer *)lineBuffer
                                          tolerateEmpty:(BOOL)tolerateEmpty {
    assert(range.end.y >= 0);
    assert(range.start.y >= 0);

    LineBufferPositionRange *positionRange = [[LineBufferPositionRange alloc] init];

    BOOL endExtends = NO;
    // Use the predecessor of endx,endy so it will have a legal position in the line buffer.
    if (range.end.x == self.width) {
        const screen_char_t *line = [self getLineAtIndex:range.end.y];
        if (line[range.end.x - 1].code == 0 && line[range.end.x].code == EOL_HARD) {
            // The selection goes all the way to the end of the line and there is a null at the
            // end of the line, so it extends to the end of the line. The linebuffer can't recover
            // this from its position because the trailing null in the line wouldn't be in the
            // linebuffer.
            endExtends = YES;
        }
    }
    range.end.x--;
    if (range.end.x < 0) {
        range.end.y--;
        range.end.x = self.width - 1;
        if (range.end.y < 0) {
            return nil;
        }
    }

    if (range.start.x < 0 || range.start.y < 0 ||
        range.end.x < 0 || range.end.y < 0) {
        return nil;
    }

    VT100GridCoord trimmedStart;
    VT100GridCoord trimmedEnd;
    BOOL ok = [self trimSelectionFromStart:VT100GridCoordMake(range.start.x, range.start.y)
                                       end:VT100GridCoordMake(range.end.x, range.end.y)
                                  toStartX:&trimmedStart
                                    toEndX:&trimmedEnd];
    if (!ok) {
        if (tolerateEmpty) {
            trimmedStart = trimmedEnd = range.start;
        } else {
            return nil;
        }
    }
    if (VT100GridCoordOrder(trimmedStart, trimmedEnd) == NSOrderedDescending) {
        if (tolerateEmpty) {
            trimmedStart = trimmedEnd = range.start;
        } else {
            return nil;
        }
    }

    positionRange.start = [lineBuffer positionForCoordinate:trimmedStart
                                                      width:self.currentGrid.size.width
                                                     offset:0];
    positionRange.end = [lineBuffer positionForCoordinate:trimmedEnd
                                                    width:self.currentGrid.size.width
                                                   offset:0];
    positionRange.end.extendsToEndOfLine = endExtends;

    if (positionRange.start && positionRange.end) {
        return positionRange;
    } else {
        return nil;
    }
}

- (NSArray *)subSelectionTuplesWithUsedHeight:(int)usedHeight
                                    newHeight:(int)newHeight
                                    selection:(iTermSelection *)selection {
    // In alternate screen mode, get the original positions of the
    // selection. Later this will be used to set the selection positions
    // relative to the end of the updated linebuffer (which could change as
    // lines from the base screen are pushed onto it).
    LineBuffer *lineBufferWithAltScreen = [self.linebuffer copy];
    [self appendScreen:self.currentGrid
          toScrollback:lineBufferWithAltScreen
        withUsedHeight:usedHeight
             newHeight:newHeight];
    NSMutableArray *altScreenSubSelectionTuples = [NSMutableArray array];
    for (iTermSubSelection *sub in selection.allSubSelections) {
        VT100GridAbsCoordRangeTryMakeRelative(sub.absRange.coordRange,
                                              self.cumulativeScrollbackOverflow,
                                              ^(VT100GridCoordRange range) {
            LineBufferPositionRange *positionRange =
            [self positionRangeForCoordRange:range
                                inLineBuffer:lineBufferWithAltScreen
                               tolerateEmpty:NO];
            if (positionRange) {
                [altScreenSubSelectionTuples addObject:@[ positionRange, sub ]];
            } else {
                DLog(@"Failed to get position range for selection on alt screen %@",
                     VT100GridCoordRangeDescription(range));
            }
        });
    }
    return altScreenSubSelectionTuples;
}

- (BOOL)intervalTreeObjectMayBeEmpty:(id<IntervalTreeObject>)note {
    // These kinds of ranges are allowed to be empty because
    // although they nominally refer to an entire line, sometimes
    // that line is blank such as just before the prompt is
    // printed. See issue 4261.
    return ([note isKindOfClass:[VT100RemoteHost class]] ||
            [note isKindOfClass:[VT100WorkingDirectory class]] ||
            [note isKindOfClass:[iTermImageMark class]] ||
            [note isKindOfClass:[iTermURLMark class]] ||
            [note isKindOfClass:[PTYAnnotation class]]);
}

- (NSArray *)intervalTreeObjectsWithUsedHeight:(int)usedHeight
                                     newHeight:(int)newHeight
                                          grid:(VT100Grid *)grid
                                    lineBuffer:(LineBuffer *)realLineBuffer {
    // Add notes that were on the alt grid to altScreenNotes, leaving notes in history alone.
    VT100GridCoordRange screenCoordRange =
    VT100GridCoordRangeMake(0,
                            self.numberOfScrollbackLines,
                            0,
                            self.numberOfScrollbackLines + self.height);
    NSArray *notesAtLeastPartiallyOnScreen =
    [self.intervalTree objectsInInterval:[self intervalForGridCoordRange:screenCoordRange]];

    LineBuffer *appendOnlyLineBuffer = [realLineBuffer copy];
    [self appendScreen:grid
                  toScrollback:appendOnlyLineBuffer
                withUsedHeight:usedHeight
                     newHeight:newHeight];

    NSMutableArray *triples = [NSMutableArray array];

    for (id<IntervalTreeObject> note in notesAtLeastPartiallyOnScreen) {
        VT100GridCoordRange range = [self coordRangeForInterval:note.entry.interval];
        [self.intervalTree removeObject:note];
        LineBufferPositionRange *positionRange =
        [self positionRangeForCoordRange:range
                                    inLineBuffer:appendOnlyLineBuffer
                                   tolerateEmpty:[self intervalTreeObjectMayBeEmpty:note]];
        if (positionRange) {
            DLog(@"Add note on alt screen at %@ (position %@ to %@) to triples",
                 VT100GridCoordRangeDescription(range),
                 positionRange.start,
                 positionRange.end);
            [triples addObject:@[ note, positionRange.start, positionRange.end ]];
        } else {
            DLog(@"Failed to get position range while in alt screen for note %@ with range %@",
                 note, VT100GridCoordRangeDescription(range));
        }
    }
    return triples;
}

- (LineBuffer *)prepareToResizeInAlternateScreenMode:(NSArray **)altScreenSubSelectionTuplesPtr
                                 intervalTreeObjects:(NSArray **)altScreenNotesPtr
                                        hasSelection:(BOOL)couldHaveSelection
                                           selection:(iTermSelection *)selection
                                          lineBuffer:(LineBuffer *)realLineBuffer
                                          usedHeight:(int)usedHeight
                                             newSize:(VT100GridSize)newSize {
    if (couldHaveSelection) {
        *altScreenSubSelectionTuplesPtr = [self subSelectionTuplesWithUsedHeight:usedHeight
                                                                       newHeight:newSize.height
                                                                       selection:selection];
    }

    LineBuffer *altScreenLineBuffer = [[LineBuffer alloc] init];
    [altScreenLineBuffer beginResizing];
    [self appendScreen:self.altGrid
          toScrollback:altScreenLineBuffer
        withUsedHeight:usedHeight
             newHeight:newSize.height];

    if ([self.intervalTree count]) {
        *altScreenNotesPtr = [self intervalTreeObjectsWithUsedHeight:usedHeight
                                                           newHeight:newSize.height
                                                                grid:self.altGrid
                                                          lineBuffer:realLineBuffer];
    }

    self.currentGrid = self.primaryGrid;
    // Move savedIntervalTree_ into intervalTree_. This should leave savedIntervalTree_ empty.
    [self swapOnscreenIntervalTreeObjects];
    self.currentGrid = self.altGrid;

    return altScreenLineBuffer;
}

- (BOOL)convertRange:(VT100GridCoordRange)range
             toWidth:(int)newWidth
                  to:(VT100GridCoordRange *)resultPtr
        inLineBuffer:(LineBuffer *)lineBuffer
       tolerateEmpty:(BOOL)tolerateEmpty {
    if (range.start.y < 0 || range.end.y < 0) {
        return NO;
    }

    // Temporarily swap in the passed-in linebuffer so the call below can access lines in the right line buffer.
    LineBuffer *savedLineBuffer = self.linebuffer;
    self.linebuffer = lineBuffer;
    LineBufferPositionRange *selectionRange = [self positionRangeForCoordRange:range
                                                                  inLineBuffer:lineBuffer
                                                                 tolerateEmpty:tolerateEmpty];
    DLog(@"%@ -> %@", VT100GridCoordRangeDescription(range), selectionRange);
    self.linebuffer = savedLineBuffer;
    if (!selectionRange) {
        // One case where this happens is when the start and end of the range are past the last
        // character in the line buffer (e.g., all nulls). It could occur when a note exists on a
        // null line.
        return NO;
    }

    resultPtr->start = [lineBuffer coordinateForPosition:selectionRange.start
                                                   width:newWidth
                                            extendsRight:NO
                                                      ok:NULL];
    BOOL ok = NO;
    VT100GridCoord newEnd = [lineBuffer coordinateForPosition:selectionRange.end
                                                        width:newWidth
                                                 extendsRight:YES
                                                           ok:&ok];
    if (ok) {
        newEnd.x++;
        if (newEnd.x > newWidth) {
            newEnd.y++;
            newEnd.x -= newWidth;
        }
        resultPtr->end = newEnd;
    } else {
        // I'm not sure how to get here. It would happen if the endpoint of the selection could
        // be converted into a LineBufferPosition with the original width but that LineBufferPosition
        // could not be converted back into a VT100GridCoord with the new width.
        resultPtr->end.x = self.currentGrid.size.width;
        resultPtr->end.y = [lineBuffer numLinesWithWidth:newWidth] + self.currentGrid.size.height - 1;
    }
    if (selectionRange.end.extendsToEndOfLine) {
        resultPtr->end.x = newWidth;
    }
    return YES;
}

- (NSArray *)subSelectionsWithConvertedRangesFromSelection:(iTermSelection *)selection
                                                  newWidth:(int)newWidth {
    NSMutableArray *newSubSelections = [NSMutableArray array];
    const long long overflow = self.cumulativeScrollbackOverflow;
    for (iTermSubSelection *sub in selection.allSubSelections) {
        DLog(@"convert sub %@", sub);
        VT100GridAbsCoordRangeTryMakeRelative(sub.absRange.coordRange,
                                              overflow,
                                              ^(VT100GridCoordRange range) {
            VT100GridCoordRange newSelection;
            const BOOL ok = [self convertRange:range
                                               toWidth:newWidth
                                                    to:&newSelection
                                          inLineBuffer:self.linebuffer
                                         tolerateEmpty:NO];
            if (ok) {
                assert(range.start.y >= 0);
                assert(range.end.y >= 0);
                const VT100GridWindowedRange relativeRange = VT100GridWindowedRangeMake(newSelection, 0, 0);
                const VT100GridAbsWindowedRange absRange =
                VT100GridAbsWindowedRangeFromWindowedRange(relativeRange, overflow);
                iTermSubSelection *theSub =
                [iTermSubSelection subSelectionWithAbsRange:absRange
                                                       mode:sub.selectionMode
                                                      width:newWidth];
                theSub.connected = sub.connected;
                [newSubSelections addObject:theSub];
            }
        });
    }
    return newSubSelections;
}

- (IntervalTree *)replacementIntervalTreeForNewWidth:(int)newWidth {
    // Convert ranges of notes to their new coordinates and replace the interval tree.
    IntervalTree *replacementTree = [[IntervalTree alloc] init];
    for (id<IntervalTreeObject> note in [self.intervalTree allObjects]) {
        VT100GridCoordRange noteRange = [self coordRangeForInterval:note.entry.interval];
        VT100GridCoordRange newRange;
        if (noteRange.end.x < 0 && noteRange.start.y == 0 && noteRange.end.y < 0) {
            // note has scrolled off top
            [self.intervalTree removeObject:note];
        } else {
            if ([self convertRange:noteRange
                           toWidth:newWidth
                                to:&newRange
                      inLineBuffer:self.linebuffer
                     tolerateEmpty:[self intervalTreeObjectMayBeEmpty:note]]) {
                assert(noteRange.start.y >= 0);
                assert(noteRange.end.y >= 0);
                Interval *newInterval = [self intervalForGridCoordRange:newRange
                                                                  width:newWidth
                                                            linesOffset:self.cumulativeScrollbackOverflow];
                [self.intervalTree removeObject:note];
                [replacementTree addObject:note withInterval:newInterval];
            }
        }
    }
    return replacementTree;
}

- (void)fixUpPrimaryGridIntervalTreeForNewSize:(VT100GridSize)newSize
                           wasShowingAltScreen:(BOOL)wasShowingAltScreen {
    if ([self.intervalTree count]) {
        // Fix up the intervals for the primary grid.
        if (wasShowingAltScreen) {
            // Temporarily swap in primary grid so convertRange: will do the right thing.
            self.currentGrid = self.primaryGrid;
        }

        self.intervalTree = [self replacementIntervalTreeForNewWidth:newSize.width];

        if (wasShowingAltScreen) {
            // Return to alt grid.
            self.currentGrid = self.altGrid;
        }
    }
}

- (void)restorePrimaryGridWithLineBuffer:(LineBuffer *)realLineBuffer
                                 oldSize:(VT100GridSize)oldSize
                                 newSize:(VT100GridSize)newSize {
    self.primaryGrid.size = newSize;
    [self.primaryGrid setCharsFrom:VT100GridCoordMake(0, 0)
                                to:VT100GridCoordMake(newSize.width - 1, newSize.height - 1)
                            toChar:self.primaryGrid.savedDefaultChar
                externalAttributes:nil];
    // If the height increased:
    // Growing (avoid pulling in stuff from scrollback. Add blank lines
    // at bottom instead). Note there's a little hack here: we use saved_primary_buffer as the default
    // line because it was just initialized with default lines.
    //
    // If the height decreased or stayed the same:
    // Shrinking (avoid pulling in stuff from scrollback, pull in no more
    // than might have been pushed, even if more is available). Note there's a little hack
    // here: we use saved_primary_buffer as the default line because it was just initialized with
    // default lines.
    [self.primaryGrid restoreScreenFromLineBuffer:realLineBuffer
                                  withDefaultChar:[self.primaryGrid defaultChar]
                                maxLinesToRestore:MIN(oldSize.height, newSize.height)];
}

// This is used for a very specific case. It's used when you have some history, optionally followed
// by lines pulled from the primary grid, followed by the alternate grid, all stuffed into a line
// buffer. Given a pair of positions, it converts them to a range. If a position is between
// originalLastPos and newLastPos, it's invalid. Likewise, if a position is in the first
// |linesMovedUp| lines of the screen, it's invalid.
// NOTE: This assumes that _mutableState.linebuffer contains the history plus lines from the primary grid.
// Returns YES if the range is valid, NO if it could not be converted (e.g., because it was entirely
// in the area of dropped lines).
/*
 * 0 History      }                                                                     }
 * 1 History      } These lines were in history before resizing began                   }
 * 2 History      }                    <- originalLimit                                 } equal to _mutableState.linebuffer
 * 3 Line from primary grid            <- limit (pushed into history due to resize)     }
 * 4 Line to be lost from alt grid     <- linesMovedUp = 1 because this one line will be lost
 * 5 Line from alt grid                }
 * 6 Line from alt grid                } These lines will be restored to the alt grid later
 */
- (BOOL)computeRangeFromOriginalLimit:(LineBufferPosition *)originalLimit
                        limitPosition:(LineBufferPosition *)limit
                        startPosition:(LineBufferPosition *)startPos
                          endPosition:(LineBufferPosition *)endPos
                             newWidth:(int)newWidth
                           lineBuffer:(LineBuffer *)lineBuffer  // NOTE: May be append-only
                                range:(VT100GridCoordRange *)resultRangePtr
                         linesMovedUp:(int)linesMovedUp {
    BOOL result = YES;
    // Compute selection positions relative to the end of the line buffer, which may have
    // grown or shrunk.
    int growth = limit.absolutePosition - originalLimit.absolutePosition;
    LineBufferPosition *savedEndPos = endPos;
    LineBufferPosition *predecessorOfLimit = [limit predecessor];
    if (growth > 0) {
        /*
         +--------------------+
         |                    |
         |  Original History  |
         |                    |
         +....................+ <------- originalLimit
         | Lines pushed from  | ^
         | primary into       | |- growth = number of lines in this section
         | history            | V
         +--------------------+ <------- limit
         |                    |
         | Alt screen         |
         |                    |
         +--------------------+
         */
        if (startPos.absolutePosition >= originalLimit.absolutePosition) {
            // Start position was on alt screen originally. Move it down by the number of lines
            // pulled in from the primary screen.
            startPos.absolutePosition += growth;
        }
        if (endPos.absolutePosition >= originalLimit.absolutePosition) {
            // End position was on alt screen originally. Move it down by the number of lines
            // pulled in from the primary screen.
            endPos.absolutePosition += growth;
        }
    } else if (growth < 0) {
        /*
         +--------------------+
         |                    |
         | Original history   |
         |                    |
         +--------------------+ +....................+ <------- limit
         | Current alt screen | | Lines pulled back  | ^
         |                    | | into primary from  | |- growth = -(number of lines in this section)
         +--------------------+ | history            | V
         +--------------------+ <------- originalLimit
         | Original           |
         | Alt screen         |
         +--------------------+
         */
        if (startPos.absolutePosition >= limit.absolutePosition &&
            startPos.absolutePosition < originalLimit.absolutePosition) {
            // Started in history in the region pulled into primary screen. Advance start to
            // new beginning of alt screen
            startPos = limit;
        } else if (startPos.absolutePosition >= originalLimit.absolutePosition) {
            // Starts after deleted region. Move start position up by number of deleted lines so
            // it refers to the same cell.
            startPos.absolutePosition += growth;
        }
        if (endPos.absolutePosition >= predecessorOfLimit.absolutePosition &&
            endPos.absolutePosition < originalLimit.absolutePosition) {
            // Ended in deleted region. Move end point to just before current alt screen.
            endPos = predecessorOfLimit;
        } else if (endPos.absolutePosition >= originalLimit.absolutePosition) {
            // Ends in alt screen. Move it up to refer to the same cell.
            endPos.absolutePosition += growth;
        }
    }
    if (startPos.absolutePosition >= endPos.absolutePosition + 1) {
        result = NO;
    }
    resultRangePtr->start = [lineBuffer coordinateForPosition:startPos
                                                        width:newWidth
                                                 extendsRight:NO
                                                           ok:NULL];
    int numScrollbackLines = [self.linebuffer numLinesWithWidth:newWidth];

    // |linesMovedUp| wrapped lines will not be restored into the alt grid later on starting at |limit|
    if (resultRangePtr->start.y >= numScrollbackLines) {
        if (resultRangePtr->start.y < numScrollbackLines + linesMovedUp) {
            // The selection started in one of the lines that was lost. Move it to the
            // first cell of the screen.
            resultRangePtr->start.y = numScrollbackLines;
            resultRangePtr->start.x = 0;
        } else {
            // The selection starts on screen, so move it up by the number of lines by which
            // the alt screen shifted up.
            resultRangePtr->start.y -= linesMovedUp;
        }
    }

    resultRangePtr->end = [lineBuffer coordinateForPosition:endPos
                                                      width:newWidth
                                               extendsRight:YES
                                                         ok:NULL];
    if (resultRangePtr->end.y >= numScrollbackLines) {
        if (resultRangePtr->end.y < numScrollbackLines + linesMovedUp) {
            // The selection ends in one of the lines that was lost. The whole selection is
            // gone.
            result = NO;
        } else {
            // The selection ends on screen, so move it up by the number of lines by which
            // the alt screen shifted up.
            resultRangePtr->end.y -= linesMovedUp;
        }
    }
    if (savedEndPos.extendsToEndOfLine) {
        resultRangePtr->end.x = newWidth;
    } else {
        // Move to the successor of newSelection.end.x, newSelection.end.y.
        resultRangePtr->end.x++;
        if (resultRangePtr->end.x > newWidth) {
            resultRangePtr->end.x -= newWidth;
            resultRangePtr->end.y++;
        }
    }

    return result;
}

- (void)addObjectsToIntervalTreeFromTuples:(NSArray *)altScreenNotes
                                   newSize:(VT100GridSize)newSize
                      originalLastPosition:(LineBufferPosition *)originalLastPos
                           newLastPosition:(LineBufferPosition *)newLastPos
                              linesMovedUp:(int)linesMovedUp
                      appendOnlyLineBuffer:(LineBuffer *)appendOnlyLineBuffer {
    for (NSArray *tuple in altScreenNotes) {
        id<IntervalTreeObject> note = tuple[0];
        LineBufferPosition *start = tuple[1];
        LineBufferPosition *end = tuple[2];
        VT100GridCoordRange newRange;
        DLog(@"  Note positions=%@ to %@", start, end);
        BOOL ok = [self computeRangeFromOriginalLimit:originalLastPos
                                                limitPosition:newLastPos
                                                startPosition:start
                                                  endPosition:end
                                                     newWidth:newSize.width
                                                   lineBuffer:appendOnlyLineBuffer
                                                        range:&newRange
                                                 linesMovedUp:linesMovedUp];
        if (ok) {
            DLog(@"  New range=%@", VT100GridCoordRangeDescription(newRange));
            Interval *interval = [self intervalForGridCoordRange:newRange
                                                                    width:newSize.width
                                                              linesOffset:self.cumulativeScrollbackOverflow];
            [self.intervalTree addObject:note withInterval:interval];
        } else {
            DLog(@"  *FAILED TO CONVERT*");
        }
    }
}

- (NSArray *)subSelectionsForNewSize:(VT100GridSize)newSize
                          lineBuffer:(LineBuffer *)realLineBuffer
                                grid:(VT100Grid *)copyOfAltGrid
                          usedHeight:(int)usedHeight
                  subSelectionTuples:(NSArray *)altScreenSubSelectionTuples
                originalLastPosition:(LineBufferPosition *)originalLastPos
                     newLastPosition:(LineBufferPosition *)newLastPos
                        linesMovedUp:(int)linesMovedUp
                appendOnlyLineBuffer:(LineBuffer *)appendOnlyLineBuffer {
    [self appendScreen:copyOfAltGrid
                  toScrollback:appendOnlyLineBuffer
                withUsedHeight:usedHeight
                     newHeight:newSize.height];

    NSMutableArray *newSubSelections = [NSMutableArray array];
    for (int i = 0; i < altScreenSubSelectionTuples.count; i++) {
        LineBufferPositionRange *positionRange = altScreenSubSelectionTuples[i][0];
        iTermSubSelection *originalSub = altScreenSubSelectionTuples[i][1];
        VT100GridCoordRange newSelection;
        BOOL ok = [self computeRangeFromOriginalLimit:originalLastPos
                                                limitPosition:newLastPos
                                                startPosition:positionRange.start
                                                  endPosition:positionRange.end
                                                     newWidth:newSize.width
                                                   lineBuffer:appendOnlyLineBuffer
                                                        range:&newSelection
                                                 linesMovedUp:linesMovedUp];
        if (ok) {
            const VT100GridAbsWindowedRange theRange =
            VT100GridAbsWindowedRangeMake(VT100GridAbsCoordRangeFromCoordRange(newSelection, self.cumulativeScrollbackOverflow),
                                          0, 0);
            iTermSubSelection *theSub = [iTermSubSelection subSelectionWithAbsRange:theRange
                                                                               mode:originalSub.selectionMode
                                                                              width:self.width];
            theSub.connected = originalSub.connected;
            [newSubSelections addObject:theSub];
        }
    }
    return newSubSelections;
}

- (NSArray *)subSelectionsAfterRestoringPrimaryGridWithCopyOfAltGrid:(VT100Grid *)copyOfAltGrid
                                                        linesMovedUp:(int)linesMovedUp
                                                        toLineBuffer:(LineBuffer *)realLineBuffer
                                                  subSelectionTuples:(NSArray *)altScreenSubSelectionTuples
                                                originalLastPosition:(LineBufferPosition *)originalLastPos
                                                             oldSize:(VT100GridSize)oldSize
                                                             newSize:(VT100GridSize)newSize
                                                          usedHeight:(int)usedHeight
                                                 intervalTreeObjects:(NSArray *)altScreenNotes {
    [self restorePrimaryGridWithLineBuffer:realLineBuffer
                                           oldSize:oldSize
                                           newSize:newSize];

    // Any onscreen notes in primary grid get moved to savedIntervalTree_.
    self.currentGrid = self.primaryGrid;
    [self swapOnscreenIntervalTreeObjects];
    self.currentGrid = self.altGrid;

    ///////////////////////////////////////
    // Create a cheap append-only copy of the line buffer and add the
    // screen to it. This sets up the current state so that if there is a
    // selection, linebuffer has the configuration that the user actually
    // sees (history + the alt screen contents). That'll make
    // convertRange:toWidth:... happy (the selection's Y values
    // will be able to be looked up) and then after that's done we can swap
    // back to the tempLineBuffer.
    LineBuffer *appendOnlyLineBuffer = [realLineBuffer copy];
    LineBufferPosition *newLastPos = [realLineBuffer lastPosition];
    NSArray *newSubSelections = [self subSelectionsForNewSize:newSize
                                                           lineBuffer:realLineBuffer
                                                                 grid:copyOfAltGrid
                                                           usedHeight:usedHeight
                                                   subSelectionTuples:altScreenSubSelectionTuples
                                                 originalLastPosition:originalLastPos
                                                      newLastPosition:newLastPos
                                                         linesMovedUp:linesMovedUp
                                                 appendOnlyLineBuffer:appendOnlyLineBuffer];
    DLog(@"Original limit=%@", originalLastPos);
    DLog(@"New limit=%@", newLastPos);
    [self addObjectsToIntervalTreeFromTuples:altScreenNotes
                                             newSize:newSize
                                originalLastPosition:originalLastPos
                                     newLastPosition:newLastPos
                                        linesMovedUp:linesMovedUp
                                appendOnlyLineBuffer:appendOnlyLineBuffer];
    return newSubSelections;
}

- (void)updateAlternateScreenIntervalTreeForNewSize:(VT100GridSize)newSize {
    // Append alt screen to empty line buffer
    LineBuffer *altScreenLineBuffer = [[LineBuffer alloc] init];
    [altScreenLineBuffer beginResizing];
    [self appendScreen:self.altGrid
          toScrollback:altScreenLineBuffer
        withUsedHeight:[self.altGrid numberOfLinesUsed]
             newHeight:newSize.height];
    int numLinesThatWillBeRestored = MIN([altScreenLineBuffer numLinesWithWidth:newSize.width],
                                         newSize.height);
    int numLinesDroppedFromTop = [altScreenLineBuffer numLinesWithWidth:newSize.width] - numLinesThatWillBeRestored;

    // Convert note ranges to new coords, dropping or truncating as needed
    self.currentGrid = self.altGrid;  // Swap to alt grid temporarily for convertRange:toWidth:to:inLineBuffer:
    IntervalTree *replacementTree = [[IntervalTree alloc] init];
    for (id<IntervalTreeObject> object in [self.savedIntervalTree allObjects]) {
        VT100GridCoordRange objectRange = [self coordRangeForInterval:object.entry.interval];
        DLog(@"Found object at %@", VT100GridCoordRangeDescription(objectRange));
        VT100GridCoordRange newRange;
        if ([self convertRange:objectRange
                       toWidth:newSize.width
                            to:&newRange
                  inLineBuffer:altScreenLineBuffer
                 tolerateEmpty:[self intervalTreeObjectMayBeEmpty:object]]) {
            assert(objectRange.start.y >= 0);
            assert(objectRange.end.y >= 0);
            // Anticipate the lines that will be dropped when the alt grid is restored.
            newRange.start.y += self.cumulativeScrollbackOverflow - numLinesDroppedFromTop;
            newRange.end.y += self.cumulativeScrollbackOverflow - numLinesDroppedFromTop;
            if (newRange.start.y < 0) {
                newRange.start.y = 0;
                newRange.start.x = 0;
            }
            DLog(@"  Its new range is %@ including %d lines dropped from top", VT100GridCoordRangeDescription(objectRange), numLinesDroppedFromTop);
            [self.savedIntervalTree removeObject:object];
            if (newRange.end.y > 0 || (newRange.end.y == 0 && newRange.end.x > 0)) {
                Interval *newInterval = [self intervalForGridCoordRange:newRange
                                                                  width:newSize.width
                                                            linesOffset:0];
                [replacementTree addObject:object withInterval:newInterval];
            } else {
                DLog(@"Failed to convert");
            }
        }
    }
    self.savedIntervalTree = replacementTree;
    self.currentGrid = self.primaryGrid;  // Swap back to primary grid

    // Restore alt screen with new width
    self.altGrid.size = VT100GridSizeMake(newSize.width, newSize.height);
    [self.altGrid restoreScreenFromLineBuffer:altScreenLineBuffer
                              withDefaultChar:[self.altGrid defaultChar]
                            maxLinesToRestore:[altScreenLineBuffer numLinesWithWidth:self.currentGrid.size.width]];
    [altScreenLineBuffer endResizing];
}

- (void)didResizeToSize:(VT100GridSize)newSize
              selection:(iTermSelection *)selection
     couldHaveSelection:(BOOL)couldHaveSelection
          subSelections:(NSArray *)newSubSelections
                 newTop:(int)newTop
               delegate:(id<VT100ScreenDelegate>)delegate {
    [self.terminal clampSavedCursorToScreenSize:VT100GridSizeMake(newSize.width, newSize.height)];

    [self.primaryGrid resetScrollRegions];
    [self.altGrid resetScrollRegions];
    [self.primaryGrid clampCursorPositionToValid];
    [self.altGrid clampCursorPositionToValid];

    // The linebuffer may have grown. Ensure it doesn't have too many lines.
    int linesDropped = 0;
    if (!self.unlimitedScrollback) {
        linesDropped = [self.linebuffer dropExcessLinesWithWidth:self.currentGrid.size.width];
        [self incrementOverflowBy:linesDropped];
    }
    int lines __attribute__((unused)) = [self.linebuffer numLinesWithWidth:self.currentGrid.size.width];
    ITAssertWithMessage(lines >= 0, @"Negative lines");

    [selection clearSelection];
    // An immediate refresh is needed so that the size of textview can be
    // adjusted to fit the new size
    DebugLog(@"setSize setDirty");
    [delegate screenNeedsRedraw];
    if (couldHaveSelection) {
        NSMutableArray *subSelectionsToAdd = [NSMutableArray array];
        for (iTermSubSelection *sub in newSubSelections) {
            VT100GridAbsCoordRangeTryMakeRelative(sub.absRange.coordRange,
                                                  self.cumulativeScrollbackOverflow,
                                                  ^(VT100GridCoordRange range) {
                [subSelectionsToAdd addObject:sub];
            });
        }
        [selection addSubSelections:subSelectionsToAdd];
    }

    [self reloadMarkCache];
    [delegate screenSizeDidChangeWithNewTopLineAt:newTop];
}

- (void)reallySetSize:(VT100GridSize)newSize
         visibleLines:(VT100GridRange)previouslyVisibleLineRange
            selection:(iTermSelection *)selection
             delegate:(id<VT100ScreenDelegate>)delegate
              hasView:(BOOL)hasView {
    assert([NSThread isMainThread]);

    DLog(@"------------ reallySetSize");
    DLog(@"Set size to %@", VT100GridSizeDescription(newSize));

    const VT100GridCoordRange previouslyVisibleLines =
    VT100GridCoordRangeMake(0,
                            previouslyVisibleLineRange.location,
                            0,
                            previouslyVisibleLineRange.location + 1);

    [self sanityCheckIntervalsFrom:self.currentGrid.size note:@"pre-hoc"];
    [self.temporaryDoubleBuffer resetExplicitly];
    const VT100GridSize oldSize = self.currentGrid.size;
    [self willSetSizeWithSelection:selection];

    const BOOL couldHaveSelection = hasView && selection.hasSelection;
    const int usedHeight = [self.currentGrid numberOfLinesUsed];

    VT100Grid *copyOfAltGrid = [self.altGrid copy];
    LineBuffer *realLineBuffer = self.linebuffer;

    // This is an array of tuples:
    // [LineBufferPositionRange, iTermSubSelection]
    NSArray *altScreenSubSelectionTuples = nil;
    LineBufferPosition *originalLastPos = [self.linebuffer lastPosition];
    BOOL wasShowingAltScreen = (self.currentGrid == self.altGrid);


    // If non-nil, contains 3-tuples NSArray*s of
    // [ PTYAnnotation*,
    //   LineBufferPosition* for start of range,
    //   LineBufferPosition* for end of range ]
    // These will be re-added to intervalTree_ later on.
    NSArray *altScreenNotes = nil;

    // If we're in the alternate screen, create a temporary linebuffer and append
    // the base screen's contents to it.
    LineBuffer *altScreenLineBuffer = nil;
    if (wasShowingAltScreen) {
        altScreenLineBuffer = [self prepareToResizeInAlternateScreenMode:&altScreenSubSelectionTuples
                                                     intervalTreeObjects:&altScreenNotes
                                                            hasSelection:couldHaveSelection
                                                               selection:selection
                                                              lineBuffer:realLineBuffer
                                                              usedHeight:usedHeight
                                                                 newSize:newSize];
    }

    // Append primary grid to line buffer.
    [self appendScreen:self.primaryGrid
                  toScrollback:self.linebuffer
                withUsedHeight:[self.primaryGrid numberOfLinesUsed]
                     newHeight:newSize.height];
    DLog(@"History after appending screen to scrollback:\n%@", [self.linebuffer debugString]);

    VT100GridCoordRange convertedRangeOfVisibleLines;
    const BOOL rangeOfVisibleLinesConvertedCorrectly = [self convertRange:previouslyVisibleLines
                                                                          toWidth:newSize.width
                                                                               to:&convertedRangeOfVisibleLines
                                                                     inLineBuffer:self.linebuffer
                                                                    tolerateEmpty:YES];

    // Contains iTermSubSelection*s updated for the new screen size. Used
    // regardless of whether we were in the alt screen, as it's simply the set
    // of new sub-selections.
    NSArray *newSubSelections = @[];
    if (!wasShowingAltScreen && couldHaveSelection) {
        newSubSelections = [self subSelectionsWithConvertedRangesFromSelection:selection
                                                                              newWidth:newSize.width];
    }

    [self fixUpPrimaryGridIntervalTreeForNewSize:newSize
                                     wasShowingAltScreen:wasShowingAltScreen];
    self.currentGrid.size = newSize;

    // Restore the screen contents that were pushed onto the linebuffer.
    [self.currentGrid restoreScreenFromLineBuffer:wasShowingAltScreen ? altScreenLineBuffer : self.linebuffer
                                          withDefaultChar:[self.currentGrid defaultChar]
                                        maxLinesToRestore:[wasShowingAltScreen ? altScreenLineBuffer : self.linebuffer numLinesWithWidth:self.currentGrid.size.width]];
    DLog(@"After restoring screen from line buffer:\n%@", [self compactLineDumpWithHistoryAndContinuationMarksAndLineNumbers]);

    if (wasShowingAltScreen) {
        // If we're in the alternate screen, restore its contents from the temporary
        // linebuffer.
        // In alternate screen mode, the screen contents move up when the screen gets smaller.
        // For example, if your alt screen looks like this before:
        //   abcd
        //   ef..
        // And then gets shrunk to 3 wide, it becomes
        //   d..
        //   ef.
        // The "abc" line was lost, so "linesMovedUp" is 1. That's the number of lines at the top
        // of the alt screen that were lost.
        newSubSelections = [self subSelectionsAfterRestoringPrimaryGridWithCopyOfAltGrid:copyOfAltGrid
                                                                                    linesMovedUp:[altScreenLineBuffer numLinesWithWidth:self.currentGrid.size.width]
                                                                                    toLineBuffer:realLineBuffer
                                                                              subSelectionTuples:altScreenSubSelectionTuples
                                                                            originalLastPosition:originalLastPos
                                                                                         oldSize:oldSize
                                                                                         newSize:newSize
                                                                                      usedHeight:usedHeight
                                                                             intervalTreeObjects:altScreenNotes];
    } else {
        // Was showing primary grid. Fix up notes in the alt screen.
        [self updateAlternateScreenIntervalTreeForNewSize:newSize];
    }

    const int newTop = rangeOfVisibleLinesConvertedCorrectly ? convertedRangeOfVisibleLines.start.y : -1;

    [self didResizeToSize:newSize
                        selection:selection
               couldHaveSelection:couldHaveSelection
                    subSelections:newSubSelections
                           newTop:newTop
                         delegate:delegate];
    [altScreenLineBuffer endResizing];
    [self sanityCheckIntervalsFrom:oldSize note:@"post-hoc"];
    DLog(@"After:\n%@", [self.currentGrid compactLineDumpWithContinuationMarks]);
    DLog(@"Cursor at %d,%d", self.currentGrid.cursorX, self.currentGrid.cursorY);
}


@end