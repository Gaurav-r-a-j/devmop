import SwiftUI
import SweepCore

/// Whether DevMop can clean an area, and why.
enum AreaStatus: String {
    case cleanable, partly, yourData, managed, readOnly

    var title: String {
        switch self {
        case .cleanable: "Cleanable"
        case .partly: "Partly cleanable"
        case .yourData: "Your data"
        case .managed: "Managed by macOS"
        case .readOnly: "Read-only"
        }
    }

    var symbol: String {
        switch self {
        case .cleanable: "sparkles"
        case .partly: "circle.lefthalf.filled"
        case .yourData: "person.crop.circle"
        case .managed: "gearshape"
        case .readOnly: "lock.fill"
        }
    }

    var color: Color {
        switch self {
        case .cleanable: .green
        case .partly: .teal
        case .yourData: .indigo
        case .managed: .secondary
        case .readOnly: .secondary
        }
    }
}

/// Title, colour, group and explanation for every part of the disk.
struct AreaInfo {
    let title: String
    let color: Color
    let group: BreakdownItem.Group
    let status: AreaStatus
    let why: String
    var section: SidebarSection?
    var actionTitle: String?

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255)
    }

    static let slices: [StorageSlice.Kind: AreaInfo] = [
        .documents: AreaInfo(title: "Documents", color: rgb(52, 199, 89), group: .data, status: .yourData,
                             why: "Your documents. DevMop never selects them for you; review big or old ones in Files.",
                             section: .files, actionTitle: "Review in Files"),
        .desktop: AreaInfo(title: "Desktop", color: rgb(48, 176, 120), group: .data, status: .yourData,
                           why: "Files on your desktop. Screenshots and recordings often pile up here."),
        .downloads: AreaInfo(title: "Downloads", color: rgb(130, 200, 80), group: .data, status: .partly,
                             why: "Installers, archives you already extracted and files you haven't opened in months can go; the rest is yours.",
                             section: .files, actionTitle: "Review in Files"),
        .pictures: AreaInfo(title: "Pictures & Photos", color: rgb(255, 204, 0), group: .data, status: .yourData,
                            why: "Your Photos library lives here. In Photos › Settings › iCloud, Optimize Mac Storage keeps the originals only in iCloud."),
        .movies: AreaInfo(title: "Movies", color: rgb(230, 170, 0), group: .data, status: .yourData,
                          why: "Videos and screen recordings. Large ones show up in Files."),
        .music: AreaInfo(title: "Music", color: rgb(255, 224, 120), group: .data, status: .yourData,
                         why: "Your music library and GarageBand or Logic content."),
        .iCloud: AreaInfo(title: "iCloud Drive (on this Mac)", color: rgb(0, 199, 190), group: .data, status: .partly,
                          why: "Downloaded copies of iCloud Drive files. Copies already safe in iCloud can be removed and download again when opened.",
                          section: .systemData, actionTitle: "Open System Data"),
        .mail: AreaInfo(title: "Mail & Messages", color: rgb(102, 212, 207), group: .data, status: .yourData,
                        why: "Your messages and attachments. In Messages › Settings, Keep messages for 1 year removes old ones for you."),
        .cloudStorage: AreaInfo(title: "Dropbox, Google Drive & OneDrive", color: rgb(90, 200, 250), group: .data, status: .yourData,
                                why: "Local copies of cloud-storage files. Make folders online-only in that app to free space without losing anything."),
        .applications: AreaInfo(title: "Applications", color: rgb(88, 86, 214), group: .data, status: .partly,
                                why: "Apps you installed. Uninstall the ones you don't use, along with their leftovers.",
                                section: .apps, actionTitle: "Open Apps"),
        .otherFolders: AreaInfo(title: "Other folders in your home", color: rgb(120, 190, 150), group: .data, status: .yourData,
                                why: "Your own folders, such as code projects. Their build folders are counted separately under Can be cleaned.",
                                section: .projects, actionTitle: "Open Projects"),
        .developerTools: AreaInfo(title: "Developer tool folders (~/.*)", color: rgb(150, 150, 210), group: .data, status: .partly,
                                  why: "Hidden folders like ~/.npm and ~/.gradle. Their caches are counted under Can be cleaned; the rest is tool settings and data.",
                                  section: .caches, actionTitle: "Open Caches"),

        .libraryCaches: AreaInfo(title: "Library › Caches", color: rgb(100, 116, 139), group: .library, status: .partly,
                                 why: "Temporary files apps keep for speed. DevMop cleans browser and developer caches and caches of apps that aren't running. Apple's own caches (com.apple.*) are left alone: macOS uses them all the time and rebuilds them at once, so deleting them gives back little and can cause glitches.",
                                 section: .systemData, actionTitle: "Open System Data"),
        .libraryAppSupport: AreaInfo(title: "Library › Application Support", color: rgb(71, 85, 105), group: .library, status: .yourData,
                                     why: "Apps' real data: databases, downloads, settings and sometimes your documents. Deleting folders here blindly loses data, so DevMop only removes an app's data when you uninstall it.",
                                     section: .apps, actionTitle: "Open Apps"),
        .libraryContainers: AreaInfo(title: "Library › Containers", color: rgb(51, 65, 85), group: .library, status: .yourData,
                                     why: "Sandboxed apps such as App Store apps, Docker, Mail and Notes keep everything here, including your documents. Data from deleted apps is under Apps › Leftovers.",
                                     section: .apps, actionTitle: "Open Apps"),
        .libraryDeveloper: AreaInfo(title: "Library › Developer", color: rgb(148, 163, 184), group: .library, status: .partly,
                                    why: "Xcode and simulator data. DerivedData, device support files and simulators are cleanable.",
                                    section: .simulators, actionTitle: "Open Simulators"),
        .libraryOther: AreaInfo(title: "Library › everything else", color: rgb(130, 145, 165), group: .library, status: .managed,
                                why: "Preferences, fonts, keychains, and data from tools such as the pnpm store (counted under Caches). Mostly small files apps need to work."),

        .homebrew: AreaInfo(title: "Homebrew packages", color: rgb(120, 113, 108), group: .system, status: .partly,
                            why: "Command-line tools installed with Homebrew. Old versions and downloads are cleaned under Caches; run brew uninstall for tools you don't need.",
                            section: .caches, actionTitle: "Open Caches"),
        .systemLibrary: AreaInfo(title: "/Library (shared by all users)", color: rgb(120, 113, 108), group: .system, status: .managed,
                                 why: "Fonts, audio plug-ins, printer drivers and Xcode command-line tools for every user. Changing it needs an admin password, so remove the app that added it instead."),
        .macOS: AreaInfo(title: "macOS", color: rgb(87, 83, 78), group: .system, status: .readOnly,
                         why: "macOS itself, on a sealed and signed volume. Nothing can change it, by design; that's what keeps your Mac secure."),
        .swap: AreaInfo(title: "Swap & sleep image", color: rgb(140, 134, 130), group: .system, status: .managed,
                        why: "Memory macOS moved to disk. It shrinks after a restart or when you quit apps that use a lot of memory."),
        .preboot: AreaInfo(title: "Startup, recovery & updates", color: rgb(168, 162, 158), group: .system, status: .managed,
                           why: "Files macOS needs to start up, run Recovery and install updates."),
    ]

    static let remainder = AreaInfo(
        title: "Snapshots, Spotlight & purgeable", color: rgb(142, 142, 147), group: .system, status: .managed,
        why: "Time Machine local snapshots, the Spotlight index and other space macOS frees on its own when it needs room. Local snapshots can be thinned from System Data.",
        section: .systemData, actionTitle: "Open System Data"
    )

    static func cleanable(_ section: SidebarSection) -> (status: AreaStatus, why: String) {
        switch section {
        case .projects: (.cleanable, "Build folders your tools recreate with an install or a build.")
        case .caches: (.cleanable, "Downloads and caches that tools fetch again when needed.")
        case .simulators: (.cleanable, "Simulators and runtimes you can create or download again in Xcode.")
        case .systemData: (.cleanable, "Backups, caches, logs and installers counted as System Data.")
        case .trash: (.cleanable, "Files you already deleted.")
        default: (.cleanable, "")
        }
    }
}
