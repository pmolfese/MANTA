import Foundation
import MANTACore

typealias HydroCelLayoutLoaderError = MANTACore.HydroCelLayoutLoaderError

struct HydroCelLayoutLoader {
    private var resourceDirectory: URL?
    private var bundle: Bundle

    init(resourceDirectory: URL? = nil, bundle: Bundle = .main) {
        self.resourceDirectory = resourceDirectory
        self.bundle = bundle
    }

    func loadLayouts() throws -> [ElectrodeLayout] {
        if let resourceDirectory {
            return try HydroCelLayoutFileLoader(resourceDirectory: resourceDirectory).loadLayouts()
        }
        for subdirectory in ["Layouts", "Resources/Layouts"] {
            if let metadata = bundle.url(
                forResource: "HydroCelLayoutMetadata", withExtension: "json",
                subdirectory: subdirectory) {
                return try HydroCelLayoutFileLoader(
                    resourceDirectory: metadata.deletingLastPathComponent()).loadLayouts()
            }
        }
        if let metadata = bundle.url(
            forResource: "HydroCelLayoutMetadata", withExtension: "json") {
            return try HydroCelLayoutFileLoader(
                resourceDirectory: metadata.deletingLastPathComponent()).loadLayouts()
        }
        throw HydroCelLayoutLoaderError.missingResource("HydroCelLayoutMetadata.json")
    }
}
