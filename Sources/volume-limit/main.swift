import Foundation
import VolumeLimitCLI

runVolumeLimitCLI(
    arguments: Array(CommandLine.arguments.dropFirst()),
    executablePath: CommandLine.arguments.first ?? "volume-limit"
)
