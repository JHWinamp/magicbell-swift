//
//  NotificationStore.swift
//  MagicBell
//
//  Created by Javi on 28/11/21.
//

import Harmony

public protocol NotificationStoreDelegate: AnyObject {
    func didReloadStore(_ store: NotificationStore)
    func store(_ store: NotificationStore, didInsertNotificationsAt indexes: [Int])
    func store(_ store: NotificationStore, didChangeNotificationAt indexes: [Int])
    func store(_ store: NotificationStore, didDeleteNotificationAt indexes: [Int])
}

public class NotificationStore {

    private let pageSize = 20
    
    private let getUserQueryInteractor: GetUserQueryInteractor
    private let fetchStorePageInteractor: FetchStorePageInteractor
    private let actionNotificationInteractor: ActionNotificationInteractor
    private let deleteNotificationInteractor: DeleteNotificationInteractor
    
    public let name: String
    public let predicate: StorePredicate
    private var edges: [Edge<Notification>] = []
    public private(set) var totalCount: Int = 0
    public private(set) var unreadCount: Int = 0
    public private(set) var unseenCount: Int = 0
    
    private let logger: Logger
    
    private var nextPageCursor: String?
    public private(set) var hasNextPage = true
    
    init(
        name: String,
        predicate: StorePredicate,
        getUserQueryInteractor: GetUserQueryInteractor,
        fetchStorePageInteractor: FetchStorePageInteractor,
        actionNotificationInteractor: ActionNotificationInteractor,
        deleteNotificationInteractor: DeleteNotificationInteractor,
        logger: Logger
    ) {
        self.name = name
        self.predicate = predicate
        self.getUserQueryInteractor = getUserQueryInteractor
        self.fetchStorePageInteractor = fetchStorePageInteractor
        self.actionNotificationInteractor = actionNotificationInteractor
        self.deleteNotificationInteractor = deleteNotificationInteractor
        self.logger = logger
    }

    public weak var delegate: NotificationStoreDelegate?

    public var count: Int {
        return edges.count
    }

    public subscript(index: Int) -> Notification {
        get {
            return edges[index].node
        }
    }

    /// Clears the store and fetches first page.
    /// - Parameters:
    ///    - completion: Closure with a `Result<[Notification], Error>`
    public func refresh(completion: @escaping (Result<[Notification], Error>) -> Void) {
        let cursorPredicate = CursorPredicate(size: pageSize)
        fetchStorePageInteractor.execute(storePredicate: predicate, cursorPredicate: cursorPredicate)
            .then { storePage in
                self.clear()
                self.configurePagination(storePage)
                self.configureCount(storePage)
                let newEdges = storePage.edges
                self.edges.append(contentsOf: newEdges)
                let notificationsT = newEdges.map { notificationEdge in
                    notificationEdge.node
                }
                completion(.success(notificationsT))
            }.fail { error in
                completion(.failure(error))
            }
    }

    /// Returns an array of notifications for the next pages. It can be called multiple times to obtain all pages.
    /// - Parameters:
    ///    - completion: Closure with a `Result<[Notification], Error>`
    public func fetch(completion: @escaping (Result<[Notification], Error>) -> Void) {
        guard hasNextPage else {
            completion(.success([]))
            return
        }
        let cursorPredicate: CursorPredicate = {
            if let after = nextPageCursor {
                return CursorPredicate(cursor: .next(after), size: pageSize)
            } else {
                return CursorPredicate(size: pageSize)
            }
        }()
        fetchStorePageInteractor.execute(storePredicate: predicate, cursorPredicate: cursorPredicate)
            .then { storePage in
                self.configurePagination(storePage)
                self.configureCount(storePage)

                let newEdges = storePage.edges
                self.edges.append(contentsOf: newEdges)
                let notificationsT = newEdges.map { notificationEdge in
                    notificationEdge.node
                }
                completion(.success(notificationsT))
            }.fail { error in
                completion(.failure(error))
            }
    }

    /// Returns an array of notifications that are newer from the last fetched time. It returns all the notifications, doesn't have pagination.
    /// - Parameters:
    ///    - completion: Closure with a `Result<[Notification], Error>`
    public func fetchAllPrev(completion: @escaping (Result<[Notification], Error>) -> Void) {
        if let newestCursor = edges.first?.cursor {
            recursiveNewElements(cursor: newestCursor, notifications: []) { result in
                switch result {
                case .success(let edges):
                    self.edges.insert(contentsOf: edges, at: 0)
                    completion(.success(edges.map {
                        $0.node
                    }))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        } else {
            completion(.failure(MagicBellError("Cannot load new elements without initial fetch.")))
        }
    }

    /// Deletes a notification from the store.
    /// - Parameters:
    ///    - notification: Notification will be removed.
    ///    - completion: Closure with a `Error`. Success if error is nil.
    public func delete(_ notification: Notification, completion: @escaping (Error?) -> Void) {
        deleteNotificationInteractor.execute(notificationId: notification.id)
            .then { _ in
                if let notificationIndex = self.edges.firstIndex(where: { $0.node.id == notification.id }) {
                    self.edges.remove(at: notificationIndex)
                    completion(nil)
                }
            }
    }

    /// Marks a notification as read.
    /// - Parameters:
    ///    - notification: Notification will be marked as read and seen.
    ///    - completion: Closure with a `Error`. Success if error is nil.
    public func markAsRead(_ notification: Notification, completion: @escaping (Error?) -> Void) {
        executeNotificationAction(
            notification: notification,
            action: .markAsRead,
            modificationsBlock: {
                let now = Date()
                $0.readAt = now
                $0.seenAt = now
            },
            completion: completion)
    }

    /// Marks a notification as unread.
    /// - Parameters:
    ///    - notification: Notification will be marked as unread.
    ///    - completion: Closure with a `Error`. Success if error is nil.
    public func markAsUnread(_ notification: Notification, completion: @escaping (Error?) -> Void) {
        executeNotificationAction(
            notification: notification,
            action: .markAsUnread,
            modificationsBlock: { $0.readAt = nil },
            completion: completion)
    }

    /// Marks a notification as archived.
    /// - Parameters:
    ///    - notification: Notification will be marked as archived.
    ///    - completion: Closure with a `Error`. Success if error is nil.
    public func archive(_ notification: Notification, completion: @escaping (Error?) -> Void) {
        executeNotificationAction(
            notification: notification,
            action: .archive,
            modificationsBlock: { $0.archivedAt = Date() },
            completion: completion)
    }

    /// Marks a notification as unarchived.
    /// - Parameters:
    ///    - notification: Notification will be marked as unarchived.
    ///    - completion: Closure with a `Error`. Success if error is nil.
    public func unarchive(_ notification: Notification, completion: @escaping (Error?) -> Void) {
        executeNotificationAction(
            notification: notification,
            action: .unarchive,
            modificationsBlock: { $0.archivedAt = nil },
            completion: completion)
    }

    /// Marks all notifications as read.
    /// - Parameters:
    ///    - completion: Closure with a `Error`. Success if error is nil.
    public func markAllRead(completion: @escaping (Error?) -> Void) {
        executeAllNotificationsAction(
            action: .markAllAsRead,
            modificationsBlock: {
                if $0.readAt == nil {
                    let now = Date()
                    $0.readAt = now
                    $0.seenAt = now
                }
            },
            completion: completion)
    }

    /// Marks all notifications as seen.
    /// - Parameters:
    ///    - completion: Closure with a `Error`. Success if error is nil.
    public func markAllSeen(completion: @escaping (Error?) -> Void) {
        executeAllNotificationsAction(
            action: .markAllAsSeen,
            modificationsBlock: {
                if $0.seenAt == nil {
                    $0.seenAt = Date()
                }
            },
            completion: completion)
    }
    
    public func clear() {
        edges = []
        totalCount = 0
        unreadCount = 0
        unseenCount = 0
        nextPageCursor = nil
        hasNextPage = true
    }

     // MARK: - Private Methods

    private func recursiveNewElements(
        cursor: String,
        notifications: [Edge<Notification>],
        completion: @escaping (Result<[Edge<Notification>], Error>) -> Void
    ) {
        let cursorPredicate = CursorPredicate(cursor: .previous(cursor), size: pageSize)
        fetchStorePageInteractor.execute(storePredicate: predicate, cursorPredicate: cursorPredicate).then { storePage in
            self.configureCount(storePage)
            var tempNotification = notifications
            tempNotification.insert(contentsOf: storePage.edges, at: 0)
            if storePage.pageInfo.hasPreviousPage, let cursor = storePage.pageInfo.startCursor {
                self.recursiveNewElements(cursor: cursor, notifications: tempNotification, completion: completion)
            } else {
                completion(.success(tempNotification))
            }
        }.fail { error in
            completion(.failure(error))
        }
    }

    private func executeNotificationAction(
        notification: Notification,
        action: NotificationActionQuery.Action,
        modificationsBlock: @escaping (inout Notification) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        actionNotificationInteractor.execute(action: action, notificationId: notification.id).then { _ in
            if let notificationIndex = self.edges.firstIndex(where: { $0.node.id == notification.id }) {
                modificationsBlock(&self.edges[notificationIndex].node)
                completion(nil)
            } else {
                completion(MagicBellError("Notification not found in store"))
            }
        }.fail { error in
            completion(error)
        }
    }

    private func executeAllNotificationsAction(
        action: NotificationActionQuery.Action,
        modificationsBlock: @escaping (inout Notification) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        actionNotificationInteractor.execute(action: action).then { _ in
            for i in self.edges.indices {
                modificationsBlock(&self.edges[i].node)
            }
            completion(nil)
        }.fail { error in
            completion(error)
        }
    }


    private func configurePagination(_ page: StorePage) {
        let pageInfo = page.pageInfo
        nextPageCursor = pageInfo.endCursor
        hasNextPage = pageInfo.hasNextPage
    }

    private func configureCount(_ page: StorePage) {
        totalCount = page.totalCount
        unreadCount = page.unreadCount
        unseenCount = page.unseenCount
    }
}