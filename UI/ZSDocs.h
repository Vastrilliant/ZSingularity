
#import <UIKit/UIKit.h>
#import "Transcoder.h"

#pragma mark - Remote docs fetching

typedef void (^ZSDocsFetchCompletion)(NSString * _Nullable markdown, NSError * _Nullable error);

static NSString * const kZSDocsRepoOwner  = @"vastrilliant";
static NSString * const kZSDocsRepoName   = @"ZSingularity";
static NSString * const kZSDocsRepoBranch = @"main";

#pragma mark - Language

static NSString * const kZSDocsSettingsSection   = @"docs";
static NSString * const kZSDocsLanguageKey       = @"language";
static NSString * const kZSDocsDefaultLanguageCode = @"en";

static NSArray<NSDictionary<NSString *, NSString *> *> *zs_docs_language_options(void) {
    static NSArray<NSDictionary<NSString *, NSString *> *> *options;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        options = @[
            @{@"code": @"en", @"name": @"English"},
            @{@"code": @"kr", @"name": @"Korean"},
            @{@"code": @"jp", @"name": @"Japanese"},
            @{@"code": @"cn", @"name": @"Chinese"},
            @{@"code": @"es", @"name": @"Spanish"},
            @{@"code": @"ru", @"name": @"Russian"},
        ];
    });
    return options;
}

static BOOL zs_docs_language_code_is_valid(NSString *code) {
    if (code.length == 0) return NO;
    for (NSDictionary<NSString *, NSString *> *option in zs_docs_language_options()) {
        if ([option[@"code"] isEqualToString:code]) return YES;
    }
    return NO;
}

static NSString *gZSDocsCurrentLanguageCache;
static BOOL gZSDocsCurrentLanguageCacheLoaded;

static NSString *zs_docs_current_language(void) {
    if (!gZSDocsCurrentLanguageCacheLoaded) {
        NSDictionary *section = zs_settings_section(kZSDocsSettingsSection);
        NSString *stored = section[kZSDocsLanguageKey];
        gZSDocsCurrentLanguageCache = zs_docs_language_code_is_valid(stored) ? stored : kZSDocsDefaultLanguageCode;
        gZSDocsCurrentLanguageCacheLoaded = YES;
    }
    return gZSDocsCurrentLanguageCache;
}

static void zs_docs_set_current_language(NSString *code) {
    if (!zs_docs_language_code_is_valid(code)) return;

    NSMutableDictionary *section = [zs_settings_section(kZSDocsSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSDocsLanguageKey] = code;
    zs_write_settings_section(kZSDocsSettingsSection, section);

    gZSDocsCurrentLanguageCache = code;
    gZSDocsCurrentLanguageCacheLoaded = YES;
}

static NSDictionary<NSString *, NSString *> *zs_docs_section_files(void) {
    static NSDictionary<NSString *, NSString *> *files;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        files = @{
            @"Display": @"Display.md",
            @"Rendering": @"Rendering.md",
            @"Anti-Aliasing": @"Anti-Aliasing.md",
            @"Post FX": @"PostFX.md",
            @"Particles": @"Particles.md",
            @"Debug": @"Debug.md",
            @"Miscellaneous": @"Miscellaneous.md",
            @"Mods": @"Mods.md",
            @"Auth": @"Auth.md",
            @"Config": @"Config.md",
        };
    });
    return files;
}

static NSString *zs_docs_key_for_filename(NSString *filename) {
    if (filename.length == 0) return nil;
    __block NSString *foundKey = nil;
    [zs_docs_section_files() enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *file, BOOL *stop) {
        if ([file isEqualToString:filename]) {
            foundKey = key;
            *stop = YES;
        }
    }];
    return foundKey;
}

static NSURL *zs_docs_remote_url(NSString *filename) {
    NSString *urlString = [NSString stringWithFormat:
        @"https://raw.githubusercontent.com/%@/%@/%@/Documentation/%@/%@",
        kZSDocsRepoOwner, kZSDocsRepoName, kZSDocsRepoBranch, zs_docs_current_language(), filename];
    return [NSURL URLWithString:urlString];
}

static NSURL *zs_docs_image_remote_url(NSString *filename) {
    NSString *urlString = [NSString stringWithFormat:
        @"https://raw.githubusercontent.com/%@/%@/%@/Documentation/%@",
        kZSDocsRepoOwner, kZSDocsRepoName, kZSDocsRepoBranch, filename];
    return [NSURL URLWithString:urlString];
}

static NSString *zs_docs_cache_directory(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *dir = [paths.firstObject stringByAppendingPathComponent:@"ZSDocsCache"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *zs_docs_cache_key(NSString *key) {
    return [NSString stringWithFormat:@"%@_%@", zs_docs_current_language(), key];
}

static NSString *zs_docs_cache_path(NSString *key) {
    NSString *safeName = [zs_docs_cache_key(key) stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    return [zs_docs_cache_directory() stringByAppendingPathComponent:[safeName stringByAppendingPathExtension:@"md"]];
}

static NSMutableDictionary<NSString *, NSString *> *zs_docs_memory_cache(void) {
    static NSMutableDictionary<NSString *, NSString *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

static NSString *zs_docs_cached_content(NSString *key) {
    if (!key) return nil;

    NSString *cacheKey = zs_docs_cache_key(key);
    NSMutableDictionary<NSString *, NSString *> *cache = zs_docs_memory_cache();
    NSString *cached = cache[cacheKey];
    if (cached) return cached;

    NSString *fromDisk = [NSString stringWithContentsOfFile:zs_docs_cache_path(key)
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
    if (fromDisk) cache[cacheKey] = fromDisk;
    return fromDisk;
}

static void zs_docs_perform_markdown_fetch(NSURL *url, NSString *filename, NSString *key,
                                            NSString * _Nullable authToken, BOOL isRetry,
                                            ZSDocsFetchCompletion completion);

static void zs_docs_perform_markdown_fetch(NSURL *url, NSString *filename, NSString *key,
                                            NSString * _Nullable authToken, BOOL isRetry,
                                            ZSDocsFetchCompletion completion) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    if (authToken.length > 0) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", authToken] forHTTPHeaderField:@"Authorization"];
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            NSString *markdown = (!error && http.statusCode == 200 && data.length > 0)
                ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                : nil;

            if (markdown) {
                zs_docs_memory_cache()[zs_docs_cache_key(key)] = markdown;
                [markdown writeToFile:zs_docs_cache_path(key) atomically:YES encoding:NSUTF8StringEncoding error:nil];
                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(markdown, nil); });
                }
                return;
            }

            if (authToken.length > 0 && !isRetry) {
                zs_docs_perform_markdown_fetch(url, filename, key, nil, YES, completion);
                return;
            }

            NSError *finalError = error ?: [NSError errorWithDomain:@"ZSDocsRemote" code:http ? http.statusCode : 2
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Unexpected response (%ld) fetching %@", (long)(http ? http.statusCode : 0), filename]}];
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, finalError); });
            }
        }];
    [task resume];
}

static void zs_docs_fetch_latest(NSString *key, ZSDocsFetchCompletion completion) {
    NSString *filename = key ? zs_docs_section_files()[key] : nil;
    NSURL *url = filename ? zs_docs_remote_url(filename) : nil;

    if (!url) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"ZSDocsRemote" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"No known doc file for this section."}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
        }
        return;
    }

    NSString *authToken = [ZTranscoderSettings loadConfig].authToken;
    zs_docs_perform_markdown_fetch(url, filename, key, authToken, NO, completion);
}

#pragma mark - Images

static NSArray<NSString *> *zs_docs_image_names_in_markdown(NSString *markdown) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *rawLine in [markdown componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![line hasPrefix:@"!["]) continue;

        NSRange closeBracket = [line rangeOfString:@"]"];
        if (closeBracket.location == NSNotFound) continue;
        NSUInteger afterBracket = closeBracket.location + 1;
        if (afterBracket >= line.length || [line characterAtIndex:afterBracket] != '(') continue;

        NSRange afterParenRange = NSMakeRange(afterBracket + 1, line.length - (afterBracket + 1));
        NSRange closeParen = [line rangeOfString:@")" options:0 range:afterParenRange];
        if (closeParen.location == NSNotFound) continue;

        NSString *src = [line substringWithRange:NSMakeRange(afterBracket + 1, closeParen.location - (afterBracket + 1))];
        if (src.length > 0 && ![names containsObject:src]) [names addObject:src];
    }
    return names;
}

static NSMutableDictionary<NSString *, UIImage *> *zs_docs_image_memory_cache(void) {
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

static NSString *zs_docs_image_cache_path(NSString *filename) {
    NSString *safeName = [filename stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    return [zs_docs_cache_directory() stringByAppendingPathComponent:safeName];
}

static UIImage *zs_docs_cached_image(NSString *filename) {
    if (filename.length == 0) return nil;

    NSMutableDictionary<NSString *, UIImage *> *cache = zs_docs_image_memory_cache();
    UIImage *cached = cache[filename];
    if (cached) return cached;

    NSData *fromDisk = [NSData dataWithContentsOfFile:zs_docs_image_cache_path(filename)];
    UIImage *image = fromDisk ? [UIImage imageWithData:fromDisk scale:1.0] : nil;
    if (image) cache[filename] = image;
    return image;
}

static void zs_docs_perform_image_fetch(NSURL *url, NSString *filename, NSString * _Nullable authToken,
                                         BOOL isRetry, void (^completion)(UIImage * _Nullable image));

static void zs_docs_perform_image_fetch(NSURL *url, NSString *filename, NSString * _Nullable authToken,
                                         BOOL isRetry, void (^completion)(UIImage * _Nullable image)) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    if (authToken.length > 0) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", authToken] forHTTPHeaderField:@"Authorization"];
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            UIImage *image = (!error && http.statusCode == 200 && data.length > 0)
                ? [UIImage imageWithData:data scale:1.0]
                : nil;

            if (image) {
                zs_docs_image_memory_cache()[filename] = image;
                [data writeToFile:zs_docs_image_cache_path(filename) atomically:YES];
                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(image); });
                }
                return;
            }

            if (authToken.length > 0 && !isRetry) {
                zs_docs_perform_image_fetch(url, filename, nil, YES, completion);
                return;
            }

            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            }
        }];
    [task resume];
}

static void zs_docs_fetch_image(NSString *filename, void (^completion)(UIImage * _Nullable image)) {
    NSURL *url = filename.length > 0 ? zs_docs_image_remote_url(filename) : nil;
    if (!url) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        }
        return;
    }

    NSString *authToken = [ZTranscoderSettings loadConfig].authToken;
    zs_docs_perform_image_fetch(url, filename, authToken, NO, completion);
}

#pragma mark - Minimal markdown renderer

static NSString * const kZSDocsQuoteBarColorAttributeName = @"ZSDocsQuoteBarColor";
static const CGFloat kZSDocsQuoteBarWidth = 2.5;
static const CGFloat kZSDocsQuoteBarIndent = 14;

@interface ZSDocsQuoteLayoutManager : NSLayoutManager
@end

@implementation ZSDocsQuoteLayoutManager

- (void)drawBackgroundForGlyphRange:(NSRange)glyphsToShow atPoint:(CGPoint)origin {
    [super drawBackgroundForGlyphRange:glyphsToShow atPoint:origin];

    NSTextStorage *textStorage = self.textStorage;
    NSTextContainer *textContainer = self.textContainers.firstObject;
    if (!textStorage || !textContainer) return;

    NSRange characterRange = [self characterRangeForGlyphRange:glyphsToShow actualGlyphRange:NULL];

    [textStorage enumerateAttribute:kZSDocsQuoteBarColorAttributeName
                             inRange:characterRange
                             options:0
                          usingBlock:^(UIColor *color, NSRange range, BOOL *stop) {
        if (![color isKindOfClass:[UIColor class]] || range.length == 0) return;

        NSRange runGlyphRange = [self glyphRangeForCharacterRange:range actualCharacterRange:NULL];

        __block CGRect unionRect = CGRectNull;
        [self enumerateLineFragmentsForGlyphRange:runGlyphRange usingBlock:^(CGRect rect, CGRect usedRect, NSTextContainer *container, NSRange lineGlyphRange, BOOL *innerStop) {
            unionRect = CGRectIsNull(unionRect) ? usedRect : CGRectUnion(unionRect, usedRect);
        }];
        if (CGRectIsNull(unionRect)) return;

        CGRect barRect = CGRectMake(origin.x + textContainer.lineFragmentPadding,
                                     origin.y + unionRect.origin.y,
                                     kZSDocsQuoteBarWidth,
                                     unionRect.size.height);
        UIBezierPath *barPath = [UIBezierPath bezierPathWithRoundedRect:barRect cornerRadius:kZSDocsQuoteBarWidth / 2];
        [color setFill];
        [barPath fill];
    }];
}

@end

static NSAttributedString *zs_render_markdown_inline(NSString *line, UIFont *baseFont, UIColor *baseColor) {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    NSUInteger length = line.length;
    NSUInteger i = 0;

    UIFont *boldFont = [UIFont fontWithDescriptor:[baseFont.fontDescriptor
        fontDescriptorWithSymbolicTraits:baseFont.fontDescriptor.symbolicTraits | UIFontDescriptorTraitBold]
                                              size:baseFont.pointSize] ?: baseFont;
    UIFont *codeFont = [UIFont monospacedSystemFontOfSize:baseFont.pointSize - 1 weight:UIFontWeightRegular];
    UIColor *codeColor = [UIColor colorWithWhite:1 alpha:0.85];
    UIColor *codeBackground = [UIColor colorWithWhite:1 alpha:0.14];

    while (i < length) {
        unichar c = [line characterAtIndex:i];

        if (c == '*' && i + 1 < length && [line characterAtIndex:i + 1] == '*') {
            NSRange remaining = NSMakeRange(i + 2, length - (i + 2));
            NSRange close = [line rangeOfString:@"**" options:0 range:remaining];
            if (close.location != NSNotFound) {
                NSString *inner = [line substringWithRange:NSMakeRange(i + 2, close.location - (i + 2))];
                [result appendAttributedString:[[NSAttributedString alloc] initWithString:inner
                    attributes:@{NSFontAttributeName: boldFont, NSForegroundColorAttributeName: baseColor}]];
                i = close.location + 2;
                continue;
            }
        }

        if (c == '`') {
            NSRange remaining = NSMakeRange(i + 1, length - (i + 1));
            NSRange close = [line rangeOfString:@"`" options:0 range:remaining];
            if (close.location != NSNotFound) {
                NSString *inner = [line substringWithRange:NSMakeRange(i + 1, close.location - (i + 1))];
                [result appendAttributedString:[[NSAttributedString alloc] initWithString:inner
                    attributes:@{NSFontAttributeName: codeFont, NSForegroundColorAttributeName: codeColor,
                                  NSBackgroundColorAttributeName: codeBackground}]];
                i = close.location + 1;
                continue;
            }
        }

        if (c == '[') {
            NSRange remaining = NSMakeRange(i + 1, length - (i + 1));
            NSRange closeBracket = [line rangeOfString:@"]" options:0 range:remaining];
            if (closeBracket.location != NSNotFound &&
                closeBracket.location + 1 < length &&
                [line characterAtIndex:closeBracket.location + 1] == '(') {
                NSRange afterParen = NSMakeRange(closeBracket.location + 2, length - (closeBracket.location + 2));
                NSRange closeParen = [line rangeOfString:@")" options:0 range:afterParen];
                if (closeParen.location != NSNotFound) {
                    NSString *linkText = [line substringWithRange:NSMakeRange(i + 1, closeBracket.location - (i + 1))];
                    NSString *href = [line substringWithRange:NSMakeRange(closeBracket.location + 2,
                        closeParen.location - (closeBracket.location + 2))];

                    NSMutableDictionary *linkAttrs = [@{
                        NSFontAttributeName: baseFont,
                        NSForegroundColorAttributeName: [UIColor colorWithRed:0.55 green:0.75 blue:1.0 alpha:1.0],
                    } mutableCopy];

                    NSURL *linkURL = [NSURL URLWithString:href];
                    if (linkURL) {
                        linkAttrs[NSLinkAttributeName] = linkURL;
                        linkAttrs[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
                    }

                    [result appendAttributedString:[[NSAttributedString alloc] initWithString:linkText
                        attributes:linkAttrs]];
                    i = closeParen.location + 1;
                    continue;
                }
            }
        }

        [result appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithCharacters:&c length:1]
            attributes:@{NSFontAttributeName: baseFont, NSForegroundColorAttributeName: baseColor}]];
        i += 1;
    }

    return result;
}

static BOOL zs_docs_admonition_for_marker(NSString *marker, NSString **outLabel, UIColor **outColor, NSString **outSymbolName) {
    NSString *normalized = [[marker stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];

    if ([normalized isEqualToString:@"[!NOTE]"]) {
        if (outLabel) *outLabel = @"Note";
        if (outColor) *outColor = [UIColor colorWithRed:0.345 green:0.647 blue:1.0 alpha:1.0];
        if (outSymbolName) *outSymbolName = @"info.circle.fill";
        return YES;
    }
    if ([normalized isEqualToString:@"[!TIP]"]) {
        if (outLabel) *outLabel = @"Tip";
        if (outColor) *outColor = [UIColor colorWithRed:0.247 green:0.725 blue:0.314 alpha:1.0];
        if (outSymbolName) *outSymbolName = @"lightbulb.fill";
        return YES;
    }
    if ([normalized isEqualToString:@"[!IMPORTANT]"]) {
        if (outLabel) *outLabel = @"Important";
        if (outColor) *outColor = [UIColor colorWithRed:0.639 green:0.443 blue:0.969 alpha:1.0];
        if (outSymbolName) *outSymbolName = @"exclamationmark.bubble.fill";
        return YES;
    }
    if ([normalized isEqualToString:@"[!WARNING]"]) {
        if (outLabel) *outLabel = @"Warning";
        if (outColor) *outColor = [UIColor colorWithRed:0.824 green:0.6 blue:0.133 alpha:1.0];
        if (outSymbolName) *outSymbolName = @"exclamationmark.triangle.fill";
        return YES;
    }
    if ([normalized isEqualToString:@"[!CAUTION]"]) {
        if (outLabel) *outLabel = @"Caution";
        if (outColor) *outColor = [UIColor colorWithRed:0.973 green:0.318 blue:0.286 alpha:1.0];
        if (outSymbolName) *outSymbolName = @"xmark.octagon.fill";
        return YES;
    }
    return NO;
}

static NSString *zs_docs_strip_blockquote_marker(NSString *trimmedLine) {
    if ([trimmedLine hasPrefix:@"> "]) return [trimmedLine substringFromIndex:2];
    if ([trimmedLine isEqualToString:@">"]) return @"";
    return [trimmedLine substringFromIndex:1];
}

static NSAttributedString *zs_render_markdown(NSString *markdownInput, CGFloat contentWidth) {
    NSString *markdown = [[markdownInput stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
        stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];

    NSMutableAttributedString *doc = [[NSMutableAttributedString alloc] init];

    UIColor *bodyColor = [UIColor colorWithWhite:1 alpha:0.82];
    UIColor *headingColor = [UIColor colorWithWhite:1 alpha:0.95];
    UIColor *dimColor = [UIColor colorWithWhite:1 alpha:0.5];

    UIFont *bodyFont = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    UIFont *h2Font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightBold];
    UIFont *codeFont = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    UIFont *captionFont = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    UIColor *codeBackground = [UIColor colorWithWhite:1 alpha:0.14];

    NSMutableParagraphStyle *bodyParagraph = [NSMutableParagraphStyle new];
    bodyParagraph.lineSpacing = 2;
    bodyParagraph.paragraphSpacingBefore = 0;

    NSMutableParagraphStyle *headingParagraph = [NSMutableParagraphStyle new];
    headingParagraph.paragraphSpacingBefore = 8;
    headingParagraph.paragraphSpacing = 3;

    NSMutableParagraphStyle *ruleParagraph = [NSMutableParagraphStyle new];
    ruleParagraph.paragraphSpacingBefore = 8;
    ruleParagraph.paragraphSpacing = 3;

    NSMutableParagraphStyle *imageParagraph = [NSMutableParagraphStyle new];
    imageParagraph.paragraphSpacingBefore = 4;
    imageParagraph.paragraphSpacing = 4;
    imageParagraph.alignment = NSTextAlignmentCenter;

    UIFont *calloutTitleFont = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightBold];

    NSMutableParagraphStyle *calloutTitleParagraph = [NSMutableParagraphStyle new];
    calloutTitleParagraph.paragraphSpacingBefore = 8;
    calloutTitleParagraph.paragraphSpacing = 2;
    calloutTitleParagraph.headIndent = kZSDocsQuoteBarIndent;
    calloutTitleParagraph.firstLineHeadIndent = kZSDocsQuoteBarIndent;

    NSMutableParagraphStyle *calloutBodyParagraph = [NSMutableParagraphStyle new];
    calloutBodyParagraph.lineSpacing = 2;
    calloutBodyParagraph.paragraphSpacingBefore = 0;
    calloutBodyParagraph.paragraphSpacing = 8;
    calloutBodyParagraph.headIndent = kZSDocsQuoteBarIndent;
    calloutBodyParagraph.firstLineHeadIndent = kZSDocsQuoteBarIndent;

    NSMutableParagraphStyle *quoteParagraph = [NSMutableParagraphStyle new];
    quoteParagraph.lineSpacing = 2;
    quoteParagraph.paragraphSpacingBefore = 0;
    quoteParagraph.paragraphSpacing = 4;
    quoteParagraph.headIndent = kZSDocsQuoteBarIndent;
    quoteParagraph.firstLineHeadIndent = kZSDocsQuoteBarIndent;

    NSArray<NSString *> *lines = [markdown componentsSeparatedByString:@"\n"];
    NSUInteger lineCount = lines.count;
    BOOL inCodeBlock = NO;
    BOOL sawFirstHeading = NO;

    void (^appendLine)(NSAttributedString *, NSParagraphStyle *) = ^(NSAttributedString *text, NSParagraphStyle *style) {
        NSMutableAttributedString *line = [text mutableCopy];
        [line addAttribute:NSParagraphStyleAttributeName value:style range:NSMakeRange(0, line.length)];
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        [doc appendAttributedString:line];
    };

    NSAttributedString *(^ruleString)(NSParagraphStyle *) = ^(NSParagraphStyle *style) {
        return [[NSAttributedString alloc] initWithString:@"\u2014\u2014\u2014\u2014\u2014\u2014\u2014\u2014\u2014\u2014\u2014\u2014"
            attributes:@{NSFontAttributeName: bodyFont, NSForegroundColorAttributeName: dimColor}];
    };

    for (NSUInteger lineIndex = 0; lineIndex < lineCount; lineIndex++) {
        NSString *rawLine = lines[lineIndex];
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if ([line hasPrefix:@"```"]) {
            inCodeBlock = !inCodeBlock;
            continue;
        }

        if (inCodeBlock) {
            appendLine([[NSAttributedString alloc] initWithString:rawLine
                attributes:@{NSFontAttributeName: codeFont, NSForegroundColorAttributeName: dimColor,
                              NSBackgroundColorAttributeName: codeBackground}],
                bodyParagraph);
            continue;
        }

        if (line.length == 0) {
            appendLine([[NSAttributedString alloc] initWithString:@" "], bodyParagraph);
            continue;
        }

        if ([line hasPrefix:@">"]) {
            NSString *firstContent = zs_docs_strip_blockquote_marker(line);

            NSString *calloutLabel = nil;
            UIColor *calloutColor = nil;
            NSString *calloutSymbolName = nil;
            BOOL isAdmonition = zs_docs_admonition_for_marker(firstContent, &calloutLabel, &calloutColor, &calloutSymbolName);

            NSMutableArray<NSString *> *quoteBodyLines = [NSMutableArray array];
            NSUInteger scan = lineIndex + 1;
            for (; scan < lineCount; scan++) {
                NSString *nextTrimmed = [lines[scan] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([nextTrimmed hasPrefix:@">"]) {
                    [quoteBodyLines addObject:zs_docs_strip_blockquote_marker(nextTrimmed)];
                    continue;
                }
                if (nextTrimmed.length == 0) break;
                if ([nextTrimmed hasPrefix:@"#"] || [nextTrimmed hasPrefix:@"```"] ||
                    [nextTrimmed hasPrefix:@"- "] || [nextTrimmed hasPrefix:@"* "] ||
                    [nextTrimmed hasPrefix:@"!["] || [nextTrimmed isEqualToString:@"---"]) break;
                [quoteBodyLines addObject:nextTrimmed];
            }
            lineIndex = scan - 1;

            UIColor *barColor = isAdmonition ? calloutColor : dimColor;
            NSUInteger blockStartLocation = doc.length;

            if (isAdmonition) {
                UIImage *symbolImage = [UIImage systemImageNamed:calloutSymbolName];
                NSMutableAttributedString *title = [[NSMutableAttributedString alloc] init];
                if (symbolImage) {
                    UIImage *tintedSymbol = [symbolImage imageWithTintColor:calloutColor renderingMode:UIImageRenderingModeAlwaysOriginal];
                    NSTextAttachment *iconAttachment = [[NSTextAttachment alloc] init];
                    iconAttachment.image = tintedSymbol;
                    CGFloat iconSize = calloutTitleFont.pointSize;
                    iconAttachment.bounds = CGRectMake(0, -1, iconSize, iconSize);
                    [title appendAttributedString:[NSAttributedString attributedStringWithAttachment:iconAttachment]];
                    [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "]];
                }
                [title appendAttributedString:[[NSAttributedString alloc] initWithString:calloutLabel
                    attributes:@{NSFontAttributeName: calloutTitleFont, NSForegroundColorAttributeName: calloutColor}]];
                appendLine(title, calloutTitleParagraph);

                for (NSUInteger i = 0; i < quoteBodyLines.count; i++) {
                    NSString *bodyLine = quoteBodyLines[i];
                    NSAttributedString *calloutBody = bodyLine.length > 0
                        ? zs_render_markdown_inline(bodyLine, bodyFont, bodyColor)
                        : [[NSAttributedString alloc] initWithString:@" "];
                    BOOL isLast = (i == quoteBodyLines.count - 1);
                    appendLine(calloutBody, isLast ? calloutBodyParagraph : quoteParagraph);
                }
            } else {
                [quoteBodyLines insertObject:firstContent atIndex:0];
                for (NSUInteger i = 0; i < quoteBodyLines.count; i++) {
                    NSString *bodyLine = quoteBodyLines[i];
                    NSAttributedString *quoteLine = bodyLine.length > 0
                        ? zs_render_markdown_inline(bodyLine, bodyFont, dimColor)
                        : [[NSAttributedString alloc] initWithString:@" "];
                    BOOL isLast = (i == quoteBodyLines.count - 1);
                    appendLine(quoteLine, isLast ? calloutBodyParagraph : quoteParagraph);
                }
            }

            NSRange blockRange = NSMakeRange(blockStartLocation, doc.length - blockStartLocation);
            if (blockRange.length > 0) {
                [doc addAttribute:kZSDocsQuoteBarColorAttributeName value:barColor range:blockRange];
            }
            continue;
        }

        if ([line hasPrefix:@"# "]) {
            continue;
        }

        if ([line hasPrefix:@"## "]) {
            if (sawFirstHeading) {
                appendLine(ruleString(ruleParagraph), ruleParagraph);
            }
            sawFirstHeading = YES;
            NSString *text = [line substringFromIndex:3];
            appendLine(zs_render_markdown_inline(text, h2Font, headingColor), headingParagraph);
            continue;
        }

        if ([line isEqualToString:@"---"]) {
            appendLine(ruleString(bodyParagraph), bodyParagraph);
            continue;
        }

        if ([line hasPrefix:@"!["]) {
            NSString *alt = nil;
            NSString *src = nil;
            NSRange closeBracket = [line rangeOfString:@"]"];
            if (closeBracket.location != NSNotFound) {
                alt = [line substringWithRange:NSMakeRange(2, closeBracket.location - 2)];
                NSUInteger afterBracket = closeBracket.location + 1;
                if (afterBracket < line.length && [line characterAtIndex:afterBracket] == '(') {
                    NSRange afterParenRange = NSMakeRange(afterBracket + 1, line.length - (afterBracket + 1));
                    NSRange closeParen = [line rangeOfString:@")" options:0 range:afterParenRange];
                    if (closeParen.location != NSNotFound) {
                        src = [line substringWithRange:NSMakeRange(afterBracket + 1, closeParen.location - (afterBracket + 1))];
                    }
                }
            }

            UIImage *image = src ? zs_docs_cached_image(src) : nil;
            if (image && image.size.width > 0 && contentWidth > 0) {
                CGFloat displayWidth = MIN(contentWidth, image.size.width);
                CGFloat aspect = image.size.height / image.size.width;

                NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
                attachment.image = image;
                attachment.bounds = CGRectMake(0, 0, displayWidth, displayWidth * aspect);

                NSMutableAttributedString *imageLine =
                    [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
                appendLine(imageLine, imageParagraph);

                if (alt.length > 0) {
                    NSMutableAttributedString *caption = [[NSMutableAttributedString alloc] initWithString:alt
                        attributes:@{NSFontAttributeName: captionFont, NSForegroundColorAttributeName: dimColor}];
                    appendLine(caption, imageParagraph);
                }
                continue;
            }

            NSString *fallback = alt.length > 0 ? [NSString stringWithFormat:@"[image: %@]", alt] : @"[see image in docs]";
            appendLine([[NSAttributedString alloc] initWithString:fallback
                attributes:@{NSFontAttributeName: captionFont, NSForegroundColorAttributeName: dimColor}], bodyParagraph);
            continue;
        }

        if ([line hasPrefix:@"- "] || [line hasPrefix:@"* "]) {
            NSMutableAttributedString *bullet = [[NSMutableAttributedString alloc] initWithString:@"\u2022  "
                attributes:@{NSFontAttributeName: bodyFont, NSForegroundColorAttributeName: dimColor}];
            [bullet appendAttributedString:zs_render_markdown_inline([line substringFromIndex:2], bodyFont, bodyColor)];
            appendLine(bullet, bodyParagraph);
            continue;
        }

        appendLine(zs_render_markdown_inline(line, bodyFont, bodyColor), bodyParagraph);
    }

    return doc;
}

static NSString *zs_docs_title(NSString *markdown) {
    for (NSString *rawLine in [markdown componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:@"# "]) return [line substringFromIndex:2];
    }
    return nil;
}
