import Foundation

public struct ArtifactRule: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let directory: String
    /// Marker files that must sit next to the folder; any one is enough. Empty means none needed.
    public let markers: [String]
    public let ecosystem: Ecosystem
    public let tier: SafetyTier
    public let rebuildHint: String?
    /// Generic names (dist, build, target…) only count when git ignores them.
    public let requiresGitIgnored: Bool

    public init(id: String, name: String, directory: String, markers: [String] = [], ecosystem: Ecosystem, tier: SafetyTier, rebuildHint: String?, requiresGitIgnored: Bool = false) {
        self.id = id
        self.name = name
        self.directory = directory
        self.markers = markers
        self.ecosystem = ecosystem
        self.tier = tier
        self.rebuildHint = rebuildHint
        self.requiresGitIgnored = requiresGitIgnored
    }

    func matches(siblings: Set<String>) -> Bool {
        markers.isEmpty || markers.contains { Rules.markerPresent($0, in: siblings) }
    }
}

public enum Rules {
    static let nodeMarkers = ["package.json"]
    static let pythonMarkers = ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile"]
    static let gradleMarkers = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]

    public static let artifacts: [ArtifactRule] = [
        ArtifactRule(id: "node-modules", name: "Node modules", directory: "node_modules", ecosystem: .node, tier: .rebuildable, rebuildHint: "Run your package manager's install"),
        ArtifactRule(id: "next", name: "Next.js build", directory: ".next", markers: nodeMarkers, ecosystem: .node, tier: .rebuildable, rebuildHint: "next build or next dev"),
        ArtifactRule(id: "nuxt", name: "Nuxt build", directory: ".nuxt", markers: nodeMarkers, ecosystem: .node, tier: .rebuildable, rebuildHint: "nuxt dev or nuxt build"),
        ArtifactRule(id: "nuxt-output", name: "Nuxt output", directory: ".output", markers: nodeMarkers, ecosystem: .node, tier: .rebuildable, rebuildHint: "nuxt build", requiresGitIgnored: true),
        ArtifactRule(id: "svelte-kit", name: "SvelteKit build", directory: ".svelte-kit", markers: nodeMarkers, ecosystem: .node, tier: .rebuildable, rebuildHint: "vite dev or vite build"),
        ArtifactRule(id: "astro", name: "Astro cache", directory: ".astro", markers: nodeMarkers, ecosystem: .node, tier: .safe, rebuildHint: nil),
        ArtifactRule(id: "turbo", name: "Turborepo cache", directory: ".turbo", markers: nodeMarkers, ecosystem: .node, tier: .safe, rebuildHint: nil),
        ArtifactRule(id: "parcel", name: "Parcel cache", directory: ".parcel-cache", markers: nodeMarkers, ecosystem: .node, tier: .safe, rebuildHint: nil),
        ArtifactRule(id: "angular", name: "Angular cache", directory: ".angular", markers: nodeMarkers, ecosystem: .node, tier: .safe, rebuildHint: nil),
        ArtifactRule(id: "docusaurus", name: "Docusaurus build", directory: ".docusaurus", markers: nodeMarkers, ecosystem: .node, tier: .safe, rebuildHint: nil),
        ArtifactRule(id: "expo", name: "Expo cache", directory: ".expo", markers: nodeMarkers, ecosystem: .node, tier: .rebuildable, rebuildHint: "expo start", requiresGitIgnored: true),
        ArtifactRule(id: "node-dist", name: "Build output", directory: "dist", markers: nodeMarkers, ecosystem: .node, tier: .rebuildable, rebuildHint: "Run the build script", requiresGitIgnored: true),
        ArtifactRule(id: "node-build", name: "Build output", directory: "build", markers: nodeMarkers, ecosystem: .node, tier: .rebuildable, rebuildHint: "Run the build script", requiresGitIgnored: true),
        ArtifactRule(id: "node-out", name: "Build output", directory: "out", markers: nodeMarkers, ecosystem: .node, tier: .rebuildable, rebuildHint: "Run the build script", requiresGitIgnored: true),
        ArtifactRule(id: "storybook", name: "Storybook build", directory: "storybook-static", markers: nodeMarkers, ecosystem: .node, tier: .rebuildable, rebuildHint: "build-storybook", requiresGitIgnored: true),
        ArtifactRule(id: "coverage", name: "Test coverage", directory: "coverage", markers: nodeMarkers + pythonMarkers, ecosystem: .node, tier: .safe, rebuildHint: nil, requiresGitIgnored: true),

        ArtifactRule(id: "rust-target", name: "Cargo build", directory: "target", markers: ["Cargo.toml"], ecosystem: .rust, tier: .rebuildable, rebuildHint: "cargo build"),
        ArtifactRule(id: "maven-target", name: "Maven build", directory: "target", markers: ["pom.xml"], ecosystem: .java, tier: .rebuildable, rebuildHint: "mvn package", requiresGitIgnored: true),

        ArtifactRule(id: "venv", name: "Virtual environment", directory: ".venv", markers: pythonMarkers, ecosystem: .python, tier: .rebuildable, rebuildHint: "Recreate the venv and reinstall"),
        ArtifactRule(id: "venv-plain", name: "Virtual environment", directory: "venv", markers: pythonMarkers, ecosystem: .python, tier: .rebuildable, rebuildHint: "Recreate the venv and reinstall", requiresGitIgnored: true),
        ArtifactRule(id: "tox", name: "tox environments", directory: ".tox", markers: pythonMarkers, ecosystem: .python, tier: .safe, rebuildHint: nil),
        ArtifactRule(id: "pytest", name: "pytest cache", directory: ".pytest_cache", ecosystem: .python, tier: .safe, rebuildHint: nil),
        ArtifactRule(id: "mypy", name: "mypy cache", directory: ".mypy_cache", ecosystem: .python, tier: .safe, rebuildHint: nil),
        ArtifactRule(id: "ruff", name: "Ruff cache", directory: ".ruff_cache", ecosystem: .python, tier: .safe, rebuildHint: nil),

        ArtifactRule(id: "swiftpm", name: "SwiftPM build", directory: ".build", markers: ["Package.swift"], ecosystem: .swift, tier: .rebuildable, rebuildHint: "swift build"),
        ArtifactRule(id: "pods", name: "CocoaPods", directory: "Pods", markers: ["Podfile"], ecosystem: .apple, tier: .rebuildable, rebuildHint: "pod install"),

        ArtifactRule(id: "gradle-project", name: "Gradle cache", directory: ".gradle", markers: gradleMarkers, ecosystem: .gradle, tier: .safe, rebuildHint: nil),
        ArtifactRule(id: "gradle-build", name: "Gradle build", directory: "build", markers: gradleMarkers, ecosystem: .gradle, tier: .rebuildable, rebuildHint: "gradle build", requiresGitIgnored: true),
        ArtifactRule(id: "android-cxx", name: "Android native build", directory: ".cxx", markers: gradleMarkers, ecosystem: .gradle, tier: .safe, rebuildHint: nil),

        ArtifactRule(id: "dart-tool", name: "Dart tool cache", directory: ".dart_tool", markers: ["pubspec.yaml"], ecosystem: .dart, tier: .rebuildable, rebuildHint: "flutter pub get"),
        ArtifactRule(id: "flutter-build", name: "Flutter build", directory: "build", markers: ["pubspec.yaml"], ecosystem: .dart, tier: .rebuildable, rebuildHint: "flutter build", requiresGitIgnored: true),

        ArtifactRule(id: "elixir-build", name: "Mix build", directory: "_build", markers: ["mix.exs"], ecosystem: .elixir, tier: .rebuildable, rebuildHint: "mix compile"),
        ArtifactRule(id: "elixir-deps", name: "Mix dependencies", directory: "deps", markers: ["mix.exs"], ecosystem: .elixir, tier: .rebuildable, rebuildHint: "mix deps.get", requiresGitIgnored: true),
        ArtifactRule(id: "composer-vendor", name: "Composer packages", directory: "vendor", markers: ["composer.json"], ecosystem: .php, tier: .rebuildable, rebuildHint: "composer install", requiresGitIgnored: true),
        ArtifactRule(id: "dotnet-bin", name: ".NET build", directory: "bin", markers: ["*.csproj", "*.fsproj"], ecosystem: .dotnet, tier: .rebuildable, rebuildHint: "dotnet build", requiresGitIgnored: true),
        ArtifactRule(id: "dotnet-obj", name: ".NET intermediates", directory: "obj", markers: ["*.csproj", "*.fsproj"], ecosystem: .dotnet, tier: .rebuildable, rebuildHint: "dotnet build", requiresGitIgnored: true),
        ArtifactRule(id: "terraform", name: "Terraform providers", directory: ".terraform", ecosystem: .terraform, tier: .rebuildable, rebuildHint: "terraform init"),
    ]

    static let rulesByDirectory: [String: [ArtifactRule]] = Dictionary(grouping: artifacts, by: \.directory)

    static let projectMarkers: [(String, Ecosystem)] = [
        ("package.json", .node),
        ("Cargo.toml", .rust),
        ("pyproject.toml", .python), ("requirements.txt", .python), ("setup.py", .python), ("Pipfile", .python),
        ("Package.swift", .swift),
        ("Podfile", .apple), ("*.xcodeproj", .apple), ("*.xcworkspace", .apple),
        ("build.gradle", .gradle), ("build.gradle.kts", .gradle), ("settings.gradle", .gradle), ("settings.gradle.kts", .gradle),
        ("go.mod", .go),
        ("pubspec.yaml", .dart),
        ("Gemfile", .ruby),
        ("composer.json", .php),
        ("pom.xml", .java),
        ("mix.exs", .elixir),
        ("*.csproj", .dotnet), ("*.fsproj", .dotnet), ("*.sln", .dotnet),
        ("main.tf", .terraform),
    ]

    static let lockfiles: Set<String> = [
        "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "npm-shrinkwrap.json",
        "Cargo.lock", "Podfile.lock", "poetry.lock", "uv.lock", "Pipfile.lock", "composer.lock", "Gemfile.lock",
        "go.sum", "pubspec.lock", "mix.lock", "Package.resolved",
    ]

    /// Folder names never entered while looking for projects.
    static let skippedDirectories: Set<String> = [
        ".git", ".hg", ".svn", ".Trash", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
    ]

    /// Top-level folders in the home directory that never contain projects or must not be read.
    static let skippedHomeDirectories: Set<String> = [
        "Library", "Applications", "Music", "Movies", "Pictures", ".Trash",
    ]

    /// Bundle extensions treated as single files.
    static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "xcarchive", "bundle", "framework",
        "xcassets", "playground", "pkg", "dmg", "sparsebundle", "lproj", "imovielibrary", "fcpbundle",
    ]

    static func markerPresent(_ marker: String, in names: Set<String>) -> Bool {
        if marker.hasPrefix("*") {
            let suffix = String(marker.dropFirst())
            return names.contains { $0.hasSuffix(suffix) }
        }
        return names.contains(marker)
    }

    static func ecosystems(in names: Set<String>) -> [Ecosystem] {
        var found: [Ecosystem] = []
        for (marker, ecosystem) in projectMarkers where !found.contains(ecosystem) && markerPresent(marker, in: names) {
            found.append(ecosystem)
        }
        return found
    }
}
