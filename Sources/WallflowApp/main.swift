import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 메뉴바 전용. Dock에 뜨지 않는다.
let coordinator = AppCoordinator()
app.delegate = coordinator
app.run()
