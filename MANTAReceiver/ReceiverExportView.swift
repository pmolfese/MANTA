import AppKit
import Foundation
import MANTACore
import SceneKit
import SwiftUI
import UniformTypeIdentifiers
import simd

struct ReceiverExportView: View {
    let bundle: MANTAValidatedBundle
    let ephemeralReconstruction: ReceiverEphemeralReconstruction?

    @State private var coordinateFrame: ReceiverCoordinateExportFrame
    @State private var isExporting = false
    @State private var status: String?
    @State private var errorMessage: String?

    init(bundle: MANTAValidatedBundle, ephemeralReconstruction: ReceiverEphemeralReconstruction?) {
        self.bundle = bundle
        self.ephemeralReconstruction = ephemeralReconstruction
        _coordinateFrame = State(initialValue:
            ReceiverCoordinateExporter.hasHeadFrame(bundle) ? .headRAS : .arkitWorld)
    }

    var body: some View {
        Form {
            Section("Surfaces") {
                surfaceRows
                Text("PLY coordinates are meters. STL is unitless, so MANTA writes millimeter values for compatibility with common mesh tools. Fused Depth is a point cloud and therefore exports as PLY only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Electrodes and Fiducials") {
                Picker("Coordinate frame", selection: $coordinateFrame) {
                    ForEach(ReceiverCoordinateExportFrame.allCases) { frame in
                        Text(frame.title).tag(frame)
                    }
                }
                .disabled(!ReceiverCoordinateExporter.hasHeadFrame(bundle))

                HStack {
                    exportButton("Coordinates CSV", systemImage: "tablecells") {
                        try exportCoordinates(.csv)
                    }
                    exportButton("MNE SFP", systemImage: "point.3.filled.connected.trianglepath.dotted") {
                        try exportCoordinates(.sfp)
                    }
                    exportButton("EGI XML", systemImage: "chevron.left.forwardslash.chevron.right") {
                        try exportCoordinates(.egiXML)
                    }
                }
                Text("CSV includes electrodes and fiducials with explicit frame, units, state, and confidence. SFP includes both using standard FidNz/FidT9/FidT10 labels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !ReceiverCoordinateExporter.hasHeadFrame(bundle) {
                    Label(
                        "Head RAS export becomes available when Nasion, LPA, and RPA are all present in ARKit world coordinates.",
                        systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Status") {
                if isExporting {
                    ProgressView(status ?? "Exporting…")
                } else if let status {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Exports are standalone analysis files and do not modify RAW or PROCESSED.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Export Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The export could not be written.")
        }
    }

    @ViewBuilder private var surfaceRows: some View {
        let reconstruction = bundle.capture.reconstruction
        if let path = reconstruction?.headCroppedLidarMeshPath {
            surfaceRow(
                "Head LiDAR", detail: "ARKit world triangle mesh",
                source: .lidar(bundle.rootDirectory.appendingPathComponent(path), label: "head_lidar"))
        }
        if let path = reconstruction?.lidarMeshPath,
           path != reconstruction?.headCroppedLidarMeshPath {
            surfaceRow(
                "Full LiDAR", detail: "ARKit world environment mesh",
                source: .lidar(bundle.rootDirectory.appendingPathComponent(path), label: "full_lidar"))
        }
        if let modelURL = ephemeralReconstruction?.modelURL
            ?? reconstruction?.objectCaptureModelPath.map({ bundle.rootDirectory.appendingPathComponent($0) }) {
            let transform = ephemeralReconstruction?.modelToWorld
                ?? reconstruction.flatMap(ReceiverSurfaceExporter.modelToWorld)
            surfaceRow(
                "Photogrammetry",
                detail: transform == nil ? "Object Capture model space" : "Aligned ARKit world mesh",
                source: .photogrammetry(modelURL, transform: transform))
        }
        if bundle.capture.observations.contains(where: { $0.depth != nil }) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Fused Depth")
                    Text("Recomputed RGB-D point cloud · ARKit world")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                exportButton("Export PLY", systemImage: "square.and.arrow.up") {
                    try exportSurface(.fusedDepth, format: .ply)
                }
            }
        }
        if reconstruction?.headCroppedLidarMeshPath == nil,
           reconstruction?.lidarMeshPath == nil,
           reconstruction?.objectCaptureModelPath == nil,
           ephemeralReconstruction == nil,
           !bundle.capture.observations.contains(where: { $0.depth != nil }) {
            Text("No exportable surface is available.")
                .foregroundStyle(.secondary)
        }
    }

    private func surfaceRow(
        _ title: String, detail: String, source: ReceiverSurfaceExportSource
    ) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            exportButton("PLY", systemImage: "square.and.arrow.up") {
                try exportSurface(source, format: .ply)
            }
            exportButton("STL", systemImage: "square.and.arrow.up") {
                try exportSurface(source, format: .stl)
            }
        }
    }

    private func exportButton(
        _ title: String, systemImage: String,
        action: @escaping () throws -> Void
    ) -> some View {
        Button(title, systemImage: systemImage) {
            do { try action() } catch { errorMessage = error.localizedDescription }
        }
        .disabled(isExporting)
    }

    private func exportSurface(
        _ source: ReceiverSurfaceExportSource,
        format: ReceiverSurfaceExportFormat
    ) throws {
        let filename = source.suggestedName + "." + format.fileExtension
        guard let destination = saveDestination(
            filename: filename, contentType: format.contentType) else { return }
        isExporting = true
        status = "Preparing \(source.title)…"
        Task {
            do {
                switch source {
                case .lidar(let sourceURL, _):
                    if format == .ply {
                        try await Task.detached(priority: .userInitiated) {
                            try ReceiverSurfaceExporter.copyReplacing(sourceURL, to: destination)
                        }.value
                    } else {
                        let mesh = try await Task.detached(priority: .userInitiated) {
                            try ReceiverSurfaceExporter.loadBinaryPLY(sourceURL)
                        }.value
                        try await Task.detached(priority: .userInitiated) {
                            try ReceiverSurfaceExporter.write(mesh, format: format, to: destination)
                        }.value
                    }
                case .photogrammetry(let sourceURL, let transform):
                    let mesh = try ReceiverSurfaceExporter.loadSceneMesh(
                        sourceURL, modelToWorld: transform)
                    try await Task.detached(priority: .userInitiated) {
                        try ReceiverSurfaceExporter.write(mesh, format: format, to: destination)
                    }.value
                case .fusedDepth:
                    let input = try ReceiverSurfaceExporter.fusionInput(bundle)
                    let cloud = try await Task.detached(priority: .userInitiated) {
                        try ReceiverDepthFusion.fuse(input)
                    }.value
                    try await Task.detached(priority: .userInitiated) {
                        try ReceiverSurfaceExporter.writePointCloud(cloud, to: destination)
                    }.value
                }
                status = "Exported \(destination.lastPathComponent)"
            } catch {
                errorMessage = error.localizedDescription
                status = nil
            }
            isExporting = false
        }
    }

    private func exportCoordinates(_ format: ReceiverCoordinateExportFormat) throws {
        let payload = try ReceiverCoordinateExporter.export(
            bundle, frame: coordinateFrame, format: format)
        guard let destination = saveDestination(
            filename: payload.filename, contentType: format.contentType) else { return }
        try payload.data.write(to: destination, options: .atomic)
        status = "Exported \(destination.lastPathComponent)"
    }

    private func saveDestination(filename: String, contentType: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

nonisolated enum ReceiverSurfaceExportFormat: String, CaseIterable, Sendable {
    case ply
    case stl
    var fileExtension: String { rawValue }
    var contentType: UTType {
        UTType(filenameExtension: fileExtension) ?? .data
    }
}

nonisolated enum ReceiverSurfaceExportSource: Sendable {
    case lidar(URL, label: String)
    case photogrammetry(URL, transform: simd_float4x4?)
    case fusedDepth

    var suggestedName: String {
        switch self {
        case .lidar(_, let label): label
        case .photogrammetry: "photogrammetry"
        case .fusedDepth: "fused_depth"
        }
    }
    var title: String {
        switch self {
        case .lidar(_, let label): label.replacingOccurrences(of: "_", with: " ").capitalized
        case .photogrammetry: "photogrammetry"
        case .fusedDepth: "fused depth"
        }
    }
}

nonisolated struct ReceiverTriangleMesh: Sendable {
    var vertices: [SIMD3<Float>]
    var indices: [UInt32]
}

nonisolated enum ReceiverSurfaceExportError: LocalizedError {
    case invalidPLY
    case invalidScene
    case noTriangles
    case noFusionBounds

    var errorDescription: String? {
        switch self {
        case .invalidPLY: "The LiDAR PLY could not be decoded."
        case .invalidScene: "The photogrammetry model could not be opened."
        case .noTriangles: "The selected surface contains no exportable triangles."
        case .noFusionBounds: "Fused Depth needs the saved head region, head mesh, or fiducials."
        }
    }
}

nonisolated enum ReceiverSurfaceExporter {
    static func modelToWorld(_ reconstruction: MANTAReconstructionReference) -> simd_float4x4? {
        guard let values = reconstruction.modelToWorld, values.count == 16 else { return nil }
        return simd_float4x4(
            SIMD4(Float(values[0]), Float(values[1]), Float(values[2]), Float(values[3])),
            SIMD4(Float(values[4]), Float(values[5]), Float(values[6]), Float(values[7])),
            SIMD4(Float(values[8]), Float(values[9]), Float(values[10]), Float(values[11])),
            SIMD4(Float(values[12]), Float(values[13]), Float(values[14]), Float(values[15])))
    }

    static func fusionInput(_ bundle: MANTAValidatedBundle) throws -> ReceiverDepthFusionInput {
        let reconstruction = bundle.capture.reconstruction
        let headURL = reconstruction?.headCroppedLidarMeshPath.map {
            bundle.rootDirectory.appendingPathComponent($0)
        }
        let fiducials = (bundle.capture.fiducials ?? []).compactMap { value -> SIMD3<Float>? in
            guard value.coordinateSystem == "arkit-world",
                  let point = value.coordinate, point.count == 3 else { return nil }
            return SIMD3(Float(point[0]), Float(point[1]), Float(point[2]))
        }
        guard reconstruction?.headBoundingBox != nil || headURL != nil || !fiducials.isEmpty else {
            throw ReceiverSurfaceExportError.noFusionBounds
        }
        return ReceiverDepthFusionInput(
            rootDirectory: bundle.rootDirectory,
            observations: bundle.capture.observations.filter { $0.depth != nil },
            declaredBounds: reconstruction?.headBoundingBox,
            headMeshURL: headURL,
            fiducialCoordinates: fiducials)
    }

    nonisolated static func copyReplacing(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        try manager.copyItem(at: source, to: temporary)
        defer { try? manager.removeItem(at: temporary) }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }

    nonisolated static func loadBinaryPLY(_ url: URL) throws -> ReceiverTriangleMesh {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let marker = data.range(of: Data("end_header\n".utf8)) else {
            throw ReceiverSurfaceExportError.invalidPLY
        }
        let header = String(decoding: data[..<marker.lowerBound], as: UTF8.self)
        guard header.contains("format binary_little_endian 1.0") else {
            throw ReceiverSurfaceExportError.invalidPLY
        }
        var vertexCount = 0, faceCount = 0
        for line in header.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 3, fields[0] == "element" else { continue }
            if fields[1] == "vertex" { vertexCount = Int(fields[2]) ?? 0 }
            if fields[1] == "face" { faceCount = Int(fields[2]) ?? 0 }
        }
        guard vertexCount > 0, faceCount > 0 else {
            throw ReceiverSurfaceExportError.invalidPLY
        }
        let bytes = data[marker.upperBound...]
        var offset = bytes.startIndex
        func u32() throws -> UInt32 {
            guard offset + 4 <= bytes.endIndex else { throw ReceiverSurfaceExportError.invalidPLY }
            let value = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            offset += 4
            return value
        }
        var vertices = [SIMD3<Float>]()
        vertices.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            let point = SIMD3(
                Float(bitPattern: try u32()), Float(bitPattern: try u32()),
                Float(bitPattern: try u32()))
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                throw ReceiverSurfaceExportError.invalidPLY
            }
            vertices.append(point)
        }
        var indices = [UInt32]()
        indices.reserveCapacity(faceCount * 3)
        for _ in 0..<faceCount {
            guard offset < bytes.endIndex, bytes[offset] == 3 else {
                throw ReceiverSurfaceExportError.invalidPLY
            }
            offset += 1
            let triangle = [try u32(), try u32(), try u32()]
            guard triangle.allSatisfy({ $0 < UInt32(vertexCount) }) else {
                throw ReceiverSurfaceExportError.invalidPLY
            }
            indices.append(contentsOf: triangle)
        }
        return ReceiverTriangleMesh(vertices: vertices, indices: indices)
    }

    @MainActor static func loadSceneMesh(
        _ url: URL, modelToWorld: simd_float4x4?
    ) throws -> ReceiverTriangleMesh {
        guard let scene = try? SCNScene(url: url, options: nil) else {
            throw ReceiverSurfaceExportError.invalidScene
        }
        let holder = SCNNode()
        scene.rootNode.childNodes.forEach { holder.addChildNode($0.clone()) }
        if let modelToWorld { holder.simdTransform = modelToWorld }
        var output = ReceiverTriangleMesh(vertices: [], indices: [])
        holder.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry,
                  let source = geometry.sources(for: .vertex).first,
                  let localVertices = decodeVertices(source), !localVertices.isEmpty else { return }
            let base = UInt32(output.vertices.count)
            let transform = node.simdWorldTransform
            output.vertices.append(contentsOf: localVertices.map {
                let p = transform * SIMD4($0, 1)
                return SIMD3(p.x, p.y, p.z)
            })
            for element in geometry.elements {
                let localIndices = decodeTriangleIndices(element)
                output.indices.append(contentsOf: localIndices.map { base + $0 })
            }
        }
        guard !output.vertices.isEmpty, !output.indices.isEmpty else {
            throw ReceiverSurfaceExportError.noTriangles
        }
        return output
    }

    @MainActor private static func decodeVertices(_ source: SCNGeometrySource) -> [SIMD3<Float>]? {
        guard source.componentsPerVector >= 3, source.bytesPerComponent == 4,
              source.usesFloatComponents else { return nil }
        let data = source.data
        func component(_ offset: Int) -> Float? {
            guard offset + 4 <= data.count else { return nil }
            let bits = UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
            return Float(bitPattern: bits)
        }
        return (0..<source.vectorCount).compactMap { index in
            let offset = source.dataOffset + index * source.dataStride
            guard let x = component(offset), let y = component(offset + 4),
                  let z = component(offset + 8) else { return nil }
            return SIMD3(x, y, z)
        }
    }

    @MainActor private static func decodeTriangleIndices(_ element: SCNGeometryElement) -> [UInt32] {
        guard element.primitiveType == .triangles || element.primitiveType == .triangleStrip,
              [1, 2, 4].contains(element.bytesPerIndex) else { return [] }
        let indexCount = element.primitiveType == .triangles
            ? element.primitiveCount * 3 : element.primitiveCount + 2
        let data = element.data
        func index(_ position: Int) -> UInt32? {
            let offset = position * element.bytesPerIndex
            guard offset + element.bytesPerIndex <= data.count else { return nil }
            switch element.bytesPerIndex {
            case 1: return UInt32(data[offset])
            case 2: return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            default:
                return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
                    | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
            }
        }
        let values = (0..<indexCount).compactMap(index)
        guard values.count == indexCount else { return [] }
        if element.primitiveType == .triangles { return values }
        var triangles = [UInt32]()
        for i in 0..<max(0, values.count - 2) {
            let triangle = i.isMultiple(of: 2)
                ? [values[i], values[i + 1], values[i + 2]]
                : [values[i + 1], values[i], values[i + 2]]
            if Set(triangle).count == 3 { triangles.append(contentsOf: triangle) }
        }
        return triangles
    }

    nonisolated static func write(
        _ mesh: ReceiverTriangleMesh,
        format: ReceiverSurfaceExportFormat,
        to url: URL
    ) throws {
        switch format {
        case .ply: try writeMeshPLY(mesh, to: url)
        case .stl: try writeBinarySTL(mesh, to: url)
        }
    }

    nonisolated static func writePointCloud(
        _ cloud: ReceiverFusedDepthCloud, to url: URL
    ) throws {
        let writer = try ReceiverBinaryFileWriter(destination: url)
        try writer.write(Data("""
            ply
            format binary_little_endian 1.0
            comment MANTA fused RGB-D point cloud; coordinates in meters; ARKit world
            element vertex \(cloud.points.count)
            property float x
            property float y
            property float z
            property uchar red
            property uchar green
            property uchar blue
            element face 0
            property list uchar uint vertex_indices
            end_header
            """.utf8))
        for (index, point) in cloud.points.enumerated() {
            try writer.float(point.x); try writer.float(point.y); try writer.float(point.z)
            let color = cloud.colors.indices.contains(index)
                ? cloud.colors[index] : SIMD4<Float>(repeating: 1)
            try writer.byte(UInt8(clamping: Int((min(max(color.x, 0), 1) * 255).rounded())))
            try writer.byte(UInt8(clamping: Int((min(max(color.y, 0), 1) * 255).rounded())))
            try writer.byte(UInt8(clamping: Int((min(max(color.z, 0), 1) * 255).rounded())))
        }
        try writer.finish()
    }

    private nonisolated static func writeMeshPLY(
        _ mesh: ReceiverTriangleMesh, to url: URL
    ) throws {
        let writer = try ReceiverBinaryFileWriter(destination: url)
        try writer.write(Data("""
            ply
            format binary_little_endian 1.0
            comment MANTA surface; coordinates in meters
            element vertex \(mesh.vertices.count)
            property float x
            property float y
            property float z
            element face \(mesh.indices.count / 3)
            property list uchar uint vertex_indices
            end_header
            """.utf8))
        for point in mesh.vertices {
            try writer.float(point.x); try writer.float(point.y); try writer.float(point.z)
        }
        for index in stride(from: 0, to: mesh.indices.count, by: 3) {
            try writer.byte(3)
            try writer.uint32(mesh.indices[index])
            try writer.uint32(mesh.indices[index + 1])
            try writer.uint32(mesh.indices[index + 2])
        }
        try writer.finish()
    }

    private nonisolated static func writeBinarySTL(
        _ mesh: ReceiverTriangleMesh, to url: URL
    ) throws {
        let writer = try ReceiverBinaryFileWriter(destination: url)
        var header = Data(repeating: 0, count: 80)
        let label = Data("MANTA STL; millimeters".utf8)
        header.replaceSubrange(0..<label.count, with: label)
        try writer.write(header)
        try writer.uint32(UInt32(mesh.indices.count / 3))
        for offset in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.vertices[Int(mesh.indices[offset])] * 1000
            let b = mesh.vertices[Int(mesh.indices[offset + 1])] * 1000
            let c = mesh.vertices[Int(mesh.indices[offset + 2])] * 1000
            let cross = simd_cross(b - a, c - a)
            let normal = simd_length_squared(cross) > 1e-12 ? simd_normalize(cross) : .zero
            for value in [normal, a, b, c] {
                try writer.float(value.x); try writer.float(value.y); try writer.float(value.z)
            }
            try writer.uint16(0)
        }
        try writer.finish()
    }
}

private nonisolated final class ReceiverBinaryFileWriter {
    private let destination: URL
    private let temporary: URL
    private let handle: FileHandle
    private var buffer = Data()
    private var finished = false

    init(destination: URL) throws {
        self.destination = destination
        temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        handle = try FileHandle(forWritingTo: temporary)
        buffer.reserveCapacity(1_048_576)
    }

    deinit {
        try? handle.close()
        if !finished { try? FileManager.default.removeItem(at: temporary) }
    }

    func write(_ data: Data) throws {
        buffer.append(data)
        if buffer.count >= 1_048_576 { try flush() }
    }
    func byte(_ value: UInt8) throws {
        buffer.append(value)
        try flushIfNeeded()
    }
    func uint16(_ value: UInt16) throws {
        buffer.append(UInt8(truncatingIfNeeded: value))
        buffer.append(UInt8(truncatingIfNeeded: value >> 8))
        try flushIfNeeded()
    }
    func uint32(_ value: UInt32) throws {
        buffer.append(UInt8(truncatingIfNeeded: value))
        buffer.append(UInt8(truncatingIfNeeded: value >> 8))
        buffer.append(UInt8(truncatingIfNeeded: value >> 16))
        buffer.append(UInt8(truncatingIfNeeded: value >> 24))
        try flushIfNeeded()
    }
    func float(_ value: Float) throws { try uint32(value.bitPattern) }

    func finish() throws {
        try flush()
        try handle.synchronize()
        try handle.close()
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
        finished = true
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private func flushIfNeeded() throws {
        if buffer.count >= 1_048_576 { try flush() }
    }
}

nonisolated enum ReceiverCoordinateExportFrame: String, CaseIterable, Identifiable, Sendable {
    case arkitWorld
    case headRAS
    var id: String { rawValue }
    var title: String {
        switch self {
        case .arkitWorld: "ARKit world · meters"
        case .headRAS: "Fiducial-derived Head RAS"
        }
    }
    var filenameLabel: String {
        switch self {
        case .arkitWorld: "arkit-world"
        case .headRAS: "head-ras"
        }
    }
}

nonisolated enum ReceiverCoordinateExportFormat: Sendable {
    case csv, sfp, egiXML
    var contentType: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .sfp: UTType(filenameExtension: "sfp") ?? .plainText
        case .egiXML: .xml
        }
    }
}

nonisolated struct ReceiverCoordinateExportPayload: Sendable {
    var filename: String
    var data: Data
}

nonisolated enum ReceiverCoordinateExportError: LocalizedError {
    case missingHeadFrame
    case noCoordinates
    var errorDescription: String? {
        switch self {
        case .missingHeadFrame: "Head RAS requires Nasion, LPA, and RPA in ARKit world coordinates."
        case .noCoordinates: "This capture contains no electrode or fiducial coordinates."
        }
    }
}

nonisolated enum ReceiverCoordinateExporter {
    private struct Item {
        var type: String
        var label: String
        var pointMeters: SIMD3<Double>
        var state: String
        var confidence: Double?
    }

    static func hasHeadFrame(_ bundle: MANTAValidatedBundle) -> Bool {
        headTransform(bundle) != nil
    }

    static func export(
        _ bundle: MANTAValidatedBundle,
        frame: ReceiverCoordinateExportFrame,
        format: ReceiverCoordinateExportFormat
    ) throws -> ReceiverCoordinateExportPayload {
        var items = rawItems(bundle)
        guard !items.isEmpty else { throw ReceiverCoordinateExportError.noCoordinates }
        if frame == .headRAS {
            guard let transform = headTransform(bundle) else {
                throw ReceiverCoordinateExportError.missingHeadFrame
            }
            items = items.map { item in
                var item = item
                let p = transform * SIMD4<Float>(
                    Float(item.pointMeters.x), Float(item.pointMeters.y),
                    Float(item.pointMeters.z), 1)
                item.pointMeters = SIMD3(Double(p.x), Double(p.y), Double(p.z))
                return item
            }
        }
        let text: String
        let filename: String
        switch format {
        case .csv:
            let unit = frame == .headRAS ? "mm" : "m"
            let coordinateSystem = frame == .headRAS ? "head-ras" : "arkit-world"
            let scale = frame == .headRAS ? 1000.0 : 1.0
            let header = "type,label,x,y,z,unit,coordinate_system,state,confidence"
            let rows = items.map { item in
                [item.type, item.label,
                 number(item.pointMeters.x * scale), number(item.pointMeters.y * scale),
                 number(item.pointMeters.z * scale), unit, coordinateSystem,
                 csvEscaped(item.state), item.confidence.map { String(format: "%.3f", $0) } ?? ""]
                    .joined(separator: ",")
            }
            text = ([header] + rows).joined(separator: "\n") + "\n"
            filename = "manta_coordinates_\(coordinateSystem).csv"
        case .sfp:
            text = items.map { item in
                let label = switch item.label {
                case FiducialKind.nasion.rawValue: "FidNz"
                case FiducialKind.leftPreauricular.rawValue: "FidT9"
                case FiducialKind.rightPreauricular.rawValue: "FidT10"
                default: item.label
                }
                return [label, sfpNumber(item.pointMeters.x), sfpNumber(item.pointMeters.y),
                        sfpNumber(item.pointMeters.z)].joined(separator: "\t")
            }.joined(separator: "\n") + "\n"
            filename = "manta_coordinates_\(frame.filenameLabel).sfp"
        case .egiXML:
            let sensors = items.enumerated().map { index, item -> String in
                let centimeters = item.pointMeters * 100
                let metadata: (String, Int, Int)
                switch item.label {
                case FiducialKind.nasion.rawValue: metadata = ("Nasion", 2002, 2)
                case FiducialKind.leftPreauricular.rawValue: metadata = ("Left periauricular point", 2011, 2)
                case FiducialKind.rightPreauricular.rawValue: metadata = ("Right periauricular point", 2010, 2)
                case "Cz":
                    let referenceNumber = bundle.capture.layoutID
                        .localizedCaseInsensitiveContains("256") ? 257 : 129
                    metadata = ("VREF", referenceNumber, 1)
                default:
                    metadata = ("", Int(item.label.drop(while: { !$0.isNumber })) ?? index + 1, 0)
                }
                return """
                                <sensor>
                                    <name>\(xmlEscaped(metadata.0))</name>
                                    <number>\(metadata.1)</number>
                                    <type>\(metadata.2)</type>
                                    <x>\(sfpNumber(centimeters.x))</x>
                                    <y>\(sfpNumber(centimeters.y))</y>
                                    <z>\(sfpNumber(centimeters.z))</z>
                                </sensor>
                    """
            }.joined(separator: "\n")
            text = """
                <?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
                <coordinates xmlns="http://www.egi.com/coordinates_mff">
                    <sensorLayout>
                        <name>\(xmlEscaped(bundle.capture.layoutID))</name>
                        <sensors>
                \(sensors)
                        </sensors>
                    </sensorLayout>
                    <acqMethod>MANTA LiDAR and photogrammetry; coordinate frame: \(frame.filenameLabel)</acqMethod>
                    <defaultSubject>false</defaultSubject>
                </coordinates>
                """
            filename = "manta_coordinates_\(frame.filenameLabel).xml"
        }
        return ReceiverCoordinateExportPayload(filename: filename, data: Data(text.utf8))
    }

    private static func rawItems(_ bundle: MANTAValidatedBundle) -> [Item] {
        let electrodes = (bundle.capture.electrodes ?? []).compactMap { value -> Item? in
            guard value.coordinateSystem == "arkit-world", value.coordinate.count == 3 else { return nil }
            return Item(
                type: "electrode", label: value.label,
                pointMeters: SIMD3(value.coordinate[0], value.coordinate[1], value.coordinate[2]),
                state: value.state, confidence: value.confidence)
        }
        let fiducials = (bundle.capture.fiducials ?? []).compactMap { value -> Item? in
            guard value.coordinateSystem == "arkit-world",
                  let point = value.coordinate, point.count == 3 else { return nil }
            return Item(
                type: "fiducial", label: value.kind,
                pointMeters: SIMD3(point[0], point[1], point[2]),
                state: value.state, confidence: nil)
        }
        return electrodes + fiducials
    }

    private static func headTransform(_ bundle: MANTAValidatedBundle) -> simd_float4x4? {
        let values = Dictionary(uniqueKeysWithValues: (bundle.capture.fiducials ?? []).compactMap {
            value -> (FiducialKind, SIMD3<Float>)? in
            guard value.coordinateSystem == "arkit-world",
                  let kind = FiducialKind(rawValue: value.kind),
                  let point = value.coordinate, point.count == 3 else { return nil }
            return (kind, SIMD3(Float(point[0]), Float(point[1]), Float(point[2])))
        })
        guard let nasion = values[.nasion], let left = values[.leftPreauricular],
              let right = values[.rightPreauricular] else { return nil }
        return HeadCoordinateFrame.solve(
            nasion: nasion, leftPreauricular: left, rightPreauricular: right)
    }

    private static func number(_ value: Double) -> String { String(format: "%.6f", value) }
    private static func sfpNumber(_ value: Double) -> String { String(format: "%.9f", value) }
    private static func csvEscaped(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    private static func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
