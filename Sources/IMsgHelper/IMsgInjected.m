//
//  IMsgInjected.m
//  IMsgHelper - Injectable dylib for Messages.app
//
//  This dylib is injected into Messages.app via DYLD_INSERT_LIBRARIES
//  to gain access to IMCore's chat registry and messaging functions.
//  It provides a Unix socket server for IPC with the CLI.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <dlfcn.h>

#pragma mark - Constants

// File-based IPC paths (in container for sandbox compatibility)
static NSString *kCommandFile = nil;
static NSString *kResponseFile = nil;
static NSString *kLockFile = nil;
static dispatch_source_t fileWatchSource = nil;
static NSTimer *fileWatchTimer = nil;
static int lockFd = -1;
static NSMutableArray *_diagLog = nil;

static void initFilePaths(void) {
    if (kCommandFile == nil) {
        // Use container path which Messages.app can write to
        NSString *containerPath = NSHomeDirectory();
        kCommandFile = [containerPath stringByAppendingPathComponent:@".imsg-plus-command.json"];
        kResponseFile = [containerPath stringByAppendingPathComponent:@".imsg-plus-response.json"];
        kLockFile = [containerPath stringByAppendingPathComponent:@".imsg-plus-ready"];
    }
}

#pragma mark - Forward Declarations for IMCore Classes

@interface IMChatRegistry : NSObject
+ (instancetype)sharedInstance;
- (id)existingChatWithGUID:(NSString *)guid;
- (id)existingChatWithChatIdentifier:(NSString *)identifier;
- (NSArray *)allExistingChats;
- (id)chatForIMHandles:(NSArray *)handles;
@end

@interface IMChat : NSObject
- (void)setLocalUserIsTyping:(BOOL)typing;
- (void)markAllMessagesAsRead;
- (id)messageForGUID:(NSString *)guid;
- (void)sendMessage:(id)message;
- (NSArray *)participants;
- (NSString *)guid;
- (NSString *)chatIdentifier;
- (NSString *)displayName;
- (void)_setDisplayName:(NSString *)name;
@end

@interface IMHandle : NSObject
- (NSString *)ID;
@end

@interface IMServiceImpl : NSObject
+ (instancetype)iMessageService;
+ (instancetype)smsService;
@end

@interface IMAccount : NSObject
- (id)imHandleWithID:(NSString *)handleID;
@end

@interface IMAccountController : NSObject
+ (instancetype)sharedInstance;
- (id)bestAccountForService:(id)service;
@end

@interface IMFileTransferCenter : NSObject
+ (instancetype)sharedInstance;
- (NSString *)guidForNewOutgoingTransferWithLocalURL:(NSURL *)localURL;
- (id)transferForGUID:(NSString *)guid;
- (void)retargetTransfer:(NSString *)guid toPath:(NSString *)path;
- (void)registerTransferWithDaemon:(NSString *)guid;
@end

@interface IMFileTransfer : NSObject
@property (nonatomic, strong) NSURL *localURL;
- (NSString *)guid;
@end

#pragma mark - Runtime Method Injection

// Provide missing isEditedMessageHistory method for IMMessageItem compatibility
static BOOL IMMessageItem_isEditedMessageHistory(id self, SEL _cmd) {
    // Return NO as default - this message is not an edited message history item
    return NO;
}

static void injectCompatibilityMethods(void) {
    SEL selector = @selector(isEditedMessageHistory);

    // Add isEditedMessageHistory to IMMessageItem if it doesn't exist
    Class IMMessageItemClass = NSClassFromString(@"IMMessageItem");
    if (IMMessageItemClass) {
        if (![IMMessageItemClass instancesRespondToSelector:selector]) {
            class_addMethod(IMMessageItemClass, selector,
                          (IMP)IMMessageItem_isEditedMessageHistory, "c@:");
            NSLog(@"[imsg-plus] Added isEditedMessageHistory method to IMMessageItem");
        }
    }

    // Also add to IMMessage class (different from IMMessageItem)
    Class IMMessageClass = NSClassFromString(@"IMMessage");
    if (IMMessageClass) {
        if (![IMMessageClass instancesRespondToSelector:selector]) {
            class_addMethod(IMMessageClass, selector,
                          (IMP)IMMessageItem_isEditedMessageHistory, "c@:");
            NSLog(@"[imsg-plus] Added isEditedMessageHistory method to IMMessage");
        }
    }
}

#pragma mark - Send Path Swizzles (spy on native UI sends)

// Original IMPs stored here so we can call through
static IMP _orig_CKConv_sendMessage_newComposition = NULL;
static IMP _orig_CKConv_sendMessage_onService_newComposition = NULL;
static IMP _orig_IMChat_sendMessage = NULL;

static void swizzled_CKConv_sendMessage_newComposition(id self, SEL _cmd, id message, id composition) {
    if (!_diagLog) _diagLog = [NSMutableArray array];
    [_diagLog addObject:@"=== SWIZZLE: CKConversation sendMessage:newComposition: ==="];
    [_diagLog addObject:[NSString stringWithFormat:@"self=%@ class=%@", self, [self class]]];

    // Log message properties
    if (message) {
        [_diagLog addObject:[NSString stringWithFormat:@"message class=%@", [message class]]];
        @try {
            [_diagLog addObject:[NSString stringWithFormat:@"  guid=%@", [message valueForKey:@"guid"]]];
            [_diagLog addObject:[NSString stringWithFormat:@"  expressiveSendStyleID=%@", [message valueForKey:@"expressiveSendStyleID"]]];
            [_diagLog addObject:[NSString stringWithFormat:@"  fileTransferGUIDs=%@", [message valueForKey:@"fileTransferGUIDs"]]];
            [_diagLog addObject:[NSString stringWithFormat:@"  threadIdentifier=%@", [message valueForKey:@"threadIdentifier"]]];
            [_diagLog addObject:[NSString stringWithFormat:@"  flags=%@", [message valueForKey:@"flags"]]];
            id text = [message valueForKey:@"text"];
            if ([text isKindOfClass:[NSAttributedString class]]) {
                NSAttributedString *attrText = (NSAttributedString *)text;
                [_diagLog addObject:[NSString stringWithFormat:@"  text.string=%@ (len=%lu)", attrText.string, (unsigned long)attrText.length]];
                // Log attributes on first char
                if (attrText.length > 0) {
                    NSDictionary *attrs = [attrText attributesAtIndex:0 effectiveRange:NULL];
                    [_diagLog addObject:[NSString stringWithFormat:@"  text.attrs[0]=%@", attrs]];
                }
            } else {
                [_diagLog addObject:[NSString stringWithFormat:@"  text=%@", text]];
            }
        } @catch (NSException *e) {
            [_diagLog addObject:[NSString stringWithFormat:@"  msg props error: %@", e.reason]];
        }
    } else {
        [_diagLog addObject:@"message=nil"];
    }

    // Log composition properties
    if (composition) {
        [_diagLog addObject:[NSString stringWithFormat:@"composition class=%@", [composition class]]];
        @try {
            if ([composition respondsToSelector:@selector(expressiveSendStyleID)]) {
                [_diagLog addObject:[NSString stringWithFormat:@"  expressiveSendStyleID=%@",
                      [composition performSelector:@selector(expressiveSendStyleID)]]];
            }
            if ([composition respondsToSelector:@selector(text)]) {
                id compText = [composition performSelector:@selector(text)];
                if ([compText isKindOfClass:[NSAttributedString class]]) {
                    NSAttributedString *at = (NSAttributedString *)compText;
                    [_diagLog addObject:[NSString stringWithFormat:@"  text.string=%@ (len=%lu)", at.string, (unsigned long)at.length]];
                    if (at.length > 0) {
                        // Log all attributes across the full range
                        [at enumerateAttributesInRange:NSMakeRange(0, at.length) options:0
                            usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
                                [_diagLog addObject:[NSString stringWithFormat:@"  text.attrs[%lu-%lu]=%@",
                                      (unsigned long)range.location, (unsigned long)(range.location+range.length), attrs]];
                            }];
                    }
                } else {
                    [_diagLog addObject:[NSString stringWithFormat:@"  text=%@", compText]];
                }
            }
            if ([composition respondsToSelector:@selector(mediaObjects)]) {
                NSArray *mos = [composition performSelector:@selector(mediaObjects)];
                [_diagLog addObject:[NSString stringWithFormat:@"  mediaObjects count=%lu", (unsigned long)mos.count]];
                for (NSUInteger i = 0; i < mos.count; i++) {
                    id mo = mos[i];
                    [_diagLog addObject:[NSString stringWithFormat:@"    mo[%lu] class=%@ transferGUID=%@ fileURL=%@",
                          (unsigned long)i, [mo class],
                          [mo respondsToSelector:@selector(transferGUID)] ? [mo performSelector:@selector(transferGUID)] : @"N/A",
                          [mo respondsToSelector:@selector(fileURL)] ? [mo performSelector:@selector(fileURL)] : @"N/A"]];
                }
            }
            if ([composition respondsToSelector:@selector(hasContent)]) {
                BOOL hc = ((BOOL (*)(id, SEL))objc_msgSend)(composition, @selector(hasContent));
                [_diagLog addObject:[NSString stringWithFormat:@"  hasContent=%d", hc]];
            }
        } @catch (NSException *e) {
            [_diagLog addObject:[NSString stringWithFormat:@"  comp props error: %@", e.reason]];
        }
    } else {
        [_diagLog addObject:@"composition=nil"];
    }

    // Call original
    if (_orig_CKConv_sendMessage_newComposition) {
        typedef void (*OrigType)(id, SEL, id, id);
        ((OrigType)_orig_CKConv_sendMessage_newComposition)(self, _cmd, message, composition);
    }
}

static void swizzled_CKConv_sendMessage_onService_newComposition(id self, SEL _cmd, id message, id service, id composition) {
    if (!_diagLog) _diagLog = [NSMutableArray array];
    [_diagLog addObject:@"=== SWIZZLE: CKConversation sendMessage:onService:newComposition: ==="];
    [_diagLog addObject:[NSString stringWithFormat:@"service=%@ class=%@", service, service ? [service class] : @"nil"]];

    // Reuse the 2-arg swizzle's logging by calling it, but don't call through twice
    // Just log the extra service param and call original
    if (message) {
        @try {
            [_diagLog addObject:[NSString stringWithFormat:@"message.expressiveSendStyleID=%@", [message valueForKey:@"expressiveSendStyleID"]]];
            [_diagLog addObject:[NSString stringWithFormat:@"message.fileTransferGUIDs=%@", [message valueForKey:@"fileTransferGUIDs"]]];
        } @catch (NSException *e) {}
    } else {
        [_diagLog addObject:@"message=nil"];
    }
    if (composition) {
        @try {
            if ([composition respondsToSelector:@selector(expressiveSendStyleID)])
                [_diagLog addObject:[NSString stringWithFormat:@"composition.expressiveSendStyleID=%@",
                      [composition performSelector:@selector(expressiveSendStyleID)]]];
            if ([composition respondsToSelector:@selector(mediaObjects)]) {
                NSArray *mos = [composition performSelector:@selector(mediaObjects)];
                [_diagLog addObject:[NSString stringWithFormat:@"composition.mediaObjects count=%lu", (unsigned long)mos.count]];
            }
        } @catch (NSException *e) {}
    } else {
        [_diagLog addObject:@"composition=nil"];
    }

    if (_orig_CKConv_sendMessage_onService_newComposition) {
        typedef void (*OrigType)(id, SEL, id, id, id);
        ((OrigType)_orig_CKConv_sendMessage_onService_newComposition)(self, _cmd, message, service, composition);
    }
}

static void swizzled_IMChat_sendMessage(id self, SEL _cmd, id message) {
    if (!_diagLog) _diagLog = [NSMutableArray array];
    [_diagLog addObject:@"=== SWIZZLE: IMChat sendMessage: ==="];
    if (message) {
        @try {
            [_diagLog addObject:[NSString stringWithFormat:@"message class=%@ guid=%@", [message class], [message valueForKey:@"guid"]]];
            [_diagLog addObject:[NSString stringWithFormat:@"  expressiveSendStyleID=%@", [message valueForKey:@"expressiveSendStyleID"]]];
            [_diagLog addObject:[NSString stringWithFormat:@"  fileTransferGUIDs=%@", [message valueForKey:@"fileTransferGUIDs"]]];
        } @catch (NSException *e) {
            [_diagLog addObject:[NSString stringWithFormat:@"  error: %@", e.reason]];
        }
    }

    if (_orig_IMChat_sendMessage) {
        typedef void (*OrigType)(id, SEL, id);
        ((OrigType)_orig_IMChat_sendMessage)(self, _cmd, message);
    }
}

static void installSendSwizzles(void) {
    // Swizzle CKConversation sendMessage:newComposition:
    Class ckConvClass = NSClassFromString(@"CKConversation");
    if (ckConvClass) {
        SEL sel2 = @selector(sendMessage:newComposition:);
        Method m2 = class_getInstanceMethod(ckConvClass, sel2);
        if (m2) {
            _orig_CKConv_sendMessage_newComposition = method_setImplementation(m2,
                (IMP)swizzled_CKConv_sendMessage_newComposition);
            NSLog(@"[imsg-plus] Swizzled CKConversation sendMessage:newComposition:");
        }

        SEL sel3 = @selector(sendMessage:onService:newComposition:);
        Method m3 = class_getInstanceMethod(ckConvClass, sel3);
        if (m3) {
            _orig_CKConv_sendMessage_onService_newComposition = method_setImplementation(m3,
                (IMP)swizzled_CKConv_sendMessage_onService_newComposition);
            NSLog(@"[imsg-plus] Swizzled CKConversation sendMessage:onService:newComposition:");
        }
    }

    // Swizzle IMChat sendMessage:
    Class imChatClass = NSClassFromString(@"IMChat");
    if (imChatClass) {
        SEL sel = @selector(sendMessage:);
        Method m = class_getInstanceMethod(imChatClass, sel);
        if (m) {
            _orig_IMChat_sendMessage = method_setImplementation(m,
                (IMP)swizzled_IMChat_sendMessage);
            NSLog(@"[imsg-plus] Swizzled IMChat sendMessage:");
        }
    }
}

#pragma mark - JSON Response Helpers

static NSDictionary* successResponse(NSInteger requestId, NSDictionary *data) {
    NSMutableDictionary *response = [NSMutableDictionary dictionaryWithDictionary:data ?: @{}];
    response[@"id"] = @(requestId);
    response[@"success"] = @YES;
    response[@"timestamp"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    return response;
}

static NSDictionary* errorResponse(NSInteger requestId, NSString *error) {
    return @{
        @"id": @(requestId),
        @"success": @NO,
        @"error": error ?: @"Unknown error",
        @"timestamp": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]
    };
}

#pragma mark - Chat Resolution

// Try multiple methods to find a chat, similar to BlueBubbles approach
static id findChat(NSString *identifier) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        NSLog(@"[imsg-plus] IMChatRegistry class not found");
        return nil;
    }

    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        NSLog(@"[imsg-plus] Could not get IMChatRegistry instance");
        return nil;
    }

    id chat = nil;

    // Method 1: Try existingChatWithGUID: (BlueBubbles approach)
    // This expects full GUID like "iMessage;-;email@example.com"
    SEL guidSel = @selector(existingChatWithGUID:);
    if ([registry respondsToSelector:guidSel]) {
        // If identifier already looks like a GUID, use it directly
        if ([identifier containsString:@";"]) {
            chat = [registry performSelector:guidSel withObject:identifier];
            if (chat) {
                NSLog(@"[imsg-plus] Found chat via existingChatWithGUID: %@", identifier);
                return chat;
            }
        }

        // Try constructing GUIDs with common prefixes
        NSArray *prefixes = @[@"iMessage;-;", @"iMessage;+;", @"SMS;-;", @"SMS;+;"];
        for (NSString *prefix in prefixes) {
            NSString *fullGUID = [prefix stringByAppendingString:identifier];
            chat = [registry performSelector:guidSel withObject:fullGUID];
            if (chat) {
                NSLog(@"[imsg-plus] Found chat via existingChatWithGUID: %@", fullGUID);
                return chat;
            }
        }
    }

    // Method 2: Try existingChatWithChatIdentifier:
    SEL identSel = @selector(existingChatWithChatIdentifier:);
    if ([registry respondsToSelector:identSel]) {
        chat = [registry performSelector:identSel withObject:identifier];
        if (chat) {
            NSLog(@"[imsg-plus] Found chat via existingChatWithChatIdentifier: %@", identifier);
            return chat;
        }
    }

    // Method 3: Iterate all chats and match by participant (exact matching only)
    SEL allChatsSel = @selector(allExistingChats);
    if ([registry respondsToSelector:allChatsSel]) {
        NSArray *allChats = [registry performSelector:allChatsSel];
        if (!allChats) {
            NSLog(@"[imsg-plus] allExistingChats returned nil");
            return nil;
        }
        NSLog(@"[imsg-plus] Searching %lu chats for identifier: %@", (unsigned long)allChats.count, identifier);

        // Normalize the search identifier (strip non-digit chars for phone numbers)
        NSString *normalizedIdentifier = nil;
        if ([identifier hasPrefix:@"+"] || [identifier hasPrefix:@"1"] ||
            [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[identifier characterAtIndex:0]]) {
            NSMutableString *digits = [NSMutableString string];
            for (NSUInteger i = 0; i < identifier.length; i++) {
                unichar c = [identifier characterAtIndex:i];
                if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
                    [digits appendFormat:@"%C", c];
                }
            }
            normalizedIdentifier = [digits copy];
        }

        for (id aChat in allChats) {
            // Check GUID — exact match only
            if ([aChat respondsToSelector:@selector(guid)]) {
                NSString *chatGUID = [aChat performSelector:@selector(guid)];
                if ([chatGUID isEqualToString:identifier]) {
                    NSLog(@"[imsg-plus] Found chat by GUID exact match: %@", chatGUID);
                    return aChat;
                }
            }

            // Check chatIdentifier — exact match only
            if ([aChat respondsToSelector:@selector(chatIdentifier)]) {
                NSString *chatId = [aChat performSelector:@selector(chatIdentifier)];
                if ([chatId isEqualToString:identifier]) {
                    NSLog(@"[imsg-plus] Found chat by chatIdentifier exact match: %@", chatId);
                    return aChat;
                }
            }

            // Check participants — exact or normalized phone match
            if ([aChat respondsToSelector:@selector(participants)]) {
                NSArray *participants = [aChat performSelector:@selector(participants)];
                if (!participants) {
                    continue;
                }
                for (id handle in participants) {
                    if ([handle respondsToSelector:@selector(ID)]) {
                        NSString *handleID = [handle performSelector:@selector(ID)];
                        // Exact match
                        if ([handleID isEqualToString:identifier]) {
                            NSLog(@"[imsg-plus] Found chat by participant exact match: %@", handleID);
                            return aChat;
                        }
                        // Normalized phone number match (compare digits only)
                        if (normalizedIdentifier && normalizedIdentifier.length >= 10) {
                            NSMutableString *handleDigits = [NSMutableString string];
                            for (NSUInteger i = 0; i < handleID.length; i++) {
                                unichar c = [handleID characterAtIndex:i];
                                if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
                                    [handleDigits appendFormat:@"%C", c];
                                }
                            }
                            if (handleDigits.length >= 10 &&
                                [handleDigits hasSuffix:normalizedIdentifier] ||
                                [normalizedIdentifier hasSuffix:handleDigits]) {
                                NSLog(@"[imsg-plus] Found chat by normalized phone match: %@ ~ %@", handleID, identifier);
                                return aChat;
                            }
                        }
                    }
                }
            }
        }
    }

    NSLog(@"[imsg-plus] Chat not found for identifier: %@", identifier);
    return nil;
}

#pragma mark - Attachment Preparation

// Prepare a file attachment for sending via IMCore.
// Returns the transfer GUID on success, or nil on failure (with error logged).
// Thread-local diagnostic string for prepareAttachment failure reason
static NSString *_attachmentDiag = nil;

static NSString* prepareAttachment(NSString *filePath, NSString *chatGUID) {
    _attachmentDiag = nil;

    if (!filePath || filePath.length == 0) {
        _attachmentDiag = @"empty file path";
        return nil;
    }

    // Validate file exists
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath isDirectory:&isDir] || isDir) {
        _attachmentDiag = [NSString stringWithFormat:@"file not found: %@", filePath];
        return nil;
    }

    NSURL *localURL = [NSURL fileURLWithPath:filePath];

    // Get IMFileTransferCenter
    Class ftcClass = NSClassFromString(@"IMFileTransferCenter");
    if (!ftcClass) {
        _attachmentDiag = @"IMFileTransferCenter class not found";
        return nil;
    }

    id ftCenter = [ftcClass performSelector:@selector(sharedInstance)];
    if (!ftCenter) {
        _attachmentDiag = @"IMFileTransferCenter sharedInstance nil";
        return nil;
    }

    // Create a new outgoing transfer
    SEL guidSel = @selector(guidForNewOutgoingTransferWithLocalURL:);
    if (![ftCenter respondsToSelector:guidSel]) {
        _attachmentDiag = @"guidForNewOutgoingTransferWithLocalURL: not available";
        return nil;
    }

    NSString *transferGUID = [ftCenter performSelector:guidSel withObject:localURL];
    if (!transferGUID) {
        _attachmentDiag = [NSString stringWithFormat:@"transfer GUID nil for URL: %@", localURL];
        return nil;
    }
    NSLog(@"[imsg-plus] prepareAttachment: created transfer GUID: %@", transferGUID);

    // The file path is expected to already be staged by the caller (CLI process)
    // at a location accessible to the daemon (e.g. ~/Library/Messages/Attachments/).
    // The CLI is not sandboxed and can copy files there before calling the bridge.
    // guidForNewOutgoingTransferWithLocalURL: already points the transfer at filePath.
    SEL registerSel = @selector(registerTransferWithDaemon:);
    if ([ftCenter respondsToSelector:registerSel]) {
        [ftCenter performSelector:registerSel withObject:transferGUID];
        NSLog(@"[imsg-plus] prepareAttachment: registered transfer with daemon");
    } else {
        _attachmentDiag = @"registerTransferWithDaemon: not available";
        return nil;
    }

    NSLog(@"[imsg-plus] prepareAttachment: ready, GUID=%@", transferGUID);
    return transferGUID;
}

#pragma mark - Command Handlers

static NSDictionary* handleTyping(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSNumber *state = params[@"typing"] ?: params[@"state"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }

    BOOL typing = [state boolValue];
    id chat = findChat(handle);

    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        // Check if chat supports typing indicators
        BOOL supportsTyping = YES;
        SEL supportsSel = @selector(supportsSendingTypingIndicators);
        if ([chat respondsToSelector:supportsSel]) {
            supportsTyping = ((BOOL (*)(id, SEL))objc_msgSend)(chat, supportsSel);
            NSLog(@"[imsg-plus] Chat supports typing indicators: %@", supportsTyping ? @"YES" : @"NO");
        }

        // Use setLocalUserIsTyping: (simpler and more reliable)
        SEL typingSel = @selector(setLocalUserIsTyping:);
        if ([chat respondsToSelector:typingSel]) {
            NSMethodSignature *sig = [chat methodSignatureForSelector:typingSel];
            if (!sig) {
                return errorResponse(requestId, @"Could not get method signature for setLocalUserIsTyping:");
            }
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:typingSel];
            [inv setTarget:chat];
            [inv setArgument:&typing atIndex:2];
            [inv invoke];

            NSLog(@"[imsg-plus] Called setLocalUserIsTyping:%@ for %@", typing ? @"YES" : @"NO", handle);
            return successResponse(requestId, @{
                @"handle": handle,
                @"typing": @(typing),
                @"supports_typing": @(supportsTyping)
            });
        }

        return errorResponse(requestId, @"setLocalUserIsTyping: method not available");
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to set typing: %@", exception.reason]);
    }
}

static NSDictionary* handleRead(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }

    id chat = findChat(handle);

    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        SEL readSel = @selector(markAllMessagesAsRead);
        if ([chat respondsToSelector:readSel]) {
            [chat performSelector:readSel];
            NSLog(@"[imsg-plus] Marked all messages as read for %@", handle);
            return successResponse(requestId, @{
                @"handle": handle,
                @"marked_as_read": @YES
            });
        } else {
            return errorResponse(requestId, @"markAllMessagesAsRead method not available");
        }
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to mark as read: %@", exception.reason]);
    }
}

// Helper to write a response dictionary to the response file (for async handlers)
static void writeResponseToFile(NSDictionary *response) {
    initFilePaths();
    NSData *responseData = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingPrettyPrinted error:nil];
    [responseData writeToFile:kResponseFile atomically:YES];
    [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[imsg-plus] Wrote async response to file");
}

// Map reaction type to verb string for summary text
static NSString* reactionVerb(long long reactionType) {
    // For removals (3000+), use the same verb as the base type
    long long baseType = reactionType >= 3000 ? reactionType - 1000 : reactionType;
    switch (baseType) {
        case 2000: return @"Loved ";
        case 2001: return @"Liked ";
        case 2002: return @"Disliked ";
        case 2003: return @"Laughed at ";
        case 2004: return @"Emphasized ";
        case 2005: return @"Questioned ";
        default:   return @"Reacted to ";
    }
}

// handleReact returns nil when it handles the response asynchronously
static NSDictionary* handleReact(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *messageGUID = params[@"guid"];
    NSNumber *type = params[@"type"];
    NSString *emoji = params[@"emoji"];  // Custom emoji string (for type 2006/3006)
    NSNumber *partIndexNum = params[@"partIndex"];
    int partIndex = partIndexNum ? [partIndexNum intValue] : 0;

    if (!handle || !messageGUID || !type) {
        return errorResponse(requestId, @"Missing required parameters: handle, guid, type");
    }

    id chat = findChat(handle);
    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    // Get IMChatHistoryController to load the message by GUID asynchronously
    Class historyClass = NSClassFromString(@"IMChatHistoryController");
    if (!historyClass) {
        return errorResponse(requestId, @"IMChatHistoryController class not found");
    }

    id historyController = [historyClass performSelector:@selector(sharedInstance)];
    if (!historyController) {
        return errorResponse(requestId, @"Could not get IMChatHistoryController instance");
    }

    SEL loadSel = @selector(loadMessageWithGUID:completionBlock:);
    if (![historyController respondsToSelector:loadSel]) {
        return errorResponse(requestId, @"loadMessageWithGUID:completionBlock: not available");
    }

    NSLog(@"[imsg-plus] Loading message %@ via IMChatHistoryController (async)...", messageGUID);

    // Capture values for the completion block
    long long reactionType = [type longLongValue];

    // Build and invoke the async load call
    NSMethodSignature *loadSig = [historyController methodSignatureForSelector:loadSel];
    if (!loadSig) {
        return errorResponse(requestId, @"Could not get method signature for loadMessageWithGUID:completionBlock:");
    }
    NSInvocation *loadInv = [NSInvocation invocationWithMethodSignature:loadSig];
    [loadInv setSelector:loadSel];
    [loadInv setTarget:historyController];
    [loadInv setArgument:&messageGUID atIndex:2];

    // The completion block receives the loaded IMMessage
    void (^completionBlock)(id) = ^(id message) {
        @autoreleasepool {
            NSLog(@"[imsg-plus] loadMessageWithGUID completion fired, message=%@, class=%@",
                  message, message ? [message class] : @"nil");

            if (!message) {
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Message not found for GUID: %@", messageGUID]));
                return;
            }

            @try {
                // Get IMMessageItem and chat items from the message
                id messageItem = [message valueForKey:@"_imMessageItem"];
                NSLog(@"[imsg-plus] messageItem class: %@", messageItem ? [messageItem class] : @"nil");

                id items = nil;
                if (messageItem && [messageItem respondsToSelector:@selector(_newChatItems)]) {
                    items = [messageItem performSelector:@selector(_newChatItems)];
                } else if (messageItem) {
                    items = [messageItem valueForKey:@"_newChatItems"];
                }
                NSLog(@"[imsg-plus] _newChatItems: %@ (class: %@)", items, items ? [items class] : @"nil");

                // Find the IMMessagePartChatItem at partIndex
                id partItem = nil;
                if ([items isKindOfClass:[NSArray class]]) {
                    NSArray *itemArray = (NSArray *)items;
                    NSLog(@"[imsg-plus] Got %lu chat items from message", (unsigned long)itemArray.count);
                    for (id item in itemArray) {
                        // Look for IMMessagePartChatItem or IMTextMessagePartChatItem
                        NSString *className = NSStringFromClass([item class]);
                        if ([className containsString:@"MessagePartChatItem"] ||
                            [className containsString:@"TextMessagePartChatItem"]) {
                            // Check if this is the right part index
                            if ([item respondsToSelector:@selector(index)]) {
                                NSInteger idx = ((NSInteger (*)(id, SEL))objc_msgSend)(item, @selector(index));
                                if (idx == partIndex) {
                                    partItem = item;
                                    break;
                                }
                            } else if (partIndex == 0) {
                                // Default: use first matching item
                                partItem = item;
                                break;
                            }
                        }
                    }
                    // Fallback: if no specific part found, use first item
                    if (!partItem && itemArray.count > 0) {
                        partItem = itemArray[partIndex < (int)itemArray.count ? partIndex : 0];
                    }
                } else if (items) {
                    partItem = items;
                }

                NSLog(@"[imsg-plus] partItem: %@ (class: %@)", partItem, partItem ? [partItem class] : @"nil");

                // Get text for the summary
                NSAttributedString *itemText = nil;
                if (partItem && [partItem respondsToSelector:@selector(text)]) {
                    itemText = [partItem performSelector:@selector(text)];
                }
                if (!itemText && [message respondsToSelector:@selector(text)]) {
                    itemText = [message performSelector:@selector(text)];
                }
                NSString *summaryText = itemText ? itemText.string : @"";
                if (!summaryText) summaryText = @"";
                NSLog(@"[imsg-plus] summaryText: %@", summaryText);

                // Build the associated GUID: p:PARTINDEX/MESSAGE_GUID
                NSString *associatedGuid = [NSString stringWithFormat:@"p:%d/%@", partIndex, messageGUID];
                NSLog(@"[imsg-plus] associatedGuid: %@", associatedGuid);

                // Build message summary info
                NSMutableDictionary *messageSummary = [@{@"amc": @1, @"ams": summaryText} mutableCopy];
                if (emoji && (reactionType == 2006 || reactionType == 3006)) {
                    messageSummary[@"ame"] = emoji;
                }

                // Build the reaction text
                NSString *reactionString;
                if (emoji && (reactionType == 2006 || reactionType == 3006)) {
                    // Custom emoji: "Reacted 🎉 to "message text""
                    reactionString = [NSString stringWithFormat:@"Reacted %@ to \u201c%@\u201d", emoji, summaryText];
                } else {
                    // Standard tapback: "Loved "message text""
                    NSString *verb = reactionVerb(reactionType);
                    reactionString = [verb stringByAppendingString:
                        [NSString stringWithFormat:@"\u201c%@\u201d", summaryText]];
                }
                NSMutableAttributedString *reactionText =
                    [[NSMutableAttributedString alloc] initWithString:reactionString];

                // Get messagePartRange from the part item
                NSRange partRange = NSMakeRange(0, summaryText.length);
                if (partItem) {
                    SEL rangeSel = @selector(messagePartRange);
                    if ([partItem respondsToSelector:rangeSel]) {
                        NSMethodSignature *sig = [partItem methodSignatureForSelector:rangeSel];
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setSelector:rangeSel];
                        [inv setTarget:partItem];
                        [inv invoke];
                        [inv getReturnValue:&partRange];
                        NSLog(@"[imsg-plus] messagePartRange: {%lu, %lu}",
                              (unsigned long)partRange.location, (unsigned long)partRange.length);
                    }
                }

                // Create the IMMessage for the reaction using the long init method
                Class IMMessageClass = NSClassFromString(@"IMMessage");
                if (!IMMessageClass) {
                    writeResponseToFile(errorResponse(requestId, @"IMMessage class not found"));
                    return;
                }

                id reactionMessage = [IMMessageClass alloc];

                // The init selector with associated message fields
                SEL initSel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:);

                if (![reactionMessage respondsToSelector:initSel]) {
                    NSLog(@"[imsg-plus] Long init selector not available, dumping IMMessage init methods...");
                    unsigned int methodCount;
                    Method *methods = class_copyMethodList(IMMessageClass, &methodCount);
                    for (unsigned int i = 0; i < methodCount; i++) {
                        NSString *name = NSStringFromSelector(method_getName(methods[i]));
                        if ([name hasPrefix:@"initWith"]) {
                            NSLog(@"[imsg-plus]   %@", name);
                        }
                    }
                    free(methods);
                    writeResponseToFile(errorResponse(requestId,
                        @"IMMessage initWithSender:time:text:...associatedMessage... selector not found"));
                    return;
                }

                // Use objc_msgSend with the correct type signature
                // Args: self, _cmd, sender(id), time(id), text(id), messageSubject(id),
                //        fileTransferGUIDs(id), flags(unsigned long long), error(id),
                //        guid(id), subject(id), associatedMessageGUID(id),
                //        associatedMessageType(long long), associatedMessageRange(NSRange),
                //        messageSummaryInfo(id)
                typedef id (*InitMsgSendType)(id, SEL,
                    id,                  // sender
                    id,                  // time
                    id,                  // text
                    id,                  // messageSubject
                    id,                  // fileTransferGUIDs
                    unsigned long long,  // flags
                    id,                  // error
                    id,                  // guid
                    id,                  // subject
                    id,                  // associatedMessageGUID
                    long long,           // associatedMessageType
                    NSRange,             // associatedMessageRange
                    id                   // messageSummaryInfo
                );

                InitMsgSendType initMsgSend = (InitMsgSendType)objc_msgSend;
                reactionMessage = initMsgSend(reactionMessage, initSel,
                    nil,                     // sender
                    nil,                     // time
                    reactionText,            // text
                    nil,                     // messageSubject
                    nil,                     // fileTransferGUIDs
                    (unsigned long long)0x5, // flags
                    nil,                     // error
                    nil,                     // guid
                    nil,                     // subject
                    associatedGuid,          // associatedMessageGUID
                    reactionType,            // associatedMessageType
                    partRange,               // associatedMessageRange
                    messageSummary           // messageSummaryInfo
                );

                if (!reactionMessage) {
                    writeResponseToFile(errorResponse(requestId, @"Failed to create reaction IMMessage (init returned nil)"));
                    return;
                }

                NSLog(@"[imsg-plus] Created reaction message: %@ (class: %@)", reactionMessage, [reactionMessage class]);

                // Set associated emoji for custom emoji reactions (type 2006/3006)
                if (emoji && (reactionType == 2006 || reactionType == 3006)) {
                    @try {
                        [reactionMessage setValue:emoji forKey:@"associatedMessageEmoji"];
                        NSLog(@"[imsg-plus] Set associatedMessageEmoji = %@", emoji);
                    } @catch (NSException *e) {
                        NSLog(@"[imsg-plus] ⚠️ Could not set associatedMessageEmoji via KVC: %@", e.reason);
                        // Try underscore-prefixed ivar as fallback
                        @try {
                            [reactionMessage setValue:emoji forKey:@"_associatedMessageEmoji"];
                            NSLog(@"[imsg-plus] Set _associatedMessageEmoji = %@", emoji);
                        } @catch (NSException *e2) {
                            NSLog(@"[imsg-plus] ⚠️ Could not set _associatedMessageEmoji either: %@", e2.reason);
                        }
                    }
                }

                // Send the reaction message
                SEL sendSel = @selector(sendMessage:);
                if (![chat respondsToSelector:sendSel]) {
                    writeResponseToFile(errorResponse(requestId, @"Chat does not respond to sendMessage:"));
                    return;
                }

                [chat performSelector:sendSel withObject:reactionMessage];
                NSLog(@"[imsg-plus] ✅ Sent reaction message via sendMessage:");

                NSMutableDictionary *resultDict = [@{
                    @"handle": handle,
                    @"guid": messageGUID,
                    @"type": type,
                    @"partIndex": @(partIndex),
                    @"action": reactionType >= 3000 ? @"removed" : @"added",
                    @"method": @"createMessage_BlueBubbles"
                } mutableCopy];
                if (emoji) {
                    resultDict[@"emoji"] = emoji;
                }
                writeResponseToFile(successResponse(requestId, resultDict));
            } @catch (NSException *exception) {
                NSLog(@"[imsg-plus] ❌ Exception in react completion: %@\n%@", exception.reason, exception.callStackSymbols);
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Failed in react completion: %@", exception.reason]));
            }
        }
    };

    [loadInv setArgument:&completionBlock atIndex:3];
    [loadInv invoke];

    NSLog(@"[imsg-plus] loadMessageWithGUID invoked, waiting for async completion...");

    // Set a 5-second timeout: if the completion block never fires (e.g. invalid GUID),
    // write an error response so the CLI doesn't hang indefinitely.
    __block BOOL completionFired = NO;
    // Patch the completion block to track if it fired
    void (^originalBlock)(id) = completionBlock;
    completionBlock = nil; // Release our reference; loadInv already retained it
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        // Check if response file has been written (completion fired)
        NSData *responseData = [NSData dataWithContentsOfFile:kResponseFile];
        if (!responseData || responseData.length < 3) {
            NSLog(@"[imsg-plus] ⚠️ React completion timeout after 5s for GUID: %@", messageGUID);
            writeResponseToFile(errorResponse(requestId,
                [NSString stringWithFormat:@"Timeout: message GUID not found or completion never fired: %@", messageGUID]));
        }
    });

    // Return nil to signal async handling — processCommandFile will check for this
    return nil;
}

static NSDictionary* handleStatus(NSInteger requestId, NSDictionary *params) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    BOOL hasRegistry = (registryClass != nil);
    NSUInteger chatCount = 0;

    if (hasRegistry) {
        id registry = [registryClass performSelector:@selector(sharedInstance)];
        if ([registry respondsToSelector:@selector(allExistingChats)]) {
            NSArray *chats = [registry performSelector:@selector(allExistingChats)];
            chatCount = chats.count;
        }
    }

    BOOL hasAccountController = (NSClassFromString(@"IMAccountController") != nil);
    BOOL hasServiceImpl = (NSClassFromString(@"IMServiceImpl") != nil);
    BOOL canCreateChat = hasRegistry && hasAccountController && hasServiceImpl;

    BOOL hasFileTransferCenter = (NSClassFromString(@"IMFileTransferCenter") != nil);

    NSMutableDictionary *result = [@{
        @"injected": @YES,
        @"registry_available": @(hasRegistry),
        @"chat_count": @(chatCount),
        @"typing_available": @(hasRegistry),
        @"read_available": @(hasRegistry),
        @"tapback_available": @(hasRegistry),
        @"create_chat_available": @(canCreateChat),
        @"rename_chat_available": @(hasRegistry),
        @"send_message_available": @(hasRegistry),
        @"thread_reply_available": @(hasRegistry),
        @"edit_message_available": @(hasRegistry),
        @"unsend_message_available": @(hasRegistry),
        @"attachment_send_available": @(hasFileTransferCenter),
    } mutableCopy];
    if (_diagLog.count > 0) {
        result[@"send_diag"] = [_diagLog copy];
    }
    return successResponse(requestId, result);
}

static NSDictionary* handleListChats(NSInteger requestId, NSDictionary *params) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        return errorResponse(requestId, @"IMChatRegistry not available");
    }

    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        return errorResponse(requestId, @"Could not get IMChatRegistry instance");
    }

    NSMutableArray *chatList = [NSMutableArray array];

    if ([registry respondsToSelector:@selector(allExistingChats)]) {
        NSArray *allChats = [registry performSelector:@selector(allExistingChats)];
        for (id chat in allChats) {
            NSMutableDictionary *chatInfo = [NSMutableDictionary dictionary];

            if ([chat respondsToSelector:@selector(guid)]) {
                chatInfo[@"guid"] = [chat performSelector:@selector(guid)] ?: @"";
            }
            if ([chat respondsToSelector:@selector(chatIdentifier)]) {
                chatInfo[@"identifier"] = [chat performSelector:@selector(chatIdentifier)] ?: @"";
            }
            if ([chat respondsToSelector:@selector(participants)]) {
                NSMutableArray *handles = [NSMutableArray array];
                NSArray *participants = [chat performSelector:@selector(participants)];
                for (id handle in participants) {
                    if ([handle respondsToSelector:@selector(ID)]) {
                        [handles addObject:[handle performSelector:@selector(ID)] ?: @""];
                    }
                }
                chatInfo[@"participants"] = handles;
            }

            [chatList addObject:chatInfo];
        }
    }

    return successResponse(requestId, @{
        @"chats": chatList,
        @"count": @(chatList.count)
    });
}

static NSDictionary* handleCreateChat(NSInteger requestId, NSDictionary *params) {
    NSArray *addresses = params[@"addresses"];
    NSString *name = params[@"name"];
    NSString *text = params[@"text"];
    NSString *serviceHint = params[@"service"] ?: @"imessage";

    if (!addresses || ![addresses isKindOfClass:[NSArray class]] || addresses.count == 0) {
        return errorResponse(requestId, @"Missing required parameter: addresses (array of phone/email)");
    }

    @try {
        // Get the appropriate service
        Class serviceClass = NSClassFromString(@"IMServiceImpl");
        if (!serviceClass) {
            return errorResponse(requestId, @"IMServiceImpl class not found");
        }

        id service = nil;
        if ([serviceHint isEqualToString:@"sms"]) {
            service = [serviceClass performSelector:@selector(smsService)];
        } else {
            service = [serviceClass performSelector:@selector(iMessageService)];
        }
        if (!service) {
            return errorResponse(requestId, @"Could not get service instance");
        }

        // Get account for the service
        Class accountControllerClass = NSClassFromString(@"IMAccountController");
        if (!accountControllerClass) {
            return errorResponse(requestId, @"IMAccountController class not found");
        }

        id accountController = [accountControllerClass performSelector:@selector(sharedInstance)];
        if (!accountController) {
            return errorResponse(requestId, @"Could not get IMAccountController instance");
        }

        id account = [accountController performSelector:@selector(bestAccountForService:) withObject:service];
        if (!account) {
            return errorResponse(requestId, @"Could not get account for service");
        }

        // Resolve addresses to IMHandles
        NSMutableArray *handles = [NSMutableArray array];
        for (NSString *address in addresses) {
            id handle = [account performSelector:@selector(imHandleWithID:) withObject:address];
            if (handle) {
                [handles addObject:handle];
            } else {
                NSLog(@"[imsg-plus] Warning: could not resolve handle for %@", address);
            }
        }

        if (handles.count == 0) {
            return errorResponse(requestId, @"Could not resolve any handles from the provided addresses");
        }

        // Get or create chat via IMChatRegistry
        Class registryClass = NSClassFromString(@"IMChatRegistry");
        if (!registryClass) {
            return errorResponse(requestId, @"IMChatRegistry class not found");
        }

        id registry = [registryClass performSelector:@selector(sharedInstance)];
        if (!registry) {
            return errorResponse(requestId, @"Could not get IMChatRegistry instance");
        }

        SEL chatForHandlesSel = @selector(chatForIMHandles:);
        if (![registry respondsToSelector:chatForHandlesSel]) {
            return errorResponse(requestId, @"chatForIMHandles: not available on this macOS version");
        }

        id chat = [registry performSelector:chatForHandlesSel withObject:handles];
        if (!chat) {
            return errorResponse(requestId, @"Failed to create/find chat for the given handles");
        }

        // Optionally set display name
        if (name && [name length] > 0) {
            SEL setNameSel = @selector(_setDisplayName:);
            if ([chat respondsToSelector:setNameSel]) {
                [chat performSelector:setNameSel withObject:name];
                NSLog(@"[imsg-plus] Set chat display name to: %@", name);
            } else {
                // Fallback: try setValue:forChatProperty:
                SEL propSel = @selector(setValue:forChatProperty:);
                if ([chat respondsToSelector:propSel]) {
                    NSMethodSignature *sig = [chat methodSignatureForSelector:propSel];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setSelector:propSel];
                    [inv setTarget:chat];
                    NSString *propName = @"GroupName";
                    [inv setArgument:&name atIndex:2];
                    [inv setArgument:&propName atIndex:3];
                    [inv invoke];
                }
            }
        }

        // Optionally send first message
        if (text && [text length] > 0) {
            Class IMMessageClass = NSClassFromString(@"IMMessage");
            if (IMMessageClass) {
                NSAttributedString *attrText = [[NSAttributedString alloc] initWithString:text];
                SEL initSel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:);
                if ([IMMessageClass instancesRespondToSelector:initSel]) {
                    typedef id (*InitType)(id, SEL, id, id, id, id, id, unsigned long long, id, id, id);
                    InitType initFunc = (InitType)objc_msgSend;
                    id msg = [IMMessageClass alloc];
                    msg = initFunc(msg, initSel, nil, nil, attrText, nil, nil, 0x5, nil, nil, nil);
                    if (msg) {
                        SEL sendSel = @selector(sendMessage:);
                        if ([chat respondsToSelector:sendSel]) {
                            [chat performSelector:sendSel withObject:msg];
                            NSLog(@"[imsg-plus] Sent initial message to new chat");
                        }
                    }
                }
            }
        }

        // Build response
        NSString *chatGuid = @"";
        if ([chat respondsToSelector:@selector(guid)]) {
            chatGuid = [chat performSelector:@selector(guid)] ?: @"";
        }
        NSString *chatIdentifier = @"";
        if ([chat respondsToSelector:@selector(chatIdentifier)]) {
            chatIdentifier = [chat performSelector:@selector(chatIdentifier)] ?: @"";
        }
        NSMutableArray *participantIDs = [NSMutableArray array];
        if ([chat respondsToSelector:@selector(participants)]) {
            NSArray *participants = [chat performSelector:@selector(participants)];
            for (id handle in participants) {
                if ([handle respondsToSelector:@selector(ID)]) {
                    [participantIDs addObject:[handle performSelector:@selector(ID)] ?: @""];
                }
            }
        }

        return successResponse(requestId, @{
            @"guid": chatGuid,
            @"identifier": chatIdentifier,
            @"participants": participantIDs,
            @"name": name ?: @""
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to create chat: %@", exception.reason]);
    }
}

static NSDictionary* handleRenameChat(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *name = params[@"name"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }
    if (!name) {
        return errorResponse(requestId, @"Missing required parameter: name");
    }

    id chat = findChat(handle);
    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        SEL setNameSel = @selector(_setDisplayName:);
        if ([chat respondsToSelector:setNameSel]) {
            [chat performSelector:setNameSel withObject:name];
            NSLog(@"[imsg-plus] Renamed chat %@ to: %@", handle, name);
        } else {
            // Fallback: try setValue:forChatProperty:
            SEL propSel = @selector(setValue:forChatProperty:);
            if ([chat respondsToSelector:propSel]) {
                NSMethodSignature *sig = [chat methodSignatureForSelector:propSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:propSel];
                [inv setTarget:chat];
                NSString *propName = @"GroupName";
                [inv setArgument:&name atIndex:2];
                [inv setArgument:&propName atIndex:3];
                [inv invoke];
            } else {
                return errorResponse(requestId, @"_setDisplayName: and setValue:forChatProperty: not available");
            }
        }

        return successResponse(requestId, @{
            @"handle": handle,
            @"name": name
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to rename chat: %@", exception.reason]);
    }
}

static NSDictionary* handleRemoveParticipant(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSArray *addresses = params[@"addresses"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }
    if (!addresses || ![addresses isKindOfClass:[NSArray class]] || addresses.count == 0) {
        return errorResponse(requestId, @"Missing required parameter: addresses");
    }

    id chat = findChat(handle);
    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        // Get account to resolve addresses to IMHandles
        Class serviceClass = NSClassFromString(@"IMServiceImpl");
        Class accountControllerClass = NSClassFromString(@"IMAccountController");
        if (!serviceClass || !accountControllerClass) {
            return errorResponse(requestId, @"IMServiceImpl or IMAccountController not found");
        }

        id service = [serviceClass performSelector:@selector(iMessageService)];
        id accountController = [accountControllerClass performSelector:@selector(sharedInstance)];
        id account = [accountController performSelector:@selector(bestAccountForService:) withObject:service];

        if (!account) {
            return errorResponse(requestId, @"Could not get account");
        }

        NSMutableArray *handles = [NSMutableArray array];
        for (NSString *address in addresses) {
            id imHandle = [account performSelector:@selector(imHandleWithID:) withObject:address];
            if (imHandle) {
                [handles addObject:imHandle];
            }
        }

        if (handles.count == 0) {
            return errorResponse(requestId, @"Could not resolve any handles");
        }

        SEL removeSel = @selector(removeParticipants:reason:);
        if ([chat respondsToSelector:removeSel]) {
            NSMethodSignature *sig = [chat methodSignatureForSelector:removeSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:removeSel];
            [inv setTarget:chat];
            [inv setArgument:&handles atIndex:2];
            NSString *reason = @"";
            [inv setArgument:&reason atIndex:3];
            [inv invoke];
            NSLog(@"[imsg-plus] Removed %lu participants from %@", (unsigned long)handles.count, handle);
        } else {
            // Fallback: try removeIMHandles:
            SEL altSel = @selector(removeIMHandles:);
            if ([chat respondsToSelector:altSel]) {
                [chat performSelector:altSel withObject:handles];
            } else {
                return errorResponse(requestId, @"removeParticipants: and removeIMHandles: not available");
            }
        }

        return successResponse(requestId, @{
            @"handle": handle,
            @"removed": @(handles.count)
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to remove participants: %@", exception.reason]);
    }
}

static id createIMMessage(Class IMMessageClass, NSAttributedString *text, NSArray *ftGUIDs, NSString *effect, NSString *thread) {
    NSString *guid = [[NSUUID UUID] UUIDString];
    id msg = nil;

    if (effect || thread) {
        SEL initSel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:threadIdentifier:);
        if ([IMMessageClass instancesRespondToSelector:initSel]) {
            typedef id (*InitType)(id, SEL, id, id, id, id, id, unsigned long long, id, id, id, id, id, id, id);
            InitType initFunc = (InitType)objc_msgSend;
            msg = [IMMessageClass alloc];
            msg = initFunc(msg, initSel,
                nil, [NSDate date], text, nil, ftGUIDs,
                (unsigned long long)0x100005, nil, guid, nil,
                nil, nil, effect, thread);
            NSLog(@"[imsg-plus] createIMMessage: long init effect=%@ thread=%@", effect ?: @"nil", thread ?: @"nil");
        }
    }

    if (!msg && thread) {
        SEL initSel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:threadIdentifier:);
        if ([IMMessageClass instancesRespondToSelector:initSel]) {
            typedef id (*InitType)(id, SEL, id, id, id, id, id, unsigned long long, id, id, id, id);
            InitType initFunc = (InitType)objc_msgSend;
            msg = [IMMessageClass alloc];
            msg = initFunc(msg, initSel,
                nil, [NSDate date], text, nil, ftGUIDs,
                (unsigned long long)0x100005, nil, guid, nil, thread);
        }
    }

    if (!msg) {
        SEL initSel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:);
        if ([IMMessageClass instancesRespondToSelector:initSel]) {
            typedef id (*InitType)(id, SEL, id, id, id, id, id, unsigned long long, id, id, id);
            InitType initFunc = (InitType)objc_msgSend;
            msg = [IMMessageClass alloc];
            msg = initFunc(msg, initSel,
                nil, [NSDate date], text, nil, ftGUIDs,
                (unsigned long long)0x100005, nil, guid, nil);
        }
    }
    return msg;
}

static void sendViaIMChat(id msg, id chat) {
    SEL sendSel = @selector(sendMessage:);
    if ([chat respondsToSelector:sendSel]) {
        [chat performSelector:sendSel withObject:msg];
    }
}

static void sendViaCKConversation(id msg, id chat, NSString *replyToGuid) {
    id ckConversation = nil;
    @try { ckConversation = [chat valueForKey:@"conversation"]; } @catch (NSException *e) { }
    if (!ckConversation) {
        @try {
            Class ckListClass = NSClassFromString(@"CKConversationList");
            if (ckListClass) {
                id ckList = [ckListClass performSelector:@selector(sharedConversationList)];
                if (ckList) {
                    SEL s1 = @selector(conversationForExistingChat:);
                    if ([ckList respondsToSelector:s1])
                        ckConversation = [ckList performSelector:s1 withObject:chat];
                    if (!ckConversation) {
                        SEL s2 = @selector(conversationForChat:);
                        if ([ckList respondsToSelector:s2])
                            ckConversation = [ckList performSelector:s2 withObject:chat];
                    }
                }
            }
        } @catch (NSException *e) { }
    }
    SEL ckSendSel = @selector(sendMessage:newComposition:);
    if (ckConversation && [ckConversation respondsToSelector:ckSendSel]) {
        typedef void (*CKSendType)(id, SEL, id, id);
        ((CKSendType)objc_msgSend)(ckConversation, ckSendSel, msg, nil);
        return;
    }
    // Fallback to IMChat
    sendViaIMChat(msg, chat);
}

static NSDictionary* handleSendRichMessage(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *attributedTextBase64 = params[@"attributed_text"];
    NSString *plainText = params[@"text"];
    NSString *filePath = params[@"file"];
    NSString *replyToGuid = params[@"reply_to_guid"];
    NSString *effectId = params[@"effect_id"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }
    if (!attributedTextBase64 && !plainText && !filePath) {
        return errorResponse(requestId, @"Missing required parameter: attributed_text, text, or file");
    }

    id chat = findChat(handle);
    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        Class IMMessageClass = NSClassFromString(@"IMMessage");
        if (!IMMessageClass) {
            return errorResponse(requestId, @"IMMessage class not found");
        }

        // Build message text from attributed_text or plain text
        NSAttributedString *messageText = nil;
        if (attributedTextBase64) {
            NSData *data = [[NSData alloc] initWithBase64EncodedString:attributedTextBase64 options:0];
            if (data) {
                @try {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    id unarchived = [NSUnarchiver unarchiveObjectWithData:data];
                    #pragma clang diagnostic pop
                    if ([unarchived isKindOfClass:[NSAttributedString class]]) {
                        messageText = (NSAttributedString *)unarchived;
                    }
                } @catch (NSException *e) {
                    NSLog(@"[imsg-plus] Failed to unarchive attributed text: %@", e.reason);
                }
            }
        }
        if (!messageText && plainText && plainText.length > 0) {
            messageText = [[NSAttributedString alloc] initWithString:plainText];
        }

        BOOL hasFile = (filePath && filePath.length > 0);
        BOOL hasText = (messageText != nil && messageText.length > 0);
        NSString *threadId = replyToGuid ? [NSString stringWithFormat:@"r:0:0:0:%@", replyToGuid] : nil;

        if (hasFile) {
            // --- ATTACHMENT (with optional text, effect, reply) ---
            NSString *chatGUID = @"";
            if ([chat respondsToSelector:@selector(guid)]) {
                chatGUID = [chat performSelector:@selector(guid)] ?: @"";
            }
            NSString *transferGUID = prepareAttachment(filePath, chatGUID);
            if (!transferGUID) {
                NSString *diag = _attachmentDiag ?: @"unknown reason";
                return errorResponse(requestId, [NSString stringWithFormat:@"Failed to prepare attachment: %@ (%@)", filePath, diag]);
            }

            // Build attachment attributed string with \uFFFC placeholder
            NSArray *ftGUIDs = @[transferGUID];
            unichar replacementChar = 0xFFFC;
            NSString *replacementStr = [NSString stringWithCharacters:&replacementChar length:1];
            NSDictionary *attachAttrs = @{
                @"__kIMFileTransferGUIDAttributeName": transferGUID,
                @"__kIMFilenameAttributeName": [filePath lastPathComponent],
                @"__kIMMessagePartAttributeName": @0,
            };
            NSAttributedString *attachText = [[NSAttributedString alloc]
                initWithString:replacementStr attributes:attachAttrs];

            NSAttributedString *finalText = attachText;
            if (hasText) {
                // Combined: text (part 0) + attachment (part 1)
                NSMutableAttributedString *combined = [[NSMutableAttributedString alloc]
                    initWithAttributedString:messageText];
                [combined addAttribute:@"__kIMMessagePartAttributeName"
                    value:@0 range:NSMakeRange(0, combined.length)];
                NSMutableDictionary *partAttrs = [attachAttrs mutableCopy];
                partAttrs[@"__kIMMessagePartAttributeName"] = @1;
                NSAttributedString *attachPart = [[NSAttributedString alloc]
                    initWithString:replacementStr attributes:partAttrs];
                [combined appendAttributedString:attachPart];
                finalText = combined;
            }

            id msg = createIMMessage(IMMessageClass, finalText, ftGUIDs, effectId, threadId);
            if (!msg) return errorResponse(requestId, @"Failed to create IMMessage");

            // Always use CKConversation for attachment sends (matches native UI behavior)
            sendViaCKConversation(msg, chat, replyToGuid);

        } else {
            // --- TEXT ONLY (with optional effect/reply) ---
            if (!messageText) return errorResponse(requestId, @"Could not construct message text");
            id msg = createIMMessage(IMMessageClass, messageText, nil, effectId, threadId);
            if (!msg) return errorResponse(requestId, @"Failed to create IMMessage");
            if (replyToGuid) {
                sendViaCKConversation(msg, chat, replyToGuid);
            } else {
                sendViaIMChat(msg, chat);
            }
        }

        return successResponse(requestId, @{
            @"handle": handle,
            @"sent": @YES
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to send message: %@", exception.reason]);
    }
}

#pragma mark - Edit and Unsend

static NSDictionary* handleEditMessage(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *messageGUID = params[@"guid"];
    NSString *newText = params[@"text"];
    NSString *attributedTextBase64 = params[@"attributed_text"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }
    if (!messageGUID) {
        return errorResponse(requestId, @"Missing required parameter: guid");
    }
    if (!newText && !attributedTextBase64) {
        return errorResponse(requestId, @"Missing required parameter: text or attributed_text");
    }

    id chat = findChat(handle);
    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    // Load message via IMChatHistoryController (async)
    Class historyClass = NSClassFromString(@"IMChatHistoryController");
    if (!historyClass) {
        return errorResponse(requestId, @"IMChatHistoryController class not found");
    }

    id historyController = [historyClass performSelector:@selector(sharedInstance)];
    if (!historyController) {
        return errorResponse(requestId, @"Could not get IMChatHistoryController instance");
    }

    SEL loadSel = @selector(loadMessageWithGUID:completionBlock:);
    if (![historyController respondsToSelector:loadSel]) {
        return errorResponse(requestId, @"loadMessageWithGUID:completionBlock: not available");
    }

    NSLog(@"[imsg-plus] Loading message %@ for edit...", messageGUID);

    NSMethodSignature *loadSig = [historyController methodSignatureForSelector:loadSel];
    if (!loadSig) {
        return errorResponse(requestId, @"Could not get method signature for loadMessageWithGUID:completionBlock:");
    }
    NSInvocation *loadInv = [NSInvocation invocationWithMethodSignature:loadSig];
    [loadInv setSelector:loadSel];
    [loadInv setTarget:historyController];
    [loadInv setArgument:&messageGUID atIndex:2];

    void (^completionBlock)(id) = ^(id message) {
        @autoreleasepool {
            NSLog(@"[imsg-plus] edit: loadMessageWithGUID completion fired, message=%@", message);

            if (!message) {
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Message not found for GUID: %@", messageGUID]));
                return;
            }

            @try {
                // Build the new attributed string
                NSAttributedString *newAttrText = nil;
                if (attributedTextBase64) {
                    NSData *data = [[NSData alloc] initWithBase64EncodedString:attributedTextBase64 options:0];
                    if (data) {
                        @try {
                            #pragma clang diagnostic push
                            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                            id unarchived = [NSUnarchiver unarchiveObjectWithData:data];
                            #pragma clang diagnostic pop
                            if ([unarchived isKindOfClass:[NSAttributedString class]]) {
                                newAttrText = (NSAttributedString *)unarchived;
                            }
                        } @catch (NSException *e) {
                            NSLog(@"[imsg-plus] Failed to unarchive attributed text for edit: %@", e.reason);
                        }
                    }
                }
                if (!newAttrText && newText) {
                    newAttrText = [[NSAttributedString alloc] initWithString:newText];
                }
                if (!newAttrText) {
                    writeResponseToFile(errorResponse(requestId, @"Could not construct edit text"));
                    return;
                }

                // Get the IMMessageItem from the IMMessage
                id messageItem = nil;
                @try {
                    messageItem = [message valueForKey:@"_imMessageItem"];
                } @catch (NSException *e) {
                    NSLog(@"[imsg-plus] Could not get _imMessageItem: %@", e.reason);
                }
                if (!messageItem) {
                    writeResponseToFile(errorResponse(requestId, @"Could not get IMMessageItem from message"));
                    return;
                }
                NSLog(@"[imsg-plus] Got IMMessageItem: %@ (class: %@)", messageItem, [messageItem class]);

                // Build backward-compat plain text
                NSAttributedString *backwardText = [[NSAttributedString alloc] initWithString:newAttrText.string];

                // Try edit selectors in priority order
                BOOL edited = NO;
                NSString *methodUsed = nil;

                // 1. editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:
                SEL sel1 = @selector(editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:);
                if (!edited && [chat respondsToSelector:sel1]) {
                    NSLog(@"[imsg-plus] Trying editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:");
                    typedef void (*EditType)(id, SEL, id, NSInteger, id, id);
                    EditType editFunc = (EditType)[chat methodForSelector:sel1];
                    editFunc(chat, sel1, messageItem, 0, newAttrText, backwardText);
                    edited = YES;
                    methodUsed = @"editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:";
                }

                // 2. editMessage:atPartIndex:withAttributedString: (fallback)
                SEL sel2 = @selector(editMessage:atPartIndex:withAttributedString:);
                if (!edited && [chat respondsToSelector:sel2]) {
                    NSLog(@"[imsg-plus] Trying editMessage:atPartIndex:withAttributedString:");
                    typedef void (*EditType)(id, SEL, id, NSInteger, id);
                    EditType editFunc = (EditType)[chat methodForSelector:sel2];
                    editFunc(chat, sel2, message, 0, newAttrText);
                    edited = YES;
                    methodUsed = @"editMessage:atPartIndex:withAttributedString:";
                }

                if (!edited) {
                    // Dump available edit methods for discovery
                    unsigned int methodCount = 0;
                    Method *methods = class_copyMethodList([chat class], &methodCount);
                    NSMutableArray *editMethods = [NSMutableArray array];
                    for (unsigned int i = 0; i < methodCount; i++) {
                        NSString *name = NSStringFromSelector(method_getName(methods[i]));
                        if ([name.lowercaseString containsString:@"edit"]) {
                            [editMethods addObject:name];
                        }
                    }
                    free(methods);
                    NSLog(@"[imsg-plus] Available edit methods on IMChat: %@", editMethods);
                    writeResponseToFile(errorResponse(requestId,
                        [NSString stringWithFormat:@"No known edit selector found. Available: %@", editMethods]));
                    return;
                }

                NSLog(@"[imsg-plus] ✅ Edited message %@ via %@", messageGUID, methodUsed);
                writeResponseToFile(successResponse(requestId, @{
                    @"handle": handle,
                    @"guid": messageGUID,
                    @"method": methodUsed
                }));
            } @catch (NSException *exception) {
                NSLog(@"[imsg-plus] ❌ Exception in edit completion: %@", exception.reason);
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Failed to edit message: %@", exception.reason]));
            }
        }
    };

    [loadInv setArgument:&completionBlock atIndex:3];
    [loadInv invoke];

    // 5-second timeout
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSData *responseData = [NSData dataWithContentsOfFile:kResponseFile];
        if (!responseData || responseData.length < 3) {
            NSLog(@"[imsg-plus] ⚠️ Edit completion timeout after 5s for GUID: %@", messageGUID);
            writeResponseToFile(errorResponse(requestId,
                [NSString stringWithFormat:@"Timeout: edit completion never fired for: %@", messageGUID]));
        }
    });

    return nil;
}

static NSDictionary* handleUnsendMessage(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *messageGUID = params[@"guid"];
    NSNumber *partIndexNum = params[@"part_index"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }
    if (!messageGUID) {
        return errorResponse(requestId, @"Missing required parameter: guid");
    }

    id chat = findChat(handle);
    if (!chat) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    // Load message via IMChatHistoryController (async)
    Class historyClass = NSClassFromString(@"IMChatHistoryController");
    if (!historyClass) {
        return errorResponse(requestId, @"IMChatHistoryController class not found");
    }

    id historyController = [historyClass performSelector:@selector(sharedInstance)];
    if (!historyController) {
        return errorResponse(requestId, @"Could not get IMChatHistoryController instance");
    }

    SEL loadSel = @selector(loadMessageWithGUID:completionBlock:);
    if (![historyController respondsToSelector:loadSel]) {
        return errorResponse(requestId, @"loadMessageWithGUID:completionBlock: not available");
    }

    NSLog(@"[imsg-plus] Loading message %@ for unsend...", messageGUID);

    NSMethodSignature *loadSig = [historyController methodSignatureForSelector:loadSel];
    if (!loadSig) {
        return errorResponse(requestId, @"Could not get method signature for loadMessageWithGUID:completionBlock:");
    }
    NSInvocation *loadInv = [NSInvocation invocationWithMethodSignature:loadSig];
    [loadInv setSelector:loadSel];
    [loadInv setTarget:historyController];
    [loadInv setArgument:&messageGUID atIndex:2];

    void (^completionBlock)(id) = ^(id message) {
        @autoreleasepool {
            NSLog(@"[imsg-plus] unsend: loadMessageWithGUID completion fired, message=%@", message);

            if (!message) {
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Message not found for GUID: %@", messageGUID]));
                return;
            }

            @try {
                // Get IMMessageItem and then chat items (same pattern as react handler)
                id messageItem = nil;
                @try {
                    messageItem = [message valueForKey:@"_imMessageItem"];
                } @catch (NSException *e) {
                    NSLog(@"[imsg-plus] Could not get _imMessageItem: %@", e.reason);
                }

                // Get chat items to find the part to retract
                id partItem = nil;
                if (messageItem) {
                    id items = nil;
                    if ([messageItem respondsToSelector:@selector(_newChatItems)]) {
                        items = [messageItem performSelector:@selector(_newChatItems)];
                    } else {
                        @try { items = [messageItem valueForKey:@"_newChatItems"]; }
                        @catch (NSException *e) {}
                    }

                    if ([items isKindOfClass:[NSArray class]]) {
                        NSArray *itemArray = (NSArray *)items;
                        NSLog(@"[imsg-plus] Got %lu chat items from message", (unsigned long)itemArray.count);
                        for (id item in itemArray) {
                            NSString *className = NSStringFromClass([item class]);
                            if ([className containsString:@"MessagePartChatItem"] ||
                                [className containsString:@"TextMessagePartChatItem"]) {
                                if ([item respondsToSelector:@selector(index)]) {
                                    NSInteger idx = ((NSInteger (*)(id, SEL))objc_msgSend)(item, @selector(index));
                                    if (idx == partIndex) {
                                        partItem = item;
                                        break;
                                    }
                                } else if (partIndex == 0) {
                                    partItem = item;
                                    break;
                                }
                            }
                        }
                        if (!partItem && itemArray.count > 0) {
                            partItem = itemArray[partIndex < (int)itemArray.count ? partIndex : 0];
                        }
                    } else if (items) {
                        partItem = items;
                    }
                }

                NSLog(@"[imsg-plus] partItem for unsend: %@ (class: %@)",
                      partItem, partItem ? [partItem class] : @"nil");

                BOOL unsent = NO;
                NSString *methodUsed = nil;

                // 1. retractMessagePart: (takes a chat item / message part)
                SEL sel1 = @selector(retractMessagePart:);
                if (!unsent && partItem && [chat respondsToSelector:sel1]) {
                    NSLog(@"[imsg-plus] Trying retractMessagePart: with partItem");
                    [chat performSelector:sel1 withObject:partItem];
                    unsent = YES;
                    methodUsed = @"retractMessagePart:";
                }

                // 2. retractMessage:atPartIndex: (fallback)
                SEL sel2 = @selector(retractMessage:atPartIndex:);
                if (!unsent && [chat respondsToSelector:sel2]) {
                    NSLog(@"[imsg-plus] Trying retractMessage:atPartIndex:");
                    typedef void (*UnsendType)(id, SEL, id, NSInteger);
                    UnsendType unsendFunc = (UnsendType)[chat methodForSelector:sel2];
                    unsendFunc(chat, sel2, message, partIndex);
                    unsent = YES;
                    methodUsed = @"retractMessage:atPartIndex:";
                }

                // 3. _unsendMessage:atPartIndex: (fallback)
                SEL sel3 = @selector(_unsendMessage:atPartIndex:);
                if (!unsent && [chat respondsToSelector:sel3]) {
                    NSLog(@"[imsg-plus] Trying _unsendMessage:atPartIndex:");
                    typedef void (*UnsendType)(id, SEL, id, NSInteger);
                    UnsendType unsendFunc = (UnsendType)[chat methodForSelector:sel3];
                    unsendFunc(chat, sel3, message, partIndex);
                    unsent = YES;
                    methodUsed = @"_unsendMessage:atPartIndex:";
                }

                if (!unsent) {
                    unsigned int methodCount = 0;
                    Method *methods = class_copyMethodList([chat class], &methodCount);
                    NSMutableArray *unsendMethods = [NSMutableArray array];
                    for (unsigned int i = 0; i < methodCount; i++) {
                        NSString *name = NSStringFromSelector(method_getName(methods[i]));
                        NSString *lower = name.lowercaseString;
                        if ([lower containsString:@"retract"] || [lower containsString:@"unsend"]) {
                            [unsendMethods addObject:name];
                        }
                    }
                    free(methods);
                    NSLog(@"[imsg-plus] Available unsend/retract methods on IMChat: %@", unsendMethods);
                    writeResponseToFile(errorResponse(requestId,
                        [NSString stringWithFormat:@"No known unsend selector found. Available: %@", unsendMethods]));
                    return;
                }

                NSLog(@"[imsg-plus] ✅ Unsent message %@ via %@", messageGUID, methodUsed);
                writeResponseToFile(successResponse(requestId, @{
                    @"handle": handle,
                    @"guid": messageGUID,
                    @"part_index": @(partIndex),
                    @"method": methodUsed
                }));
            } @catch (NSException *exception) {
                NSLog(@"[imsg-plus] ❌ Exception in unsend completion: %@", exception.reason);
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Failed to unsend message: %@", exception.reason]));
            }
        }
    };

    [loadInv setArgument:&completionBlock atIndex:3];
    [loadInv invoke];

    // 5-second timeout
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSData *responseData = [NSData dataWithContentsOfFile:kResponseFile];
        if (!responseData || responseData.length < 3) {
            NSLog(@"[imsg-plus] ⚠️ Unsend completion timeout after 5s for GUID: %@", messageGUID);
            writeResponseToFile(errorResponse(requestId,
                [NSString stringWithFormat:@"Timeout: unsend completion never fired for: %@", messageGUID]));
        }
    });

    return nil;
}

#pragma mark - Location (Find My / FMFSession)

static id valueForKeySafely(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (NSException *exception) {
        return nil;
    }
}

static id objectByPerformingSelector(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || !selector || ![target respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static id objectByPerformingSelectorWithObject(id target, NSString *selectorName, id arg) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || !selector || ![target respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, arg);
}

static id objectByPerformingSelectorWithObjectAndBool(id target, NSString *selectorName, id arg, BOOL flag) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || !selector || ![target respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL, id, BOOL))objc_msgSend)(target, selector, arg, flag);
}

static BOOL boolByPerformingSelectorWithObjectAndBool(id target, NSString *selectorName, id arg, BOOL flag, BOOL *didRespond) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || !selector || ![target respondsToSelector:selector]) {
        if (didRespond) *didRespond = NO;
        return NO;
    }
    if (didRespond) *didRespond = YES;
    return ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(target, selector, arg, flag);
}

static BOOL boolByPerformingSelector(id target, NSString *selectorName, BOOL *didRespond) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || !selector || ![target respondsToSelector:selector]) {
        if (didRespond) *didRespond = NO;
        return NO;
    }
    if (didRespond) *didRespond = YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
}

static NSArray* objectsFromCollection(id collection) {
    if (!collection || collection == [NSNull null]) return @[];
    if ([collection isKindOfClass:[NSArray class]]) return collection;
    if ([collection isKindOfClass:[NSSet class]]) return [(NSSet *)collection allObjects];
    return @[collection];
}

static NSString* firstNonEmptyStringForKeys(id obj, NSArray *keys) {
    for (NSString *key in keys) {
        id value = valueForKeySafely(obj, key);
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            return value;
        }
    }
    return nil;
}

static NSNumber* firstNumberForKeys(id obj, NSArray *keys) {
    for (NSString *key in keys) {
        id value = valueForKeySafely(obj, key);
        if ([value respondsToSelector:@selector(doubleValue)]) {
            return @([value doubleValue]);
        }
    }
    return nil;
}

static NSNumber* firstBoolForKeys(id obj, NSArray *keys) {
    for (NSString *key in keys) {
        id value = valueForKeySafely(obj, key);
        if ([value respondsToSelector:@selector(boolValue)]) {
            return @([value boolValue]);
        }
    }
    return nil;
}

static NSArray* stringArrayFromCollection(id collection) {
    NSArray *objects = objectsFromCollection(collection);
    NSMutableArray *strings = [NSMutableArray array];
    for (id object in objects) {
        if ([object isKindOfClass:[NSString class]] && [(NSString *)object length] > 0) {
            [strings addObject:object];
        }
    }
    return strings;
}

static NSString* iso8601StringFromDateValue(id value) {
    if (!value || value == [NSNull null]) return nil;
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }

    NSDate *date = nil;
    if ([value isKindOfClass:[NSDate class]]) {
        date = value;
    } else if ([value respondsToSelector:@selector(doubleValue)]) {
        double timestamp = [value doubleValue];
        if (timestamp > 1000000000000.0) {
            timestamp /= 1000.0;
        }
        date = [NSDate dateWithTimeIntervalSince1970:timestamp];
    }

    if (!date) return nil;

    static NSISO8601DateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSISO8601DateFormatter new];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return [formatter stringFromDate:date];
}

static NSString* handleStringFromObject(id handleObj) {
    if ([handleObj isKindOfClass:[NSString class]] && [(NSString *)handleObj length] > 0) {
        return handleObj;
    }

    NSString *candidate = firstNonEmptyStringForKeys(handleObj, @[
        @"ID", @"identifier", @"handle", @"address", @"value", @"formattedID", @"destination"
    ]);
    if (candidate.length > 0) {
        return candidate;
    }

    if (handleObj) {
        NSString *description = [handleObj description];
        if (description.length > 0 && ![description hasPrefix:@"<"]) {
            return description;
        }
    }

    return nil;
}

static NSArray* summarizedHandlesFromObjects(NSArray *objects) {
    NSMutableArray *summaries = [NSMutableArray array];
    for (id object in objects) {
        NSString *handle = handleStringFromObject(object);
        if (handle.length > 0) {
            [summaries addObject:handle];
        } else {
            NSString *summary = [NSString stringWithFormat:@"%@ :: %@",
                                 NSStringFromClass([object class]),
                                 [object description] ?: @""];
            [summaries addObject:summary];
        }
        if ([summaries count] >= 25) break;
    }
    return summaries;
}

static id newObjectOfClassNamed(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return nil;

    SEL newSel = NSSelectorFromString(@"new");
    if ([cls respondsToSelector:newSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(cls, newSel);
    }

    SEL allocSel = NSSelectorFromString(@"alloc");
    SEL initSel = NSSelectorFromString(@"init");
    if ([cls respondsToSelector:allocSel]) {
        id object = ((id (*)(id, SEL))objc_msgSend)(cls, allocSel);
        if (object && [object respondsToSelector:initSel]) {
            return ((id (*)(id, SEL))objc_msgSend)(object, initSel);
        }
        return object;
    }

    return nil;
}

static CLLocation* extractCLLocation(id locationObj) {
    if ([locationObj isKindOfClass:[CLLocation class]]) {
        return locationObj;
    }

    for (NSString *key in @[@"location", @"clLocation", @"coreLocation", @"currentLocation"]) {
        id nested = valueForKeySafely(locationObj, key);
        if ([nested isKindOfClass:[CLLocation class]]) {
            return nested;
        }
    }

    return nil;
}

static id extractAddressObject(id locationObj) {
    for (NSString *key in @[@"address", @"formattedAddress", @"placemark", @"geocodedAddress", @"fmfAddress"]) {
        id nested = valueForKeySafely(locationObj, key);
        if (nested && nested != [NSNull null]) {
            return nested;
        }
    }
    return nil;
}

static NSArray* debugPropertyNamesForObject(id obj) {
    if (!obj) return @[];

    NSMutableSet *names = [NSMutableSet set];
    for (Class cls = [obj class]; cls != Nil && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        objc_property_t *properties = class_copyPropertyList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *propertyName = property_getName(properties[i]);
            if (propertyName) {
                [names addObject:[NSString stringWithUTF8String:propertyName]];
            }
        }
        free(properties);
    }

    return [[names allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

static id jsonSafeDebugValue(id value, NSInteger depth) {
    if (!value || value == [NSNull null]) {
        return [NSNull null];
    }

    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) {
        return value;
    }

    if ([value isKindOfClass:[NSDate class]]) {
        NSString *timestamp = iso8601StringFromDateValue(value);
        return timestamp ?: [value description];
    }

    if ([value isKindOfClass:[NSURL class]]) {
        return [(NSURL *)value absoluteString] ?: [value description];
    }

    if ([value isKindOfClass:[NSUUID class]]) {
        return [(NSUUID *)value UUIDString];
    }

    if ([value isKindOfClass:[NSData class]]) {
        return @{
            @"class": NSStringFromClass([value class]),
            @"length": @([(NSData *)value length]),
        };
    }

    if ([value isKindOfClass:[NSTimeZone class]]) {
        NSTimeZone *timeZone = value;
        return @{
            @"class": NSStringFromClass([value class]),
            @"name": timeZone.name ?: @"",
            @"abbreviation": timeZone.abbreviation ?: @"",
            @"seconds_from_gmt": @(timeZone.secondsFromGMT),
        };
    }

    if ([value isKindOfClass:[CLRegion class]]) {
        NSMutableDictionary *region = [@{
            @"class": NSStringFromClass([value class]),
            @"identifier": [(CLRegion *)value identifier] ?: @"",
        } mutableCopy];
        if ([value isKindOfClass:[CLCircularRegion class]]) {
            CLCircularRegion *circular = value;
            region[@"center_latitude"] = @(circular.center.latitude);
            region[@"center_longitude"] = @(circular.center.longitude);
            region[@"radius"] = @(circular.radius);
        }
        return region;
    }

    CLLocation *location = extractCLLocation(value);
    if (location) {
        NSMutableDictionary *payload = [@{
            @"class": NSStringFromClass([location class]),
            @"latitude": @(location.coordinate.latitude),
            @"longitude": @(location.coordinate.longitude),
            @"altitude": @(location.altitude),
            @"horizontal_accuracy": @(location.horizontalAccuracy),
            @"vertical_accuracy": @(location.verticalAccuracy),
            @"course": @(location.course),
            @"speed": @(location.speed),
        } mutableCopy];
        NSString *timestamp = iso8601StringFromDateValue(location.timestamp);
        if (timestamp) payload[@"timestamp"] = timestamp;
        return payload;
    }

    if ([value isKindOfClass:[NSDictionary class]]) {
        if (depth <= 0) {
            return @{
                @"class": NSStringFromClass([value class]),
                @"count": @([(NSDictionary *)value count]),
            };
        }

        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        NSArray *sortedKeys = [[(NSDictionary *)value allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [[a description] localizedCaseInsensitiveCompare:[b description]];
        }];
        NSUInteger limit = MIN([sortedKeys count], (NSUInteger)50);
        for (NSUInteger i = 0; i < limit; i++) {
            id key = sortedKeys[i];
            id nested = jsonSafeDebugValue([(NSDictionary *)value objectForKey:key], depth - 1);
            if (nested) {
                dict[[key description]] = nested;
            }
        }
        return dict;
    }

    if ([value isKindOfClass:[NSArray class]]) {
        if (depth <= 0) {
            return @{
                @"class": NSStringFromClass([value class]),
                @"count": @([(NSArray *)value count]),
            };
        }

        NSMutableArray *items = [NSMutableArray array];
        NSUInteger limit = MIN([(NSArray *)value count], (NSUInteger)50);
        for (NSUInteger i = 0; i < limit; i++) {
            id nested = jsonSafeDebugValue([(NSArray *)value objectAtIndex:i], depth - 1);
            if (nested) [items addObject:nested];
        }
        return items;
    }

    if ([value isKindOfClass:[NSSet class]]) {
        return jsonSafeDebugValue([(NSSet *)value allObjects], depth);
    }

    return @{
        @"class": NSStringFromClass([value class]),
        @"description": [value description] ?: @"",
    };
}

static NSDictionary* debugSnapshotForObject(id obj, NSArray *extraKeys) {
    if (!obj || obj == [NSNull null]) return nil;

    NSMutableSet *keys = [NSMutableSet setWithArray:debugPropertyNamesForObject(obj)];
    for (NSString *key in extraKeys) {
        if ([key isKindOfClass:[NSString class]] && key.length > 0) {
            [keys addObject:key];
        }
    }

    NSArray *sortedKeys = [[keys allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    for (NSString *key in sortedKeys) {
        id value = valueForKeySafely(obj, key);
        if (!value || value == [NSNull null]) continue;
        id safeValue = jsonSafeDebugValue(value, 2);
        if (safeValue) {
            fields[key] = safeValue;
        }
    }

    return @{
        @"class": NSStringFromClass([obj class]),
        @"description": [obj description] ?: @"",
        @"keys": sortedKeys,
        @"fields": fields,
    };
}

static NSDictionary* locationEntryForHandle(id handleObj, id locationObj, BOOL includeDebugRaw) {
    NSString *handle = handleStringFromObject(handleObj);
    if (handle.length == 0) {
        handle = handleStringFromObject(valueForKeySafely(locationObj, @"handle"));
    }
    if (handle.length == 0) {
        return nil;
    }

    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"handle"] = handle;

    if (!locationObj || locationObj == [NSNull null]) {
        return entry;
    }

    CLLocation *clLocation = extractCLLocation(locationObj);
    if (clLocation) {
        CLLocationCoordinate2D coordinate = clLocation.coordinate;
        if (CLLocationCoordinate2DIsValid(coordinate)) {
            entry[@"latitude"] = @(coordinate.latitude);
            entry[@"longitude"] = @(coordinate.longitude);
        }
        entry[@"altitude"] = @(clLocation.altitude);
        if (clLocation.horizontalAccuracy >= 0) {
            entry[@"horizontal_accuracy"] = @(clLocation.horizontalAccuracy);
        }
        if (clLocation.verticalAccuracy >= 0) {
            entry[@"vertical_accuracy"] = @(clLocation.verticalAccuracy);
        }
        NSString *timestamp = iso8601StringFromDateValue(clLocation.timestamp);
        if (timestamp) {
            entry[@"timestamp"] = timestamp;
        }
    }

    NSNumber *latitude = firstNumberForKeys(locationObj, @[@"latitude", @"lat"]);
    NSNumber *longitude = firstNumberForKeys(locationObj, @[@"longitude", @"lng", @"lon"]);
    NSNumber *altitude = firstNumberForKeys(locationObj, @[@"altitude"]);
    NSNumber *horizontalAccuracy = firstNumberForKeys(locationObj, @[@"horizontalAccuracy"]);
    NSNumber *verticalAccuracy = firstNumberForKeys(locationObj, @[@"verticalAccuracy"]);
    NSString *timestamp = iso8601StringFromDateValue(valueForKeySafely(locationObj, @"timestamp"));

    if (!entry[@"latitude"] && latitude) entry[@"latitude"] = latitude;
    if (!entry[@"longitude"] && longitude) entry[@"longitude"] = longitude;
    if (!entry[@"altitude"] && altitude) entry[@"altitude"] = altitude;
    if (!entry[@"horizontal_accuracy"] && horizontalAccuracy) entry[@"horizontal_accuracy"] = horizontalAccuracy;
    if (!entry[@"vertical_accuracy"] && verticalAccuracy) entry[@"vertical_accuracy"] = verticalAccuracy;
    if (!entry[@"timestamp"] && timestamp) entry[@"timestamp"] = timestamp;

    id addressObj = extractAddressObject(locationObj);
    NSString *address = firstNonEmptyStringForKeys(locationObj, @[@"formattedAddress", @"addressString", @"fullAddress"]);
    NSArray *formattedAddressLines = stringArrayFromCollection(valueForKeySafely(addressObj, @"formattedAddressLines"));
    if (!address && addressObj) {
        if ([formattedAddressLines count] > 0) {
            address = [formattedAddressLines componentsJoinedByString:@", "];
        }
    }
    if (!address) {
        address = firstNonEmptyStringForKeys(addressObj, @[@"formattedAddress", @"fullAddress", @"address"]);
    }
    if (address.length > 0) entry[@"address"] = address;
    if ([formattedAddressLines count] > 0) entry[@"formatted_address_lines"] = formattedAddressLines;

    NSString *street = firstNonEmptyStringForKeys(addressObj, @[@"street", @"streetAddress", @"thoroughfare"]);
    NSString *locality = firstNonEmptyStringForKeys(addressObj, @[@"locality", @"city"]);
    NSString *state = firstNonEmptyStringForKeys(addressObj, @[@"state", @"stateCode", @"administrativeArea"]);
    NSString *country = firstNonEmptyStringForKeys(addressObj, @[@"country", @"countryName"]);
    NSString *label = firstNonEmptyStringForKeys(locationObj, @[@"label", @"locationLabel"]);
    NSArray *labels = stringArrayFromCollection(valueForKeySafely(locationObj, @"labels"));
    NSString *firstName = firstNonEmptyStringForKeys(locationObj, @[@"firstName", @"givenName"]);
    NSString *lastName = firstNonEmptyStringForKeys(locationObj, @[@"lastName", @"familyName"]);

    if (street.length > 0) entry[@"street"] = street;
    if (locality.length > 0) entry[@"locality"] = locality;
    if (state.length > 0) entry[@"state"] = state;
    if (country.length > 0) entry[@"country"] = country;
    if (label.length > 0) entry[@"label"] = label;
    if ([labels count] > 0) entry[@"labels"] = labels;
    if (firstName.length > 0) entry[@"first_name"] = firstName;
    if (lastName.length > 0) entry[@"last_name"] = lastName;

    NSNumber *isOld = firstBoolForKeys(locationObj, @[@"isOld", @"old"]);
    NSNumber *isInaccurate = firstBoolForKeys(locationObj, @[@"isInaccurate", @"inaccurate"]);
    if (isOld) entry[@"is_old"] = isOld;
    if (isInaccurate) entry[@"is_inaccurate"] = isInaccurate;

    if (includeDebugRaw) {
        NSDictionary *rawLocation = debugSnapshotForObject(locationObj, @[
            @"name", @"label", @"locationLabel", @"firstName", @"lastName",
            @"formattedAddress", @"addressString", @"fullAddress",
            @"address", @"placemark", @"geocodedAddress", @"fmfAddress",
            @"location", @"clLocation", @"coreLocation", @"currentLocation",
            @"latitude", @"longitude", @"lat", @"lng", @"lon",
            @"altitude", @"horizontalAccuracy", @"verticalAccuracy",
            @"timestamp", @"isOld", @"old", @"isInaccurate", @"inaccurate"
        ]);
        NSDictionary *rawAddress = debugSnapshotForObject(addressObj, @[
            @"name", @"formattedAddress", @"formattedAddressLines",
            @"address", @"addressDictionary", @"postalAddress",
            @"street", @"streetAddress", @"thoroughfare", @"subThoroughfare",
            @"locality", @"subLocality", @"city",
            @"administrativeArea", @"subAdministrativeArea",
            @"state", @"stateCode", @"postalCode",
            @"country", @"countryName", @"ISOcountryCode", @"isoCountryCode",
            @"areasOfInterest", @"inlandWater", @"ocean",
            @"timeZone", @"region", @"location"
        ]);
        id rawCLLocation = jsonSafeDebugValue(clLocation ?: extractCLLocation(locationObj), 2);
        if (rawLocation) entry[@"raw_location"] = rawLocation;
        if (rawAddress) entry[@"raw_address"] = rawAddress;
        if (rawCLLocation && rawCLLocation != [NSNull null]) entry[@"raw_cllocation"] = rawCLLocation;
    }

    return entry;
}

static NSArray* collectLocationEntriesFromFindMyLocateTarget(id target,
                                                             NSString *label,
                                                             NSString *filterHandle,
                                                             NSArray *friendObjects,
                                                             NSArray *locationSelectorsWithAddress,
                                                             NSArray *locationSelectors,
                                                             BOOL includeDebugRaw,
                                                             NSMutableSet *seenHandles,
                                                             NSMutableArray *diagLog) {
    NSMutableArray *results = [NSMutableArray array];
    NSMutableArray *candidateObjects = [NSMutableArray array];
    NSMutableSet *candidateKeys = [NSMutableSet set];

    if (filterHandle.length > 0) {
        [candidateObjects addObject:filterHandle];
        [candidateKeys addObject:filterHandle];
    }

    NSInteger anonymousIndex = 0;
    for (id friendObj in friendObjects) {
        NSString *candidateKey = handleStringFromObject(friendObj);
        if (candidateKey.length == 0) {
            candidateKey = [NSString stringWithFormat:@"__anon_%@_%ld",
                            label, (long)anonymousIndex++];
        }
        if ([candidateKeys containsObject:candidateKey]) continue;
        [candidateKeys addObject:candidateKey];
        [candidateObjects addObject:friendObj];
    }

    for (id candidate in candidateObjects) {
        id locationObject = nil;
        NSString *usedLocationSelector = nil;
        id nestedHandleObject = valueForKeySafely(candidate, @"handle");

        for (NSString *selectorName in locationSelectorsWithAddress) {
            if (![target respondsToSelector:NSSelectorFromString(selectorName)]) continue;
            locationObject = objectByPerformingSelectorWithObjectAndBool(target, selectorName, candidate, YES);
            usedLocationSelector = selectorName;

            if (!locationObject && nestedHandleObject && nestedHandleObject != candidate) {
                locationObject = objectByPerformingSelectorWithObjectAndBool(target, selectorName, nestedHandleObject, YES);
            }

            NSString *candidateHandle = handleStringFromObject(candidate);
            if (!locationObject && candidateHandle.length > 0 && candidate != candidateHandle) {
                locationObject = objectByPerformingSelectorWithObjectAndBool(target, selectorName, candidateHandle, YES);
            }

            if (locationObject) break;
        }

        if (!locationObject) {
            for (NSString *selectorName in locationSelectors) {
                if (![target respondsToSelector:NSSelectorFromString(selectorName)]) continue;
                locationObject = objectByPerformingSelectorWithObject(target, selectorName, candidate);
                usedLocationSelector = selectorName;

                if (!locationObject && nestedHandleObject && nestedHandleObject != candidate) {
                    locationObject = objectByPerformingSelectorWithObject(target, selectorName, nestedHandleObject);
                }

                NSString *candidateHandle = handleStringFromObject(candidate);
                if (!locationObject && candidateHandle.length > 0 && candidate != candidateHandle) {
                    locationObject = objectByPerformingSelectorWithObject(target, selectorName, candidateHandle);
                }

                if (locationObject) break;
            }
        }

        NSString *candidateHandle = handleStringFromObject(candidate);
        NSString *candidateLabel = candidateHandle.length > 0 ? candidateHandle : NSStringFromClass([candidate class]);
        [diagLog addObject:[NSString stringWithFormat:@"%@ %@(%@) -> %@",
                            label,
                            usedLocationSelector ?: @"cachedLocation",
                            candidateLabel,
                            locationObject ? NSStringFromClass([locationObject class]) : @"nil"]];

        if (!locationObject) {
            continue;
        }

        NSDictionary *entry = locationEntryForHandle(candidate, locationObject, includeDebugRaw);
        NSString *entryHandle = [entry[@"handle"] isKindOfClass:[NSString class]] ? entry[@"handle"] : nil;
        if (!entry || entryHandle.length == 0) {
            continue;
        }

        if (seenHandles && [seenHandles containsObject:entryHandle]) {
            continue;
        }

        if (seenHandles) {
            [seenHandles addObject:entryHandle];
        }
        [results addObject:entry];
    }

    return results;
}

static NSArray* handleObjectsFromFindMyLocateObjects(NSArray *objects) {
    NSMutableArray *handleObjects = [NSMutableArray array];
    NSMutableSet *seenKeys = [NSMutableSet set];

    for (id object in objects) {
        id handleObject = valueForKeySafely(object, @"handle");
        id candidate = handleObject ?: object;
        NSString *dedupeKey = handleStringFromObject(candidate);
        if (dedupeKey.length == 0) {
            dedupeKey = [NSString stringWithFormat:@"%p", candidate];
        }
        if ([seenKeys containsObject:dedupeKey]) continue;
        [seenKeys addObject:dedupeKey];
        [handleObjects addObject:candidate];
    }

    return handleObjects;
}

static id newFMLHandleForIdentifier(NSString *identifier) {
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) {
        return nil;
    }

    Class handleClass = NSClassFromString(@"FMLHandle");
    SEL selector = NSSelectorFromString(@"handleWithIdentifier:");
    if (!handleClass || ![handleClass respondsToSelector:selector]) {
        return nil;
    }

    return ((id (*)(id, SEL, id))objc_msgSend)(handleClass, selector, identifier);
}

static void spinMainRunLoopForSeconds(NSTimeInterval seconds) {
    if (seconds <= 0) {
        return;
    }

    NSDate *untilDate = [NSDate dateWithTimeIntervalSinceNow:seconds];
    if ([NSThread isMainThread]) {
        [[NSRunLoop mainRunLoop] runUntilDate:untilDate];
        return;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSRunLoop mainRunLoop] runUntilDate:untilDate];
        dispatch_semaphore_signal(semaphore);
    });
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((seconds + 1.0) * NSEC_PER_SEC)));
}

// Poll explicit friend objects/handles after refresh because the cached friend arrays
// can remain empty even after findmylocateagent has produced a usable cached location.
static NSArray* pollLocationsFromExplicitFindMyLocateTargets(NSString *filterHandle,
                                                             id directFindMyLocateSession,
                                                             NSArray *directFriendObjects,
                                                             id findMyLocateBootstrap,
                                                             NSArray *bootstrapFriendObjects,
                                                             NSArray *bootstrapHandleObjects,
                                                             BOOL includeDebugRaw,
                                                             NSMutableArray *diagLog) {
    NSArray *sessionCandidates = [directFriendObjects count] > 0 ? directFriendObjects : @[];
    NSArray *wrapperCandidates = [bootstrapFriendObjects count] > 0 ? bootstrapFriendObjects :
                                 ([bootstrapHandleObjects count] > 0 ? bootstrapHandleObjects : @[]);

    if (!directFindMyLocateSession && !findMyLocateBootstrap) {
        return @[];
    }
    if ([sessionCandidates count] == 0 && [wrapperCandidates count] == 0 && filterHandle.length == 0) {
        [diagLog addObject:@"FindMyLocate explicit poll skipped: no friend objects or handles to query"];
        return @[];
    }

    for (NSInteger attempt = 0; attempt < 6; attempt++) {
        if (attempt > 0) {
            spinMainRunLoopForSeconds(0.5);
        }

        NSMutableArray *results = [NSMutableArray array];
        NSMutableSet *seenHandles = [NSMutableSet set];
        NSString *attemptLabel = [NSString stringWithFormat:@"attempt %ld", (long)(attempt + 1)];

        if (directFindMyLocateSession) {
            NSArray *sessionResults = collectLocationEntriesFromFindMyLocateTarget(
                directFindMyLocateSession,
                [NSString stringWithFormat:@"FindMyLocateSession(explicit %@)", attemptLabel],
                filterHandle,
                sessionCandidates,
                @[@"cachedLocationForHandle:includeAddress:"],
                @[@"cachedLocationForHandle:"],
                includeDebugRaw,
                seenHandles,
                diagLog
            );
            if ([sessionResults count] > 0) {
                [results addObjectsFromArray:sessionResults];
            }
        }

        if (findMyLocateBootstrap) {
            NSArray *wrapperResults = collectLocationEntriesFromFindMyLocateTarget(
                findMyLocateBootstrap,
                [NSString stringWithFormat:@"FindMyLocateObjCWrapper(explicit %@)", attemptLabel],
                nil,
                wrapperCandidates,
                @[@"cachedLocationFor:includeAddress:"],
                @[],
                includeDebugRaw,
                seenHandles,
                diagLog
            );
            if ([wrapperResults count] > 0) {
                [results addObjectsFromArray:wrapperResults];
            }
        }

        if ([results count] > 0) {
            [diagLog addObject:[NSString stringWithFormat:@"FindMyLocate explicit poll returned %lu location entries on %@",
                                (unsigned long)[results count], attemptLabel]];
            return results;
        }
    }

    [diagLog addObject:@"FindMyLocate explicit poll exhausted without location objects"];
    return @[];
}

static NSArray* collectLocationsViaFindMyLocate(NSString *filterHandle, BOOL includeDebugRaw, NSMutableArray *diagLog, BOOL *sawKnownSharingHandles) {
    if (sawKnownSharingHandles) *sawKnownSharingHandles = NO;

    dlopen("/System/Library/PrivateFrameworks/FindMyLocate.framework/FindMyLocate", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/FindMyLocateObjCWrapper.framework/FindMyLocateObjCWrapper", RTLD_NOW);

    NSArray *targets = @[
        @{
            @"label": @"FindMyLocateSession",
            @"class_name": @"FindMyLocateSession",
            @"friend_selectors": @[@"cachedFriendsSharingLocationsWithMe"],
            @"location_selectors_with_address": @[@"cachedLocationForHandle:includeAddress:"],
            @"location_selectors": @[@"cachedLocationForHandle:"],
        },
        @{
            @"label": @"FindMyLocateObjCWrapper",
            @"class_name": @"FindMyLocateObjCWrapper.ObjCBootstrap",
            @"friend_selectors": @[@"cachedFriendsSharingLocationWithMe"],
            @"location_selectors_with_address": @[@"cachedLocationFor:includeAddress:"],
            @"location_selectors": @[],
        },
    ];

    NSMutableArray *results = [NSMutableArray array];
    NSMutableSet *seenHandles = [NSMutableSet set];

    for (NSDictionary *targetInfo in targets) {
        NSString *label = targetInfo[@"label"];
        NSString *className = targetInfo[@"class_name"];
        id target = newObjectOfClassNamed(className);
        if (!target) {
            [diagLog addObject:[NSString stringWithFormat:@"%@ unavailable", label]];
            continue;
        }

        [diagLog addObject:[NSString stringWithFormat:@"%@ target=%@", label, NSStringFromClass([target class])]];

        NSArray *friendObjects = @[];
        NSString *usedFriendSelector = nil;
        for (NSString *selectorName in targetInfo[@"friend_selectors"]) {
            id value = objectByPerformingSelector(target, selectorName);
            if (value) {
                usedFriendSelector = selectorName;
                friendObjects = objectsFromCollection(value);
                break;
            }
        }

        if (usedFriendSelector) {
            [diagLog addObject:[NSString stringWithFormat:@"%@ %@ -> %lu objects %@",
                                label,
                                usedFriendSelector,
                                (unsigned long)[friendObjects count],
                                summarizedHandlesFromObjects(friendObjects)]];
        } else {
            [diagLog addObject:[NSString stringWithFormat:@"%@ no cached friends selector responded", label]];
        }

        if ([friendObjects count] > 0 && sawKnownSharingHandles) {
            *sawKnownSharingHandles = YES;
        }

        NSArray *targetResults = collectLocationEntriesFromFindMyLocateTarget(
            target,
            label,
            filterHandle,
            friendObjects,
            targetInfo[@"location_selectors_with_address"],
            targetInfo[@"location_selectors"],
            includeDebugRaw,
            seenHandles,
            diagLog
        );
        if ([targetResults count] > 0) {
            [results addObjectsFromArray:targetResults];
        }
    }

    return results;
}

static NSArray* friendObjectsFromFindMyLocateTarget(id target, NSArray *friendSelectors) {
    for (NSString *selectorName in friendSelectors) {
        id value = objectByPerformingSelector(target, selectorName);
        NSArray *objects = objectsFromCollection(value);
        if ([objects count] > 0) {
            return objects;
        }
    }
    return @[];
}

static NSArray* handleStringsFromFindMyLocateTarget(id target, NSArray *friendSelectors) {
    NSArray *friendObjects = friendObjectsFromFindMyLocateTarget(target, friendSelectors);
    NSMutableArray *handles = [NSMutableArray array];
    NSMutableSet *seenHandles = [NSMutableSet set];

    for (id object in friendObjects) {
        NSString *handle = handleStringFromObject(object);
        if (handle.length == 0 || [seenHandles containsObject:handle]) continue;
        [seenHandles addObject:handle];
        [handles addObject:handle];
    }

    return handles;
}

static NSArray* methodNamesForClass(Class cls, BOOL instanceMethods) {
    if (!cls) return @[];

    unsigned int count = 0;
    Class targetClass = instanceMethods ? cls : object_getClass(cls);
    Method *methods = class_copyMethodList(targetClass, &count);
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int i = 0; i < count; i++) {
        SEL selector = method_getName(methods[i]);
        if (selector) {
            [names addObject:NSStringFromSelector(selector)];
        }
    }
    free(methods);

    return [names sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

static NSDictionary* handleDebugObjCClass(NSInteger requestId, NSDictionary *params) {
    NSString *className = [params[@"class_name"] isKindOfClass:[NSString class]] ? params[@"class_name"] : params[@"class"];
    NSString *prefix = [params[@"prefix"] isKindOfClass:[NSString class]] ? params[@"prefix"] : nil;

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];

    if (prefix.length > 0) {
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        NSMutableArray *matching = [NSMutableArray array];
        for (unsigned int i = 0; i < classCount; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            if ([name hasPrefix:prefix]) {
                [matching addObject:name];
            }
        }
        free(classes);
        payload[@"matching_classes"] = [matching sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    }

    if (className.length > 0) {
        Class cls = NSClassFromString(className);
        if (!cls) {
            return errorResponse(requestId, [NSString stringWithFormat:@"Class not found: %@", className]);
        }

        payload[@"class_name"] = className;
        payload[@"instance_methods"] = methodNamesForClass(cls, YES);
        payload[@"class_methods"] = methodNamesForClass(cls, NO);
    }

    if (payload.count == 0) {
        return errorResponse(requestId, @"Provide `class_name` or `prefix`");
    }

    return successResponse(requestId, payload);
}

static id summarizedDebugValue(id value) {
    if (!value || value == [NSNull null]) return @"nil";

    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *items = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            [items addObject:[NSString stringWithFormat:@"%@ :: %@",
                              NSStringFromClass([item class]), [item description]]];
            if ([items count] >= 50) break;
        }
        return @{
            @"class": NSStringFromClass([value class]),
            @"count": @([(NSArray *)value count]),
            @"items": items,
        };
    }

    if ([value isKindOfClass:[NSSet class]]) {
        return summarizedDebugValue([(NSSet *)value allObjects]);
    }

    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *summary = [NSMutableDictionary dictionary];
        NSMutableArray *keys = [NSMutableArray array];
        for (id key in [(NSDictionary *)value allKeys]) {
            [keys addObject:[key description]];
        }
        summary[@"class"] = NSStringFromClass([value class]);
        summary[@"count"] = @([(NSDictionary *)value count]);
        summary[@"keys"] = [keys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        return summary;
    }

    return @{
        @"class": NSStringFromClass([value class]),
        @"description": [value description] ?: @"",
    };
}

static NSDictionary* handleDebugInvokeSelector(NSInteger requestId, NSDictionary *params) {
    NSString *className = [params[@"class_name"] isKindOfClass:[NSString class]] ? params[@"class_name"] : nil;
    NSString *selectorName = [params[@"selector"] isKindOfClass:[NSString class]] ? params[@"selector"] : nil;
    BOOL useSharedInstance = [params[@"shared_instance"] respondsToSelector:@selector(boolValue)] ? [params[@"shared_instance"] boolValue] : NO;

    if (className.length == 0 || selectorName.length == 0) {
        return errorResponse(requestId, @"Provide `class_name` and `selector`");
    }

    Class cls = NSClassFromString(className);
    if (!cls) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Class not found: %@", className]);
    }

    id target = cls;
    if (useSharedInstance) {
        target = objectByPerformingSelector(cls, @"sharedInstance");
        if (!target) {
            return errorResponse(requestId, [NSString stringWithFormat:@"%@.sharedInstance is nil", className]);
        }
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        return errorResponse(requestId, [NSString stringWithFormat:@"%@ does not respond to %@", target, selectorName]);
    }

    id result = ((id (*)(id, SEL))objc_msgSend)(target, selector);
    return successResponse(requestId, @{
        @"class_name": className,
        @"selector": selectorName,
        @"shared_instance": @(useSharedInstance),
        @"result": summarizedDebugValue(result),
    });
}

static NSDictionary* handleDebugFriendshipState(NSInteger requestId, NSDictionary *params) {
    NSString *handleIdentifier = [params[@"handle"] isKindOfClass:[NSString class]] ? params[@"handle"] : nil;
    if (handleIdentifier.length == 0) {
        return errorResponse(requestId, @"Provide `handle`");
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"handle"] = handleIdentifier;

    id handleObject = newFMLHandleForIdentifier(handleIdentifier);
    if (handleObject) {
        payload[@"handle_object"] = summarizedDebugValue(handleObject);
    }

    NSArray *targetSpecs = @[
        @{
            @"label": @"findmylocate_session",
            @"class": @"FindMyLocateSession",
            @"friendship_selector": @"friendshipStateWithHandle:isFromGroup:completion:",
            @"cached_friend_selectors": @[@"cachedFriendsSharingLocationsWithMe", @"cachedFriendsFollowingMyLocation"],
        },
        @{
            @"label": @"findmylocate_wrapper",
            @"class": @"FindMyLocateObjCWrapper.ObjCBootstrap",
            @"friendship_selector": @"friendshipStateWithHandle:isFromGroup:completionHandler:",
            @"cached_friend_selectors": @[@"cachedFriendsSharingLocationWithMe", @"cachedFriendsFollowingMyLocation", @"cachedFriendsWithPendingOffers"],
        },
    ];

    for (NSDictionary *spec in targetSpecs) {
        NSString *label = spec[@"label"];
        NSString *className = spec[@"class"];
        id target = newObjectOfClassNamed(className);
        if (!target) {
            payload[label] = @{@"error": [NSString stringWithFormat:@"Unable to create %@", className]};
            continue;
        }

        NSMutableDictionary *targetPayload = [NSMutableDictionary dictionary];
        targetPayload[@"target_class"] = NSStringFromClass([target class]);

        BOOL cachedCanShareDidRespond = NO;
        BOOL cachedCanShare = boolByPerformingSelectorWithObjectAndBool(
            target,
            @"cachedCanShareLocationWithHandle:isFromGroup:",
            handleObject ?: handleIdentifier,
            NO,
            &cachedCanShareDidRespond
        );
        if (cachedCanShareDidRespond) {
            targetPayload[@"cached_can_share"] = @(cachedCanShare);
        }

        NSMutableSet *seenCachedHandles = [NSMutableSet set];
        NSMutableArray *cachedHandleLists = [NSMutableArray array];
        for (NSString *selectorName in spec[@"cached_friend_selectors"]) {
            NSArray *handles = handleStringsFromFindMyLocateTarget(target, @[selectorName]);
            if ([handles count] == 0) continue;

            NSMutableArray *uniqueHandles = [NSMutableArray array];
            for (NSString *candidate in handles) {
                if (![candidate isKindOfClass:[NSString class]] || candidate.length == 0) continue;
                if ([seenCachedHandles containsObject:candidate]) continue;
                [seenCachedHandles addObject:candidate];
                [uniqueHandles addObject:candidate];
            }
            if ([uniqueHandles count] == 0) continue;

            [cachedHandleLists addObject:@{
                @"selector": selectorName,
                @"handles": uniqueHandles,
            }];
        }
        if ([cachedHandleLists count] > 0) {
            targetPayload[@"cached_handle_sets"] = cachedHandleLists;
        }

        NSString *friendshipSelectorName = spec[@"friendship_selector"];
        SEL friendshipSelector = NSSelectorFromString(friendshipSelectorName);
        if ([target respondsToSelector:friendshipSelector]) {
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            __block id friendshipState = nil;
            typedef void (*FriendshipIMP)(id, SEL, id, BOOL, void(^)(id));
            FriendshipIMP friendshipIMP = (FriendshipIMP)objc_msgSend;
            friendshipIMP(target, friendshipSelector, handleObject ?: handleIdentifier, NO, ^(id state) {
                friendshipState = state;
                dispatch_semaphore_signal(semaphore);
            });

            long waitResult = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
            if (waitResult != 0) {
                targetPayload[@"friendship_state_timeout"] = @YES;
            } else {
                targetPayload[@"friendship_state"] = summarizedDebugValue(friendshipState);
                if (friendshipState) {
                    targetPayload[@"friendship_state_methods"] = methodNamesForClass([friendshipState class], YES);
                }
            }
        } else {
            targetPayload[@"friendship_state_error"] = [NSString stringWithFormat:@"%@ does not respond to %@",
                                                        NSStringFromClass([target class]),
                                                        friendshipSelectorName];
        }

        payload[label] = targetPayload;
    }

    return successResponse(requestId, payload);
}

static NSDictionary* handleInitLocation(NSInteger requestId, NSDictionary *params) {
    if (!_diagLog) _diagLog = [NSMutableArray array];
    else [_diagLog removeAllObjects];
    [_diagLog addObject:@"=== init_location START ==="];

    @try {
        dlopen("/System/Library/PrivateFrameworks/FMFCore.framework/FMFCore", RTLD_NOW);
        Class FMFSessionClass = NSClassFromString(@"FMFSession");
        if (!FMFSessionClass) {
            return errorResponse(requestId, @"FMFSession not available");
        }

        id session = objectByPerformingSelector(FMFSessionClass, @"sharedInstance");
        if (!session) {
            return errorResponse(requestId, @"FMFSession.sharedInstance is nil");
        }

        NSMutableDictionary *diag = [NSMutableDictionary dictionary];

        // Check provisioning
        BOOL hasProvisioningValue = NO;
        BOOL prov = boolByPerformingSelector((id)FMFSessionClass, @"isProvisionedForLocationSharing", &hasProvisioningValue);
        if (hasProvisioningValue) {
            diag[@"provisioned"] = @(prov);
        }

        // isMyLocationEnabled
        BOOL hasMyLocationValue = NO;
        BOOL myLocEnabled = boolByPerformingSelector(session, @"isMyLocationEnabled", &hasMyLocationValue);
        if (hasMyLocationValue) {
            diag[@"my_location_enabled"] = @(myLocEnabled);
        }

        // Current handles
        NSSet *handles = objectByPerformingSelector(session, @"handles");
        diag[@"handles"] = [handles allObjects] ?: @[];
        diag[@"cached_sharing_with_me"] = objectsFromCollection(objectByPerformingSelector(session, @"cachedGetHandlesSharingLocationsWithMe"));
        diag[@"sync_sharing_with_me"] = objectsFromCollection(objectByPerformingSelector(session, @"getHandlesSharingLocationsWithMe"));
        diag[@"active_device_sync"] = [NSString stringWithFormat:@"%@", objectByPerformingSelector(session, @"getActiveLocationSharingDevice") ?: @"nil"];

        id allDevicesSync = objectByPerformingSelector(session, @"getAllDevices");
        if (allDevicesSync) {
            diag[@"devices_sync"] = objectsFromCollection(allDevicesSync);
        }

        NSDictionary *cachedLocationMap = objectByPerformingSelector(session, @"cachedLocationForHandleByHandle");
        if ([cachedLocationMap isKindOfClass:[NSDictionary class]]) {
            diag[@"cached_location_handles"] = [[cachedLocationMap allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        }

        BOOL sawFindMyLocateHandles = NO;
        NSArray *findMyLocateResults = collectLocationsViaFindMyLocate(nil, YES, _diagLog, &sawFindMyLocateHandles);
        diag[@"findmylocate_has_known_sharing_handles"] = @(sawFindMyLocateHandles);
        if ([findMyLocateResults count] > 0) {
            diag[@"findmylocate_locations"] = findMyLocateResults;
        }

        // Set handles from params if provided
        NSArray *newHandles = params[@"handles"];
        if (newHandles && newHandles.count > 0) {
            NSSet *handleSet = [NSSet setWithArray:newHandles];
            ((void (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"setHandles:"), handleSet);
            diag[@"set_handles"] = newHandles;
            [_diagLog addObject:[NSString stringWithFormat:@"Set handles: %@", newHandles]];
        }

        // Try to unhide location
        SEL unhideSel = NSSelectorFromString(@"setHideMyLocationEnabled:completion:");
        if ([session respondsToSelector:unhideSel]) {
            typedef void (*UnhideIMP)(id, SEL, BOOL, id);
            UnhideIMP doUnhide = (UnhideIMP)objc_msgSend;
            doUnhide(session, unhideSel, NO, nil);
            diag[@"unhide_called"] = @YES;
        }

        // Reload data
        SEL reloadSel = NSSelectorFromString(@"reloadDataIfNotLoaded");
        if ([session respondsToSelector:reloadSel]) {
            ((void (*)(id, SEL))objc_msgSend)(session, reloadSel);
            diag[@"reload_called"] = @YES;
        }

        // Get devices + active device + force refresh (all async, chain them)
        typedef void (*AsyncIMP)(id, SEL, void(^)(id));
        __block NSMutableDictionary *asyncDiag = [NSMutableDictionary dictionary];
        dispatch_group_t group = dispatch_group_create();

        // getAllDevices
        SEL allDevSel = NSSelectorFromString(@"getAllDevices:");
        if ([session respondsToSelector:allDevSel]) {
            dispatch_group_enter(group);
            AsyncIMP fn = (AsyncIMP)objc_msgSend;
            fn(session, allDevSel, ^(id result) {
                if ([result isKindOfClass:[NSArray class]]) {
                    NSMutableArray *devNames = [NSMutableArray array];
                    for (id dev in (NSArray *)result) {
                        NSString *name = nil;
                        @try { name = [dev valueForKey:@"name"]; } @catch(id e) {}
                        if (!name) @try { name = [dev description]; } @catch(id e) {}
                        [devNames addObject:name ?: @"?"];
                    }
                    asyncDiag[@"devices"] = devNames;

                    // Try to set the first device as active
                    if ([(NSArray *)result count] > 0) {
                        SEL setActiveSel = NSSelectorFromString(@"setActiveDevice:completion:");
                        if ([session respondsToSelector:setActiveSel]) {
                            typedef void (*SetDevIMP)(id, SEL, id, void(^)(id));
                            SetDevIMP setDev = (SetDevIMP)objc_msgSend;
                            id firstDevice = [(NSArray *)result firstObject];
                            setDev(session, setActiveSel, firstDevice, ^(id res) {
                                asyncDiag[@"set_active_result"] = [NSString stringWithFormat:@"%@", res ?: @"ok"];
                            });
                        }
                    }
                } else {
                    asyncDiag[@"devices"] = [NSString stringWithFormat:@"%@", result ?: @"nil"];
                }
                dispatch_group_leave(group);
            });
        }

        // getActiveLocationSharingDevice
        SEL activeSel = NSSelectorFromString(@"getActiveLocationSharingDevice:");
        if ([session respondsToSelector:activeSel]) {
            dispatch_group_enter(group);
            AsyncIMP fn = (AsyncIMP)objc_msgSend;
            fn(session, activeSel, ^(id result) {
                asyncDiag[@"active_device"] = [NSString stringWithFormat:@"%@", result ?: @"nil"];
                dispatch_group_leave(group);
            });
        }

        // forceRefresh
        SEL refreshSel = NSSelectorFromString(@"forceRefreshWithCompletion:");
        if ([session respondsToSelector:refreshSel]) {
            dispatch_group_enter(group);
            typedef void (*RefreshIMP)(id, SEL, void(^)(void));
            RefreshIMP fn = (RefreshIMP)objc_msgSend;
            fn(session, refreshSel, ^{
                asyncDiag[@"refresh"] = @"completed";
                // After refresh, check sharing handles
                SEL shareSel = NSSelectorFromString(@"getHandlesSharingLocationsWithMe:");
                if ([session respondsToSelector:shareSel]) {
                    AsyncIMP fn2 = (AsyncIMP)objc_msgSend;
                    fn2(session, shareSel, ^(id handles) {
                        if ([handles isKindOfClass:[NSSet class]]) {
                            asyncDiag[@"sharing_with_me"] = [(NSSet *)handles allObjects];
                        } else {
                            asyncDiag[@"sharing_with_me"] = [NSString stringWithFormat:@"%@", handles ?: @"nil"];
                        }
                        SEL cachedSel = NSSelectorFromString(@"cachedLocationForHandle:");
                        if ([session respondsToSelector:cachedSel] && [handles respondsToSelector:@selector(allObjects)]) {
                            NSMutableArray *cached = [NSMutableArray array];
                            for (id handleObj in [(NSSet *)handles allObjects]) {
                                id cachedLocation = ((id (*)(id, SEL, id))objc_msgSend)(session, cachedSel, handleObj);
                                NSDictionary *entry = locationEntryForHandle(handleObj, cachedLocation, YES);
                                if (entry) [cached addObject:entry];
                            }
                            asyncDiag[@"cached_locations"] = cached;
                        }
                        dispatch_group_leave(group);
                    });
                } else {
                    dispatch_group_leave(group);
                }
            });
        }

        // Wait for all async ops and write response
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
            [diag addEntriesFromDictionary:asyncDiag];
            diag[@"diag_log"] = [_diagLog copy];
            writeResponseToFile(successResponse(requestId, diag));
        });

        return nil; // async
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"init_location failed: %@", exception.reason]);
    }
}

static NSDictionary* handleGetLocations(NSInteger requestId, NSDictionary *params) {
    if (!_diagLog) _diagLog = [NSMutableArray array];
    else [_diagLog removeAllObjects];
    [_diagLog addObject:@"=== get_locations START (FindMyLocate + FMFSession) ==="];

    @try {
        NSString *filterHandle = [params[@"handle"] isKindOfClass:[NSString class]] ? params[@"handle"] : nil;
        BOOL includeDebugRaw = [params[@"debug_raw"] respondsToSelector:@selector(boolValue)] ? [params[@"debug_raw"] boolValue] : NO;

        BOOL sawFindMyLocateHandles = NO;
        NSArray *findMyLocateResults = collectLocationsViaFindMyLocate(filterHandle, includeDebugRaw, _diagLog, &sawFindMyLocateHandles);
        if ([findMyLocateResults count] > 0) {
            [_diagLog addObject:[NSString stringWithFormat:@"returning %lu location entries from FindMyLocate snapshot",
                                 (unsigned long)[findMyLocateResults count]]];
            return successResponse(requestId, @{@"locations": findMyLocateResults});
        }
        if (sawFindMyLocateHandles) {
            [_diagLog addObject:@"FindMyLocate found sharing handles but no cached location objects"];
        }

        NSMutableArray *asyncFindMyLocateHandles = [NSMutableArray array];
        NSMutableArray *asyncFindMyLocateObjects = [NSMutableArray array];
        id directFindMyLocateSession = newObjectOfClassNamed(@"FindMyLocateSession");
        if (directFindMyLocateSession) {
            SEL getFriendsSel = NSSelectorFromString(@"getFriendsSharingLocationsWithMeWithCompletion:");
            if ([directFindMyLocateSession respondsToSelector:getFriendsSel]) {
                dispatch_semaphore_t friendsSemaphore = dispatch_semaphore_create(0);
                __block NSArray *asyncFriendObjects = @[];
                typedef void (*GetFriendsIMP)(id, SEL, void(^)(id));
                GetFriendsIMP getFriends = (GetFriendsIMP)objc_msgSend;
                getFriends(directFindMyLocateSession, getFriendsSel, ^(id friends) {
                    asyncFriendObjects = objectsFromCollection(friends);
                    dispatch_semaphore_signal(friendsSemaphore);
                });

                long friendsWait = dispatch_semaphore_wait(friendsSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
                if (friendsWait != 0) {
                    [_diagLog addObject:@"FindMyLocateSession getFriendsSharingLocationsWithMeWithCompletion timed out"];
                } else {
                    [_diagLog addObject:[NSString stringWithFormat:@"FindMyLocateSession getFriendsSharingLocationsWithMeWithCompletion -> %lu objects %@",
                                         (unsigned long)[asyncFriendObjects count],
                                         summarizedHandlesFromObjects(asyncFriendObjects)]];
                    if ([asyncFriendObjects count] > 0) {
                        [asyncFindMyLocateObjects addObjectsFromArray:asyncFriendObjects];
                    }
                    NSArray *knownHandles = handleStringsFromFindMyLocateTarget(
                        directFindMyLocateSession,
                        @[@"cachedFriendsSharingLocationsWithMe"]
                    );
                    if ([knownHandles count] == 0) {
                        for (id friendObject in asyncFriendObjects) {
                            NSString *handle = handleStringFromObject(friendObject);
                            if (handle.length > 0) {
                                [asyncFindMyLocateHandles addObject:handle];
                            }
                        }
                    } else {
                        [asyncFindMyLocateHandles addObjectsFromArray:knownHandles];
                    }

                    NSArray *asyncResults = collectLocationEntriesFromFindMyLocateTarget(
                        directFindMyLocateSession,
                        @"FindMyLocateSession(async)",
                        filterHandle,
                        asyncFriendObjects,
                        @[@"cachedLocationForHandle:includeAddress:"],
                        @[@"cachedLocationForHandle:"],
                        includeDebugRaw,
                        [NSMutableSet set],
                        _diagLog
                    );
                    if ([asyncResults count] > 0) {
                        [_diagLog addObject:[NSString stringWithFormat:@"returning %lu location entries after FindMyLocate async friend fetch",
                                             (unsigned long)[asyncResults count]]];
                        return successResponse(requestId, @{@"locations": asyncResults});
                    }
                }
            }
        }

        id findMyLocateBootstrap = newObjectOfClassNamed(@"FindMyLocateObjCWrapper.ObjCBootstrap");
        if (findMyLocateBootstrap) {
            SEL startUpdatingSel = NSSelectorFromString(@"startUpdatingFriendsWithInitialUpdates:completionHandler:");
            if ([findMyLocateBootstrap respondsToSelector:startUpdatingSel]) {
                dispatch_semaphore_t updateSemaphore = dispatch_semaphore_create(0);
                __block NSString *updateResult = @"completed";
                typedef void (*StartUpdatingIMP)(id, SEL, BOOL, void(^)(NSError *));
                StartUpdatingIMP startUpdating = (StartUpdatingIMP)objc_msgSend;
                startUpdating(findMyLocateBootstrap, startUpdatingSel, YES, ^(NSError *error) {
                    if (error) {
                        updateResult = [NSString stringWithFormat:@"error=%@", error.localizedDescription ?: error];
                    }
                    dispatch_semaphore_signal(updateSemaphore);
                });

                long updateWait = dispatch_semaphore_wait(updateSemaphore, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC));
                if (updateWait != 0) {
                    [_diagLog addObject:@"FindMyLocateObjCWrapper startUpdatingFriends timed out"];
                } else {
                    [_diagLog addObject:[NSString stringWithFormat:@"FindMyLocateObjCWrapper startUpdatingFriends %@", updateResult]];
                }

                sawFindMyLocateHandles = NO;
                findMyLocateResults = collectLocationsViaFindMyLocate(filterHandle, includeDebugRaw, _diagLog, &sawFindMyLocateHandles);
                if ([findMyLocateResults count] > 0) {
                    [_diagLog addObject:[NSString stringWithFormat:@"returning %lu location entries after FindMyLocate friend update",
                                         (unsigned long)[findMyLocateResults count]]];
                    return successResponse(requestId, @{@"locations": findMyLocateResults});
                }
            }

            NSMutableArray *refreshHandles = [NSMutableArray array];
            NSArray *cachedFriendObjects = friendObjectsFromFindMyLocateTarget(
                findMyLocateBootstrap,
                @[@"cachedFriendsSharingLocationWithMe"]
            );
            NSArray *cachedHandleObjects = handleObjectsFromFindMyLocateObjects(cachedFriendObjects);
            NSArray *asyncHandleObjects = handleObjectsFromFindMyLocateObjects(asyncFindMyLocateObjects);
            if ([cachedHandleObjects count] > 0) {
                [refreshHandles addObjectsFromArray:cachedHandleObjects];
            } else if ([asyncHandleObjects count] > 0) {
                [refreshHandles addObjectsFromArray:asyncHandleObjects];
            } else {
                NSMutableArray *stringHandles = [NSMutableArray array];
                if (filterHandle.length > 0) {
                    [stringHandles addObject:filterHandle];
                }
                NSArray *cachedHandles = handleStringsFromFindMyLocateTarget(
                    findMyLocateBootstrap,
                    @[@"cachedFriendsSharingLocationWithMe"]
                );
                if ([cachedHandles count] > 0) {
                    [stringHandles addObjectsFromArray:cachedHandles];
                }
                if ([asyncFindMyLocateHandles count] > 0) {
                    [stringHandles addObjectsFromArray:asyncFindMyLocateHandles];
                }

                NSMutableSet *seenStringHandles = [NSMutableSet set];
                for (NSString *identifier in stringHandles) {
                    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) continue;
                    if ([seenStringHandles containsObject:identifier]) continue;
                    [seenStringHandles addObject:identifier];

                    id handleObject = newFMLHandleForIdentifier(identifier);
                    if (handleObject) {
                        [refreshHandles addObject:handleObject];
                    }
                }

                if ([refreshHandles count] == 0) {
                    if ([cachedHandles count] > 0) {
                        [_diagLog addObject:[NSString stringWithFormat:@"FindMyLocate had string handles but could not build FMLHandle objects: %@",
                                             cachedHandles]];
                    } else if ([asyncFindMyLocateHandles count] > 0) {
                        [_diagLog addObject:[NSString stringWithFormat:@"FindMyLocate async friend fetch only yielded unresolved string handles: %@",
                                             asyncFindMyLocateHandles]];
                    } else if (filterHandle.length > 0) {
                        [_diagLog addObject:[NSString stringWithFormat:@"Skipping FindMyLocate refresh for %@ because no FMLHandle objects were available",
                                             filterHandle]];
                    }
                }
            }

            if ([refreshHandles count] > 0) {
                SEL refreshSel = NSSelectorFromString(@"startRefreshingLocationFor:priority:isFromGroup:reverseGeocode:completionHandler:");
                if ([findMyLocateBootstrap respondsToSelector:refreshSel]) {
                    dispatch_semaphore_t refreshSemaphore = dispatch_semaphore_create(0);
                    __block NSString *refreshResult = @"completed";
                    typedef void (*StartRefreshIMP)(id, SEL, NSArray *, NSInteger, BOOL, BOOL, void(^)(NSError *));
                    StartRefreshIMP startRefresh = (StartRefreshIMP)objc_msgSend;
                    startRefresh(findMyLocateBootstrap, refreshSel, refreshHandles, 1, NO, YES, ^(NSError *error) {
                        if (error) {
                            refreshResult = [NSString stringWithFormat:@"error=%@", error.localizedDescription ?: error];
                        }
                        dispatch_semaphore_signal(refreshSemaphore);
                    });

                    long refreshWait = dispatch_semaphore_wait(refreshSemaphore, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));
                    if (refreshWait != 0) {
                        [_diagLog addObject:[NSString stringWithFormat:@"FindMyLocateObjCWrapper refresh timed out for %@", refreshHandles]];
                    } else {
                        [_diagLog addObject:[NSString stringWithFormat:@"FindMyLocateObjCWrapper refresh %@ for %@",
                                             refreshResult, refreshHandles]];
                    }

                    sawFindMyLocateHandles = NO;
                    findMyLocateResults = collectLocationsViaFindMyLocate(filterHandle, includeDebugRaw, _diagLog, &sawFindMyLocateHandles);
                    if ([findMyLocateResults count] > 0) {
                        [_diagLog addObject:[NSString stringWithFormat:@"returning %lu location entries after FindMyLocate refresh",
                                             (unsigned long)[findMyLocateResults count]]];
                        return successResponse(requestId, @{@"locations": findMyLocateResults});
                    }

                    NSArray *explicitPollResults = pollLocationsFromExplicitFindMyLocateTargets(
                        filterHandle,
                        directFindMyLocateSession,
                        asyncFindMyLocateObjects,
                        findMyLocateBootstrap,
                        cachedFriendObjects,
                        refreshHandles,
                        includeDebugRaw,
                        _diagLog
                    );
                    if ([explicitPollResults count] > 0) {
                        [_diagLog addObject:[NSString stringWithFormat:@"returning %lu location entries after explicit FindMyLocate poll",
                                             (unsigned long)[explicitPollResults count]]];
                        return successResponse(requestId, @{@"locations": explicitPollResults});
                    }
                }
            }
        }

        dlopen("/System/Library/PrivateFrameworks/FMFCore.framework/FMFCore", RTLD_NOW);
        Class FMFSessionClass = NSClassFromString(@"FMFSession");
        if (!FMFSessionClass) {
            return errorResponse(requestId, @"FMFSession not available");
        }

        id session = objectByPerformingSelector(FMFSessionClass, @"sharedInstance");
        if (!session) {
            return errorResponse(requestId, @"FMFSession.sharedInstance is nil");
        }

        [_diagLog addObject:[NSString stringWithFormat:@"session=%@", NSStringFromClass([session class])]];

        BOOL hasMyLocationValue = NO;
        BOOL myLocationEnabled = boolByPerformingSelector(session, @"isMyLocationEnabled", &hasMyLocationValue);
        if (hasMyLocationValue) {
            [_diagLog addObject:[NSString stringWithFormat:@"isMyLocationEnabled=%d", myLocationEnabled]];
        }

        if (filterHandle.length > 0) {
            SEL setHandlesSel = NSSelectorFromString(@"setHandles:");
            if ([session respondsToSelector:setHandlesSel]) {
                NSSet *handleSet = [NSSet setWithObject:filterHandle];
                ((void (*)(id, SEL, id))objc_msgSend)(session, setHandlesSel, handleSet);
                [_diagLog addObject:[NSString stringWithFormat:@"setHandles filter=%@", filterHandle]];
            }
        }

        SEL reloadSel = NSSelectorFromString(@"reloadDataIfNotLoaded");
        if ([session respondsToSelector:reloadSel]) {
            ((void (*)(id, SEL))objc_msgSend)(session, reloadSel);
            [_diagLog addObject:@"reloadDataIfNotLoaded called"];
        }

        SEL forceRefreshSyncSel = NSSelectorFromString(@"forceRefresh");
        if ([session respondsToSelector:forceRefreshSyncSel]) {
            ((void (*)(id, SEL))objc_msgSend)(session, forceRefreshSyncSel);
            [_diagLog addObject:@"forceRefresh called"];
        }

        NSArray *cachedSharingHandles = objectsFromCollection(objectByPerformingSelector(session, @"cachedGetHandlesSharingLocationsWithMe"));
        NSArray *syncSharingHandles = objectsFromCollection(objectByPerformingSelector(session, @"getHandlesSharingLocationsWithMe"));
        NSDictionary *cachedLocationByHandle = objectByPerformingSelector(session, @"cachedLocationForHandleByHandle");
        if ([cachedSharingHandles count] > 0) {
            [_diagLog addObject:[NSString stringWithFormat:@"cachedGetHandlesSharingLocationsWithMe -> %lu handles",
                                 (unsigned long)[cachedSharingHandles count]]];
        }
        if ([syncSharingHandles count] > 0) {
            [_diagLog addObject:[NSString stringWithFormat:@"getHandlesSharingLocationsWithMe -> %lu handles",
                                 (unsigned long)[syncSharingHandles count]]];
        }
        if ([cachedLocationByHandle isKindOfClass:[NSDictionary class]]) {
            [_diagLog addObject:[NSString stringWithFormat:@"cachedLocationForHandleByHandle -> %lu entries",
                                 (unsigned long)[cachedLocationByHandle count]]];
        }

        NSMutableDictionary *syncCandidatesByHandle = [NSMutableDictionary dictionary];
        if (filterHandle.length > 0) {
            syncCandidatesByHandle[filterHandle] = filterHandle;
        }
        for (id handleObj in cachedSharingHandles) {
            NSString *handle = handleStringFromObject(handleObj);
            if (handle.length > 0 && !syncCandidatesByHandle[handle]) {
                syncCandidatesByHandle[handle] = handleObj;
            }
        }
        for (id handleObj in syncSharingHandles) {
            NSString *handle = handleStringFromObject(handleObj);
            if (handle.length > 0 && !syncCandidatesByHandle[handle]) {
                syncCandidatesByHandle[handle] = handleObj;
            }
        }
        if ([cachedLocationByHandle isKindOfClass:[NSDictionary class]]) {
            for (NSString *handle in cachedLocationByHandle) {
                if (handle.length > 0 && !syncCandidatesByHandle[handle]) {
                    syncCandidatesByHandle[handle] = handle;
                }
            }
        }

        NSMutableArray *syncResults = [NSMutableArray array];
        NSArray *sortedSyncHandles = [[syncCandidatesByHandle allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        for (NSString *handle in sortedSyncHandles) {
            id originalHandleObj = syncCandidatesByHandle[handle] ?: handle;
            id cachedLocation = [cachedLocationByHandle isKindOfClass:[NSDictionary class]] ? cachedLocationByHandle[handle] : nil;
            if (!cachedLocation) {
                cachedLocation = ((id (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"cachedLocationForHandle:"), originalHandleObj);
            }
            if (!cachedLocation && originalHandleObj != handle) {
                cachedLocation = ((id (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"cachedLocationForHandle:"), handle);
            }
            [_diagLog addObject:[NSString stringWithFormat:@"sync cachedLocationForHandle(%@) -> %@",
                                 handle, cachedLocation ? NSStringFromClass([cachedLocation class]) : @"nil"]];
            NSDictionary *entry = locationEntryForHandle(originalHandleObj ?: handle, cachedLocation, includeDebugRaw);
            if (entry) {
                [syncResults addObject:entry];
            }
        }

        if ([syncResults count] > 0) {
            [_diagLog addObject:[NSString stringWithFormat:@"returning %lu location entries from sync snapshot",
                                 (unsigned long)[syncResults count]]];
            return successResponse(requestId, @{@"locations": syncResults});
        }

        SEL shareSel = NSSelectorFromString(@"getHandlesSharingLocationsWithMe:");
        SEL refreshSel = NSSelectorFromString(@"forceRefreshWithCompletion:");
        SEL cachedSel = NSSelectorFromString(@"cachedLocationForHandle:");
        if (![session respondsToSelector:cachedSel]) {
            return errorResponse(requestId, @"FMFSession.cachedLocationForHandle: not available");
        }

        __block NSArray *sharingHandleObjects = nil;
        __block BOOL shareRequested = NO;
        __block BOOL shareFinished = NO;
        __block BOOL shareTimedOut = NO;
        __block BOOL refreshRequested = NO;
        __block BOOL refreshFinished = NO;
        __block BOOL refreshTimedOut = NO;
        __block BOOL responseWritten = NO;

        void (^finishIfReady)(BOOL) = ^(BOOL forced) {
            if (responseWritten) return;

            BOOL shareSatisfied = !shareRequested || shareFinished;
            BOOL refreshSatisfied = !refreshRequested || refreshFinished;
            if (!forced && !(shareSatisfied && refreshSatisfied)) {
                return;
            }

            NSMutableDictionary *candidatesByHandle = [NSMutableDictionary dictionary];
            if (filterHandle.length > 0) {
                candidatesByHandle[filterHandle] = filterHandle;
            }

            for (id handleObj in objectsFromCollection(sharingHandleObjects)) {
                NSString *handle = handleStringFromObject(handleObj);
                if (handle.length > 0 && !candidatesByHandle[handle]) {
                    candidatesByHandle[handle] = handleObj;
                }
            }

            NSMutableArray *results = [NSMutableArray array];
            NSArray *sortedHandles = [[candidatesByHandle allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
            for (NSString *handle in sortedHandles) {
                id originalHandleObj = candidatesByHandle[handle] ?: handle;
                id cachedLocation = ((id (*)(id, SEL, id))objc_msgSend)(session, cachedSel, originalHandleObj);
                if (!cachedLocation && originalHandleObj != handle) {
                    cachedLocation = ((id (*)(id, SEL, id))objc_msgSend)(session, cachedSel, handle);
                }
                [_diagLog addObject:[NSString stringWithFormat:@"cachedLocationForHandle(%@) -> %@",
                                     handle, cachedLocation ? NSStringFromClass([cachedLocation class]) : @"nil"]];
                NSDictionary *entry = locationEntryForHandle(originalHandleObj ?: handle, cachedLocation, includeDebugRaw);
                if (entry) {
                    [results addObject:entry];
                }
            }

            BOOL cleanEmpty = shareRequested && shareFinished && !shareTimedOut;
            if (results.count > 0 || cleanEmpty) {
                [_diagLog addObject:[NSString stringWithFormat:@"returning %lu location entries",
                                     (unsigned long)results.count]];
                responseWritten = YES;
                writeResponseToFile(successResponse(requestId, @{@"locations": results}));
                return;
            }

            NSString *diag = [_diagLog componentsJoinedByString:@"; "];
            responseWritten = YES;
            writeResponseToFile(errorResponse(
                requestId,
                [NSString stringWithFormat:@"FMFSession did not return location data. Diag: %@", diag]
            ));
        };

        if ([session respondsToSelector:shareSel]) {
            shareRequested = YES;
            typedef void (*HandlesIMP)(id, SEL, void(^)(id));
            HandlesIMP fetchHandles = (HandlesIMP)objc_msgSend;
            fetchHandles(session, shareSel, ^(id handles) {
                sharingHandleObjects = objectsFromCollection(handles);
                shareFinished = YES;
                [_diagLog addObject:[NSString stringWithFormat:@"sharing handles callback returned %lu handles",
                                     (unsigned long)[sharingHandleObjects count]]];
                finishIfReady(NO);
            });
        } else {
            [_diagLog addObject:@"getHandlesSharingLocationsWithMe: unavailable"];
        }

        if ([session respondsToSelector:refreshSel]) {
            refreshRequested = YES;
            typedef void (*RefreshIMP)(id, SEL, void(^)(void));
            RefreshIMP refresh = (RefreshIMP)objc_msgSend;
            refresh(session, refreshSel, ^{
                refreshFinished = YES;
                [_diagLog addObject:@"forceRefreshWithCompletion finished"];
                finishIfReady(NO);
            });
        } else {
            [_diagLog addObject:@"forceRefreshWithCompletion: unavailable"];
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (responseWritten) return;
            if (shareRequested && !shareFinished) {
                shareTimedOut = YES;
                [_diagLog addObject:@"sharing handles callback timed out"];
            }
            if (refreshRequested && !refreshFinished) {
                refreshTimedOut = YES;
                [_diagLog addObject:@"forceRefreshWithCompletion timed out"];
            }
            shareFinished = YES;
            refreshFinished = YES;
            finishIfReady(YES);
        });

        return nil; // async — response written by callbacks/timeout
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Failed to get locations: %@", exception.reason]);
    }
}

#pragma mark - Command Router

static NSDictionary* processCommand(NSDictionary *command) {
    NSNumber *requestIdNum = command[@"id"];
    NSInteger requestId = requestIdNum ? [requestIdNum integerValue] : 0;
    NSString *action = command[@"action"];
    NSDictionary *params = command[@"params"] ?: @{};

    NSLog(@"[imsg-plus] Processing command: %@ (id=%ld)", action, (long)requestId);

    if ([action isEqualToString:@"typing"]) {
        return handleTyping(requestId, params);
    } else if ([action isEqualToString:@"read"]) {
        return handleRead(requestId, params);
    } else if ([action isEqualToString:@"react"]) {
        return handleReact(requestId, params);
    } else if ([action isEqualToString:@"status"]) {
        return handleStatus(requestId, params);
    } else if ([action isEqualToString:@"list_chats"]) {
        return handleListChats(requestId, params);
    } else if ([action isEqualToString:@"create_chat"]) {
        return handleCreateChat(requestId, params);
    } else if ([action isEqualToString:@"rename_chat"]) {
        return handleRenameChat(requestId, params);
    } else if ([action isEqualToString:@"remove_participant"]) {
        return handleRemoveParticipant(requestId, params);
    } else if ([action isEqualToString:@"send_message"]) {
        return handleSendRichMessage(requestId, params);
    } else if ([action isEqualToString:@"edit_message"]) {
        return handleEditMessage(requestId, params);
    } else if ([action isEqualToString:@"unsend_message"]) {
        return handleUnsendMessage(requestId, params);
    } else if ([action isEqualToString:@"get_locations"]) {
        return handleGetLocations(requestId, params);
    } else if ([action isEqualToString:@"init_location"]) {
        return handleInitLocation(requestId, params);
    } else if ([action isEqualToString:@"debug_objc_class"]) {
        return handleDebugObjCClass(requestId, params);
    } else if ([action isEqualToString:@"debug_invoke_selector"]) {
        return handleDebugInvokeSelector(requestId, params);
    } else if ([action isEqualToString:@"debug_friendship_state"]) {
        return handleDebugFriendshipState(requestId, params);
    } else if ([action isEqualToString:@"ping"]) {
        return successResponse(requestId, @{@"pong": @YES});
    } else {
        return errorResponse(requestId, [NSString stringWithFormat:@"Unknown action: %@", action]);
    }
}

#pragma mark - Socket Server

static void processCommandFile(void) {
    @autoreleasepool {
        initFilePaths();

        // Read command file
        NSError *error = nil;
        NSData *commandData = [NSData dataWithContentsOfFile:kCommandFile options:0 error:&error];
        if (!commandData || error) {
            return;
        }

        // Clear command file immediately to prevent re-entry if processCommand
        // yields to the run loop (e.g. XPC calls in prepareAttachment)
        [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // Parse JSON
        NSDictionary *command = [NSJSONSerialization JSONObjectWithData:commandData options:0 error:&error];
        if (error || ![command isKindOfClass:[NSDictionary class]]) {
            NSDictionary *response = errorResponse(0, @"Invalid JSON in command file");
            NSData *responseData = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingPrettyPrinted error:nil];
            [responseData writeToFile:kResponseFile atomically:YES];
            return;
        }

        // Timer runs on main run loop, so we're already on the main thread for IMCore access
        NSDictionary *result = processCommand(command);

        if (result != nil) {
            // Synchronous response — write it now
            NSData *responseData = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
            [responseData writeToFile:kResponseFile atomically:YES];
            NSLog(@"[imsg-plus] Processed command, wrote response");
        } else {
            // Async handler (e.g., react) will write its own response
            NSLog(@"[imsg-plus] Command dispatched async, response pending");
        }
    }
}

static void startFileWatcher(void) {
    initFilePaths();

    NSLog(@"[imsg-plus] Starting file-based IPC");
    NSLog(@"[imsg-plus] Command file: %@", kCommandFile);
    NSLog(@"[imsg-plus] Response file: %@", kResponseFile);

    // Create/clear command and response files
    [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"" writeToFile:kResponseFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Create lock file to indicate we're ready
    lockFd = open(kLockFile.UTF8String, O_CREAT | O_WRONLY, 0644);
    if (lockFd >= 0) {
        // Write PID to lock file
        NSString *pidStr = [NSString stringWithFormat:@"%d", getpid()];
        write(lockFd, pidStr.UTF8String, pidStr.length);
    }

    // Watch command file for changes using NSTimer on the main run loop.
    // dispatch_source timers get deallocated in injected dylib contexts,
    // but NSTimer tied to the main run loop survives reliably.
    __block NSDate *lastModified = nil;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull t) {
        @autoreleasepool {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kCommandFile error:nil];
            NSDate *modDate = attrs[NSFileModificationDate];

            if (modDate && ![modDate isEqualToDate:lastModified]) {
                // Check if file has content
                NSData *data = [NSData dataWithContentsOfFile:kCommandFile];
                if (data && data.length > 2) {  // More than just "{}"
                    lastModified = modDate;
                    processCommandFile();
                }
            }
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    fileWatchTimer = timer;  // Prevent deallocation
    fileWatchSource = nil;   // No longer using dispatch_source

    NSLog(@"[imsg-plus] File watcher started, ready for commands");
}


#pragma mark - Dylib Entry Point

__attribute__((constructor))
static void injectedInit(void) {
    NSLog(@"[imsg-plus] Dylib injected into %@", [[NSProcessInfo processInfo] processName]);

    // Inject compatibility methods for IMCore
    injectCompatibilityMethods();

    // Connect to IMDaemon for full IMCore access
    Class daemonClass = NSClassFromString(@"IMDaemonController");
    if (daemonClass) {
        id daemon = [daemonClass performSelector:@selector(sharedInstance)];
        if (daemon && [daemon respondsToSelector:@selector(connectToDaemon)]) {
            [daemon performSelector:@selector(connectToDaemon)];
            NSLog(@"[imsg-plus] ✅ Connected to IMDaemon");
        } else {
            NSLog(@"[imsg-plus] ⚠️ IMDaemonController available but couldn't connect");
        }
    } else {
        NSLog(@"[imsg-plus] ⚠️ IMDaemonController class not found");
    }

    // Delay initialization to let Messages.app fully start
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSLog(@"[imsg-plus] Initializing after delay...");

        // Log IMCore status
        Class registryClass = NSClassFromString(@"IMChatRegistry");
        if (registryClass) {
            id registry = [registryClass performSelector:@selector(sharedInstance)];
            if ([registry respondsToSelector:@selector(allExistingChats)]) {
                NSArray *chats = [registry performSelector:@selector(allExistingChats)];
                NSLog(@"[imsg-plus] IMChatRegistry available with %lu chats", (unsigned long)chats.count);
            }
        } else {
            NSLog(@"[imsg-plus] IMChatRegistry NOT available");
        }

        // Install send method swizzles to observe native UI sends
        installSendSwizzles();

        // Start file watcher for IPC
        startFileWatcher();
    });
}

__attribute__((destructor))
static void injectedCleanup(void) {
    NSLog(@"[imsg-plus] Cleaning up...");

    if (fileWatchTimer) {
        [fileWatchTimer invalidate];
        fileWatchTimer = nil;
    }
    if (fileWatchSource) {
        dispatch_source_cancel(fileWatchSource);
        fileWatchSource = nil;
    }

    if (lockFd >= 0) {
        close(lockFd);
        lockFd = -1;
    }

    // Clean up files
    initFilePaths();
    [[NSFileManager defaultManager] removeItemAtPath:kLockFile error:nil];
}
