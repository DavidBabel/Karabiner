//
//  KeyRemap4MacBook_serverAppDelegate.m
//  KeyRemap4MacBook_server
//
//  Created by Takayama Fumihiko on 09/11/01.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#import <Carbon/Carbon.h>
#import "KeyRemap4MacBook_serverAppDelegate.h"
#import "UserClient_userspace.h"
#include <stdlib.h>
#include "util.h"
#include "server_objc_part.h"
#include "server.hpp"

@implementation KeyRemap4MacBook_serverAppDelegate

@synthesize window;

- (void) threadMain {
  for (;;) {
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    int error = server_process();
    [pool drain];

    if (error) break;
  }

  [NSApp terminate:self];
}

- (void) configThreadMain {
  for (;;) {
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    if (isSessionActive_) {
      set_sysctl_do_reload_xml();
    }
    sleep(1);
    [pool drain];
  }

  [NSThread exit];
}

// ----------------------------------------
- (void) statusBarItemSelected:(id)sender {
  [statusbar_ statusBarItemSelected:sender];
}

// ------------------------------------------------------------
- (void) send_workspacedata_to_kext {
  struct BridgeUserClientStruct bridgestruct;
  bridgestruct.type   = BRIDGE_USERCLIENT_TYPE_SET_WORKSPACEDATA;
  bridgestruct.option = 0;
  bridgestruct.data   = (uintptr_t)(&bridgeworkspacedata_);
  bridgestruct.size   = sizeof(bridgeworkspacedata_);

  [UserClient_userspace synchronized_communication_with_retry:&bridgestruct];
}

- (void) observer_NSWorkspaceDidActivateApplicationNotification:(NSNotification*)notification
{
  NSString* name = [WorkSpaceData getActiveApplicationName];
  if (name) {
    // We ignore our investigation application.
    if (! [name isEqualToString:@"org.pqrs.KeyRemap4MacBook.KeyDump"]) {
      bridgeworkspacedata_.applicationtype = [WorkSpaceData getApplicationType:name];
      [self send_workspacedata_to_kext];

      NSString* observedObject = @"org.pqrs.KeyRemap4MacBook.KeyDump";
      NSDictionary* userInfo = [NSDictionary dictionaryWithObject:name forKey:@"name"];
      [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"applicationChanged" object:observedObject userInfo:userInfo];
    }
  }
}

- (void) observer_kTISNotifySelectedKeyboardInputSourceChanged:(NSNotification*)notification
{
  NSString* name = [WorkSpaceData getTISPropertyInputModeID];
  if (name) {
    [WorkSpaceData getInputMode:name
               output_inputmode:(&(bridgeworkspacedata_.inputmode))
         output_inputmodedetail:(&(bridgeworkspacedata_.inputmodedetail))];
    [self send_workspacedata_to_kext];

    NSString* observedObject = @"org.pqrs.KeyRemap4MacBook.KeyDump";
    NSDictionary* userInfo = [NSDictionary dictionaryWithObject:name forKey:@"name"];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"inputSourceChanged" object:observedObject userInfo:userInfo];
  }
}

// ------------------------------------------------------------
- (void) send_remapclasses_initialize_vector_to_kext {
  NSArray* a = [[ConfigXMLParser getInstance] remapclasses_initialize_vector];
  if (! a) return;

  size_t size = [a count] * sizeof(uint32_t);
  uint32* data = (uint32*)(malloc(size));
  uint32* p = data;
  for (NSNumber* number in a) {
    *p++ = [number unsignedIntValue];
  }

  struct BridgeUserClientStruct bridgestruct;
  bridgestruct.type   = BRIDGE_USERCLIENT_TYPE_SET_REMAPCLASSES_INITIALIZE_VECTOR;
  bridgestruct.option = 0;
  bridgestruct.data   = (uintptr_t)(data);
  bridgestruct.size   = size;

  [UserClient_userspace synchronized_communication_with_retry:&bridgestruct];
}

- (void) send_essential_config_to_kext {
  NSArray* essential_config = [[PreferencesManager getInstance] essential_config];
  if (! essential_config) {
    NSLog(@"[WARNING] essential_config == nil");
    return;
  }

  int32_t value[BRIDGE_ESSENTIAL_CONFIG_INDEX__END__];
  size_t i = 0;
  for (NSNumber* number in essential_config) {
    if (i >= sizeof(value) / sizeof(value[0])) {
      NSLog(@"[WARNING] Too many items in essential_config");
      return;
    }

    value[i] = [number intValue];
    ++i;
  }

  struct BridgeUserClientStruct bridgestruct;
  bridgestruct.type   = BRIDGE_USERCLIENT_TYPE_SET_ESSENTIAL_CONFIG;
  bridgestruct.option = 0;
  bridgestruct.data   = (uintptr_t)(value);
  bridgestruct.size   = sizeof(value);

  [UserClient_userspace synchronized_communication_with_retry:&bridgestruct];
}

// ------------------------------------------------------------
static void observer_IONotification(void* refcon, io_iterator_t iterator) {
  NSLog(@"observer_IONotification");

  KeyRemap4MacBook_serverAppDelegate* self = refcon;
  if (! self) {
    NSLog(@"[ERROR] observer_IONotification refcon == nil\n");
    return;
  }

  for (;;) {
    io_object_t obj = IOIteratorNext(iterator);
    if (! obj) break;

    IOObjectRelease(obj);
  }
  // Do not release iterator.

  // = Documentation of IOKit =
  // - Introduction to Accessing Hardware From Applications
  //   - Finding and Accessing Devices
  //
  // In the case of IOServiceAddMatchingNotification, make sure you release the iterator only if you’re also ready to stop receiving notifications:
  // When you release the iterator you receive from IOServiceAddMatchingNotification, you also disable the notification.

  [UserClient_userspace refresh_connection];
  [self send_remapclasses_initialize_vector_to_kext];
  [self send_essential_config_to_kext];
  [self send_workspacedata_to_kext];
}

- (void) unregisterIONotification {
  if (notifyport_) {
    if (loopsource_) {
      CFRunLoopSourceInvalidate(loopsource_);
      loopsource_ = nil;
    }
    IONotificationPortDestroy(notifyport_);
    notifyport_ = nil;
  }
}

- (void) registerIONotification {
  [self unregisterIONotification];

  notifyport_ = IONotificationPortCreate(kIOMasterPortDefault);
  if (! notifyport_) {
    NSLog(@"[ERROR] IONotificationPortCreate failed\n");
    return;
  }

  // ------------------------------------------------------------
  NSMutableDictionary* match = [NSMutableDictionary dictionaryWithObject:@"org_pqrs_driver_KeyRemap4MacBook" forKey:@"IOMatchCategory"];

  // ----------------------------------------------------------------------
  io_iterator_t it;
  kern_return_t kernResult;

  [match retain]; // for kIOMatchedNotification
  kernResult = IOServiceAddMatchingNotification(notifyport_,
                                                kIOMatchedNotification,
                                                (CFMutableDictionaryRef)(match),
                                                &observer_IONotification,
                                                self,
                                                &it);
  if (kernResult != kIOReturnSuccess) {
    NSLog(@"[ERROR] IOServiceAddMatchingNotification failed");
    return;
  }
  observer_IONotification(self, it);

  // ----------------------------------------------------------------------
  loopsource_ = IONotificationPortGetRunLoopSource(notifyport_);
  if (! loopsource_) {
    NSLog(@"[ERROR] IONotificationPortGetRunLoopSource failed");
    return;
  }
  CFRunLoopAddSource(CFRunLoopGetCurrent(), loopsource_, kCFRunLoopDefaultMode);
}

// ------------------------------------------------------------
- (void) observer_ConfigXMLReloaded:(NSNotification*)notification {
  [self send_remapclasses_initialize_vector_to_kext];
  [self send_essential_config_to_kext];
  set_sysctl_do_reset();
  set_sysctl_do_reload_xml();
}

- (void) observer_ConfigListChanged:(NSNotification*)notification {
  [statusbar_ refresh];
}

- (void) observer_PreferencesChanged:(NSNotification*)notification {
  set_sysctl_do_reload_only_config();
  [self send_essential_config_to_kext];
}

// ------------------------------------------------------------
- (void) observer_NSWorkspaceSessionDidBecomeActiveNotification:(NSNotification*)notification
{
  NSLog(@"observer_NSWorkspaceSessionDidBecomeActiveNotification");

  isSessionActive_ = YES;

  // Note: The console user is "real login user" or "loginwindow",
  //       when NSWorkspaceSessionDidBecomeActiveNotification, NSWorkspaceSessionDidResignActiveNotification are called.
  [[StatusWindow getInstance] resetStatusMessage];

  set_sysctl_do_reset();
  set_sysctl_do_reload_xml();

  [self registerIONotification];
}

- (void) observer_NSWorkspaceSessionDidResignActiveNotification:(NSNotification*)notification
{
  NSLog(@"observer_NSWorkspaceSessionDidResignActiveNotification");

  isSessionActive_ = NO;

  // Note: The console user is "real login user" or "loginwindow",
  //       when NSWorkspaceSessionDidBecomeActiveNotification, NSWorkspaceSessionDidResignActiveNotification are called.
  [[StatusWindow getInstance] resetStatusMessage];

  set_sysctl_do_reset();

  [self unregisterIONotification];
  [UserClient_userspace disconnect_from_kext];
}

// ------------------------------------------------------------
- (void) applicationDidFinishLaunching:(NSNotification*)aNotification {
  isSessionActive_ = YES;
  registerServerObjcPart(serverobjcpart_);

  [[StatusWindow getInstance] resetStatusMessage];
  [statusbar_ refresh];

  set_sysctl_do_reset();

  [self registerIONotification];

  // ------------------------------------------------------------
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                         selector:@selector(observer_NSWorkspaceDidActivateApplicationNotification:)
                                                             name:NSWorkspaceDidActivateApplicationNotification
                                                           object:nil];

  [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                      selector:@selector(observer_kTISNotifySelectedKeyboardInputSourceChanged:)
                                                          name:(NSString*)(kTISNotifySelectedKeyboardInputSourceChanged)
                                                        object:nil];

  // ------------------------------
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                         selector:@selector(observer_NSWorkspaceSessionDidBecomeActiveNotification:)
                                                             name:NSWorkspaceSessionDidBecomeActiveNotification
                                                           object:nil];

  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                         selector:@selector(observer_NSWorkspaceSessionDidResignActiveNotification:)
                                                             name:NSWorkspaceSessionDidResignActiveNotification
                                                           object:nil];

  // ------------------------------
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(observer_ConfigXMLReloaded:) name:@"ConfigXMLReloaded" object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(observer_ConfigListChanged:) name:@"ConfigListChanged" object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(observer_PreferencesChanged:) name:@"PreferencesChanged" object:nil];

  // ------------------------------------------------------------
  [self observer_NSWorkspaceDidActivateApplicationNotification:nil];
  [self observer_kTISNotifySelectedKeyboardInputSourceChanged:nil];

  // ------------------------------------------------------------
  [NSThread detachNewThreadSelector:@selector(threadMain)
                           toTarget:self
                         withObject:nil];
  [NSThread detachNewThreadSelector:@selector(configThreadMain)
                           toTarget:self
                         withObject:nil];

  // ------------------------------------------------------------
  // Kick updater
  [[NSWorkspace sharedWorkspace] launchApplication:@"/Library/org.pqrs/KeyRemap4MacBook/app/KeyRemap4MacBook.app"];
}

- (void) applicationWillTerminate:(NSNotification*)aNotification {
  NSLog(@"applicationWillTerminate");
  set_sysctl_do_reset();
}

@end
