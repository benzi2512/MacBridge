import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class ToolDiscoveryTests: XCTestCase {
    private func rows(_ arguments: JSONObject = [:]) throws -> [JSONObject] {
        try XCTUnwrap(ToolDiscovery.catalog(arguments)["tools"] as? [JSONObject])
    }

    func testCompactIndexDoesNotRepeatAliasOrFullSchemas() throws {
        let starter = try ToolDiscovery.catalog([:])
        XCTAssertEqual(starter["selection"] as? String, "starter")
        XCTAssertEqual(try rows().compactMap { $0["name"] as? String }, ToolDiscovery.starterNames)
        XCTAssertEqual(try rows().first?["name"] as? String, "bridge_capabilities")
        XCTAssertEqual(starter["returned_count"] as? Int, 14)
        XCTAssertEqual(starter["truncated"] as? Bool, true)
        let result = try ToolDiscovery.catalog(["limit": 77]), index = try rows(["limit": 77])
        XCTAssertEqual(result["catalog_count"] as? Int, 77)
        XCTAssertEqual(result["canonical_count"] as? Int, 76)
        XCTAssertEqual(result["returned_count"] as? Int, 76)
        XCTAssertEqual(result["matched_count"] as? Int, 76)
        XCTAssertEqual(result["truncated"] as? Bool, false)
        XCTAssertEqual(index.count, Set(index.compactMap { $0["canonical_name"] as? String }).count)
        XCTAssertFalse(index.contains { $0["name"] as? String == "workspace_list" })
        XCTAssertTrue(index.allSatisfy { $0["inputSchema"] == nil && $0["deprecated"] as? Bool == false })
        XCTAssertEqual(result["host_callable_loading_guaranteed"] as? Bool, false)
        XCTAssertFalse((result["instructions"] as! String).contains("Available tools ("))
    }

    func testExplicitSchemasAndLegacyAliasRemainExact() throws {
        let all = LocalMCPServer.toolSpecs
        XCTAssertEqual(try LocalJSON.encode(rows(["detail": "schemas"])), try LocalJSON.encode(all))
        for name in ["workspace_list", "command_run", "command_start", "file_apply_edits"] {
            let selected = try rows(["names": [name, name]])
            XCTAssertEqual(selected.count, 1)
            XCTAssertEqual(try LocalJSON.encode(selected[0]), try LocalJSON.encode(all.first { $0["name"] as? String == name }!))
        }
        let alias = try rows(["names": ["workspace_list"], "detail": "index"])[0]
        XCTAssertEqual(alias["deprecated"] as? Bool, true)
        XCTAssertEqual(alias["canonical_name"] as? String, "workspace_overview")
        let suggested = try rows(["query": "  WORKSPACE_LIST  "])
        XCTAssertEqual(suggested.first?["name"] as? String, "workspace_overview")
        XCTAssertFalse(suggested.contains { $0["name"] as? String == "workspace_list" })
    }

    func testExactToolQueriesRankFirstAndPreserveAnnotations() throws {
        for spec in LocalMCPServer.toolSpecs {
            let name = spec["name"] as! String
            let selected = try rows(["query": name, "limit": 1])[0]
            let canonical = ToolDiscovery.aliases[name] ?? name
            XCTAssertEqual(selected["name"] as? String, canonical, name)
            let original = LocalMCPServer.toolSpecs.first { $0["name"] as? String == canonical }!
            XCTAssertEqual(try LocalJSON.encode(selected["annotations"] as! JSONObject),
                           try LocalJSON.encode(original["annotations"] as! JSONObject), name)
        }
    }

    func testEnglishAndVietnameseWorkflowQueries() throws {
        let examples = [
            ("read many files", "file_read_many"),
            ("đọc nhiều file", "file_read_many"),
            ("ĐỌC DÒNG VĂN BẢN", "file_read_lines"),
            ("tìm tên file pattern", "directory_find"),
            ("tìm nội dung trong thư mục", "file_search"),
            ("build test chạy nền", "command_start"),
            ("trạng thái nhiều job", "process_status_many"),
            ("xem log job mới nhất", "process_output_tail"),
            ("status output", "process_output"),
            ("sửa nhiều chỗ trong một file", "file_apply_edits"),
            ("replace all occurrences", "file_patch"),
            ("restore undo", "transaction_restore"),
            ("git history recent commits", "git_log"),
            ("xóa file", "path_remove"),
            ("sao chép file", "path_copy"),
            ("đổi tên thư mục", "path_move"),
            ("ghi thêm vào file", "file_append"),
            ("dừng job", "process_cancel"),
            ("copy a directory", "path_copy"),
            ("rename a folder", "path_move"),
            ("delete a file", "path_remove"),
            ("append to file", "file_append"),
            ("cancel running job", "process_cancel"),
            ("đọc campaign brevo", "brevo_read"),
            ("read brevo campaign", "brevo_read"),
            ("đọc campaigns brevo", "brevo_read"),
            ("send brevo campaign", "brevo_campaign"),
            ("sửa campaign brevo", "brevo_campaign"),
            ("send test brevo campaign", "brevo_campaign"),
        ]
        for (query, expected) in examples {
            let result = try rows(["query": query])
            XCTAssertEqual(result.first?["name"] as? String, expected, query)
            XCTAssertLessThanOrEqual(result.count, 5)
        }
    }

    func testFiltersLimitsAndNoMatchAreHonestAndDeterministic() throws {
        for category in ToolDiscovery.categories {
            let first = try rows(["category": category, "limit": 50])
            XCTAssertFalse(first.isEmpty, category)
            XCTAssertTrue(first.allSatisfy { $0["category"] as? String == category })
            XCTAssertEqual(try LocalJSON.encode(first), try LocalJSON.encode(rows(["category": category, "limit": 50])))
        }
        let bounded = try ToolDiscovery.catalog(["category": "process", "limit": 1])
        XCTAssertEqual(bounded["returned_count"] as? Int, 1)
        XCTAssertGreaterThan(bounded["matched_count"] as! Int, 1)
        XCTAssertEqual(bounded["truncated"] as? Bool, true)
        XCTAssertTrue(try rows(["query": "zzqvexample9187"]).isEmpty)
        XCTAssertTrue(try rows(["names": ["git_status"], "category": "files"]).isEmpty)
        let subset = try rows(["query": "build test chạy nền", "category": "process", "detail": "schemas", "limit": 1])
        XCTAssertEqual(subset[0]["name"] as? String, "command_start")
        XCTAssertNotNil(subset[0]["inputSchema"])
    }

    func testInvalidArgumentsCannotSilentlyExpandLookup() throws {
        let invalid: [JSONObject] = [
            ["names": []], ["names": "command_start"], ["names": ["invented"]],
            ["names": [1]], ["names": Array(repeating: "file_read", count: LocalMCPServer.toolSpecs.count + 1)],
            ["category": "invented"], ["category": false], ["query": "   "],
            ["query": "***"], ["query": String(repeating: "x", count: 513)],
            ["query": 1], ["limit": 0], ["limit": LocalMCPServer.toolSpecs.count + 1], ["limit": "1"],
            ["detail": "invalid"], ["execute": "file_write"],
        ]
        for arguments in invalid { XCTAssertThrowsError(try ToolDiscovery.catalog(arguments), "\(arguments)") }
    }

    func testCompactDiscoveryReducesPayloadWithoutWeakeningSchemas() throws {
        let full = try LocalJSON.encode(ToolDiscovery.catalog(["detail": "schemas"]))
        let compact = try LocalJSON.encode(ToolDiscovery.catalog([:]))
        let index = try LocalJSON.encode(ToolDiscovery.catalog(["limit": 50]))
        let filtered = try LocalJSON.encode(ToolDiscovery.catalog(["query": "read many files"]))
        XCTAssertLessThan(compact.count, index.count / 2)
        XCTAssertLessThan(compact.count, full.count / 3)
        XCTAssertLessThanOrEqual(compact.count, 8_000)
        XCTAssertLessThanOrEqual(filtered.count, 4_000)
        // Full schemas include ten typed Brevo groups; compact discovery stays under 8 KB.
        XCTAssertLessThanOrEqual(full.count, 90_000)
        XCTAssertLessThanOrEqual(LocalMCPServer.discoveryGuide.utf8.count, 1_200)
        XCTAssertTrue(LocalMCPServer.discoveryGuide.contains("Operator loop"))
        XCTAssertTrue(LocalMCPServer.discoveryGuide.contains("checkpoint"))
        XCTAssertTrue(LocalMCPServer.discoveryGuide.contains("truncation and unknowns"))
        XCTAssertTrue(LocalMCPServer.discoveryGuide.contains("names return exact schemas"))
        XCTAssertTrue(LocalMCPServer.discoveryGuide.contains("current catalog count"))
        XCTAssertLessThan(filtered.count, full.count / 2)
        let start = try rows(["names": ["command_start"]])[0]["inputSchema"] as! JSONObject
        let run = try rows(["names": ["command_run"]])[0]["inputSchema"] as! JSONObject
        XCTAssertNil((start["properties"] as! JSONObject)["timeout_milliseconds"])
        XCTAssertNotNil((run["properties"] as! JSONObject)["timeout_milliseconds"])
    }

    func testStarterDoesNotHideSpecialistToolsOrMisstateCatalogIdentity() throws {
        let all = LocalMCPServer.toolSpecs
        XCTAssertEqual(all.count, 77)
        XCTAssertEqual(Set(ToolDiscovery.starterNames).count, 14)
        XCTAssertTrue(Set(ToolDiscovery.starterNames).isSubset(of: Set(all.compactMap { $0["name"] as? String })))
        let lookups: [JSONObject] = [[:], ["limit": 1], ["limit": 50], ["query": "git blame"], ["detail": "schemas"]]
        for arguments in lookups {
            let result = try ToolDiscovery.catalog(arguments)
            XCTAssertEqual(result["catalog_sha256"] as? String, LocalHash.sha256(try LocalJSON.encode(all)))
            let categories = try XCTUnwrap(result["categories"] as? [JSONObject])
            XCTAssertEqual(categories.compactMap { $0["count"] as? Int }.reduce(0, +), 76)
            XCTAssertEqual(result["matched_count"] as! Int > result["returned_count"] as! Int,
                           result["truncated"] as! Bool)
        }
        XCTAssertEqual(try rows(["query": "git blame", "limit": 1]).first?["name"] as? String, "git_blame")
        XCTAssertEqual(try rows(["category": "git", "limit": 50]).count, 8)
        XCTAssertEqual(try rows(["names": ["workspace_list"]]).count, 1)
    }

    func testConsumingOutputIsNotAdvertisedAsSafeToReplay() throws {
        for name in ["process_output", "process_output_many"] {
            let annotations = try rows(["names": [name]])[0]["annotations"] as! JSONObject
            XCTAssertEqual(annotations["idempotentHint"] as? Bool, false, name)
        }
    }

    func testCommandSchemasExplainExecutableIDsAtThePointOfUse() throws {
        XCTAssertTrue(LocalMCPServer.discoveryGuide.contains("Reviewing a tool is not permission to execute it"))
        XCTAssertTrue(LocalMCPServer.discoveryGuide.contains("never replay commands from earlier tasks"))
        for name in ["command_run", "command_start"] {
            let tool = try rows(["names": [name]])[0]
            let input = try XCTUnwrap(tool["inputSchema"] as? JSONObject)
            let properties = try XCTUnwrap(input["properties"] as? JSONObject)
            let executable = try XCTUnwrap(properties["executable"] as? JSONObject)
            XCTAssertEqual(executable["type"] as? String, "string")
            XCTAssertEqual(executable["maxLength"] as? Int, 64)
            XCTAssertNil(executable["enum"], "Documentation must not introduce a second executable allowlist")
            let description = try XCTUnwrap(executable["description"] as? String)
            XCTAssertTrue(description.contains("not an absolute path"))
            XCTAssertTrue(description.contains("command_list once"))
            XCTAssertTrue(description.contains("arguments"))
            XCTAssertLessThan(description.utf8.count, 256)
            let annotations = try XCTUnwrap(tool["annotations"] as? JSONObject)
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false)
            if name == "command_start" {
                XCTAssertNil(properties["timeout_milliseconds"])
                XCTAssertTrue((tool["description"] as? String)?.contains("No timeout_milliseconds") == true)
            } else {
                XCTAssertNotNil(properties["timeout_milliseconds"])
            }
        }
    }

    func testDeveloperInspectionIsReadOnlyAndCommandGatewayIsNot() throws {
        let inspection = try rows(["names": ["developer_inspect"]])[0]
        let command = try rows(["names": ["developer_task"]])[0]
        XCTAssertEqual((inspection["annotations"] as? JSONObject)?["readOnlyHint"] as? Bool, true)
        XCTAssertEqual((inspection["annotations"] as? JSONObject)?["destructiveHint"] as? Bool, false)
        XCTAssertEqual((command["annotations"] as? JSONObject)?["readOnlyHint"] as? Bool, false)
        let inspectActions = (((inspection["inputSchema"] as? JSONObject)?["properties"] as? JSONObject)?["action"] as? JSONObject)?["enum"] as? [String]
        let taskActions = (((command["inputSchema"] as? JSONObject)?["properties"] as? JSONObject)?["action"] as? JSONObject)?["enum"] as? [String]
        XCTAssertEqual(inspectActions, DeveloperTask.inspectActions)
        XCTAssertEqual(taskActions, DeveloperTask.taskActions)
    }
}
