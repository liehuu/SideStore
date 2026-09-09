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
// so we "conform" RefreshAllAppsWidgetIntent to it in an `unavailable` extension ¯\_(ツ)_/¯
//
// NOTE: This matches upstream SideStore develop exactly. An earlier attempt removed this
// declaration hoping to lower the bundle's `introducedVersion` from 17.2 back to 17.0, but
// binary verification showed `Metadata.appintents/extract.actionsdata` still reports 17.2
// for every AppIntent (including bare ones with no system protocols), i.e. 17.2 is an
// intrinsic annotation for the AppIntent type itself and cannot be lowered from source.
// Keeping upstream's declaration is therefore harmless and keeps us aligned with upstream.
@available(iOS, unavailable)
@available(tvOS, unavailable)
extension RefreshAllAppsWidgetIntent: ForegroundContinuableIntent {}
