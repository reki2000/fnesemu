import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// security scoped directories and files: picks them, keeps accessing them and
/// makes their bookmarks, so that a sandboxed app can open them again after a
/// restart. the files are read by dart:io.
///
/// a sandboxed app needs the entitlements:
/// - com.apple.security.files.user-selected.read-only
/// - com.apple.security.files.bookmarks.app-scope
public class MpBigfilePickerPlugin: NSObject, FlutterPlugin {
  private var picking = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "mp_bigfile_picker", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(MpBigfilePickerPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "pickDirectory":
      pick(result, title: args?["title"] as? String, files: false, extensions: nil, multiple: false)
    case "pickFiles":
      pick(result, title: args?["title"] as? String, files: true,
           extensions: args?["extensions"] as? [String], multiple: args?["multiple"] as? Bool ?? false)
    case "restore":
      result(restore(call.arguments as? String))
    case "release":
      release(call.arguments as? String)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func pick(_ result: @escaping FlutterResult, title: String?, files: Bool,
                    extensions: [String]?, multiple: Bool) {
    guard !picking else {
      result(FlutterError(code: "busy", message: "already picking", details: nil))
      return
    }
    picking = true
    let panel = NSOpenPanel()
    panel.canChooseDirectories = !files
    panel.canChooseFiles = files
    panel.allowsMultipleSelection = multiple
    if let title = title { panel.message = title }
    if let extensions = extensions {
      panel.allowedContentTypes = extensions.map { UTType(filenameExtension: $0) ?? .data }
    }
    panel.begin { response in
      self.picking = false
      guard response == .OK else {
        result(nil)
        return
      }
      let picked = panel.urls.map(self.access)
      if files {
        result(picked)
      } else {
        result(picked.first)
      }
    }
  }

  /// the path and the bookmark of [url], which is accessed while the app is
  /// running
  private func access(_ url: URL) -> [String: String] {
    // false if the app is not sandboxed, where the url is readable anyway
    _ = url.startAccessingSecurityScopedResource()
    var r = ["path": url.path]
    r["key"] = bookmark(url)
    return r
  }

  private func bookmark(_ url: URL) -> String? {
    let data = (try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                      includingResourceValuesForKeys: nil, relativeTo: nil))
      ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    return data?.base64EncodedString()
  }

  /// the path and the bookmark (made again if stale) of a bookmark
  private func restore(_ key: String?) -> [String: String]? {
    guard let key = key, let data = Data(base64Encoded: key) else { return nil }
    var stale = false
    let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                        relativeTo: nil, bookmarkDataIsStale: &stale))
      ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
    guard let url = url else { return nil }
    var r = access(url)
    if !stale { r["key"] = key }
    return r
  }

  /// stops accessing the directory or file of a bookmark
  private func release(_ key: String?) {
    guard let key = key, let data = Data(base64Encoded: key) else { return }
    var stale = false
    let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                        relativeTo: nil, bookmarkDataIsStale: &stale))
      ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
    url?.stopAccessingSecurityScopedResource()
  }
}
