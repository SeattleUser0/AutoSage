import Foundation

public final class RequestIDGenerator {
    private let lock = NSLock()
    private var responseCounter: Int
    private var chatCompletionCounter: Int
    private var toolCallCounter: Int
    private var jobCounter: Int

    public init(
        responseStart: Int = 0,
        chatCompletionStart: Int = 0,
        toolCallStart: Int = 0,
        jobStart: Int = 0
    ) {
        self.responseCounter = responseStart
        self.chatCompletionCounter = chatCompletionStart
        self.toolCallCounter = toolCallStart
        self.jobCounter = jobStart
    }

    public func nextResponseID() -> String {
        lock.lock()
        defer { lock.unlock() }
        responseCounter += 1
        return formattedID(prefix: "resp", value: responseCounter)
    }

    public func nextChatCompletionID() -> String {
        lock.lock()
        defer { lock.unlock() }
        chatCompletionCounter += 1
        return formattedID(prefix: "chatcmpl", value: chatCompletionCounter)
    }

    public func nextToolCallID() -> String {
        lock.lock()
        defer { lock.unlock() }
        toolCallCounter += 1
        return formattedID(prefix: "call", value: toolCallCounter)
    }

    public func nextJobID() -> String {
        lock.lock()
        defer { lock.unlock() }
        jobCounter += 1
        return formattedID(prefix: "job", value: jobCounter)
    }

    public func seedJobCounterIfHigher(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        if value > jobCounter {
            jobCounter = value
        }
    }

    private func formattedID(prefix: String, value: Int) -> String {
        return String(format: "\(prefix)_%04d", value)
    }
}
