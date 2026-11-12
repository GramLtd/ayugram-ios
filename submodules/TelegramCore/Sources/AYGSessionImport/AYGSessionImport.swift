import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit
import sqlcipher

// AYG: logging into an account from an existing MTProto session, instead of the phone +
// code flow. Every supported source format (Telethon/Pyrogram `.session`, `.json`, tdata)
// boils down to the same two values: the datacenter id and the 256-byte auth key. Given
// those, Telegram-iOS already knows how to materialise a logged-in account — the account
// backup/restore path (`AccountBackupData` → `accountWithId`) injects a raw key for a DC.
// So the whole job here is: get (dc, key) out of the file, confirm the key is alive and
// learn whose account it is, then write a backup-shaped account record.
//
// IMPORTANT: this is for importing the user's OWN accounts (migrating from Telethon,
// Pyrogram or Telegram Desktop). A session file is a full credential — treat an imported
// file as a login.

public struct AYGImportedSession: Equatable {
    public let datacenterId: Int32
    public let authKey: Data

    public init(datacenterId: Int32, authKey: Data) {
        self.datacenterId = datacenterId
        self.authKey = authKey
    }
}

public enum AYGSessionImportError {
    /// The file could not be opened or is not a Telethon session database.
    case invalidFile
    /// The row was found but the key is not a 256-byte MTProto auth key.
    case invalidAuthKey
    /// A datacenter id outside the 1...10 range Telegram uses.
    case invalidDatacenter
    /// The network could not be reached to validate the key.
    case network
    /// The server rejected the key: it has been revoked, or it never was valid.
    case keyRevoked
    /// This account (peer id) is already added to the app.
    case alreadyAdded
    case generic
}

/// The MTProto auth-key id: the low 64 bits of SHA1(authKey), read exactly the way the
/// handshake does it (`MTDatacenterAuthMessageService`: the last 8 bytes of the digest,
/// copied into an int64). Must match or the key is unusable.
public func aygAuthKeyId(_ authKey: Data) -> Int64 {
    guard let hash = MTSha1(authKey), hash.count >= 8 else {
        return 0
    }
    var keyId: Int64 = 0
    hash.withUnsafeBytes { raw in
        if let base = raw.baseAddress {
            memcpy(&keyId, base.advanced(by: hash.count - 8), 8)
        }
    }
    return keyId
}

/// Reads a Telethon `.session` file — a plain SQLite database whose `sessions` table holds
/// `dc_id`, `server_address`, `port`, `auth_key` (a 256-byte BLOB). The bundled SQLCipher
/// reads an unkeyed (plaintext) database like ordinary SQLite, so no key is set.
public func aygParseTelethonSession(path: String) -> AYGImportedSession? {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
        if let handle {
            sqlite3_close(handle)
        }
        return nil
    }
    defer {
        sqlite3_close(db)
    }

    var statement: OpaquePointer?
    // `LIMIT 1`: Telethon keeps a single row here. Column order is explicit so a schema
    // with extra columns (takeout_id and such) does not shift what we read.
    let query = "SELECT dc_id, auth_key FROM sessions LIMIT 1"
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
        return nil
    }
    defer {
        sqlite3_finalize(stmt)
    }

    guard sqlite3_step(stmt) == SQLITE_ROW else {
        return nil
    }

    let datacenterId = Int32(sqlite3_column_int(stmt, 0))
    guard let blob = sqlite3_column_blob(stmt, 1) else {
        return nil
    }
    let length = Int(sqlite3_column_bytes(stmt, 1))
    guard length == 256 else {
        return nil
    }
    let authKey = Data(bytes: blob, count: length)
    return AYGImportedSession(datacenterId: datacenterId, authKey: authKey)
}

private final class AYGKeychainStore {
    var values: [String: Data]
    init(_ values: [String: Data]) {
        self.values = values
    }
}

/// Builds the in-memory keychain `initializedNetwork` reads its persistent auth info from:
/// one datacenter, one key, pre-archived under the key the Network layer looks up.
private func aygMakeImportKeychain(session: AYGImportedSession) -> Keychain? {
    guard let authInfo = MTDatacenterAuthInfo(authKey: session.authKey, authKeyId: aygAuthKeyId(session.authKey), validUntilTimestamp: Int32.max, saltSet: [], authKeyAttributes: [:]) else {
        return nil
    }
    let dict = NSMutableDictionary()
    dict.setObject(authInfo, forKey: session.datacenterId as NSNumber)
    guard let archived = try? NSKeyedArchiver.archivedData(withRootObject: dict, requiringSecureCoding: false) else {
        return nil
    }
    let store = AYGKeychainStore(["persistent:datacenterAuthInfoById": archived])
    return Keychain(get: { key in
        return store.values[key]
    }, set: { key, data in
        store.values[key] = data
    }, remove: { key in
        store.values.removeValue(forKey: key)
    })
}

/// Confirms the key works and learns whose account it is. Spins up a short-lived,
/// supplementary network bound to the key's datacenter and asks `users.getUsers` for
/// `inputUserSelf`. A revoked or bogus key fails the request; a live one returns the self
/// user, whose peer id the account record needs (the session file does not carry it).
public func aygResolveImportedSelf(
    networkArguments: NetworkInitializationArguments,
    rootPath: String,
    testingEnvironment: Bool,
    session: AYGImportedSession
) -> Signal<Int64, AYGSessionImportError> {
    guard session.datacenterId >= 1 && session.datacenterId <= 10 else {
        return .fail(.invalidDatacenter)
    }
    guard session.authKey.count == 256 else {
        return .fail(.invalidAuthKey)
    }
    guard let keychain = aygMakeImportKeychain(session: session) else {
        return .fail(.invalidAuthKey)
    }

    let accountId = generateAccountRecordId()
    let basePath = rootPath + "/ayg-import-\(accountId.int64)"
    let _ = try? FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true, attributes: nil)

    return initializedNetwork(
        accountId: accountId,
        arguments: networkArguments,
        supplementary: true,
        datacenterId: Int(session.datacenterId),
        keychain: keychain,
        basePath: basePath,
        testingEnvironment: testingEnvironment,
        languageCode: nil,
        proxySettings: nil,
        networkSettings: nil,
        networkEngineSettings: nil,
        phoneNumber: nil,
        useRequestTimeoutTimers: true,
        appConfiguration: .defaultValue
    )
    |> castError(AYGSessionImportError.self)
    |> mapToSignal { network -> Signal<Int64, AYGSessionImportError> in
        return network.request(Api.functions.users.getUsers(id: [.inputUserSelf]))
        |> mapError { _ -> AYGSessionImportError in
            return .keyRevoked
        }
        |> mapToSignal { users -> Signal<Int64, AYGSessionImportError> in
            guard let apiUser = users.first else {
                return .fail(.keyRevoked)
            }
            if case .userEmpty = apiUser {
                return .fail(.keyRevoked)
            }
            let user = TelegramUser(user: apiUser)
            // Clean up the throwaway network's working directory.
            let _ = try? FileManager.default.removeItem(atPath: basePath)
            return .single(user.id.toInt64())
        }
    }
}

/// Writes a new, already-authorized account record from the imported key, exactly as the
/// backup-restore path expects: an `AccountBackupData` attribute with the master key, plus
/// environment and sort order. `accountWithId` sees the backup on the next refresh and
/// injects the key into the account's keychain.
public func aygAddImportedAccount(
    accountManager: AccountManager<TelegramAccountManagerTypes>,
    session: AYGImportedSession,
    peerId: Int64,
    testingEnvironment: Bool,
    makeCurrent: Bool
) -> Signal<AccountRecordId, AYGSessionImportError> {
    return accountManager.transaction { transaction -> Result<AccountRecordId, AYGSessionImportError> in
        // Don't add the same account twice: an existing record carrying this peer id in
        // its backup attribute means it's already here.
        for record in transaction.getRecords() {
            for attribute in record.attributes {
                if case let .backupData(backupData) = attribute, backupData.data?.peerId == peerId {
                    return .failure(.alreadyAdded)
                }
            }
        }

        let backupData = AccountBackupData(
            masterDatacenterId: session.datacenterId,
            peerId: peerId,
            masterDatacenterKey: session.authKey,
            masterDatacenterKeyId: aygAuthKeyId(session.authKey),
            notificationEncryptionKeyId: nil,
            notificationEncryptionKey: nil,
            additionalDatacenterKeys: [:]
        )

        let nextSortOrder = (transaction.getRecords().map({ record -> Int32 in
            for attribute in record.attributes {
                if case let .sortOrder(sortOrder) = attribute {
                    return sortOrder.order
                }
            }
            return 0
        }).max() ?? 0) + 1

        let attributes: [TelegramAccountManagerTypes.Attribute] = [
            .environment(AccountEnvironmentAttribute(environment: testingEnvironment ? .test : .production)),
            .sortOrder(AccountSortOrderAttribute(order: nextSortOrder)),
            .backupData(AccountBackupDataAttribute(data: backupData))
        ]

        let id = transaction.createRecord(attributes)
        if makeCurrent {
            transaction.setCurrentId(id)
        }
        return .success(id)
    }
    |> castError(AYGSessionImportError.self)
    |> mapToSignal { result -> Signal<AccountRecordId, AYGSessionImportError> in
        switch result {
        case let .success(id):
            return .single(id)
        case let .failure(error):
            return .fail(error)
        }
    }
}
