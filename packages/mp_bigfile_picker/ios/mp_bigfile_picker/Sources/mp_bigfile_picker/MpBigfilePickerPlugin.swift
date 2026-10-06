import Flutter
import UIKit
import UniformTypeIdentifiers

/// security scoped directories and files: picks them, keeps accessing them and
/// makes their bookmarks. the files are read by dart:io.
public class MpBigfilePickerPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private var pending: FlutterResult?
  private var pickingFiles = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "mp_bigfile_picker", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(MpBigfilePickerPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "pickDirectory":
      pick(result, types: [.folder], multiple: false, files: false)
    case "pickFiles":
      let extensions = args?["extensions"] as? [String]
      let types = extensions?.map { UTType(filenameExtension: $0) ?? .data } ?? [.item]
      pick(result, types: types, multiple: args?["multiple"] as? Bool ?? false, files: true)
    case "restore":
      result(restore(call.arguments as? String))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func pick(_ result: @escaping FlutterResult, types: [UTType], multiple: Bool, files: Bool) {
    guard pending == nil, let top = topViewController() else {
      result(FlutterError(code: "busy", message: "no view controller, or already picking", details: nil))
      return
    }
    pending = result
    pickingFiles = files
    // opens the originals, not copies
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
    picker.delegate = self
    picker.allowsMultipleSelection = multiple
    top.present(picker, animated: true)
  }

  public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pending else { return }
    pending = nil
    let picked = urls.map(access)
    if pickingFiles {
      result(picked)
    } else {
      result(picked.first)
    }
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pending?(nil)
    pending = nil
  }

  /// the path and the bookmark of [url], which is accessed while the app is
  /// running
  private func access(_ url: URL) -> [String: String] {
    _ = url.startAccessingSecurityScopedResource()
    var r = ["path": url.path]
    r["key"] = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))?
      .base64EncodedString()
    return r
  }

  /// the path and the bookmark (made again if stale) of a bookmark
  private func restore(_ key: String?) -> [String: String]? {
    guard let key = key, let data = Data(base64Encoded: key) else { return nil }
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
    var r = access(url)
    if !stale { r["key"] = key }
    return r
  }

  private func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
