import Foundation
import HorizonCore

final class HorizonRecordedHTTPClient: RecordedHTTPControlClient, @unchecked Sendable {
    private let api: HorizonAPI
    private let account: String
    var address: ServerAddress { api.address }
    var cookies: [HTTPCookie] { api.cookies }
    init(api: HorizonAPI) throws {
        guard let account = api.viewingAccountKey else { throw HorizonError.unauthorized }
        self.api=api; self.account=account
    }
    func request(_ url: URL, method: String, body: Data?, success: Set<Int>) async throws -> RecordedHTTPControlResponse {
        guard api.viewingAccountKey == account else { throw HorizonError.unauthorized }
        let result = try await api.viewerResponse(url, method: method, body: body, success: success)
        let headers = result.response.allHeaderFields.reduce(into: [String: String]()) { fields, item in
            if let key = item.key as? String, let value = item.value as? String { fields[key]=value }
        }
        return RecordedHTTPControlResponse(data: result.data, status: result.response.statusCode, headers: headers)
    }
}
