import Foundation

/// An in-memory Mac for `--demo onboarding`. Starts as a new login would find
/// it: default wallpaper, Safari as default, the user an admin.
public final class DemoOnboardingWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var wallpaper: String? = "/System/Library/CoreServices/DefaultDesktop.heic"
    private var defaults: [String: String] = ["http": "com.apple.Safari"]
    private var admins: Set<String> = ["demo"]
    private var files: Set<String> = []

    public init() {}

    /// A typical new Dock, using real system apps for real icons.
    private var dock: [String] = [
        // Safari is in /Applications, not /System/Applications.
        "/Applications/Safari.app",
        "/System/Applications/Messages.app",
        "/System/Applications/Mail.app",
        "/System/Applications/Calendar.app",
        "/System/Applications/Notes.app",
        "/System/Applications/Music.app",
    ]

    public var probes: OnboardingProbes {
        OnboardingProbes(
            currentUserName: { "demo" },
            fileExists: { [self] path in lock.withLock { files.contains(path) } },
            currentWallpaperPath: { [self] in lock.withLock { wallpaper } },
            currentDefaultApp: { [self] target in lock.withLock { defaults[target.key] } },
            isMemberOfAdminGroup: { [self] name in lock.withLock { admins.contains(name) } },
            currentDockItems: { [self] in lock.withLock { dock } },
            isAppInstalled: { _ in true }
        )
    }

    fileprivate func setWallpaper(_ path: String) { lock.withLock { wallpaper = path } }
    fileprivate func setDefault(_ key: String, to bundleID: String) { lock.withLock { defaults[key] = bundleID } }
    fileprivate func demote(_ name: String) { lock.withLock { _ = admins.remove(name) } }
    fileprivate func touch(_ path: String) { lock.withLock { _ = files.insert(path) } }
}

/// Demo actions: a short pause, then the in-memory Mac changes.
public struct DemoOnboardingActions: OnboardingActing {
    private let world: DemoOnboardingWorld

    public init(world: DemoOnboardingWorld) {
        self.world = world
    }

    public func perform(_ item: OnboardingItem, choice: StepChoice?) async -> ItemRecord {
        try? await Task.sleep(for: .milliseconds(700))

        if case .keepCurrent = choice {
            return ItemRecord(outcome: .skipped, status: .notNeeded, message: nil)
        }

        switch item.kind {
        case .message:
            return ItemRecord(outcome: .success, status: .done)
        case .wallpaper(let spec):
            guard case .wallpaper(let index) = choice, spec.sources.indices.contains(index) else {
                // A single source needs no choice.
                if let only = spec.sources.first, spec.sources.count == 1 {
                    world.setWallpaper(WallpaperLocation.destination(for: only).path)
                    return ItemRecord(outcome: .success, status: .done)
                }
                return ItemRecord(outcome: .failed, status: .failed, message: "no wallpaper chosen")
            }
            world.setWallpaper(WallpaperLocation.destination(for: spec.sources[index]).path)
            return ItemRecord(outcome: .success, status: .done)

        case .dock(let spec):
            if case .dock(.keep) = choice {
                return ItemRecord(outcome: .skipped, status: .notNeeded)
            }
            let skipped = spec.items.count / 3
            return ItemRecord(
                outcome: .success,
                status: .done,
                detail: ["added": spec.items.count - skipped, "skipped": skipped]
            )

        case .defaultApps(let spec):
            if case .defaultApps(let picks) = choice {
                for (key, bundleID) in picks { world.setDefault(key, to: bundleID) }
            } else {
                // Single values: apply the only candidates.
                for (target, candidates) in spec.targets {
                    if let only = candidates.first, candidates.count == 1 {
                        world.setDefault(target.key, to: only)
                    }
                }
            }
            return ItemRecord(outcome: .success, status: .done)

        case .open:
            // The opened app is assumed to create its validatePath.
            if let path = item.validatePath {
                world.touch(path)
            }
            return ItemRecord(outcome: .success, status: .awaitingUser)

        case .demoteUser:
            world.demote("demo")
            return ItemRecord(outcome: .success, status: .done)
        }
    }
}

public enum DemoOnboarding {
    /// One item per kind, covering both choices (arrays) and confirmations
    /// (single values).
    public static func items() -> [OnboardingItem] {
        [
            OnboardingItem(
                id: "welcome",
                kind: .message,
                title: LocalizedText(localized: ["en": "Welcome to your new Mac", "nl": "Welkom bij je nieuwe Mac", "fr": "Bienvenue sur votre nouveau Mac"]),
                subtitle: LocalizedText(localized: ["en": "A few steps to make it yours. Press Continue to begin.", "nl": "Een paar stappen om hem van jou te maken. Klik op Doorgaan om te beginnen.", "fr": "Quelques étapes pour le personnaliser. Cliquez sur Continuer pour commencer."]),
                icon: .symbol("hand.wave"),
                required: false
            ),
            OnboardingItem(
                id: "wallpaper",
                kind: .wallpaper(.init(
                    sources: demoWallpaperSources(),
                    allowKeepExisting: true
                )),
                title: LocalizedText(localized: ["en": "Choose a wallpaper", "nl": "Kies een bureaubladachtergrond", "fr": "Choisissez un fond d’écran"]),
                subtitle: LocalizedText(localized: ["en": "Please choose a wallpaper from our list of branded images. You can always change it later.", "nl": "Kies een achtergrond uit onze bedrijfsafbeeldingen. Je kunt dit later altijd aanpassen.", "fr": "Choisissez un fond d’écran parmi nos images d’entreprise. Vous pourrez le changer plus tard."]),
                icon: .symbol("photo"),
                required: false
            ),
            OnboardingItem(
                id: "dock",
                kind: .dock(.init(
                    strategies: [.add, .replace],
                    items: [
                        "/System/Applications/Apps.app",
                        "/Applications/Microsoft Edge.app",
                        "/Applications/Microsoft Outlook.app",
                        "/Applications/Microsoft Teams.app",
                        "/System/Applications/System Settings.app",
                    ]
                )),
                title: LocalizedText(localized: ["en": "Dock", "nl": "Dock", "fr": "Dock"]),
                subtitle: LocalizedText(localized: ["en": "For convenient access, we recommend adding these apps and items to your Dock.", "nl": "Voor snelle toegang raden we aan deze apps en onderdelen aan je Dock toe te voegen.", "fr": "Pour un accès rapide, nous vous conseillons d’ajouter ces apps et éléments à votre Dock."]),
                icon: .symbol("dock.rectangle"),
                required: false
            ),
            OnboardingItem(
                id: "browser",
                kind: .defaultApps(.init(
                    browsers: ["com.microsoft.edgemac"],
                    explanation: LocalizedText(plain: "macOS will ask you to confirm the change.")
                )),
                title: LocalizedText(localized: ["en": "Confirm default browser", "nl": "Standaardbrowser bevestigen", "fr": "Confirmer le navigateur par défaut"]),
                subtitle: LocalizedText(localized: ["en": "Confirm Microsoft Edge as default browser.", "nl": "Bevestig Microsoft Edge als standaardbrowser.", "fr": "Confirmez Microsoft Edge comme navigateur par défaut."]),
                icon: .symbol("globe"),
                required: false
            ),
            OnboardingItem(
                id: "mail",
                kind: .defaultApps(.init(
                    urlSchemes: ["mailto": ["com.microsoft.Outlook", "com.apple.mail"]],
                    allowKeepExisting: true
                )),
                title: LocalizedText(localized: ["en": "Choose mail app", "nl": "Kies een mailapp", "fr": "Choisissez une app de messagerie"]),
                subtitle: LocalizedText(localized: ["en": "Choose your preferred app for email.", "nl": "Kies de app die je voor e-mail wilt gebruiken.", "fr": "Choisissez l’app que vous souhaitez utiliser pour vos e-mails."]),
                icon: .symbol("envelope"),
                required: false
            ),
            OnboardingItem(
                id: "portal",
                kind: .open(target: .bundleID("com.microsoft.CompanyPortalMac"), completion: .manual),
                title: LocalizedText(localized: ["en": "Sign in to Company Portal", "nl": "Aanmelden bij Bedrijfsportal", "fr": "Connectez-vous au Portail d’entreprise"]),
                subtitle: LocalizedText(localized: ["en": "Register this Mac so it can receive company resources.", "nl": "Registreer deze Mac zodat hij bedrijfsresources kan ontvangen.", "fr": "Enregistrez ce Mac pour qu’il reçoive les ressources de l’entreprise."]),
                icon: .symbol("person.badge.shield.checkmark"),
                buttonTitle: LocalizedText(localized: ["en": "Open Company Portal", "nl": "Bedrijfsportal openen", "fr": "Ouvrir le Portail d’entreprise"]),
                required: false
            ),
            OnboardingItem(
                id: "demote",
                kind: .demoteUser(exclude: []),
                title: LocalizedText(localized: ["en": "Standard account", "nl": "Standaardaccount", "fr": "Compte standard"]),
                subtitle: LocalizedText(localized: ["en": "Your account is switched to a standard user. Use Privileges when you need admin rights.", "nl": "Je account wordt omgezet naar een standaardgebruiker. Gebruik Privileges als je beheerdersrechten nodig hebt.", "fr": "Votre compte passe en utilisateur standard. Utilisez Privileges lorsque vous avez besoin de droits d’administration."]),
                icon: .symbol("person.crop.circle.badge.checkmark"),
                required: false
            ),
        ]
    }

    /// Images from the system Desktop Pictures folder when present;
    /// placeholder paths otherwise.
    static func demoWallpaperSources() -> [OnboardingItem.Source] {
        let directory = URL(filePath: "/System/Library/Desktop Pictures")
        let found = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?
            .filter { ["heic", "jpg", "png"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(6)
            .map { OnboardingItem.Source.path($0.path) } ?? []

        return found.isEmpty
            ? [.path("/Library/Desktop Pictures/corp-light.jpg"), .path("/Library/Desktop Pictures/corp-dark.jpg")]
            : Array(found)
    }

    /// A new engine whose state is kept in a temporary directory.
    public static func makeEngine() -> OnboardingEngine {
        let world = DemoOnboardingWorld()
        let store = StateStore(rootDirectory: URL(filePath: NSTemporaryDirectory())
            .appending(path: "IntuneOnboard-demo-\(UUID().uuidString)"))
        return OnboardingEngine(
            items: items(),
            store: store,
            probes: world.probes,
            actions: DemoOnboardingActions(world: world)
        )
    }
}
