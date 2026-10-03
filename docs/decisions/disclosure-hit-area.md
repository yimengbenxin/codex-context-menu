# Disclosure header hit area

Decision: EXTEND the existing SwiftUI DisclosureGroup contract with one shared style at the companion content root, leaving the native sidebar List alone. Preserve disclosure-owned expansion state, labels and content; use a native plain Button whose rectangular hit area spans the available width, including blank trailing space. Apply the same rule explicitly to nested disclosure content because SwiftUI resets the style there. Keyboard activation and accessibility remain native button behavior. No runtime, configuration or conversation changes are required. GitHub publication is paused at the user's request.

Acceptance: compile and run Swift tests, then click both the title and trailing blank area of the installed usage disclosure, confirming one toggle per click and unchanged surrounding layout.

Verified locally in version 0.6.16: 56 Swift tests passed; package signature verification passed. Actual installed project-title click expanded its row. Clicking blank trailing space expanded both the project row and its nested daily-details row; nested date rows expose the same expanded/collapsed accessibility state. Installer reported global configuration unchanged. Main Codex was not restarted. No GitHub push or release was performed.
