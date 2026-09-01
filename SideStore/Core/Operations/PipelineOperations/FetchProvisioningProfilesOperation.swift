//
//  FetchProvisioningProfilesOperation.swift
//  AltStore
//
//  Created by Riley Testut on 2/27/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import SideSign
import CoreData

class FetchProvisioningProfilesOperation: BasePipelineOperation<InstallAppOperationContext, [String: ALTProvisioningProfile]>, @unchecked Sendable {
    // this class is abstract or shouldn't be extended outside, use the subclasses
    
    override func execute(parentProgress: Progress?) async throws -> [String: ALTProvisioningProfile] {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[FetchProvisioningProfilesOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[FetchProvisioningProfilesOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        if let error = self.context.error {
            self.debugLog("[FetchProvisioningProfiles] Context has pre-existing error: \(error.localizedDescription)")
            throw error
        }
        
        guard let team = self.context.authenticatedContext.team,
              let session = self.context.authenticatedContext.session else {
            self.debugLog("[FetchProvisioningProfiles] Missing parameters: team=\(String(describing: self.context.authenticatedContext.team)), session=\(String(describing: self.context.authenticatedContext.session))")
            throw OperationError.invalidParameters("FetchProvisioningProfilesOperation.main: self.context.authenticatedContext.team or self.context.authenticatedContext.session is nil")
        }
        
        guard let targetAppBundle = self.context.targetAppBundle else {
            self.debugLog("[FetchProvisioningProfiles] App not found in context.")
            throw OperationError.appNotFound(name: nil)
        }
        
        let effectiveBundleId = self.context.targetBundleIdentifier
        self.debugLog("[FetchProvisioningProfiles] Executing for app \(targetAppBundle.bundleIdentifier), targetBundleID: \(effectiveBundleId), team: \(team.identifier), useMainProfile: \(self.context.useMainProfile)")
        
        self.setProgress(10)

        self.debugLog("[FetchProvisioningProfiles] Preparing main provisioning profile for \(targetAppBundle.bundleIdentifier)...")
        let profile = try await self.prepareProvisioningProfile(for: targetAppBundle, parentAppBundle: nil, team: team, session: session)
        self.debugLog("[FetchProvisioningProfiles] Main profile prepared successfully for \(effectiveBundleId), expiration: \(String(describing: profile.expirationDate))")
        
        var profiles = [effectiveBundleId: profile]
        
        if !self.context.useMainProfile && !targetAppBundle.appExtensions.isEmpty {
            self.setProgress(50)
            self.debugLog("[FetchProvisioningProfiles] Preparing profiles for \(targetAppBundle.appExtensions.count) app extensions...")
            try await withThrowingTaskGroup(of: (String, ALTProvisioningProfile).self) { group in
                for appExtension in targetAppBundle.appExtensions {
                    group.addTask {
                        self.verboseLog("[FetchProvisioningProfiles] Preparing extension profile for \(appExtension.bundleIdentifier)...")
                        let extProfile = try await self.prepareProvisioningProfile(for: appExtension, parentAppBundle: targetAppBundle, team: team, session: session)
                        // Use customized bundle ID if applicable
                        let updatedExtensionBundleId = appExtension.bundleIdentifier.replacingOccurrences(of: targetAppBundle.bundleIdentifier, with: effectiveBundleId)
                        self.verboseLog("[FetchProvisioningProfiles] Extension profile prepared for \(updatedExtensionBundleId)")
                        return (updatedExtensionBundleId, extProfile)
                    }
                }
                
                var completedCount = 0
                let totalExtensions = targetAppBundle.appExtensions.count
                let startProgress = self.progress.completedUnitCount
                let endProgress: Int64 = 100
                let range = endProgress - startProgress
                
                for try await (bundleId, extProfile) in group {
                    profiles[bundleId] = extProfile
                    self.debugLog("[FetchProvisioningProfiles] Added profile for extension bundle ID: \(bundleId)")
                    completedCount += 1
                    if range > 0 {
                        let percent = startProgress + Int64(Double(completedCount) / Double(totalExtensions) * Double(range))
                        self.setProgress(percent)
                    }
                }
            }
        } else {
            self.setProgress(100)
        }
        
        self.debugLog("[FetchProvisioningProfiles] Total profiles prepared: \(profiles.count) -> keys: \(Array(profiles.keys))")
        return profiles
    }

    
    internal func fetchProvisioningProfile(for appID: ALTAppID, targetAppBundle: ALTApplication, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTProvisioningProfile {
        verboseLog(targetAppBundle.dumpMachOInfo())
        debugLog("[FetchProvisioningProfiles] Fetching existing provisioning profile to get its identifier for App ID \(appID.bundleIdentifier).")
        let profile = try await ALTAppleAPI.shared.fetchProvisioningProfile(for: appID, deviceType: .iphone, team: team, session: session)
        return profile
    }
    
    private func fetchPreferredBundleID(for targetAppBundle: ALTApplication, team: ALTTeam) async throws -> String? {
        await DatabaseManager.shared.persistentContainer.performBackgroundTask { [weak self] (context) -> String? in
            guard let self else { return nil }
            return preferredBundleID(for: targetAppBundle, team: team, in: context)
        }
    }
    
    private func preferredBundleID(for targetAppBundle: ALTApplication, team: ALTTeam, in context: NSManagedObjectContext) -> String? {
        let target = self.context.targetBundleIdentifier
        let predicate = NSPredicate(
            format: "(%K == %@) OR (%K == %@)",
            #keyPath(InstalledApp.customBundleIdentifier), target,
            #keyPath(InstalledApp.resignedBundleIdentifier), target
        )
        guard let installedApp = InstalledApp.first(satisfying: predicate, in: context) else {
            self.verboseLog("[FetchProvisioningProfiles] No existing InstalledApp found for target: \(target)")
            return nil
        }
        
        // Teams match if installedApp.team has same identifier as team (or team is nil)
        // AND installedApp.resignedBundleIdentifier actually contains the team's identifier.
        let teamsMatch = (installedApp.team?.identifier == team.identifier || installedApp.team == nil)
                         && installedApp.resignedBundleIdentifier.contains(team.identifier)
        
        self.verboseLog("[FetchProvisioningProfiles] preferredBundleID check: app=\(targetAppBundle.bundleIdentifier), installedResignedID=\(installedApp.resignedBundleIdentifier), installedTeam=\(installedApp.team?.identifier ?? "nil"), targetTeam=\(team.identifier), teamsMatch=\(teamsMatch)")

        // TODO: @mahee96: Try to keep the debug build and release build operations similar, refactor later with proper reasoning
        //                 for now, restricted it to debug on simulator only
        #if DEBUG && targetEnvironment(simulator)

        let result = teamsMatch ? installedApp.resignedBundleIdentifier : nil
        self.debugLog("[FetchProvisioningProfiles] preferredBundleID result (DEBUG simulator): \(result ?? "nil")")
        return result

        #else
        
        let result = teamsMatch ? installedApp.resignedBundleIdentifier : nil
        self.debugLog("[FetchProvisioningProfiles] preferredBundleID result: \(result ?? "nil")")
        return result
        
        #endif
    }
    
    private func prepareProvisioningProfile(for targetAppBundle: ALTApplication,
                                    parentAppBundle: ALTApplication?,
                                    team: ALTTeam,
                                    session: ALTAppleAPISession) async throws -> ALTProvisioningProfile {
        let preferredBundleID = try await self.fetchPreferredBundleID(for: targetAppBundle, team: team)
        
        let bundleID: String
        
        if let preferredBundleID = preferredBundleID {
            bundleID = preferredBundleID
            self.debugLog("[FetchProvisioningProfiles] Using preferredBundleID: \(bundleID)")
        } else {
            let parentBundleID = parentAppBundle?.bundleIdentifier ?? targetAppBundle.bundleIdentifier
            let effectiveParentBundleID = self.context.targetBundleIdentifier
            let updatedParentBundleID: String
            if targetAppBundle.isAltStoreApp && self.context.customBundleIdentifier == nil {
                // AltStore: always use com.<TEAMID>.<originalBundleID> format by default.
                updatedParentBundleID = "com." + team.identifier + "." + effectiveParentBundleID
            } else {
                updatedParentBundleID = self.context.appendTeamID ? (effectiveParentBundleID + "." + team.identifier) : effectiveParentBundleID
            }

            if parentAppBundle != nil,
               targetAppBundle.bundleIdentifier.hasPrefix(parentBundleID + ".") {
                let suffix = String(targetAppBundle.bundleIdentifier.dropFirst(parentBundleID.count))
                bundleID = updatedParentBundleID + suffix
            } else {
                bundleID = updatedParentBundleID
            }
            self.debugLog("[FetchProvisioningProfiles] Constructed mangled bundleID: \(bundleID) (effectiveParent: \(effectiveParentBundleID), appendTeamID: \(self.context.appendTeamID), team: \(team.identifier))")

        }
        
        let preferredName: String
        
        if let parentAppBundle = parentAppBundle {
            preferredName = parentAppBundle.name + " " + targetAppBundle.name
        } else {
            preferredName = targetAppBundle.name
        }
        
        self.debugLog("[FetchProvisioningProfiles] Registering App ID with name '\(preferredName)' and bundleID '\(bundleID)'...")
        // Register
        let appID = try await self.registerAppID(for: targetAppBundle, name: preferredName, bundleIdentifier: bundleID, team: team, session: session)
        self.debugLog("[FetchProvisioningProfiles] App ID registered successfully: \(appID.bundleIdentifier) (\(appID.identifier))")
        
        // Fetch Provisioning Profile
        self.debugLog("[FetchProvisioningProfiles] Fetching provisioning profile for App ID \(appID.bundleIdentifier)...")
        let profile = try await self.fetchProvisioningProfile(for: appID, targetAppBundle: targetAppBundle, team: team, session: session)
        self.debugLog("[FetchProvisioningProfiles] Provisioning profile fetched for \(appID.bundleIdentifier) (Name: \(profile.name), Expiration: \(String(describing: profile.expirationDate)))")
        return profile
    }
    
    private func registerAppID(for targetAppBundle: ALTApplication,
                               name: String,
                               bundleIdentifier: String,
                               team: ALTTeam,
                               session: ALTAppleAPISession) async throws -> ALTAppID {
        let appIDs: [ALTAppID]
        if let cachedAppIDs = self.context.sharedContext?.appIDs {
            self.debugLog("[FetchProvisioningProfiles] Using cached App IDs from shared context.")
            appIDs = cachedAppIDs
        } else {
            self.debugLog("[FetchProvisioningProfiles] Fetching existing App IDs from Apple for team \(team.identifier)...")
            let fetchedAppIDs = try await TaskChainCoalescer.shared.coalesce(key: "fetch_app_ids_\(team.identifier)") {
                try await ALTAppleAPI.shared.fetchAppIDs(for: team, session: session)
            }
            self.context.sharedContext?.appIDs = fetchedAppIDs
            appIDs = fetchedAppIDs
            self.verboseLog("[FetchProvisioningProfiles] Found \(appIDs.count) existing App IDs on portal for team \(team.identifier): \(appIDs.map { $0.bundleIdentifier })")
        }
        
        if let appID = appIDs.first(where: { $0.bundleIdentifier.lowercased() == bundleIdentifier.lowercased() }) {
            self.debugLog("[FetchProvisioningProfiles] Found existing App ID on portal: \(appID.bundleIdentifier)")
            return appID
        } else {
            let requiredAppIDs = 1 + targetAppBundle.appExtensions.count
            let availableAppIDs = max(0, Team.maximumFreeAppIDs - appIDs.count)
            self.verboseLog("[FetchProvisioningProfiles] App ID not found on portal for '\(bundleIdentifier)'. Required: \(requiredAppIDs), Available: \(availableAppIDs) (teamType: \(team.type))")
            
            let sortedExpirationDates = appIDs.compactMap { $0.expirationDate }.sorted(by: { $0 < $1 })
            
            //App ID name must be ascii. If the name is not ascii, using bundleID instead
            let appIDName: String
            if !name.allSatisfy({ $0.isASCII }) {
                //Contains non ASCII (Such as Chinese/Japanese...), using bundleID
                appIDName = bundleIdentifier
            } else {
                //ASCII text, keep going as usual
                appIDName = name
            }
            
            do {
                self.debugLog("[FetchProvisioningProfiles] Calling ALTAppleAPI.shared.addAppID with name '\(appIDName)' and identifier '\(bundleIdentifier)'...")
                let appID = try await ALTAppleAPI.shared.addAppID(withName: appIDName, bundleIdentifier: bundleIdentifier, team: team, session: session)
                self.context.sharedContext?.appendAppID(appID)
                self.debugLog("[FetchProvisioningProfiles] Successfully registered new App ID '\(appID.bundleIdentifier)' on Apple portal.")
                return appID
            } catch let error as DeveloperPortalError {
                switch error {
                case .maximumAppIDLimitReached:
                    self.debugLog("[FetchProvisioningProfiles] addAppID failed: maximumAppIDLimitReached")
                    if let expirationDate = sortedExpirationDates.first {
                        throw OperationError.maximumAppIDLimitReached(appName: targetAppBundle.name, requiredAppIDs: requiredAppIDs, availableAppIDs: availableAppIDs, expirationDate: expirationDate)
                    }
                    throw error

                case .bundleIdentifierUnavailable:
                    self.debugLog("[FetchProvisioningProfiles] addAppID failed: bundleIdentifierUnavailable for '\(bundleIdentifier)'. Re-checking portal...")
                    let appIDs = try await TaskChainCoalescer.shared.coalesce(key: "fetch_app_ids_\(team.identifier)") {
                        try await ALTAppleAPI.shared.fetchAppIDs(for: team, session: session)
                    }
                    self.context.sharedContext?.appIDs = appIDs
                    if let appID = appIDs.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                        self.debugLog("[FetchProvisioningProfiles] Found App ID on secondary fetch after bundleIdentifierUnavailable: \(appID.bundleIdentifier)")
                        return appID
                    } else {
                        self.debugLog("[FetchProvisioningProfiles] App ID '\(bundleIdentifier)' unavailable and not found in secondary fetch.")
                        throw OperationError.appIDUnavailable
                    }

                default:
                    self.debugLog("[FetchProvisioningProfiles] addAppID failed with error: \(error.localizedDescription)")
                    throw error
                }
            } catch {
                self.debugLog("[FetchProvisioningProfiles] addAppID failed with error: \(error.localizedDescription)")
                throw error
            }
        }
    }
}

class FetchProvisioningProfilesInstallOperation: FetchProvisioningProfilesOperation, @unchecked Sendable {
    
    // modify Operations are allowed for the app groups and other stuffs
    override func fetchProvisioningProfile(for appID: ALTAppID,
                                    targetAppBundle: ALTApplication,
                                    team: ALTTeam,
                                    session: ALTAppleAPISession) async throws -> ALTProvisioningProfile {
        self.debugLog("[FetchProvisioningProfilesInstall] Updating features for App ID \(appID.bundleIdentifier)...")
        let updatedAppID = try await self.updateFeatures(for: appID, targetAppBundle: targetAppBundle, team: team, session: session)
        
        self.debugLog("[FetchProvisioningProfilesInstall] Updating app groups for App ID \(updatedAppID.bundleIdentifier)...")
        let groupAppID = try await self.updateAppGroups(for: updatedAppID, targetAppBundle: targetAppBundle, team: team, session: session)
        
        self.debugLog("[FetchProvisioningProfilesInstall] Fetching profile from Apple for App ID \(groupAppID.bundleIdentifier)...")
        return try await super.fetchProvisioningProfile(for: groupAppID, targetAppBundle: targetAppBundle, team: team, session: session)
    }
    
    private func updateFeatures(for appID: ALTAppID, targetAppBundle: ALTApplication, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTAppID {
        var entitlements = targetAppBundle.entitlements
        for (key, value) in context.additionalEntitlements {
            entitlements[key] = value
        }
        
        guard let allowedFeatures = team.type.allowedFeatures else {
            throw OperationError.invalidParameters("Cannot update features for unknown team type.")
        }
        
        var targetFeatures: [ALTFeature: String] = [:]
        var droppedFeatures: Set<ALTFeature> = []
        
        // Filter applicable features
        for (key, value) in entitlements {
            guard let feature = ALTFeature(entitlement: ALTEntitlement(rawValue: key)) else { 
                continue 
            }
            let isEnabled = (value as? [Any])?.isEmpty == false || (value as? Bool) ?? true
            
            if allowedFeatures.contains(feature) {
                targetFeatures[feature] = isEnabled ? "true" : "false"
            } else {
                droppedFeatures.insert(feature)
            }
        }
        
        // Force apply mandatory features
        for feature in AppConstants.mandatoryFeatures {
            if allowedFeatures.contains(feature) {
                targetFeatures[feature] = "true"
            } else {
                droppedFeatures.insert(feature)
            }
        }
        
        if !droppedFeatures.isEmpty {
            let bulleted = droppedFeatures.map { "  • \($0.rawValue)" }.joined(separator: "\n")
            self.debugLog("[FetchProvisioningProfiles] Dropped non-applicable features for team type \(team.type):\n\(bulleted)")
        }
        
        // check if we really need to make a update on portal
        let currentFeatures = appID.features
        let needsUpdate = targetFeatures.contains { feature, targetValue in
            // if not available yet assume feature = off
            let currentValue = currentFeatures[feature] ?? "false"
            return currentValue != targetValue
        }
        guard needsUpdate else { 
            self.debugLog("[FetchProvisioningProfiles] Features for App ID \(appID.bundleIdentifier) are already satisfied. Skipping portal update.")
            return appID 
        }
        
        // set for requesting and send request
        var appID = appID
        appID.features = targetFeatures
        
        do {
            let updated = try await ALTAppleAPI.shared.updateAppID(appID, team: team, session: session)
            self.verboseLog("[FetchProvisioningProfiles] Updated features for App ID \(updated.bundleIdentifier).")
            return updated
        } catch {
            self.debugLog("[FetchProvisioningProfiles] Failed to update features for App ID \(appID.bundleIdentifier). \(error.localizedDescription)")
            throw error
        }
    }
    
    private func updateAppGroups(for appID: ALTAppID, targetAppBundle: ALTApplication, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTAppID {
        var entitlements = targetAppBundle.entitlements
        for (key, value) in self.context.additionalEntitlements {
            entitlements[key] = value
        }
                
        guard var applicationGroups = entitlements[ALTEntitlement.appGroups.rawValue] as? [String], !applicationGroups.isEmpty else {
            verboseLog("[FetchProvisioningProfiles] App ID \(appID.bundleIdentifier) has no app groups, skipping assignment.")
            // Assigning an App ID to an empty app group array fails,
            // so just do nothing if there are no app groups.
            return appID
        }
        
        for group in applicationGroups {
            if group.contains("$(APP_GROUP_IDENTIFIER)") {
                self.debugLog("[FetchProvisioningProfiles] Error: Application group contains raw placeholder '$(APP_GROUP_IDENTIFIER)': \(group)")
                throw OperationError.invalidParameters("Application group '\(group)' contains raw placeholder '$(APP_GROUP_IDENTIFIER)'.")
            }
        }
        
        if targetAppBundle.isAltStoreApp {
            verboseLog("[FetchProvisioningProfiles] Application groups before modifying for SideStore: \(applicationGroups)")
            
            // Remove app groups that contain AltStore since they can be problematic (cause SideStore to expire early)
            for (index, group) in applicationGroups.enumerated() {
                if group.contains("AltStore") {
                    verboseLog("[FetchProvisioningProfiles] Removing application group: \(group)")
                    applicationGroups.remove(at: index)
                }
            }
            
            // Make sure we add .AltWidget for the widget
            var altStoreAppGroupID = Bundle.baseAltStoreAppGroupID
            for (_, group) in applicationGroups.enumerated() {
                if group.contains("AltWidget") {
                    altStoreAppGroupID += ".AltWidget"
                    break
                }
            }
            
            // Potentially updating app groups for this specific AltStore.
            // Find the (unique) AltStore app group, then replace it
            // with the correct "base" app group ID.
            // Otherwise, we may append a duplicate team identifier to the end.
            if let index = applicationGroups.firstIndex(where: { $0.contains(Bundle.baseAltStoreAppGroupID) }) {
                applicationGroups[index] = altStoreAppGroupID
            } else {
                applicationGroups.append(altStoreAppGroupID)
            }
        }
        verboseLog("[FetchProvisioningProfiles] Application groups: \(applicationGroups)")
        
        var seenGroupIDs = Set<String>()
        
        do {
            let fetchedGroups: [ALTAppGroup]
            if let cachedGroups = self.context.sharedContext?.appGroups {
                self.debugLog("[FetchProvisioningProfiles] Using cached App Groups from shared context.")
                fetchedGroups = cachedGroups
            } else {
                self.debugLog("[FetchProvisioningProfiles] Fetching existing App Groups from Apple for team \(team.identifier)...")
                let groups = try await ALTAppleAPI.shared.fetchAppGroups(for: team, session: session)
                self.context.sharedContext?.appGroups = groups
                fetchedGroups = groups
            }
            
            var groups = [ALTAppGroup]()
            
            for groupIdentifier in applicationGroups {
                let adjustedGroupIdentifier = try await self.adjustedGroupIdentifier(for: groupIdentifier, appID: appID, targetAppBundle: targetAppBundle, team: team)
                guard seenGroupIDs.insert(adjustedGroupIdentifier).inserted else { continue }
                
                if let group = fetchedGroups.first(where: { $0.groupIdentifier == adjustedGroupIdentifier }) {
                    groups.append(group)
                } else {
                    // Not all characters are allowed in group names, so we replace periods with spaces (like Apple does).
                    let name = "AltStore " + groupIdentifier.replacingOccurrences(of: ".", with: " ")
                    do {
                        let group = try await ALTAppleAPI.shared.addAppGroup(withName: name, groupIdentifier: adjustedGroupIdentifier, team: team, session: session)
                        self.context.sharedContext?.appendAppGroup(group)
                        self.verboseLog("[FetchProvisioningProfiles] Created new App Group \(group.groupIdentifier).")
                        groups.append(group)
                    } catch {
                        self.debugLog("[FetchProvisioningProfiles] Failed to create new App Group \(adjustedGroupIdentifier). \(error.localizedDescription)")
                        throw error
                    }
                }
            }
            
            try await ALTAppleAPI.shared.assign(appID, to: Array(groups), team: team, session: session)
            let groupIDs = groups.map { $0.groupIdentifier }
            self.debugLog("[FetchProvisioningProfiles] Assigned App ID \(appID.bundleIdentifier) to App Groups \(groupIDs.description).")
            
            return appID
        } catch {
            let groupIDs = Array(seenGroupIDs.isEmpty ? Set(applicationGroups.map { $0 + "." + team.identifier }) : seenGroupIDs)
            self.debugLog("[FetchProvisioningProfiles] Failed to assign/create App Groups \(groupIDs) for App ID \(appID.bundleIdentifier): \(error.localizedDescription)")
            throw error
        }
    }

    private func adjustedGroupIdentifier(for groupIdentifier: String, appID: ALTAppID, targetAppBundle: ALTApplication, team: ALTTeam) async throws -> String {
        // Currently Build.xconfig for debug appends suffix as TEAMID already
        #if DEBUG
        if groupIdentifier.contains(Bundle.baseAltStoreAppGroupID) && groupIdentifier.contains(team.identifier) {
            return groupIdentifier
        }
        #endif

        let rawGroupID = groupIdentifier.hasPrefix("group.") ? String(groupIdentifier.dropFirst("group.".count)) : groupIdentifier
        let targetBundleID = targetAppBundle.bundleIdentifier
        let contextTargetBundleID = self.context.targetBundleIdentifier
        
        let matchesBundleID = rawGroupID.caseInsensitiveCompare(targetBundleID) == .orderedSame ||
                              rawGroupID.caseInsensitiveCompare(contextTargetBundleID) == .orderedSame
        let isExactCaseMatch = rawGroupID == targetBundleID || rawGroupID == contextTargetBundleID

        if matchesBundleID && !isExactCaseMatch {
            let correctedGroup = "group." + appID.bundleIdentifier
            let originalGroupWithTeam = groupIdentifier + "." + team.identifier
            
            if UserDefaults.standard.autoFixAppGroupIDs {
                return correctedGroup
            } else {
                let decision = try await self.context.handler.userCustomizationHandler.resolveAppGroupMismatch(
                    originalGroup: originalGroupWithTeam,
                    correctedGroup: correctedGroup
                )
                switch decision {
                case .correctAndProceed(let group):
                    return group
                case .keepOriginal(let group):
                    return group
                }
            }
        }

        return groupIdentifier + "." + team.identifier
    }
}

class FetchProvisioningProfilesRefreshOperation: FetchProvisioningProfilesInstallOperation, @unchecked Sendable {
}


