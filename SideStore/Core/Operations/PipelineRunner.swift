//
//  PipelineRunner.swift
//  AltStore
//
//  Created by Magesh K on 8/3/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import SideSign


protocol PipelineProgress: Sendable{
    func progress(for operation: AppOperation) -> Progress?
    func set(_ progress: Progress?, for operation: AppOperation)
}
protocol PipelineExecutionContext: AnyObject, Sendable {
    var isActivelyManagingAnyApp: Bool { get }
}
protocol PipelineErrorLogger: AnyObject, Sendable {
    func log(_ error: Error, operation: LoggedError.Operation, app: AppProtocol)
    func getMappedError(for operation: AppOperation, error: Error) -> Error
}


// Pipeline based App Operations
final class PipelineRunner: Sendable
{
    let progress: PipelineProgress
    let context: PipelineExecutionContext
    let logger: PipelineErrorLogger
    let defaultEntitlements: [ALTEntitlement: any Sendable]
    
    init(progress: PipelineProgress,
         context: PipelineExecutionContext,
         logger: PipelineErrorLogger,
         defaultEntitlements: [ALTEntitlement: any Sendable] = [:])
    {
        self.progress = progress
        self.context = context
        self.logger = logger
        self.defaultEntitlements = defaultEntitlements
    }
    
    @discardableResult
    func performSingleOperation(_ operation: AppOperation,
                                handler: PipelineExecutionHandler,
                                context: StandaloneOperationContext,
                                completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> RefreshGroup
    {
        let group = RefreshGroup(context: context)
        group.completionHandler = { (results) in
            do
            {
                guard let result = results.values.first else { throw group.context.error ?? OperationError.unknown() }
                let installedApp = try result.get()
                completionHandler(.success(installedApp))
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
        debugLog("[AppManager] performSingleOperation started for: \(operation.bundleIdentifier)")
        group.activeTask = Task.detached {
            do {
                debugLog("[AppManager] performSingleOperation executing task for: \(operation.bundleIdentifier)")
                try await self.perform([operation], handler: handler, group: group)
            } catch {
                debugLog("[AppManager] performSingleOperation task failed for: \(operation.bundleIdentifier) with error: \(error)")
                completionHandler(.failure(error))
            }
        }
        
        return group
    }
    
    func performVoidOperation(_ operation: AppOperation,
                              handler: PipelineExecutionHandler,
                              context: StandaloneOperationContext,
                              completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        self.performSingleOperation(operation, handler: handler, context: context) { (result) in
            switch result {
            case .success:
                completionHandler(.success(()))
            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
    }
    
    @discardableResult
    func perform(_ operations: [AppOperation],
                 handler: PipelineExecutionHandler,
                 group: RefreshGroup) async throws -> RefreshGroup
    {
        let operations = operations.filter { progress.progress(for: $0) == nil || progress.progress(for: $0)?.isCancelled == true }
        guard !operations.isEmpty else { throw OperationError.cancelled }
        
        let backgroundTaskID = await MainActor.run {
            var taskID = UIBackgroundTaskIdentifier.invalid
            taskID = UIApplication.shared.beginBackgroundTask(withName: "com.altstore.AppManager.perform") {
                UIApplication.shared.endBackgroundTask(taskID)
            }
            return taskID
        }
        
        // Disable the idleTimeout
        await MainActor.run {
            if !UIApplication.shared.isIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.isIdleTimeoutDisableEnabled
            }
        }
        
        defer {
            for operation in operations {                   // Clean up progress for all operations
                progress.set(nil, for: operation)
            }
            if let error = group.context.error {            // Mark error as-is
                for operation in operations {
                    group.set(.failure(error), forAppWithBundleIdentifier: operation.bundleIdentifier)
                }
            }
            
            
            // Re-enable idleTimeout if no more actions are running and end background task
            Task { @MainActor in
                if UIApplication.shared.isIdleTimerDisabled && !context.isActivelyManagingAnyApp {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
            }
        }
        
        /* Minimuxer Readiness Check */
        if !CellularRefreshManager.shared.isEnabled,
           case .failure(let error) = await isMinimuxerReady()
        {
            let opError = error.asOperationError
            group.context.error = opError
            throw opError
        }
        
        group.progress.totalUnitCount = Int64(operations.count * 100)
        group.progress.completedUnitCount = 1
        
        for operation in operations
        {
            let progress = Progress.discreteProgress(totalUnitCount: 100)
            self.progress.set(progress, for: operation)
            group.progress.addChild(progress, withPendingUnitCount: 100)
        }
        
        
        /* Preflight SideStore specific validations */
        let unhandledOperations = operations.filter { operation in
            let isSideStore = (operation.app as? ALTApplication)?.isAltStoreApp == true ||
                               operation.bundleIdentifier.isAltStoreAppID
            
            if isSideStore {
                return handler.preflightChecksHandler.isResignActive == true
            }
            return true
        }
        
        do {
            let validateOp = try PreflightChecksOperation(
                operations: unhandledOperations,
                handler: handler.preflightChecksHandler,
                context: group.context
            )
            try await validateOp.execute()
        } catch {
            group.context.error = error
            throw error
        }
        
        
        // run the operation pipeline
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            for operation in operations {
                taskGroup.addTask {
                    try await self.performOperation(for: operation, handler: handler, group: group)
                }
            }
            while let _ = try await taskGroup.next() {}
        }
        await MainActor.run {
            group.completionHandler?(group.results)
        }
        
        return group
    }
    
    func performOperation(for operation: AppOperation, handler: PipelineExecutionHandler, group: RefreshGroup) async throws {
        debugLog("[AppManager] performOperation: Starting execution for app: \(operation.bundleIdentifier)")
        defer {
            // request update view context's in-mem coredata caches (coz we worked so far on bg context)
            Task { @MainActor in
                DatabaseManager.shared.viewContext.processPendingChanges()
            }
        }
        do {
            let result = try await self.performPipeline(for: operation, handler: handler, group: group)
            progress.set(nil, for: operation)
            debugLog("[AppManager] performOperation: completed successfully. progress was reset for installedApp: \(result.bundleIdentifier)")
            
            // persist the result
            let bundleID = result.bundleIdentifier
            let dbContext = group.context.dbBackgroundContext
            do {
                try await dbContext.perform {
                    let hasChanges = dbContext.hasChanges
                    if hasChanges {
                        try dbContext.save()
                    }
                    debugLog("[AppManager] performOperation: Context changes were saved for installedApp: \(bundleID)")
                }
            } catch {
                debugLog("[AppManager] perform(): Failed to save InstalledApp to database. \(error.localizedDescription)")
            }
            
            group.set(.success(result), forAppWithBundleIdentifier: bundleID)
            debugLog("[AppManager] performOperation: Execution SUCCESS for app: \(operation.bundleIdentifier)")
            
            debugLog("[AppManager] performOperation: Reloading widget timelines...")
            await WidgetDataManager.publishCurrentInstalledApps(in: dbContext)
            debugLog("[AppManager] performOperation: Reloading COMPLETE for widget timelines.")
            
            if result.bundleIdentifier == StoreApp.altstoreAppID {
                let context = StandaloneOperationContext(steps: .scheduleExpirationWarningNotification, dbBackgroundContext: group.context.dbBackgroundContext)
                let scheduleNotifOp = try ScheduleExpirationWarningNotificationOperation(
                    installedApp: result,
                    context: context
                )
                try await scheduleNotifOp.execute()
            }
            await CellularRefreshManager.shared.turnOnDataIfNeeded()
        } catch {
            await CellularRefreshManager.shared.turnOnDataIfNeeded()
            progress.set(nil, for: operation)
            
            if Task.isCancelled {
                debugLog("[AppManager] performOperation: Execution CANCELLED for app: \(operation.bundleIdentifier)")
            } else {
                debugLog("[AppManager] performOperation: Execution FAILED for app: \(operation.bundleIdentifier) with error: \(error.localizedDescription)")
            }
            
            let mappedError = logger.getMappedError(for: operation, error: error)
            
            logger.log(error, operation: operation.loggedErrorOperation, app: operation.app)
            
            group.set(.failure(mappedError), forAppWithBundleIdentifier: operation.bundleIdentifier)
        }
    }
    
    private func performPipeline(for operation: AppOperation, handler: PipelineExecutionHandler, group: RefreshGroup) async throws -> InstalledApp
    {
        let pipelineSteps = PipelineStepDefinition.steps(for: operation)
        
        // ── Cross-context safety ──────────────────────────────────────────
        // InstalledApp objects carried by `operation` may belong to a different
        // (possibly deallocated) NSManagedObjectContext — this happens every
        // time the pipeline is entered from a background-refresh / Shortcuts
        // path: IntentHandler and RefreshAllAppsIntent both call
        // `newBackgroundContext()` to fetch apps, then pass them to
        // `AppManager.backgroundRefresh`, which creates *another*
        // `newBackgroundContext()` for the StandaloneOperationContext.
        //
        // Once the original context is released, accessing @NSManaged
        // properties (bundleIdentifier, fileURL, …) returns empty values.
        // That corrupts every downstream path:
        //   bundleID="" → fileURL=".../Apps//App.app" → ALTApplication=nil
        //   → "VerifyCertificateOperation: targetAppBundle is missing in context."
        //
        // Re-fetch the InstalledApp on the pipeline's own dbBackgroundContext
        // before extracting any properties, so all @NSManaged reads happen on
        // a context that stays alive for the entire pipeline lifetime.
        let dbBackgroundContext = group.context.dbBackgroundContext
        let resolvedApp: InstalledApp? = await dbBackgroundContext.perform {
            guard let installedApp = operation.app as? InstalledApp else { return nil }
            return dbBackgroundContext.object(with: installedApp.objectID) as? InstalledApp
        }
        
        // Read bundleIdentifier on the owning context (never trust it outside one).
        let resolvedBundleID: String
        if let resolvedApp {
            resolvedBundleID = await dbBackgroundContext.perform { resolvedApp.bundleIdentifier }
        } else {
            // Non-Core-Data app (e.g. ALTApplication from a fresh download).
            resolvedBundleID = operation.bundleIdentifier
        }
        
        let context = InstallAppOperationContext(
            pipelineSteps: pipelineSteps,
            bundleIdentifier: resolvedBundleID,
            standaloneContext: group.context,
            sharedContext: group.sharedContext,
            handler: handler,
            additionalEntitlements: defaultEntitlements,
            activeSigningCertificate: CertificateManager.shared.activeCertificate?.certificate
        )
        
        if case .install(_, let customID) = operation { context.customBundleIdentifier  = customID }
        if case .update(_,  let customID) = operation { context.customBundleIdentifier  = customID }
        if case .resign(_,  let mode)     = operation { context.alternateIconMode       = mode }
        
        if let app = resolvedApp {
            // Read all @NSManaged properties synchronously on the owning context.
            var resolvedFileURL: URL!
            var resolvedUseMainProfile = false
            var resolvedCustomBundleID: String?
            dbBackgroundContext.performAndWait {
                resolvedFileURL = app.fileURL
                resolvedUseMainProfile = app.useMainProfile
                resolvedCustomBundleID = app.customBundleIdentifier
            }
            context.targetAppBundle = ALTApplication(fileURL: resolvedFileURL)
            context.useMainProfile = resolvedUseMainProfile
            context.customBundleIdentifier = resolvedCustomBundleID
            context.installedApp = app
        }
        
        context.beginInstallationHandler = { (installedApp) in
            group.beginInstallationHandler?(installedApp)
        }
        
        var downloadingApp = operation.app
        if let installedApp = resolvedApp {
            var resolvedFileURL: URL!
            var resolvedStoreApp: StoreApp?
            dbBackgroundContext.performAndWait {
                resolvedFileURL = installedApp.fileURL
                resolvedStoreApp = installedApp.storeApp
            }
            if case .resign = operation { downloadingApp = installedApp }
            else if let storeApp = resolvedStoreApp, !FileManager.default.fileExists(atPath: resolvedFileURL.path) {
                downloadingApp = storeApp
            }
        }
        
        let permissionReviewMode: PermissionReviewMode
        switch operation {
            case .install: permissionReviewMode = .all
            case .update: permissionReviewMode = .added
            default: permissionReviewMode = .none
        }
        
        let permissionsMode = UserDefaults.standard.permissionCheckingDisabled ? .none : permissionReviewMode
        let operationProgress = progress.progress(for: operation)
        return try await PipelineExecutor.shared.executePipeline(
            steps: pipelineSteps,
            context: context,
            operation: operation,
            group: group,
            downloadingApp: downloadingApp,
            permissionsMode: permissionsMode,
            operationProgress: operationProgress
        )
    }
}


