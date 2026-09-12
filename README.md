# PasteFormatted

`PasteFormatted` is an AutoHotkey v2 script for converting a raw
clinical note on the Windows clipboard into a consistently formatted
note and pasting it as rich text.

It is designed around notes containing a **History of Present Illness**,
**Assessment & Recommendations**, and **Follow-up** section. It can also
identify diagnosis titles in the Assessment & Recommendations section
and automatically build a Urologic Problem/Problems summary.

The script has two modes:

1.  **Direct paste** --- format the clipboard note and paste the
    complete note at the cursor.
2.  **Template merge** --- when text containing supported `{{tags}}` is
    highlighted, insert the appropriate portions of the note into those
    locations while attempting to preserve the template's existing
    rich-text formatting.

## Requirements

-   Windows
-   AutoHotkey v2.0 or later
-   An application that accepts clipboard paste
-   Rich-text support is recommended when preservation of formatting is
    desired

The script explicitly requires AutoHotkey v2:

``` ahk
#Requires AutoHotkey v2.0
```

## Installation

1.  Install AutoHotkey v2.
2.  Save the script somewhere convenient.
3.  Run `PasteFormatted_29_debugged.ahk`.
4.  A tray notification should indicate that PasteFormatted is running.
5.  Leave the script running while using the hotkeys.

Because the script uses:

``` ahk
#SingleInstance Force
```

launching it again replaces the existing instance rather than creating
multiple copies.

## Hotkeys

### Ctrl+W --- Format and paste

`Ctrl+W` is the main command.

The script:

1.  Saves the complete current clipboard.
2.  Reads the clipboard's plain-text representation as the source note.
3.  Parses and formats the note.
4.  Temporarily copies the currently highlighted text, if any.
5.  Determines whether the selection contains a supported `{{tag}}`.
6.  If it does, merges the parsed note into the highlighted template.
7.  Otherwise, if nothing is selected, pastes the complete formatted
    note at the cursor.
8.  Restores the original clipboard after the paste.

The script includes a reentrancy guard so repeatedly pressing `Ctrl+W`
while a paste is already being processed should not start overlapping
formatting operations.

### Ctrl+Shift+W --- Raw/plain paste

`Ctrl+Shift+W` bypasses the formatter and sends:

``` ahk
+{Insert}
```

This provides a convenient way to paste without running the note through
`PasteFormatted`.

Normal `Ctrl+V` is not remapped.

## Important clipboard behavior

Before pressing `Ctrl+W`, the **raw note that you want formatted must
already be on the clipboard**.

If you want to use template mode:

1.  Copy the source note.
2.  Go to the destination application.
3.  Highlight the template text containing the `{{tags}}`.
4.  Press `Ctrl+W`.

The script temporarily replaces the clipboard while copying the
highlighted template, but it saves the original clipboard first and
restores it after the operation.

## Expected note structure

The parser recognizes an HPI heading written as either:

``` text
HPI:
```

or:

``` text
History of Present Illness:
```

It recognizes Assessment headings such as:

``` text
Assessment and Plan:
Assessment & Plan:
Assessment / Plan:
Assessment and Recommendations:
Assessment & Recommendations:
Assessment / Recommendations:
```

It also recognizes designated Follow-up/FU headings at the beginning of
a line.

A typical source note might resemble:

``` text
History of Present Illness:

who presents for follow-up of BPH/LUTS. He continues to have bothersome urinary symptoms despite medical therapy.

Assessment & Recommendations:

1. BPH/LUTS: Given the severity and progression of his symptoms despite prior medical therapy, I recommended further evaluation toward an outlet procedure.

2. Elevated PSA: His PSA remains elevated. I recommended prostate mpMRI for further risk stratification.

Follow-up: After completion of the above testing.
```

## Problem detection

The Assessment & Recommendations section is parsed into individual
problems.

Numbered lines can start new items:

``` text
1. BPH/LUTS: Plan text...
2. Elevated PSA: Plan text...
```

The script also recognizes suitable unnumbered colon-delimited titles.

Continuation lines following an item are appended to that item's plan.

For example:

``` text
1. BPH/LUTS: He has persistent symptoms.
We discussed further evaluation with cystoscopy and TRUS.
```

is treated as one Assessment & Recommendations item rather than two
separate problems.

Generic structural labels such as `Assessment`, `Plan`,
`Recommendations`, `Follow-up`, `HPI`, and `Results` are excluded from
diagnosis-title detection.

## Automatic problem summary

When an Assessment & Recommendations section is present, the script
builds a problem summary at the top of the formatted note.

For one detected problem:

``` text
Urologic Problem: BPH/LUTS
```

For multiple problems:

``` text
Urologic Problems:
(1) BPH/LUTS
(2) Elevated PSA
```

A separator is then inserted before the HPI.

If an Assessment & Recommendations section exists but no usable
diagnosis title can be identified, the script generates a blank problem
heading that can be completed manually.

## Template mode

If highlighted destination text contains `{{...}}`, `PasteFormatted`
treats the selection as a template.

Supported tags can appear on their own line or, where appropriate,
inline after a label.

### Problem tags

#### `{{PROBLEMS}}`

Inserts the generated Urologic Problem(s) section.

Alias:

``` text
{{PROBLEM}}
```

#### `{{SINGLE PROBLEM}}`

Inserts only the problem name when exactly one problem was detected.

Example:

``` text
Urologic Problem: {{SINGLE PROBLEM}}
```

If multiple problems are present, the tag is left empty.

#### `{{MULTIPLE PROBLEM LIST}}`

Inserts a numbered `(1)`, `(2)`, etc. problem list when two or more
problems were detected.

Alias:

``` text
{{PROBLEM LIST}}
```

If fewer than two problems are present, the insertion is empty.

## HPI tags

### `{{HPI}}`

Inserts the HPI body.

The script removes the generated HPI header before insertion so that a
template can supply its own heading.

Aliases include:

``` text
{{HPI_BODY}}
{{HPI BODY}}
```

Example:

``` text
History of Present Illness: {{HPI_BODY}}
```

## Assessment & Recommendations tags

### `{{AR}}`

Inserts the complete parsed Assessment & Recommendations section.

Aliases include:

``` text
{{ASSESSMENT}}
{{PLAN}}
{{ASSESSMENT & RECOMMENDATIONS}}
```

### `{{AR_BODY}}`

Inserts the Assessment & Recommendations content without its leading
header.

Aliases include:

``` text
{{ASSESSMENT_BODY}}
{{AR BODY}}
{{ASSESSMENT BODY}}
```

### `{{AR SINGLE}}`

Designed for a single-problem template.

When zero or one problem is detected, the Assessment & Recommendations
content is inserted without repeating the diagnosis title.

Example:

``` text
Assessment & Recommendations: {{AR SINGLE}}
```

When multiple problems are detected, the script can remove template
content back to the `Recommendations:` label rather than incorrectly
inserting a single-problem plan.

Alias:

``` text
{{ASSESSMENT SINGLE}}
```

### `{{AR MULTIPLE}}`

Inserts the numbered Assessment & Recommendations items only when two or
more problems are detected.

Alias:

``` text
{{ASSESSMENT MULTIPLE}}
```

## Follow-up tags

### `{{FOLLOWUP}}`

Inserts the complete Follow-up section.

Aliases include:

``` text
{{FU}}
{{FOLLOW UP}}
{{FOLLOW-UP}}
```

### `{{FOLLOWUP_BODY}}`

Inserts only the Follow-up text without the leading header.

Aliases include:

``` text
{{FU_BODY}}
{{FOLLOWUP BODY}}
{{FOLLOW UP BODY}}
```

Example:

``` text
Follow-up: {{FOLLOWUP_BODY}}
```

## Example template

A template can be constructed along these lines:

``` text
Urologic Problem: {{SINGLE PROBLEM}}
{{MULTIPLE PROBLEM LIST}}

History of Present Illness: {{HPI_BODY}}

Assessment & Recommendations: {{AR SINGLE}}
{{AR MULTIPLE}}

Follow-up: {{FOLLOWUP_BODY}}
```

The conditional single/multiple tags allow the same general template
strategy to accommodate notes containing either one problem or several
problems.

## Rich-text formatting

`PasteFormatted` supports both plain text and RTF.

When no template is involved, the script renders its own RTF using Arial
and creates:

-   bold section headings;
-   bold diagnosis titles;
-   hanging-indent numbered Assessment & Recommendations items;
-   hanging-indent bullet/list items.

When a highlighted template supplies RTF, the script first attempts an
**RTF-level merge**. This is intended to preserve the template's
existing font, font size, labels, signature, and other formatting.

Injected content generally does not specify its own font or size so that
it can inherit those properties from the destination template.

If usable template RTF is unavailable, the script falls back to a
plain/template merge and generates RTF from the resulting internal line
model.

## Markdown support

The parser understands basic `**bold**` Markdown.

For example:

``` text
**BPH/LUTS:** Persistent urinary symptoms.
```

can be converted into RTF with the appropriate bold segment.

The formatter is intentionally not a complete Markdown renderer. Its
Markdown handling is primarily designed around the formatting patterns
expected in clinical notes.

## Lists

Lines beginning with `*` or `-` can be converted into bullet items.

The script also recognizes certain inline `" * "` patterns and converts
the resulting components into bullet items.

Numbered Assessment & Recommendations items are rendered with hanging
indents so wrapped text aligns with the body rather than with the item
number.

## Demographic stem removal

When the HPI begins with a conventional demographic introduction such as
a patient name followed by an age, the script attempts to remove that
leading demographic stem before inserting the HPI.

This is intended for destination templates in which the demographic
portion is already generated elsewhere.

Text that already begins directly with wording such as:

``` text
who ...
```

is left intact.

## Follow-up behavior

If the source contains an explicit Follow-up section, it is parsed and
used.

If an Assessment & Recommendations section is present but no Follow-up
section is found, the formatter automatically adds:

``` text
Follow-up: ***
```

This provides a visible placeholder rather than silently omitting the
section.

## Signature handling

The script contains signature detection intended to prevent duplicate
note material below the clinician's signature from being included in the
formatted result.

The configured signature anchor recognizes:

-   `Michael A. Gorin` with an optional period after the middle initial;
-   the configured email-address pattern;
-   the configured Mount Sinai profile URL pattern.

When parsing a source note, a matching signature encountered after both
the HPI and Assessment have been recognized is treated as the end of the
note.

Template cleanup also attempts to detect a duplicate note below the
signature and remove that duplicate while preserving the signature block
itself.

## Clipboard implementation

Rich text is placed on the Windows clipboard using the Win32 clipboard
API.

The script registers and writes:

-   `CF_UNICODETEXT`
-   `Rich Text Format` (`CF_RTF`)

If rich clipboard creation fails, it falls back to putting the
plain-text representation on the clipboard before pasting.

The clipboard-open operation is retried briefly because another Windows
application can transiently hold the clipboard.

## Timing settings

Near the beginning of the script are two useful settings:

``` ahk
global SettleDelay  := 40
global RestoreDelay := 300
```

`SettleDelay` gives Windows a short period to recognize the newly
populated clipboard before `Ctrl+V` is sent.

`RestoreDelay` controls how long the script waits after issuing the
paste before restoring the user's original clipboard.

If the destination application occasionally pastes the wrong clipboard
contents or appears to race the clipboard restoration, increasing
`RestoreDelay` is a reasonable first troubleshooting step. The source
comments specifically suggest trying approximately 400--500 ms when
necessary.

## What happens when highlighted text has no tags?

If text is highlighted but does not contain a usable `{{tag}}`, the
script deliberately does **not** overwrite the selection.

Instead, it restores the clipboard and displays:

``` text
No {{tags}} found in the highlighted text
```

This is a safety mechanism intended to prevent accidentally replacing
selected clinical text.

## Unknown tags

Unknown `{{tags}}` are not silently discarded by the template parser.
They are retained as literal text.

This makes an incorrectly named tag easier to notice.

## Troubleshooting

### Ctrl+W does nothing

Confirm that:

-   AutoHotkey v2 is installed;
-   the script is running;
-   the source note is actually on the clipboard;
-   another AutoHotkey script or application is not intercepting
    `Ctrl+W`.

### The wrong text gets pasted

The most likely cause is clipboard timing.

Try increasing:

``` ahk
global RestoreDelay := 300
```

to:

``` ahk
global RestoreDelay := 400
```

or:

``` ahk
global RestoreDelay := 500
```

### My selected template was not replaced

Make sure the highlighted selection actually contains a supported tag
such as:

``` text
{{HPI_BODY}}
```

A selection without recognized tags is intentionally protected from
replacement.

### Formatting is lost

The application may not be exposing the selected template as RTF or may
not accept RTF from the clipboard in the expected way.

The script falls back to its own generated rich/plain representation
when an RTF-level template merge is unavailable.

### A diagnosis is missing from the problem list

Use a clear Assessment & Recommendations structure, preferably:

``` text
1. Diagnosis: Plan...
```

or:

``` text
1. Diagnosis
Plan...
```

The diagnosis title should be concise and should not resemble ordinary
prose.

### Something that is not a diagnosis appears as a problem

Review the source Assessment & Recommendations formatting. The parser
uses structural heuristics rather than medical terminology recognition.

The debugged version excludes common generic section labels, but unusual
colon-delimited headings may still look like diagnosis titles to the
parser.

### The note is cut off unexpectedly

Check whether the source contains text matching the configured signature
anchor before the intended end of the note.

Signature truncation is only activated in source-note parsing after the
formatter has already recognized both an HPI and an Assessment section.

## Internal architecture

The script can be thought of as five layers:

``` text
Clipboard
    ↓
BuildNote()
    ↓
Structured line model
    ↓
Template merge / complete-note rendering
    ↓
RTF + Unicode clipboard
    ↓
Paste
```

### `BuildNote()`

Parses the raw clipboard text and identifies the major clinical
sections.

It returns an object containing:

``` text
{
    lines: ...,
    problems: ...
}
```

### Internal line model

A normal line resembles:

``` text
{ kind: "normal", segs: [...], sect: "hpi" }
```

A list line resembles:

``` text
{
    kind: "list",
    marker: "1.",
    segs: [...],
    sect: "ar",
    boldMarker: true
}
```

Segments contain text plus a bold flag.

This intermediate representation separates parsing from output
formatting.

### `GroupItems()`

Converts raw Assessment & Recommendations lines into logical problem
items consisting of:

``` text
{
    title: ...,
    body: ...
}
```

### `SectionForKey()` / `TagInfo()`

Map template tags to the corresponding portions of the parsed note.

`SectionForKey()` supports the normal template-rendering path.

`TagInfo()` supplies the RTF fragments used for direct RTF-level
template merging.

### `MergeTemplate()`

Performs template replacement using the internal line representation and
can produce both plain text and newly generated RTF.

### `MergeIntoRTF()`

Performs replacement directly inside the destination template's RTF.

This is the preferred template path when RTF is available because it
allows the surrounding template formatting to remain intact.

### `RenderPlain()` / `RenderRTF()`

Convert the internal line model into plain text or standalone RTF.

### `SetClipboardRichText()`

Places both Unicode plain text and RTF representations on the Windows
clipboard before issuing the paste command.

## Debugged-version changes

The debugged version includes several defensive changes while preserving
the original architecture and intended behavior:

1.  Follow-up detection is anchored so an incidental `follow-up:` phrase
    inside ordinary prose is less likely to be mistaken for a section
    boundary.
2.  Generic structural headings are excluded from diagnosis-title
    recognition.
3.  Signature detection is made consistent across source parsing and
    template truncation.
4.  Clipboard allocations are explicitly released when ownership is not
    successfully transferred to Windows.

These changes are intended to reduce false parsing and improve
robustness without changing the basic workflow.

## Safety and testing

This script transforms clinical text automatically. Review the pasted
result before signing or finalizing a clinical note.

When modifying the parser, test at minimum:

-   a single-problem note;
-   a multi-problem note;
-   a note without explicit Follow-up;
-   a note with multiline Assessment items;
-   a note containing Markdown bold;
-   a plain direct paste;
-   a tagged template paste;
-   a template with a signature;
-   a source containing duplicate material below the signature;
-   a note containing non-ASCII characters.

## Customization

The script is intentionally organized into relatively independent
parsing, rendering, template, and clipboard functions.

The most useful customization points are:

-   `SignatureAnchor` --- signature recognition;
-   `SettleDelay` --- delay before paste;
-   `RestoreDelay` --- delay before restoring the clipboard;
-   `SectionForKey()` --- plain-template tag behavior;
-   `TagInfo()` --- RTF-template tag behavior;
-   `GroupItems()` / `IsTitleLike()` --- Assessment problem detection;
-   `RenderRTF()` --- standalone rich-text appearance.

When adding a new template tag, update both the plain-template and
RTF-template mappings so behavior remains consistent between the two
paths.

## License

No license is specified in the source script. Add a license here if the
project will be distributed outside its intended environment.
