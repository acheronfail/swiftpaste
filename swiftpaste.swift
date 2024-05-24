import CarbonBridge
import Cocoa
import Foundation

let DOUBLE_CLICK_INTERVAL: Double = 0.5
let DRAG_THRESHOLD: CGFloat = 4

var clip: String = ""

/// State that's passed into the event callback.
struct State {
  var pasteEnabled: Bool

  var leftClick1: Date?
  var leftClick2: Date?

  var dragStart: CGPoint?
  var wasDragging: Bool

  mutating func recordClick() {
    self.leftClick2 = self.leftClick1
    self.leftClick1 = Date()
  }

  func wasDoubleClick() -> Bool {
    guard let a = self.leftClick1, let b = self.leftClick2 else {
      return false
    }

    return a.timeIntervalSince(b) < DOUBLE_CLICK_INTERVAL
  }
}

func sendKey(_ key: CGKeyCode, _ flags: CGEventFlags?) {
  if let source = CGEventSource(stateID: .combinedSessionState) {
    // Disable local keyboard events while sending key events
    source.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalMouseEvents, .permitSystemDefinedEvents],
      state: .eventSuppressionStateSuppressionInterval)

    let kbdEventDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
    let kbdEventUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
    if let flags = flags {
      kbdEventDown?.flags = flags
    }

    kbdEventDown?.post(tap: .cgSessionEventTap)
    kbdEventUp?.post(tap: .cgSessionEventTap)
  }

}

func doPaste() {
  // TODO: put clip back into pasteboard, paste, then restore pasteboard again
  // https://github.com/p0deje/Maccy/blob/cc2435598c937cbfe6b58ca42f173954827501bc/Maccy/Clipboard.swift#L135
  // sendKey(CGKeyCode(CarbonBridge.kVK_ANSI_C), CGEventFlags.maskCommand)
}

func copyText() {
  // first, save the contents of the clipboard
  let pasteboard = NSPasteboard.general
  let savedItems = pasteboard.pasteboardItems
  let changeCount = pasteboard.changeCount

  // then, trigger a copy
  sendKey(CGKeyCode(CarbonBridge.kVK_ANSI_C), CGEventFlags.maskCommand)

  let start = Date()
  Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
    if pasteboard.changeCount != changeCount {
      timer.invalidate()

      // extract
      if let text = pasteboard.string(forType: .string) {
        clip = text
      }

      // FIXME: don't conflict with maccy? (it has a 0.5s timer to check `changeCount`)

      // restore
      pasteboard.clearContents()
      if let items = savedItems {
        //   pasteboard.writeObjects(items)
        for item in items {
          for type in item.types {
            if let data = item.data(forType: type) {
              pasteboard.setData(data, forType: type)
            }
          }
        }
      }
    }

    // expire after timeout
    if Date().timeIntervalSince(start) > 2.0 {
      timer.invalidate()
    }
  }
}

/// This function is called each time a keyboard or mouse event is received.
let eventCallback: CGEventTapCallBack = { (proxy, type, event, userInfo) in
  guard let userInfo = userInfo else { return nil }

  let state = userInfo.assumingMemoryBound(to: State.self)
  if !state.pointee.pasteEnabled {
    print("paste disabled")
    return Unmanaged.passRetained(event)
  }

  switch type {
  case .leftMouseDown:
    state.pointee.recordClick()
  case .leftMouseUp:
    if state.pointee.wasDoubleClick() {
      print("copy (multi-click)")
      copyText()
    } else if state.pointee.wasDragging {
      // ignore events which only dragged a few pixels, since even if it moves
      // a single pixel, then we get drag events
      if let start = state.pointee.dragStart {
        let dx = (start.x - event.location.x).magnitude
        let dy = (start.y - event.location.y).magnitude
        if dx > DRAG_THRESHOLD || dy > DRAG_THRESHOLD {
          print("copy (drag)")
          copyText()
        }
      }
    }
    state.pointee.wasDragging = false
  case .leftMouseDragged:
    if !state.pointee.wasDragging {
      state.pointee.dragStart = event.location
    }

    state.pointee.wasDragging = true
  case .otherMouseDown:
    print("clip: \(clip)")
    doPaste()
  default:
    break
  }

  return Unmanaged.passRetained(event)
}

/// Main application function.
func main() {
  var userInfo = State(pasteEnabled: true, wasDragging: false)

  if CommandLine.arguments.contains("-n") {
    userInfo.pasteEnabled = false
  }

  // have to declare it this way otherwise swift chucks a barney...
  let eventMaskParts: [CGEventMask] = [
    CGEventMask(1 << CGEventType.otherMouseDown.rawValue),
    CGEventMask(1 << CGEventType.otherMouseUp.rawValue),
    CGEventMask(1 << CGEventType.leftMouseDown.rawValue),
    CGEventMask(1 << CGEventType.leftMouseUp.rawValue),
    CGEventMask(1 << CGEventType.mouseMoved.rawValue),
    CGEventMask(1 << CGEventType.keyUp.rawValue),
    CGEventMask(1 << CGEventType.keyDown.rawValue),
    CGEventMask(1 << CGEventType.leftMouseDragged.rawValue),
  ]
  let eventMask = eventMaskParts.reduce(0, |)

  let statePtr = UnsafeMutablePointer<State>.allocate(capacity: 1)
  statePtr.initialize(to: userInfo)
  guard
    let eventTap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .tailAppendEventTap,
      options: .listenOnly,
      eventsOfInterest: eventMask,
      callback: eventCallback,
      userInfo: statePtr)
  else {
    print("Failed to create event tap")
    exit(1)
  }

  let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
  CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)

  print("starting loop")
  CFRunLoopRun()

  // NOTE: unreachable, since CFRunLoopRun doesn't return

  statePtr.deinitialize(count: 1)
  statePtr.deallocate()
}

main()
