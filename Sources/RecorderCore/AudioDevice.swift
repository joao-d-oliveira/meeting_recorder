public struct AudioDevice: Equatable, Identifiable {
    public let index: Int
    public let name: String
    public var id: String { name }

    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }
}
