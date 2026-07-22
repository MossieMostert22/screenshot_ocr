# Instant Screenshot OCR (`screenshot_ocr`)

A high-utility, automated background productivity application for Android designed to instantly harvest, process, and organize text from standard or long-scrolling screenshots into a clean, inbox-style digital workspace.

## 1. Executive Summary & Purpose
The primary objective of `screenshot_ocr` is to eliminate the tedious manual steps typically required to extract information from images. Instead of snapping a picture, manually opening a secondary scanner, uploading the file, and waiting for an output loop, this application sits quietly in the device background. It intercepts new image files, extracts their plaintext context via offline Optical Character Recognition (OCR), copies it to the system clipboard, and drops it into a local productivity dashboard—all from a single hardware screenshot trigger.

## 2. Core Operational Goals
*   **Zero-Click Background Pipeline:** Silently observe the phone storage layer and auto-trigger text parsing loops without user intervention.
*   **Instant Clipboard Synchronisation:** Push extracted text string buffers straight into the device RAM clipboard the microsecond processing finishes.
*   **Dynamic Sound Pollution Control:** Isolate and silence system beep alerts during sequential database writes, ensuring exactly one completion tone triggers per task.
*   **Samsung Scroll-Capture Alignment:** Intercept, debounce, and contract temporary multi-page image slices into exactly one single, complete inbox record.
*   **Persistent Task Inbox UI:** Organize scanned text snippets into independent, manageable dashboard cards that support deep review, re-copying, and local data export.
*   **Device Documents Storage Export:** Provide on-demand file creation tools allowing users to save individual text extractions straight to the device `Documents` folder under custom filenames.

## 3. Project Architecture & Directory Map
The repository workspace runs on a highly streamlined, decoupled layout separating native hardware observers from the Dart user interface layer:

```text
screenshot_ocr/
├── android/
│   └── app/
│       └── src/
│           └── main/
│               ├── AndroidManifest.xml      <-- Background permissions, wake-locks & service rules
│               └── kotlin/
│                   └── com/
│                       └── mossiemostert22/
│                           └── screenshot_ocr/
│                               └── MainActivity.kt  <-- Native MediaStore observer & wake-locks
├── lib/
│   ├── main.dart                            <-- Task inbox view model layout & switch settings
│   └── services/
│       └── ocr_service.dart                 <-- Offline ML Kit engine & local notifications
├── pubspec.yaml                             <-- Project dependencies configuration profile
└── README.md                                <-- Project documentation brief
```

## 4. Technical Implementation Journey

### What Has Been Fully Implemented:
*   **Native MediaStore ContentObserver:** Replaced broken intent-broadcast tracking layouts. The app connects directly to Android's raw external database to capture file writes instantly.
*   **Hardware CPU Wake-Locks:** Wired the native `PowerManager.PARTIAL_WAKE_LOCK` layer into Kotlin to prevent aggressive phone power managers from freezing background engine threads.
*   **Offline OCR Engine:** Leveraged Google's `google_mlkit_text_recognition` model suite to perform data parsing locally on the hardware chip with zero network usage or lag.
*   **Dual-Profile Notification Tray Links:** Configured isolated notification channel streams to enable persistent tray status icons while respecting complete audio mute toggles.
*   **Inline Card Erasure Controls:** Built custom pre-deletion warning dialog screens to safely wipe both the application log entry and the original public gallery screenshot file simultaneously.

### Active Pipeline Refinements & Future Roadmap:
*   **Custom Branded Asset Badges:** Migrate the workspace layout from the default blue Flutter symbol to custom application icon graphics.
*   **Local Documents Exporter:** Implement user-named file generation scripts targeting the public local device directory: `/storage/emulated/0/Documents/`.
*   **Rich Layout Document Generation (Future Update):** Transition the exporter tool from plaintext outputs into a structured PDF or HTML rendering engine to seamlessly merge image recipes and text arrays inside a single unified document layout file.

## 5. Engineering Challenges & Solutions

### The Obstacles Faced
Modern mobile operating systems utilize aggressive background memory-freezing algorithms. This caused our background listening loops to stall out the moment the app window was minimized. Additionally, when executing long scroll captures, Samsung's native interface rapidly updates the storage database with temporary placeholder file fragments. This caused our initial listening logic to misidentify the frames, triggering an annoying storm of duplicate notifications and overlapping sound beeps for a single scrolling operation.

### Options Evaluated & Superseded
*   *Static Intent Receivers:* Abandoned because modern vendor-specific capture signals bypass global system broadcast actions.
*   *Manual Image Stitching Engines:* Created a counter-service tracking frame counts. Discarded because it forced users to manually count frames, creating severe notification delays and processing bottlenecks.

### Our Master Breakthrough Strategy
Instead of fighting the phone's native processes with manual canvas-stitching loops, the app architecture handles data collection through a streamlined, passive synchronization layout: **We let the Android operating system do all the heavy scrolling work.**

When a long scroll capture is performed, your device natively blends the pixel blocks in its RAM and saves exactly *one complete graphic file* to disk when your finger lifts. Our app remains silent while you scroll. The moment the file is written, our native `ContentObserver` wakes the processor using a 3.5-second CPU wake-lock, routes the path across the platform bridge, and fires exactly one clean notification sound block. 

To filter out the temporary file fragments generated during long scrolls, we integrated a **Global Text Matrix Contraction Filter** right inside the parsing loops. The app automatically scans your active history stack. If it identifies that a new capture overlaps with or expands upon an existing entry, it instantly purges the incomplete duplicate card out of the log registry, leaving exactly one perfect complete text task on your dashboard board.
