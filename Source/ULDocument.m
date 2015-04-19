//
//  ULDocument.m
//
//  Copyright (c) 2014 The Soulmen GbR
//
//	Permission is hereby granted, free of charge, to any person obtaining a copy
//	of this software and associated documentation files (the "Software"), to deal
//	in the Software without restriction, including without limitation the rights
//	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//	copies of the Software, and to permit persons to whom the Software is
//	furnished to do so, subject to the following conditions:
//
//	The above copyright notice and this permission notice shall be included in
//	all copies or substantial portions of the Software.
//
//	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//	THE SOFTWARE.
//

#import "ULDocument.h"
#import "ULDocument_Subclassing.h"

#import "ULFilePresentationProxy.h"

#import "NSDate+Utilities.h"
#import "NSFileCoordinator+Convenience.h"
#import "NSFileManager+FilesystemConvenience.h"
#import "NSURL+PathUtilities.h"

#import <objc/runtime.h>


#ifndef ULError
	#define ULError(...)				NSLog(__VA_ARGS__)
	#define ULNotice(...)
	#define ULNoticeBeginURL(...)
	#define ULNoticeEndURL(...)
#endif

/*!
 @abstract The delay used by ULDocument instances for autosaving changes.
 */
static NSTimeInterval ULDocumentAutosaveDelay = 30.;

/*!
 @abstract The minimum interval used by ULDocument instances for automatic version generation.
 */
static NSTimeInterval ULDocumentAutoversioningInterval = 900.;


NSString *ULDocumentUnhandeledSaveErrorNotification					= @"ULDocumentUnhandeledSaveErrorNotification";
NSString *ULDocumentUnhandeledSaveErrorNotificationErrorKey			= @"error";

@interface ULDocument () <NSFilePresenter>
{
	id						_autosaveToken;							// Used to keep a document alive while autosave is pending
	dispatch_queue_t		_autosaveQueue;							// A queue used to process and dequeue autosave operations

	BOOL					_deletionPending;						// Whether or not a deletion is pending
	NSURL					*_fileURL;								// Write accessor for document's file URL
	NSOperationQueue		*_interactionQueue;						// A queue used to process and synchronize all background document interactions
	ULFilePresentationProxy	*_presenter;
	NSUndoManager			*_undoManager;
	
	NSDate					*_lastWriteErrorDate;					// The change date of the sheet when the 'writeErrorNotificationChangeDate' was set. Used to detect duplicate notifications.
	NSDate					*_lastVisibleErrorNotificationDate;		// Used to show errors again after 60s if unhandled.
}

@property NSInteger changeCount;

@property(readwrite) BOOL isReadOnly;
@property(readwrite) BOOL documentIsOpen;
@property(readwrite) BOOL isDeleted;
@property(readwrite) NSDate *fileModificationDate;
@property(readwrite) NSDate *lastFileOpenDate;
@property(readwrite) NSDate *changeDate;
@property(readwrite) NSURL *revertURL;

// The change token representing the current state in memory
@property(readwrite) id changeToken;

// The change token of the persisted state the current state in memory is based on. (Used to detect stale -presentedItemDidChange notifications)
@property(readwrite) id fileChangeToken;

@property(readwrite) NSFileVersion *currentVersion;
@property(readwrite) NSArray *conflictVersions;

@property(readwrite) NSError *lastReadError;
@property(readwrite) NSError *lastWriteError;

/*!
 @abstract Actual worker implementation writing the document's contents to disk.
 @discussion Depending on the save operation, a new version will be added to the versions store or not.
 */
- (BOOL)writeSafelyToURL:(NSURL *)url forSaveOperation:(ULDocumentSaveOperation)saveOperation error:(NSError **)outError;

@end

@implementation ULDocument

+ (NSString *)defaultFileType
{
	NSAssert(NO, @"+fileType must be overridden by subclasses");
	return nil;
}

+ (NSString *)defaultPathExtension
{
	NSAssert(NO, @"+defaultPathExtension must be overridden by subclasses");
	return nil;
}

+ (void)setAutosaveDelay:(NSTimeInterval)delay
{
	ULDocumentAutosaveDelay = delay;
}

+ (void)setAutoversioningInterval:(NSTimeInterval)interval
{
	ULDocumentAutoversioningInterval = interval;
}


#pragma mark - Initialization

+ (id)alloc
{
	NSAssert(self != ULDocument.class, @"Abstract class ULDocument cannot be instantiated directly.");
	return [super alloc];
}

- (id)init
{
	return [self initWithFileURL:nil readOnly:NO];
}

- (id)initWithFileURL:(NSURL *)url readOnly:(BOOL)readOnly
{
	self = [super init];
	
	if (self) {
		_autosaveQueue = dispatch_queue_create([[NSString stringWithFormat: @"com.soulmen.ulysses3.autosave.%p", self] cStringUsingEncoding: NSUTF8StringEncoding], DISPATCH_QUEUE_SERIAL);
		_deletionPending = NO;
		
		_interactionQueue = [NSOperationQueue new];
		_interactionQueue.maxConcurrentOperationCount = 1;
		
		self.isReadOnly = readOnly;
		self.fileURL = url;
		self.documentIsOpen = NO;
		self.undoManager = [NSUndoManager new];
	}
	
	return self;
}

- (void)dealloc
{
	self.undoManager = nil;

	[_presenter endPresentation];
}


#pragma mark - Properties

- (NSURL *)fileURL
{
	@synchronized(self) {
		return _fileURL;
	}
}

- (NSString *)fileType
{
	return self.class.defaultFileType;
}

- (void)setFileURL:(NSURL *)fileURL
{
	NSParameterAssert(!fileURL || fileURL.isFileURL);
	
	@synchronized(self) {
		if (_fileURL == fileURL || [_fileURL isEqual: fileURL])
			return;
		
		_fileURL = [[fileURL copy] ul_URLByResolvingExactFilenames];
	}
	
	if (self.documentIsOpen)
		self.currentVersion = [NSFileVersion currentVersionOfItemAtURL: _fileURL];
}

- (NSString *)preferredFilename
{
	return self.fileURL.lastPathComponent;
}

+ (NSSet *)keyPathsForValuesAffectingPreferredFilename
{
	return [NSSet setWithObject: @"fileURL"];
}

- (NSString *)sanitizedPathExtension
{
	return self.class.defaultPathExtension;
}


#pragma mark - Document state

- (void)disableEditing
{
	// Stub for subclasses to override
}

- (void)enableEditing
{
	// Stub for subclasses to override
}


#pragma mark - Change tracking

- (NSUndoManager *)undoManager
{
	@synchronized(self) {
		return _undoManager;
	}
}

- (void)setUndoManager:(NSUndoManager *)undoManager
{
	if (_undoManager) {
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSUndoManagerDidCloseUndoGroupNotification object:_undoManager];
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSUndoManagerDidUndoChangeNotification object:_undoManager];
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSUndoManagerDidRedoChangeNotification object:_undoManager];
	}
	
	_undoManager = undoManager;
	
	if (_undoManager) {
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(undoManagerDidCloseGroup:) name:NSUndoManagerDidCloseUndoGroupNotification object:_undoManager];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(undoManagerDidUndo:) name:NSUndoManagerDidUndoChangeNotification object:_undoManager];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(undoManagerDidRedo:) name:NSUndoManagerDidRedoChangeNotification object:_undoManager];
	}
}

- (void)breakUndoCoalescing
{
	// Stub for subclasses to override
}

- (void)undoManagerDidCloseGroup:(NSNotification *)notification
{
	[self updateChangeCount: ULDocumentChangeDone];
}

- (void)undoManagerDidUndo:(NSNotification *)notification
{
	[self updateChangeCount: ULDocumentChangeUndone];
}

- (void)undoManagerDidRedo:(NSNotification *)notification
{
	[self updateChangeCount: ULDocumentChangeRedone];
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
	/*
	 Resigning active state on iOS causes the app to be suspended. We must thus write out changes synchronously, as the app may fail to reach the autosave point before suspended. This is no issue on Mac OS.
	 */
	
	if ([self hasUnsavedChanges] && self.fileURL) {
#if TARGET_OS_IPHONE
		// Block for synchronous semaphore
		dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
		
		// Perform async operation
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			[self autosaveWithCompletionHandler: ^(BOOL success){
				dispatch_semaphore_signal(semaphore);
			}];
		});
		
		// Wait until finished
		dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
#else
		[self autosaveWithCompletionHandler: nil];
#endif
	}
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	// Perform synchronous save if needed
	if ([self hasUnsavedChanges] && self.fileURL) {
		NSError *error;
		NSURL *url = [self URLForSaveOperation:ULDocumentAutosave ignoreCurrentName:NO];
		if (!url) return;
		
		BOOL success = [self saveToURL:url forSaveOperation:ULDocumentAutosave error:&error];
		if (!success)
			ULError(@"Error writing file: %@ Path: %@", error.localizedDescription, url.path);
	}
}


#pragma mark -

- (BOOL)hasUnsavedChanges
{
	return (self.changeCount != 0);
}

+ (NSSet *)keyPathsForValuesAffectingHasUnsavedChanges
{
	return [NSSet setWithObject: @"changeCount"];
}

- (void)updateChangeCount:(ULDocumentChangeKind)change
{
	// Clear change counter
	if (change == ULDocumentChangeCleared) {
		self.changeCount = 0;
		
		// Deactivate autosave token in autosave queue to synchronize it
		dispatch_async(_autosaveQueue, ^{
			[self unsetAutosaveToken];
		});

		return;
	}
	
	NSAssert(!_isReadOnly, @"Modification made to read-only document %@!", self);
	
	
	// Update change date
	[self updateChangeDate];
	
	// Change autosave token in a autosave queue to synchronize it. Block retains 'self' since the autosave token has not been set yet.
	dispatch_async(_autosaveQueue, ^{
		// Autosave is already scheduled or pending: do nothing.
		if (_autosaveToken)
			return;

		// Activate autosave token to ensure document is kept alive and saved on exit
		[self setAutosaveToken];
		
		// Run autosave after predefined delay.
		__weak ULDocument *weakSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ULDocumentAutosaveDelay * NSEC_PER_SEC), _autosaveQueue, ^(void) {
			ULDocument *strongSelf = weakSelf;
			if (!strongSelf || !strongSelf->_autosaveToken)
				return;
				
			// Deregister autosave token and termination observers
			[strongSelf unsetAutosaveToken];

			// Autosave only if still needed
			if ([strongSelf hasUnsavedChanges])
				[strongSelf autosaveWithCompletionHandler: nil];
		});
	});
	
	
	// Update counter only if still possible
	if (self.changeCount == NSIntegerMax)
		return;
	
	// Not undoable changes kill the change count
	if (change & ULDocumentChangeNotUndoable) {
		self.changeCount = NSIntegerMax;
		return;
	}
	
	// Update counter
	switch (change & 0xF) {
		case ULDocumentChangeDone:
			// Doing changes to a negative change count can never be restored to "no change done"
			if (self.changeCount >= 0)
				self.changeCount++;
			else
				self.changeCount = NSIntegerMax;
			break;
			
		case ULDocumentChangeUndone:
			self.changeCount--;
			break;
			
		case ULDocumentChangeRedone:
			self.changeCount++;
			break;
	}
}

- (void)updateChangeDate
{
	self.changeDate = [NSDate date];
	
	// For any unpersisted changes, an arbitrary random number is used (-hash/-description would has only seconds precision for NSDate). For debugging purpose, we prefix it with "l:".
	self.changeToken = [NSString stringWithFormat: @"l:%X", arc4random()];
}

+ (id)changeTokenForItemAtURL:(NSURL *)documentURL
{
	NSError *error;
	NSArray *urlAttributes;
	NSString *versionIdentifier;
	
	[self getChangeTokenURLAttributes:&urlAttributes versionIdentifier:&versionIdentifier];

	NSDictionary *resourceValues = [documentURL ul_uncachedResourceValuesForKeys:urlAttributes error:&error];
	
	// Report any errors. Prevent search index corruption by creating random tokens on error
	if (!resourceValues) {
		ULError(@"Cannot request change token attributes from '%@' for '%@': %@", urlAttributes, documentURL, error);
		return [NSString stringWithFormat: @"e:%X", arc4random()];
	}

	// Create unique token value.
	NSMutableString *changeToken = [versionIdentifier mutableCopy];

	for (NSString *urlAttribute in urlAttributes) {
		id tokenValue = resourceValues[urlAttribute];
		[changeToken appendString: @"|"];
		
		if ([tokenValue isKindOfClass: NSDate.class])
			[changeToken appendFormat: @"%lX", (unsigned long)[tokenValue timeIntervalSinceReferenceDate]];

		else if (tokenValue)
			[changeToken appendString: [tokenValue description]];
	}
	
	// Create token based on resource values. Calling -hash directly would not provide a proper value for NSDictionary.
	return changeToken;
}

+ (void)getChangeTokenURLAttributes:(NSArray **)outAttributes versionIdentifier:(NSString **)outIdentifier
{
	static NSArray *attributes;
	static NSString *versionIdentifier;
	
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		attributes = @[(id)kCFURLContentModificationDateKey];
		versionIdentifier = @"1";
	});
	
	if (outAttributes) *outAttributes = attributes;
	if (outIdentifier) *outIdentifier = versionIdentifier;
}

- (void)setAutosaveToken
{
	if (_autosaveToken)
		return;
	
	// Create a cyclic reference to ensure that the document is kept alive until autosave happens
	_autosaveToken = self;
	
	// Register for notifications to autosave on termination / resign active
	#if TARGET_OS_IPHONE
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillTerminate:) name:UIApplicationWillTerminateNotification object:nil];
	#else
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillResignActive:) name:NSApplicationWillResignActiveNotification object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:nil];
	#endif
}

- (void)unsetAutosaveToken
{
	if (!_autosaveToken)
		return;

	// Autosave happened: no further retaining needed
	_autosaveToken = nil;
		
	#if TARGET_OS_IPHONE
		[NSNotificationCenter.defaultCenter removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
		[NSNotificationCenter.defaultCenter removeObserver:self name:UIApplicationWillTerminateNotification object:nil];
	#else
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSApplicationWillResignActiveNotification object:nil];
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSApplicationWillTerminateNotification object:nil];
	#endif
}


#pragma mark - Reading and writing

- (void)openWithCompletionHandler:(void (^)(BOOL success))completionHandler
{
	// Document does not need to be opened
	if (self.documentIsOpen) {
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			if (completionHandler)
				completionHandler(YES);
		});
		return;
	}
	
	// Document has no URL
	if (!self.fileURL) {
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			if (completionHandler)
				completionHandler(NO);
		});
		return;
	}
	
	// Coordinate sequential reading
	[_interactionQueue addOperationWithBlock:^{
		__block BOOL success = NO;
		__block NSError *readError;
		NSError *error;
		
		ULNoticeBeginURL(self.fileURL);
		
		[[[NSFileCoordinator alloc] initWithFilePresenter: _presenter] coordinateReadingItemAtURL:self.fileURL options:NSFileCoordinatorReadingWithoutChanges error:&error byAccessor:^(NSURL *newURL) {
			// Document has been opened in the meantime
			if (self.documentIsOpen) {
				success = YES;
				return;
			}
			
			// Attempt read
			success = [self coordinatedOpenFromURL:newURL error:&readError];
		}];
		
		ULNoticeEndURL(self.fileURL);

		// Set last read error
		self.lastReadError = error ?: readError;
		
		// Callback
		if (!success)
			ULError(@"Error opening file %@: %@", self.fileURL.path, error ?: readError);
			
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			if (completionHandler)
				completionHandler(success);
		});
	}];
}

- (void)saveWithCompletionHandler:(void (^)(BOOL success))completionHandler
{
	NSURL *url = [self URLForSaveOperation:ULDocumentSave ignoreCurrentName:NO];
	NSAssert(url, @"Explicit save without valid URL forbidden.");
	
	[self saveToURL:url forSaveOperation:ULDocumentSave completionHandler:completionHandler];
}

- (void)autosaveWithCompletionHandler:(void (^)(BOOL success))completionHandler
{
	NSURL *url = [self URLForSaveOperation:ULDocumentAutosave ignoreCurrentName:NO];
	if (!url) return;
	
	[self saveToURL:url forSaveOperation:ULDocumentAutosave completionHandler:completionHandler];
}

- (void)closeWithCompletionHandler:(void (^)(BOOL success))completionHandler
{
	[_interactionQueue addOperationWithBlock:^{
		// Document does not need to be closed
		if (!self.documentIsOpen) {
			if (completionHandler) {
				dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
					completionHandler(YES);
				});
			}
			return;
		}
		
		// Write changes if needed
		if (self.hasUnsavedChanges) {
			[self autosaveWithCompletionHandler: ^(BOOL success) {
				[self close];
				if (completionHandler) {
					dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
						completionHandler(success);
					});
				}
			}];
		}
		else {
			[self close];
			if (completionHandler) {
				dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
					completionHandler(YES);
				});
			}
		}
	}];
}

- (void)deleteWithCompletionHandler:(void (^)(BOOL success))completionHandler
{
	// Coordinate sequential deletion
	[_interactionQueue addOperationWithBlock:^{
		__block NSError *deleteError;
		__block BOOL success = NO;
		NSError *error;
		
		ULNoticeBeginURL(self.fileURL);
		
		[[[NSFileCoordinator alloc] initWithFilePresenter: _presenter] coordinateWritingItemAtURL:self.fileURL options:NSFileCoordinatorWritingForDeleting error:&error byAccessor:^(NSURL *newURL) {
			// File has been deleted externally
			if (_deletionPending) {
				deleteError = [NSError errorWithDomain:NSCocoaErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: @"Deletion pending."}];
				return;
			}
			
			// Attempt delete
			success = [NSFileManager.defaultManager removeItemAtURL:newURL error:&deleteError];
			success = success || ![newURL checkResourceIsReachableAndReturnError: NULL];
		}];
		
		ULNoticeEndURL(self.fileURL);
		
		// Close document
		if (success) {
			[self close];
			self.fileModificationDate = nil;
			self.changeDate = nil;
			self.changeToken = nil;
			self.fileChangeToken = nil;
		}
		else
			ULError(@"Error deleting file: %@", (error ?: deleteError).localizedDescription);
		
		// Callback
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			if (completionHandler)
				completionHandler(success);
		});
	}];
}

- (void)close
{
	_presenter = nil;
	
	// Deactivate autosave observers. Do it on _autosaveQueue to prevent race conditions.
	dispatch_async(_autosaveQueue, ^{
		[self unsetAutosaveToken];
	});
	
	self.documentIsOpen = NO;
	self.changeCount = 0;
}

- (void)revertToContentsOfURL:(NSURL *)url completionHandler:(void (^)(BOOL success))completionHandler
{
	// No duplicate reverts to the same URL
	if ([self.revertURL ul_isEqualToFileURL:url])
		return;
	else
		NSAssert(!self.revertURL, @"Document is currently being reverted to URL %@, but second request to revert to %@ was issued!", self.revertURL, url);
	
	// Disable document for reverting
	self.revertURL = [url copy];
	[self disableEditing];
	
	// Coordinate sequential reading
	[_interactionQueue addOperationWithBlock:^{
		__block NSError *readError;
		__block BOOL success = NO;
		NSError *error;
		
		ULNoticeBeginURL(self.fileURL);
		
		[[[NSFileCoordinator alloc] initWithFilePresenter: _presenter] coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&error byAccessor:^(NSURL *newURL) {
			// Attempt read
			self.fileURL = newURL;
			success = [self coordinatedOpenFromURL:newURL error:&readError];
		}];
		
		ULNoticeEndURL(self.fileURL);
		
		// Callback
		if (!success)
			ULError(@"Error reverting to file %@: %@", self.fileURL.path, (error ?: readError).localizedDescription);
		else
			[self enableEditing];
		self.revertURL = nil;
		self.changeDate = self.fileModificationDate;
		
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			if (completionHandler)
				completionHandler(success);
		});
	}];
}


#pragma mark -

- (NSURL *)URLForSaveOperation:(ULDocumentSaveOperation)saveOperation ignoreCurrentName:(BOOL)ignoreCurrentName
{ 
	return [[self.fileURL URLByDeletingLastPathComponent] URLByAppendingPathComponent: self.preferredFilename];
}

- (void)didChangeFileURLBySaving
{
	// Empty implementation
}

- (void)didMoveToURL:(NSURL *)newURL
{
	// Empty implementation
}

- (BOOL)coordinatedOpenFromURL:(NSURL *)url error:(NSError **)outError
{
	if (![self readFromURL:url error:outError])
		return NO;
	
	// Clear dirty state
	[self.undoManager removeAllActions];
	[self updateChangeCount: ULDocumentChangeCleared];
	
	// Read change date and current version
	NSDate *fileDate = url.ul_fileModificationDate;
	self.fileModificationDate = fileDate;
	self.fileChangeToken = [self.class changeTokenForItemAtURL: url];
	self.changeToken = self.fileChangeToken;
	self.currentVersion = [NSFileVersion currentVersionOfItemAtURL: self.fileURL];
	
	// Note to update conflict versions.
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
		[self updateConflictVersions];
	});
	
	// Update state
	self.documentIsOpen = YES;
	self.lastFileOpenDate = [NSDate new];
	
	if (!_isReadOnly && !_presenter) {
		_presenter = [[ULFilePresentationProxy alloc] initWithOwner: self];
		[_presenter beginPresentationOnURL: url];
	}
	
	_deletionPending = NO;
	
	return YES;
}

- (void)saveToURL:(NSURL *)url forSaveOperation:(ULDocumentSaveOperation)saveOperation completionHandler:(void (^)(BOOL success))completionHandler
{
	NSParameterAssert(url);

	[_interactionQueue addOperationWithBlock:^{
		__autoreleasing NSError *error;
		
		// Perform write
		BOOL success = [self saveToURL:url forSaveOperation:saveOperation error:&error];
		if (!success) {
			ULError(@"Error writing file: %@ Path: %@", error.localizedDescription, url.path);
		
			// Post error notification if needed
			if (!completionHandler)
				[self notifyError:error forSaveOperation:saveOperation];
		}
		
		// Notify
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			if (completionHandler)
				completionHandler(success);
		});
	}];
}

- (BOOL)saveToURL:(NSURL *)url forSaveOperation:(ULDocumentSaveOperation)saveOperation error:(NSError **)outError
{
	NSParameterAssert(url);
	NSError *localError;
	__block BOOL success = NO;
	
	// Only standardize URL, do not resolve exact filename since filename's case may change
	url = url.ul_URLByFastStandardizingPath;
	
	// Renaming and writing a file (use direct, standardized URL comparison to detect filename case changes, instead of -ul_isEqualToFileURL:)
	if ((saveOperation == ULDocumentSave || saveOperation == ULDocumentAutosave) && ![url isEqual: self.fileURL] && [self.fileURL checkResourceIsReachableAndReturnError: NULL]) {
		NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter: _presenter];
		__block NSURL *movedURL;
		__block NSError *operationError;
		
		ULNoticeBeginURL(self.fileURL);

		[coordinator ul_coordinateMovingItemAtURL:self.fileURL toURL:url error:&localError byAccessor:^(NSURL *currentURL, NSURL *newURL) {
			// File has been deleted externally
			if (_deletionPending) {
				operationError = [NSError errorWithDomain:NSCocoaErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: @"Deletion pending."}];
				return;
			}

			// Move old file, if URL is about to change
			if (![NSFileManager.defaultManager ul_moveItemCaseSensistiveAtURL:currentURL toURL:newURL error:&operationError]) {
				success = NO;
				return;
			}

			[coordinator itemAtURL:currentURL didMoveToURL:newURL];

			// Resolve to exact URL
			movedURL = newURL.ul_URLByResolvingExactFilenames;

			self.fileURL = movedURL;

			// File has been deleted externally
			if (_deletionPending) {
				operationError = [NSError errorWithDomain:NSCocoaErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: @"Deletion pending."}];
				success = NO;
				return;
			}

			// Write wrapper
			success = [self coordinatedSaveToURL:movedURL forSaveOperation:saveOperation error:&operationError];
			[self didChangeFileURLBySaving];
		}];
		
		localError = localError ?: operationError;
		ULNoticeEndURL(self.fileURL);
	}
	// Just writing
	else {
		ULNoticeBeginURL(url);
		__block NSError *operationError;
		
		[[[NSFileCoordinator alloc] initWithFilePresenter: _presenter] coordinateWritingItemAtURL:url options:0 error:&localError byAccessor:^(NSURL *newURL) {
			// File has been deleted externally
			if (_deletionPending) {
				operationError = [NSError errorWithDomain:NSCocoaErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: @"Deletion pending."}];
				return;
			}
			
			success = [self coordinatedSaveToURL:newURL forSaveOperation:saveOperation error:&operationError];
		}];
		
		localError = localError ?: operationError;
		ULNoticeEndURL(url);
	}
		
	// Report
	if (outError) *outError = localError;
	self.lastWriteError = localError;

	// Notify unhandled errors	
	if (!success && !outError)
		[self notifyError:localError forSaveOperation:saveOperation];
		
	return success;
}

- (BOOL)coordinatedSaveToURL:(NSURL *)url forSaveOperation:(ULDocumentSaveOperation)saveOperation error:(NSError **)outError
{
	id lastChangeToken = self.changeToken;
	NSDictionary *preservedAttributes = self.fileURL.ul_preservableFileAttributes;
	
	// Perform safe write
	BOOL success = [self writeSafelyToURL:url forSaveOperation:saveOperation error:outError];
	if (!success) {
		// Break undo coalescing, to ensure that further changes will trigger further write errors.
		[self breakUndoCoalescing];
		return NO;
	}
	
	// Restore preserved file attributes if possible
	if (preservedAttributes.count)
		[url setResourceValues:preservedAttributes error:NULL];
	
	// Save to does not alter document state
	if (saveOperation == ULDocumentSaveTo)
		return YES;
	
	// Update document state
	self.documentIsOpen = YES;
	self.fileURL = url;
	[self updateChangeCount: ULDocumentChangeCleared];
	
	[self breakUndoCoalescing];
	
	// We need to create a unique timestamp for each new version of the file (e.g. for indexing). Since file modification dates have a second as granularity, we may need to wait...
	if (self.fileModificationDate.timeIntervalSinceReferenceDate >= floor(NSDate.timeIntervalSinceReferenceDate))
		[NSThread sleepUntilDate: [NSDate dateWithTimeIntervalSinceReferenceDate: ceil(NSDate.timeIntervalSinceReferenceDate)]];
	
	// Make sure that file modification date is updated to the new timestamp (the actual file modification happened before getting a unique time stamp...)
	[url setResourceValue:[NSDate new] forKey:NSURLContentModificationDateKey error:NULL];
	self.fileModificationDate = url.ul_fileModificationDate;
	
	// Update change token to persisted state. This ensures that stale -presentedItemDidChange notifications will not revert changes happen in memory while saving the file.
	self.fileChangeToken = [self.class changeTokenForItemAtURL: url];
	
	// If a change occured while saving: update change count to mark document as dirty and ensure that changeToken is set to a non-persistent value.
	if (self.changeDate && ![lastChangeToken isEqual: self.changeToken])
		[self updateChangeCount: ULDocumentChangeDone | ULDocumentChangeNotUndoable];
	
	// If there are no unsaved changes, the change token should be based on information persisted to the file system.
	// We completely switch to the currently persisted state, since it may contain additional file system attributes and dates with different precision.
	else
		self.changeToken = self.fileChangeToken;
	
	// Update current version
	self.currentVersion = [NSFileVersion currentVersionOfItemAtURL: self.fileURL];
	
	// Requires the activation of a new presenter
	if (!_presenter) {
		_presenter = [[ULFilePresentationProxy alloc] initWithOwner: self];
		[_presenter beginPresentationOnURL: url];
	}
	
	return YES;
}

- (BOOL)writeSafelyToURL:(NSURL *)url forSaveOperation:(ULDocumentSaveOperation)saveOperation error:(NSError **)outError
{
	NSParameterAssert(url);
	
	NSFileManager *fileManager = NSFileManager.defaultManager;
	
	// Create temporary folder
	NSURL *temporaryFolderURL = [fileManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:url create:YES error:outError];
	if (!temporaryFolderURL)
		return NO;

	// Create URL for temporary file
	NSURL *temporaryFileURL = [temporaryFolderURL URLByAppendingPathComponent: url.lastPathComponent];
	
	// Copy old version to a temporary place for adding it to the version store.
	// Note: We copy it, since some applications would lose track of the file when moving it away. (e.g. TextEdit)
	if ([url checkResourceIsReachableAndReturnError: NULL]) {
		// Fast path: Try hard linking first
		if (![fileManager linkItemAtURL:url toURL:temporaryFileURL error:NULL]) {
			// Linking failed: remove if anything has been generated while linking (e.g. empty folders, see ULYSSES-2533)
			[fileManager removeItemAtURL:temporaryFileURL error:NULL];
			
			// Slow path: make a full copy.
			if (![fileManager copyItemAtURL:url toURL:temporaryFileURL error:outError]) {
				// Copying failed: remove entire temporary folder
				[fileManager removeItemAtURL:temporaryFolderURL error:NULL];
				return NO;
			}
		}
	}
	
	// Write new version to location
	if (![self writeToURL:url forSaveOperation:saveOperation originalContentsURL:self.fileURL error:outError]) {
		// Remove temporary directory
		[fileManager removeItemAtURL:temporaryFolderURL error:NULL];
		return NO;
	}
	
#if !TARGET_OS_IPHONE
	// Store old state as version
	if ([temporaryFileURL checkResourceIsReachableAndReturnError: NULL]) {
		BOOL shouldAddVersion;
		
		switch (saveOperation) {
			case ULDocumentSave:
				shouldAddVersion = (self.changeDate && [self.changeDate.ul_dateWithFilesystemPrecision timeIntervalSinceDate: self.fileModificationDate] > 0);
				break;
				
			case ULDocumentAutosave:
				shouldAddVersion = (ULDocumentAutoversioningInterval > 0 && self.changeDate && self.currentVersion && [self.changeDate timeIntervalSinceDate: self.currentVersion.modificationDate] > ULDocumentAutoversioningInterval);
				break;
				
			case ULDocumentSaveAs:
			case ULDocumentSaveTo:
				shouldAddVersion = (ULDocumentAutoversioningInterval > 0);
				break;
		}
		
		// Add version to store. Ignore failures, since file systems may not support the version store.
		if (shouldAddVersion && ![NSFileVersion addVersionOfItemAtURL:url withContentsOfURL:temporaryFileURL options:NSFileVersionAddingByMoving error:outError])
			ULNotice(@"Can't store version of item '%@' using temporary URL %@: %@", url, temporaryFileURL, *outError);
	}
#endif
	
	// Remove temporary directory
	[fileManager removeItemAtURL:temporaryFolderURL error:NULL];
	
	// Done
	return YES;
}

- (void)notifyError:(NSError *)error forSaveOperation:(ULDocumentSaveOperation)saveOperation
{
	NSParameterAssert(error);

	// Do not notify if we already submitted the same error for the same change date. Make the error visible again after 60s.
	if ([_lastWriteErrorDate isEqualToDate: self.changeDate] && [self.lastWriteError isEqual: error] && (_lastVisibleErrorNotificationDate.timeIntervalSinceNow > -60) && (saveOperation == ULDocumentAutosave))
		return;
		
	_lastVisibleErrorNotificationDate = [NSDate dateWithTimeIntervalSinceNow: 0];
	_lastWriteErrorDate = self.changeDate;
	self.lastWriteError = error;
	
	// Handle error asynchronously to prevent main-queue deadlocks
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		[NSNotificationCenter.defaultCenter postNotificationName:ULDocumentUnhandeledSaveErrorNotification object:self userInfo:@{ULDocumentUnhandeledSaveErrorNotificationErrorKey: error}];
	});
}


#pragma mark -

- (BOOL)readFromFileWrapper:(NSFileWrapper *)fileWrapper error:(NSError **)outError
{
	NSAssert(NO, @"Neither -readFromURL:error: nor -readFromFileWrapper:error: have been overridden!");
	return NO;
}

- (NSFileWrapper *)fileWrapperWithError:(NSError **)outError
{
	NSAssert(NO, @"Neither -writeToURL:forSaveOperation:originalContentsURL:error: nor -fileWrapperWithError: have been overridden!");
	return nil;
}

- (BOOL)readFromURL:(NSURL *)url error:(NSError **)outError
{
	NSFileWrapper *wrapper = [[NSFileWrapper alloc] initWithURL:url options:0 error:outError];
	if (!wrapper)
		return NO;
	
	return [self readFromFileWrapper:wrapper error:outError];
}

- (BOOL)writeToURL:(NSURL *)url forSaveOperation:(ULDocumentSaveOperation)saveOperation originalContentsURL:(NSURL *)originalURL error:(NSError **)outError
{
	NSFileWrapper *wrapper = [self fileWrapperWithError: outError];
	if (!wrapper)
		return NO;
	
	return [wrapper writeToURL:url options:NSFileWrapperWritingWithNameUpdating|NSFileWrapperWritingAtomic originalContentsURL:originalURL error:outError];
}

- (NSURL *)preferredURL
{
	return self.fileURL;
}


#pragma mark - File presentation

- (NSURL *)presentedItemURL
{
	NSAssert(NO, @"Should not be called. Use -filePresenter instead. Implemented for conformance to <NSFilePresenter> protocol only.");
	return nil;
}

- (NSOperationQueue *)presentedItemOperationQueue
{
	NSAssert(NO, @"Should not be called. Use -filePresenter instead. Implemented for conformance to <NSFilePresenter> protocol only.");
	return nil;
}

- (void)relinquishPresentedItemToReader:(void (^)(void (^)(void)))reader
{
	[self disableEditing];
	reader(^{
		[self enableEditing];
	});
}

- (void)relinquishPresentedItemToWriter:(void (^)(void (^reaquirer)(void)))writer
{
	[self disableEditing];
	writer(^{
		[self enableEditing];
	});
}

- (void)savePresentedItemChangesWithCompletionHandler:(void (^)(NSError *errorOrNil))completionHandler
{
	// Perform autosave if state is dirty
	if ([self hasUnsavedChanges]) {
		[self autosaveWithCompletionHandler: ^(BOOL success){
			completionHandler(success ? nil : [NSError errorWithDomain:NSCocoaErrorDomain code:0 userInfo:nil]);
		}];
	}
	// Nothing to save
	else {
		if (completionHandler)
			completionHandler(nil);
	}
}

- (void)accommodatePresentedItemDeletionWithCompletionHandler:(void (^)(NSError *errorOrNil))completionHandler
{
	// Note the close and have the completion handler called. We won't write anything from this point on.
	_deletionPending = YES;
    self.isDeleted = YES;
	if (completionHandler)
		completionHandler(nil);
	
	[_interactionQueue addOperationWithBlock:^{
		[self close];
		self.fileModificationDate = nil;
		self.fileChangeToken = nil;
		self.changeDate = nil;
	}];
}

- (void)presentedItemDidMoveToURL:(NSURL *)newURL
{
	self.fileURL = newURL.ul_URLByResolvingExactFilenames;
	
	// Notify on document change if change token has been changed
	if (![self.changeToken isEqual: [self.class changeTokenForItemAtURL: newURL]])
		[self presentedItemDidChange];
		
	[self didMoveToURL: newURL];
}

- (void)presentedItemDidChange
{
	__weak ULDocument *weakSelf = self;
	
	// Dispatch coordinated read on another queue, to ensure that it cannot block/deadlock other coordinators waiting for confirmation of presentation events of this presenter
	[_interactionQueue addOperationWithBlock:^{
		ULDocument *strongSelf = weakSelf;
		if (!strongSelf)
			return;
		
		ULNoticeBeginURL(strongSelf.fileURL);
		
		[[[NSFileCoordinator alloc] initWithFilePresenter: strongSelf->_presenter] coordinateReadingItemAtURL:strongSelf.fileURL options:NSFileCoordinatorReadingWithoutChanges error:NULL byAccessor:^(NSURL *newURL) {
			newURL = newURL.ul_URLByResolvingExactFilenames;
			
			// Item seems to be still reachable
			if ([newURL checkResourceIsReachableAndReturnError: NULL]) {
				// Revert contents if needed:
				//  - current state in memory is not based upon latest state on disk (tested through fileChangeToken)
				//	- must not be the *same* date, but may be *older* if an older file is reverted!
				//	- recognize URL changes that have not been notified as move, since file presentation doesn't notify filename case changes properly...
				if (strongSelf.documentIsOpen && !([strongSelf.fileChangeToken isEqual: [self.class changeTokenForItemAtURL: newURL]] && [self.fileURL.ul_URLByFastStandardizingPath isEqual:newURL]))
					[strongSelf revertToContentsOfURL:newURL completionHandler: nil];
			}
			
			// Item is gone, close
			else {
				[strongSelf accommodatePresentedItemDeletionWithCompletionHandler: nil];
			}
		}];
		
		ULNoticeEndURL(strongSelf.fileURL);
	}];
}


#pragma mark - Conflict managment

- (void)presentedItemDidGainVersion:(NSFileVersion *)version
{
	if (version.isConflict)
		self.conflictVersions = (self.conflictVersions ? [self.conflictVersions arrayByAddingObject: version] : @[version]);
	else
		self.currentVersion = version;
}

- (void)presentedItemDidLoseVersion:(NSFileVersion *)version
{
	if (version.isConflict) {
		NSMutableArray *versions = [NSMutableArray arrayWithArray: self.conflictVersions];
		[versions removeObject: version];
		self.conflictVersions = (versions.count >= 1 ? [versions copy] : nil);
	}
}

- (void)presentedItemDidResolveConflictVersion:(NSFileVersion *)version
{
	NSMutableArray *versions = [NSMutableArray arrayWithArray: self.conflictVersions];
	[versions removeObject: version];
	self.conflictVersions = (versions.count >= 1 ? [versions copy] : nil);
}

- (void)updateConflictVersions
{
	NSArray *conflicts = (self.fileURL ? [NSFileVersion unresolvedConflictVersionsOfItemAtURL: self.fileURL] : nil);
	conflicts = (conflicts.count >= 1 ? conflicts : nil);
	
	if (self.conflictVersions != conflicts && ![self.conflictVersions isEqualToArray: conflicts])
		self.conflictVersions = conflicts;
}

@end
