# Zone fixes: tutorial progress

Copy zone_fixes beside the game executable and restart once. The existing loader discovers it; mod_settings exposes tutorial_progress. Extend FEATURES in main.gd with one small Node script and one default config key for later fixes. The optional live-lifecycle loader can unload the mod without restart.

Completed lessons remain replayable even if an earlier record is absent. Resume preserves an active lesson or starts the first unfinished one, and rows show Completed. Only records the game actually wrote enter a verified, replaceable checkpoint at user://zone_fixes/progress.cfg. Startup merges that checkpoint with the native profile. A checkpoint never invents completed lessons or reconstructs unwritten history. It is monotonic within a session so a later empty settings object cannot erase known completions. To deliberately reset progress, remove both native completion records and this checkpoint while the game is closed.

Before the fix, a completed lesson after a gap was locked, and pressing native Play cleared an active tutorial. Both failures were reproduced in the actual game. The current contiguous saved profile already read back and stayed unlocked before the fix, so the specific original loss/lock cause remains unconfirmed.

Validated: pure merge/filter/next-track/checkpoint replacement checks; native progress gap, save round trip, active lesson preservation, hot unload restoring callbacks, reload and recovery after clearing the native completion object. Uninstall restores labels and button callbacks. No proprietary game source or personal settings are shipped; flight physics is unchanged. Tested on Godot 4.7.2. Escape navigation is a separate dependent change.
