import Foundation
import CoreFoundation

/// Narrow file-to-URL staging. Does not call Meta, create ads, grant permissions,
/// provision storage, renew links implicitly or execute a caller-chosen URL.
enum MediaShareOperations {
    static let maximumOutstandingBytes = 1_024 * 1_024 * 1_024

    static func execute(_ name: String, _ a: JSONObject, workspace: RegisteredLocalWorkspace?,
                        configurationURL: URL = MediaShareConfiguration.defaultURL,
                        transport: MediaShareTransport.Perform? = nil,
                        now: () -> Date = { Date() }) throws -> JSONObject {
        let action = try a.requiredString("action", maximumBytes: 32)
        if name == "media_inspect", action == "capabilities" {
            try a.requireOnlyKeys(["action"])
            return ["status": "owner_configuration_required", "provider": "private_r2_s3",
                    "maximum_file_bytes": MediaFile.maximumBytes,
                    "maximum_outstanding_bytes": maximumOutstandingBytes,
                    "maximum_concurrent_media_calls": 1, "default_link_seconds": 900,
                    "maximum_link_seconds": 3_600, "media_types": ["IMAGE", "VIDEO"],
                    "extensions": ["jpg", "jpeg", "png", "gif", "mp4", "mov"],
                    "credential_read": false, "network_request": false, "mutation_performed": false,
                    "meta_upload_performed": false, "link_is_bearer": true,
                    "link_method": "GET", "same_link_allows_HEAD": false,
                    "link_expiry_deletes_object": false,
                    "note": "prepare is local only. publish requires owner-configured storage and approval to share the selected file. Meta URL ingestion remains a separate operation and live acceptance test."]
        }
        guard let workspace else { throw LocalMCPError.unknownWorkspace }
        let workspaceID = try MediaShareID.parse(a.requiredString("workspace_id", maximumBytes: 36))
        guard workspaceID == workspace.id.lowercased() else { throw LocalMCPError.unknownWorkspace }
        if name == "media_inspect", action == "prepare" {
            try a.requireOnlyKeys(["action", "workspace_id", "path"])
            var result = try MediaFile.read(workspace: workspace, path: a.requiredString("path")).json
            result["status"] = "prepared_local_only"
            result["mutation_performed"] = false
            result["credential_read"] = false
            result["meta_upload_performed"] = false
            return result
        }
        let publishing = name == "media_share" && action == "publish"
        let revoking = name == "media_share" && action == "revoke"
        let inspecting = name == "media_inspect" && action == "status"
        guard publishing || revoking || inspecting else {
            throw LocalMCPError.invalidRequest("unsupported media action")
        }
        let baseKeys: Set<String> = ["action", "workspace_id", "request_id"]
        try a.requireOnlyKeys(publishing ? baseKeys.union(["path", "expected_sha256", "expires_in_seconds", "confirm_public_link"]) : baseKeys)
        let id = try MediaShareID.parse(a.requiredString("request_id", maximumBytes: 36))
        let config = try MediaShareConfiguration.load(from: configurationURL)
        guard config.workspaceID == workspaceID,
              workspace.rootURL.path == "/" || config.root.path == workspace.rootURL.path
                || config.root.path.hasPrefix(workspace.rootURL.path + "/") else {
            throw LocalMCPError.invalidRequest("media sharing is not enabled for this workspace")
        }
        let journal = try MediaShareJournal(configurationURL: configurationURL, binding: config.binding)
        let send = transport ?? { try MediaShareTransport.perform($0, file: $1) }
        if publishing {
            // The caller must have the user's sharing approval. This explicit
            // acknowledgement is not an authorization source by itself.
            guard let acknowledgement = a["confirm_public_link"] as? NSNumber,
                  CFGetTypeID(acknowledgement) == CFBooleanGetTypeID(), acknowledgement.boolValue else {
                throw LocalMCPError.invalidRequest("publishing requires acknowledgement of an expiring bearer link")
            }
            let sha = try a.requiredString("expected_sha256", maximumBytes: 64)
            guard LocalHash.isSHA256(sha) else { throw LocalMCPError.invalidRequest("expected_sha256 must be lower-case SHA-256") }
            let path = try MediaFile.resolve(workspace: workspace, path: a.requiredString("path"), mediaRoot: config.root).path
            let seconds = try a.optionalInt("expires_in_seconds", default: 900, range: 60...3_600)
            if var record = journal.record(id) {
                try validate(record, config: config)
                guard record.path == path, record.sha256 == sha, record.seconds == seconds else {
                    throw LocalMCPError.conflict("request_id already belongs to a different file, digest or lifetime; nothing was uploaded")
                }
                let checksRemote = !["revoked", "missing"].contains(record.state)
                if checksRemote {
                    reconcile(&record, config: config, send: send, now: now())
                    try journal.save(record)
                }
                return receipt(record, config: config, now: now(), network: checksRemote,
                               writeAttempted: false, replay: true)
            }
            let snapshot = try MediaFile.Snapshot()
            let proof = try MediaFile.read(workspace: workspace, path: path, mediaRoot: config.root, snapshot: snapshot)
            guard proof.sha256 == sha else { throw LocalMCPError.conflict("media SHA-256 changed since prepare; nothing was uploaded") }
            guard journal.outstandingBytes <= maximumOutstandingBytes - proof.bytes else {
                throw LocalMCPError.limitExceeded("media staging budget reached; revoke retained transfers first")
            }
            var record = MediaShareRecord(requestID: id, workspaceID: workspaceID, path: path,
                sha256: sha, bytes: proof.bytes, mime: proof.mime, ext: proof.ext,
                objectKey: "macbridge-transfers/" + UUID().uuidString.lowercased() + "/media." + proof.ext,
                issued: Int64(now().timeIntervalSince1970), seconds: seconds, state: "pending")
            try journal.save(record) // No network before the durable intent.
            do {
                let request = signed("PUT", record, config, now(), payload: sha,
                    headers: ["content-type": proof.mime, "content-length": String(proof.bytes),
                              "cache-control": "no-store", "x-amz-meta-sha256": sha])
                let reply = try send(request, snapshot.url)
                guard [200, 201].contains(reply.status) else { throw LocalMCPError.operationFailed("media PUT was not acknowledged") }
                reconcile(&record, config: config, send: send, now: now())
            } catch { record.state = "outcome_unknown" }
            try journal.save(record)
            return receipt(record, config: config, now: now(), network: true, writeAttempted: true, replay: false)
        }
        guard var record = journal.record(id) else {
            throw LocalMCPError.invalidRequest("unknown media receipt; no remote request was made")
        }
        try validate(record, config: config)
        if record.state == "revoked" {
            return receipt(record, config: config, now: now(), network: false, writeAttempted: false, replay: true)
        }
        if inspecting {
            reconcile(&record, config: config, send: send, now: now())
            try journal.save(record)
            return receipt(record, config: config, now: now(), network: true, writeAttempted: false, replay: false)
        }
        // Reconcile first. A 404 after an uncertain PUT is not proof that an
        // in-flight write cannot still commit; never label that case revoked.
        reconcile(&record, config: config, send: send, now: now())
        guard record.state == "ready" || record.state == "missing" else {
            try journal.save(record)
            return receipt(record, config: config, now: now(), network: true, writeAttempted: false, replay: false)
        }
        if record.state == "missing" { record.state = "revoked" }
        else {
            do {
                let deleted = try send(signed("DELETE", record, config, now()), nil)
                guard [200, 204].contains(deleted.status) else { throw LocalMCPError.operationFailed("media deletion not acknowledged") }
                let absent = try send(signed("HEAD", record, config, now()), nil)
                record.state = absent.status == 404 ? "revoked" : "outcome_unknown"
            } catch { record.state = "outcome_unknown" }
        }
        try journal.save(record)
        return receipt(record, config: config, now: now(), network: true, writeAttempted: true, replay: false)
    }

    private static func validate(_ r: MediaShareRecord, config: MediaShareConfiguration) throws {
        try r.validate()
        guard r.workspaceID == config.workspaceID, r.path.hasPrefix(config.root.path + "/"),
              !r.path.split(separator: "/").contains("..") else {
            throw LocalMCPError.conflict("media receipt does not match the owner binding")
        }
    }

    private static func signed(_ method: String, _ r: MediaShareRecord, _ c: MediaShareConfiguration, _ date: Date,
                               payload: String = MediaS3Signing.emptySHA256, headers: [String: String] = [:]) -> URLRequest {
        MediaS3Signing.signedRequest(method: method, host: c.endpoint.host!, path: "/" + c.bucket + "/" + r.objectKey,
            access: c.accessKeyID, secret: c.secretAccessKey, date: date, payloadSHA256: payload, headers: headers)
    }

    private static func reconcile(_ r: inout MediaShareRecord, config: MediaShareConfiguration,
                                  send: MediaShareTransport.Perform, now: Date) {
        do {
            let reply = try send(signed("HEAD", r, config, now), nil)
            if reply.status == 200, reply.headers["content-length"] == String(r.bytes),
               reply.headers["content-type"] == r.mime, reply.headers["x-amz-meta-sha256"] == r.sha256 {
                r.state = "ready"
            } else if reply.status == 404, ["ready", "missing"].contains(r.state) { r.state = "missing" }
            else { r.state = "outcome_unknown" }
        } catch { r.state = "outcome_unknown" }
    }

    private static func receipt(_ r: MediaShareRecord, config: MediaShareConfiguration, now: Date,
                                network: Bool, writeAttempted: Bool, replay: Bool) -> JSONObject {
        let time = Int64(now.timeIntervalSince1970)
        let usable = r.state == "ready" && time >= r.issued && time < r.expires
        var result: JSONObject = ["request_id": r.requestID, "workspace_id": r.workspaceID,
            "sha256": r.sha256, "byte_count": r.bytes, "mime_type": r.mime, "media_type": r.mediaType,
            "share_state": r.state, "expires_at": r.expires, "link_expired": time >= r.expires,
            "link_available": usable, "network_request": network, "credential_read": true,
            "write_attempted": writeAttempted, "same_request_reconciled": replay,
            "source_modified": false, "meta_upload_performed": false, "link_expiry_deletes_object": false,
            "isError": r.state == "outcome_unknown" || r.state == "pending" || time < r.issued,
            "status": usable ? "staged_not_uploaded_to_meta" : r.state == "ready" && time >= r.expires ? "link_expired" : r.state,
            "next_step": usable
                ? "Pass this exact URL with upload_source=URL and media_type to the existing Meta Ads upload tool only with user approval. Verify its real image hash/video ID and readiness, then revoke. Do not log the signed URL."
                : "Do not repeat PUT automatically or change request_id to retry an uncertain publication. Use status to reconcile; expiry does not delete the staged object."]
        if usable {
            result["media_url"] = MediaS3Signing.presignedGET(host: config.endpoint.host!,
                path: "/" + config.bucket + "/" + r.objectKey, access: config.accessKeyID,
                secret: config.secretAccessKey, issued: Date(timeIntervalSince1970: TimeInterval(r.issued)),
                seconds: r.seconds).absoluteString
        }
        return result
    }
}
