//
//  AppShortcuts.swift
//  AltStore
//
//  Created by Riley Testut on 8/23/22.
//  Copyright © 2022 Riley Testut. All rights reserved.
//

import AppIntents

@available(iOS 17, tvOS 17, *)
public struct ShortcutsProvider: AppShortcutsProvider
{
    /// The App Intents metadata extractor stamps every SideStore App Intent with
    /// `introducedVersion` 17.2 (see the note in `RefreshAllAppsIntent.swift`), so on
    /// iOS 17.0/17.1 an auto-shortcut would be handed to Shortcuts and immediately reported as
    /// "This action is not supported on iPhone". Don't register any in that case — those devices
    /// use the legacy SiriKit `RefreshAllIntent` instead, which is added manually.
    private static var supportsAppIntents: Bool
    {
        if #available(iOS 17.2, tvOS 17.2, *) { return true }
        return false
    }

    public static var appShortcuts: [AppShortcut] {
        guard Self.supportsAppIntents else { return [] }

        return [
            AppShortcut(intent: RefreshAllAppsIntent(),
                        phrases: [
                            "Refresh \(.applicationName)",
                            "Refresh \(.applicationName) apps",
                            "Refresh my \(.applicationName) apps",
                            "Refresh apps with \(.applicationName)",
                        ],
                        shortTitle: "Refresh All Apps",
                        systemImageName: "arrow.triangle.2.circlepath"),

            AppShortcut(intent: InstallIPAIntent(),
                        phrases: [
                            "Install IPA with \(.applicationName)",
                            "Install an IPA with \(.applicationName)",
                        ],
                        shortTitle: "Install IPA",
                        systemImageName: "square.and.arrow.down"),
        ]
    }
    
    public static var shortcutTileColor: ShortcutTileColor {
        return .teal
    }
}
