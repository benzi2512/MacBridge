import Foundation

extension LocalWorkspaceService {
    public static let maximumBatchPaths = 32
    public static let maximumBatchReadBytes = 1_048_576

    /// Reuses the single-file boundary. A denied item never authorizes another item.
    public func readFiles(workspaceID: String, paths: [String], encoding: String,
                          maximumBytesPerFile: Int, maximumTotalBytes: Int) throws -> JSONObject {
        try validateBatch(workspaceID: workspaceID, paths: paths)
        guard ["utf8", "base64"].contains(encoding),
              (1...262_144).contains(maximumBytesPerFile),
              (4...Self.maximumBatchReadBytes).contains(maximumTotalBytes) else {
            throw LocalMCPError.invalidRequest("invalid batch read encoding or byte budget")
        }
        var results: [JSONObject] = []
        var returned = 0
        var reads = 0
        var errors = 0
        var skipped = 0
        var complete = true
        for path in paths {
            // Single-file UTF-8 reads may finish a scalar by extending up to 3 bytes.
            let capacity = maximumTotalBytes - returned - (encoding == "utf8" ? 3 : 0)
            guard capacity > 0 else {
                results.append(["requested_path": path, "status": "skipped_budget"])
                skipped += 1
                complete = false
                continue
            }
            do {
                let response = try readFile(workspaceID: workspaceID, path: path,
                    encoding: encoding, maximumBytes: min(maximumBytesPerFile, capacity))
                guard let file = response["file"] as? JSONObject,
                      let count = file["byte_count"] as? Int else {
                    throw LocalMCPError.operationFailed("unexpected file response")
                }
                returned += count
                reads += 1
                complete = complete && (file["eof"] as? Bool == true)
                results.append(["requested_path": path, "status": "ok", "file": file])
            } catch {
                results.append(batchError(path: path, error: error))
                errors += 1
                complete = false
            }
        }
        return ["results": results, "requested_count": paths.count, "read_count": reads,
                "error_count": errors, "skipped_count": skipped, "returned_bytes": returned,
                "maximum_total_bytes": maximumTotalBytes, "complete": complete,
                "snapshot_atomic": false]
    }

    /// Hashing is opt-in so a metadata batch does not unexpectedly scan file contents.
    public func statPaths(workspaceID: String, paths: [String], includeSHA256: Bool) throws -> JSONObject {
        try validateBatch(workspaceID: workspaceID, paths: paths)
        var errors = 0
        let results: [JSONObject] = paths.map { path in
            do {
                let result = try statPath(workspaceID: workspaceID, path: path, includeSHA256: includeSHA256)
                return ["requested_path": path, "status": "ok", "path": result["path"]!]
            } catch {
                errors += 1
                return batchError(path: path, error: error)
            }
        }
        return ["results": results, "requested_count": paths.count, "error_count": errors,
                "complete": errors == 0, "snapshot_atomic": false]
    }

    private func validateBatch(workspaceID: String, paths: [String]) throws {
        _ = try registry.workspace(id: workspaceID)
        guard !paths.isEmpty, paths.count <= Self.maximumBatchPaths,
              paths.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") }) else {
            throw LocalMCPError.invalidRequest("paths requires 1...32 non-empty bounded paths")
        }
    }

    private func batchError(path: String, error: Error) -> JSONObject {
        let code: String
        switch error as? LocalMCPError {
        case .sensitivePathBlocked: code = "sensitive_path_blocked"
        case .notFound: code = "not_found"
        case .invalidPath: code = "invalid_path"
        case .wrongFileType: code = "unsupported_file_type"
        default: code = "operation_failed"
        }
        return ["requested_path": path, "status": "error", "error_code": code,
                "message": (error as? LocalMCPError)?.description ?? "File operation failed."]
    }
}
