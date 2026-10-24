import Foundation

/// User-facing wording for TDLib errors. TDLib reports Telegram's error identifiers verbatim.
nonisolated enum ErrorText {
    static func describe(_ error: any Error) -> String {
        if let error = error as? TDError { return describe(error) }
        if error is TDClientError { return "Telegram is not running. Try again." }
        return error.localizedDescription
    }

    static func describe(_ error: TDError) -> String {
        let message = error.message
        if message.hasPrefix("Too Many Requests: retry after "), let seconds = Int(message.split(separator: " ").last ?? "") {
            return "Too many attempts. Try again in \(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))."
        }
        switch message {
        case "PHONE_NUMBER_INVALID": return "That phone number isn't valid. Include the country code, e.g. +81 90 1234 5678."
        case "PHONE_NUMBER_BANNED": return "This phone number is banned from Telegram."
        case "PHONE_NUMBER_FLOOD": return "This number made too many sign-in attempts. Try again later."
        case "PHONE_CODE_INVALID": return "That code isn't correct."
        case "PHONE_CODE_EMPTY": return "Enter the code."
        case "PHONE_CODE_EXPIRED": return "That code expired. Request a new one."
        case "PASSWORD_HASH_INVALID": return "That password isn't correct."
        case "EMAIL_INVALID": return "That email address isn't valid."
        case "CODE_INVALID", "EMAIL_CODE_INVALID": return "That code isn't correct."
        case "SEND_CODE_UNAVAILABLE": return "No other way to send the code is available."
        default:
            return message.isEmpty ? "Something went wrong (error \(error.code))." : message
        }
    }
}
