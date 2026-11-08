import AppKit

/// Puts the `shrinkbox` command on the PATH by linking the app's executable, and takes it away again.
enum CLIInstaller {
    static var executable: URL { Bundle.main.executableURL ?? URL(fileURLWithPath: "/Applications/Shrinkbox.app/Contents/MacOS/Shrinkbox") }

    static var folders: [String] { ["/opt/homebrew/bin", "/usr/local/bin", (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")] }

    /// Where the command points at this app, if anywhere.
    static var installedAt: String? {
        for dir in folders {
            let link = (dir as NSString).appendingPathComponent("shrinkbox")
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { continue }
            if URL(fileURLWithPath: dest).resolvingSymlinksInPath().path == executable.resolvingSymlinksInPath().path { return link }
        }
        return nil
    }

    /// A folder on the PATH that can be written without a password, or nil.
    static var writableFolder: String? {
        folders.first { dir in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue && FileManager.default.isWritableFile(atPath: dir)
        }
    }

    /// Links the command. Returns where, or an error message. Falls back to an administrator prompt for /usr/local/bin.
    @MainActor
    static func install() -> Result<String, ShrinkError> {
        let exe = executable.path
        if let dir = writableFolder {
            let link = (dir as NSString).appendingPathComponent("shrinkbox")
            try? FileManager.default.removeItem(atPath: link)
            do { try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: exe); return .success(link) }
            catch { return .failure(.failed(error.localizedDescription)) }
        }
        let command = "mkdir -p /usr/local/bin && ln -sf " + shellQuote(exe) + " /usr/local/bin/shrinkbox"
        var error: NSDictionary?
        NSAppleScript(source: adminScript(command))?.executeAndReturnError(&error)
        if let e = error { return .failure(.failed((e[NSAppleScript.errorMessage] as? String) ?? L("Installation failed"))) }
        return .success("/usr/local/bin/shrinkbox")
    }

    @MainActor
    static func uninstall() -> Result<Void, ShrinkError> {
        guard let link = installedAt else { return .success(()) }
        do { try FileManager.default.removeItem(atPath: link); return .success(()) }
        catch {
            var e: NSDictionary?
            NSAppleScript(source: adminScript("rm " + shellQuote(link)))?.executeAndReturnError(&e)
            return e == nil ? .success(()) : .failure(.failed(L("Installation failed")))
        }
    }

    private static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// AppleScript that runs a shell command after asking for the administrator password.
    private static func adminScript(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"" + escaped + "\" with administrator privileges"
    }
}
