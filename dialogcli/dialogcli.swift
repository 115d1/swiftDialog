
//
//  dialogcli
//
//  Created by Bart E Reardon on 7/7/2025.
//

import Foundation
import SystemConfiguration
import ArgumentParser

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

@main
struct DialogLauncher: ParsableCommand {
    @Option(name: .long, help: "Path to the command file")
    var commandfile: String?

    @Argument(parsing: .captureForPassthrough)
    var passthroughArgs: [String] = []

    func run() throws {
        let defaultCommandFile = "/var/tmp/dialog.log"
        let dialogAppPath = "/Library/Application Support/Dialog/Dialog.app"
        let dialogBinary = "\(dialogAppPath)/Contents/MacOS/Dialog"

        guard FileManager.default.fileExists(atPath: dialogBinary) else {
            fputs("ERROR: Cannot find swiftDialog binary at \(dialogBinary)\n", stderr)
            throw ExitCode(255)
        }

        let commandFilePath = commandfile ?? defaultCommandFile

        if FileManager.default.destinationOfSymbolicLinkSafe(atPath: commandFilePath) != nil {
            fputs("ERROR: \(commandFilePath) is a symbolic link - aborting\n", stderr)
            throw ExitCode(1)
        }

        if !FileManager.default.fileExists(atPath: commandFilePath) {
            FileManager.default.createFile(atPath: commandFilePath, contents: nil)
        } else if !FileManager.default.isReadableFile(atPath: commandFilePath) {
            fputs("WARNING: \(commandFilePath) is not readable\n", stderr)
        }

        let (user, userUID) = getConsoleUserInfo()

        guard !user.isEmpty && userUID != 0 else {
            fputs("ERROR: Unable to determine current GUI user\n", stderr)
            throw ExitCode(1)
        }

        if getuid() == 0 {
            if !canUserReadFile(user: user, file: commandFilePath) {
                fputs("ERROR: \(commandFilePath) is not readable by user \(user)\n", stderr)
                throw ExitCode(1)
            }

            let result = runAsUser(uid: userUID, user: user, binary: dialogBinary, args: passthroughArgs)
            print(result.stdout)
            fputs(result.stderr, stderr)
            throw ExitCode(result.status)
        } else {
            let result = runCommand(binary: dialogBinary, args: passthroughArgs)
            print(result.stdout)
            fputs(result.stderr, stderr)
            throw ExitCode(result.status)
        }
    }

    func getConsoleUserInfo() -> (username: String, userID: UInt32) {
        var uid: uid_t = 0
        if let consoleUser = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as? String {
            return (consoleUser, uid)
        } else {
            return ("", 0)
        }
    }

    func runAsUser(uid: UInt32, user: String, binary: String, args: [String]) -> CommandResult {
        fputs("Switching User\n", stderr)
        guard FileManager.default.fileExists(atPath: binary) else {
            return CommandResult(status: 255, stdout: "", stderr: "App path does not exist: \(binary)")
        }

        var commandArgs = ["asuser", "\(uid)", "sudo", "-H", "-u", user, binary]
        if !args.isEmpty {
            commandArgs.append(contentsOf: args)
        }

        return runCommand(binary: "/bin/launchctl", args: commandArgs)
    }

    func runCommand(binary: String, args: [String]) -> CommandResult {
        let process = Process()
        process.launchPath = binary
        process.arguments = args

        fputs("running \(binary) \(args)\n", stderr)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        } catch {
            return CommandResult(status: 255, stdout: "", stderr: "Failed to run process: \(error)")
        }
    }

    func canUserReadFile(user: String, file: String) -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments = ["-u", user, "test", "-r", file]
        task.launch()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}

extension FileManager {
    func destinationOfSymbolicLinkSafe(atPath path: String) -> String? {
        var isSymlink = ObjCBool(false)
        guard fileExists(atPath: path, isDirectory: &isSymlink), isSymlink.boolValue else {
            return nil
        }
        return try? destinationOfSymbolicLink(atPath: path)
    }
}
