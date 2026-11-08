"""Host-only contract for the exact DEBUG location fixture, without Simulator.

These synthetic helper probes do not prove CoreLocation or native UI acceptance.
The independent intent must return even when the provider Task is not cancelled.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "DayPageLocal/NoteLocationCapture.swift"
HARNESS = r'''
extension QALocationIntentGate {
  func installedForContract() -> Bool {
    lock.lock()
    let value = waiter != nil
    lock.unlock()
    return value
  }
  func completedForContract() -> Bool {
    lock.lock()
    let value = completed
    lock.unlock()
    return value
  }
}

private final class CompletionCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.lock(); count += 1; lock.unlock() }
  func read() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}

private struct ProbeResult: Sendable {
  let name: String
  let elapsedMilliseconds: Double
}

@main struct IntentGateContract {
  static func until(_ condition: () -> Bool) async {
    let stop = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
    while !condition() {
      precondition(DispatchTime.now().uptimeNanoseconds < stop, "Synthetic contract deadline")
      await Task.yield()
    }
  }

  private static func probe(_ mode: String) async -> ProbeResult {
    let gate = QALocationIntentGate()
    let count = CompletionCount()
    var lease: QALocationIntentLease? = mode == "owner_release" ? QALocationIntentLease(gate) : nil
    weak var weakLease = lease
    var signalledAt = DispatchTime.now().uptimeNanoseconds

    if mode == "signal_before_install" || mode == "completed_before_install" {
      gate.releaseAfterCancellationIntent()
      if mode == "completed_before_install" {
        await until { gate.completedForContract() }
      }
    }
    let task = Task.detached {
      await gate.wait()
      count.increment()
    }
    if mode != "completed_before_install" {
      await until { gate.installedForContract() }
    }
    if mode == "cancel_without_intent" {
      task.cancel()
      try? await Task.sleep(for: .milliseconds(200))
      precondition(count.read() == 0, "Task cancellation must not release the synthetic provider")
    }
    if mode == "owner_release" {
      signalledAt = DispatchTime.now().uptimeNanoseconds
      lease = nil
      precondition(weakLease == nil, "The provider must not retain its owner lease")
    } else if mode != "signal_before_install" && mode != "completed_before_install" {
      signalledAt = DispatchTime.now().uptimeNanoseconds
      gate.releaseAfterCancellationIntent()
    }
    if mode == "repeated_intent" {
      try? await Task.sleep(for: .seconds(2))
      gate.releaseAfterCancellationIntent()
      gate.releaseAfterCancellationIntent()
    }
    await task.value
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - signalledAt) / 1_000_000
    precondition(count.read() == 1 && gate.completedForContract(), "Exactly one real provider return is required")
    precondition(!gate.installedForContract(), "The continuation slot must be released")
    precondition(elapsed >= 9_500 && elapsed < 15_000, "The original real ten-second deadline must run")
    if mode == "repeated_intent" {
      precondition(elapsed < 11_500, "A later intent must not reset the first deadline")
    }
    return ProbeResult(name: mode, elapsedMilliseconds: elapsed)
  }

  static func main() async {
    async let first = probe("intent_only_uncancelled_task")
    async let before = probe("signal_before_install")
    async let completed = probe("completed_before_install")
    async let repeated = probe("repeated_intent")
    async let cancelled = probe("cancel_without_intent")
    async let released = probe("owner_release")
    let results = await [first, before, completed, repeated, cancelled, released]
    // Let any incorrectly duplicated same-deadline dispatch execute too.
    try? await Task.sleep(for: .milliseconds(200))
    for result in results {
      print("PASS \(result.name) \(result.elapsedMilliseconds) ms")
    }
    print("LOCATION_INTENT_CONTRACT_PASS 6")
  }
}
'''


def main():
    source = SOURCE.read_text()
    match = re.search(r"^#if DEBUG\n(.*?)^#endif$", source, re.S | re.M)
    assert match, "The private DEBUG fixture helpers must be present"
    helpers = match.group(1)
    assert "private final class QALocationIntentGate" in helpers
    assert "private final class QALocationIntentLease" in helpers
    compiler = subprocess.check_output(["xcrun", "--sdk", "macosx", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="daypage-location-intent-", dir=os.environ.get("RUNNER_TEMP")) as directory:
        root = Path(directory)
        swift = root / "LocationIntentContract.swift"
        binary = root / "LocationIntentContract"
        swift.write_text("import Foundation\n\n" + helpers + "\n" + HARNESS)
        compiled = subprocess.run([compiler, "-sdk", sdk, "-swift-version", "5", "-DDEBUG", "-strict-concurrency=complete",
                                   "-parse-as-library", str(swift), "-o", str(binary)], capture_output=True, text=True, timeout=90)
        if compiled.returncode:
            raise AssertionError("The exact fixture helpers did not compile:\n" + compiled.stderr)
        if compiled.stderr:
            print(compiled.stderr, end="")
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=25)
        assert result.returncode == 0, "Fixture intent contract failed:\n" + result.stdout + result.stderr
        assert "LOCATION_INTENT_CONTRACT_PASS 6" in result.stdout
        print(result.stdout, end="")
    print(json.dumps({"scope": "host-only synthetic helper; no native UI or real location acceptance",
                      "helper_sha256": hashlib.sha256(helpers.encode()).hexdigest(), "cases": 6}))


if __name__ == "__main__":
    main()
