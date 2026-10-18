import Foundation
import FileProvider

let domainControlServiceName = NSFileProviderServiceName("local.mydrive.control")

@objc protocol DomainControlProtocol {
    #if MYDRIVE_DEVELOPMENT
    func useDevelopmentCredential(_ password: String, reply: @escaping (NSError?) -> Void)
    func forgetDevelopmentCredential(reply: @escaping (NSError?) -> Void)
    #endif
    func refresh(reply: @escaping (NSError?) -> Void)
    func keepDownloaded(_ identifiers: [String], reply: @escaping (NSError?) -> Void)
    func freeUpSpace(_ identifiers: [String], reply: @escaping (Int, [String], NSError?) -> Void)
    func freeUpAllSpace(reply: @escaping (Int, [String], NSError?) -> Void)
    func prepareForRemoval(reply: @escaping (Int, [String], NSError?) -> Void)
}
