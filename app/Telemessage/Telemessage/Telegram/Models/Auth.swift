import Foundation

/// A TDLib `error` object, thrown by `TDLibClient.send` when a request fails.
nonisolated struct TDError: Error, Decodable, Sendable, Equatable, LocalizedError {
    let code: Int32
    let message: String

    var errorDescription: String? { message }
}

/// Response of requests that return `ok`.
nonisolated struct TDOk: Decodable, Sendable {}

nonisolated enum OptionValue: Decodable, Sendable, Equatable {
    case empty
    case boolean(Bool)
    case integer(Int64)
    case string(String)
    case unknown(String)

    private struct BoolValue: Decodable { let value: Bool }
    private struct IntValue: Decodable { let value: TDInt64 }
    private struct StringValue: Decodable { let value: String }

    init(from decoder: any Decoder) throws {
        switch try TDTypeTag.read(decoder) {
        case "optionValueEmpty": self = .empty
        case "optionValueBoolean": self = .boolean(try BoolValue(from: decoder).value)
        case "optionValueInteger": self = .integer(try IntValue(from: decoder).value.value)
        case "optionValueString": self = .string(try StringValue(from: decoder).value)
        case let other: self = .unknown(other)
        }
    }
}

nonisolated enum AuthorizationState: Decodable, Sendable, Equatable {
    case waitTdlibParameters
    case waitPhoneNumber
    case waitPremiumPurchase
    case waitEmailAddress(allowAppleID: Bool, allowGoogleID: Bool)
    case waitEmailCode(EmailCodeInfo)
    case waitCode(AuthenticationCodeInfo)
    case waitOtherDeviceConfirmation(link: String)
    case waitRegistration(termsOfService: FormattedText)
    case waitPassword(PasswordInfo)
    case ready
    case loggingOut
    case closing
    case closed
    case unknown(String)

    nonisolated struct EmailCodeInfo: Decodable, Sendable, Equatable {
        let emailAddressPattern: String
        let length: Int32
    }

    nonisolated struct PasswordInfo: Decodable, Sendable, Equatable {
        let passwordHint: String
        let hasRecoveryEmailAddress: Bool
        let recoveryEmailAddressPattern: String
    }

    private struct WaitEmailAddress: Decodable { let allowAppleID: Bool; let allowGoogleID: Bool }
    private struct WaitEmailCode: Decodable { let codeInfo: EmailCodeInfo }
    private struct WaitCode: Decodable { let codeInfo: AuthenticationCodeInfo }
    private struct WaitOtherDevice: Decodable { let link: String }
    private struct TermsOfService: Decodable { let text: FormattedText }
    private struct WaitRegistration: Decodable { let termsOfService: TermsOfService }

    init(from decoder: any Decoder) throws {
        switch try TDTypeTag.read(decoder) {
        case "authorizationStateWaitTdlibParameters":
            self = .waitTdlibParameters
        case "authorizationStateWaitPhoneNumber":
            self = .waitPhoneNumber
        case "authorizationStateWaitPremiumPurchase":
            self = .waitPremiumPurchase
        case "authorizationStateWaitEmailAddress":
            let value = try WaitEmailAddress(from: decoder)
            self = .waitEmailAddress(allowAppleID: value.allowAppleID, allowGoogleID: value.allowGoogleID)
        case "authorizationStateWaitEmailCode":
            self = .waitEmailCode(try WaitEmailCode(from: decoder).codeInfo)
        case "authorizationStateWaitCode":
            self = .waitCode(try WaitCode(from: decoder).codeInfo)
        case "authorizationStateWaitOtherDeviceConfirmation":
            self = .waitOtherDeviceConfirmation(link: try WaitOtherDevice(from: decoder).link)
        case "authorizationStateWaitRegistration":
            self = .waitRegistration(termsOfService: try WaitRegistration(from: decoder).termsOfService.text)
        case "authorizationStateWaitPassword":
            self = .waitPassword(try PasswordInfo(from: decoder))
        case "authorizationStateReady":
            self = .ready
        case "authorizationStateLoggingOut":
            self = .loggingOut
        case "authorizationStateClosing":
            self = .closing
        case "authorizationStateClosed":
            self = .closed
        case let other:
            self = .unknown(other)
        }
    }
}

nonisolated struct AuthenticationCodeInfo: Decodable, Sendable, Equatable {
    let phoneNumber: String
    let type: CodeType
    let nextType: CodeType?
    /// Seconds before `nextType` can be requested with resendAuthenticationCode.
    let timeout: Int32

    /// How the code was delivered; `name` is the constructor without the `authenticationCodeType` prefix.
    nonisolated struct CodeType: Decodable, Sendable, Equatable {
        let name: String
        let length: Int32?

        private enum CodingKeys: String, CodingKey { case length }

        init(from decoder: any Decoder) throws {
            name = String(try TDTypeTag.read(decoder).trimmingPrefix("authenticationCodeType"))
            length = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Int32.self, forKey: .length)
        }
    }
}

nonisolated enum ConnectionState: Decodable, Sendable, Equatable {
    case waitingForNetwork
    case connectingToProxy
    case connecting
    case updating
    case ready
    case unknown(String)

    init(from decoder: any Decoder) throws {
        switch try TDTypeTag.read(decoder) {
        case "connectionStateWaitingForNetwork": self = .waitingForNetwork
        case "connectionStateConnectingToProxy": self = .connectingToProxy
        case "connectionStateConnecting": self = .connecting
        case "connectionStateUpdating": self = .updating
        case "connectionStateReady": self = .ready
        case let other: self = .unknown(other)
        }
    }
}
