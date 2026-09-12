#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================================
;  PasteFormatted.ahk  (v2 - Markdown aware, hanging-indent lists)
;  Trigger: Ctrl+W. Reads the raw note from the clipboard, formats it, and:
;    * if you have a template highlighted that contains {{tags}}, drops each
;      section into its tagged slot (replacing the highlighted template);
;    * otherwise pastes the whole formatted note at the cursor.
;  Normal Ctrl+V is left untouched.  Ctrl+Shift+W = raw / plain paste.
;
;  Template tags (own line = block insert, or inline after a label):
;    {{PROBLEMS}}                     Urologic Problem(s) summary
;    {{SINGLE PROBLEM}}               problem name inline (only if exactly one)
;    {{MULTIPLE PROBLEM LIST}}        (1)(2) list (only if two or more)
;    {{HPI}}        {{HPI_BODY}}      HPI  (with / without the bold header)
;    {{AR SINGLE}}                    single-problem A/R inline; deletes back to
;                                     the "...Recommendations:" label when multiple
;    {{AR MULTIPLE}}                  numbered A/R list (only if two or more)
;    {{AR}}         {{AR_BODY}}       whole Assessment & Recommendations
;    {{FOLLOWUP}}   {{FOLLOWUP_BODY}} Follow-up  (aka {{FU}})
; ============================================================================

TrayTip "PasteFormatted is running", "Ctrl+W formats and pastes", 1

; ---- Settings --------------------------------------------------------------
global SettleDelay  := 40     ; ms to let the clipboard settle before pasting
global RestoreDelay := 300    ; ms to wait after paste before restoring clipboard
                              ; (raise toward 400-500 if Epic still races)
global PasteBusy    := false  ; reentrancy guard

; A source line matching this (case-insensitive regex) marks the signature block;
; that line and everything below it are dropped from the pasted text. The name
; requires the "A." middle initial so an in-note mention like "with Michael Gorin,
; MD" (e.g. in a medications header) is NOT mistaken for the signature. Email and
; profile URL are also matched as signature-only fallbacks.
global SignatureAnchor := "i)Michael\s+A\.?\s+Gorin|michael\.gorin@|profiles\.mountsinai\.org/michael-gorin"

$^w:: {
    global PasteBusy
    if PasteBusy                ; ignore overlapping presses
        return
    PasteBusy := true
    try
        PasteFormatted()
    finally
        PasteBusy := false
}
$^+w::Send "+{Insert}"          ; raw / plain paste, bypasses the formatter


; ----------------------------------------------------------------------------
PasteFormatted() {
    saved      := ClipboardAll()
    sourceText := A_Clipboard

    if (sourceText = "") {          ; nothing to format
        Send "^v"
        return
    }

    note := BuildNote(sourceText)

    ; Try to capture a highlighted template (its tags tell us where sections go).
    A_Clipboard := ""
    Send "^c"
    gotSel   := ClipWait(0.6)
    template := gotSel ? A_Clipboard : ""

    if (gotSel && Trim(template) != "") {
        ; Something is highlighted.
        if (InStr(template, "{{")) {
            template    := TruncateBelowSignatureText(template)   ; drop recipient leftover
            templateRtf := TruncateBelowSignatureRtf(GetClipboardRTF())
            if (templateRtf != "") {
                rm := MergeIntoRTF(templateRtf, note)     ; preserves template formatting
                if (rm.matched) {
                    plainMerged := MergeTemplate(template, note).plain
                    PasteRich(rm.rtf, plainMerged)
                    A_Clipboard := saved
                    ClipWait(1)
                    return
                }
            }
            ; No RTF from the app -> plain-text merge (formatting not preserved).
            pm := MergeTemplate(template, note)
            if (pm.matched) {
                PasteRich(pm.rtf, pm.plain)
                A_Clipboard := saved
                ClipWait(1)
                return
            }
        }
        ; Highlighted, but no usable tags -> don't overwrite; just notify.
        A_Clipboard := saved
        ClipWait(1)
        ToolTip "No {{tags}} found in the highlighted text"
        SetTimer(() => ToolTip(), -1500)
        return
    }

    ; Nothing highlighted -> original behavior: paste the formatted note at the cursor.
    PasteRich(RenderRTF(note.lines), RenderPlain(note.lines))
    A_Clipboard := saved
    ClipWait(1)
}

; Put rich text on the clipboard and paste it (does not restore the clipboard).
PasteRich(rtf, plain) {
    if SetClipboardRichText(rtf, plain) {
        Sleep SettleDelay
        Send "^v"
        Sleep RestoreDelay
    } else {
        A_Clipboard := plain
        ClipWait(1)
        Send "^v"
        Sleep RestoreDelay
    }
}


; ----------------------------------------------------------------------------
;  Line model:
;    { kind:"normal", segs:[...], sect:"" }              normal paragraph
;    { kind:"list",   marker:"1.", segs:[...], sect:"" } hanging-indent list line
;  A segment is { text:"...", bold:true|false }.
;  sect tags which section a line belongs to: "problems","hpi","ar","fu", or "".
; ----------------------------------------------------------------------------
MakeNormal(segs) => { kind: "normal", segs: segs, sect: "" }
MakeList(marker, segs, boldMarker := true) => { kind: "list", marker: marker, segs: segs, sect: "", boldMarker: boldMarker }

TagLines(out, startIdx, sect) {
    i := startIdx
    while (i <= out.Length) {
        out[i].sect := sect
        i += 1
    }
}


BuildNote(raw) {
    raw := StrReplace(raw, "`r`n", "`n")
    raw := StrReplace(raw, "`r", "`n")
    src := StrSplit(raw, "`n")

    out          := []
    problems     := []
    apItems      := []
    apHeaderTrailing := ""
    inAssessment := false
    hadAssessment := false
    hpiSeen      := false
    sawFollowup  := false
    inHPI        := false

    idx := 1
    N   := src.Length
    while (idx <= N) {
        clean := CleanLine(src[idx])
        if (clean = "") {
            idx += 1
            continue
        }
        match := StripMd(clean)

        ; Once the note already has an HPI and an A/P, a signature line marks the
        ; end -> drop it and everything below (a duplicate note, addenda, etc.).
        if (hpiSeen && hadAssessment && RegExMatch(clean, SignatureAnchor))
            break

        ; ---- HPI ------------------------------------------------------------
        if RegExMatch(match, "i)^(?:HPI|History of Present Illness)\s*:?\s*(.*)$", &m) {
            if (inAssessment) {
                CloseAssessment(out, apHeaderTrailing, apItems, problems, sawFollowup)
                apItems := []
                inAssessment := false
            }

            trailing := Trim(m[1])
            if (trailing = "") {
                j := idx + 1
                while (j <= N && CleanLine(src[j]) = "")
                    j += 1
                if (j <= N) {
                    trailing := StripMd(CleanLine(src[j]))
                    idx := j
                }
            }
            trailing := StripDemographicStem(trailing)   ; drop duplicate "Mr. X is a NN-year-old ..."
            s0 := out.Length + 1
            EmitHeader(out, "History of Present Illness:", trailing)
            TagLines(out, s0, "hpi")
            inHPI := true
            hpiSeen := true
            idx += 1
            continue
        }

        ; ---- Assessment and Plan (and variants) -----------------------------
        if RegExMatch(match, "i)^Assessment\s*(?:and|&|/)\s*(?:Plan|Recommendations?)\s*:?\s*(.*)$", &m) {
            if (inAssessment) {
                CloseAssessment(out, apHeaderTrailing, apItems, problems, sawFollowup)
                apItems := []
                inAssessment := false
            }
            apHeaderTrailing := Trim(m[1])      ; header emitted later, at flush time
            inAssessment  := true
            hadAssessment := true
            sawFollowup   := false
            inHPI         := false
            apItems       := []
            idx += 1
            continue
        }

        ; ---- Follow-up (designated [FU]/FU:/F/U:, or a Follow-up: label) -----
        if RegExMatch(match, "i)^\s*(?:\d+[.)]\s*)?(?:\[\s*(?:F/?U|FOLLOW[\s-]?UP)\s*\]\s*:?|Follow[\s-]?up\s*:?|F/?U\s*:)\s*(.*)$", &m)
            || RegExMatch(match, "i)\bFollow[\s-]?up\s*:\s*(.*)$", &m) {
            if (inAssessment) {
                s0 := out.Length + 1
                FlushAssessment(out, apHeaderTrailing, apItems, problems)
                TagLines(out, s0, "ar")
                apItems := []
                inAssessment := false
            }
            trailing := Trim(m[1])
            if (trailing = "") {                 ; header alone -> pull following line(s)
                j := idx + 1
                pulled := ""
                while (j <= N && CleanLine(src[j]) = "")
                    j += 1
                while (j <= N && CleanLine(src[j]) != "" && !IsSectionHeader(StripMd(CleanLine(src[j])))) {
                    pulled := (pulled = "" ? "" : pulled " ") StripMd(CleanLine(src[j]))
                    idx := j
                    j += 1
                }
                if (pulled != "")
                    trailing := pulled
            }
            if (trailing = "")
                trailing := "***"
            s1 := out.Length + 1
            EmitHeader(out, "Follow-up:", trailing)
            TagLines(out, s1, "fu")
            sawFollowup := true
            inHPI := false
            idx += 1
            continue
        }

        ; ---- Assessment item (buffer; rendered at section close) ------------
        if (inAssessment) {
            apItems.Push(clean)
            idx += 1
            continue
        }

        ; ---- Ordinary line --------------------------------------------------
        if (inHPI) {                            ; still inside HPI -> keep tagging hpi
            s2 := out.Length + 1
            EmitPassthrough(out, clean)
            TagLines(out, s2, "hpi")
        } else {
            EmitPassthrough(out, clean)
        }
        idx += 1
    }

    if (inAssessment)
        CloseAssessment(out, apHeaderTrailing, apItems, problems, sawFollowup)

    ; Build the problem summary and place it at the very top, before the HPI.
    final := []
    for ln in BuildProblemSummary(problems, hadAssessment)
        final.Push(ln)
    for ln in out
        final.Push(ln)

    StripTrailingBlanks(final)
    return { lines: final, problems: problems }
}

; Flush A/P items (tagged "ar") and, if no follow-up was seen, the auto follow-up
; placeholder (tagged "fu").
CloseAssessment(out, headerTrailing, apItems, problems, sawFollowup) {
    s0 := out.Length + 1
    FlushAssessment(out, headerTrailing, apItems, problems)
    TagLines(out, s0, "ar")
    if (!sawFollowup) {
        s1 := out.Length + 1
        AddFollowup(out)
        TagLines(out, s1, "fu")
    }
}


; ----------------------------------------------------------------------------
;  Problem summary block (top of note)
; ----------------------------------------------------------------------------
BuildProblemSummary(problems, hadAssessment) {
    static Sep := "___________________________________________"
    top := []
    if (!hadAssessment)                       ; no A/P section -> no summary at all
        return top

    if (problems.Length = 0) {
        ; A/P present but no colon-delimited disease titles -> blank header to fill in
        line := MakeNormal([{ text: "Urology Problem:", bold: true }, { text: " ", bold: false }])
        line.sect := "problems"
        top.Push(line)
    } else if (problems.Length = 1) {
        line := MakeNormal([{ text: "Urologic Problem:", bold: true }, { text: " " problems[1], bold: false }])
        line.sect := "problems"
        top.Push(line)
    } else {
        hdr := MakeNormal([{ text: "Urologic Problems:", bold: true }])
        hdr.sect := "problems"
        top.Push(hdr)
        n := 0
        for p in problems {
            n += 1
            li := MakeList("(" n ")", [{ text: p, bold: false }], false)
            li.sect := "problems"
            top.Push(li)
        }
    }

    top.Push(MakeNormal([{ text: Sep, bold: false }]))   ; separator (untagged), no blank before
    top.Push(MakeNormal([{ text: "", bold: false }]))    ; blank line, then HPI follows
    return top
}


; ----------------------------------------------------------------------------
;  Template merge: drop parsed sections into tagged slots
; ----------------------------------------------------------------------------
; Return the lines belonging to one section (trailing blanks removed).
GetSection(lines, sect) {
    r := []
    for ln in lines
        if (ln.sect = sect)
            r.Push(ln)
    while (r.Length && IsBlankLine(r[r.Length]))
        r.Pop()
    return r
}

; Strip the leading bold header from a section so only the body remains.
; Handles both inline headers (HPI/Follow-up) and header-on-its-own-line (A&R).
BodyOf(lines) {
    src := lines.Clone()
    if (src.Length = 0)
        return src
    ln := src[1]
    if (ln.kind = "normal") {
        kept := []
        skipping := true
        for seg in ln.segs {
            if (skipping && (seg.bold || Trim(seg.text) = ""))
                continue
            skipping := false
            kept.Push({ text: seg.text, bold: seg.bold })
        }
        if (kept.Length >= 1)
            kept[1] := { text: LTrim(kept[1].text), bold: kept[1].bold }
        if (kept.Length = 0 || (kept.Length = 1 && kept[1].text = "")) {
            src.RemoveAt(1)                         ; header was the whole line -> drop it
            if (src.Length && IsBlankLine(src[1]))
                src.RemoveAt(1)
        } else {
            nl := MakeNormal(kept)
            nl.sect := ln.sect
            src[1] := nl
        }
    }
    return src
}

; Split a template line into text / tag tokens.
SplitByTags(line) {
    parts := []
    pos := 1
    while (RegExMatch(line, "\{\{\s*([A-Za-z_][A-Za-z_ -]*?)\s*\}\}", &m, pos)) {
        if (m.Pos > pos)
            parts.Push({ isTag: false, text: SubStr(line, pos, m.Pos - pos) })
        key := RegExReplace(Trim(StrUpper(m[1])), "\s+", " ")
        parts.Push({ isTag: true, key: key, raw: m[0] })
        pos := m.Pos + m.Len
    }
    if (pos <= StrLen(line))
        parts.Push({ isTag: false, text: SubStr(line, pos) })
    return parts
}

; Map a tag key to its lines. known=false for unrecognized keys.
; `note` is { lines, problems }.
; Collapse a set of lines into one normal line (segments joined), dropping
; list markers and blanks. Used for the single-problem inline A/R.
FlattenToNormal(lines) {
    segs := []
    for ln in lines {
        if (IsBlankLine(ln))
            continue
        if (segs.Length)
            segs.Push({ text: " ", bold: false })
        for s in ln.segs
            segs.Push(s)
    }
    if (segs.Length = 0)
        segs.Push({ text: "", bold: false })
    return MakeNormal(segs)
}

; Drop the leading bold diagnosis title (and its list marker) from the first line,
; leaving just the plan body. Used for the single-problem A/R, where the title
; already appears at the top as {{SINGLE PROBLEM}}.
StripItemTitle(lines) {
    src := lines.Clone()
    if (src.Length = 0)
        return src
    ln := src[1]
    kept := []
    skipping := true
    for seg in ln.segs {
        if (skipping && (seg.bold || Trim(seg.text) = ""))
            continue
        skipping := false
        kept.Push({ text: seg.text, bold: seg.bold })
    }
    if (kept.Length >= 1)
        kept[1] := { text: LTrim(kept[1].text), bold: kept[1].bold }
    if (kept.Length = 0)
        kept := [{ text: "", bold: false }]
    nl := MakeNormal(kept)          ; also drops the list marker
    nl.sect := ln.sect
    src[1] := nl
    return src
}

; Truncate accumulated segments back to (and including) the last anchor text.
TruncatedSegs(segs, anchor) {
    txt := ""
    for s in segs
        txt .= s.text
    p := InStr(txt, anchor, false, -1)
    if (p)
        txt := SubStr(txt, 1, p + StrLen(anchor) - 1)
    return [{ text: txt, bold: false }]
}

SectionForKey(key, note) {
    switch key {
        case "SINGLE PROBLEM", "SINGLE PROBLEM(S)":
            if (note.problems.Length = 1)
                return { known: true, lines: [MakeNormal([{ text: note.problems[1], bold: false }])], deleteBack: "" }
            return { known: true, lines: [], deleteBack: "" }
        case "MULTIPLE PROBLEM LIST", "PROBLEM LIST":
            if (note.problems.Length >= 2) {
                ls := []
                n := 0
                for p in note.problems {
                    n += 1
                    ls.Push(MakeList("(" n ")", [{ text: p, bold: false }], false))
                }
                return { known: true, lines: ls, deleteBack: "" }
            }
            return { known: true, lines: [], deleteBack: "" }
        case "AR SINGLE", "ASSESSMENT SINGLE":
            ; single/zero problem -> plan text only (title dropped); multiple -> delete back to label
            if (note.problems.Length <= 1)
                return { known: true, lines: [FlattenToNormal(StripItemTitle(BodyOf(GetSection(note.lines, "ar"))))], deleteBack: "" }
            return { known: true, lines: [], deleteBack: "Recommendations:" }
        case "AR MULTIPLE", "ASSESSMENT MULTIPLE":
            ; multiple problems -> numbered list (template supplies the gap above it)
            if (note.problems.Length >= 2)
                return { known: true, lines: BodyOf(GetSection(note.lines, "ar")), deleteBack: "" }
            return { known: true, lines: [], deleteBack: "" }
        case "PROBLEMS", "PROBLEM":
            return { known: true, lines: GetSection(note.lines, "problems"), deleteBack: "" }
        case "HPI", "HPI_BODY", "HPI BODY":
            return { known: true, lines: BodyOf(GetSection(note.lines, "hpi")), deleteBack: "" }
        case "AR", "ASSESSMENT", "PLAN", "ASSESSMENT & RECOMMENDATIONS":
            return { known: true, lines: GetSection(note.lines, "ar"), deleteBack: "" }
        case "AR_BODY", "ASSESSMENT_BODY", "AR BODY", "ASSESSMENT BODY":
            return { known: true, lines: BodyOf(GetSection(note.lines, "ar")), deleteBack: "" }
        case "FOLLOWUP", "FU", "FOLLOW UP", "FOLLOW-UP":
            return { known: true, lines: GetSection(note.lines, "fu"), deleteBack: "" }
        case "FOLLOWUP_BODY", "FU_BODY", "FOLLOWUP BODY", "FOLLOW UP BODY":
            return { known: true, lines: BodyOf(GetSection(note.lines, "fu")), deleteBack: "" }
    }
    return { known: false, lines: [], deleteBack: "" }
}

; Merge parsed sections into the template. Tags may sit on their own line
; (block insert) or inline after a label (single-line sections inline).
; Returns {plain, rtf, matched}.
MergeTemplate(templateText, note) {
    templateText := StrReplace(templateText, "`r`n", "`n")
    templateText := StrReplace(templateText, "`r", "`n")

    merged  := []
    matched := false
    for tline in StrSplit(templateText, "`n") {
        parts  := SplitByTags(tline)
        hasTag := false
        for p in parts
            if (p.isTag)
                hasTag := true

        if (!hasTag) {
            if (Trim(tline) = "")
                merged.Push(MakeNormal([{ text: "", bold: false }]))
            else
                merged.Push(MakeNormal(ParseInline(tline)))
            continue
        }

        curSegs := []
        for p in parts {
            if (!p.isTag) {
                if (p.text != "")
                    for s in ParseInline(p.text)
                        curSegs.Push(s)
                continue
            }
            sec := SectionForKey(p.key, note)
            if (!sec.known) {                       ; leave unknown tag as literal text
                for s in ParseInline(p.raw)
                    curSegs.Push(s)
                continue
            }
            matched := true

            if (sec.deleteBack != "" && NonBlankCount(sec.lines) = 0) {
                curSegs := TruncatedSegs(curSegs, sec.deleteBack)   ; delete back to the label
                continue
            }

            nonblank := []
            for l in sec.lines
                if (!IsBlankLine(l))
                    nonblank.Push(l)

            if (nonblank.Length = 1 && nonblank[1].kind = "normal") {
                for s in nonblank[1].segs          ; single-line section -> inline
                    curSegs.Push(s)
            } else if (sec.lines.Length >= 1) {     ; multi-line section -> block insert
                if (curSegs.Length) {
                    merged.Push(MakeNormal(curSegs))
                    curSegs := []
                }
                for l in sec.lines
                    merged.Push(l)
            }
        }
        if (curSegs.Length)
            merged.Push(MakeNormal(curSegs))
    }
    StripTrailingBlanks(merged)
    return { plain: RenderPlain(merged), rtf: RenderRTF(merged), matched: matched }
}


; ----------------------------------------------------------------------------
;  RTF-level merge: splice section RTF into the template's own RTF so the
;  template's formatting (fonts, bold labels, signature) is preserved.
;  Injected content carries no font/size, so it inherits the template's.
; ----------------------------------------------------------------------------
NonBlankCount(lines) {
    c := 0
    for ln in lines
        if (!IsBlankLine(ln))
            c += 1
    return c
}

MarkerRtf(mk, bold) {
    x := RtfEscape(mk)
    return bold ? ("\b " x "\b0  ") : (x " ")
}

; Multi-paragraph fragment. First line inherits the template's current
; paragraph; later lines and all list lines set their own paragraph.
BlockFragment(lines) {
    frag  := ""
    first := true
    for ln in lines {
        if (!first)
            frag .= "\par "
        if (ln.kind = "list")
            frag .= "\pard\fi-240\li240 " MarkerRtf(ln.marker, ln.boldMarker) SegsRtf(ln.segs)
        else
            frag .= first ? SegsRtf(ln.segs) : ("\pard " SegsRtf(ln.segs))
        first := false
    }
    return frag
}

; Single-run fragment (no paragraph breaks); joins any lines with a space.
InlineFragment(lines) {
    out := ""
    for ln in lines {
        if (IsBlankLine(ln))
            continue
        out .= (out = "" ? "" : " ") SegsRtf(ln.segs)
    }
    return out
}

; Prose fragment: first paragraph flows inline (continuing the template's line),
; remaining paragraphs get an explicit paragraph reset so the breaks always render.
; \pard resets only paragraph properties, so the font/size is inherited unchanged.
ParaFragment(lines) {
    frag  := ""
    first := true
    for ln in lines {
        if (first)
            frag .= SegsRtf(ln.segs)
        else
            frag .= "\par\pard " SegsRtf(ln.segs)
        first := false
    }
    return frag
}

; Return { known, frag, block, empty, deleteBack } for a tag key.
TagInfo(key, note) {
    switch key {
        case "SINGLE PROBLEM", "SINGLE PROBLEM(S)":
            if (note.problems.Length = 1)
                return { known: true, frag: RtfEscape(note.problems[1]), block: false, empty: false, deleteBack: "" }
            return { known: true, frag: "", block: false, empty: true, deleteBack: "" }
        case "MULTIPLE PROBLEM LIST", "PROBLEM LIST":
            if (note.problems.Length >= 2) {
                ls := []
                n := 0
                for p in note.problems {
                    n += 1
                    ls.Push(MakeList("(" n ")", [{ text: p, bold: false }], false))
                }
                return { known: true, frag: BlockFragment(ls), block: true, empty: false, deleteBack: "" }
            }
            return { known: true, frag: "", block: true, empty: true, deleteBack: "" }
        case "AR SINGLE", "ASSESSMENT SINGLE":
            if (note.problems.Length <= 1) {
                ls := StripItemTitle(BodyOf(GetSection(note.lines, "ar")))   ; plan only, title dropped
                return { known: true, frag: ParaFragment(ls), block: false, empty: (NonBlankCount(ls) = 0), deleteBack: "" }
            }
            return { known: true, frag: "", block: false, empty: true, deleteBack: "Recommendations:" }
        case "AR MULTIPLE", "ASSESSMENT MULTIPLE":
            if (note.problems.Length >= 2) {
                ls := BodyOf(GetSection(note.lines, "ar"))   ; items only; template supplies the gap
                return { known: true, frag: BlockFragment(ls), block: true, empty: false, deleteBack: "" }
            }
            return { known: true, frag: "", block: true, empty: true, deleteBack: "" }
        case "PROBLEMS", "PROBLEM":
            ls := GetSection(note.lines, "problems")
            return { known: true, frag: BlockFragment(ls), block: true, empty: (ls.Length = 0), deleteBack: "" }
        case "HPI", "HPI_BODY", "HPI BODY":
            ls := BodyOf(GetSection(note.lines, "hpi"))
            return { known: true, frag: ParaFragment(ls), block: false, empty: (NonBlankCount(ls) = 0), deleteBack: "" }
        case "AR", "ASSESSMENT", "PLAN", "ASSESSMENT & RECOMMENDATIONS":
            ls := GetSection(note.lines, "ar")
            return { known: true, frag: BlockFragment(ls), block: true, empty: (ls.Length = 0), deleteBack: "" }
        case "AR_BODY", "ASSESSMENT_BODY", "AR BODY", "ASSESSMENT BODY":
            ls := BodyOf(GetSection(note.lines, "ar"))
            return { known: true, frag: BlockFragment(ls), block: true, empty: (ls.Length = 0), deleteBack: "" }
        case "FOLLOWUP", "FU", "FOLLOW UP", "FOLLOW-UP":
            ls := GetSection(note.lines, "fu")
            return { known: true, frag: InlineFragment(ls), block: false, empty: (NonBlankCount(ls) = 0), deleteBack: "" }
        case "FOLLOWUP_BODY", "FU_BODY", "FOLLOWUP BODY", "FOLLOW UP BODY":
            ls := BodyOf(GetSection(note.lines, "fu"))
            return { known: true, frag: InlineFragment(ls), block: false, empty: (NonBlankCount(ls) = 0), deleteBack: "" }
    }
    return { known: false, frag: "", block: false, empty: false, deleteBack: "" }
}

; Replace {{tags}} (which appear as \{\{...\}\} in RTF) inside the template RTF.
MergeIntoRTF(templateRtf, note) {
    out     := ""
    pos     := 1
    matched := false
    while (RegExMatch(templateRtf, "\\\{\\\{\s*([A-Za-z_][A-Za-z_ -]*?)\s*\\\}\\\}", &m, pos)) {
        out .= SubStr(templateRtf, pos, m.Pos - pos)
        key   := RegExReplace(Trim(StrUpper(m[1])), "\s+", " ")
        info  := TagInfo(key, note)
        after := m.Pos + m.Len
        if (!info.known) {
            out .= m[0]                              ; leave unknown tag literal
        } else {
            matched := true
            if (info.deleteBack != "") {             ; delete back to the label (e.g. multiple A/R)
                p := InStr(out, info.deleteBack, false, -1)
                if (p)
                    out := SubStr(out, 1, p + StrLen(info.deleteBack) - 1) "\b0 "
            } else if (info.empty && info.block) {   ; drop the whole empty paragraph
                rest := SubStr(templateRtf, after)
                if RegExMatch(rest, "^\s*\\par\b", &pm)
                    after := after + pm.Len
            } else if (info.block) {                 ; block insert: reset indent afterwards
                out .= info.frag "\par\pard "
                rest := SubStr(templateRtf, after)   ; consume the template's own \par
                if RegExMatch(rest, "^\s*\\par\b", &pm)
                    after := after + pm.Len
            } else {                                 ; inline insert
                out .= info.frag
            }
        }
        pos := after
    }
    out .= SubStr(templateRtf, pos)
    return { rtf: out, matched: matched }
}


; ----------------------------------------------------------------------------
;  Emit helpers
; ----------------------------------------------------------------------------
EmitHeader(out, label, trailing) {
    segs := [{ text: label, bold: true }]
    t := Trim(trailing)
    if (t != "")
        segs.Push({ text: " " t, bold: false })
    out.Push(MakeNormal(segs))
    PushBlank(out)
}

AddFollowup(out) {
    out.Push(MakeNormal([{ text: "Follow-up:", bold: true }, { text: " ***", bold: false }]))
    PushBlank(out)
}

; Emit the (deferred) Assessment & Recommendations header plus its items.
; If at least one item has a "Diagnosis:" title -> bold header + numbered items.
; Otherwise -> the plan text starts one space after the header, on the same line.
FlushAssessment(out, headerTrailing, apItems, problems) {
    items    := GroupItems(apItems)
    hasTitle := false
    for it in items
        if (it.title != "")
            hasTitle := true

    if (hasTitle) {
        EmitHeader(out, "Assessment & Recommendations:", headerTrailing)
        n := 0
        for it in items {
            n += 1
            RenderItem(out, n, it.title, it.body)
            if (it.title != "")
                problems.Push(it.title)
        }
    } else {
        ; No titled problems: plan text follows the header inline.
        parts := []
        if (Trim(headerTrailing) != "")
            parts.Push(headerTrailing)
        for it in items {
            if (Trim(it.body) != "")
                parts.Push(it.body)
            else if (Trim(it.title) != "")
                parts.Push(it.title)
        }
        hdr := [{ text: "Assessment & Recommendations:", bold: true }, { text: " ", bold: false }]
        if (parts.Length >= 1)
            for s in ParseInline(parts[1])
                hdr.Push(s)
        out.Push(MakeNormal(hdr))
        PushBlank(out)
        i := 2
        while (i <= parts.Length) {
            out.Push(MakeNormal(ParseInline(parts[i])))
            PushBlank(out)
            i += 1
        }
    }
}

; Group buffered A/P lines into items. A numbered line ("1. ...") starts a new
; item; non-numbered lines that follow are appended to that item's plan body.
; This handles both "1. Diagnosis: plan" and "1. Diagnosis" + plan on next lines.
GroupItems(apItems) {
    items := []
    for line in apItems {
        s := Trim(StrReplace(line, "**", ""))

        ; numbered item: "1. ..." (with or without a colon)
        if RegExMatch(s, "^\s*\d+[.)]\s+(.+)$", &m) {
            ti := TitleFromHead(Trim(m[1]))
            items.Push({ title: ti.title, body: ti.body })
            continue
        }

        ; strip a leading bullet, if any, before the remaining checks
        body := RegExReplace(s, "^\s*[*\-\x{2022}]\s+", "")

        ; colon-titled item with no number: "Diagnosis: plan ..."
        cpos := InStr(body, ":")
        if (cpos) {
            cand := Trim(SubStr(body, 1, cpos - 1))
            if (IsTitleLike(cand)) {
                items.Push({ title: cand, body: Trim(SubStr(body, cpos + 1)) })
                continue
            }
        }

        ; otherwise a continuation line -> append to the current item's plan
        AppendBody(items, body)
    }
    return items
}

AppendBody(items, text) {
    if (text = "")
        return
    if (items.Length) {
        it := items[items.Length]
        it.body := (it.body = "" ? text : it.body " " text)
    } else {
        items.Push({ title: "", body: text })
    }
}

; Split a numbered line's head into a diagnosis title and any inline plan text.
TitleFromHead(head) {
    cpos := InStr(head, ":")
    if (cpos) {
        cand := Trim(SubStr(head, 1, cpos - 1))
        rest := Trim(SubStr(head, cpos + 1))
        if (IsTitleLike(cand))
            return { title: cand, body: rest }
        return { title: "", body: head }
    }
    if (IsTitleLike(head))
        return { title: head, body: "" }
    return { title: "", body: head }
}

IsTitleLike(s) {
    return (s != "" && StrLen(s) <= 60 && !InStr(s, ".") && !InStr(s, "?") && !InStr(s, "!"))
}

; True if the (md-stripped) line is an HPI / A&P / Follow-up section header.
IsSectionHeader(s) {
    if RegExMatch(s, "i)^(?:HPI|History of Present Illness)\s*:?")
        return true
    if RegExMatch(s, "i)^Assessment\s*(?:and|&|/)\s*(?:Plan|Recommendations?)\b")
        return true
    if RegExMatch(s, "i)^\s*(?:\[\s*(?:F/?U|FOLLOW[\s-]?UP)\s*\]|Follow[\s-]?up\s*:|F/?U\s*:)")
        return true
    return false
}

RenderItem(out, num, title, body) {
    if (title != "") {
        segs := [{ text: title ":", bold: true }]
        if (Trim(body) != "")
            for s in ParseInline(" " body)
                segs.Push(s)
        out.Push(MakeList(num ".", segs))
    } else {
        out.Push(MakeList(num ".", ParseInline(body)))
    }
    PushBlank(out)
}

EmitPassthrough(out, clean) {
    if RegExMatch(clean, "^\s*[*\-]\s+(.*)$", &mm) {
        out.Push(MakeList(Chr(0x2022), ParseInline(mm[1]), false))
        PushBlank(out)
        return
    }
    if InStr(clean, " * ") {
        parts := StrSplit(clean, [" * "])
        head  := parts.RemoveAt(1)
        if (Trim(StripMd(head)) != "") {
            out.Push(MakeNormal(ParseInline(head)))
            PushBlank(out)
        }
        for p in parts {
            out.Push(MakeList(Chr(0x2022), ParseInline(p), false))
            PushBlank(out)
        }
        return
    }
    out.Push(MakeNormal(ParseInline(clean)))
    PushBlank(out)
}


; ----------------------------------------------------------------------------
;  Markdown / text helpers
; ----------------------------------------------------------------------------
ParseInline(s) {
    segs := []
    bold := false
    for p in StrSplit(s, ["**"]) {
        if (p != "")
            segs.Push({ text: p, bold: bold })
        bold := !bold
    }
    if (segs.Length = 0)
        segs.Push({ text: "", bold: false })
    return segs
}

StripMd(s) {
    s := StrReplace(s, "**", "")
    s := RegExReplace(s, "^\s*[*\-\x{2022}]\s+", "")
    return Trim(s)
}

CleanLine(line) {
    line := StrReplace(line, "`t", " ")
    line := Trim(line)
    while InStr(line, "  ")
        line := StrReplace(line, "  ", " ")
    return line
}

; Remove a leading demographic stem ("[Title] Name is a NN-year-old descriptor")
; up to the connector (who/with/...) so it doesn't duplicate the template's stem.
; Text with no "NN-year-old" phrase (e.g. one that already starts "who ...") is
; returned unchanged.
StripDemographicStem(text) {
    return Trim(RegExReplace(text
        , "i)^\s*(?:[A-Z][a-z]{1,3}\.\s+)?(?:[^.]|(?:Mr|Mrs|Ms|Dr|Prof)\.)*?\b\d+[\s-]?year[\s-]?old\b(?:[^.]|(?:Mr|Mrs|Ms|Dr|Prof)\.)*?\s+(?=(?:who|whom|with|and|presenting|presents|status|s/p|here|being)\b)"
        , ""))
}

PushBlank(out) {
    if (out.Length && IsBlankLine(out[out.Length]))
        return
    out.Push(MakeNormal([{ text: "", bold: false }]))
}

IsBlankLine(ln) {
    return (ln.kind = "normal" && ln.segs.Length = 1 && ln.segs[1].text = "")
}

StripTrailingBlanks(out) {
    while (out.Length && IsBlankLine(out[out.Length]))
        out.Pop()
}


; ----------------------------------------------------------------------------
;  Renderers
; ----------------------------------------------------------------------------
RenderPlain(out) {
    s := ""
    for ln in out {
        if (A_Index > 1)
            s .= "`r`n"
        if (ln.kind = "list")
            s .= ln.marker " "
        for seg in ln.segs
            s .= seg.text
    }
    return s
}

RenderRTF(out) {
    body := ""
    for ln in out {
        if (ln.kind = "list") {
            mk := RtfEscape(ln.marker)
            if (ln.boldMarker)                       ; bold marker, 1 space, hang
                body .= "\pard\fi-240\li240 \b " mk "\b0  " SegsRtf(ln.segs) "\par`r`n"
            else                                     ; plain marker, 1 space, hang
                body .= "\pard\fi-240\li240 " mk " " SegsRtf(ln.segs) "\par`r`n"
        }
        else
            body .= "\pard " SegsRtf(ln.segs) "\par`r`n"
    }
    return "{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss\fcharset0 Arial;}}\f0\fs22 " body "}"
}

SegsRtf(segs) {
    r := ""
    for seg in segs {
        t := RtfEscape(seg.text)
        r .= seg.bold ? ("\b " t "\b0 ") : t
    }
    return r
}

RtfEscape(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, "{", "\{")
    s := StrReplace(s, "}", "\}")
    o := ""
    loop parse s {
        ch   := A_LoopField
        code := Ord(ch)
        if (ch = "`t")
            o .= "\tab "
        else if (code > 127) {
            if (code > 32767)
                code -= 65536
            o .= "\u" code "?"
        } else
            o .= ch
    }
    return o
}


; ----------------------------------------------------------------------------
;  Rich clipboard (Win32):  CF_RTF + CF_UNICODETEXT
; ----------------------------------------------------------------------------
; Remove a duplicate note that sits below the signature in the recipient template.
; Finds the signature, then the first section header (HPI/A&P/Follow-up) after it,
; and drops everything from there down. The signature block itself is kept.
TruncateBelowSignatureText(text) {
    norm  := StrReplace(StrReplace(text, "`r`n", "`n"), "`r", "`n")
    lines := StrSplit(norm, "`n")
    sigIdx := 0
    loop lines.Length {
        if (!sigIdx && RegExMatch(lines[A_Index], "i)Michael\s+A\.?\s+Gorin"))
            sigIdx := A_Index
    }
    if (!sigIdx)
        return text
    cutIdx := 0
    i := sigIdx + 1
    while (i <= lines.Length) {
        if IsSectionHeader(StripMd(CleanLine(lines[i]))) {
            cutIdx := i
            break
        }
        i += 1
    }
    if (!cutIdx)
        return text
    kept := ""
    loop cutIdx - 1
        kept .= (A_Index = 1 ? "" : "`n") lines[A_Index]
    return kept
}

; Same idea on the recipient's RTF: cut at the last paragraph break before the
; duplicate section header that follows the signature, then re-close the RTF.
TruncateBelowSignatureRtf(rtf) {
    if (rtf = "")
        return ""
    sigPos := RegExMatch(rtf, "i)Michael\s+A\.?\s+Gorin")
    if (!sigPos)
        return rtf
    leftPos := RegExMatch(rtf, "i)History of Present Illness|Assessment\s*(?:&|and)\s*Plan|Follow[\s-]?up", , sigPos + 20)
    if (!leftPos)
        return rtf
    seg := SubStr(rtf, 1, leftPos - 1)
    p := 1
    lastParEnd := 0
    while (fp := RegExMatch(seg, "\\par\b", &pm, p)) {
        lastParEnd := fp + pm.Len - 1
        p := fp + pm.Len
    }
    if (lastParEnd)
        return SubStr(rtf, 1, lastParEnd) "}"
    return SubStr(rtf, 1, leftPos - 1) "}"
}

; Read CF_RTF (Rich Text Format) from the clipboard, or "" if none is present.
GetClipboardRTF() {
    CF_RTF := DllCall("RegisterClipboardFormat", "Str", "Rich Text Format", "UInt")
    if !CF_RTF
        return ""
    if !DllCall("OpenClipboard", "Ptr", 0)
        return ""
    rtf := ""
    hData := DllCall("GetClipboardData", "UInt", CF_RTF, "Ptr")
    if (hData) {
        pData := DllCall("GlobalLock", "Ptr", hData, "Ptr")
        if (pData) {
            rtf := StrGet(pData, "CP1252")
            DllCall("GlobalUnlock", "Ptr", hData)
        }
    }
    DllCall("CloseClipboard")
    return rtf
}

SetClipboardRichText(rtf, plain) {
    static CF_UNICODETEXT := 13
    CF_RTF := DllCall("RegisterClipboardFormat", "Str", "Rich Text Format", "UInt")
    if !CF_RTF
        return false

    ; OpenClipboard fails transiently when another app holds it; retry briefly.
    opened := false
    loop 12 {
        if DllCall("OpenClipboard", "Ptr", 0) {
            opened := true
            break
        }
        Sleep 25
    }
    if !opened
        return false

    DllCall("EmptyClipboard")

    ok := true
    hUni := AllocClipboardMem(plain, "UTF-16")
    if (!hUni || !DllCall("SetClipboardData", "UInt", CF_UNICODETEXT, "Ptr", hUni))
        ok := false
    hRtf := AllocClipboardMem(rtf, "CP1252")
    if (!hRtf || !DllCall("SetClipboardData", "UInt", CF_RTF, "Ptr", hRtf))
        ok := false

    DllCall("CloseClipboard")
    return ok
}

AllocClipboardMem(str, enc) {
    static GMEM_MOVABLE := 0x0002
    sz   := StrPut(str, enc)
    hMem := DllCall("GlobalAlloc", "UInt", GMEM_MOVABLE, "Ptr", sz, "Ptr")
    if !hMem
        return 0
    pMem := DllCall("GlobalLock", "Ptr", hMem, "Ptr")
    if !pMem {
        DllCall("GlobalFree", "Ptr", hMem)
        return 0
    }
    StrPut(str, pMem, enc)
    DllCall("GlobalUnlock", "Ptr", hMem)
    return hMem
}
