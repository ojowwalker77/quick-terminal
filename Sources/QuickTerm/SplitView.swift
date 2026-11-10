import AppKit

/// Lays out one or more terminals as a tree of even splits.
final class SplitView: NSView {
    enum Direction {
        case left, right, up, down
    }

    private indirect enum Node {
        case leaf(TerminalView)
        /// `sideBySide` places the two halves left and right; otherwise the
        /// first is above the second.
        case split(sideBySide: Bool, Node, Node)
    }

    private var root: Node?
    private var dividers: [CALayer] = []

    private enum Metrics {
        static let divider: CGFloat = 1
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The terminals in reading order.
    var terminals: [TerminalView] {
        var result: [TerminalView] = []
        func walk(_ node: Node) {
            switch node {
            case .leaf(let view): result.append(view)
            case .split(_, let first, let second):
                walk(first)
                walk(second)
            }
        }
        if let root { walk(root) }
        return result
    }

    var isEmpty: Bool { root == nil }

    /// The frame a terminal would get as the only one, for sizing the first shell.
    var soleFrame: NSRect { bounds }

    /// Adds a terminal. With `beside`, that terminal's space is halved and
    /// the new one takes the half in `direction`.
    func add(_ view: TerminalView, beside existing: TerminalView? = nil, direction: Direction = .right) {
        addSubview(view)
        guard let root, let existing else {
            self.root = .leaf(view)
            needsLayout = true
            return
        }

        func insert(_ node: Node) -> Node {
            switch node {
            case .leaf(let leaf) where leaf === existing:
                let sideBySide = direction == .left || direction == .right
                let newFirst = direction == .left || direction == .up
                return newFirst
                    ? .split(sideBySide: sideBySide, .leaf(view), node)
                    : .split(sideBySide: sideBySide, node, .leaf(view))
            case .leaf:
                return node
            case .split(let sideBySide, let first, let second):
                return .split(sideBySide: sideBySide, insert(first), insert(second))
            }
        }
        self.root = insert(root)
        needsLayout = true
    }

    /// Removes a terminal; its sibling takes over the freed space.
    func remove(_ view: TerminalView) {
        func prune(_ node: Node) -> Node? {
            switch node {
            case .leaf(let leaf):
                return leaf === view ? nil : node
            case .split(let sideBySide, let first, let second):
                switch (prune(first), prune(second)) {
                case (let a?, let b?): return .split(sideBySide: sideBySide, a, b)
                case (let a?, nil): return a
                case (nil, let b?): return b
                case (nil, nil): return nil
                }
            }
        }
        root = root.flatMap(prune)
        view.removeFromSuperview()
        needsLayout = true
    }

    /// The terminal next to `view` in a direction, judged by where they are
    /// on screen rather than by their place in the tree.
    func neighbour(of view: TerminalView, _ direction: Direction) -> TerminalView? {
        let from = view.frame
        let candidates = terminals.filter { other in
            guard other !== view else { return false }
            let frame = other.frame
            switch direction {
            case .left: return frame.maxX <= from.minX + 1
            case .right: return frame.minX >= from.maxX - 1
            case .up: return frame.minY >= from.maxY - 1
            case .down: return frame.maxY <= from.minY + 1
            }
        }
        func distance(_ other: TerminalView) -> CGFloat {
            hypot(other.frame.midX - from.midX, other.frame.midY - from.midY)
        }
        return candidates.min { distance($0) < distance($1) }
    }

    /// The terminal before or after `view` in reading order, wrapping around.
    func sibling(of view: TerminalView, offset: Int) -> TerminalView? {
        let all = terminals
        guard all.count > 1, let index = all.firstIndex(where: { $0 === view }) else { return nil }
        return all[(index + offset + all.count) % all.count]
    }

    override func layout() {
        super.layout()
        dividers.forEach { $0.removeFromSuperlayer() }
        dividers.removeAll()
        guard let root else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(root, in: bounds)
        CATransaction.commit()
    }

    private func place(_ node: Node, in rect: NSRect) {
        switch node {
        case .leaf(let view):
            view.frame = rect

        case .split(let sideBySide, let first, let second):
            let gap = Metrics.divider
            let line: NSRect
            if sideBySide {
                let width = ((rect.width - gap) / 2).rounded()
                place(first, in: NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
                place(second, in: NSRect(
                    x: rect.minX + width + gap, y: rect.minY,
                    width: rect.width - width - gap, height: rect.height))
                line = NSRect(x: rect.minX + width, y: rect.minY, width: gap, height: rect.height)
            } else {
                // AppKit's y axis points up, so the first (top) half is the higher one.
                let height = ((rect.height - gap) / 2).rounded()
                place(first, in: NSRect(
                    x: rect.minX, y: rect.maxY - height, width: rect.width, height: height))
                place(second, in: NSRect(
                    x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - height - gap))
                line = NSRect(x: rect.minX, y: rect.maxY - height - gap, width: rect.width, height: gap)
            }

            let divider = CALayer()
            divider.frame = line
            divider.backgroundColor = NSColor.separatorColor.cgColor
            layer?.addSublayer(divider)
            dividers.append(divider)
        }
    }
}
