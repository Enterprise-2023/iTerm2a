//
//  iTermTextRendererTransientState.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 12/22/17.
//

#import "iTermTextRendererTransientState.h"
#import "iTermTextRendererTransientState+Private.h"
#import "iTermPIUArray.h"
#import "iTermSubpixelModelBuilder.h"
#import "iTermTexturePage.h"
#import "iTermTexturePageCollection.h"
#import "NSMutableData+iTerm.h"

#include <map>

const vector_float4 iTermIMEColor = simd_make_float4(1, 1, 0, 1);
const vector_float4 iTermAnnotationUnderlineColor = simd_make_float4(1, 1, 0, 1);

namespace iTerm2 {
    class TexturePage;
}

typedef struct {
    size_t piu_index;
    int x;
    int y;
} iTermTextFixup;

// text color component, background color component
typedef std::pair<unsigned char, unsigned char> iTermColorComponentPair;

@implementation iTermTextRendererTransientState {
    // Data's bytes contains a C array of iTermMetalBackgroundColorRLE with background colors.
    NSMutableArray<iTermData *> *_backgroundColorRLEDataArray;

    // Info about PIUs that need their background colors set. They belong to
    // parts of glyphs that spilled out of their bounds. The actual PIUs
    // belong to _pius, but are missing some fields.
    std::map<iTerm2::TexturePage *, std::vector<iTermTextFixup> *> _fixups;

    // Color models for this frame. Only used when there's no intermediate texture.
    NSMutableData *_colorModels;

    // Key is text, background color component. Value is color model number (0 is 1st, 1 is 2nd, etc)
    // and you can multiply the color model number by 256 to get its starting point in _colorModels.
    // Only used when there's no intermediate texture.
    std::map<iTermColorComponentPair, int> *_colorModelIndexes;


    // Array of PIUs for each texture page.
    std::map<iTerm2::TexturePage *, iTerm2::PIUArray<iTermTextPIU> *> _pius;

    iTermPreciseTimerStats _stats[iTermTextRendererStatCount];

    vector_float4 _lastTextColor, _lastBackgroundColor;
    vector_int3 _lastColorModelIndex;
}

NS_INLINE vector_int3 GetColorModelIndexForPIU(iTermTextRendererTransientState *self, iTermTextPIU *piu) {
    if (simd_equal(piu->textColor, self->_lastTextColor) &&
        simd_equal(piu->backgroundColor, self->_lastBackgroundColor)) {
        return self->_lastColorModelIndex;
    } else {
        vector_int3 result = SlowGetColorModelIndexForPIU(self, piu);
        self->_lastTextColor = piu->textColor;
        self->_lastBackgroundColor = piu->backgroundColor;
        self->_lastColorModelIndex = result;
        return result;
    }
}

- (instancetype)initWithConfiguration:(__kindof iTermRenderConfiguration *)configuration {
    self = [super initWithConfiguration:configuration];
    if (self) {
        _backgroundColorRLEDataArray = [NSMutableArray array];
        iTermCellRenderConfiguration *cellConfiguration = configuration;
        if (!cellConfiguration.usingIntermediatePass) {
            _colorModels = [NSMutableData data];
            _colorModelIndexes = new std::map<iTermColorComponentPair, int>();
            _lastTextColor = _lastBackgroundColor = simd_make_float4(-1, -1, -1, -1);
        }
    }
    return self;
}

- (void)dealloc {
    for (auto pair : _fixups) {
        delete pair.second;
    }
    if (_colorModelIndexes) {
        delete _colorModelIndexes;
    }
    for (auto it = _pius.begin(); it != _pius.end(); it++) {
        delete it->second;
    }
}

+ (NSString *)formatTextPIU:(iTermTextPIU)a {
    return [NSString stringWithFormat:
            @"offset=(%@, %@) "
            @"textureOffset=(%@, %@) "
            @"backgroundColor=(%@, %@, %@, %@) "
            @"textColor=(%@, %@, %@, %@) "
            @"remapColors=%@ "
            @"colorModelIndex=(%@, %@, %@) "
            @"underlineStyle=%@ "
            @"underlineColor=(%@, %@, %@, %@)\n",
            @(a.offset.x),
            @(a.offset.y),
            @(a.textureOffset.x),
            @(a.textureOffset.y),
            @(a.backgroundColor.x),
            @(a.backgroundColor.y),
            @(a.backgroundColor.z),
            @(a.backgroundColor.w),
            @(a.textColor.x),
            @(a.textColor.y),
            @(a.textColor.z),
            @(a.textColor.w),
            a.remapColors ? @"YES" : @"NO",
            @(a.colorModelIndex.x),
            @(a.colorModelIndex.y),
            @(a.colorModelIndex.z),
            @(a.underlineStyle),
            @(a.underlineColor.x),
            @(a.underlineColor.y),
            @(a.underlineColor.z),
            @(a.underlineColor.w)];
}

- (void)writeDebugInfoToFolder:(NSURL *)folder {
    [super writeDebugInfoToFolder:folder];

    [_modelData writeToURL:[folder URLByAppendingPathComponent:@"model.bin"] atomically:NO];

    @autoreleasepool {
        NSMutableString *s = [NSMutableString string];
        [_backgroundColorRLEDataArray enumerateObjectsUsingBlock:^(iTermData * _Nonnull data, NSUInteger idx, BOOL * _Nonnull stop) {
            iTermMetalBackgroundColorRLE *rle = (iTermMetalBackgroundColorRLE *)data.mutableBytes;
            [s appendFormat:@"%4d: %@\n", (int)idx, iTermMetalBackgroundColorRLEDescription(rle)];
        }];
        [s writeToURL:[folder URLByAppendingPathComponent:@"backgroundColors.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }

    @autoreleasepool {
        NSMutableString *s = [NSMutableString string];
        for (auto entry : _fixups) {
            id<MTLTexture> texture = entry.first->get_texture();
            [s appendFormat:@"Texture Page with texture %@\n", texture.label];
            if (entry.second) {
                for (auto fixup : *entry.second) {
                    [s appendFormat:@"piu_index=%@ x=%@ y=%@\n", @(fixup.piu_index), @(fixup.x), @(fixup.y)];
                }
            }
        }
        [s writeToURL:[folder URLByAppendingPathComponent:@"fixups.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }

    [_colorModels writeToURL:[folder URLByAppendingPathComponent:@"colorModels.bin"] atomically:NO];

    if (_colorModelIndexes) {
        @autoreleasepool {
            NSMutableString *s = [NSMutableString string];
            for (auto entry : *_colorModelIndexes) {
                [s appendFormat:@"(%@, %@) -> %@\n",
                 @(entry.first.first),
                 @(entry.first.second),
                 @(entry.second)];
            }
            [s writeToURL:[folder URLByAppendingPathComponent:@"colorModelIndexes.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
        }
    }

    @autoreleasepool {
        NSMutableString *s = [NSMutableString string];
        for (auto entry : _pius) {
            const iTerm2::TexturePage *texturePage = entry.first;
            iTerm2::PIUArray<iTermTextPIU> *piuArray = entry.second;
            [s appendFormat:@"Texture Page with texture %@:\n", texturePage->get_texture().label];
            if (piuArray) {
                for (int j = 0; j < piuArray->size(); j++) {
                    iTermTextPIU &piu = piuArray->get(j);
                    [s appendString:[self.class formatTextPIU:piu]];
                }
            }
        }
        [s writeToURL:[folder URLByAppendingPathComponent:@"non-ascii-pius.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }

    NSString *s = [NSString stringWithFormat:@"backgroundTexture=%@\nonAsciiUnderlineDescriptor=%@\ndefaultBackgroundColor=(%@, %@, %@, %@)",
                   _backgroundTexture,
                   iTermMetalUnderlineDescriptorDescription(&_nonAsciiUnderlineDescriptor),
                   @(_defaultBackgroundColor.x),
                   @(_defaultBackgroundColor.y),
                   @(_defaultBackgroundColor.z),
                   @(_defaultBackgroundColor.w)];
    [s writeToURL:[folder URLByAppendingPathComponent:@"state.txt"]
       atomically:NO
         encoding:NSUTF8StringEncoding
            error:NULL];
}

- (iTermPreciseTimerStats *)stats {
    return _stats;
}

- (int)numberOfStats {
    return iTermTextRendererStatCount;
}

- (NSString *)nameForStat:(int)i {
    return [@[ @"text.newQuad",
               @"text.newPIU",
               @"text.newDims",
               @"text.subpixel",
               @"text.draw" ] objectAtIndex:i];
}

- (void)enumerateDraws:(void (^)(const iTermTextPIU *, NSInteger, id<MTLTexture>, vector_uint2, vector_uint2, iTermMetalUnderlineDescriptor))block {
    for (auto const &mapPair : _pius) {
        const iTerm2::TexturePage *const &texturePage = mapPair.first;
        const iTerm2::PIUArray<iTermTextPIU> *const &piuArray = mapPair.second;

        for (size_t i = 0; i < piuArray->get_number_of_segments(); i++) {
            const size_t count = piuArray->size_of_segment(i);
            if (count > 0) {
                block(piuArray->start_of_segment(i),
                      count,
                      texturePage->get_texture(),
                      texturePage->get_atlas_size(),
                      texturePage->get_cell_size(),
                      _nonAsciiUnderlineDescriptor);
            }
        }
    }
}

- (void)willDraw {
    DLog(@"WILL DRAW %@", self);
    // Fix up the background color of parts of glyphs that are drawn outside their cell. Add to the
    // correct page's PIUs.
    const int numRows = _backgroundColorRLEDataArray.count;
        const int width = self.cellConfiguration.gridSize.width;
    for (auto pair : _fixups) {
        iTerm2::TexturePage *page = pair.first;
        std::vector<iTermTextFixup> *fixups = pair.second;
        for (auto fixup : *fixups) {
            iTerm2::PIUArray<iTermTextPIU> &piuArray = *_pius[page];
            iTermTextPIU &piu = piuArray.get(fixup.piu_index);

            // Set fields in piu
            if (fixup.y >= 0 && fixup.y < numRows && fixup.x >= 0 && fixup.x < width) {
                iTermData *data = _backgroundColorRLEDataArray[fixup.y];
                const iTermMetalBackgroundColorRLE *backgroundRLEs = (iTermMetalBackgroundColorRLE *)data.mutableBytes;
                // find RLE for index fixup.x
                const int rleCount = data.length / sizeof(iTermMetalBackgroundColorRLE);
                // Use upper bound. Consider the following:
                // Origins          0         10         20         end()
                // Lower bounds     0         1...10     11...20    21...inf
                // Upper bounds               0...9      10...19    20...inf
                //
                // Upper bound always gives you one past what you wanted. Lower bound is not consistent.
                auto it = std::upper_bound(backgroundRLEs,
                                           backgroundRLEs + rleCount,
                                           static_cast<unsigned short>(fixup.x));
                it--;
                const iTermMetalBackgroundColorRLE &rle = *it;
                piu.backgroundColor = rle.color;
                if (_colorModels) {
                    piu.colorModelIndex = GetColorModelIndexForPIU(self, &piu);
                }
            } else {
                // Offscreen
                piu.backgroundColor = _defaultBackgroundColor;
            }
        }
        delete fixups;
    }

    _fixups.clear();

    for (auto pair : _pius) {
        iTerm2::TexturePage *page = pair.first;
        page->record_use();
    }
    DLog(@"END WILL DRAW");
}

- (void)setGlyphKeysData:(iTermData *)glyphKeysData
                   count:(int)count
          attributesData:(iTermData *)attributesData
                     row:(int)row
  backgroundColorRLEData:(nonnull iTermData *)backgroundColorRLEData
       markedRangeOnLine:(NSRange)markedRangeOnLine
                 context:(iTermMetalBufferPoolContext *)context
                creation:(NSDictionary<NSNumber *, iTermCharacterBitmap *> *(NS_NOESCAPE ^)(int x, BOOL *emoji))creation {
    DLog(@"BEGIN setGlyphKeysData for %@", self);
    ITDebugAssert(row == _backgroundColorRLEDataArray.count);
    [_backgroundColorRLEDataArray addObject:backgroundColorRLEData];
    const iTermMetalGlyphKey *glyphKeys = (iTermMetalGlyphKey *)glyphKeysData.mutableBytes;
    const iTermMetalGlyphAttributes *attributes = (iTermMetalGlyphAttributes *)attributesData.mutableBytes;
    const float cellHeight = self.cellConfiguration.cellSize.height;
    const float cellWidth = self.cellConfiguration.cellSize.width;
    const float yOffset = (self.cellConfiguration.gridSize.height - row - 1) * cellHeight;

    std::map<int, int> lastRelations;
    BOOL inMarkedRange = NO;

    for (int x = 0; x < count; x++) {
        if (x == markedRangeOnLine.location) {
            inMarkedRange = YES;
        } else if (inMarkedRange && x == NSMaxRange(markedRangeOnLine)) {
            inMarkedRange = NO;
        }

        if (!glyphKeys[x].drawable) {
            continue;
        }

        const iTerm2::GlyphKey glyphKey(&glyphKeys[x]);
        std::vector<const iTerm2::GlyphEntry *> *entries = _texturePageCollectionSharedPointer.object->find(glyphKey);
        if (!entries) {
            entries = _texturePageCollectionSharedPointer.object->add(x, glyphKey, context, creation);
            if (!entries) {
                continue;
            }
        }
        for (auto entry : *entries) {
            auto it = _pius.find(entry->_page);
            iTerm2::PIUArray<iTermTextPIU> *array;
            if (it == _pius.end()) {
                array = _pius[entry->_page] = new iTerm2::PIUArray<iTermTextPIU>(_numberOfCells);
            } else {
                array = it->second;
            }
            iTermTextPIU *piu = array->get_next();
            // Build the PIU
            const int &part = entry->_part;
            const int dx = iTermImagePartDX(part);
            const int dy = iTermImagePartDY(part);
            piu->offset = simd_make_float2((x + dx) * cellWidth,
                                           -dy * cellHeight + yOffset);
            MTLOrigin origin = entry->get_origin();
            vector_float2 reciprocal_atlas_size = entry->_page->get_reciprocal_atlas_size();
            piu->textureOffset = simd_make_float2(origin.x * reciprocal_atlas_size.x,
                                                  origin.y * reciprocal_atlas_size.y);
            piu->textColor = attributes[x].foregroundColor;
            piu->remapColors = !entry->_is_emoji;
            if (attributes[x].annotation) {
                piu->underlineStyle = iTermMetalGlyphAttributesUnderlineSingle;
                piu->underlineColor = iTermAnnotationUnderlineColor;
            } else if (inMarkedRange) {
                piu->underlineStyle = iTermMetalGlyphAttributesUnderlineSingle;
                piu->underlineColor = iTermIMEColor;
                piu->textColor = iTermIMEColor;
            } else {
                piu->underlineStyle = attributes[x].underlineStyle;
                piu->underlineColor = _nonAsciiUnderlineDescriptor.color.w > 1 ? _nonAsciiUnderlineDescriptor.color : piu->textColor;
            }

            // Set color info or queue for fixup since color info may not exist yet.
            if (entry->_part == iTermTextureMapMiddleCharacterPart) {
                piu->backgroundColor = attributes[x].backgroundColor;
                if (_colorModels) {
                    piu->colorModelIndex = GetColorModelIndexForPIU(self, piu);
                }
            } else {
                iTermTextFixup fixup = {
                    .piu_index = array->size() - 1,
                    .x = x + dx,
                    .y = row + dy,
                };
                std::vector<iTermTextFixup> *fixups = _fixups[entry->_page];
                if (fixups == nullptr) {
                    fixups = new std::vector<iTermTextFixup>();
                    _fixups[entry->_page] = fixups;
                }
                fixups->push_back(fixup);
            }
        }
    }
    DLog(@"END setGlyphKeysData for %@", self);
}

static vector_int3 SlowGetColorModelIndexForPIU(iTermTextRendererTransientState *self, iTermTextPIU *piu) {
    iTermColorComponentPair redPair = std::make_pair(piu->textColor.x * 255,
                                                     piu->backgroundColor.x * 255);
    iTermColorComponentPair greenPair = std::make_pair(piu->textColor.y * 255,
                                                       piu->backgroundColor.y * 255);
    iTermColorComponentPair bluePair = std::make_pair(piu->textColor.z * 255,
                                                      piu->backgroundColor.z * 255);
    vector_int3 result;
    auto it = self->_colorModelIndexes->find(redPair);
    if (it == self->_colorModelIndexes->end()) {
        result.x = [self allocateColorModelForColorPair:redPair];
    } else {
        result.x = it->second;
    }
    it = self->_colorModelIndexes->find(greenPair);
    if (it == self->_colorModelIndexes->end()) {
        result.y = [self allocateColorModelForColorPair:greenPair];
    } else {
        result.y = it->second;
    }
    it = self->_colorModelIndexes->find(bluePair);
    if (it == self->_colorModelIndexes->end()) {
        result.z = [self allocateColorModelForColorPair:bluePair];
    } else {
        result.z = it->second;
    }

    return result;
}

- (int)allocateColorModelForColorPair:(iTermColorComponentPair)colorPair {
    int i = _colorModelIndexes->size();
    iTermSubpixelModel *model = [[iTermSubpixelModelBuilder sharedInstance] modelForForegoundColor:colorPair.first / 255.0
                                                                                   backgroundColor:colorPair.second / 255.0];
    [_colorModels appendData:model.table];
    (*_colorModelIndexes)[colorPair] = i;
    return i;
}

- (void)didComplete {
    DLog(@"BEGIN didComplete for %@", self);
    _texturePageCollectionSharedPointer.object->prune_if_needed();
    DLog(@"END didComplete");
}

- (nonnull NSMutableData *)modelData  {
    if (_modelData == nil) {
        _modelData = [[NSMutableData alloc] initWithUninitializedLength:sizeof(iTermTextPIU) * self.cellConfiguration.gridSize.width * self.cellConfiguration.gridSize.height];
    }
    return _modelData;
}

@end

