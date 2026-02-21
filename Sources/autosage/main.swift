import Foundation
import AutoSageCore

private func usage() {
    print("Usage:")
    print("  autosage ngspice-smoketest")
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    usage()
    exit(1)
}

switch arguments[1] {
case "ngspice-smoketest":
    do {
        let result = try NgSpiceRunner.runSmokeTest(timeoutS: 30)
        let parsedCount = result.parsed?.pointCount ?? 0
        print("ngspice smoketest passed")
        print("raw: \(result.rawPath)")
        print("points: \(parsedCount)")
        exit(0)
    } catch let error as NgSpiceRunnerError {
        fputs("ngspice smoketest failed: \(error.code): \(error.message)\n", stderr)
        if !error.details.isEmpty {
            for key in error.details.keys.sorted() {
                let value = error.details[key] ?? ""
                fputs("\(key): \(value)\n", stderr)
            }
        }
        exit(1)
    } catch {
        fputs("ngspice smoketest failed: \(error)\n", stderr)
        exit(1)
    }
default:
    usage()
    exit(1)
}
