# Location Feature — Current State and Find My Investigation

## Status
`imsg-plus location` is now working again on this Mac when Messages is launched with the current rebuilt helper dylib.

What is now confirmed:
- The old direct HTTP / pyicloud-style fallback was dead and has been removed.
- The helper now probes the same app-native Find My stack that Messages itself uses:
  - `FindMyLocateSession`
  - `FindMyLocateObjCWrapper.ObjCBootstrap`
  - `FMFSession` as a secondary/diagnostic path
- The failure was not "wrong private API."
- A targeted key-sync repair sequence changed `findmylocateagent` from:
  - `Found shared key record but no locationId`
  - `No Location Found`
  to:
  - `Received Keys for locationId ... decryptionKey ...`
  - `We may have stale locationId. Requesting new keys`
  - `subscribeAndFetch location counts. ... fromServer 1 ... noLocationFound 0`
  - `cached location for id: ..., sending before subscribe`
- A post-refresh explicit poll against known Find My friend objects/handles was enough to surface the now-repaired cached location to the CLI.
- On April 3, 2026 around 8:24 PM Melbourne time, this exact sequence succeeded:
  - `swift run imsg-plus launch --quiet --dylib /Users/tay-i/Documents/imsg-plus/.build/release/imsg-plus-helper.dylib`
  - `swift run imsg-plus location --json`
  - returned a real location entry for `+61413661735`, including reverse-geocoded address and coordinates

What still needs cleanup:
- `swift run imsg-plus launch --quiet` without `--dylib` can still pick up the stale installed helper at `/usr/local/lib/imsg-plus-helper.dylib`
- that stale helper can make it look like the dead HTTP path still exists, even though the repo build no longer uses it

## What Was Changed

### Removed
- Dead HTTP fallback code in `Sources/IMsgHelper/IMsgInjected.m`
- Old `Security` framework linkage from the dylib build

### Added / Improved
- `FindMyLocateSession` probing in `handleGetLocations`
- `FindMyLocateObjCWrapper.ObjCBootstrap` probing in `handleGetLocations`
- explicit post-refresh polling against known Find My friend objects/handles
- Better location-object extraction and diagnostics
- Honest failure behavior: the helper no longer returns a fake empty success when the Mac has no usable location data
- Extra `init_location` diagnostics to compare `FindMyLocate` and `FMFSession`

### Build change
- `Makefile` now links `CoreLocation` for the dylib build

## Verified Runtime Path

As of April 3, 2026, the following is confirmed from a live injected Messages session:

1. `FindMyLocateSession.getFriendsSharingLocationsWithMeWithCompletion:` returns the shared friend handle.
2. `FindMyLocateObjCWrapper.startRefreshingLocation(...)` successfully runs with the correct internal handle object type.
3. `findmylocateagent` receives that request and logs:
   - `validSecureLocationHandles count: 1`
   - `SubscribeAndFetch received status 200`
   - `Decoded SubscribeAndFetch response successfully`
4. After that, the daemon still logs:
   - `Found shared key record but no locationId`
   - `No Location Found`
   - `getCachedLocations - no location found`

So the proven sequence is:
- friend relationship exists
- app-native Find My refresh path works
- server responds
- local secure-location state is still unusable

## Verified Environment Repair

Later on April 3, 2026, the environment-level key state changed materially after a targeted reset and CKKS resync:

1. Backed up and cleared:
   - `~/Library/Caches/com.apple.findmy.fmfcore`
   - `~/Library/Caches/CloudKit/com.apple.findmy.findmylocateagent`
   - `~/Library/Preferences/com.apple.findmy.findmylocateagent.plist`
2. Restarted `findmylocateagent`
3. Forced keychain / CloudKit reconciliation with:
   - `ckksctl -v SecureObjectSync fetch`
   - `ckksctl -v ProtectedCloudStorage resync`
   - `ckksctl -v SecureObjectSync resync`

After that, `findmylocateagent` logs changed in the important way:
- `Received Keys for locationId ... decryptionKey ...`
- `We may have stale locationId. Requesting new keys`
- `SubscribeAndFetch location counts. requested 1 failed 0 fromServer 1 notOnServer 0 notOnServerButInCache 0 noLocationFound 0`
- `SubscribeAndFetch: cached location for id: ..., sending before subscribe ...`

That is the first verified evidence that this Mac stopped being stuck in the "shared key record but no locationId" state and started holding a usable cached friend location again.

## Verified End-to-End Recovery

After the environment repair, `get_locations` still missed the recovered location until the helper was changed to poll direct per-friend cached-location selectors after refresh, instead of relying only on `cachedFriendsSharingLocationWithMe`.

With that helper change loaded into Messages from the repo build path, the feature worked end-to-end again:

1. Relaunched Messages with:
   - `swift run imsg-plus launch --quiet --dylib /Users/tay-i/Documents/imsg-plus/.build/release/imsg-plus-helper.dylib`
2. Confirmed Messages had loaded:
   - `/Users/tay-i/Documents/imsg-plus/.build/arm64-apple-macosx/release/imsg-plus-helper.dylib`
3. Ran:
   - `swift run imsg-plus location --json`
4. Received a real location payload for `+61413661735`, including:
   - latitude `-37.83014118643288`
   - longitude `144.9925040740517`
   - address `48 Balmain St, Cremorne VIC 3121, Australia`
   - `horizontal_accuracy = 5`
   - `is_old = false`

At the same time, `findmylocateagent` was logging the healthy secure-location path:
- `SubscribeAndFetch: cached location for id: ..., sending before subscribe`
- `subscribeAndFetch location counts. requested 1 failed 0 fromServer 1 ... noLocationFound 0`
- `SubscribeAndFetch - no response data. Returning locations from cache. count 1`

So the final picture is:
- the environment-level secure-location key problem was real
- the CKKS reset/resync repaired it
- the helper needed one more retrieval change to read the recovered cached location reliably
- the feature now works end-to-end in this environment

## Important Clarification

The active "Share My Location From" device being an iPhone is expected and is **not** the blocker here.

We also no longer have evidence that "FMFSession is working but Messages is wrong." The opposite is now true:
- Messages and the helper are hitting the correct Find My path
- the original secure-location failure was upstream of the CLI formatting layer
- after CKKS resync, that upstream daemon-level blocker appears to have recovered

## Key Findings

### 1. `FindMyLocate` is the real path to follow
`FMFSession` alone was not enough to explain what Messages was doing.

Messages has these loaded classes:
- `FindMyLocateSession`
- `FindMyLocateObjCWrapper.ObjCBootstrap`
- `FindMyLocate.Session`
- `FindMyLocate.*`

The wrapper/session methods that matter are:
- `getFriendsSharingLocationsWithMeWithCompletion:`
- `cachedFriendsSharingLocationWithMe`
- `cachedLocationFor:includeAddress:`
- `startUpdatingFriendsWithInitialUpdates:completionHandler:`
- `startRefreshingLocationFor:priority:isFromGroup:reverseGeocode:completionHandler:`

### 2. Shared friend enumeration works
From a live injected Messages run, `FindMyLocateSession.getFriendsSharingLocationsWithMeWithCompletion:` returned one friend:
- `+61413661735`

That means the Mac does know about the sharing relationship.

### 3. Before repair, cached location population still failed
Even after:
- async friend enumeration
- wrapper start-updating call
- wrapper refresh call
- FMF refresh fallback

both of these remain empty/useless:
- `FindMyLocate` cached location lookup
- `FMFSession` cached location lookup

### 4. Before repair, the daemon-side failure narrowed to missing key / locationId state
Recent `findmylocateagent` logs show:
- `Found shared key record but no locationId. Looks like we didn't receive keys`
- `SubscribeAndFetch received status 200`
- `Decoded SubscribeAndFetch response successfully`
- `subscribeAndFetch: No Location Found`

That strongly suggests:
- the share relationship record exists
- the server round-trip is happening
- this Mac still lacks the final secure-location state needed to materialize a usable friend location

### 5. The missing key finally arrived after CKKS resync
After the repair sequence above, newer daemon logs show the missing transition:
- `Received Keys for locationId ... decryptionKey ...`
- `We may have stale locationId. Requesting new keys`
- `fromServer 1`
- `cached location for id: ..., sending before subscribe`

This strongly suggests the real environment bug was not the Messages integration, and not a dead Find My path. It was the local secure-location key / locationId state for the shared friend on this Mac.

## Local State Observed On Disk

### Present before repair
- `~/Library/Caches/com.apple.findmy.fmfcore/FriendCacheData.data`
  - binary plist
  - contains only `signature` and `encryptedData`
- `~/Library/Preferences/com.apple.findmy.findmylocateagent.plist`
  - includes `DataManager::isInitialized = 1`
  - includes `DataManager::lastRefreshClientSuccessDate`
- `~/Library/Caches/CloudKit/com.apple.findmy.findmylocateagent`
  - very sparse
  - no obvious cleartext friend/location model

### Interesting after repair
- After the targeted reset and CKKS resync, the daemon still recovered usable friend-location state even though:
  - `FriendCacheData.data` was not immediately recreated
  - `com.apple.findmy.findmylocateagent.plist` was not immediately recreated
- So the important state is not just those obvious user-cache files.

### Absent / not useful
- no readable cleartext location cache
- no populated Messages-side cached friend list from `cachedFriendsSharingLocationWithMe`
- no usable FMF cached location map

## Current CLI / Helper Behavior

`get_locations` now behaves like this:

1. Try `FindMyLocateSession` / `FindMyLocateObjCWrapper`
2. Try app-native refresh/update calls
3. Fall back to `FMFSession` diagnostics
4. Return an error if no usable location data exists

This is intentional. An empty `[]` was masking the real failure mode.

## Remaining Follow-Ups

1. Make `imsg-plus launch` prefer the current workspace build, or at least warn loudly when it is about to load `/usr/local/lib/imsg-plus-helper.dylib`.
2. Remove or trim temporary location-debug plumbing that is no longer needed now that the path is proven.
3. Add a compact operator runbook so future debugging starts with the right launch path and the CKKS repair sequence if this regresses.

## Files
- `Sources/IMsgHelper/IMsgInjected.m`
- `Makefile`
