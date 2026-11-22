# Nia v0.4.1

## UI and cursor refinement on top of the Metal preview

- removes the bordered/pill style from the active session title in the title bar
- uses a plain navigation title for the active session
- removes the vertical session color bar and the top terminal accent bar
- replaces the session color control with a subtler circular color affordance
- drops custom row background tinting so selection looks more native
- adjusts cursor row resolution when the VT cursor lands on trailing blank rows
- keeps SwiftUI/AppKit chrome and Metal terminal renderer unchanged otherwise
