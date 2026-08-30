import Foundation

enum NotificationKind {
    case airing(episode: Int, mediaTitle: String?, mediaId: Int, coverImageURL: String?)
    case following(userId: Int, userName: String?, avatarURL: String?)
    case activityMessage(activityId: Int?, userName: String?, context: String?, avatarURL: String?)
    case activityReply(activityId: Int?, userName: String?, context: String?, avatarURL: String?)
    case activityMention(activityId: Int?, userName: String?, context: String?, avatarURL: String?)
    case activityLike(activityId: Int?, userName: String?, context: String?, avatarURL: String?)
    case threadComment(threadTitle: String?, threadURL: String?, userName: String?, context: String?, avatarURL: String?)
    case threadLike(threadTitle: String?, threadURL: String?, userName: String?, context: String?, avatarURL: String?)
    case mediaChange(title: String?, context: String?, coverURL: String?, mediaId: Int?)
    case unknown(context: String?)
}

/// AniList hands notifications to clients as a context string written to sit
/// between a username and, for forum notifications, a thread title —
/// " liked your comment in ". The padding around it is the API's, not ours, and
/// a missing user or context is answered with a fallback rather than a sentence
/// that starts or ends mid-air.
struct NotificationSentence: Equatable {
    let subject: String
    let action: String
    let object: String?

    init(userName: String?, context: String?, fallbackAction: String, objectTitle: String? = nil) {
        subject = NotificationSentence.trimmed(userName) ?? "Someone"
        action = NotificationSentence.trimmed(context) ?? fallbackAction
        object = NotificationSentence.trimmed(objectTitle)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension NotificationKind {
    enum IconImage {
        case avatar(String)
        case cover(String)
    }

    var iconImage: IconImage? {
        switch self {
        case .airing(_, _, _, let url): return url.map { .cover($0) }
        case .following(_, _, let url): return url.map { .avatar($0) }
        case .activityMessage(_, _, _, let url): return url.map { .avatar($0) }
        case .activityReply(_, _, _, let url): return url.map { .avatar($0) }
        case .activityMention(_, _, _, let url): return url.map { .avatar($0) }
        case .activityLike(_, _, _, let url): return url.map { .avatar($0) }
        case .threadComment(_, _, _, _, let url): return url.map { .avatar($0) }
        case .threadLike(_, _, _, _, let url): return url.map { .avatar($0) }
        case .mediaChange(_, _, let url, _): return url.map { .cover($0) }
        default: return nil
        }
    }
}

struct ProviderNotification: Identifiable {
    let id: Int
    let kind: NotificationKind
    let createdAt: Int
}

extension NotificationKind {
    /// Shirox has no forum screen, so thread notifications link out to AniList.
    var externalURL: URL? {
        switch self {
        case .threadComment(_, let url, _, _, _), .threadLike(_, let url, _, _, _):
            return url.flatMap(URL.init(string:))
        default:
            return nil
        }
    }
}
