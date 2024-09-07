import XCTest

@testable import OllamaKit

final class OllamaKitTests: XCTestCase {
    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        super.tearDown()
    }

    func testGenerateSuccess() async throws {

    }

    func testGenerateFailure() async throws {

    }

    func testModelsSuccess() async throws {

    }

    func testModelsFailure() async throws {

    }

    func testModelInfoSuccess() async throws {

    }

    func testModelInfoFailure() async throws {

    }

    func testCopyModelSuccess() async throws {

    }

    func testCopyModelFailure() async throws {

    }

    func testDeleteModelSuccess() async throws {

    }

    func testDeleteModelFailure() async throws {

    }

    func testEmbeddingsFailure() async throws {

    }

    func testChat() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            let mainTask = Task {
                print("starting testChat")
                let ollamaKit = OllamaKit(baseURL: URL(string: "http://localhost:11434")!)

                var receivedContent = false

                for try await response in ollamaKit.chat(
                    data: .init(model: "llama3", messages: [.init(role: .user, content: "hello")]))
                {
                    if let content = response.message?.content {
                        receivedContent = true
                        print(content)
                    }
                }

                try Task.checkCancellation()

                print("Done")
                XCTAssertTrue(receivedContent)
            }

            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(20))
                mainTask.cancel()
                XCTFail("Timed out!")
            }

            let _ = try await mainTask.value
            timeoutTask.cancel()
        }
    }
}
