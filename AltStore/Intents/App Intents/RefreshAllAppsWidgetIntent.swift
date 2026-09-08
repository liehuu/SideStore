//
//  RefreshAllAppsWidgetIntent.swift
//  AltStore
//
//  Created by Riley Testut on 8/18/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import AppIntents

@available(iOS 17, tvOS 17, *)
struct RefreshAllAppsWidgetIntent: AppIntent, ProgressReportingIntent
{
    static var title: LocalizedStringResource { "Refresh Apps via Widget" }
    static var isDiscoverable: Bool { false } // Don't show in Shortcuts or Spotlight.
    
    #if !WIDGET_EXTENSION
    private let intent = RefreshAllAppsIntent(presentsNotifications: true)
    #endif
    
    func perform() async throws -> some IntentResult
    {
    #if !WIDGET_EXTENSION
        do
        {
            _ = try await self.intent.perform()
        }
        catch
        {
            debugLog("Failed to refresh apps via widget. \(error)")
        }
    #endif
        
        return .result()
    }
}

// To ensure this intent is handled by the app itself (and not widget extension)
// we need to conform to either `ForegroundContinuableIntent` or `AudioPlaybackIntent`.
// https://mastodon.social/@mgorbach/110812347476671807
//
// Unfortunately `ForegroundContinuableIntent` is marked as unavailable in app extensions,
// so upstream "conformed" RefreshAllAppsWidgetIntent to it in an `unavailable` extension.
//
// That declaration has been REMOVED. Reason: even though `@available(iOS, unavailable)`
// means the conformance never actually exists at runtime on iOS, the App Intents metadata
// extractor still records `com.apple.link.systemProtocol.ForegroundContinuable` in
// `Metadata.appintents/extract.actionsdata`. `ForegroundContinuableIntent` folds into the
// iOS 17.2-only `.foreground(.dynamic)` mode, which bumps the *whole bundle's* action
// `introducedVersion` to 17.2 — so Shortcuts reports "This action is not supported on
// iPhone" for every SideStore action on iOS 17.0/17.1.
// See https://github.com/SideStore/SideStore/issues/968 and #1141.
