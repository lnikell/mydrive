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
    func clearCache(reply: @escaping (Int, [String], NSError?) -> Void)
    func snapshot(_ measureCache: Bool, reply: @escaping (Data?, NSError?) -> Void)
    func library(_ scope: String, afterID: String?, generation: NSNumber?, reply: @escaping (Data?, NSError?) -> Void)
    func clearActivity(reply: @escaping (NSError?) -> Void)
    func resolveActivity(_ identifier: String, reply: @escaping (NSError?) -> Void)
    func maintainCache(_ bytes: Int64, ageDays: Int, reply: @escaping (Int64, NSError?) -> Void)
    func setMountOffline(_ keep: Bool, reply: @escaping (NSError?) -> Void)
    func prepareForRemoval(reply: @escaping (Int, [String], NSError?) -> Void)
}
