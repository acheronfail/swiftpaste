import CarbonBridge
import Cocoa
import Foundation

struct Clicks {
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

let CLIP_CHECK_INTERVAL: Double = 0.2
let CLIP_CHECK_TIMEOUT: Double = 2.0
let DOUBLE_CLICK_INTERVAL: Double = 0.5
let DRAG_THRESHOLD_PX: CGFloat = 4

var clip: String = ""
var clicks = Clicks(wasDragging: false)

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

func setPasteboard(_ savedItems: [NSPasteboardItem]?) {
  // clear
  NSPasteboard.general.clearContents()

  // restore
  if let items = savedItems {
    //   NSPasteboard.general.writeObjects(items)
    for item in items {
      for type in item.types {
        if let data = item.data(forType: type) {
          NSPasteboard.general.setData(data, forType: type)
        }
      }
    }
  }
}

// https://github.com/p0deje/Maccy/blob/cc2435598c937cbfe6b58ca42f173954827501bc/Maccy/Clipboard.swift#L135
func doPaste() {
  // save
  let savedItems = NSPasteboard.general.pasteboardItems

  // set saved text into clipboard
  NSPasteboard.general.setString(clip, forType: .string)

  // paste
  sendKey(CGKeyCode(CarbonBridge.kVK_ANSI_V), CGEventFlags.maskCommand)

  // FIXME: need to wait until paste has fired before we can clear it
  sleep(1)
  setPasteboard(savedItems)
}

/// Not sure if there's a better way to know if we've selected text or not across
/// all applications (what if applications have their own custom text rendering?)
/// So for now, we just fire the 'copy' event, read the clipboard, and then extract
/// the text from that.
func saveSelectedText(_ savedItems: [NSPasteboardItem]?) {
  // extract
  if let text = NSPasteboard.general.string(forType: .string) {
    clip = text
  }

  // FIXME: don't conflict with maccy? (it has a 0.5s timer to check `changeCount`...)
  // investigate other ways of detecting clipboard changes...

  setPasteboard(savedItems)
}

func tryCopyText() {
  // first, save the contents of the clipboard
  let savedItems = NSPasteboard.general.pasteboardItems
  let changeCount = NSPasteboard.general.changeCount

  // then, trigger a copy
  sendKey(CGKeyCode(CarbonBridge.kVK_ANSI_C), CGEventFlags.maskCommand)

  // finally, periodically check the clipboard to see if something was added to it
  let start = Date()
  Timer.scheduledTimer(withTimeInterval: CLIP_CHECK_INTERVAL, repeats: true) { timer in
    if NSPasteboard.general.changeCount != changeCount {
      timer.invalidate()
      saveSelectedText(savedItems)
    }

    // expire after timeout
    if Date().timeIntervalSince(start) > CLIP_CHECK_TIMEOUT {
      timer.invalidate()
    }
  }
}

/// This function is called each time a keyboard or mouse event is received.
let eventCallback: CGEventTapCallBack = { (proxy, type, event, _) in
  switch type {
  case .leftMouseDown:
    clicks.recordClick()
  case .leftMouseUp:
    if clicks.wasDoubleClick() {
      print("copy (multi-click)")
      tryCopyText()
    } else if clicks.wasDragging {
      // ignore events which only dragged a few pixels, since even if it moves
      // a single pixel, then we get drag events
      if let start = clicks.dragStart {
        let dx = (start.x - event.location.x).magnitude
        let dy = (start.y - event.location.y).magnitude
        if dx > DRAG_THRESHOLD_PX || dy > DRAG_THRESHOLD_PX {
          print("copy (drag)")
          tryCopyText()
        }
      }
    }
    clicks.wasDragging = false
  case .leftMouseDragged:
    if !clicks.wasDragging {
      clicks.dragStart = event.location
    }

    clicks.wasDragging = true
  case .otherMouseDown:
    // FIXME: some apps (like kitty) automatically map middle-click to paste
    doPaste()
  default:
    break
  }

  return Unmanaged.passRetained(event)
}

/// Main application function.
func main() {
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
  guard
    let eventTap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .tailAppendEventTap,
      options: .listenOnly,
      eventsOfInterest: eventMask,
      callback: eventCallback,
      userInfo: nil)
  else {
    print("Failed to create event tap")
    exit(1)
  }

  let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
  CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)

  print("starting loop")
  CFRunLoopRun()

  // NOTE: unreachable, since CFRunLoopRun doesn't return
}

main()
