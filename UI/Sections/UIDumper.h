#pragma once

#import "UIInternal.h"

@interface UserInterface (Dumper)
- (void)dumperTapped;
- (void)zs_buildDumperFullScreenPanelIfNeeded;
- (void)zs_openDumperFullScreenPanel;
- (void)zs_endDumperSession;
- (void)zs_closeDumperFullScreenPanelTapped;
- (void)zs_dumperOptionChanged:(UISwitch *)toggle;
- (void)zs_dumperRunTapped;
- (void)zs_dumperDiffTapped;
- (void)zs_dumperShareTapped;
- (void)zs_dumperResetTapped;
- (void)zs_dumperSyncControls;
- (void)zs_dumperAppendLog:(NSString *)line;
@end
