//
//  RefreshAllAppsIntent.swift
//  AltStore
//
//  Created by Riley Testut on 8/18/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import AppIntents
import WidgetKit
import AltStoreCore

// Shouldn't conform types we don't own to protocols we don't own, so make custom
// NSError subclass that conforms to CustomLocalizedStringResourceConvertible instead.
//
// Would prefer to just conform ALTLocalizedError to CustomLocalizedStringResourceConvertible,
// but that can't be done without raising minimum version for ALTLocalizedError to iOS 16 :/
@available(iOS 16, *)
class IntentError: NSError, CustomLocalizedStringResourceConvertible
{
    var localizedStringResource: LocalizedStringResource {
        return "\(self.localizedDescription)"
    }
    
    init(_ error: some Error)
    {
        let serializedError = (error as NSError).sanitizedForSerialization()
        super.init(domain: serializedError.domain, code: serializedError.code, userInfo: serializedError.userInfo)
    }
    
    required init?(coder: NSCoder)
    {
        super.init(coder: coder)
    }
}

@available(iOS 17.0, *)
extension RefreshAllAppsIntent
{
    private actor OperationActor
    {
        private(set) var operation: BackgroundRefreshAppsOperation?
        
        func set(_ operation: BackgroundRefreshAppsOperation?)
        {
            self.operation = operation
        }
    }
}

// NOTE: This intent intentionally does NOT conform to `CustomIntentMigratedAppIntent`.
//
// Background: SideStore still ships the legacy SiriKit intent `RefreshAllIntent`
// (AltStore/Intents/Legacy/Intents.intentdefinition + `INIntentsSupported` in Info.plist,
// handled by `IntentHandler` via `AppDelegate.application(_:handlerFor:)`). That is the exact
// code path 0.5.8 used, and it works on iOS 17.0/17.1.
//
// Conforming to `CustomIntentMigratedAppIntent` makes this App Intent *take over* the
// `RefreshAllIntent` identity. The App Intents metadata extractor (xcode-tools 17C519/17E202,
// `Metadata.appintents` schema 3.0) stamps **every** App Intent with
// `availabilityAnnotations.LNPlatformNameIOS.introducedVersion = 17.2` — even bare ones with no
// system protocols at all (verified against the widget extension's `PaginationIntent`, which has
// `systemProtocols: []` and is still 17.2). So on iOS 17.0/17.1 the migrated action resolves to
// this App Intent, is unavailable, and Shortcuts reports
// "This action is not supported on iPhone" — while the perfectly good SiriKit intent is shadowed.
//
// Dropping the migration conformance leaves the two as independent actions:
//   • iOS < 17.2 → App Intent unavailable, Shortcuts falls back to the SiriKit
//     `RefreshAllIntent` (0.5.8 behaviour) and refresh works again.
//   • iOS >= 17.2 → this App Intent is used (and the auto-shortcut resolves to it).
// Old shortcuts that referenced `RefreshAllIntent` keep working too, since they now resolve
// back to the SiriKit intent.
@available(iOS 17.0, *)
struct RefreshAllAppsIntent: AppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    static var title: LocalizedStringResource = "Refresh All Apps"
    static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")
    
    static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }
    
    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps",
                subtitle: ""
            )
        }
    }
    
    let presentsNotifications: Bool
    
    private let operationActor = OperationActor()
    
    init(presentsNotifications: Bool)
    {
        self.presentsNotifications = presentsNotifications
        
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }
    
    init()
    {
        self.init(presentsNotifications: false)
    }
    
    func perform() async throws -> some IntentResult & ProvidesDialog
    {
        do
        {
            // Request foreground execution at ~27 seconds to gracefully handle timeout.
            let deadline: ContinuousClock.Instant = .now + .seconds(27)
            
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                taskGroup.addTask {
                    try await self.refreshAllApps()
                }
                
                taskGroup.addTask {
                    try await Task.sleep(until: deadline)
                    throw OperationError.timedOut
                }
                
                do
                {
                    for try await _ in taskGroup.prefix(1)
                    {
                        // We only care about the first child task to complete.
                        taskGroup.cancelAll()
                        break
                    }
                }
                catch OperationError.timedOut
                {
                    // We took too long to finish and return the final result,
                    // so we'll now present a normal notification when finished.
                    let operation = await self.operationActor.operation
                    operation?.presentsFinishedNotification = true
                    
                    try await self.requestToContinueInForeground()
                }
            }
            
            return .result(dialog: "All apps have been refreshed.")
        }
        catch
        {
            let intentError = IntentError(error)
            throw intentError
        }
    }
}

@available(iOS 17.0, *)
private extension RefreshAllAppsIntent
{
    func refreshAllApps() async throws
    {
        if !DatabaseManager.shared.isStarted
        {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DatabaseManager.shared.start { error in
                    if let error
                    {
                        continuation.resume(throwing: error)
                    }
                    else
                    {
                        continuation.resume()
                    }
                }
            }
        }
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let installedApps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }
        
        try await withCheckedThrowingContinuation { continuation in
            let operation = AppManager.shared.backgroundRefresh(installedApps, presentsNotifications: self.presentsNotifications) { (result) in
                do
                {
                    let results = try result.get()
                    
                    for (_, result) in results
                    {
                        guard case let .failure(error) = result else { continue }
                        throw error
                    }
                    
                    continuation.resume()
                }
                catch ~RefreshErrorCode.noInstalledApps
                {
                    continuation.resume()
                }
                catch
                {
                    continuation.resume(throwing: error)
                }
            }
            
            operation.ignoresServerNotFoundError = false
            
            self.progress.addChild(operation.progress, withPendingUnitCount: 1)
            
            Task {
                await self.operationActor.set(operation)
            }
        }
    }
}
