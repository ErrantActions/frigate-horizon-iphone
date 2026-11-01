import Foundation

public struct NativePushDeviceMetadata: Decodable, Sendable {
    public let installationID: UUID
    public let cameraIDs: [String]?
    private enum CodingKeys: String, CodingKey { case installationID = "installation_id"; case cameraIDs = "camera_ids" }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        installationID = try values.decode(UUID.self, forKey: .installationID)
        guard values.contains(.cameraIDs) else {
            throw HorizonError.message("The device metadata omitted camera choices. Renewal was not attempted.")
        }
        cameraIDs = try values.decodeIfPresent([String].self, forKey: .cameraIDs)
        guard cameraIDs?.allSatisfy(NativeNotificationRoute.isValidIdentifier) != false else {
            throw HorizonError.message("The server returned invalid notification camera choices.")
        }
    }
}

public struct NativePushSelection: Equatable, Sendable {
    public private(set) var known = false
    public private(set) var cameraIDs: [String]?
    public init() {}
    public mutating func confirm(_ ids: [String]?) {
        cameraIDs = ids.map { Array(Set($0)).sorted() }
        known = true
    }
    public func renewalCameras() throws -> [String]? {
        guard known else { throw HorizonError.message("Refresh this installation's actual notification camera choices before renewing.") }
        return cameraIDs
    }
}
